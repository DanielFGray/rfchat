# Scoped reads

Status: proposed design, revision 5 (slice 1 built). Three cold reviews on gpt-6.1-sol are logged on the task. Task: "Context reads take the signed-in user's Scope and return only what that user can see".

## Rule

Every **domain operation** takes a `%Scope{}` as its first argument. A domain operation is any public function that reads or changes chat data for someone: messages, reactions, channels, threads, members, roles, emojis, settings, moderation, bots, notifications.

- A read returns only rows the scope may see under the read policy below.
- A write runs its permission check and its change in one transaction (see "Consistency").
- A row the scope may not see is answered the same way as a row that does not exist (`nil` or `{:error, :not_found}`). A response never tells whether a hidden row exists.

Three kinds of function are not domain operations and take no Scope:

- **Authentication** builds a Scope from a credential: `Accounts.get_user_by_session_token/1` and `Bots.get_bot_scope_by_token/1`.
- **Pure helpers** read no rows: `asset_url/1`, `default_reaction_emojis/0`, serializers.
- **Provisioning** runs from `Rfchat.Bootstrap` and `Rfchat.Release` only. It reads and writes through its own queries in those modules. There is no "system scope": a scope that sees everything is one argument away from a web handler.

The web layer (`lib/rfchat_web`) calls only domain operations, authentication and pure helpers. It calls `Repo` nowhere.

Terms:

- **Scope**: the struct that names who acts. It is built once per request or LiveView mount, by authentication.
- **Visible channel set**: the ids of the channels and threads the scope may view now.
- **Decision**: one answer to "may this scope do this action on this target now".

## Why

The contexts take `%User{}` or no actor, so each handler must remember its own check. The security review found three bugs from handlers that forgot: message events that loaded any message by id, message edits with no view check, and bot role grants that ignored overwrites. An inventory found seven more unscoped by-id call sites in the web layer and three direct `Repo` calls there.

## The Scope struct

One struct for people and bots. It replaces `Rfchat.Accounts.Scope` (`user, membership, roles, base_permissions`) and `Rfchat.Bots.BotScope` (`bot_user, token, roles, base_permissions`):

```elixir
defmodule Rfchat.Accounts.Scope do
  defstruct [:user_id, :bot_token_id]
end
```

- The struct holds no permission snapshot. `base_permissions` and `roles` are copied at mount today, and they go stale after a role change, a timeout or a ban.
- For a bot scope, every decision first checks the token row: it still names this bot, `revoked_at` is nil, and `expires_at` has not passed. A revoked or expired token fails every call, with no event needed. The event reader runs the same check on every page it pulls, and pulls at least every 20 seconds, so a quiet bot stream is checked every 20 seconds (event-log.md, "Reading").
- The web layer keeps a separate `current_user` assign for display (the name in the user menu). Display data never decides access.

## Decisions: one module

`Rfchat.Chat.Visibility` makes every access decision. It replaces `Rfchat.Chat.Permissions` and the permission copy in `RfchatWeb.Live.SharedHelpers.scope_permissions`. `Rfchat.Chat.Authorization` stays as the pure bitmask math under it. This design absorbs the task "Compute channel permissions once, in one module".

```elixir
Visibility.member(scope)                    # the fresh member, or nil (deleted, banned, kicked, bad token)
Visibility.can?(scope, action, target)      # one decision
Visibility.visible_channels(scope)          # the visible channel and thread structs, for list readers
Visibility.channel_ids(scope)               # visible channel set, for list readers only
Visibility.authority(scope, channel_ids)    # the facts Bots.Authority decides a role grant from, in one load
Visibility.timed_out?(membership)           # the one timeout rule, also read by the banned page
```

`can?/3` owns every rule that today is spread over `Permissions` and the contexts:

| Rule | Today | In `can?/3` |
|---|---|---|
| Channel bits and overwrites | `Authorization.channel_permissions/3` | yes, through Authorization |
| A thread needs its parent visible | `can_view_thread_channel?` | yes |
| Send in a thread needs the parent's send | `thread_parent_allows_messages?` | yes |
| A timeout blocks send, react, edit, thread create | `timed_out?` checks in each caller | yes, for those actions |
| Role hierarchy for moderation | `top_role_position`, `authorize_member_moderation` | yes, `:moderate` actions |
| Bot grant authority | `Bots.Authority` | stays in `Bots.Authority`, which reads `authority/2`: owner, server bits, top role position and the bits in each named channel, from one load |
| Owner and administrator | `expand_administrator`, owner checks | yes |

Old `Permissions.can_*?` functions are deleted, not kept beside `can?/3`.

Cost:

- A by-id read loads the target, its channel (and its parent channel, for a thread), their overwrites and the member, then decides. It does not build the whole visible set.
- `channel_ids/1` is for list readers only: the channel sidebar, the bot stream and the event reader's context. It loads the inputs in batches (channels, threads under visible parents, their overwrites, the member) and decides each one with the same pure `Authorization` function and parent rule as a by-id read. There is one permission algorithm. Overwrite precedence (default role, then roles, then the user; allow after deny at each level; administrator first) is never restated in SQL.
- No cache across calls. The event reader computes its read context once per page and keeps nothing between pages. Measure first: slice 1 counts the queries for each decision and benchmarks a server with 200 channels and 20,000 threads. If SQL filtering is ever needed, it must implement the full precedence, and a property test must prove it equal to the pure function.
- Measured in slice 1: each by-id decision is one statement, except moderation, which reads the actor and then the subject (two); `authority/2` is one, and a role grant whose overwrites name channels reads those channels in a second; `channel_ids/1` is 3 statements and 435 to 507 ms on 200 channels and 20,000 threads; the GuildLive join runs 15 queries before its first connected render and 50 once hydrated. `channel_ids/1` is `visible_channels/1` mapped to ids, so a list reader that needs the structs does not load the channels twice.

## Read policy

| Data | Who may read |
|---|---|
| Channels, threads, messages, reactions | members who can view the channel (and the thread's parent) |
| Server name, icon, custom emojis | every active member |
| Member directory (names, avatars, roles, bots) | every active member |
| A member's notification settings and read state | that member only |
| Bot tokens (metadata, never values) | members with `manage_bots` who also pass `Bots.Authority.control_bot` for that bot |
| Message attachments | the same as the message they belong to; the upload route serves them only through that scoped check |
| Avatars, banners, custom emojis, the server icon | anyone with the URL, as today (they appear in other members' views and, later, in federated copies) |
| Moderation cases and the audit log | members with `kick_members`, `ban_members`, `moderate_members` or `administrator` (until slice 4 adds the `view_audit_log` bit, which then replaces this list; question 3) |
| A message body inside a reply preview or thread starter | the same as the referenced message |

Related data follows the row it hangs on only where an invariant makes that safe. Each invariant is checked on write:

- `reply_to_id` must name a message in the same channel. `create_message` checks it today; keep and test it.
- A thread's starter message is in the thread's parent channel. Thread creation sets it from the scoped message read.
- Mention ids must name existing users and roles that the author may see under the member directory policy. Mentions never carry content.

The policies in this table that are marked by an owner question below are proposals until the owner answers.

Serializers become pure functions of already-loaded data. The `Repo.preload` calls in `Rfchat.Bots.Serializer` move into the scoped read that feeds it, so a serializer can never be a second read path.

## Consistency

- The permission check and the change run in one transaction at READ COMMITTED. The transaction locks first and loads after: it takes its membership locks, then loads all the inputs of one decision (member, roles, the channel and its parent, their overwrites) in one statement. One statement at READ COMMITTED sees one snapshot, so a decision never mixes role bits from before a change with overwrites from after it.
- Lock protocol for membership rows. Each write names every membership row it needs before it starts, takes each one once, in the strongest mode it needs, in ascending user id order:
  - a write by a member that changes no membership: the actor's row, `FOR SHARE`;
  - a write that changes the actor's own membership (profile, nickname, leaving): the actor's row, `FOR UPDATE`;
  - moderation (timeout, kick, ban) and ownership changes: the actor's and the subject's rows, `FOR UPDATE`, in id order.
  A ban is then atomic with respect to the banned member's own writes: no write by them commits after the ban commits. Taking each row once, in id order, prevents lock upgrades and opposite-order deadlocks.
- After the membership rows, a write locks channel rows (parent before child, then by id), then the message row; the event head comes last (event-log.md, "Deleted channels"). A message write locks its message row `FOR UPDATE` and reads it only while `deleted_at` is null. A deleted message takes no action: edit, delete and reaction answer `{:error, :not_found}`.
- A role or overwrite change does not lock every member. A write whose one-statement load ran before such a change committed may still commit after it. It then acts on one coherent earlier decision. That overlap lasts at most one transaction. This is a proposed policy, pending owner question 4.
- A read decides from one statement (the permission inputs, and the target when it names one), then loads the rows it returns. A read therefore returns only rows the scope could see at the moment of its decision, which is what a read one statement earlier would return. A decision never mixes inputs from two snapshots, because Visibility loads them in one statement. REPEATABLE READ adds nothing for these reads. The event reader still needs it: its snapshot and cursor must come from one moment (event-log.md, "Reading").
- Live delivery is covered by the event log design. Each page an event reader pulls is authorized from current data, like any read.

## Context API shape

| Today | Scoped |
|---|---|
| `Chat.get_message!(id)` | `Chat.get_message(scope, id)` returns a message or `nil` |
| `Chat.get_message_in_channels(id, ids)` | removed; `Chat.get_message(scope, id)` |
| `Chat.list_messages(channel_id, opts)` | `Chat.list_messages(scope, channel_id, opts)` returns `{:ok, page}` or `{:error, :not_found}` |
| `Chat.get_message!(id)` (several ids) | `Chat.get_messages(scope, ids)` returns the visible messages among `ids`, in order |
| `Chat.get_channel!(id)`, `get_channel/1` | `Chat.get_channel(scope, id)` |
| `Chat.get_channel_by_slug_for_user(slug, user)` | `Chat.get_channel_by_slug(scope, slug)` |
| `Chat.list_visible_channels_for_user(user)` | `Chat.list_channels(scope)` |
| `Chat.create_message(channel, user, attrs)` | `Chat.create_message(scope, channel_id, attrs)` |
| `Chat.update_message(message, user, attrs)` | `Chat.update_message(scope, message_id, attrs)` |
| `Chat.create_channel(attrs)` (no actor) | `Chat.create_channel(scope, attrs)`; the context decides `manage_channels` |
| `Chat.create_custom_emoji_from_upload(user, ...)` (actor, no check in the context) | `Chat.create_custom_emoji(scope, upload, attrs)`; the context decides `manage_emojis_and_stickers` |

Rules for the shape:

- Writes take ids, not structs the caller loaded. The write loads its target through the scoped read.
- A write that has no actor today (channels), or has an actor with no check in the context (emojis), gains the decision inside the context. The web checks (`can_manage_channels?` and similar) stay only to decide what to show.
- Bang functions (`get_*!`) leave the public API.

UI rules stay in the web layer. A scoped read answers "may this person see it". It does not answer "is it on their screen". GuildLive keeps `State.fetch_open_message/2`: a message event acts only on a message in the open channel or thread, and that message is loaded through `Chat.get_message(scope, id)`.

## Enforcement

1. A test runs `rg 'Repo\.' lib/rfchat_web` and expects no match.
2. Each domain operation pattern-matches `%Scope{}` in its first argument, so a forgotten scope fails loudly.
3. One test per LiveView and API surface sends each event or request with two ids: a row in a channel the actor cannot view, and a row in a visible channel that is not open. The first never appears in any response. The second is ignored by events that act on the open conversation. The GuildLive test in the commit "fix(guild): act only on messages in the open conversation" is the model.

## Order of work

Each slice deletes the old functions and updates all their callers. No old signature is kept beside a new one.

1. **Scope and Visibility, with every consumer.** The new Scope struct, `Visibility.member/1`, `can?/3` and `channel_ids/1`. Every reader of the old Scope and BotScope fields moves in this slice: `UserAuth`, `RequireBotAuth`, `Bots.can_manage_bots?/1`, `Bots.Commands`, `SharedHelpers`, LiveView assigns. The `Permissions` callers move to `can?/3`. Includes the query count and the benchmark.
2. Messages and reactions: scoped reads, writes by id, membership lock, pure serializer.
3. Channels and threads, including SettingsLive channel edit and delete.
4. Emojis, server settings, moderation, notifications, member directory, under the read policy.
5. Bots management and the message API.
6. Remove `Repo` from the web layer and add the enforcement tests.

Slices 2 to 5 share `chat.ex` (the facade), so they run in order.

## Effects on other work

- The event log design reads `Visibility.channel_ids/1` and `can?/3` for replay and live delivery.
- The client API for people and bots uses one Scope for both.
- `Visibility` removes the `:cache_default_role` test switch (task "Remove test-only switches"), because the default role is read with the member.

## Questions for the owner

1. **Managers and hidden channels.** Decided by the owner (2026-11-08): a member with `manage_channels` who cannot view a channel cannot see or edit it (as in Discord). The other option is that `manage_channels` sees every channel.
2. **Member directory.** Proposed: every active member sees every member and bot (names, avatars, roles). The other option limits the directory to members who share a visible channel.
3. **Audit log access.** Decided by the owner (2026-11-08): add a `view_audit_log` permission bit, as Discord has, and give it to the moderator roles. The other option reuses the moderation bits.
4. **Role changes and writes in flight.** Proposed: a write that loaded its permissions just before a role or overwrite change committed may still commit (an overlap of at most one transaction), as described under "Consistency". The other option locks every affected member on each role change, which makes role edits slow on a large server.
