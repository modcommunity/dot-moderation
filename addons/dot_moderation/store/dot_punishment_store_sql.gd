@tool
class_name DotPunishmentStoreSql
extends DotPunishmentStore

## Punishments in a real table, in whichever SQL a [DotSqlDriver] speaks.
##
## [codeblock]
## var store := DotPunishmentStoreSql.new(DotSqlDriverSqlite.new("user://moderation.db"))
## var opened := await store.open()      # creates the table if it is not there
## [/codeblock]
##
## Everything dialect-specific comes from [DotPunishmentSchema], so SQLite, Postgres and
## MySQL hold the same fourteen columns and this class contains no `if postgres` anywhere.
##
## [b]Statements are parameterised, always.[/b] A ban reason is typed by a moderator and
## half of them quote the name the offender was using, so it is exactly the string that
## must never reach SQL by concatenation. Nothing here builds a WHERE clause out of a
## value; [method DotPunishmentSchema.placeholder] is the only way a value gets in.

## Where statements go.
var driver: DotSqlDriver = null

## Table name, in case an operator already owns `punishments`.
var table: String = DotPunishmentSchema.DEFAULT_TABLE

## Create the table and indexes on [method open].
##
## On, because the statements are `IF NOT EXISTS` and an operator who made the table by
## hand is not fought with. Off for a deployment whose schema is managed by migrations
## and which would rather this touched nothing.
var create_schema: bool = true

## Diagnostics.
var loads: int = 0
var writes: int = 0


func _init(p_driver: DotSqlDriver = null) -> void:
	driver = p_driver


func store_name() -> String:
	return "sql/%s" % (driver.driver_name() if driver != null else "none")


func is_writable() -> bool:
	return driver != null and driver.is_open()


## Opens the driver and, unless told not to, creates the table.
func open() -> DotResult:
	if driver == null:
		return DotResult.fail(DotError.CODE_STATE, "No SQL driver.")

	var available := driver.is_available()
	if not available.ok:
		return available

	var opened: DotResult = await driver.open()
	if not opened.ok:
		return opened

	if not create_schema:
		return DotResult.success(true)

	var statements: Array = []
	for sql in DotPunishmentSchema.ddl(driver.dialect(), table):
		statements.append([sql, []])

	var created: DotResult = await driver.batch(statements)

	if not created.ok:
		return created.wrap("Could not create the punishment table.")

	# Recorded so a future build can refuse a database it does not understand rather than
	# reading columns that have changed meaning underneath it.
	var stamped: DotResult = await driver.execute(
		DotPunishmentSchema.upsert_meta(driver.dialect()),
		["schema_version", str(DotPunishmentSchema.SCHEMA_VERSION)]
	)

	if not stamped.ok:
		DotLog.warn(CHANNEL, "could not stamp the schema version", {
			"why": stamped.error.message
		})

	DotLog.info(CHANNEL, "punishment table ready", {
		"dialect": DotPunishmentSchema.dialect_name(driver.dialect()),
		"table": table,
	})

	return DotResult.success(true)


func close() -> void:
	if driver != null:
		driver.close()


func load_all() -> DotResult:
	if driver == null or not driver.is_open():
		return DotResult.fail(DotError.CODE_STATE, "The database is not open.")

	var result: DotResult = await driver.query(
		DotPunishmentSchema.select_all(table), []
	)

	if not result.ok:
		return result.wrap("Could not read the punishment table.")

	var loaded: Array[DotPunishment] = []
	var skipped := 0

	for row in (result.value as Array):
		var punishment := DotPunishmentSchema.from_row(row)

		if punishment == null:
			skipped += 1
			continue

		var valid := punishment.validate()

		if not valid.ok:
			# One bad row does not condemn the table, for the same reason one bad entry
			# does not condemn the JSON file: a community with fifty thousand records
			# and one hand-edited row should moderate with the rest and be told which.
			DotLog.warn(CHANNEL, "skipping an unusable row", {
				"why": valid.error.message, "id": punishment.id
			})
			skipped += 1
			continue

		loaded.append(punishment)

	loads += 1

	if skipped > 0:
		DotLog.warn(CHANNEL, "the punishment table had unusable rows", {
			"skipped": skipped, "loaded": loaded.size()
		})

	return DotResult.success(loaded)


## Reads only what is against one subject.
##
## [b]The one query a live server makes.[/b] `load_all` is a boot-time operation; this is
## what a join asks, while a player waits, and it is why `subject` is indexed. A
## deployment with a shared database uses this rather than caching everything, so a mute
## set on another server is in force here on the next connection rather than on the next
## restart.
func load_for(subject: String) -> DotResult:
	if driver == null or not driver.is_open():
		return DotResult.fail(DotError.CODE_STATE, "The database is not open.")

	var result: DotResult = await driver.query(
		DotPunishmentSchema.select_by_subject(driver.dialect(), table), [subject]
	)

	if not result.ok:
		return result.wrap("Could not read punishments for a player.")

	var loaded: Array[DotPunishment] = []

	for row in (result.value as Array):
		var punishment := DotPunishmentSchema.from_row(row)
		if punishment != null and punishment.validate().ok:
			loaded.append(punishment)

	return DotResult.success(loaded)


func put(punishment: DotPunishment) -> DotResult:
	if punishment == null:
		return DotResult.fail(DotError.CODE_INVALID, "No punishment to store.")

	var valid := punishment.validate()
	if not valid.ok:
		return valid

	if driver == null or not driver.is_open():
		return DotResult.fail(DotError.CODE_STATE, "The database is not open.")

	# An upsert, not an insert. A retry after a network failure must not produce two
	# records for one action, which is how a duplicate ban ends up in somebody's history
	# and how a revoke ends up applying to only one of them.
	var result: DotResult = await driver.execute(
		DotPunishmentSchema.upsert(driver.dialect(), table),
		DotPunishmentSchema.to_row(punishment)
	)

	if not result.ok:
		return result.wrap("Could not write the punishment.")

	writes += 1
	return DotResult.success(true)


func remove(id: String) -> DotResult:
	if driver == null or not driver.is_open():
		return DotResult.fail(DotError.CODE_STATE, "The database is not open.")

	var result: DotResult = await driver.execute(
		DotPunishmentSchema.delete_by_id(driver.dialect(), table), [id]
	)

	if not result.ok:
		return result.wrap("Could not remove the punishment.")

	writes += 1
	return DotResult.success(true)


func describe() -> Dictionary:
	return {
		"store": store_name(),
		"writable": is_writable(),
		"table": table,
		"dialect": DotPunishmentSchema.dialect_name(
			driver.dialect() if driver != null else DotPunishmentSchema.Dialect.SQLITE
		),
		"loads": loads,
		"writes": writes,
		"driver": driver.describe() if driver != null else {},
	}
