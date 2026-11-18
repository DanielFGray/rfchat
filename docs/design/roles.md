# Roles

How a member manages roles and gives roles to members, and why.

## Summary

- `Tavern.Chat.Roles` holds every role operation. Each takes a `%Scope{}` first and decides inside its own transaction: `list_roles/1`, `role_controls/1`, `member_roles/2`, `create_role/2`, `update_role/3`, `delete_role/2`, `move_role/3`, `add_member_role/3`, `remove_member_role/3`. `Tavern.Chat` delegates to it.
- `Tavern.Chat.RoleAuthority` holds the one rule for which roles an actor may change or give. People (through `Roles`) and bot management (through `Tavern.Bots.Authority`) both use it.
- `Tavern.Chat.ChannelOverwrites` holds the channel and category permission overwrites: `list_overwrites/2`, `overwrite_controls/2`, `put_overwrite/5`, `delete_overwrite/3`. The channel editor in Settings has a Permissions section (see "Channel overwrites").
- The Settings page has a Roles tab for members who hold `manage_roles`, and the member list has role controls.

Terms:

- **Top role**: the member's role with the highest position. A member with no roles has the default role's position, 0.
- **Default role**: `@everyone` (`is_default`). Every member has its permissions without a `member_roles` row.
- **Managed role**: a role with `managed` set. The system owns it.

## The rule

An actor has authority over a role when all four hold:

1. The actor holds `manage_roles`.
2. The role sits below the actor's top role.
3. The role grants no server bit the actor lacks, and does not grant `administrator`.
4. Each channel overwrite on the role allows no bit the actor lacks in that channel.

The server owner passes all four. An administrator holds every bit in every channel, so 1 and 4 pass; 2 still binds, and 3 still keeps `administrator` back. Only the owner sets or gives `administrator`.

Each operation applies the rule like this:

| Operation | Needs |
|---|---|
| Create | rule 1, and the new role (placed at position 1) passes 2 to 4 |
| Edit | the role as it stands and as it will be both pass. A role below the actor that holds a bit the actor lacks cannot be edited at all, so an edit never strips or adds a bit the actor does not hold |
| Move | the role passes, and the neighbour it swaps with sits below the actor's top role |
| Delete | the role passes |
| Give or take | the role passes, and the `:assign_roles` decision passes: the subject is the actor, or a member whose top role sits below the actor's; the owner may give or take any givable role from anyone, themselves included. The subject is an active member |

Fixed rules, for every actor including the owner:

- The default role is always lowest. It is never deleted, moved, given or taken. Only its permissions are editable, under the rule. Bootstrap marks it managed; the default-role rule wins over the managed rule.
- Any other managed role is never edited, moved, deleted, given or taken by a person.
- Only the owner gives a role to an owner. This follows Discord: giving roles is not moderation, so a manager may give themselves a role below their top role.
- A role below the actor's top role cannot restrict the actor, because the actor manages it. Deleting such a role, or taking it from oneself, also removes its channel denies. This follows Discord. A restriction that must hold against a manager goes on a role above them, or on a user overwrite, which they cannot remove: a user deny is applied last, so the manager does not hold the denied bit in that channel, and an overwrite write changes only bits the actor holds there.

Refusals: a hidden or missing role or member answers `{:error, :not_found}`; a visible one the actor may not change answers `{:error, :forbidden}`. Roles are visible to every active member, so a scope with no active member gets `:not_found` for any role.

Why rule 4: a role is part of what its holder may do, and a bot token acts with its bot's roles. Without rule 4 an actor could give a role whose overwrite opens a channel the actor cannot read. The security review found that bug in bot grants.

Why edit checks both states: the settings form disables the checkboxes for bits the actor cannot set, and a disabled checkbox submits nothing. A check on the new state alone would let a rename silently strip such a bit.

## Positions

Non-default roles hold positions `n..1`, highest first; the default role holds 0. Every create, move and delete renumbers the non-default roles in order. Positions therefore stay distinct, and "below" is always strict. A new role starts at position 1, just above the default role, so a manager's new role always lands below them. A move swaps two neighbours.

## Channel overwrites

An overwrite sets, for one role or one user, the bits allowed and the bits denied in one channel or category. `Visibility` applies them (scoped-reads.md, "Decisions: one module"). An actor may put or delete the overwrite for a target when all three hold (the `{:manage_permissions, target}` decision, then the bit rule in `ChannelOverwrites`):

1. The actor can view the channel and holds `manage_roles` in it, after overwrites. This follows Discord's "Manage Permissions", which is the same bit.
2. Every bit the write changes, in allow or in deny, is a bit the actor holds in that channel. A bit already stored that the actor does not hold stays as it is; a delete changes every stored bit.
3. The target is a role below the actor's top role (the default role always qualifies, even for an actor with no roles), or the actor, or a member whose top role is below the actor's. Only the owner targets an owner. The user rule is the one `:assign_roles` decides with (`ranks_over?`).

The owner passes all three. An administrator holds every bit in every channel, so 1 and 2 pass; 3 still binds. No overwrite holds `administrator`, unknown bits, or a bit both allowed and denied (`ChannelPermissionOverwrite.changeset/2`): administrator bypasses every overwrite, so a channel cannot grant or take it.

- A category overwrite applies to the category only; its children keep their own overwrites. A category's view deny still hides every child (scoped-reads.md).
- A thread takes no managed overwrite (`{:error, :thread}`).
- An overwrite with no bits is kept: it lists the target with every bit inherited.
- Refusals: a hidden or missing channel, a missing role, a put for a user who is not an active member, and a delete of an overwrite that does not exist answer `{:error, :not_found}`; anything else the actor may not change answers `{:error, :forbidden}`.

## Locks

A role write runs in one transaction at READ COMMITTED and takes its locks in this order:

1. One transaction-scoped advisory lock for the role list (`pg_advisory_xact_lock`). Two role writes never interleave: the second decides from the role list the first committed. Renumbering touches many rows, so a row-by-row lock would deadlock two moves.
2. The membership rows, through `Visibility.authorize_write/3`: the actor's row `FOR SHARE`; for give and take (`:assign_roles`), the actor's and the subject's rows `FOR UPDATE` in user id order, as moderation does.
3. The target role row, `FOR UPDATE`.

A moderation write (timeout, kick, ban) and a role assignment (giving or taking a member role) take the role-list lock in shared mode before their membership rows. Each reads the actor's and the subject's top roles in two statements, and a role write may renumber every position; the shared lock keeps any role write from committing between the two reads. Giving or taking a member role through `Roles` already holds the lock exclusive; Postgres lets the same transaction take it shared again.

Then the write loads the actor's authority (`Visibility.authority/2`) and decides. The protocol is in docs/design/scoped-reads.md, "Consistency".

Bot role grants (`Tavern.Bots.create_bot/2` and `update_bot/3`) follow the same order: the role-list lock (exclusive), the actor's membership row, then the actor's authority, and they decide and write `member_roles` in that one transaction.

An overwrite write changes what role writes (rule 4) and channel writes (who sees the channel) both decide from, so it takes both advisory locks: the role-list lock (exclusive), then the channel-tree lock, then the membership rows (the actor's `FOR SHARE`; for a user target the actor's and the subject's `FOR UPDATE`, in user id order), then the channel row, then the overwrite row. Every write that takes both advisory locks takes the role-list lock first.

A role change does not lock every member who holds the role. A write that loaded its permissions just before a role change committed may still commit after it (scoped-reads.md, question 4).

## Effects

- Default permissions: `Tavern.Bootstrap.ensure_default_role!/0` sets the default role's permissions only when it creates the role. `Release.migrate` runs it on every deploy, so it never writes them again: a deploy keeps edits to `@everyone`. A new default bit reaches existing servers through a data migration, as `20261118165602_grant_view_audit_log_to_moderators` does.
- Delete: the foreign keys from `member_roles`, `channel_permission_overwrites`, `emoji_roles` and `message_role_mentions` to `roles` are `ON DELETE CASCADE`, so those rows go with the role.
- Audit: each write that changes something inserts one `audit_log_entries` row with `target_type: "role"`, the role id, and for give and take the subject's user id. Action types: `role_created`, `role_updated`, `role_moved`, `role_deleted`, `member_role_added`, `member_role_removed`. A move at the edge, giving a held role or taking one not held changes nothing, and is neither audited nor broadcast.
- Overwrite audit: each overwrite write that changes something inserts one row with `target_type: "channel"`, the channel id in `target_id` and `channel_id`, the subject's user id for a user target, and `role_id`, `allow`, `deny`, `previous_allow`, `previous_deny` in `metadata`. Action types: `channel_overwrite_updated`, `channel_overwrite_deleted`. A put of the bits already stored is neither audited nor broadcast.
- Live updates: after the commit, each role write and each overwrite write broadcasts `:roles_changed` on the server topic. ServerLive reloads its channel tree, SettingsLive reloads its role and channel lists, and the bot stream re-syncs its channel subscriptions. The writing process is skipped, so the acting SettingsLive reloads itself.

## Known gaps

- A role write decides from several statements (the membership decision, the actor's authority, the role's overwrites, the bits in those channels). The role-list lock freezes roles, member roles and the overwrites that `ChannelOverwrites` writes. Two deletes still remove overwrite rows under one advisory lock only: deleting a channel cascades its overwrites under the channel-tree lock, and deleting a role cascades its overwrites under the role-list lock. Each removes rows only for the channel or role it deletes, so a concurrent write decides from one coherent earlier state (scoped-reads.md, question 4).
- The channel editor, and with it the Permissions section, opens only for a member with server `manage_channels`. A member with `manage_roles` alone cannot reach it, as in Discord, where channel settings need Manage Channels.
- SettingsLive refreshes its role controls on `:roles_changed`, but not its other permission flags (`can_manage_channels?` and the rest), which are read at mount.
- Bot role grants do not broadcast `:roles_changed`.
