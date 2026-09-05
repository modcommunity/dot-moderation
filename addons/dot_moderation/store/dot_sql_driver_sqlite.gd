@tool
class_name DotSqlDriverSqlite
extends DotSqlDriver

## SQLite, through the `godot-sqlite` GDExtension.
##
## [b]The extension is reached by name and never by identifier.[/b] `ClassDB.instantiate`
## plus `Object.call`, exactly as `DotTransportENet` reaches ENet, and for exactly the
## same reason: a script that merely [i]mentions[/i] a `class_name` the project does not
## have fails to compile and takes every script referencing it down with it. So this file
## compiles on a machine with no extension installed, and says so when asked.
##
## [codeblock]
## # https://github.com/2shady4u/godot-sqlite -> addons/godot-sqlite/
## var driver := DotSqlDriverSqlite.new("user://moderation.db")
## var store := DotPunishmentStoreSql.new(driver)
## await store.open()
## [/codeblock]
##
## [b]Not covered by the suite.[/b] The extension is not installed here, so everything
## below the `is_available()` check is the same kind of untested device layer as
## dot-voice's microphone. It is written to the documented API and read against it, which
## is not the same as having been run. Said out loud rather than left to be discovered.

const EXTENSION_CLASS := "SQLite"

## Where the database file lives. `user://` on a client, an absolute path on a server.
var path: String = "user://moderation.db"

## Log every statement through the extension's own verbosity. For a bad afternoon.
var verbose: bool = false

var _db: Object = null


func _init(p_path: String = "user://moderation.db") -> void:
	path = p_path


func dialect() -> DotPunishmentSchema.Dialect:
	return DotPunishmentSchema.Dialect.SQLITE


func driver_name() -> String:
	return "sqlite"


func is_available() -> DotResult:
	if not ClassDB.class_exists(EXTENSION_CLASS):
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"The SQLite GDExtension is not installed.",
			"install github.com/2shady4u/godot-sqlite into addons/, or use "
			+ "DotPunishmentStoreFile for a JSON file"
		)

	if not ClassDB.can_instantiate(EXTENSION_CLASS):
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"The SQLite class exists but cannot be instantiated on this platform.",
			"a GDExtension has to ship a binary per platform, and the web is usually "
			+ "the one it does not"
		)

	return DotResult.success(true)


func open() -> DotResult:
	if _db != null:
		return DotResult.success(true)

	var available := is_available()
	if not available.ok:
		return available

	_db = ClassDB.instantiate(EXTENSION_CLASS)

	if _db == null:
		return DotResult.fail(
			DotError.CODE_INTERNAL, "The SQLite extension would not instantiate."
		)

	# A relative `user://` path is resolved by the extension itself, which wants the
	# Godot path rather than an OS one.
	_db.set("path", path)
	_db.set("verbosity_level", 2 if verbose else 0)

	var opened: Variant = _db.call("open_db")

	if not bool(opened):
		var why := str(_db.get("error_message"))
		_db = null
		return DotResult.fail(
			DotError.CODE_IO,
			"Could not open the SQLite database.",
			"%s: %s" % [path, why]
		)

	# Write-ahead logging, because a dedicated server writing a ban while a web panel
	# reads the list is the normal case and the default journal mode locks one out.
	_db.call("query", "PRAGMA journal_mode=WAL")
	# Without this SQLite does not enforce them, which makes them decoration.
	_db.call("query", "PRAGMA foreign_keys=ON")

	DotLog.info(CHANNEL, "sqlite open", {"path": path})

	return DotResult.success(true)


func close() -> void:
	if _db == null:
		return
	_db.call("close_db")
	_db = null


func is_open() -> bool:
	return _db != null


func execute(sql: String, params: Array = []) -> DotResult:
	if _db == null:
		return DotResult.fail(DotError.CODE_STATE, "The database is not open.")

	var ok: Variant = _db.call("query_with_bindings", sql, params)

	if not bool(ok):
		return DotResult.fail(
			DotError.CODE_IO,
			"A statement failed.",
			str(_db.get("error_message"))
		)

	return DotResult.success(true)


func query(sql: String, params: Array = []) -> DotResult:
	if _db == null:
		return DotResult.fail(DotError.CODE_STATE, "The database is not open.")

	var ok: Variant = _db.call("query_with_bindings", sql, params)

	if not bool(ok):
		return DotResult.fail(
			DotError.CODE_IO,
			"A query failed.",
			str(_db.get("error_message"))
		)

	var rows: Variant = _db.get("query_result")

	return DotResult.success(rows if rows is Array else [])


func supports_transactions() -> bool:
	return true


func batch(statements: Array) -> DotResult:
	if _db == null:
		return DotResult.fail(DotError.CODE_STATE, "The database is not open.")

	_db.call("query", "BEGIN")

	for entry in statements:
		if not (entry is Array) or (entry as Array).is_empty():
			continue
		var pair := entry as Array
		var params: Array = pair[1] if pair.size() > 1 and pair[1] is Array else []
		var result: DotResult = await execute(str(pair[0]), params)
		if not result.ok:
			# Rolled back as a unit. A half-applied batch is a moderation list that
			# disagrees with itself and nothing says which half is real.
			_db.call("query", "ROLLBACK")
			return result

	_db.call("query", "COMMIT")

	return DotResult.success(statements.size())


func describe() -> Dictionary:
	var out := super.describe()
	out["path"] = path
	out["available"] = is_available().ok
	return out
