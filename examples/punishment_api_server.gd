extends Node

## A punishment API in a hundred lines, so [DotPunishmentStoreRest] is tested for real.
##
## [b]Why this exists.[/b] The REST store is the one a community actually reaches for,
## because most of them already have a ban system and are not going to migrate it. It is
## also the one with the most that can go wrong on the wire: a missing key, a 500, a body
## that is not JSON, an auth header that is not checked. Every one of those is a code path
## in the store, and a mock object would exercise none of them.
##
## Serving from GDScript rather than shelling out keeps the suite self-contained: no
## Python, no Docker, nothing to install, and it runs headless anywhere the engine runs.
## Same reasoning as dot-cloud's static file server, which is where this pattern comes
## from.
##
## It is deliberately not production code and does not live in `addons/`. It speaks
## exactly as much HTTP as [DotHttp] asks for, and every fault it can inject exists
## because a branch in the store needs it.

## id -> punishment dictionary. The API's whole database.
var records: Dictionary = {}

## Port actually bound. Read after [method start].
var port: int = 0

## Required in the Authorization header. Empty accepts anything.
var require_token: String = ""

## Answer everything with 500.
var fail_all: bool = false

## Answer a read with a body that is not JSON at all.
var serve_garbage: bool = false

## Answer a read with valid JSON that has no "punishments" key.
var serve_wrong_shape: bool = false

## Every request line handled, for assertions about what the store actually sent.
var log: PackedStringArray = PackedStringArray()

var _server: TCPServer = null
var _clients: Array[Dictionary] = []


func start(requested_port: int = 0) -> DotResult:
	_server = TCPServer.new()

	var error := _server.listen(requested_port, "127.0.0.1")

	if error != OK:
		return DotResult.failure(DotError.from_engine(error, "listen"))

	port = _server.get_local_port()
	set_process(true)

	return DotResult.success(port)


func base_url() -> String:
	return "http://127.0.0.1:%d" % port


func stop() -> void:
	set_process(false)
	if _server != null:
		_server.stop()
	_server = null
	_clients.clear()


func _exit_tree() -> void:
	stop()


func _process(_delta: float) -> void:
	if _server == null:
		return

	while _server.is_connection_available():
		_clients.append({"peer": _server.take_connection(), "buffer": ""})

	var still: Array[Dictionary] = []

	for client in _clients:
		if _pump(client):
			still.append(client)

	_clients = still


## Reads one request, including its body, and answers it.
##
## [b]The body matters here and does not in a static file server.[/b] A PUT carries the
## record, so the request is not complete at the blank line: it is complete at the blank
## line plus Content-Length bytes. Answering early gives the client a response to a
## request the server has not finished reading, which presents as an intermittent
## failure on exactly the payloads that are large enough to be split across packets.
func _pump(client: Dictionary) -> bool:
	var peer: StreamPeerTCP = client["peer"]
	peer.poll()

	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return false

	var available := peer.get_available_bytes()

	if available > 0:
		var chunk := peer.get_data(available)
		if chunk[0] == OK:
			client["buffer"] = str(client["buffer"]) + (chunk[1] as PackedByteArray).get_string_from_utf8()

	var buffer := str(client["buffer"])
	var header_end := buffer.find("\r\n\r\n")

	if header_end < 0:
		return true

	var head := buffer.substr(0, header_end)
	var body := buffer.substr(header_end + 4)

	var content_length := 0
	for line in head.split("\r\n"):
		if line.to_lower().begins_with("content-length:"):
			content_length = line.split(":")[1].strip_edges().to_int()

	if body.length() < content_length:
		return true

	_respond(peer, head, body.substr(0, content_length))
	peer.disconnect_from_host()
	return false


func _respond(peer: StreamPeerTCP, head: String, body: String) -> void:
	var lines := head.split("\r\n")
	var parts := lines[0].split(" ")

	if parts.size() < 2:
		_send(peer, 400, {"error": "bad request"})
		return

	var method := parts[0]
	var target := parts[1]

	log.append("%s %s" % [method, target])

	if require_token != "":
		var supplied := ""
		for line in lines:
			if line.to_lower().begins_with("authorization:"):
				supplied = line.split(":", true, 1)[1].strip_edges()
		if supplied != require_token:
			_send(peer, 401, {"error": "unauthorized"})
			return

	if fail_all:
		_send(peer, 500, {"error": "the database is on fire"})
		return

	var path := target
	var query := ""
	var q := target.find("?")
	if q >= 0:
		path = target.substr(0, q)
		query = target.substr(q + 1)

	if not path.begins_with("/punishments"):
		_send(peer, 404, {"error": "no such resource"})
		return

	var id := path.trim_prefix("/punishments").trim_prefix("/").uri_decode()

	match method:
		"GET":
			if serve_garbage:
				_send_raw(peer, 200, "this is not json at all")
				return
			if serve_wrong_shape:
				_send(peer, 200, {"data": []})
				return

			var subject := ""
			for pair in query.split("&"):
				var kv := pair.split("=")
				if kv.size() == 2 and kv[0] == "subject":
					subject = kv[1].uri_decode()

			var out: Array = []
			for key in records.keys():
				var record: Dictionary = records[key]
				if subject == "" or str(record.get("subject", "")) == subject:
					out.append(record)

			_send(peer, 200, {"punishments": out})

		"PUT":
			var parsed: Variant = JSON.parse_string(body)
			if not (parsed is Dictionary):
				_send(peer, 400, {"error": "body is not an object"})
				return
			var record: Dictionary = parsed
			# Keyed by the id in the URL rather than the one in the body, so a store
			# that PUTs to a stable URL really is idempotent.
			records[id] = record
			_send(peer, 200, {"ok": true})

		"DELETE":
			records.erase(id)
			_send(peer, 200, {"ok": true})

		_:
			_send(peer, 405, {"error": "method not allowed"})


func _send(peer: StreamPeerTCP, status: int, document: Dictionary) -> void:
	_send_raw(peer, status, JSON.stringify(document))


func _send_raw(peer: StreamPeerTCP, status: int, body: String) -> void:
	var payload := body.to_utf8_buffer()
	var header := "HTTP/1.1 %d %s\r\n" % [status, "OK" if status < 400 else "Error"]
	header += "Content-Type: application/json\r\n"
	header += "Content-Length: %d\r\n" % payload.size()
	header += "Connection: close\r\n\r\n"

	peer.put_data(header.to_utf8_buffer())
	peer.put_data(payload)
