@tool
class_name DotSqlDriver
extends RefCounted

## Executes statements against a database. One of these per backend.
##
## [b]Godot ships no database driver, and that is the constraint this interface exists to
## work around honestly.[/b] There is no `SQLite`, no `PostgreSQLClient` and no `MySQL`
## class in the engine; every one of them is a GDExtension somebody installs. So
## [DotPunishmentStoreSql] does everything that can be done in GDScript — build the DDL,
## build parameterised statements, bind values, map rows — and hands the one step that
## needs a native library to whatever is installed.
##
## The split is the same one [DotVoiceSource] makes for microphones and for the same
## reason: it is what lets the part written here be tested without the part that cannot be.
##
## [b]Never build a statement by concatenation.[/b] Every method here takes bound
## parameters. A ban reason is typed by a moderator and quotes an attacker-supplied name
## half the time, so it is precisely the string that must not reach SQL as text.

const CHANNEL := "moderation.sql"


## Which SQL this driver speaks, so the store can pick the right spelling.
func dialect() -> DotPunishmentSchema.Dialect:
	return DotPunishmentSchema.Dialect.SQLITE


func driver_name() -> String:
	return "none"


## Whether the native library this driver needs is actually installed.
##
## Answered before anything is opened, so a deployment gets "the SQLite extension is not
## installed" rather than a store that fails on its first write.
func is_available() -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "This driver has no backend."
	)


func open() -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "This driver cannot open.")


func close() -> void:
	pass


func is_open() -> bool:
	return false


## Runs a statement that returns no rows.
func execute(_sql: String, _params: Array = []) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "This driver cannot execute.")


## Runs a statement and returns [code]Array[/code] of rows.
##
## A row may be a [Dictionary] keyed by column name or an [Array] in column order;
## [method DotPunishmentSchema.from_row] accepts either, so a driver does not have to
## normalise and cannot normalise wrongly.
func query(_sql: String, _params: Array = []) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "This driver cannot query.")


## Runs several statements as one unit, rolling back if any fails.
##
## The default runs them in order without a transaction, which is honest rather than
## silently pretending: a driver that has transactions overrides this. A store that needs
## atomicity should check [method supports_transactions] rather than assume.
func batch(statements: Array) -> DotResult:
	var done := 0

	for entry in statements:
		if not (entry is Array) or (entry as Array).is_empty():
			continue
		var pair := entry as Array
		var sql := str(pair[0])
		var params: Array = pair[1] if pair.size() > 1 and pair[1] is Array else []
		var result: DotResult = await execute(sql, params)
		if not result.ok:
			return result.wrap("Statement %d of %d failed." % [done + 1, statements.size()])
		done += 1

	return DotResult.success(done)


func supports_transactions() -> bool:
	return false


func describe() -> Dictionary:
	return {
		"driver": driver_name(),
		"dialect": DotPunishmentSchema.dialect_name(dialect()),
		"open": is_open(),
	}
