@tool
class_name DotPunishmentSchema
extends RefCounted

## The punishment table, in one place, for every backend that has tables.
##
## [b]One definition, four dialects.[/b] The column list, the DDL, the index set and the
## row mapping all come from here, so a JSON file, a SQLite file, a Postgres cluster and
## a MySQL instance hold the same fourteen fields under the same names. A schema written
## once per backend is a schema that disagrees with itself within a month, and the way
## you find out is a ban that reads back with no expiry.
##
## [codeblock]
## for statement in DotPunishmentSchema.ddl(DotPunishmentSchema.Dialect.POSTGRES):
##     await driver.execute(statement)
## [/codeblock]

## Which SQL a backend speaks. The differences are small and every one of them is fatal.
enum Dialect {
	SQLITE,
	POSTGRES,
	MYSQL,
}

## Table name. Overridable per store, because an operator may already own `punishments`.
const DEFAULT_TABLE := "dot_punishments"

## Bumped when a column is added or changes meaning. Stored in [constant META_TABLE] so a
## server can refuse a database written by a newer build rather than reading it wrongly.
const SCHEMA_VERSION := 1

const META_TABLE := "dot_punishments_meta"

## Column order. Every INSERT, SELECT and row mapping uses this, so they cannot drift.
const COLUMNS := [
	"id",
	"kind",
	"subject",
	"reason",
	"issuer",
	"issued_at",
	"expires_at",
	"scope",
	"issuer_immunity",
	"revoked",
	"revoked_by",
	"revoked_at",
	"revoke_reason",
	"evidence",
]


## SQL type for a column in a dialect.
##
## The three that differ and why:
##
## - [b]Text.[/b] SQLite has one string type. Postgres wants `TEXT`. MySQL cannot index a
##   `TEXT` column without a prefix length, so anything indexed here is `VARCHAR`, and
##   `id`, `subject` and `scope` are all indexed.
## - [b]Booleans.[/b] SQLite and MySQL have none worth the name, so `revoked` is a small
##   integer everywhere and the mapping does the converting. A `BOOLEAN` column in
##   Postgres and an `INTEGER` in SQLite would need two row mappers.
## - [b]Time.[/b] Unix seconds in a 64-bit integer, never a timestamp type. A timestamp
##   carries a zone, or does not and pretends to, and the two servers reading this table
##   are in different places. Seconds since the epoch are the same number everywhere.
static func column_type(column: String, dialect: Dialect) -> String:
	match column:
		"id":
			return "VARCHAR(64)" if dialect == Dialect.MYSQL else "TEXT"
		"subject", "scope":
			return "VARCHAR(191)" if dialect == Dialect.MYSQL else "TEXT"
		"kind", "reason", "issuer", "revoked_by", "revoke_reason", "evidence":
			return "TEXT"
		"issued_at", "expires_at", "revoked_at":
			return "BIGINT"
		"issuer_immunity", "revoked":
			return "INTEGER" if dialect != Dialect.MYSQL else "INT"
	return "TEXT"


## Every statement needed to create the table and its indexes, in order.
##
## Idempotent: each is `IF NOT EXISTS`, so a server may run them on every boot and an
## operator who created the table by hand is not fought with.
static func ddl(dialect: Dialect, table: String = DEFAULT_TABLE) -> PackedStringArray:
	var out := PackedStringArray()
	var lines := PackedStringArray()

	for column in COLUMNS:
		var line := "  %s %s" % [column, column_type(column, dialect)]

		if column == "id":
			line += " PRIMARY KEY"
		elif column == "subject":
			line += " NOT NULL"
		elif column == "revoked":
			line += " NOT NULL DEFAULT 0"
		elif column in ["issued_at", "expires_at", "revoked_at", "issuer_immunity"]:
			line += " NOT NULL DEFAULT 0"

		lines.append(line)

	out.append(
		"CREATE TABLE IF NOT EXISTS %s (\n%s\n)" % [table, ",\n".join(Array(lines))]
	)

	# [b]The subject index is the one that matters.[/b] Every question this table is
	# asked is "what is in force against this person", on the join path, while a player
	# waits. Without it a community with fifty thousand records does a full scan per
	# connection and the symptom is a server that gets slower the longer it is popular.
	out.append(
		"CREATE INDEX IF NOT EXISTS %s_subject_idx ON %s (subject)" % [table, table]
	)
	# For "what is still in force", which is what a sweep and an admin listing both want.
	out.append(
		"CREATE INDEX IF NOT EXISTS %s_active_idx ON %s (revoked, expires_at)"
			% [table, table]
	)

	out.append(
		"CREATE TABLE IF NOT EXISTS %s (\n  key %s PRIMARY KEY,\n  value %s\n)" % [
			META_TABLE,
			"VARCHAR(64)" if dialect == Dialect.MYSQL else "TEXT",
			"TEXT",
		]
	)

	return out


## Placeholder for the [param index]-th bound parameter, counting from 1.
##
## [b]Not string interpolation, anywhere, ever.[/b] A ban reason is typed by a moderator
## and quotes an attacker-supplied name half the time, so it is exactly the string that
## must never reach a statement by concatenation. Postgres numbers its placeholders and
## the other two do not, which is the only reason this is a function.
static func placeholder(index: int, dialect: Dialect) -> String:
	return "$%d" % index if dialect == Dialect.POSTGRES else "?"


## `INSERT ... ON CONFLICT`, which every dialect spells differently.
##
## A punishment is written once and updated when it is revoked, and both go through this:
## an upsert means a retry after a network failure cannot produce two records for one
## action, which is how a duplicate ban ends up in somebody's history.
static func upsert(dialect: Dialect, table: String = DEFAULT_TABLE) -> String:
	var placeholders := PackedStringArray()
	for i in range(COLUMNS.size()):
		placeholders.append(placeholder(i + 1, dialect))

	var base := "INSERT INTO %s (%s) VALUES (%s)" % [
		table, ", ".join(COLUMNS), ", ".join(Array(placeholders))
	]

	match dialect:
		Dialect.MYSQL:
			var assignments := PackedStringArray()
			for column in COLUMNS:
				if column == "id":
					continue
				assignments.append("%s = VALUES(%s)" % [column, column])
			return "%s ON DUPLICATE KEY UPDATE %s" % [base, ", ".join(Array(assignments))]
		_:
			# SQLite and Postgres share this spelling, which is the one the SQL standard
			# eventually adopted.
			var assignments := PackedStringArray()
			for column in COLUMNS:
				if column == "id":
					continue
				assignments.append("%s = excluded.%s" % [column, column])
			return "%s ON CONFLICT(id) DO UPDATE SET %s" % [
				base, ", ".join(Array(assignments))
			]


## Records a key and value in the metadata table, for the schema version.
static func upsert_meta(dialect: Dialect) -> String:
	var base := "INSERT INTO %s (key, value) VALUES (%s, %s)" % [
		META_TABLE, placeholder(1, dialect), placeholder(2, dialect)
	]

	if dialect == Dialect.MYSQL:
		return "%s ON DUPLICATE KEY UPDATE value = VALUES(value)" % base

	return "%s ON CONFLICT(key) DO UPDATE SET value = excluded.value" % base


static func select_all(table: String = DEFAULT_TABLE) -> String:
	return "SELECT %s FROM %s" % [", ".join(COLUMNS), table]


static func select_by_subject(dialect: Dialect, table: String = DEFAULT_TABLE) -> String:
	return "%s WHERE subject = %s" % [select_all(table), placeholder(1, dialect)]


static func delete_by_id(dialect: Dialect, table: String = DEFAULT_TABLE) -> String:
	return "DELETE FROM %s WHERE id = %s" % [table, placeholder(1, dialect)]


## A punishment as the bound parameters for [method upsert], in [constant COLUMNS] order.
static func to_row(punishment: DotPunishment) -> Array:
	return [
		punishment.id,
		# The machine token, never the player-facing name. Writing "voice muted" here is
		# the bug that made every stored mute load back as a warning.
		DotPunishment.kind_token(punishment.kind),
		punishment.subject,
		punishment.reason,
		punishment.issuer,
		punishment.issued_at,
		punishment.expires_at,
		punishment.scope,
		punishment.issuer_immunity,
		1 if punishment.revoked else 0,
		punishment.revoked_by,
		punishment.revoked_at,
		punishment.revoke_reason,
		"" if punishment.evidence.is_empty() else JSON.stringify(punishment.evidence),
	]


## A row back into a punishment.
##
## Accepts a [Dictionary] keyed by column name, which is what most drivers return, or an
## [Array] in [constant COLUMNS] order, which is what the rest return. Supporting both
## here means a driver does not have to normalise, and a driver that normalises wrongly is
## a bug in a place nobody looks.
static func from_row(row: Variant) -> DotPunishment:
	var values := {}

	if row is Dictionary:
		values = row as Dictionary
	elif row is Array:
		var array := row as Array
		for i in range(mini(array.size(), COLUMNS.size())):
			values[COLUMNS[i]] = array[i]
	else:
		return null

	var punishment := DotPunishment.new()
	punishment.id = str(values.get("id", ""))
	punishment.kind = DotPunishment.kind_from_name(str(values.get("kind", "warn")))
	punishment.subject = str(values.get("subject", ""))
	punishment.reason = str(values.get("reason", ""))
	punishment.issuer = str(values.get("issuer", ""))
	punishment.issued_at = int(values.get("issued_at", 0))
	punishment.expires_at = int(values.get("expires_at", 0))
	punishment.scope = str(values.get("scope", ""))
	punishment.issuer_immunity = int(values.get("issuer_immunity", 0))
	# A driver may hand back a bool, an int or the string "1"; all three mean the same
	# and only one of them is what any given backend does.
	var revoked_value: Variant = values.get("revoked", 0)
	punishment.revoked = (
		bool(revoked_value) if revoked_value is bool
		else int(str(revoked_value).to_int()) != 0
	)
	punishment.revoked_by = str(values.get("revoked_by", ""))
	punishment.revoked_at = int(values.get("revoked_at", 0))
	punishment.revoke_reason = str(values.get("revoke_reason", ""))

	var evidence_text := str(values.get("evidence", ""))
	if evidence_text != "":
		var parsed: Variant = JSON.parse_string(evidence_text)
		if parsed is Dictionary:
			punishment.evidence = parsed as Dictionary

	return punishment


static func dialect_name(dialect: Dialect) -> String:
	match dialect:
		Dialect.SQLITE: return "sqlite"
		Dialect.POSTGRES: return "postgres"
		Dialect.MYSQL: return "mysql"
	return "sqlite"


static func dialect_from_name(name: String) -> Dialect:
	match name.strip_edges().to_lower():
		"postgres", "postgresql", "pgsql": return Dialect.POSTGRES
		"mysql", "mariadb": return Dialect.MYSQL
		_: return Dialect.SQLITE
