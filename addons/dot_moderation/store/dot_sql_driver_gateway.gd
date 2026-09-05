@tool
class_name DotSqlDriverGateway
extends DotSqlDriver

## PostgreSQL and MySQL, through a small HTTP gateway you run beside the database.
##
## [b]Read this before reaching for it, because the honest answer is uncomfortable.[/b]
## Godot has no PostgreSQL or MySQL client, and neither protocol can be spoken from
## GDScript without implementing an authentication handshake (SCRAM-SHA-256 for one,
## `caching_sha2_password` for the other), a binary wire format and a connection pool.
## That is a project, not a file, and a half-finished one is a security problem rather
## than a missing feature.
##
## So there are exactly two honest ways to put punishments in Postgres or MySQL from
## Godot, and this addon supports both:
##
## 1. [b]Install a GDExtension[/b] that speaks the protocol, and write a [DotSqlDriver]
##    for it. Twenty lines, following [DotSqlDriverSqlite]. The dialect handling,
##    the DDL and the row mapping are already done.
## 2. [b]Put the database behind HTTP[/b], which is this class. A dozen lines of PHP,
##    Go or Node beside the database accepts a statement and its bound parameters and
##    returns rows. It is what a community running a web panel usually has already, and
##    it keeps the database credentials off every game server.
##
## [b]The second is what most deployments should do anyway.[/b] A game server holding a
## Postgres password is a game server whose compromise is a compromise of the database;
## a gateway can be scoped to one table and one set of statements.
##
## Prefer [DotPunishmentStoreRest] when the far end can speak in punishments rather than
## in SQL: it is a smaller contract with less to get wrong. This exists for the case where
## somebody already has a SQL gateway and wants the schema handled here.
##
## [codeblock]
## POST {base_url}/query
##   { "sql": "SELECT ...", "params": [...], "dialect": "postgres" }
## -> { "rows": [ { "id": "...", ... } ] }        200
## -> { "error": "..." }                          4xx / 5xx
## [/codeblock]

## Where the gateway lives, without a trailing slash.
var base_url: String = ""

## Sent as `Authorization`. Kept out of logs; see [method describe].
var token: String = ""

## Which database is on the far side, so the right SQL is generated.
var sql_dialect: DotPunishmentSchema.Dialect = DotPunishmentSchema.Dialect.POSTGRES

var http: DotHttp = null

var _open: bool = false


func _init(
	p_base_url: String = "",
	p_dialect: DotPunishmentSchema.Dialect = DotPunishmentSchema.Dialect.POSTGRES
) -> void:
	base_url = p_base_url
	sql_dialect = p_dialect


func dialect() -> DotPunishmentSchema.Dialect:
	return sql_dialect


func driver_name() -> String:
	return "gateway/%s" % DotPunishmentSchema.dialect_name(sql_dialect)


func is_available() -> DotResult:
	if base_url.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "A SQL gateway driver needs a base_url."
		)
	return DotResult.success(true)


func open() -> DotResult:
	var available := is_available()
	if not available.ok:
		return available

	if http == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"A SQL gateway driver needs a DotHttp.",
			"it must be in the scene tree, because HTTPRequest is a Node"
		)

	_open = true
	return DotResult.success(true)


func close() -> void:
	_open = false


func is_open() -> bool:
	return _open


func execute(sql: String, params: Array = []) -> DotResult:
	var result := await _post(sql, params)
	return result if not result.ok else DotResult.success(true)


func query(sql: String, params: Array = []) -> DotResult:
	return await _post(sql, params)


func _post(sql: String, params: Array) -> DotResult:
	if not _open or http == null:
		return DotResult.fail(DotError.CODE_STATE, "The gateway is not open.")

	var headers := {}
	if token != "":
		headers["Authorization"] = token

	var response := await http.post_json(
		"%s/query" % base_url.trim_suffix("/"),
		{
			"sql": sql,
			"params": params,
			"dialect": DotPunishmentSchema.dialect_name(sql_dialect),
		},
		headers
	)

	if not response.ok:
		return response.wrap("The SQL gateway did not answer.")

	# post_json returns the parsed body, not a wrapper around it. See the same note in
	# DotPunishmentStoreRest.
	var body: Variant = response.value

	if not (body is Dictionary):
		return DotResult.fail(
			DotError.CODE_INVALID, "The SQL gateway did not return an object."
		)

	var document: Dictionary = body

	if document.has("error"):
		return DotResult.fail(
			DotError.CODE_IO,
			"The SQL gateway refused a statement.",
			str(document["error"])
		)

	var rows: Variant = document.get("rows", [])

	return DotResult.success(rows if rows is Array else [])


func describe() -> Dictionary:
	var out := super.describe()
	out["base_url"] = base_url
	# Never the token. The one field here that must not reach a log or a pasted bug
	# report, which is the same rule DotConfig.sensitive_keys enforces.
	out["authenticated"] = token != ""
	return out
