# dot-moderation

Moderation that survives a reconnect.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first. This file
is only what is specific to moderation.

**Only dot-core is a dependency.** dot-voice and dot-server are both optional and neither
is named anywhere in the source.

## Why this exists next to dot-server, which already bans

dot-server has bans, kicks, admin flags with immunity and an audit log, and none of that
changes. What it does not have is a **mute that outlives a session**:

```gdscript
# dot-server/addons/dot_server/server/dot_client_session.gd
var muted: bool = false      # voice
var gagged: bool = false     # text
var mute_expires_at: int = 0
```

A `DotClientSession` is destroyed when its player disconnects, so a muted player
reconnects and can talk. That is the first thing anybody who has been muted tries, and it
is the most common complaint on any community server.

**Bans persisting and mutes not is not a design.** It is an accident of where the state
happened to live. Here a mute is the same kind of record a ban is: stored, expiring,
scoped, revocable, and on the player's history.

There is a **deliberate overlap**: this does bans too, for a project not using dot-server.
A deployment should pick one list rather than run both, and the README says so.

## A punishment is a record, not a flag

`BAN`, `KICK`, `VOICE_MUTE`, `GAG` and `WARN` are one record with a different kind,
because a server asks the same four questions about each: is it in force, who did it,
why, and when does it end.

- **A kick and a warning are never active.** They happened; they are not still happening.
  A kick that read as active would keep a player out for ever.
- **`expires_at == 0` means permanent.** The alternative reading, "expired at the epoch",
  is exactly the bug that lets everybody back in.
- **A revoke keeps the record.** The history is the point.
- **The player message never names the moderator.** That is how a moderator gets
  harassed, and it is not information a player needs in order to appeal.

## The subject is never a peer id

A peer id is reused within minutes and means nothing after a disconnect, so a punishment
keyed on one is a punishment against whoever connects next.

`DotModerationManager.key_for_peer` is where a deployment's identity model plugs in:
dot-user's pseudonymous id, an account uid, a device id for a guest. **Left unset the
mapping is `str(peer)`, which is correct for a single-process test and wrong on a real
server in a way that enforces nothing and reports nothing.** It warns once on the first
lookup and again in `describe_lines()`, because that is where an operator looks.

## An address is a subject too, and how it is spelled is the whole trick

`DotPunishmentSubject` is one small file for one reason: a subject is opaque and that is
correct, but opaque and "however each caller wrote it" are not the same thing. A ban
filed against `1.2.3.4` and a check for the `1.2.3.4:51234` a transport actually reports
are two strings that never meet, and nothing errors — the ban is in the file, the player
walks in, and the moderator is told the system works. `for_address` strips the port, the
scheme and the brackets; `for_uid` adds the prefix if it is not already there; a subject
with no prefix at all is still legal, because a deployment that has always written bare
ids keeps working.

`ban_address` and `ban_uid` are the two entry points, and they exist as a pair on
purpose. An account ban is exact and only works on somebody who has an account — a guest
comes back as a different guest, which is most of the people a server has to remove. An
address ban catches a household and everybody behind one NAT and is defeated by a router
reboot. Neither is sufficient alone; dot-server's `DotBanManager` reached the same
conclusion first.

Loopback is refused, as is an address the transport could not report. Both are a mistyped
argument far more often than a decision, and one locks the operator out of their own
listen server while the other bans everybody at once.

## `dot_ban_source`, or the ban that stops nobody

**Nothing in this addon can refuse a connection.** There is no session list here and no
socket — that is a deliberate boundary, listed under "Things deliberately not here" since
the addon was written. Which means a `BAN` recorded with nothing asking about it is a row
in a file, and the moderator who issued it has no way to tell the difference.

So the manager registers under `dot_ban_source` (`register_ban_source`, on by default)
and answers:

```gdscript
check_admission(uid: String, address: String) -> DotResult
```

dot-server calls it twice per join: on the address before the client has said who it is,
and on both once it has. **This is the same shape as `dot_mute_source`** and it is the
shape every expensive bug in this family has started from, so it is tested the same way —
`examples/dedicated_server.gd` in dot-server loads this addon by path, registers it, and
asserts a real `DotServer` refuses a real connection.

Two details worth keeping:

- **Both spellings of a person are checked.** `check_admission("backbone:evil", …)` and
  `check_admission("uid:backbone:evil", …)` both refuse, because this addon cannot know
  which convention a deployment writes — `key_for_peer` returns whatever the host uses —
  and checking one spelling enforces nothing for the other, silently.
- **`describe_lines()` warns when bans are in force and nothing is registered.** The
  addon's most likely misconfiguration is the one where every part is correct and nobody
  is asking.

## Expiry is answered on read, never swept

A punishment that has expired but not yet been noticed is indistinguishable from one still
in force, and the read path is the only place it matters. A sweep additionally means a
server that was off overnight comes up enforcing yesterday's mutes until its timer fires.

Same choice `DotClientSession.is_silenced()` and `DotBanManager` already make.

## The store is what makes it a community's list rather than a machine's

`DotPunishmentStoreFile` is right for one server and wrong the moment there are two: a
player muted on the surf server walks into the deathmatch server unmuted, which is "he
just reconnects" one level up. Subclass `DotPunishmentStore` and point at a database or an
HTTP service.

Three rules the default obeys and a subclass must too:

- **A failed load keeps whatever is already in force.** Returning an empty list on an
  error readmits everybody who was ever removed, silently.
- **Writes are awaited before the in-memory set changes**, so a store that refuses does
  not leave a punishment that exists on one server and nowhere else. A failed revoke is
  rolled back for the same reason.
- **`is_writable() == false` is legitimate.** A server enforcing a centrally managed list
  says so rather than appearing to work and losing the record on the next refresh.

**One bad entry does not condemn the file.** Nine hundred good records and one typo should
moderate with the nine hundred and say which one was dropped. Same as dot-map's catalogue.

## Storage: what is real, and what Godot cannot do

The table is defined once in `DotPunishmentSchema` and emitted per dialect. Fourteen
columns, the same everywhere, so a JSON file, a SQLite file, a Postgres cluster and a
MySQL instance never disagree about what a punishment is. A schema written once per
backend disagrees with itself within a month, and you find out when a ban reads back with
no expiry.

Three dialect differences, each of which is fatal if you get it wrong:

- **MySQL cannot index a `TEXT` column** without a prefix length, and `subject` is
  indexed, so anything indexed is `VARCHAR`.
- **Booleans.** SQLite and MySQL have none worth the name, so `revoked` is a small integer
  everywhere and the row mapper converts. A `BOOLEAN` in Postgres and an `INTEGER` in
  SQLite would need two mappers.
- **Placeholders.** Postgres numbers them (`$1`), the other two do not (`?`). That is the
  only reason a statement builder has to know the dialect.

**Time is Unix seconds in a `BIGINT`, never a timestamp type.** A timestamp carries a
zone, or does not and pretends to, and the two servers reading this table are in different
places.

### What cannot be done here, said plainly

There is no `SQLite`, `PostgreSQLClient` or `MySQL` class in Godot. Verified, not assumed:

```
SQLite               false
PostgreSQLClient     false
MySQL                false
```

Neither the Postgres nor the MySQL protocol can be spoken from GDScript without
implementing an authentication handshake (SCRAM-SHA-256, `caching_sha2_password`), a
binary wire format and a connection pool. That is a project, and a half-finished one is a
security problem rather than a missing feature.

So the split is the same one dot-voice makes for microphones: **everything that can be
done in GDScript is done and tested here**, and the one step that needs a native library
goes through `DotSqlDriver`. `DotSqlDriverRecording` is what makes the store testable —
it captures statements and answers with rows a test supplies, which covers generation,
binding and mapping. Execution is the untested device layer, and the suite says so.

`DotSqlDriverGateway` exists because putting the database behind HTTP is what most
deployments should do anyway: a game server holding a Postgres password is a game server
whose compromise is a compromise of the database.

**Statements are always parameterised.** A ban reason is typed by a moderator and quotes
the offender's name half the time. The suite asserts that a reason containing a quote
never appears in the statement text.

## The REST store, and the two bugs a real server caught

`DotPunishmentStoreRest` is what a community with an existing ban system uses, and it is
tested against a hundred-line HTTP server in `examples/punishment_api_server.gd` rather
than against a mock. Two bugs came out of that, and neither could have:

- **`DotHttp.get_json` returns the parsed body, not a wrapper around it.** The store
  reached for `.value["json"]`, got null on every successful read, and reported "the API
  did not return an object" — a failure blaming the far end for something on this side. A
  mock returning whatever was assumed would have passed.
- **`document.get("punishments", [])` accepted any JSON object at all.** A different
  shape, a paginated envelope, an error body that happened to be 200: all fell through
  the default to an empty list and were reported as a successful read of nothing. Which
  means nobody is banned. **The single worst failure this addon has, one default argument
  away.** The key must be present, and the suite serves `{"data": []}` to prove it.

## Mod tools

`DotModTools` is the live half: teleport, bring, goto, send, return.

**`return_player` is what makes the rest usable.** Without an undo, "bring" is something a
moderator hesitates to do mid-round, and a moderator who hesitates does not moderate. The
position is saved **before** the move; saving after would record the destination, so a
return would put them where they already are, which looks exactly like the return being
broken.

Other decisions worth not undoing:

- **`goto` stops short.** Two bodies in the same place is a stuck player at best and a
  physics explosion at worst, and it happens every time without a stand-off. When the two
  are already in the same spot there is no direction to normalise, so a fallback is used
  rather than producing a NaN position.
- **Anybody may `goto` anybody.** Immunity blocks moving a player, not observing one: a
  moderator who cannot watch a senior admin cannot do their job.
- **Positions are `Variant`.** A 2D game is a first-class user; naming `Vector3` in a
  signature would make it something to work around. Same reason dot-timer serves a 3D surf
  map and a 2D course.
- **The return history is capped.** A position per player per action, held for ever
  against ids that are never reused, is a slow leak on a long-running server.
- **Every action is recorded as a `WARN`**, which enforces nothing. A teleport is not a
  punishment and must not read as one, but "an admin moved me" needs an answer.

It knows nothing about the world: `position_fn` and `teleport_fn` are the host's, and
without both every action refuses. `describe_lines()` says so, because refusing everything
is indistinguishable from nobody using it.

## Immunity, in both directions

Immunity is about who may be **acted on**, not only who may act, and the second half is
the one that usually gets left out: without it a junior can quietly reverse every decision
above them.

**Equal cannot act on equal** by default. Two moderators at the same level muting each
other in a loop has no correct resolution, so it is forbidden rather than raced.
The rule every admin system converges on.

**Zero means no immunity, not the highest rank.** Requiring strictly greater immunity
unconditionally meant a punishment issued at the default of 0 could never be lifted by a
caller at the default of 0, which is every ordinary `unmute` on a server that has not
configured immunity at all. The suite caught it.

## Bugs the suite found, all parse-clean

- **A stored voice mute loaded back as a warning.** `to_dictionary` wrote
  `kind_name(VOICE_MUTE)`, which is the string a *player* reads: `"voice muted"`, with a
  space. `kind_from_name` had no case for it and fell through to `WARN`, which enforces
  nothing. So the one thing this addon exists for, persisting a mute across a reconnect,
  was the thing that did not work, and nothing errored. `kind_token()` is now the storage
  key and `kind_name()` is for humans. **The two ends of a serialisation are exactly as
  capable of never meeting as the two ends of a wire.**
- **A punishment at the default immunity could never be lifted.** See above.
- **A server with no scope saw no scoped punishments.** `applies_to` required the scopes to
  match or the punishment to be unscoped, so the unconfigured case — one server, which
  never sets a scope — was invisible to punishments that named one. Empty on either side
  now means everything.

## The join with dot-voice, and why it is tested

`DotModerationManager` publishes itself in `DotRegistry` under `dot_mute_source` and
answers `is_voice_muted(peer)`. `DotVoiceRouter` looks that name up and calls that method.
Neither addon imports the other, and a project with only one of them works.

**That shape is exactly how every expensive bug in this family has started:** dot-map
calling `ensure` on a client that only had `acquire`, a leaderboard reporter sending its
file format where the backbone expected a schema, four call sites all finding a null cloud
client without one of them erroring. So `_test_voice_actually_asks` runs both halves for
real: a moderator mutes a player, the router silences them without being told, the manager
is destroyed and rebuilt from the file, and the player is still silenced.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/moderation_selftest.tscn   # 231 checks
```

The suite links `addons/dot_voice` so the last section can run. Without it that section
fails loudly rather than skipping, because "0 failures" from a suite that ran nothing is
how a family ships two ends that never met.

## Things deliberately not here

- **Console commands.** `mute`, `gag` and `ban` belong to dot-server's console, which has
  permission checking, chat triggers, player targeting and an audit trail. This is the
  record behind them, and `dot_ban_source` is how the two halves meet.
- **A per-address connection limit.** Admission belongs where the sessions are:
  `sv_max_connections_per_ip` and `DotAddressGuard`, in dot-server.
- **Kicking anybody.** No session list, no socket. It records that a kick happened.
- **An appeals workflow.** `evidence` holds a ticket number; the workflow is a website.
- **Chat filtering.** dot-server sanitises chat already, and a word list is a policy
  rather than a mechanism.
