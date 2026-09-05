This is the **moderation** asset for TMC's **Dot** collection. It is the answer to "he just reconnects", which is the most common complaint on any community server.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Moderation That Survives a Reconnect

Bans, kicks, chat gags, voice mutes and warnings as one durable record, with pluggable
storage so a community running several servers shares one list. Plus the live tools a
moderator uses on somebody standing in front of them, teleporting included.

Needs **dot-core** and nothing else. Works with [dot-voice](../dot-voice) and
[dot-server](../dot-server) without importing either.

```bash
ln -s ../../dot-core/addons/dot_core addons/dot_core
godot --headless --path . res://examples/moderation_selftest.tscn   # 231 checks
```

### Why this exists next to dot-server, which already bans

[dot-server](../dot-server) has bans, kicks, admin flags with immunity, and an audit log,
and none of that changes. What it does not have is a **mute that outlives a session**:
`DotClientSession.silence()` sets two booleans on a session object, and a session is
destroyed when its player disconnects. So a muted player reconnects and can talk again,
which is the first thing anybody who has been muted tries.

Bans persisting and mutes not is not a design. It is an accident of where the state
happened to live. Here a mute is the same kind of record a ban is: stored, expiring,
scoped, revocable, and on the player's history.

### The model

A `DotPunishment` is a kind, a subject, a reason, an issuer, a moment it was issued and a
moment it expires. `BAN`, `KICK`, `VOICE_MUTE`, `GAG` and `WARN` are the same record with
a different kind, because a server asks the same four questions about each.

- **The subject is an opaque durable key, never a peer id.** A peer id is reused within
  minutes and means nothing after a disconnect, so a punishment keyed on one is a
  punishment against whoever connects next. `key_for_peer` is where your identity model
  plugs in, and if you do not set it the addon says so in `describe_lines()`.
- **Expiry is answered on read, never swept on a timer.** A server that was off overnight
  would otherwise come up enforcing yesterday's mutes.
- **A revoke keeps the record.** The history is the point; it is what makes the next
  decision defensible.
- **A kick and a warning are never "active".** They happened; they are not still
  happening.
- **A subject is a person or a machine**, and `DotPunishmentSubject` decides how each is
  spelled: `uid:backbone:abc` and `ip:203.0.113.9`, with the port and any decoration
  stripped off the address. Opaque is right — the addon must not care whether you key
  people on an account, a pseudonymous id or a device — but "opaque" and "however each
  caller felt like writing it" are not the same thing. A ban filed against `1.2.3.4` and
  a check for `1.2.3.4:51234` are two strings that never meet, and nothing errors: the
  ban is in the file, the player walks in, and the moderator is told it works.

### Banning an address, and getting it enforced

An account ban is exact and only works on somebody who has an account; a guest comes back
as a different guest, which is most of the people a server actually has to remove. An
address ban catches everybody behind it — a household, a shared NAT — and is defeated by
a router reboot. Neither is sufficient alone, so `ban_uid` and `ban_address` both exist.

Nothing here can refuse a connection: there is no session list and no socket. So the
manager publishes itself under **`dot_ban_source`**, and dot-server asks it on every
join:

```gdscript
check_admission(uid: String, address: String) -> DotResult
```

Same shape as the `dot_mute_source` name dot-voice already looks up — one registry name,
one method, neither addon naming the other. With nothing registered, a `BAN` recorded
here is a row in a file that stops nobody, and `describe_lines()` says so where an
operator looks.

### Storage

The table is defined once in `DotPunishmentSchema` and every backend holds the same
fourteen columns: `id`, `kind`, `subject`, `reason`, `issuer`, `issued_at`, `expires_at`,
`scope`, `issuer_immunity`, `revoked`, `revoked_by`, `revoked_at`, `revoke_reason`,
`evidence`.

| Backend | Class | Status |
| --- | --- | --- |
| **JSON file** | `DotPunishmentStoreFile` | Works out of the box. Right for one server. |
| **REST API** | `DotPunishmentStoreRest` | Works out of the box. Four endpoints; keep your own ban system. |
| **SQLite** | `DotPunishmentStoreSql` + `DotSqlDriverSqlite` | Needs the [godot-sqlite](https://github.com/2shady4u/godot-sqlite) GDExtension. |
| **PostgreSQL** | `DotPunishmentStoreSql` + `DotSqlDriverGateway` | Needs a driver extension, or an HTTP gateway beside the database. |
| **MySQL** | same | same |

**Be aware of what Godot does not have.** There is no `SQLite`, `PostgreSQLClient` or
`MySQL` class in the engine, and neither the Postgres nor the MySQL wire protocol can be
spoken from GDScript without implementing an authentication handshake, a binary format
and a connection pool. That is a project, not a file, and a half-finished one is a
security problem rather than a missing feature.

So the SQL half does everything that *can* be done here — the DDL per dialect, bound
parameters, row mapping, upserts, indexes — and hands execution to a driver. Write a
twenty-line `DotSqlDriver` for whatever extension you install, or put the database behind
HTTP. **The second is what most deployments should do anyway:** a game server holding a
Postgres password is a game server whose compromise is a compromise of the database.

Statements are **always parameterised**. A ban reason is typed by a moderator and quotes
the offender's name half the time, so it is exactly the string that must never reach SQL
by concatenation.

### The REST contract

```
GET    {base}/punishments                  -> {"punishments": [ {...}, ... ]}
GET    {base}/punishments?subject=uid:123  -> the same, filtered
PUT    {base}/punishments/{id}             <- one record   -> {"ok": true}
DELETE {base}/punishments/{id}                             -> {"ok": true}
```

A record is the JSON `DotPunishment.to_dictionary()` produces, which is what the file
store writes. One format for every backend, so moving between them is one line.

A read failure is **never** an empty list. An API outage that read as "nobody is banned"
would readmit everyone silently, so every error path returns a failure and the manager
keeps what it already had.

### Mod tools

`DotModTools` is what a moderator does to a player standing in front of them.

| | |
| --- | --- |
| `teleport(actor, target, to)` | Move a player to a position. |
| `bring(actor, target)` | The player comes to the moderator. |
| `goto(actor, target)` | The moderator goes to the player, stopping short so nobody lands inside anybody. |
| `send(actor, target, destination)` | One player to another. |
| `return_player(actor, target)` | Put them back. |

**`return_player` is what makes the rest safe to use.** Without an undo, "bring" is
something a moderator hesitates to do mid-round, and a moderator who hesitates does not
moderate. Every move saves a position first, including a `goto`, so a moderator can put
themselves back too.

It knows nothing about your world: positions come from `position_fn` and moves go through
`teleport_fn`, both yours. Positions are `Variant`, so **2D is a first-class user** rather
than something to work around. Every action goes on the target's history as a warning
(which enforces nothing), so "an admin moved me" has an answer.

### Where a game plugs in

| To change | Where |
| --- | --- |
| Where punishments live | `DotPunishmentStore` subclass |
| Which database | `DotSqlDriver` subclass, or `DotPunishmentStoreRest` |
| Where a player is, and how to move them | `DotModTools.position_fn` / `teleport_fn` |
| How a peer maps to a person | `DotModerationManager.key_for_peer` |
| Which servers a punishment covers | `DotModerationManager.server_scope` |
| Whether dot-server enforces these bans | `DotModerationManager.register_ban_source` |
| The longest punishment allowed | `DotModerationManager.max_duration_sec` |
| Whether equals may act on equals | `DotModerationManager.equal_immunity_may_act` |

### What is deliberately not here

- **Console commands.** `mute`, `gag` and `ban` belong to [dot-server](../dot-server)'s
  console, which already has permission checking and an audit trail. This is the record
  behind them.
- **A second ban list.** dot-server's `DotBanManager` is shipped, tested and works
  standalone. This does bans too — including by address, and enforced at connect through
  `dot_ban_source` — for a project that wants one record type for everything, and a
  deployment should pick one rather than run both.
- **A limit on connections from one address.** That is admission, so it belongs where the
  sessions are: `sv_max_connections_per_ip` in dot-server.
- **Kicking anybody.** This has no session list and no socket. It records that a kick
  happened; performing one is the server's.
- **An appeals workflow.** `evidence` holds a ticket number. The workflow is a website.
