# Event log

Status: proposed design, revision 5. Four cold reviews on gpt-6.1-sol are logged on the task. Task: "One numbered event log for the chat server". It depends on [scoped-reads.md](scoped-reads.md) for every access decision.

This is a **local** event log. Federation will deliver some events to peers through its own protocol, which adds signatures, origin identity, acknowledgements and retry. This design fixes only what federation will build on: one order, a local-only flag and a redaction envelope that keeps its identifying fields.

## Rule

Every logical change to chat data appends events in the same transaction as the change. Events have one global order. Each reader keeps its own cursor and pulls the events after it from the table, in pages. For each page it reloads its permissions, so a page is authorized the same way as any scoped read. A PubSub message only tells readers that the table has new rows.

Terms:

- **Event**: one row in `events`, recording one logical change (a message created, a role given, a member banned).
- **`seq`**: the event's place in the one total order. Committed `seq` values have no gaps. Retention deletes old rows, so gaps exist only at or below the prune watermark.
- **Reader**: a consumer of events: a GuildLive socket, a bot stream, a client API socket, the audit page.
- **Cursor**: `{epoch, seq}`. `seq` is the highest event the reader has scanned, whether or not it delivered that event. `epoch` names the database generation (see "Restore").
- **Page**: one pull: the events after the cursor, at most 500, read with the reader's permissions in one transaction.
- **Read context**: what the reader's scope may see now: the member, the visible channel set, permission bits, the bots it controls. `Visibility` from [scoped-reads.md](scoped-reads.md) computes it for each page. It is never kept from one page to the next.

## Why

The bot event stream, the client API, the audit log page, reconnect recovery and, later, federation all need "what changed since point N". Today:

- broadcasts carry no number, and the bot stream cannot resume;
- many writes broadcast nothing (timeout, kick, ban, bots, emojis, server settings);
- `delete_message` and the reaction writes run outside a transaction;
- `audit_log_entries` and the PubSub tuples describe the same changes in two shapes.

## Tables

```sql
create table event_log_head (
  singleton      boolean primary key default true check (singleton),
  epoch          uuid not null,        -- database generation
  head           bigint not null,      -- highest committed seq
  pruned_through bigint not null       -- rows at or below this may be gone
);

create table events (
  seq          bigint primary key,
  kind         text not null,          -- from the event catalogue
  channel_id   uuid,                   -- plain id, no foreign key; null for server-wide kinds
  subject_id   uuid,
  actor_id     uuid,
  local_only   boolean not null,
  payload      jsonb not null,         -- the envelope below
  recorded_at  timestamptz not null default clock_timestamp()
);
```

- The writer takes `seq` with `update event_log_head set head = head + 1 returning head`. The row lock is held until commit, so `seq` order is commit order, and a rollback undoes the increment. The federation research proposed the same transactional head row.
- `recorded_at` is the time of the append, not of the commit. Retention uses it as an approximate age. `seq` is the only order.
- `channel_id` is not a foreign key, so a deleted channel's id stays on its events.
- At one chat server's write rate (tens of writes a second), one head row is not a bottleneck. Slice 1 measures it on real connections.
- Typing and presence stay in Valkey and are not events.

## Envelope and payloads

```json
{"v": 1, "kind": "message.created", "id": "<subject uuid>", "data": { ... }}
```

- `data` comes from one pure serializer per kind. The bot stream, the client API and a resumed reader receive the same frames. The `Bots.Serializer` functions become these serializers, with their database reads moved out.
- Only `message.created` and `message.updated` carry a message body. Every other kind refers to messages by id: reactions carry `message_id`, the emoji, the user and the new count; replies carry `reply_to_id`; threads carry `starter_message_id`.
- Structure events are opaque: `channel.*`, `thread.*` and `permissions.changed` carry only ids. A reader that receives one fetches the channel or thread through a scoped read. A hidden channel's name or kind never reaches a member who cannot view it.
- Token values and hashes are never in a payload. A moderation reason is only in the `moderation.*` kinds.
- Author display data (names, avatars) is not repeated in message payloads. Each reader keeps a member directory from its snapshot and updates it from `member.*` events.

## Event catalogue

`Rfchat.Events.Catalogue` lists every kind with its visibility predicate, its retention class and its local-only flag. A test checks that every kind any context appends is in the catalogue, and that no kind is a wildcard. Each predicate is a pure function of (read context, event). It applies the read policy of [scoped-reads.md](scoped-reads.md), so the event log has no second permission algorithm.

| Kinds | Who receives it (predicate) | Retention | Local only |
|---|---|---|---|
| `message.created/updated/deleted`, `reaction.added/removed` | can view `channel_id` (a thread id for thread messages, so the thread's own overwrites apply) | window | no |
| `channel.created/updated/deleted`, `channels.reordered`, `thread.created/updated/deleted` | every active member (payload is ids only) | permanent | no |
| `permissions.changed` (role or overwrite change; ids only) | every active member | permanent | no |
| `member.joined/left/updated`, `role.created/updated/deleted`, `member_roles.changed`, `owner.changed` | every active member | permanent | no |
| `emoji.created/deleted`, `settings.updated` | every active member | permanent | no |
| `member.timed_out/kicked/banned/unbanned` | every active member (public facts only) | permanent | no |
| `moderation.case_opened/revoked/expired` (reason, case number) | members with the audit-log permission | permanent | yes |
| `bot.created/updated/revoked`, `bot_token.minted/revoked` (metadata only) | members with `manage_bots` who pass `control_bot` for that bot | permanent | yes |
| `session.revoked` | the session's own user | window | yes |
| `notification_settings.updated`, `read_state.updated` | that member only | window | yes |

Not events: typing, presence, `last_seen_at`, and the channel-membership rows made during navigation. They are derived bookkeeping. Logging them would add events on reads, and could start a loop between read state and notifications.

Writers, all in the inventory: Chat, Channels, Threads, Notifications, Emojis, ServerConfig, Accounts (registration, profile, ownership changes, session-token revocation) and Bots (bot create, update, revoke; token mint and revoke, each in one transaction with its event).

## Writing

Composed operations build one `Ecto.Multi`. Only the operation that owns the transaction runs it:

```elixir
Ecto.Multi.new()
|> Messages.create_steps(scope, channel_id, attrs)   # domain steps, no Repo calls
|> Events.append(:created, &Events.Message.created/1)
|> Events.run()
```

- A context function that other operations compose exposes a `*_steps` function. It adds steps to a Multi. The public operation is those steps plus `Events.run/1`.
- `Events.run/1` refuses to run inside another transaction (`Repo.in_transaction?/0` is true). It raises and names the caller, so nested work cannot signal before the outer commit.
- `Events.append` steps come last in the Multi. The head lock is then held only for the inserts and the commit.
- After `{:ok, changes}`, `Events.run/1` broadcasts `{:events_committed, epoch, head}` on one topic to every node. After an error it sends nothing.
- Message update and delete lock the message row `FOR UPDATE`, then reload it. An update of a tombstoned message fails with `{:error, :not_found}`. An update therefore never appends content after a delete.
- The writer's own LiveView applies its changes from the events, like every other reader. The handlers that today insert their own results directly stop doing so, so each change has one owner.

## Reading

Every reader runs the same loop, through `Rfchat.Events.Reader`:

1. **Subscribe first.** The reader subscribes to the `events_committed` topic.
2. **Open.** `Reader.open(scope, snapshot_fun)` runs, in one REPEATABLE READ transaction: `Visibility.member(scope)`, the consumer's snapshot function, and a read of `epoch` and `head`. It returns `{:ok, snapshot, cursor}` or `{:closed, reason}`. The consumer installs the snapshot and the cursor in the same handler. GuildLive's snapshot function is its hydration. A bot stream's is its visible channel list.
3. **Pull a page.** `Reader.pull(scope, cursor, known_channel_ids, load_channel)` runs, in one REPEATABLE READ transaction:
   - read `epoch`, `head` and `pruned_through`; a different epoch, or a cursor below `pruned_through`, returns `{:resync, reason}`;
   - `Visibility.member(scope)`, including the live token check for a bot; a failure returns `{:closed, reason}`;
   - compute the read context, including the visible channel set;
   - for each visible channel not in `known_channel_ids`, call the consumer's `load_channel` function, in the same transaction;
   - read `seq > cursor order by seq limit 500`;
   - keep the events whose catalogue predicate accepts that context.

   It returns `{:ok, %Page{}}` with these fields:
   - `events`: the kept events, in order;
   - `cursor`: the last `seq` read, even when no event was kept; the input cursor when no row was read;
   - `more?`: true when the page read 500 rows, so the consumer pulls again at once;
   - `visible`: the visible channel set;
   - `gained`: for each newly visible channel, the state `load_channel` returned;
   - `floor`: the `head` read in this transaction.
4. **Install, apply, then advance.** The consumer handles a page in this order:
   1. For each channel in `known_channel_ids` but not in `visible`, clear that channel's state.
   2. For each channel in `gained`, install its loaded state and record `floor[channel] = page.floor`.
   3. Apply the events in order. Skip every event of a channel whose `seq <= floor[channel]`, with all its side effects (stream insert, unread count, mention push, desktop notification). The loaded state already shows those messages, and messages sent before the member gained the channel send no notification.
   4. Store `page.cursor`.

   Every side effect happens only on this path, and only for events above the stored cursor. The gained and lost channels are installed first, because the page can hold a gained channel's events before the permission event that made it visible.
5. **When to pull.** On `{:events_committed, _, head}` with `head` above the cursor; again at once while `more?` is true; and on a timer every 20 seconds. When the reader handles one `events_committed` message, it first removes every other queued `events_committed` message from its mailbox (a `receive ... after 0` loop), so a burst of writes causes one pull, not one pull per write.

Authorization follows scoped reads: "may this scope see this now", decided once per page from current data. Two results follow, and they are accepted:

- An event in a short window where access was removed and given back can be delivered, when the page is read after the access came back. The member could read the same message through a scoped read at that time. This follows from the owner decision on question 3 (full history on gaining access).
- A ban, a role change or a token revocation takes effect at the reader's next page or timer pull. The timer schedules that check every 20 seconds. A reader that is blocked (for example on a slow SSE client) is checked when it is free again; the bot stream sends with a write timeout and closes when the timeout passes. The ban path also disconnects the banned member's sockets (task "Make moderation and role revocation effective on connected sockets").

What each consumer does with accepted events:

- GuildLive applies message and reaction events to its stream only for the open channel or thread, as today. It updates unread counts for the other visible channels, and it sends notifications under the member's notification settings.
- On structure, permission, member and role events, GuildLive reloads the channel tree through a scoped read. For each channel that left the visible set, it clears that channel's messages and unread state.
- Channels that joined or left the visible set are handled by step 4, before the page's events. A floor does not affect other channels' events.

### Resume: bot stream and client API

- Each SSE frame carries `id: <epoch>.<seq>`. When nothing was delivered for 20 seconds, the keepalive sends `event: progress` with the cursor as its `id`, so a client that resumes after a quiet period does not rescan events it could not see.
- `Last-Event-ID` subscribes (step 1), then pulls from that cursor (step 3). It needs no open step and no hand-off: the pull loop is the same for live and resumed readers.
- A `Last-Event-ID` that does not parse, names another epoch, is above `head`, or is below `pruned_through` gets `event: resync_required`. The client reloads its state through scoped reads.

### Pre-grant history

When a member gains a channel, they load its current history through a scoped read, as in Discord. They do not replay its old events. Owner question 3 covers this.

## Deleted messages

The delete runs in one transaction:

1. Lock the message row, reload it and tombstone it.
2. Rewrite the payloads of that message's `message.created` and `message.updated` events to the redaction envelope: `{"v": 1, "kind": <same>, "id": <same>, "redacted": true}`. Only those two kinds carry a body.
3. Append `message.deleted`.

A reader that pulled a page before the delete committed may already hold the body. It then receives `message.deleted` in a later page and removes the message. This is the same as a person who saw the message before it was deleted. A pull after the delete never returns the body.

The envelope keeps `v`, `kind` and `id`. The federation design can choose to sign those fields plus a content hash, so that redaction does not break a signature. That signature design is still open. This matches the task "Make deleted-message semantics consistent and immutable".

## Deleted channels

Channels stay hard-deleted, as they are today. A deleted category takes its channels with it, and a deleted channel takes its threads (the foreign keys cascade). The delete transaction:

1. locks the deleted set, one level at a time: it locks the channel row `FOR UPDATE`, then runs `select ... where parent_id = any(<locked ids>) order by id for update` until a level returns no rows. A level waits for any creation that still holds its parent, and the next statement then sees the new row, so no child escapes the set;
2. rewrites the payload of every event whose `channel_id` is in that set to the redaction envelope; the rows and their `seq` stay, so the log has no gap;
3. appends one `channel.deleted` (or `thread.deleted`) event for each id in the set.

Creating a child channel, a thread or a message locks its parent channel (or thread) row `FOR SHARE`, after the membership locks. A creation then either commits before the delete locks that row, and is in the set, or waits and fails with `{:error, :not_found}` after the delete. The full lock order is: membership rows, channel rows (parent before child, then by id), the message row, and the event head last.

The redacted rows of a deleted channel hold no content. Its id-only `channel.*` and `thread.*` events stay readable by every active member, under owner question 5. Owner question 5 covers who may see that a channel existed.

## Retention

- Window kinds are kept for a configured window (7 days, question 1). Permanent kinds are kept until the owner changes the policy.
- A daily job (task "Background jobs and durable file storage") deletes window-kind events older than the window. In the same transaction, it sets `pruned_through = greatest(pruned_through, <highest seq it deleted>)`. A run that deletes nothing leaves it unchanged, and the watermark never goes back, whatever order prune runs finish in. Retention is the only operation that deletes rows.
- A reader whose cursor is below `pruned_through` resyncs. This is conservative: it resyncs even when none of its own events were pruned.

## Restore

The migration creates the one `event_log_head` row. `Events.new_generation!/0` sets a new random `epoch` and sets `pruned_through = head`. The restore step of the deploy runbook calls it after it restores a backup, before the app starts. Every cursor from before the restore then names another epoch, and its reader resyncs. A numeric `head` check alone cannot detect a restore: after a restore, new writes can carry `head` past an old cursor before any reader looks.

## Audit log migration

Precondition for deploy: every old instance of the app is stopped before the migration runs. The cartridge runs one instance, and its migrate step runs before the new instance starts. The deploy checks that precondition; it does not assume it.

1. Create the new tables, with a new `epoch`.
2. Copy every `audit_log_entries` row into `events`, in order of (`inserted_at`, `id`). The migration maps each old `action_type` to a catalogue kind. It keeps `actor_user_id` as `actor_id`, `subject_user_id` as `subject_id` and `channel_id`. It keeps `message_id`, `reason`, `metadata`, `target_type` and `target_id` (a string) inside `data`, and `inserted_at` as `recorded_at`. Moderation and bot rows get their local-only kinds.
3. Set `head` to the last copied `seq` and `pruned_through` to 0, in the same transaction.
4. Drop `audit_log_entries`. The same release moves every writer to events.

`moderation_cases` stays: it has its own state (open, revoked, expired) and a case number people quote. Each case change also appends a `moderation.*` event.

## Testing

- `Rfchat.TestDatabase.truncate!/0` empties every table before the suite. It keeps the `event_log_head` row and calls `Events.new_generation!/0`, because emptying `events` is a restore to an empty log: the same path as production.
- The Ecto sandbox wraps each test in a transaction that never commits, and rolls back the head row after it. Readers are the test's own LiveViews and processes, which already share the test's sandbox connection, so no reader outlives its test. A test that writes events holds the head row lock until it ends, so such tests cannot run `async: true` together. Today only the two error-page tests are async. DataCase documents the rule.
- Commit order and rollback are proved by one integration test outside the sandbox. It uses its own connections and commits for real. It writes window-kind events, asserts order and density over the `seq` range it wrote, and then cleans up through the retention prune with a window of zero. That advances `pruned_through` past its rows, so the committed log stays consistent with the rule above. The shared test database lock already keeps other suites from running at the same time.

## Order of work

1. Tables, `Events.append/3`, `Events.run/1`, the catalogue, `Reader` and the integration test. Message create, update and delete move onto it, with redaction. Measure the page cost (read context plus page query) for 100 connected readers on a server with 200 channels and 20,000 threads.
2. Reactions, channels, threads, reorder, with the deleted-set redaction. Writes that run outside transactions move into Multis.
3. Moderation, members, roles, overwrites, emojis, settings, bots and Accounts. Migrate the audit log; the audit page reads events.
4. The bot stream: `id:` lines, `progress`, `Last-Event-ID`, `resync_required`. This is the task "Resumable bot event gateway".
5. GuildLive reads through `Reader`, with the snapshot cursor, the channel floors and one owner for its own writes. The tuple events (`{:message_created, ...}` and the rest) are deleted, with the per-channel PubSub topics.
6. Retention job, watermark and the restore runbook step.

Slice 1 of [scoped-reads.md](scoped-reads.md) (`Visibility` and the read context) comes before slice 1 here.

## Federation decisions this leaves open

- Canonical JSON encoding, the signed field set and the content hash.
- Remote identity in `actor_id` (a local UUID today).
- Which non-local events a peer receives. Proposed default: `local_only` events never leave.

## Questions for the owner

1. **Retention window** for message, reaction and per-user events. Decided by the owner (2026-11-08): 7 days. Longer lets clients resume after longer outages, and costs disk.
2. **Redaction on delete.** Proposed: yes. The other option keeps the body in old events until the window expires.
3. **History on gaining access.** Decided by the owner (2026-11-08): a member who gains a channel sees its full current history, as in Discord. The other option shows only messages sent after they gained it, and then the event reader must check access at each event's `seq`, which costs much more.
4. **Revocation delay.** Proposed: a ban, role change or token revocation reaches a connected reader within 20 seconds (sockets of a banned member are closed at once). Shorter means more polling queries.
5. **Deleted channels.** Proposed: members see only "a channel was deleted" (an id). Moderators see who deleted it and when.
