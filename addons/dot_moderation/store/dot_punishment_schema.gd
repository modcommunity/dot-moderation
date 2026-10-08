@tool
class_name DotPunishmentSchema
extends RefCounted

## The punishment table, in one place, for every backend that has tables.
##
## [b]One definition, every backend.[/b] The column list, the indexes and the row mapping
## all come from here, so a JSON file, a SQLite file, a Postgres cluster and a MySQL
## instance hold the same fourteen fields under the same names. A schema written once per
## backend is a schema that disagrees with itself within a month, and the way you find out
## is a ban that reads back with no expiry.
##
## [b]The table is plain data, rendered by dot-sql.[/b] [method table_spec] is a
## [Dictionary] a dot-sql driver turns into DDL for its own dialect
## ([code]driver.ensure_table(spec)[/code]), which is where MySQL's refusal to index TEXT,
## its lack of [code]CREATE INDEX IF NOT EXISTS[/code] and its reserved words are handled
## once for every addon. This file names no dot-sql class, so dot-moderation still parses
## in a project without it; only [DotPunishmentStoreSql] needs a driver at all.
##
## [b]Placeholders are [code]?[/code] in every dialect[/b] — dot-sql's contract. A driver
## that speaks to Postgres natively numbers them itself at the last moment.

## Table name. Overridable per store, because an operator may already own `punishments`.
const DEFAULT_TABLE := "dot_punishments"

## The component name the table's schema version is recorded under, in dot-sql's
## migration table. Bumped by adding a step to [method migration_steps], never by editing
## one: a database at version 1 must be brought to 2 by what 2 adds.
const MIGRATION_COMPONENT := "dot_moderation"

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


## The table, as a dot-sql table spec.
##
## - [b]`id`, `subject` and `scope` are `key`[/b] (VARCHAR on MySQL): all three are
##   indexed, and MySQL cannot index TEXT without a prefix length.
## - [b]Times are Unix seconds in a BIGINT[/b], never a timestamp type. A timestamp
##   carries a zone, or does not and pretends to, and the two servers reading this table
##   are in different places.
## - [b]`revoked` is 0/1[/b] everywhere, and [method from_row] reads a bool, an int or a
##   string back, because each backend returns a different one.
##
## [b]The subject index is the one that matters.[/b] Every question this table is asked is
## "what is in force against this person", on the join path, while a player waits.
static func table_spec(table: String = DEFAULT_TABLE) -> Dictionary:
	return {
		"name": table,
		"columns": [
			{"name": "id", "type": "key", "null": false},
			{"name": "kind", "type": "text", "null": false, "default": "warn"},
			{"name": "subject", "type": "key", "null": false},
			{"name": "reason", "type": "text"},
			{"name": "issuer", "type": "text"},
			{"name": "issued_at", "type": "bigint", "null": false, "default": 0},
			{"name": "expires_at", "type": "bigint", "null": false, "default": 0},
			{"name": "scope", "type": "key"},
			{"name": "issuer_immunity", "type": "int", "null": false, "default": 0},
			{"name": "revoked", "type": "bool", "null": false, "default": 0},
			{"name": "revoked_by", "type": "text"},
			{"name": "revoked_at", "type": "bigint", "null": false, "default": 0},
			{"name": "revoke_reason", "type": "text"},
			{"name": "evidence", "type": "json"},
		],
		"primary_key": ["id"],
		"indexes": [
			{"name": "subject_idx", "columns": ["subject"]},
			# For "what is still in force", which a sweep and an admin listing both want.
			{"name": "active_idx", "columns": ["revoked", "expires_at"]},
		],
	}


## Every schema change, in order, for dot-sql's migrator. Step N brings version N to N+1.
static func migration_steps(table: String = DEFAULT_TABLE) -> Array:
	return [
		[table_spec(table)],
	]


static func select_all(table: String = DEFAULT_TABLE) -> String:
	return "SELECT %s FROM %s" % [", ".join(COLUMNS), table]


static func select_by_subject(table: String = DEFAULT_TABLE) -> String:
	return "%s WHERE subject = ?" % select_all(table)


static func delete_by_id(table: String = DEFAULT_TABLE) -> String:
	return "DELETE FROM %s WHERE id = ?" % table


## A punishment as the bound parameters for an upsert, in [constant COLUMNS] order.
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


## A dialect's name, for logs and [code]describe()[/code]. The integers are dot-sql's.
static func dialect_name(dialect: int) -> String:
	match dialect:
		0: return "sqlite"
		1: return "postgres"
		2: return "mysql"
	return "unknown"
