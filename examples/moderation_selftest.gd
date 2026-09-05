extends Node

## Proves punishments persist, expire, respect immunity, and are actually consulted.
##
## [codeblock]
## godot --headless --path . res://examples/moderation_selftest.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]The section that matters most is the last one.[/b] Everything before it checks this
## addon against itself, which is the kind of testing that has never once found a bug in
## this family. The last one connects a real [DotVoiceRouter] to a real
## [DotModerationManager] through the registry and asks whether a muted player is actually
## silenced, because "the two ends have never met" is how every expensive bug here has
## started: dot-map calling `ensure` on a client that offered `acquire`, the leaderboard
## reporter sending its file format as the wire, four call sites all finding a null cloud
## client and none of them erroring.

const DATA := "user://dot_moderation_selftest"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-moderation self-test")

	DotPaths.remove_tree(DATA)

	_test_record()
	_test_durations()
	await _test_issue_and_ask()
	await _test_expiry()
	await _test_revoke()
	await _test_immunity()
	await _test_persistence()
	await _test_store_refusals()
	await _test_scope()
	await _test_address_bans()
	await _test_voice_actually_asks()
	_test_schema()
	await _test_sql_store()
	await _test_rest_store()
	await _test_mod_tools()

	DotPaths.remove_tree(DATA)

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


# --- Harness ---------------------------------------------------------------

func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


func _manager(path: String = "", scope: String = "") -> DotModerationManager:
	var manager := DotModerationManager.new()
	manager.store = DotPunishmentStoreFile.new(
		path if path != "" else DATA.path_join("m.json")
	)
	manager.server_scope = scope
	# Off by default in the tests so two managers in one process do not fight over the
	# registry name. The section that needs it turns it on.
	manager.register_mute_source = false
	manager.register_ban_source = false
	add_child(manager)
	return manager


# --- Sections --------------------------------------------------------------

func _test_record() -> void:
	_section("a punishment is a record, not a flag")

	var mute := DotPunishment.create(
		DotPunishment.Kind.VOICE_MUTE, "uid:1", "mic spam", "admin:sarah", 3600
	)

	_check(mute.validate().ok, "a well-formed punishment validates")
	_check(mute.id != "", "and gets an id, so a revoke can name one record")
	_check(mute.is_active(), "it is in force")
	_check(not mute.is_permanent(), "and is not permanent")
	_check(mute.remaining() > 3500, "with time left (%d)" % mute.remaining())

	var forever := DotPunishment.create(DotPunishment.Kind.BAN, "uid:2", "cheating")
	_check(forever.is_permanent(), "a zero duration is permanent")
	_check(
		forever.remaining() == -1,
		"and reports -1 rather than 0",
		"0 would read as expired, which is the bug that lets everybody back in"
	)
	_check(forever.is_active(), "and is in force")

	# A kick is an event. It happened; it is not still happening, and a kick that read as
	# active would keep a player out for ever.
	var kick := DotPunishment.create(DotPunishment.Kind.KICK, "uid:3", "afk")
	_check(not kick.is_active(), "a kick is history rather than a state")
	var warn := DotPunishment.create(DotPunishment.Kind.WARN, "uid:3", "language")
	_check(not warn.is_active(), "and so is a warning")

	var nameless := DotPunishment.create(DotPunishment.Kind.BAN, "", "no subject")
	_check(not nameless.validate().ok, "a punishment against nobody is refused")

	var backwards := DotPunishment.create(DotPunishment.Kind.BAN, "uid:4", "x")
	backwards.expires_at = backwards.issued_at - 10
	_check(
		not backwards.validate().ok,
		"and one that expires before it was issued"
	)

	# The player-facing message must never name the moderator: that is how a moderator
	# gets harassed, and it is not information a player needs in order to appeal.
	var message := mute.player_message()
	_check(message.contains("mic spam"), "the player is told why (%s)" % message)
	_check(not message.contains("sarah"), "and not by whom")

	# A Dictionary is a reference in GDScript, and this family has shipped that bug more
	# than once: every scoped leaderboard and the template it came from were one object.
	mute.evidence = {"demo": "round3.dem"}
	var dict := mute.to_dictionary()
	(dict["evidence"] as Dictionary)["demo"] = "tampered"
	_check(
		str(mute.evidence["demo"]) == "round3.dem",
		"to_dictionary hands out a copy of its evidence, not the original"
	)

	var back := DotPunishment.from_dictionary(mute.to_dictionary())
	_check(back.id == mute.id, "a record round-trips its id")
	_check(back.kind == mute.kind, "its kind (%s)" % DotPunishment.kind_name(back.kind))
	_check(back.subject == mute.subject and back.reason == mute.reason, "and its content")
	_check(back.expires_at == mute.expires_at, "and its expiry")
	_done()


func _test_durations() -> void:
	_section("durations a person reads")

	_check(DotPunishment.format_duration(45) == "45s", "seconds")
	_check(DotPunishment.format_duration(90) == "1m", "minutes")
	_check(DotPunishment.format_duration(3700).begins_with("1h"), "hours")
	_check(DotPunishment.format_duration(90000).begins_with("1d"), "days")
	_check(DotPunishment.format_duration(0) == "0s", "and zero does not crash")
	_done()


func _test_issue_and_ask() -> void:
	_section("issuing, and the questions a server asks")

	var manager := _manager()
	await get_tree().process_frame
	await manager.load_all()

	var issued: DotResult = await manager.issue(
		DotPunishment.Kind.VOICE_MUTE, "uid:1", "mic spam", "admin:sarah", 600
	)
	_check(issued.ok, "a mute is issued", str(issued.error))

	_check(manager.is_voice_muted_key("uid:1"), "and the player is voice muted")
	_check(not manager.is_gagged_key("uid:1"), "but not gagged")
	_check(not manager.is_banned_key("uid:1"), "and not banned")
	_check(not manager.is_voice_muted_key("uid:2"), "and nobody else is muted")

	await manager.issue(DotPunishment.Kind.GAG, "uid:1", "spam", "admin:sarah", 600)
	_check(manager.is_gagged_key("uid:1"), "a gag is a separate record")
	_check(
		manager.active_for("uid:1").size() == 2,
		"so a player can hold both at once (%d)" % manager.active_for("uid:1").size()
	)

	await manager.issue(DotPunishment.Kind.WARN, "uid:1", "first warning")
	_check(
		manager.active_for("uid:1").size() == 2,
		"a warning enforces nothing"
	)
	_check(
		manager.history_for("uid:1").size() == 3,
		"but is on the history (%d)" % manager.history_for("uid:1").size(),
		"which is what makes the next decision defensible"
	)

	var found := manager.search("mic")
	_check(found.size() == 1, "records are searchable by reason (%d)" % found.size())

	var nobody: DotResult = await manager.issue(DotPunishment.Kind.BAN, "  ", "x")
	_check(not nobody.ok, "a punishment against nobody is refused")

	manager.queue_free()
	await get_tree().process_frame
	_done()


func _test_expiry() -> void:
	_section("expiry is answered on read, never swept")

	var manager := _manager(DATA.path_join("expiry.json"))
	await get_tree().process_frame
	await manager.load_all()

	await manager.issue(
		DotPunishment.Kind.VOICE_MUTE, "uid:9", "short", "console", 3600
	)
	_check(manager.is_voice_muted_key("uid:9"), "a mute is in force")

	# Reached into rather than waited for: a test that slept an hour is a test nobody
	# runs. What is being checked is that the READ notices, which is the whole design.
	var record := manager.active_of_kind("uid:9", DotPunishment.Kind.VOICE_MUTE)
	record.expires_at = int(Time.get_unix_time_from_system()) - 1

	var noticed := [false]
	manager.expired.connect(func(_p: DotPunishment) -> void: noticed[0] = true)

	_check(
		not manager.is_voice_muted_key("uid:9"),
		"and stops being in force the moment it expires",
		"a sweep on a timer means a server that was off overnight enforces yesterday"
	)
	_check(noticed[0], "the expiry is announced")
	_check(
		manager.history_for("uid:9").size() == 1,
		"and the record stays on the history"
	)

	manager.queue_free()
	await get_tree().process_frame
	_done()


func _test_revoke() -> void:
	_section("lifting a punishment keeps the record")

	var manager := _manager(DATA.path_join("revoke.json"))
	await get_tree().process_frame
	await manager.load_all()

	var issued: DotResult = await manager.issue(
		DotPunishment.Kind.VOICE_MUTE, "uid:5", "mic spam", "admin:sarah", 600
	)
	var punishment: DotPunishment = issued.value

	var lifted: DotResult = await manager.revoke(punishment.id, "admin:tom", "appealed")
	_check(lifted.ok, "a mute is lifted", str(lifted.error))
	_check(not manager.is_voice_muted_key("uid:5"), "and the player can speak")
	_check(
		manager.history_for("uid:5").size() == 1,
		"the record is kept rather than deleted",
		"the history is the point"
	)
	_check(punishment.revoked_by == "admin:tom", "with who lifted it")
	_check(punishment.revoke_reason == "appealed", "and why")

	var again: DotResult = await manager.revoke(punishment.id, "admin:tom")
	_check(not again.ok, "lifting it twice is refused")

	var missing: DotResult = await manager.revoke("nope", "admin:tom")
	_check(not missing.ok, "and so is lifting one that does not exist")

	# What `unmute <player>` calls, which is the shape a console command wants.
	await manager.issue(DotPunishment.Kind.VOICE_MUTE, "uid:6", "a", "console", 600)
	await manager.issue(DotPunishment.Kind.VOICE_MUTE, "uid:6", "b", "console", 600)
	var all: DotResult = await manager.revoke_all(
		"uid:6", DotPunishment.Kind.VOICE_MUTE, "console"
	)
	_check(all.ok and int(all.value) == 2, "every active mute can be lifted at once")
	_check(not manager.is_voice_muted_key("uid:6"), "and the player can speak")

	var nothing: DotResult = await manager.revoke_all(
		"uid:7", DotPunishment.Kind.VOICE_MUTE, "console"
	)
	_check(not nothing.ok, "lifting nothing says so rather than reporting success")

	manager.queue_free()
	await get_tree().process_frame
	_done()


func _test_immunity() -> void:
	_section("immunity, in both directions")

	var manager := _manager(DATA.path_join("immunity.json"))
	await get_tree().process_frame
	await manager.load_all()

	# A senior mutes somebody.
	var senior: DotResult = await manager.issue(
		DotPunishment.Kind.VOICE_MUTE, "uid:8", "spam", "admin:senior", 600, 80
	)
	_check(senior.ok, "a senior moderator issues a mute")

	# A junior cannot undo it. This is the half of immunity that usually gets left out,
	# and without it a junior can quietly reverse every decision above them.
	var junior: DotResult = await manager.revoke(
		(senior.value as DotPunishment).id, "admin:junior", "", 10
	)
	_check(
		not junior.ok,
		"a junior cannot lift it",
		"immunity is about who may be acted on, not only who may act"
	)

	var higher: DotResult = await manager.revoke(
		(senior.value as DotPunishment).id, "admin:root", "", 100
	)
	_check(higher.ok, "somebody above them can")

	# Equal cannot act on equal. Two moderators at the same level muting each other in a
	# loop has no correct resolution, so it is forbidden rather than raced.
	await manager.issue(
		DotPunishment.Kind.VOICE_MUTE, "uid:11", "spam", "admin:a", 600, 50
	)
	var equal: DotResult = await manager.issue(
		DotPunishment.Kind.GAG, "uid:11", "more", "admin:b", 600, 50
	)
	_check(not equal.ok, "equal immunity cannot act on equal by default")

	manager.equal_immunity_may_act = true
	var permitted: DotResult = await manager.issue(
		DotPunishment.Kind.GAG, "uid:11", "more", "admin:b", 600, 50
	)
	_check(permitted.ok, "unless a community says otherwise")

	manager.queue_free()
	await get_tree().process_frame
	_done()


func _test_persistence() -> void:
	_section("the whole reason this exists: a mute survives a reconnect")

	var path := DATA.path_join("persist.json")

	var first := _manager(path)
	await get_tree().process_frame
	await first.load_all()
	await first.issue(
		DotPunishment.Kind.VOICE_MUTE, "uid:99", "mic spam", "admin:sarah", 3600
	)
	_check(first.is_voice_muted_key("uid:99"), "a player is muted")
	first.queue_free()
	await get_tree().process_frame

	# A different manager reading the same file is what "they reconnected", "the server
	# restarted" and "they joined the other server" all look like from here.
	var second := _manager(path)
	await get_tree().process_frame
	var loaded: DotResult = await second.load_all()

	_check(loaded.ok, "a second server loads the same list", str(loaded.error))
	_check(
		second.is_voice_muted_key("uid:99"),
		"and the player is STILL muted",
		"dot-server's mute is a boolean on a session object, so it is gone the moment "
		+ "they disconnect. That is the complaint this addon exists to answer."
	)

	var record := second.active_of_kind("uid:99", DotPunishment.Kind.VOICE_MUTE)
	_check(record != null and record.reason == "mic spam", "with the reason intact")
	_check(record != null and record.remaining() > 3500, "and the time left")

	second.queue_free()
	await get_tree().process_frame
	_done()


func _test_store_refusals() -> void:
	_section("what the store refuses, and what it keeps")

	var path := DATA.path_join("broken.json")
	DotPaths.write_text(path, "this is not json")

	var store := DotPunishmentStoreFile.new(path)
	var loaded: DotResult = await store.load_all()
	_check(
		not loaded.ok,
		"a corrupt file is a loud failure",
		"silently meaning nobody is punished turns a typo into an unmoderated server"
	)

	# And the manager keeps what it already had rather than clearing.
	var manager := _manager(DATA.path_join("keep.json"))
	await get_tree().process_frame
	await manager.load_all()
	await manager.issue(DotPunishment.Kind.BAN, "uid:20", "cheating", "console")
	_check(manager.is_banned_key("uid:20"), "a ban is in force")

	manager.store = DotPunishmentStoreFile.new(path)
	var failed: DotResult = await manager.load_all()
	_check(not failed.ok, "a failed reload reports the failure")
	_check(
		manager.is_banned_key("uid:20"),
		"and keeps what was already in force",
		"starting empty on a read error readmits everybody who was ever removed"
	)

	# One bad entry does not condemn the file.
	var mixed := DATA.path_join("mixed.json")
	DotPaths.write_text(mixed, JSON.stringify({
		"format_version": 1,
		"punishments": [
			{"id": "a", "kind": "ban", "subject": "uid:30", "reason": "ok",
			 "issued_at": 1, "expires_at": 0},
			{"id": "", "kind": "ban", "subject": "", "reason": "broken"},
			{"id": "c", "kind": "mute", "subject": "uid:31", "reason": "ok",
			 "issued_at": 1, "expires_at": 0},
		],
	}))
	var partial: DotResult = await DotPunishmentStoreFile.new(mixed).load_all()
	_check(partial.ok, "a file with one bad entry still loads")
	_check(
		partial.ok and (partial.value as Array).size() == 2,
		"with the good ones (%d)" % ((partial.value as Array).size() if partial.ok else -1)
	)

	# A read-only store is a legitimate configuration, said plainly.
	var readonly := _manager(DATA.path_join("ro.json"))
	await get_tree().process_frame
	readonly.store = DotPunishmentStore.new()
	var refused: DotResult = await readonly.issue(
		DotPunishment.Kind.BAN, "uid:40", "x", "console"
	)
	_check(
		not refused.ok,
		"a read-only store refuses rather than pretending",
		"appearing to work and losing the record on the next refresh is worse"
	)
	_check(not readonly.is_banned_key("uid:40"), "and nothing is applied locally")

	manager.queue_free()
	readonly.queue_free()
	await get_tree().process_frame
	_done()


func _test_scope() -> void:
	_section("a community with more than one server")

	var path := DATA.path_join("scope.json")

	var surf := _manager(path, "surf")
	await get_tree().process_frame
	await surf.load_all()
	await surf.issue(DotPunishment.Kind.VOICE_MUTE, "uid:50", "spam", "console", 600)
	_check(surf.is_voice_muted_key("uid:50"), "a mute applies on the server that set it")
	surf.queue_free()
	await get_tree().process_frame

	var dm := _manager(path, "deathmatch")
	await get_tree().process_frame
	await dm.load_all()
	_check(
		not dm.is_voice_muted_key("uid:50"),
		"and not on a server with a different scope",
		"a surf mute need not be a deathmatch mute"
	)

	var everywhere := _manager(path, "")
	await get_tree().process_frame
	await everywhere.load_all()
	_check(
		everywhere.is_voice_muted_key("uid:50"),
		"a server with no scope sees every punishment"
	)

	dm.queue_free()
	everywhere.queue_free()
	await get_tree().process_frame
	_done()


## The join, run rather than assumed.
##
## [b]This is the section that would have caught every expensive bug in this family.[/b]
## dot-voice's router calls `is_voice_muted(peer)` on whatever it finds in [DotRegistry]
## under `dot_mute_source`. This manager publishes itself there and answers that method.
## Neither addon imports the other, which is the family rule and is also exactly the
## shape that has already produced: dot-map calling `ensure` on a client that only had
## `acquire`, a leaderboard reporter sending its file format where the backbone expected
## a schema, and four call sites all finding a null cloud client without one of them
## erroring.
##
## Reading the two sides next to each other is cheaper than a socket and has found more
## bugs here than any other technique. This runs them.
func _test_address_bans() -> void:
	_section("banning a machine rather than a person")

	# How a subject is spelled decides whether the two ends ever meet. A ban filed
	# against "1.2.3.4" and checked against what a transport actually reports —
	# "1.2.3.4:51234" — is two strings and no error.
	_check(
		DotPunishmentSubject.for_address("1.2.3.4:51234") == "ip:1.2.3.4",
		"the port is not part of the subject"
	)
	_check(
		DotPunishmentSubject.for_address("[2001:db8::1]:9999") == "ip:2001:db8::1",
		"nor is a bracketed IPv6 port"
	)
	_check(
		DotPunishmentSubject.for_address("ip:1.2.3.4") == "ip:1.2.3.4",
		"a subject that is already one is left alone"
	)
	_check(
		DotPunishmentSubject.for_uid("uid:alice") == "uid:alice"
			and DotPunishmentSubject.for_uid("alice") == "uid:alice",
		"and the same holds for a person"
	)
	_check(
		not DotPunishmentSubject.is_bannable_address("127.0.0.1")
			and not DotPunishmentSubject.is_bannable_address("::1"),
		"loopback is not a bannable address",
		"banning it locks the operator out of their own listen server"
	)
	_check(
		not DotPunishmentSubject.is_bannable_address("unknown"),
		"and neither is an address the transport could not report",
		"that is every client at once"
	)

	var manager := _manager(DATA.path_join("address.json"))
	await get_tree().process_frame
	await manager.load_all()

	var banned: DotResult = await manager.ban_address(
		"203.0.113.9:40000", "ban evasion", "admin:sarah", 0, 0
	)
	_check(banned.ok, "an address is banned", str(banned.error))
	_check(
		manager.is_banned_address("203.0.113.9:51111"),
		"and matches the same address on a different port"
	)
	_check(
		not manager.is_banned_address("203.0.113.10"),
		"and nobody else"
	)

	var loopback: DotResult = await manager.ban_address("127.0.0.1", "oops", "console")
	_check(not loopback.ok, "loopback is refused rather than recorded")

	# What dot-server calls. Everything above is unreachable from a server without it.
	var refused: DotResult = manager.check_admission("", "203.0.113.9:51111")
	_check(not refused.ok, "check_admission refuses the banned address")
	_check(
		not refused.ok and refused.error.message.to_lower().contains("banned"),
		"with the message the player is shown",
		"a player told nothing reconnects immediately"
	)
	_check(
		manager.check_admission("uid:nobody", "198.51.100.1").ok,
		"and admits everybody else"
	)

	await manager.ban_uid("backbone:evil", "cheating", "admin:sarah", 0, 0)
	_check(
		not manager.check_admission("backbone:evil", "198.51.100.1").ok,
		"an account ban is refused from an unbanned address"
	)
	_check(
		not manager.check_admission("uid:backbone:evil", "198.51.100.1").ok,
		"and either spelling of the same person is refused",
		"a deployment writing bare ids and one writing prefixed ids are both legal"
	)

	# A kick is history, not a state, so it must never refuse a connection — which is
	# the whole reason a kick and a ban are one record with a different kind.
	await manager.issue(
		DotPunishment.Kind.KICK, "ip:198.51.100.2", "language", "admin:sarah"
	)
	_check(
		manager.check_admission("", "198.51.100.2").ok,
		"a kick against an address keeps nobody out"
	)

	var temporary: DotResult = await manager.ban_address(
		"198.51.100.3", "cooling off", "admin:sarah", 1, 0
	)
	_check(temporary.ok, "a temporary address ban is recorded")
	_check(
		not manager.check_admission("", "198.51.100.3").ok,
		"and refuses while it is in force"
	)
	var record: DotPunishment = temporary.value
	record.expires_at = int(Time.get_unix_time_from_system()) - 1
	_check(
		manager.check_admission("", "198.51.100.3").ok,
		"and admits the moment it runs out",
		"expiry is answered on read, never swept"
	)

	# An unregistered ban source is a ban nothing enforces, and the moderator who
	# issued one has no way to tell. It has to be said where an operator looks.
	var lines := manager.describe_lines()
	var warned := false
	for line in lines:
		if line.contains("nothing is enforcing them"):
			warned = true
	_check(
		warned,
		"an unregistered ban source is reported in describe_lines",
		"nothing here can refuse a connection; dot-server has to ask"
	)

	manager.queue_free()
	await get_tree().process_frame
	_done()


func _test_voice_actually_asks() -> void:
	_section("dot-voice asks this addon, and this addon answers")

	if not ClassDB.class_exists("Node") or not _voice_is_present():
		# Said out loud rather than skipped quietly. "0 failures" from a suite that ran
		# nothing is how a family gets to a release with two ends that never met.
		_check(
			false,
			"dot-voice is present so the join can be run",
			"addons/dot_voice is not linked; the integration below is NOT covered"
		)
		_done()
		return

	var manager := DotModerationManager.new()
	manager.store = DotPunishmentStoreFile.new(DATA.path_join("join.json"))
	# On, because publishing under `dot_mute_source` IS the integration.
	manager.register_mute_source = true
	add_child(manager)
	await get_tree().process_frame
	await manager.load_all()

	_check(
		DotRegistry.get_service(&"dot_mute_source") == manager,
		"the manager publishes itself where dot-voice looks",
		"one registration, and four call sites in this family have found null before"
	)

	# A transport peer is not a durable identity. Something has to map one to the other,
	# and only the host knows how.
	var peers := {1: "uid:alice", 2: "uid:bob"}
	manager.key_for_peer = func(peer: int) -> String:
		return str(peers.get(peer, "peer:%d" % peer))

	var config := DotVoiceConfig.new()
	config.sample_rate = 24000
	config.frame_ms = 20.0
	config.codec_id = &"adpcm"

	var router := DotVoiceRouter.new()
	router.name = "Router"
	router.config = config
	router.max_bytes_per_second = 0
	add_child(router)
	await get_tree().process_frame

	router.add_peer(1)
	router.add_peer(2)
	router.add_peer(3)

	var delivered: Array[int] = []
	router.send_fn = func(peer: int, _bytes: PackedByteArray) -> void:
		delivered.append(peer)

	var codec := DotVoiceCodec.instance_for(&"adpcm")
	var frame := DotVoiceSourceBuffer.tone(300.0, 0.02, config.sample_rate, 0.4)

	var speak := func(from: int) -> void:
		var packet := DotVoicePacket.new()
		packet.speaker = from
		packet.sample_count = config.frame_samples()
		packet.channel = DotVoiceRouter.Channel.ALL
		packet.codec_id = &"adpcm"
		packet.payload = codec.encode(frame)
		router.relay(from, packet.to_bytes())

	delivered.clear()
	speak.call(1)
	_check(delivered.size() == 2, "alice is heard (%d listeners)" % delivered.size())

	# Now mute her through moderation, and nothing about the router changes.
	var issued: DotResult = await manager.issue(
		DotPunishment.Kind.VOICE_MUTE, "uid:alice", "mic spam", "admin:sarah", 600
	)
	_check(issued.ok, "a moderator mutes her", str(issued.error))

	delivered.clear()
	speak.call(1)
	_check(
		delivered.is_empty(),
		"and the voice router silences her without being told",
		"the two addons meet through one registry name and one method"
	)
	_check(router.refused_muted > 0, "the router counts the refusal")

	delivered.clear()
	speak.call(2)
	_check(delivered.size() == 2, "bob is unaffected (%d)" % delivered.size())

	# The mute has to survive the thing every muted player tries.
	manager.queue_free()
	await get_tree().process_frame

	var rejoined := DotModerationManager.new()
	rejoined.store = DotPunishmentStoreFile.new(DATA.path_join("join.json"))
	rejoined.register_mute_source = true
	rejoined.key_for_peer = func(peer: int) -> String:
		return str(peers.get(peer, "peer:%d" % peer))
	add_child(rejoined)
	await get_tree().process_frame
	await rejoined.load_all()

	delivered.clear()
	speak.call(1)
	_check(
		delivered.is_empty(),
		"she is still silenced after a reconnect",
		"which is the entire point of the addon"
	)

	# And lifting it restores her, through the same seam.
	await rejoined.revoke_all("uid:alice", DotPunishment.Kind.VOICE_MUTE, "admin:sarah")
	delivered.clear()
	speak.call(1)
	_check(delivered.size() == 2, "lifting the mute lets her talk again")

	# The mapping is the part that fails silently, so it is asserted rather than trusted.
	var unmapped := DotModerationManager.new()
	unmapped.store = DotPunishmentStoreFile.new(DATA.path_join("unmapped.json"))
	unmapped.register_mute_source = false
	add_child(unmapped)
	await get_tree().process_frame
	await unmapped.load_all()
	await unmapped.issue(
		DotPunishment.Kind.VOICE_MUTE, "uid:alice", "spam", "console", 600
	)
	_check(
		not unmapped.is_voice_muted(1),
		"with no key_for_peer, a peer id does not match a durable subject",
		"which is correct, silent, and enforces nothing: hence the warning it prints"
	)
	var lines := unmapped.describe_lines()
	var warned := false
	for line in lines:
		if line.contains("WARNING"):
			warned = true
	_check(
		warned,
		"so describe_lines says so where an operator will see it",
		"a mapping nobody set is a moderation system punishing the wrong people"
	)

	router.queue_free()
	rejoined.queue_free()
	unmapped.queue_free()
	await get_tree().process_frame
	_done()


## Whether dot-voice is linked into this project.
##
## The addon is optional here: dot-moderation depends on nothing but dot-core, and a
## project can install it without any voice at all. Checked by loading a script by path
## rather than by naming the class, because naming a `class_name` this project might not
## have would make the whole suite fail to parse, and a scene that fails to parse HANGS
## rather than failing.
func _voice_is_present() -> bool:
	return ResourceLoader.exists("res://addons/dot_voice/runtime/dot_voice_router.gd")


# --- Storage backends ------------------------------------------------------

func _test_schema() -> void:
	_section("the punishment table, in three dialects")

	for dialect in [
		DotPunishmentSchema.Dialect.SQLITE,
		DotPunishmentSchema.Dialect.POSTGRES,
		DotPunishmentSchema.Dialect.MYSQL,
	]:
		var name := DotPunishmentSchema.dialect_name(dialect)
		var statements := DotPunishmentSchema.ddl(dialect)
		var create := statements[0]

		_check(
			create.begins_with("CREATE TABLE IF NOT EXISTS dot_punishments"),
			"%s: the table is created idempotently" % name,
			"a server may run this on every boot, and an operator who made the table "
			+ "by hand must not be fought with"
		)

		# The fields you actually moderate with. Named individually rather than by
		# counting columns, because a count passes when two of them are swapped.
		for column in ["subject", "reason", "expires_at", "issuer", "kind", "revoked"]:
			_check(create.contains(column), "%s: has %s" % [name, column])

		_check(
			create.contains("id") and create.contains("PRIMARY KEY"),
			"%s: the id is the primary key" % name,
			"which is what makes a write idempotent rather than duplicating a ban"
		)

		var joined := "\n".join(Array(statements))
		_check(
			joined.contains("subject_idx"),
			"%s: subject is indexed" % name,
			"every question this table is asked is 'what is against this person', on "
			+ "the join path, while a player waits"
		)
		_check(joined.contains("active_idx"), "%s: and so is what is still in force" % name)

	# MySQL cannot index a TEXT column without a prefix length, and subject IS indexed.
	var mysql := DotPunishmentSchema.ddl(DotPunishmentSchema.Dialect.MYSQL)[0]
	_check(
		mysql.contains("subject VARCHAR"),
		"mysql: an indexed column is VARCHAR rather than TEXT",
		"MySQL cannot index a TEXT column without a prefix length"
	)
	var postgres := DotPunishmentSchema.ddl(DotPunishmentSchema.Dialect.POSTGRES)[0]
	_check(postgres.contains("subject TEXT"), "postgres: and TEXT where that is fine")

	# Times are Unix seconds in a 64-bit integer, never a timestamp type: a timestamp
	# carries a zone, or does not and pretends to, and two servers reading this table are
	# in different places.
	_check(
		postgres.contains("expires_at BIGINT"),
		"expiry is Unix seconds in a BIGINT, not a timestamp"
	)

	# Placeholders. Postgres numbers them and the other two do not, which is the only
	# reason the dialect matters to a statement builder.
	_check(
		DotPunishmentSchema.placeholder(1, DotPunishmentSchema.Dialect.POSTGRES) == "$1",
		"postgres numbers its placeholders"
	)
	_check(
		DotPunishmentSchema.placeholder(1, DotPunishmentSchema.Dialect.SQLITE) == "?",
		"and sqlite does not"
	)

	var upsert_pg := DotPunishmentSchema.upsert(DotPunishmentSchema.Dialect.POSTGRES)
	_check(upsert_pg.contains("ON CONFLICT(id) DO UPDATE"), "postgres upserts")
	var upsert_my := DotPunishmentSchema.upsert(DotPunishmentSchema.Dialect.MYSQL)
	_check(upsert_my.contains("ON DUPLICATE KEY UPDATE"), "and mysql spells it its way")
	_check(
		not upsert_pg.contains("'"),
		"no statement contains a quoted value",
		"a ban reason is typed by a moderator and quotes an attacker-supplied name half "
		+ "the time, so it must never reach SQL by concatenation"
	)

	# The row mapping, both directions, including the trap that already bit this addon.
	var mute := DotPunishment.create(
		DotPunishment.Kind.VOICE_MUTE, "uid:1", "mic spam", "admin:sarah", 600
	)
	mute.evidence = {"demo": "r3.dem"}
	var row := DotPunishmentSchema.to_row(mute)

	_check(
		row.size() == DotPunishmentSchema.COLUMNS.size(),
		"a row has one value per column (%d)" % row.size()
	)
	_check(
		row[1] == "voice_mute",
		"and stores the machine token (%s)" % str(row[1]),
		"writing the player-facing name is the bug that made every stored mute load "
		+ "back as a warning"
	)

	var back := DotPunishmentSchema.from_row(row)
	_check(back.kind == DotPunishment.Kind.VOICE_MUTE, "a row round-trips its kind")
	_check(back.subject == "uid:1" and back.reason == "mic spam", "and its content")
	_check(back.expires_at == mute.expires_at, "and its expiry")
	_check(
		back.evidence.get("demo", "") == "r3.dem",
		"and its evidence, through JSON in a text column"
	)

	# A driver may hand a boolean back as a bool, an int or a string, and only one of
	# those is what any given backend does.
	for revoked_value in [true, 1, "1"]:
		var mapped := DotPunishmentSchema.from_row({
			"id": "x", "subject": "uid:2", "kind": "ban", "revoked": revoked_value
		})
		_check(mapped.revoked, "revoked reads as true from %s" % type_string(typeof(revoked_value)))
	for falsey in [false, 0, "0", ""]:
		var mapped := DotPunishmentSchema.from_row({
			"id": "x", "subject": "uid:2", "kind": "ban", "revoked": falsey
		})
		_check(not mapped.revoked, "and false from %s" % type_string(typeof(falsey)))

	# Rows come back as a Dictionary from some drivers and an Array from others.
	var as_array := DotPunishmentSchema.from_row(row)
	_check(as_array != null and as_array.id == mute.id, "an array row maps too")
	_check(DotPunishmentSchema.from_row("nonsense") == null, "and nonsense maps to null")
	_done()


func _test_sql_store() -> void:
	_section("the SQL store, against a driver that records what it is asked")

	# The store's job is to generate correct statements, bind values in the right order
	# and map rows back. None of that needs a real engine and all of it is where the bugs
	# are. Execution is the part no headless run can cover; see the note at the end.
	var driver := DotSqlDriverRecording.new(DotPunishmentSchema.Dialect.POSTGRES)
	var store := DotPunishmentStoreSql.new(driver)

	var opened: DotResult = await store.open()
	_check(opened.ok, "the store opens and creates its schema", str(opened.error))
	_check(
		driver.matching("CREATE TABLE").size() >= 2,
		"the table and its metadata table are created (%d)"
			% driver.matching("CREATE TABLE").size()
	)
	_check(driver.matching("CREATE INDEX").size() >= 2, "and the indexes")
	_check(store.is_writable(), "and reports itself writable")

	driver.clear()

	var ban := DotPunishment.create(
		DotPunishment.Kind.BAN, "uid:42", "cheating; said 'hi'", "admin:sarah", 86400
	)
	var written: DotResult = await store.put(ban)
	_check(written.ok, "a ban is written", str(written.error))

	var inserts := driver.matching("INSERT INTO")
	if _check(inserts.size() == 1, "as one statement (%d)" % inserts.size()):
		var statement: Dictionary = inserts[0]
		var params: Array = statement["params"]

		_check(
			params.size() == DotPunishmentSchema.COLUMNS.size(),
			"with one bound parameter per column (%d)" % params.size()
		)
		_check(
			str(statement["sql"]).contains("$1"),
			"numbered for postgres"
		)
		# The reason contains a quote. If it reached the statement text rather than the
		# parameters, this is where it would show.
		_check(
			not str(statement["sql"]).contains("cheating"),
			"and the reason is bound, never interpolated",
			"the whole point of parameterised statements"
		)
		_check(
			params.has("cheating; said 'hi'"),
			"so a quote in a ban reason is just a value"
		)
		_check(
			str(statement["sql"]).contains("ON CONFLICT"),
			"a write is an upsert",
			"a retry after a timeout must not produce two records for one ban"
		)

	# Reading back, through the real row mapping.
	driver.clear()
	driver.rows = [DotPunishmentSchema.to_row(ban)]
	var loaded: DotResult = await store.load_all()
	_check(loaded.ok, "the store reads", str(loaded.error))
	_check(
		loaded.ok and (loaded.value as Array).size() == 1,
		"one record comes back"
	)
	if loaded.ok and (loaded.value as Array).size() == 1:
		var read: DotPunishment = (loaded.value as Array)[0]
		_check(read.subject == "uid:42", "with its subject")
		_check(read.kind == DotPunishment.Kind.BAN, "its kind")
		_check(read.reason == "cheating; said 'hi'", "and its reason intact")

	# The query a live server makes on the join path.
	driver.clear()
	driver.rows = [DotPunishmentSchema.to_row(ban)]
	var one: DotResult = await store.load_for("uid:42")
	_check(one.ok, "a single subject can be looked up")
	_check(
		driver.statements.size() == 1
			and str(driver.statements[0]["sql"]).contains("WHERE subject"),
		"with a WHERE rather than by reading the whole table"
	)
	_check(
		(driver.statements[0]["params"] as Array) == ["uid:42"],
		"and the subject bound"
	)

	# A row the table should not have had does not condemn the rest.
	driver.clear()
	driver.rows = [
		DotPunishmentSchema.to_row(ban),
		{"id": "", "subject": "", "kind": "ban"},
	]
	var partial: DotResult = await store.load_all()
	_check(
		partial.ok and (partial.value as Array).size() == 1,
		"one unusable row does not condemn the table (%d loaded)"
			% ((partial.value as Array).size() if partial.ok else -1)
	)

	# A driver failure is a failure, not an empty list.
	driver.clear()
	driver.fail_next = "connection reset"
	var failed: DotResult = await store.load_all()
	_check(
		not failed.ok,
		"a read failure is reported rather than read as 'nobody is punished'"
	)

	# SQLite is the dialect most deployments will use, and its spelling differs.
	var sqlite_driver := DotSqlDriverRecording.new(DotPunishmentSchema.Dialect.SQLITE)
	var sqlite_store := DotPunishmentStoreSql.new(sqlite_driver)
	await sqlite_store.open()
	sqlite_driver.clear()
	await sqlite_store.put(ban)
	_check(
		sqlite_driver.matching("INSERT INTO").size() == 1
			and str(sqlite_driver.matching("INSERT INTO")[0]["sql"]).contains("?"),
		"sqlite gets unnumbered placeholders"
	)

	# And the driver nobody has installed says so rather than failing later.
	var missing := DotSqlDriverSqlite.new("user://never.db")
	var available := missing.is_available()
	_check(
		not available.ok,
		"the SQLite driver reports the extension is absent",
		"rather than failing on the first write"
	)
	_check(
		available.error != null and available.error.code == DotError.CODE_UNSUPPORTED,
		"as CODE_UNSUPPORTED, which a host can branch on"
	)
	print("  note  DotSqlDriverSqlite and DotSqlDriverGateway are NOT executed here.")
	print("        SQLite needs the godot-sqlite GDExtension; Postgres and MySQL need")
	print("        a driver extension or an HTTP gateway. The statements they would")
	print("        run are covered above; running them is not.")
	_done()


func _test_rest_store() -> void:
	_section("the REST store, against a real HTTP server")

	var api: Node = preload("res://examples/punishment_api_server.gd").new()
	api.name = "PunishmentApi"
	add_child(api)

	var started: DotResult = api.start(0)
	if not _check(started.ok, "a punishment API is listening", str(started.error)):
		api.queue_free()
		_done()
		return

	var http := DotHttp.new()
	http.name = "Http"
	add_child(http)
	await get_tree().process_frame

	var store := DotPunishmentStoreRest.new(api.base_url(), http)
	store.token = "secret-token"
	api.require_token = "secret-token"

	var ban := DotPunishment.create(
		DotPunishment.Kind.BAN, "uid:77", "aimbot", "admin:sarah", 86400
	)

	var written: DotResult = await store.put(ban)
	_check(written.ok, "a ban is PUT to the API", str(written.error))
	_check(api.records.has(ban.id), "and the API has it")
	_check(
		api.log.size() > 0 and str(api.log[0]).begins_with("PUT /punishments/"),
		"to the record's own URL (%s)" % [api.log[0] if api.log.size() > 0 else "-"],
		"so a retry after a timeout cannot create a second record"
	)

	var loaded: DotResult = await store.load_all()
	_check(loaded.ok, "the list is read back", str(loaded.error))
	_check(
		loaded.ok and (loaded.value as Array).size() == 1,
		"with the record in it"
	)
	if loaded.ok and (loaded.value as Array).size() == 1:
		var read: DotPunishment = (loaded.value as Array)[0]
		_check(read.subject == "uid:77" and read.reason == "aimbot", "intact")
		_check(read.kind == DotPunishment.Kind.BAN, "and still a ban")
		_check(read.expires_at == ban.expires_at, "with its expiry")

	# The query a live server makes.
	await store.put(DotPunishment.create(
		DotPunishment.Kind.GAG, "uid:88", "spam", "console", 600
	))
	var filtered: DotResult = await store.load_for("uid:77")
	_check(
		filtered.ok and (filtered.value as Array).size() == 1,
		"one subject can be asked for (%d)"
			% ((filtered.value as Array).size() if filtered.ok else -1)
	)

	# A whole manager on top of the API, which is the shape a deployment runs.
	var manager := DotModerationManager.new()
	manager.store = store
	manager.register_mute_source = false
	add_child(manager)
	await get_tree().process_frame
	var pulled: DotResult = await manager.load_all()
	_check(pulled.ok, "a manager loads from the API")
	_check(manager.is_banned_key("uid:77"), "and enforces what it found")
	_check(manager.is_gagged_key("uid:88"), "for every record")

	# The failures, which are the reason a real server is worth the hundred lines.
	api.fail_all = true
	var broke: DotResult = await store.load_all()
	_check(not broke.ok, "a 500 is a failure")
	var still: DotResult = await manager.load_all()
	_check(not still.ok, "which reaches the manager")
	_check(
		manager.is_banned_key("uid:77"),
		"and the manager keeps what was already in force",
		"an API outage must never read as 'nobody is banned'"
	)
	api.fail_all = false

	api.serve_garbage = true
	var garbage: DotResult = await store.load_all()
	_check(not garbage.ok, "a body that is not JSON is a failure")
	api.serve_garbage = false

	api.serve_wrong_shape = true
	var wrong: DotResult = await store.load_all()
	_check(
		not wrong.ok,
		"and so is JSON with no punishments array",
		"which would otherwise read as an empty list, so nobody is banned"
	)
	api.serve_wrong_shape = false

	store.token = "wrong"
	var refused: DotResult = await store.load_all()
	_check(not refused.ok, "a bad token is refused by the API")
	store.token = "secret-token"

	store.writable = false
	var readonly: DotResult = await store.put(ban)
	_check(
		not readonly.ok,
		"a read-only API refuses a write rather than pretending",
		"for a community that issues bans on its website"
	)
	store.writable = true

	var removed: DotResult = await store.remove(ban.id)
	_check(removed.ok, "a record can be deleted")
	_check(not api.records.has(ban.id), "and is gone from the API")

	manager.queue_free()
	http.queue_free()
	api.stop()
	api.queue_free()
	await get_tree().process_frame
	_done()


func _test_mod_tools() -> void:
	_section("moving players around")

	var places := {
		&"admin:sarah": Vector3(0, 0, 0),
		&"uid:bob": Vector3(100, 0, 0),
		&"uid:carol": Vector3(-50, 0, 0),
	}

	var tools := DotModTools.new()
	tools.register_service = false
	tools.record_actions = false
	tools.position_fn = func(id: StringName) -> Vector3:
		return places.get(id, Vector3.ZERO)
	tools.teleport_fn = func(id: StringName, to: Variant) -> void:
		places[id] = to
	add_child(tools)
	await get_tree().process_frame

	# Teleport to a coordinate.
	var to_spot: DotResult = await tools.teleport(
		&"admin:sarah", &"uid:bob", Vector3(10, 5, 10)
	)
	_check(to_spot.ok, "a player is teleported", str(to_spot.error))
	_check(places[&"uid:bob"] == Vector3(10, 5, 10), "and is where they were sent")

	# The one that makes the rest safe to use.
	_check(tools.can_return(&"uid:bob"), "and can be put back")
	var back: DotResult = await tools.return_player(&"admin:sarah", &"uid:bob")
	_check(back.ok, "returning works", str(back.error))
	_check(
		places[&"uid:bob"] == Vector3(100, 0, 0),
		"and puts them exactly where they were (%s)" % places[&"uid:bob"],
		"the position is saved BEFORE the move; saving after would record the "
		+ "destination and a return would put them where they already are"
	)
	_check(not tools.can_return(&"uid:bob"), "and the history is consumed")

	# Bring: the player comes to the moderator.
	var brought: DotResult = await tools.bring(&"admin:sarah", &"uid:bob")
	_check(brought.ok, "a player is brought", str(brought.error))
	_check(places[&"uid:bob"] == Vector3(0, 0, 0), "to the moderator")

	# Goto: the moderator goes to the player, and stops short.
	places[&"uid:carol"] = Vector3(-50, 0, 0)
	var went: DotResult = await tools.goto(&"admin:sarah", &"uid:carol")
	_check(went.ok, "a moderator goes to a player", str(went.error))
	var landed: Vector3 = places[&"admin:sarah"]
	var gap := landed.distance_to(Vector3(-50, 0, 0))
	_check(
		gap > 0.1,
		"and lands short of them (%.2f m away)" % gap,
		"two bodies in the same place is a stuck player at best"
	)
	_check(
		absf(gap - tools.goto_standoff) < 0.01,
		"by the configured stand-off (%.2f)" % gap
	)
	_check(
		tools.can_return(&"admin:sarah"),
		"and the moderator can put themselves back too"
	)

	# Two players in the same spot: the stand-off has no direction to work with, and
	# normalising a zero vector is how that turns into a NaN position.
	places[&"admin:sarah"] = Vector3(7, 7, 7)
	places[&"uid:carol"] = Vector3(7, 7, 7)
	var overlapped: DotResult = await tools.goto(&"admin:sarah", &"uid:carol")
	var after: Vector3 = places[&"admin:sarah"]
	_check(overlapped.ok, "going to somebody standing on you works")
	_check(
		not (is_nan(after.x) or is_nan(after.y) or is_nan(after.z)),
		"and does not produce a NaN position (%s)" % after,
		"normalising a zero-length direction is how it would"
	)

	# Send: one player to another.
	places[&"uid:bob"] = Vector3(100, 0, 0)
	places[&"uid:carol"] = Vector3(-50, 0, 0)
	var sent: DotResult = await tools.send(&"admin:sarah", &"uid:bob", &"uid:carol")
	_check(sent.ok, "a player is sent to another", str(sent.error))
	_check(
		(places[&"uid:bob"] as Vector3).distance_to(Vector3(-50, 0, 0)) < 5.0,
		"and arrives near them"
	)

	# 2D is a first-class user of this, which is why positions are Variant.
	var flat := {&"admin:sarah": Vector2(0, 0), &"uid:bob": Vector2(50, 50)}
	var tools_2d := DotModTools.new()
	tools_2d.register_service = false
	tools_2d.record_actions = false
	tools_2d.position_fn = func(id: StringName) -> Vector2:
		return flat.get(id, Vector2.ZERO)
	tools_2d.teleport_fn = func(id: StringName, to: Variant) -> void:
		flat[id] = to
	add_child(tools_2d)
	await get_tree().process_frame

	var flat_bring: DotResult = await tools_2d.bring(&"admin:sarah", &"uid:bob")
	_check(flat_bring.ok, "the same tools work in 2D", str(flat_bring.error))
	_check(flat[&"uid:bob"] == Vector2(0, 0), "and move a Vector2")
	await tools_2d.return_player(&"admin:sarah", &"uid:bob")
	_check(flat[&"uid:bob"] == Vector2(50, 50), "and return one")

	# Immunity: a junior cannot move a senior.
	var ranks := {&"admin:junior": 10, &"admin:senior": 90, &"uid:bob": 0}
	tools.immunity_fn = func(id: StringName) -> int: return ranks.get(id, 0)

	var blocked: DotResult = await tools.bring(&"admin:junior", &"admin:senior")
	_check(not blocked.ok, "a junior cannot move a senior")
	_check(
		blocked.error != null and blocked.error.code == DotError.CODE_FORBIDDEN,
		"as a refusal rather than a failure"
	)
	var permitted: DotResult = await tools.bring(&"admin:senior", &"uid:bob")
	_check(permitted.ok, "and a senior can move a player")

	# Going to look at somebody is not something to be immune from: a moderator who
	# cannot observe a senior admin cannot do their job.
	places[&"admin:senior"] = Vector3(400, 0, 0)
	var observe: DotResult = await tools.goto(&"admin:junior", &"admin:senior")
	_check(
		observe.ok,
		"but anybody may go and watch anybody",
		"a moderator who cannot observe a senior cannot do their job"
	)

	# Wiring that is not there refuses rather than half-working.
	var unwired := DotModTools.new()
	unwired.register_service = false
	add_child(unwired)
	await get_tree().process_frame
	var nowhere: DotResult = await unwired.bring(&"a", &"b")
	_check(not nowhere.ok, "with no callables set, every action refuses")
	var lines := unwired.describe_lines()
	var warned := false
	for line in lines:
		if line.contains("WARNING"):
			warned = true
	_check(warned, "and describe_lines says so where an operator will see it")

	# The history is bounded, or a long-running server leaks a position per action.
	tools.return_depth = 3
	for i in range(10):
		await tools.teleport(&"admin:senior", &"uid:bob", Vector3(i, 0, 0))
	var depth := 0
	while tools.can_return(&"uid:bob"):
		await tools.return_player(&"admin:senior", &"uid:bob")
		depth += 1
		if depth > 20:
			break
	_check(depth == 3, "the return history is capped at its depth (%d)" % depth)

	tools.forget(&"uid:bob")
	_check(not tools.can_return(&"uid:bob"), "and a disconnect can clear it")

	# Every action on the record, which is what makes "an admin moved me" answerable.
	var manager := DotModerationManager.new()
	manager.store = DotPunishmentStoreFile.new(DATA.path_join("tools.json"))
	manager.register_mute_source = false
	add_child(manager)
	await get_tree().process_frame
	await manager.load_all()

	tools.manager = manager
	tools.record_actions = true
	places[&"uid:dave"] = Vector3(1, 1, 1)
	await tools.bring(&"admin:senior", &"uid:dave")

	var history := manager.history_for("uid:dave")
	_check(history.size() == 1, "a teleport goes on the player's history (%d)" % history.size())
	_check(
		history.size() == 1 and history[0].kind == DotPunishment.Kind.WARN,
		"as a warning, which enforces nothing",
		"a teleport is not a punishment and must not read as one"
	)
	_check(
		history.size() == 1 and not manager.is_banned_key("uid:dave"),
		"so it punishes nobody"
	)
	_check(
		history.size() == 1 and str(history[0].evidence.get("action", "")) == "bring",
		"and records which action it was"
	)

	tools.queue_free()
	tools_2d.queue_free()
	unwired.queue_free()
	manager.queue_free()
	await get_tree().process_frame
	_done()
