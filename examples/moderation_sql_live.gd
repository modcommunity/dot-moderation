extends Node

## The SQL store against a real database, through dot-sql's gateway.
##
## The self-test proves which statements the store sends; this proves a database accepts
## them, in all three dialects. Run by dot-sql's runner, which starts a gateway per
## dialect and sets DOT_SQL_URL, DOT_SQL_DIALECT and DOT_SQL_TOKEN_FILE:
##
## [codeblock]
## ../dot-sql/tools/test_live.sh . res://examples/moderation_sql_live.tscn
## [/codeblock]

const CHECKS := 10

var _passed := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)

	var dialect := DotSqlDialect.from_name(OS.get_environment("DOT_SQL_DIALECT"))
	var made := DotSql.from_config({
		"driver": "gateway",
		"url": OS.get_environment("DOT_SQL_URL"),
		"dialect": DotSqlDialect.name_of(dialect),
		"token": FileAccess.get_file_as_string(OS.get_environment("DOT_SQL_TOKEN_FILE")).strip_edges(),
	}, self)
	if not made.ok or made.value == null:
		print("set DOT_SQL_URL, DOT_SQL_DIALECT and DOT_SQL_TOKEN_FILE; see dot-sql/tools/test_live.sh")
		get_tree().quit(2)
		return

	var driver: DotSqlDriverGateway = made.value
	print("dot-moderation live: %s" % DotSqlDialect.name_of(dialect))

	# A clean table every run.
	await driver.open()
	await driver.execute("DROP TABLE IF EXISTS dot_punishments_live")
	await driver.execute("DELETE FROM dot_sql_migrations WHERE component = ?", ["dot_moderation:dot_punishments_live"])

	var store := DotPunishmentStoreSql.new(driver)
	store.table = "dot_punishments_live"

	var opened: DotResult = await store.open()
	_check("the store creates its table", opened.ok, opened)

	var ban := DotPunishment.create(DotPunishment.Kind.BAN, "uid:42", "cheating; said 'hi' 🙃", "admin:sarah", 86400)
	ban.evidence = {"demo": "r3.dem"}
	var put: DotResult = await store.put(ban)
	_check("a ban is written", put.ok, put)

	ban.revoked = true
	ban.revoked_by = "admin:tom"
	var again: DotResult = await store.put(ban)
	_check("writing it again updates rather than duplicates", again.ok, again)

	var mute := DotPunishment.create(DotPunishment.Kind.VOICE_MUTE, "uid:7", "mic spam", "admin:sarah", 600)
	await store.put(mute)

	var all: DotResult = await store.load_all()
	_check("both come back", all.ok and (all.value as Array).size() == 2, all)

	var mine: DotResult = await store.load_for("uid:42")
	var read: DotPunishment = (mine.value as Array)[0] if mine.ok and not (mine.value as Array).is_empty() else null
	_check("one subject's come back alone", mine.ok and (mine.value as Array).size() == 1, mine)
	_check("with the reason, quotes and all", read != null and read.reason == "cheating; said 'hi' 🙃")
	_check("revoked, as written the second time", read != null and read.revoked and read.revoked_by == "admin:tom")
	_check("and the evidence", read != null and read.evidence.get("demo", "") == "r3.dem")

	var removed: DotResult = await store.remove(ban.id)
	var after: DotResult = await store.load_for("uid:42")
	_check("a removal removes", removed.ok and after.ok and (after.value as Array).is_empty(), removed)

	var reopened: DotResult = await DotPunishmentStoreSql.new(driver).open()
	var reopened_store := DotPunishmentStoreSql.new(driver)
	reopened_store.table = "dot_punishments_live"
	var reopen: DotResult = await reopened_store.open()
	_check("opening an existing table again is harmless", reopened.ok and reopen.ok, reopen)

	print("%d passed, %d failed" % [_passed, _failed])
	await driver.execute("DROP TABLE IF EXISTS dot_punishments_live")
	get_tree().quit(1 if _failed > 0 or _passed + _failed != CHECKS else 0)


func _check(what: String, passed: bool, res: DotResult = null) -> void:
	if passed:
		_passed += 1
		print("  %-52s ok" % what)
		return
	_failed += 1
	var why := ""
	if res != null and not res.ok and res.error != null:
		why = " — %s (%s)" % [res.error.message, res.error.detail]
	print("  %-52s FAILED%s" % [what, why])
