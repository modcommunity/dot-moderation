@tool
class_name DotPunishmentStoreRest
extends DotPunishmentStore

## Punishments from somebody else's ban system, over HTTP.
##
## [b]This is the one to reach for when a community already has a ban system.[/b] Most do:
## a web panel, a chat bot, an admin-plugin database with ten years of history in it.
## None
## of that should be migrated to make a Godot addon happy, and none of it needs to be. The
## contract below is four endpoints, and a server that speaks them keeps its own storage,
## its own appeal workflow and its own admin interface.
##
## It is also the answer for PostgreSQL and MySQL, which Godot cannot speak: put the
## database behind this rather than putting its password on every game server. See
## [DotSqlDriverGateway] for why that is the better shape anyway.
##
## [codeblock]
## GET    {base}/punishments                  -> {"punishments": [ {...}, ... ]}
## GET    {base}/punishments?subject=uid:123  -> the same, filtered
## PUT    {base}/punishments/{id}             <- one record   -> {"ok": true}
## DELETE {base}/punishments/{id}                             -> {"ok": true}
## [/codeblock]
##
## A record is the same JSON [method DotPunishment.to_dictionary] produces, which is the
## same shape the file store writes. One format for all three backends, so a community can
## move between them by changing one line.
##
## [b]The read path is what has to be right.[/b] A failure here must never look like "no
## punishments": that readmits everybody who was ever removed, silently, which is the
## worst failure this addon has. Every error path returns a failure and
## [DotModerationManager] keeps whatever it already had.

## Where the API lives, without a trailing slash.
var base_url: String = ""

## Sent as the `Authorization` header on every request.
##
## Never logged and never in [method describe]. Same rule as `DotConfig.sensitive_keys`:
## a credential that reaches a pasted bug report is a credential that has to be rotated.
var token: String = ""

## Path under [member base_url]. Some deployments mount this under an existing API.
var resource_path: String = "/punishments"

## Whether this server may write. Off for a deployment where bans are issued on a website
## and a game server only enforces them.
var writable: bool = true

## Seconds a request may take. Short, because this is on the join path.
var timeout_sec: float = 10.0

## The HTTP client. Must be in the tree, because [HTTPRequest] is a [Node].
var http: DotHttp = null

## Diagnostics.
var loads: int = 0
var writes: int = 0
var failures: int = 0


func _init(p_base_url: String = "", p_http: DotHttp = null) -> void:
	base_url = p_base_url
	http = p_http


func store_name() -> String:
	return "rest"


func is_writable() -> bool:
	return writable


func _headers() -> Dictionary:
	var headers := {}
	if token != "":
		headers["Authorization"] = token
	return headers


func _url(suffix: String = "") -> String:
	return "%s%s%s" % [base_url.trim_suffix("/"), resource_path, suffix]


func _ready_to_call() -> DotResult:
	if base_url.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "A REST punishment store needs a base_url."
		)

	if http == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"A REST punishment store needs a DotHttp.",
			"it must be in the scene tree, because HTTPRequest is a Node"
		)

	return DotResult.success(true)


func load_all() -> DotResult:
	return await _load(_url())


## Reads only what is against one subject.
##
## What a live server asks on the join path. A deployment with a shared API uses this
## rather than pulling the whole list, so a ban issued on the website is in force here on
## the next connection rather than on the next restart.
func load_for(subject: String) -> DotResult:
	return await _load("%s?subject=%s" % [_url(), subject.uri_encode()])


func _load(url: String) -> DotResult:
	var ready := _ready_to_call()
	if not ready.ok:
		return ready

	var response := await http.get_json(url, _headers())

	if not response.ok:
		failures += 1
		# Wrapped rather than swallowed. The caller keeps what it had, which is the whole
		# reason this returns a failure instead of an empty list.
		return response.wrap("Could not read punishments from the API.")

	# [b]`get_json` hands back the parsed body itself, not a wrapper around it.[/b]
	# Reaching for `.value["json"]` produced null on every successful read, which the
	# check below then reported as "the API did not return an object" — a failure that
	# blames the far end for something on this side. The suite caught it because it runs
	# against a real HTTP server rather than a mock that returns whatever was assumed.
	var body: Variant = response.value

	if not (body is Dictionary):
		failures += 1
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The punishment API did not return an object.",
			url
		)

	var document: Dictionary = body

	# [b]The key has to be PRESENT, not merely default to an empty array.[/b] Written as
	# `document.get("punishments", [])` this accepted any JSON object at all: a response
	# with a different shape, a paginated envelope, an error body that happened to be
	# 200, all of them fell through to an empty list and were reported as a successful
	# read of nothing. Which means nobody is banned. This is the single worst failure
	# this addon has and it was one default argument away.
	if not document.has("punishments"):
		failures += 1
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The punishment API returned no 'punishments' key.",
			"got keys: %s" % ", ".join(PackedStringArray(document.keys()))
		)

	var entries: Variant = document["punishments"]

	if not (entries is Array):
		failures += 1
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The punishment API's 'punishments' is not an array.",
			"got %s" % type_string(typeof(entries))
		)

	var loaded: Array[DotPunishment] = []
	var skipped := 0

	for entry in (entries as Array):
		if not (entry is Dictionary):
			skipped += 1
			continue

		var punishment := DotPunishment.from_dictionary(entry as Dictionary)
		var valid := punishment.validate()

		if not valid.ok:
			# One bad record does not condemn the response, for the same reason one bad
			# line does not condemn the file. The API is somebody else's software and it
			# will have a row this build does not like.
			DotLog.warn(CHANNEL, "skipping an unusable record from the API", {
				"why": valid.error.message
			})
			skipped += 1
			continue

		loaded.append(punishment)

	loads += 1

	if skipped > 0:
		DotLog.warn(CHANNEL, "the punishment API returned unusable records", {
			"skipped": skipped, "loaded": loaded.size()
		})

	return DotResult.success(loaded)


func put(punishment: DotPunishment) -> DotResult:
	if punishment == null:
		return DotResult.fail(DotError.CODE_INVALID, "No punishment to store.")

	var valid := punishment.validate()
	if not valid.ok:
		return valid

	if not writable:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"This punishment API is read only from here.",
			"issued centrally; this server enforces rather than adds"
		)

	var ready := _ready_to_call()
	if not ready.ok:
		return ready

	# PUT to the record's own URL rather than POST to the collection, so a retry after a
	# timeout cannot create a second record. The id is generated here and is stable, which
	# is what makes the write idempotent.
	var response := await http.put_json(
		_url("/%s" % punishment.id.uri_encode()),
		punishment.to_dictionary(),
		_headers()
	)

	if not response.ok:
		failures += 1
		return response.wrap("The punishment API refused the record.")

	writes += 1
	return DotResult.success(true)


func remove(id: String) -> DotResult:
	if not writable:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "This punishment API is read only from here."
		)

	var ready := _ready_to_call()
	if not ready.ok:
		return ready

	var response := await http.request(
		HTTPClient.METHOD_DELETE,
		_url("/%s" % id.uri_encode()),
		PackedByteArray(),
		_headers()
	)

	if not response.ok:
		failures += 1
		return response.wrap("The punishment API would not remove the record.")

	writes += 1
	return DotResult.success(true)


func describe() -> Dictionary:
	return {
		"store": store_name(),
		"writable": writable,
		"base_url": base_url,
		# Never the token itself.
		"authenticated": token != "",
		"loads": loads,
		"writes": writes,
		"failures": failures,
	}
