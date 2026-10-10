# Storage

## The store is what makes it a community's list rather than a machine's

`DotPunishmentStoreFile` is right for one server and wrong the moment there are two: a player muted on one server walks into the next one unmuted, which is "he just reconnects" one level up. Use `DotPunishmentStoreSql` or `DotPunishmentStoreRest`, or subclass `DotPunishmentStore`.

Three rules the shipped stores obey and a subclass must too:

- **A failed load keeps whatever is already in force.** Returning an empty list on an error readmits everybody who was ever removed, silently.
- **Writes are awaited before the in-memory set changes**, so a store that refuses does not leave a punishment that exists on one server and nowhere else. A failed revoke is rolled back for the same reason.
- **`is_writable() == false` is legitimate.** A server enforcing a centrally managed list says so rather than appearing to work and losing the record on the next refresh.

**One bad entry does not condemn the file.** Nine hundred good records and one typo should moderate with the nine hundred and say which one was dropped. Same as dot-map's catalogue.

## SQL

The table is defined once, in `DotPunishmentSchema.table_spec()`, as plain data, the same everywhere, so a JSON file, a SQLite file, a Postgres cluster and a MySQL instance never disagree about what a punishment is. A schema written once per backend disagrees with itself within a month, and you find out when a ban reads back with no expiry.

**The SQL itself is dot-sql's.** This addon once carried its own `DotSqlDriver*` classes and DDL per dialect; a `class_name` declared twice fails every script in a project that links both, and the DDL had MySQL bugs no suite here could see. Both are handled once, in dot-sql's `DotSqlSchema`, for every addon that keeps a table. Do not add SQL dialect code here.

**The store reaches its driver duck-typed.** `DotPunishmentStoreSql.driver` is untyped and asked for `migrate`, `query`, `execute` and `upsert_sql`, so this addon depends only on dot-core and parses in a project without dot-sql. Only the suites link dot-sql (the `/addons/dot_sql` line in `.gitignore`).

**The schema is versioned** through dot-sql's migrator under the component `dot_moderation:<table>`. A database from a newer build is refused rather than read with columns that changed meaning underneath it.

What the dialects still differ in, and why the spec is shaped the way it is: `id`, `subject` and `scope` are `key` columns (VARCHAR on MySQL) because all three are indexed and MySQL cannot index TEXT; `revoked` is 0/1 everywhere and `from_row` reads back a bool, an int or a string because each backend returns a different one; and time is Unix seconds in a BIGINT, never a timestamp type, because a timestamp carries a zone or pretends not to and two servers reading this table are in different places. Placeholders are `?` in every dialect (dot-sql's contract).

**Statements are always parameterised.** A ban reason is typed by a moderator and quotes the offender's name half the time. The suite asserts that a reason containing a quote never appears in the statement text, and the live suite writes one with a quote and an emoji and reads it back.

## The REST store

`DotPunishmentStoreRest` is what a community with an existing ban system uses. It is tested against a real small HTTP server in `examples/punishment_api_server.gd` rather than a mock, because a mock returns whatever was assumed:

- **`DotHttp.get_json` returns the parsed body, not a wrapper around it.**
- **The `punishments` key must be present.** `document.get("punishments", [])` accepted any JSON object at all (a different shape, a paginated envelope, an error body that happened to be 200) as a successful read of nothing, which means nobody is banned. **The single worst failure this addon has, one default argument away.** The suite serves `{"data": []}` to prove it is refused.

## Testing

`moderation_selftest` drives the SQL store against dot-sql's recording driver: which statements, which parameters, in which order, and the row mapping. `moderation_sql_live` runs the same store against real SQLite, Postgres and MySQL through dot-sql's reference gateway: `../dot-sql/tools/test_live.sh . res://examples/moderation_sql_live.tscn`, with `DOT_SQL_PG_DSN` and `DOT_SQL_MYSQL_DSN` set. Both matter: the recording driver cannot see a dialect bug.
