# dot-moderation

Moderation that survives a reconnect: bans, kicks, gags, voice mutes and warnings as records that are stored, expiring, scoped, revocable and on the player's history; a file, SQL or REST store; the admission and mute hooks dot-server and dot-voice ask; and the live admin tools (teleport, noclip, god, freeze and the rest) with their commands.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to moderation. The reasoning is in [docs/](docs/README.md).

**Only dot-core is a dependency.** dot-server, dot-voice and dot-sql are optional and none is named in the source: they meet through `DotRegistry` names (`dot_ban_source`, `dot_mute_source`), duck-typed console hosts, and an untyped SQL driver. The suites link dot-voice and dot-sql (`.gitignore`).

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/records.md](docs/records.md) | `DotPunishment`, `DotPunishmentSubject`, `DotModerationManager`, admission, mutes, immunity, what is deliberately not here |
| [docs/storage.md](docs/storage.md) | any `DotPunishmentStore`, `DotPunishmentSchema` |
| [docs/mod-tools.md](docs/mod-tools.md) | `DotModTools`, `DotModToolCommands` |
| [docs/history.md](docs/history.md) | the bugs, and how each looked |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_moderation/core/` | `DotPunishment` (the record), `DotPunishmentSubject` (how a uid or an address is spelled) |
| `addons/dot_moderation/runtime/` | `DotModerationManager`: the set in force; registers `dot_ban_source` and `dot_mute_source` |
| `addons/dot_moderation/store/` | `DotPunishmentStore` (abstract), file, SQL (on dot-sql, duck-typed), REST; `DotPunishmentSchema` |
| `addons/dot_moderation/tools/` | `DotModTools`: teleport and return, and the handler table |
| `addons/dot_moderation/integrations/` | `DotModToolCommands`: the live tools as console commands on any host |
| `examples/moderation_selftest.tscn` | the suite (links dot-voice and dot-sql's recording driver) |
| `examples/moderation_sql_live.tscn` | the SQL store against real SQLite, Postgres and MySQL |
| `examples/punishment_api_server.gd` | a real HTTP server the REST store is tested against |

## Running and testing

- The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `godot --headless --path . res://examples/moderation_selftest.tscn`. Without `addons/dot_voice` linked its last section fails loudly, on purpose.
- Anything in the SQL store: `../dot-sql/tools/test_live.sh . res://examples/moderation_sql_live.tscn` with `DOT_SQL_PG_DSN` and `DOT_SQL_MYSQL_DSN` set. [storage](docs/storage.md#testing)
- A change to admission is not done until dot-server's `examples/dedicated_server.gd` still refuses a banned connection.

## Rules that bite

**Records**

- One record for every kind. Kicks and warnings are never active; `expires_at == 0` is permanent; a revoke keeps the record; the player message never names the moderator. [records](docs/records.md#a-punishment-is-a-record-not-a-flag)
- Store `kind_token()`, show `kind_name()`. [records](docs/records.md#a-punishment-is-a-record-not-a-flag)
- Empty scope on either side means everything. [records](docs/records.md#a-punishment-is-a-record-not-a-flag)
- Expiry is answered on read, never swept. [records](docs/records.md#expiry-is-answered-on-read-never-swept)
- A subject is never a peer id; set `key_for_peer` (unset is `str(peer)` and warns). [records](docs/records.md#the-subject-is-never-a-peer-id)
- Spell subjects through `DotPunishmentSubject.for_address` / `for_uid`; `ban_address` and `ban_uid` are a pair; loopback and unknown addresses are refused. [records](docs/records.md#an-address-is-a-subject-too-and-how-it-is-spelled-is-the-whole-trick)
- A ban stops nobody unless something asks: `check_admission` on `dot_ban_source` checks both spellings of a uid; `describe_lines()` warns when nothing is registered. [records](docs/records.md#dot_ban_source-or-the-ban-that-stops-nobody)
- The dot-voice join is tested by running both halves for real. [records](docs/records.md#the-join-with-dot-voice-and-why-it-is-tested)
- Immunity guards the target as well as the actor; equal cannot act on equal; zero is no immunity; acting on yourself is never an immunity question. [records](docs/records.md#immunity-in-both-directions)

**Storage**

- A failed load keeps what is in force; writes are awaited before memory changes; a failed revoke rolls back; `is_writable() == false` is legitimate; one bad entry is dropped, not fatal. [storage](docs/storage.md#the-store-is-what-makes-it-a-communitys-list-rather-than-a-machines)
- The table is `DotPunishmentSchema.table_spec()`; SQL and dialects are dot-sql's; the driver is duck-typed; statements are parameterised; time is Unix seconds in a BIGINT. [storage](docs/storage.md#sql)
- The REST store requires the `punishments` key; a missing key is a failure, never an empty list. [storage](docs/storage.md#the-rest-store)

**Tools**

- Save the position before a move; `goto` stops short; positions are `Variant`; the return history is capped; every action is a `WARN`. [mod-tools](docs/mod-tools.md#moving-people)
- An ability with no handler refuses with the game's reason; respawn clears through the handlers and re-applies god and buddha; a timed release checks its serial. [mod-tools](docs/mod-tools.md#the-rest-of-the-admin-set-is-a-handler-table)
- Commands target through the server's `resolve_target`; a protected player is skipped from a group and counted; a name already registered is never taken. [mod-tools](docs/mod-tools.md#the-commands-and-why-they-are-here-rather-than-in-dot-server)

## Where a game plugs in

| To change | Where |
| --- | --- |
| Who a peer is | `DotModerationManager.key_for_peer` |
| Where punishments live | `DotPunishmentStoreFile`, `DotPunishmentStoreSql` (with a dot-sql driver), `DotPunishmentStoreRest`, or a `DotPunishmentStore` subclass |
| Whether bans refuse connections | `register_ban_source` (on), with dot-server asking `dot_ban_source` |
| Whether mutes reach voice | `dot_mute_source`, asked by `DotVoiceRouter` |
| What a live tool does in this game | `DotModTools.handlers`, `unsupported_reasons`, `position_fn` / `teleport_fn` |
| Group targets | `alive_fn`, `team_fn` on the commands |
| Which abilities survive a respawn | `persist_on_respawn` |

Deliberately not here: punishment console commands (dot-server's), per-address connection limits, kicking anybody, appeals, chat filtering. [records](docs/records.md#deliberately-not-here)
