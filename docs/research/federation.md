# Federation design options for rfchat

Research date: 2026-11-08. Task: research federation design options (`ts-520427`).

## Question

Each rfchat installation hosts one guild. The owner wants a user on server A to take part in a guild on server B. This file compares (a) Matrix, (b) ActivityPub with group extensions, (c) XMPP MUC and MIX, and (d) a custom host-authoritative protocol. In (d), the guild's home server orders all events and enforces permissions, and members on other servers join through their own home server, which relays for them.

Then it designs one guild event log for the bot gateway and federation, and ends with a recommendation and the owner's decisions. Each claim cites the document that owns it. Text marked "estimate" or "design" is my reasoning, not a sourced fact.

## Terms

- **Host server.** The installation that owns a guild.
- **Member server.** Another installation whose users are members of that guild.
- **Authority model.** Which server puts events in order, and which server decides if an event is permitted.
- **Backfill.** Fetching history that a server did not receive live.
- **Resume token.** A value a consumer sends after a disconnect, so the producer can send only what the consumer missed.
- **SSE.** Server-sent events, the HTTP streaming format rfchat's bot gateway uses.
- **Ed25519.** A public-key signature algorithm. **OTP** is the Erlang runtime library set. **Hex** is the Elixir package registry.

Matrix terms (S2S and CS are the Matrix server-server and client-server API documents):

- **PDU** (persistent data unit). One room event sent between servers and kept in room history. **EDU** (ephemeral data unit). A short-lived message, such as typing, with no ID and no place in history ([S2S §EDUs][s2s-edus]).
- **State event.** An event that sets one key in the room's current state, such as the room name.
- **Power level.** An integer per user per room. Each action needs a minimum level.
- **ACL** (access control list). A list of allowed and denied server names for a room.

ActivityPub terms:

- **Actor.** An object that can perform activities, such as a `Person` or a `Group`. **Inbox.** The URL where an actor receives activities.
- **FEP** (Fediverse Enhancement Proposal). A community extension document, not a W3C standard. Status is DRAFT or FINAL.

XMPP terms:

- **XEP** (XMPP Extension Protocol). An extension document from the XMPP Standards Foundation. Status is Experimental, Stable, Deferred, and so on.
- **JID** (Jabber ID). An address, `user@host`, or `user@host/resource` for one session ([XEP-0045 §4.1][x45-terms]).
- **MUC** (Multi-User Chat, XEP-0045). Group chat rooms hosted on one service. **MIX** (Mediated Information eXchange, XEP-0369). A newer design for the same job.
- **MAM** (Message Archive Management, XEP-0313). A query protocol for stored message history.
- **Affiliation.** A lasting rank in a room, such as owner, admin, member or outcast (banned).

## Summary grid

The grid gives short answers. The sections after it give the detail and the citations.

| Dimension | (a) Matrix | (b) ActivityPub groups | (c) XMPP MUC / MIX | (d) Host-authoritative |
|---|---|---|---|---|
| Who orders events | No single server. Each server orders a shared event graph | The `Group` actor's server | The service that hosts the room | The host server |
| Who enforces permissions | Every server | The group's server | The room's service | The host server |
| Fit for roles, bits and overwrites | Poor. One integer per user per room | Poor. Fixed affiliations (FEP-5219, DRAFT) | Poor. Fixed affiliations and roles | Full. The host runs rfchat's own rules |
| Event signing | Every event, by its origin server | Optional, DRAFT | Not in core MUC | User's server and host (design) |
| Elixir or Erlang libraries | No server-side library | Pleroma, Akkoma, Bonfire | ejabberd | OTP `:crypto` |
| Interop reach | Matrix clients and bridges | Forum servers such as Lemmy | XMPP clients | rfchat only |
| Size for one small team (estimate) | Very large in-process. Medium as an application service | Medium | Medium if you run ejabberd beside rfchat | Small to medium |

## Authority model

### (a) Matrix

A Matrix room is a directed acyclic graph (DAG) of events. Each event lists its parents in `prev_events`. This gives "a partial ordering on events within the room" ([S2S §PDUs][s2s-pdus]).

No server is the authority. Every server checks each PDU's signature, hashes and authorisation rules ([S2S §Checks performed on receipt of a PDU][s2s-checks]). When branches of the graph disagree about room state, every server runs the same state resolution algorithm to pick one answer ([v2 §State resolution][v2-sr]). Room version 12 is the default for new rooms ([Room versions][rooms]) and changes that algorithm ([v12 §State resolution][v12-sr]).

When a server goes offline, the room continues on the servers that remain. A malicious server can sign events for its own users only. It can also send events that cite old parts of the graph, for example to post after a ban. The spec cannot reject these, "as it is impossible to distinguish such an event from a legitimate one which has been delayed". Servers "soft fail" them instead: they keep the event but do not show it to clients ([S2S §Soft failure][s2s-soft]).

In room version 12, room creators "have infinitely high power level and cannot be specified in the `m.room.power_levels` event, nor can they be changed after the room is created" ([v12 §Client considerations][v12]). A guild owner transfer cannot remove the old owner from any channel's room.

### (b) ActivityPub groups

ActivityPub servers send activities by POST to an actor's inbox ([AP §7][ap-7]). `Group` is a core actor type ([AS Vocabulary §3.2, Group][as-group]). FEP-1b12 (FINAL) describes how forums work. The group receives an activity, validates it, and "MUST wrap it in an `Announce` activity". Followers "use the outer `Announce` activity to verify that the content was really approved by the group" ([FEP-1b12][1b12]).

This is already a host-authoritative model. FEP-5219 (DRAFT) says it directly: "The operators of the server where a group actor is hosted have super-admin privileges" ([FEP-5219 §Affiliation][5219]). If the group's server goes offline, nobody can post. Each object is hosted "on the server of the actor that created it" ([FEP-db0e §Summary][db0e]), so a member server keeps its own users' posts.

### (c) XMPP MUC and MIX

In MUC (XEP-0045, Stable 1.35.5), a room lives on one MUC service, and the service relays every message. MIX (XEP-0369, Experimental 0.14.6) also hosts each channel on one service. MIX keeps the user in the channel when the user's clients go offline, and stores history on both the channel and the user's own server ([XEP-0369 §4.1, §4.5][x369-muc]). Both are host-authoritative. If the host goes offline, the room is gone until it returns.

MUC handles network breaks badly. XEP-0410 (Stable 1.1.0) says MUC "was not designed to handle s2s interruptions or message loss well" ([XEP-0410 §1][x410]).

### (d) Host-authoritative (design)

The host server orders every guild event and checks every permission with the rules rfchat already has. A member server authenticates its own users, signs what they send, and forwards it to the host. The host checks permissions, gives the event the next sequence number, signs it, and sends it to the member servers that have a member who can view the channel.

A malicious host can drop, reorder or refuse events in its own guild, as a MUC service or FEP-1b12 group server can. If user events carry the member server's signature, other servers can detect a forged message, but not a dropped one. A malicious member server can act only as its own users, as in Matrix. If the host goes offline, the guild stops, and member servers keep their cached history.

## Roles, permission bits and overwrites

rfchat's model is a set of roles with permission bits, a role order, and per-channel allow and deny overwrites for roles and members (`lib/rfchat/chat/authorization.ex`, `lib/rfchat/chat/channel_permission_overwrite.ex`).

### Matrix power levels

Power levels live in the `m.room.power_levels` state event. Apart from membership and redactions, "the level required to send a certain event is governed purely by `events`, `state_default` and `events_default`" ([CS §m.room.power_levels][cs-pl]). A user cannot raise anyone above their own level. A change to another user's entry is rejected "If the current value is greater than or equal to the sender's current power level" ([v12 §Authorisation rules][v12-auth]).

What maps:

- Role order maps to integer order.
- Each permission bit can become a threshold for an event type or action (`kick`, `ban`, `redact`, or a custom state event).
- A per-channel overwrite becomes a different `m.room.power_levels` in that channel's room.
- A guild maps to a space. A space is a room with type `m.space` that lists child rooms ([CS §Spaces][cs-spaces]).

What is lost:

- **Roles.** The spec has no role object. Each room lists users and their levels. A role change rewrites the power levels event in every room the role touches.
- **Bits that do not nest.** All thresholds sit on one integer line. Take user A who can manage emojis but cannot kick, and user B who can kick but cannot manage emojis. A needs emoji ≤ a < kick. B needs kick ≤ b < emoji. Both cannot hold, so the model cannot express this pair.
- **Deny overwrites for a role.** An overwrite such as "the Muted role cannot send in #announcements" becomes per-user levels in that room, which rfchat must rewrite each time the role's members change.
- **View permission.** Viewing a channel is room membership. A `restricted` join rule can admit space members, but the conditions "are only checked/evaluated during the join process" ([CS §Restricted rooms][cs-restricted]). Removing `view_channel` means kicking the user from that room.
- **Owner transfer.** See room version 12 above.

### ActivityPub groups

FEP-5219 (DRAFT, June 2026) copies MUC. It has fixed affiliations (`admin`, `moderator`, `member`, `outcast`) and a privilege table ([FEP-5219 §Privileges][5219]). Custom affiliations need a fallback with "equal or fewer privileges". FEP-1b12 has only a moderator list. Neither has per-channel overwrites.

### XMPP

MUC has two fixed ladders. Affiliations (`owner`, `admin`, `member`, `outcast`) last across visits. Roles (`moderator`, `participant`, `visitor`) last only for one visit ([XEP-0045 §5.1, §5.2][x45-roles]). MIX-ADMIN (XEP-0406, Deferred) has owners, administrators, allowed and banned lists, and "Rights are defined in a strictly hierarchical manner" ([XEP-0406 §2.1][x406]). Permission bits and overwrites do not map. Each channel is a separate room with separate lists.

### Host-authoritative

Nothing is lost. The host runs rfchat's existing `Authorization` code on remote users, who get roles, overwrites and bans like local users. Member servers only show what the host sends.

## Identity, mentions and bans

- **Matrix.** Remote users are ordinary room members with power levels. Mentions use `m.mentions` with user IDs ([CS §User and room mentions][cs-mentions]). A ban is per room, so a guild-wide ban is one ban in each room.
- **ActivityPub.** Users are actor URIs. Mentions use the `Mention` link type ([AS Vocabulary, Mention][as-mention]). A group bans with `Block` ([FEP-5219 §Privileges][5219]).
- **XMPP.** A ban gives a JID the `outcast` affiliation. A room's ban list SHOULD also match a bare domain, which bans every user of that server from that room. Banning a domain from all rooms on a service "is a service-level feature and is therefore out of scope for this document" ([XEP-0045 §9.2][x45-ban]).
- **Host-authoritative (design).** The ID is `localpart@server`. The host stores a remote user as a `users` row with a UUID, like a local user. Mentions carry both. Bans apply to a user or to a whole server.

## Signing, verification and server authentication

- **Matrix.** Each request is signed with the server's Ed25519 key in an `X-Matrix` header. Responses rely on the TLS certificate. A server treats a key as valid until its `valid_until_ts` or "7 days into the future", whichever is sooner ([S2S §Authentication][s2s-auth], [S2S §Retrieving server keys][s2s-keys]). Each event carries a SHA-256 content hash and a signature over the redacted event ([S2S §Signing Events][s2s-sign]). Signing needs Matrix's canonical JSON: keys sorted "by Unicode codepoint", integers only ([Appendices §Canonical JSON][canon]).
- **ActivityPub.** The spec says "there are no strongly agreed upon mechanisms for authentication" ([AP §B.1][ap-b1]). Mastodon signs with the draft-cavage HTTP Signatures. Since 4.5.0 it also accepts incoming RFC 9421 HTTP Message Signatures by default. Both use RSASSA-PKCS1-v1_5 with SHA-256 only ([Mastodon security spec][masto-sec], [RFC 9421][rfc9421]). FEP-8b32 (DRAFT) adds signatures inside objects so a forwarded object can be checked ([FEP-8b32][8b32]).
- **XMPP.** Trust is hop by hop. RFC 6120 notes that "most deployed servers still use the Server Dialback protocol" for "weak identity verification" ([RFC 6120 §1.3][rfc6120]). Dialback is "subject to DNS poisoning attacks" ([XEP-0220, Stable 1.1.1][x220]). Stanza signature XEPs exist (XEP-0274, XEP-0285, XEP-0290 Deferred; XEP-0475 Pubsub Signing Experimental), per the [XEP index][xep-index].
- **Host-authoritative (design).** Copy the Matrix pattern of Ed25519 server keys at a well-known URL, signed requests, and signed events. OTP `:crypto` supports Ed25519 ([Erlang crypto docs][otp-crypto]). Matrix canonical JSON is not RFC 8785, which sorts keys by UTF-16 code units ([RFC 8785 §3.2.3][rfc8785]). The Hex package `rfc8785` 1.0.0 implements RFC 8785.

## History backfill and resume

- **Matrix.** A server that joins late fetches older events with `/backfill` from another server in the room, and fills holes with `/get_missing_events` ([S2S §Backfilling][s2s-backfill]). Servers push live events in transactions of at most 50 PDUs and 100 EDUs. A transaction "is meaningful only to the pair of homeservers that exchanged it" ([S2S §Transactions][s2s-txn]).
- **ActivityPub.** An outbox is an `OrderedCollection` "presented consistently in reverse chronological order" ([AP §5][ap-5]). There is no resume token. FEP-f228 (DRAFT) proposes `context` collections for backfill ([FEP-f228][f228]).
- **XMPP.** MUC sends a service-chosen amount of history on join, stamped with a delay ([XEP-0045 §7.2.13][x45-hist]). With MAM (XEP-0313, Stable 1.1.3), the room exposes an archive at its bare JID and tags each message with a `stanza-id`, so a client can page from the last ID it saw ([XEP-0313 §3.3.2, §3.5][x313-muc]). MIX uses MAM for "quick resync" ([XEP-0369 §4.3][x369-core]). XEP-0198 (Stable 1.6.3) resumes a broken stream ([XEP-0198 §5][x198]).
- **Host-authoritative (design).** The host is the archive. A member server pulls `GET /events?after=<seq>`. See the event log section.

## Moderation across servers

- **Matrix.** `m.room.server_acl` lists allowed and denied server names. Every server in the room must enforce it, and servers that do not "MUST be manually appended to the denied hosts list" ([CS §Server ACLs][cs-acl], [S2S §Server ACLs][s2s-acl]). Policy lists carry `m.ban` rules for users, servers and rooms, and "enforcement of this is deliberately left as an implementation detail" ([CS §Moderation policy lists][cs-policy]). Since v1.18 a room can name a Policy Server that must sign each event, or other servers soft fail it ([S2S §Policy Servers][s2s-ps]).
- **ActivityPub.** The group SHOULD validate incoming activities, "such as checking for domain and user blocks" ([FEP-1b12][1b12]). The spec offers no spam mechanism and recommends filters ([AP §B.6][ap-b6]).
- **XMPP.** Room bans are covered above. Moderated message retraction is XEP-0425, Experimental 0.3.1 ([XEP-0425][x425]).
- **Host-authoritative (design).** The host checks bans, timeouts and rate limits before it numbers an event. A banned server's requests are refused at ingress. Abuse reports from remote users go to the host's existing report queue (`lib/rfchat/chat/message_report.ex`).

## Media

- **Matrix.** Content has an `mxc://<server-name>/<media-id>` URI. The user's own server downloads it from the origin and serves it to the client ([CS §Content repository][cs-media]). Since v1.11, both the federation and client download endpoints require authentication ([S2S §Content Repository][s2s-media]).
- **ActivityPub.** Uploading media is "out of scope for this version" ([AP §6.12][ap-612]). Objects link to URLs on the author's server.
- **XMPP.** XEP-0363 (Stable 1.2.0) gives the uploader an HTTP slot. It recommends "long randomized parts in their URLs", so access control is an unguessable URL ([XEP-0363 §9][x363-sec]).
- **Host-authoritative.** Owner decision. Either the host copies each attachment into its own store, or member servers fetch from the uploader's server with signed requests, as Matrix does.

## Implementation size and hard parts (estimates)

No source states sizes. These estimates assume one or two people working part time.

- **(a) Matrix, inside rfchat.** The v1.19 S2S page has about 35 endpoints. The hard parts are the authorisation rules, state resolution, soft failure, keys and canonical JSON. Matrix clients would also need the client-server API. Estimate: more than a year. A bug in state resolution splits a room between servers.
- **(a') Matrix through an application service.** Run an existing homeserver and connect rfchat as an application service. An application service is a process that a homeserver pushes events to, and that can act as users in its namespace. Estimate: weeks to two months. But application services "cannot prevent events from being sent, nor can they modify the content" ([AS API §Application Services][as-api]). rfchat could not enforce its permissions on Matrix users. This is a bridge, not federation of rfchat guilds.
- **(b) ActivityPub groups.** Actors, inboxes, HTTP signatures in two formats, `Announce` wrapping, and FEP-5219 affiliations. Estimate: two to four months. No other server renders these forum objects as chat.
- **(c) XMPP.** Run ejabberd beside rfchat and bridge rooms to it. Estimate: two to four months. The hard parts are MUC presence rules and MAM. Permissions do not map, so XMPP users see a reduced room.
- **(d) Host-authoritative.** Signed requests, key publishing, a relay endpoint, the event log, remote user rows and media fetching. Estimate: one to three months. The hard parts are sequence commit order, retries, and remote media.

## Elixir and Erlang libraries

Figures are from the Hex API (`https://hex.pm/api/packages?search=...`) and repository APIs on 2026-11-08.

- **Matrix.** matrix.org lists one Elixir homeserver, Matrex, as "Obsolete" and "A WIP toy" ([Matrix servers][m-servers]). The client libraries `polyjuice_client` 0.4.4 (2021), `polyjuice_util` 0.2.2 (2021, [GitLab][polyjuice]) and `matrix_sdk` 0.2.0 (2020) do not implement federation.
- **ActivityPub.** Pleroma ([git.pleroma.social/pleroma/pleroma][pleroma]) and Akkoma ([akkoma.dev][akkoma], updated 2026-11-03) are full Elixir servers. Pleroma publishes `http_signatures` 0.1.3 (2026-05-11). Bonfire's `activity_pub` library is AGPL-3.0 and active ([GitHub][bonfire]).
- **XMPP.** ejabberd 26.9.0 is on Hex (2026-10-05). It is GPL-2.0 ([COPYING][ejabberd-lic]), and its `mod_mix` declares XEP-0369 0.14.1 as "complete" ([source][ejabberd-mix]). MongooseIM is also GPL-2.0 ([COPYING][mongoose-lic]). The `xmpp` parser 1.13.5 is Apache-2.0.
- **Host-authoritative.** OTP `:crypto` (Ed25519), `rfc8785` 1.0.0, and Req, which rfchat already uses for HTTP.

rfchat has no `licenses` entry in `mix.exs` and no LICENSE file, so GPL and AGPL compatibility is an open question.

## Interop reach

- **Matrix.** matrix.org lists 48 clients ([Matrix clients][m-clients]). Bridges to other networks run as application services ([AS API][as-api]).
- **ActivityPub.** FEP-1b12 groups federate between Lemmy, Friendica, Hubzilla, Lotide and PeerTube. Moderation "is only implemented by Lemmy" ([FEP-1b12 §Implementations][1b12]). Mastodon's ActivityPub spec does not mention `Group` actors ([Mastodon ActivityPub spec][masto-ap]). FEP-1970 (DRAFT) only links to a chat room elsewhere ([FEP-1970][1970]). I found no FEP for real-time channel chat.
- **XMPP.** xmpp.org lists clients and servers ([XMPP software][x-soft]). I did not check per-client MUC or MIX support. MIX is Experimental, and its admin XEP is Deferred.
- **Host-authoritative.** rfchat servers only. A bridge can come later.

## One numbered, signed guild event log

This section is design. It serves the resumable bot gateway task (`ts-6fa2ae`) and federation with one table.

### Shape

One append-only table, `guild_events`:

| Column | Meaning |
|---|---|
| `seq` | Strictly increasing integer, the order the host gives |
| `id` | UUID of the event |
| `kind` | `message.created`, `role.updated`, `member.banned`, and so on |
| `channel_id` | Channel or thread, or null for guild-wide events |
| `actor_id` | User who caused it, local or remote |
| `origin_server` | Server that signed the user's submission |
| `payload` | Canonical JSON body |
| `content_hash` | SHA-256 of the full payload |
| `origin_sig` | Member server signature over the redacted event, null for local users |
| `host_sig` | Host signature over `seq` and the redacted event |
| `scope` | `federated` or `local` |

### Sequence numbers

A Postgres sequence can commit out of order. Transaction 1 takes seq 10, transaction 2 takes seq 11, and transaction 2 commits first. A consumer that reads 11 and later resumes "after 11" never sees 10. Assign `seq` under a row lock on a single log head row, inside the same transaction as the domain write. With one guild per installation this is one lock, and a small server will not reach its limit.

### What goes in the log

- **Federated.** Messages and their edits, deletes and reactions. Channel, thread, role and overwrite changes. Member join, leave, update, timeout and ban. Guild settings. Emoji changes.
- **Local only.** Bot token changes, sessions, read states, notification settings, audit details that name local staff. These get a `seq` so local bots can resume, but they never leave the host.
- **Not logged.** Typing and presence. These are like Matrix EDUs: they are sent live and dropped on a disconnect.

### Deletes and redaction

A deleted message must not come back in a replay, and the signatures must still verify. Use the Matrix method ([S2S §Signing Events][s2s-sign]). Each signature covers the redacted event: the event with its content removed, plus `content_hash`. A `message.deleted` event makes the host blank the `payload` of the earlier rows for that message. The signatures still check, and a replay sends the blank form. Member servers must apply each redaction they receive to their own copies.

### Filtering and gaps

Each consumer sees a filtered view. A bot sees the channels it can view and the kinds it asked for (intents). A member server sees federated events for channels where at least one of its users can view. So a consumer sees gaps in `seq`, and gaps are normal. The resume protocol must not read a gap as lost data.

### Resume

- **Bots.** The SSE `id:` field is `seq`. On reconnect, the browser or bot sends `Last-Event-ID` ([WHATWG HTML §9.2.4][sse]). The server replays filtered events after that number. The order matters. The stream subscribes to live Phoenix PubSub first, then replays from the database, then drops live events with a `seq` at or below the last replayed one. Any other order can lose or repeat events. The replay filters by the bot's permissions now, not when the event happened, so a bot that lost `view_channel` gets no backlog from that channel.
- **Member servers.** The host keeps one outbound cursor per destination: the last `seq` that destination confirmed. It pushes batches with a transaction ID made from the destination and the batch range. A retry resends the same batch, so the receiver can ignore a duplicate. A member server can also pull `GET /events?after=<seq>`.
- **Too old.** The log keeps a bounded window. If a resume token is older than the window, the server answers with a `resync` that points to a state snapshot. This is the same idea as a Matrix `limited` timeline with a state delta ([CS §Syncing][cs-sync]).

### Comparison with Matrix

Matrix `/sync` returns a `next_batch` token, and the client long-polls with it. Its order is "the arrival time of the event on the homeserver", which "can conflict with other APIs which order events based on their partial ordering in the event graph", so clients must remove duplicates by event ID ([CS §Syncing][cs-sync]). Federation transactions are separate, pairwise and retried with the same `txnId` ([S2S §Transactions][s2s-txn]). Neither stream has one global order, because no server owns the order of the graph.

In design (d) the host owns the order. One `seq` is the order, the bot resume token and the federation cursor. Member servers store the host's `seq` with their copy, so their bots resume on the same numbers.

### Integrity

With both signatures, a server can check that the user's server sent this content and that the host put it at this position. Because of filtering, it cannot check that the host sent everything. A hash chain per channel would detect drops for servers that see the whole channel. That can come later.

## Recommendation

Build option (d), the host-authoritative protocol, as rfchat-to-rfchat federation on one numbered, signed guild event log that the bot gateway also uses.

The reasons:

1. It keeps rfchat's permission model whole. Matrix power levels cannot express bits that do not nest, and MUC and FEP-5219 have fixed ladders.
2. Its authority model is the one MUC and FEP-1b12 groups already use, so it is a known design, not a new one.
3. It is the smallest option that gives real federation. One event log serves bot resume and federation.

Borrow proven Matrix parts: Ed25519 server keys, signed requests, signed and redactable events, per-destination retried transactions, server deny lists, and authenticated remote media. If other networks matter later, a Matrix application service or an XMPP bridge can show a reduced view of a guild.

The cost is that the guild depends on its host. If the host dies, the guild stops, and only an export can save it.

## Decisions for the owner

1. **Interop or rfchat only.** Do we accept that version one talks only to other rfchat servers?
2. **Host failure.** When a host dies, is the guild gone, or do we build export and migration to a new host?
3. **Remote moderators.** Can remote users hold roles with moderation or admin bits?
4. **Remote media.** Does the host copy attachments into its own store, or do member servers fetch from the uploader's server?
5. **Replay window.** How long does the log keep events for resume: hours, days, or all history?
6. **End-to-end encryption.** Out of scope? Matrix has it. rfchat and option (d) do not.
7. **Licenses.** rfchat declares no license. Is a GPL-2.0 (ejabberd) or AGPL-3.0 (Bonfire) dependency acceptable for a future bridge?
8. **Canonical JSON.** RFC 8785, or Matrix canonical JSON so that Matrix tools can check signatures?

## Sources

[s2s-pdus]: https://spec.matrix.org/v1.19/server-server-api/#pdus
[s2s-edus]: https://spec.matrix.org/v1.19/server-server-api/#edus
[s2s-checks]: https://spec.matrix.org/v1.19/server-server-api/#checks-performed-on-receipt-of-a-pdu
[s2s-soft]: https://spec.matrix.org/v1.19/server-server-api/#soft-failure
[s2s-auth]: https://spec.matrix.org/v1.19/server-server-api/#authentication
[s2s-keys]: https://spec.matrix.org/v1.19/server-server-api/#retrieving-server-keys
[s2s-txn]: https://spec.matrix.org/v1.19/server-server-api/#transactions
[s2s-backfill]: https://spec.matrix.org/v1.19/server-server-api/#backfilling-and-retrieving-missing-events
[s2s-media]: https://spec.matrix.org/v1.19/server-server-api/#content-repository
[s2s-acl]: https://spec.matrix.org/v1.19/server-server-api/#server-access-control-lists-acls
[s2s-ps]: https://spec.matrix.org/v1.19/server-server-api/#policy-servers
[s2s-sign]: https://spec.matrix.org/v1.19/server-server-api/#signing-events
[cs-sync]: https://spec.matrix.org/v1.19/client-server-api/#syncing
[cs-pl]: https://spec.matrix.org/v1.19/client-server-api/#mroompower_levels
[cs-spaces]: https://spec.matrix.org/v1.19/client-server-api/#spaces
[cs-restricted]: https://spec.matrix.org/v1.19/client-server-api/#restricted-rooms
[cs-acl]: https://spec.matrix.org/v1.19/client-server-api/#server-access-control-lists-acls-for-rooms
[cs-policy]: https://spec.matrix.org/v1.19/client-server-api/#moderation-policy-lists
[cs-media]: https://spec.matrix.org/v1.19/client-server-api/#content-repository
[cs-mentions]: https://spec.matrix.org/v1.19/client-server-api/#user-and-room-mentions
[as-api]: https://spec.matrix.org/v1.19/application-service-api/#application-services
[rooms]: https://spec.matrix.org/v1.19/rooms/
[v2-sr]: https://spec.matrix.org/v1.19/rooms/v2/#state-resolution
[v12-auth]: https://spec.matrix.org/v1.19/rooms/v12/#authorisation-rules
[v12]: https://spec.matrix.org/v1.19/rooms/v12/#client-considerations
[v12-sr]: https://spec.matrix.org/v1.19/rooms/v12/#state-resolution
[canon]: https://spec.matrix.org/v1.19/appendices/#canonical-json
[m-servers]: https://matrix.org/ecosystem/servers/
[m-clients]: https://matrix.org/ecosystem/clients/
[ap-5]: https://www.w3.org/TR/activitypub/#collections
[ap-612]: https://www.w3.org/TR/activitypub/#uploading-media
[ap-7]: https://www.w3.org/TR/activitypub/#server-to-server-interactions
[ap-b1]: https://www.w3.org/TR/activitypub/#authorization
[ap-b6]: https://www.w3.org/TR/activitypub/#security-spam
[as-group]: https://www.w3.org/TR/activitystreams-vocabulary/#dfn-group
[as-mention]: https://www.w3.org/TR/activitystreams-vocabulary/#dfn-mention
[1b12]: https://codeberg.org/fediverse/fep/src/branch/main/fep/1b12/fep-1b12.md
[5219]: https://codeberg.org/fediverse/fep/src/branch/main/fep/5219/fep-5219.md
[8b32]: https://codeberg.org/fediverse/fep/src/branch/main/fep/8b32/fep-8b32.md
[f228]: https://codeberg.org/fediverse/fep/src/branch/main/fep/f228/fep-f228.md
[db0e]: https://codeberg.org/fediverse/fep/src/branch/main/fep/db0e/fep-db0e.md
[1970]: https://codeberg.org/fediverse/fep/src/branch/main/fep/1970/fep-1970.md
[masto-sec]: https://docs.joinmastodon.org/spec/security/
[masto-ap]: https://docs.joinmastodon.org/spec/activitypub/
[rfc9421]: https://www.rfc-editor.org/rfc/rfc9421
[rfc8785]: https://www.rfc-editor.org/rfc/rfc8785#section-3.2.3
[rfc6120]: https://www.rfc-editor.org/rfc/rfc6120
[x45-terms]: https://xmpp.org/extensions/xep-0045.html#terms-general
[x45-roles]: https://xmpp.org/extensions/xep-0045.html#roles
[x45-hist]: https://xmpp.org/extensions/xep-0045.html#enter-history
[x45-ban]: https://xmpp.org/extensions/xep-0045.html#modifyban
[x369-muc]: https://xmpp.org/extensions/xep-0369.html#concepts-muc-comparison
[x369-core]: https://xmpp.org/extensions/xep-0369.html#concepts-core
[x406]: https://xmpp.org/extensions/xep-0406.html#roles
[x410]: https://xmpp.org/extensions/xep-0410.html#intro
[x313-muc]: https://xmpp.org/extensions/xep-0313.html#archives_muc
[x198]: https://xmpp.org/extensions/xep-0198.html#resumption
[x220]: https://xmpp.org/extensions/xep-0220.html
[x363-sec]: https://xmpp.org/extensions/xep-0363.html#security
[x425]: https://xmpp.org/extensions/xep-0425.html
[xep-index]: https://xmpp.org/extensions/
[x-soft]: https://xmpp.org/software/
[sse]: https://html.spec.whatwg.org/multipage/server-sent-events.html#the-last-event-id-header
[otp-crypto]: https://www.erlang.org/doc/apps/crypto/crypto.html
[polyjuice]: https://gitlab.com/polyjuice/polyjuice_util
[pleroma]: https://git.pleroma.social/pleroma/pleroma
[akkoma]: https://akkoma.dev/AkkomaGang/akkoma
[bonfire]: https://github.com/bonfire-networks/activity_pub
[ejabberd-lic]: https://github.com/processone/ejabberd/blob/master/COPYING
[ejabberd-mix]: https://github.com/processone/ejabberd/blob/master/src/mod_mix.erl
[mongoose-lic]: https://github.com/esl/MongooseIM/blob/master/COPYING

Reference definitions above render as links in the text. Each Matrix link pins spec v1.19. XEP statuses and versions are as listed on each XEP page on 2026-11-08: XEP-0045 Stable 1.35.5, XEP-0198 Stable 1.6.3, XEP-0220 Stable 1.1.1, XEP-0313 Stable 1.1.3, XEP-0363 Stable 1.2.0, XEP-0369 Experimental 0.14.6, XEP-0405 Experimental 0.5.3, XEP-0406 Deferred 0.3.1, XEP-0410 Stable 1.1.0, XEP-0425 Experimental 0.3.1. FEP statuses are from the FEP index README: 1b12 FINAL, 1970, 5219, 8b32, db0e and f228 DRAFT.
