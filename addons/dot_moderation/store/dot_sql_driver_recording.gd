@tool
class_name DotSqlDriverRecording
extends DotSqlDriver

## A driver that writes nothing and remembers everything it was asked to do.
##
## [b]This is how the SQL store is tested without a database.[/b] The store's job is to
## generate correct DDL, build parameterised statements, bind values in the right order
## and map rows back; none of that needs a real engine, and all of it is where the bugs
## are. What a native driver adds is execution, and that is the part no headless run can
## cover, exactly as with dot-voice's microphone.
##
## It also answers queries from a set of rows a test supplies, so the read path and the
## row mapping are exercised for real rather than assumed.

## Every statement executed or queried, in order, as `{sql, params}`.
var statements: Array[Dictionary] = []

## Rows handed back by [method query]. Set by a test.
var rows: Array = []

## Set to make the next call fail, for testing what a store does about it.
var fail_next: String = ""

var sql_dialect: DotPunishmentSchema.Dialect = DotPunishmentSchema.Dialect.SQLITE
var _open: bool = false


func _init(p_dialect: DotPunishmentSchema.Dialect = DotPunishmentSchema.Dialect.SQLITE) -> void:
	sql_dialect = p_dialect


func dialect() -> DotPunishmentSchema.Dialect:
	return sql_dialect


func driver_name() -> String:
	return "recording"


func is_available() -> DotResult:
	return DotResult.success(true)


func open() -> DotResult:
	_open = true
	return DotResult.success(true)


func close() -> void:
	_open = false


func is_open() -> bool:
	return _open


func supports_transactions() -> bool:
	return true


func execute(sql: String, params: Array = []) -> DotResult:
	statements.append({"sql": sql, "params": params})

	if fail_next != "":
		var why := fail_next
		fail_next = ""
		return DotResult.fail(DotError.CODE_IO, why)

	return DotResult.success(true)


func query(sql: String, params: Array = []) -> DotResult:
	statements.append({"sql": sql, "params": params})

	if fail_next != "":
		var why := fail_next
		fail_next = ""
		return DotResult.fail(DotError.CODE_IO, why)

	return DotResult.success(rows.duplicate())


## Statements whose SQL contains [param needle], for an assertion.
func matching(needle: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in statements:
		if str(entry["sql"]).contains(needle):
			out.append(entry)
	return out


func clear() -> void:
	statements.clear()
