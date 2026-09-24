class_name DotModToolCommands
extends RefCounted

## The live tools as console and chat commands, on a dot-server, in one call.
##
## [codeblock]
## # from a DotModule's _module_load, or anything holding the server:
## var commands := DotModToolCommands.install(self, tools, server)
## commands.alive_fn = func(id: StringName) -> bool: return game.is_alive(int(id))
## [/codeblock]
##
## [b]Duck-typed, in the shape [code]DotVoteCommands[/code] set.[/b] The host is anything
## with [code]add_command[/code] (a [code]DotModule[/code], which then removes every one of
## them on unload) or [code]command[/code] (a [code]DotConsole[/code]); the server is
## anything with [code]resolve_target[/code], [code]find_sessions[/code] and
## [code]playing_sessions[/code]; a command context is anything with [code]args[/code],
## [code]session[/code] and [code]reply[/code]. So this file names no dot-server class and
## dot-moderation stays installable without it — which is the rule this addon has kept since
## it was written, and the reason [code]dot_ban_source[/code] exists.
##
## [b]Targets go through the server, not through a second parser.[/b] A single player is
## resolved by [code]resolve_target[/code], which is what [code]kick[/code] uses: the same
## name, userid, [code]#id[/code], account-id and [code]ip:[/code] forms, the same refusal of
## an ambiguous name, and the same immunity rule. What is added here is only what the
## server cannot know: [code]@all[/code], [code]@others[/code], and — when the game says —
## [code]@alive[/code], [code]@dead[/code] and [code]@team:<name>[/code]. A player the caller
## cannot outrank is skipped from a group and counted in the reply, never silently.
##
## [b]A bare command acts on the caller.[/b] [code]!noclip[/code] with no name is how every
## admin has typed it for twenty years, so an empty target and [code]@me[/code] are the
## caller — and acting on yourself is never refused for immunity, which dot-server's own
## [code]resolve_target[/code] would do, because everybody has equal immunity to themselves.
##
## [b]Every command is registered whether or not this game supports it.[/b] A
## [code]!noclip[/code] in a 2D lobby answers with the game's reason, from
## [member DotModTools.unsupported_reasons]; a command that did not exist would answer
## "unknown command", which is a worse sentence about a better-defined situation.

const CHANNEL := "moderation.commands"

## The permission names this file hands the console. Spelled out rather than read off
## dot-server's `DotAdminFlags`, which this addon may not name; the strings are the same.
const FLAG_CHEATS := "cheats"
const FLAG_SLAY := "slay"
const FLAG_TELEPORT := "teleport"
const FLAG_GENERIC := "generic"

## role -> [default name, usage, description, flag, minimum arguments].
##
## [b]Why the split between the flags is where it is.[/b] `slay` is handling a PERSON —
## stopping a griefer, removing somebody from a spot, a name that should not be on a
## scoreboard — and is what a moderator needs. `cheats` is changing the GAME — flying,
## immortality, a weapon out of nowhere — and a community that trusts somebody to freeze a
## griefer has not thereby trusted them to give themselves a rocket launcher. `teleport` is
## separate because moving players is the power that looks most like cheating from outside.
const COMMANDS := {
	"noclip": ["noclip", "[player] [on|off]", "Fly through walls, or stop", FLAG_CHEATS, 0],
	"god": ["god", "[player] [on|off]", "Take no damage, or stop", FLAG_CHEATS, 0],
	"buddha": ["buddha", "[player] [on|off]", "Take damage but never die, or stop", FLAG_CHEATS, 0],
	"freeze": ["freeze", "<player> [seconds]", "Hold a player where they stand", FLAG_SLAY, 1],
	"unfreeze": ["unfreeze", "<player>", "Let a frozen player go", FLAG_SLAY, 1],
	"slay": ["slay", "<player>", "Kill a player", FLAG_SLAY, 1],
	"slap": ["slap", "<player> [damage]", "Shove a player, and optionally hurt them", FLAG_SLAY, 1],
	"respawn": ["respawn", "<player>", "Put a player back at a spawn, alive", FLAG_SLAY, 1],
	"rename": ["rename", "<player> <new name>", "Change a player's name", FLAG_SLAY, 2],
	"burn": ["burn", "<player> [seconds]", "Set a player on fire", FLAG_SLAY, 1],
	"blind": ["blind", "<player> [on|off|seconds]", "Black out a player's screen, or stop", FLAG_SLAY, 1],
	"beacon": ["beacon", "<player> [on|off]", "Make a player visible to everybody, or stop", FLAG_SLAY, 1],
	"hp": ["hp", "<player> <health>", "Set a player's health", FLAG_CHEATS, 2],
	"speed": ["speed", "<player> <multiplier>", "Scale how fast a player moves; 1 is normal", FLAG_CHEATS, 2],
	"gravity": ["gravity", "<player> <multiplier>", "Scale a player's gravity; 1 is normal", FLAG_CHEATS, 2],
	"give": ["give", "<player> <item>", "Give a player something", FLAG_CHEATS, 2],
	"strip": ["strip", "<player>", "Take a player's weapons away", FLAG_CHEATS, 1],
	"bring": ["bring", "<player>", "Bring a player to you", FLAG_TELEPORT, 1],
	"goto": ["goto", "<player>", "Go to a player", FLAG_TELEPORT, 1],
	"send": ["send", "<player> <destination player>", "Send a player to another", FLAG_TELEPORT, 2],
	"return": ["return", "<player>", "Put a player back where they were before a move", FLAG_TELEPORT, 1],
	"modtools": ["modtools", "[player]", "What the live tools can do here, or what is on a player", FLAG_GENERIC, 0],
}

## Toggles, and which ability each command drives.
const TOGGLE_ROLES := {
	"noclip": DotModTools.ACTION_NOCLIP,
	"god": DotModTools.ACTION_GOD,
	"buddha": DotModTools.ACTION_BUDDHA,
	"blind": DotModTools.ACTION_BLIND,
	"beacon": DotModTools.ACTION_BEACON,
}

## Toggles that also take a number of seconds in place of on|off, released by
## [method DotModTools.release_after] when it runs out — freeze's rule, for the toggles a
## moderator means as a spell rather than as a state.
##
## [b]Only where the player is a required argument.[/b] `noclip 5` already means "noclip
## the player called 5", so a number there cannot also be a duration; `blind` always names
## its target first, and its second word is free. The switch words are read first, so `1`
## and `0` stay on and off as they are for every other toggle, and `blind bob 1` is a blind
## until somebody lifts it rather than a one-second one.
const TIMED_TOGGLES: Array[String] = ["blind"]

## Past tense, for replies and announcements. A table because English is not regular
## enough to derive "slain" from "slay".
const DONE := {
	"freeze": "frozen", "unfreeze": "unfrozen", "slay": "slain", "slap": "slapped",
	"respawn": "respawned", "rename": "renamed", "burn": "set on fire", "hp": "healed",
	"speed": "sped up", "gravity": "given new gravity", "give": "given", "strip": "stripped",
	"bring": "brought", "goto": "visited", "send": "sent", "return": "returned",
}

var tools: DotModTools = null

## The server. Duck-typed: `resolve_target(ctx, text)`, `find_sessions(text, caller)`,
## `playing_sessions()`, and optionally `chat` and `audit`.
var server: Object = null

## Prepended to every command name. `"admin_"` gives `admin_noclip`.
var prefix: String = ""

## Per-role name overrides, e.g. `{"hp": "sethealth"}`.
var names: Dictionary = {}

## Per-role permission overrides, e.g. `{"rename": "kick"}`. Empty string makes a command
## public, which is never what an operator means for these; it is allowed because refusing
## it would be a policy this file has no business holding.
var permissions: Dictionary = {}

## Roles not to register at all. For a game that has its own command by that name and
## would rather the operator's muscle memory reach it — or a community that wants no slap.
var skip: PackedStringArray = PackedStringArray()

## Announce each action to the server, without naming who did it. Visible moderation is a
## deterrent; the moderator's name is not information a player needs to appeal, and it is
## how a moderator gets harassed — the same rule dot-moderation's player message keeps.
var announce: bool = true

## Tell the target, privately, what was done to them. Also without the moderator's name.
var notify_target: bool = true

## How a session becomes the id [member tools] knows a player by. The default is the
## session's userid, which is what every game in this family keys its players on.
var id_fn: Callable = Callable()

## `func(id: StringName) -> bool`. Enables `@alive` and `@dead`.
var alive_fn: Callable = Callable()

## `func(id: StringName) -> String`, a team's name or number. Enables `@team:<name>`.
var team_fn: Callable = Callable()

## `func() -> PackedStringArray`, what `give` can hand out, for completion and for its
## usage line.
var items_fn: Callable = Callable()

## Names actually registered, for a host that has to remove them again.
var registered: PackedStringArray = PackedStringArray()

## Names refused because something else already had them.
var collided: PackedStringArray = PackedStringArray()


static func install(host: Object, p_tools: DotModTools, p_server: Object) -> DotModToolCommands:
	var commands := DotModToolCommands.new()
	commands.tools = p_tools
	commands.server = p_server
	var _res := commands.bind(host)
	return commands


func command_name(role: String) -> String:
	var entry: Array = COMMANDS.get(role, [role])
	return prefix + str(names.get(role, entry[0]))


func permission_for(role: String) -> String:
	if permissions.has(role):
		return str(permissions[role])

	var entry: Array = COMMANDS.get(role, ["", "", "", FLAG_GENERIC, 0])
	return str(entry[3])


## Registers everything on [param host].
func bind(host: Object) -> DotResult:
	if host == null or tools == null or server == null:
		return DotResult.fail(
			DotError.CODE_INVALID, "A host, the tools and a server are all needed."
		)

	var adder := ""

	if host.has_method("add_command"):
		adder = "add_command"
	elif host.has_method("command"):
		adder = "command"
	else:
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"That host has no way to register a command.",
			"expected a DotModule (add_command) or a DotConsole (command)"
		)

	var console := _console_of(host)

	for role: String in COMMANDS:
		if skip.has(role):
			continue

		var full := command_name(role)

		# [b]Checked before registering, not left to the console.[/b] A console that is
		# handed a name it already has warns and returns the EXISTING command — and a
		# DotModule records the name anyway and unregisters it on unload, which would remove
		# somebody else's command. A game with its own `respawn` keeps it.
		if console != null and console.has_method("has_name") and bool(console.call("has_name", full)):
			collided.append(full)
			continue

		var entry: Array = COMMANDS[role]
		var made: Variant = host.call(
			adder, full, _handler_for(role), str(entry[2]), permission_for(role)
		)

		if made is Object:
			var command := made as Object

			if command.has_method("with_usage"):
				command.call("with_usage", str(entry[1]))
			if command.has_method("with_args") and int(entry[4]) > 0:
				command.call("with_args", int(entry[4]))
			# Typable in chat whatever the server's default, like kick and mute: this is
			# moderation, and the flag is what refuses anybody who should not.
			if command.has_method("with_chat"):
				command.call("with_chat")
			if command.has_method("with_completer"):
				command.call("with_completer", _completer_for(role))

		registered.append(full)

	if not collided.is_empty():
		DotLog.warn(CHANNEL, "some mod tool commands were already taken and are not registered", {
			"names": ", ".join(collided),
		})

	DotLog.info(CHANNEL, "mod tool commands registered", {
		"count": registered.size(), "abilities": ", ".join(tools.abilities()),
	})

	return DotResult.success(registered)


## Removes what [method bind] registered, from a console host. A module host does this
## itself on unload.
func unbind(host: Object) -> void:
	var console := _console_of(host)

	if console == null or not console.has_method("unregister_command"):
		return

	for full in registered:
		console.call("unregister_command", full)

	registered.clear()


# --- Commands --------------------------------------------------------------

func _handler_for(role: String) -> Callable:
	return func(ctx: Object) -> void:
		await _run(role, ctx)


func _run(role: String, ctx: Object) -> void:
	var args := _args(ctx)

	if role == "modtools":
		_status(ctx, args)
		return

	var target_text := args[0] if args.size() > 0 else ""
	var rest := Array(args).slice(1)

	# The toggles take an optional player and an optional on|off, in either order people
	# actually type: `noclip`, `noclip off`, `noclip bob`, `noclip bob on`.
	if TOGGLE_ROLES.has(role) and args.size() == 1 and _parse_switch(args[0]) != null:
		target_text = ""
		rest = [args[0]]

	var targets := _targets(ctx, target_text)

	if not targets.ok:
		_reply(ctx, targets.error.message + (
			" (%s)" % targets.error.detail if targets.error.detail != "" else ""
		))
		return

	var sessions: Array = targets.value["sessions"]
	var skipped: int = targets.value["skipped"]
	var actor := _actor_id(ctx)
	var actor_level := _actor_immunity(ctx)

	var done := PackedStringArray()
	var failures := PackedStringArray()
	# For a toggle typed without on|off: what each target ended up as, so the reply can say
	# "on" rather than "toggled" when every one of them went the same way.
	var ended_on: Array[bool] = []
	# For a multiplier: what each target was actually put on. See below.
	var applied: Array = []

	for session: Object in sessions:
		var id := _id_of(session)
		var result: DotResult = await _apply(role, ctx, actor, actor_level, id, rest)
		var shown := str(session.get("display_name"))

		if not result.ok:
			failures.append("%s: %s" % [shown, result.error.message])
			continue

		done.append(shown)

		if TOGGLE_ROLES.has(role):
			ended_on.append(tools.is_active(id, TOGGLE_ROLES[role]))

		if (role == "speed" or role == "gravity") and (result.value is float or result.value is int):
			applied.append(float(result.value))

		_after(role, ctx, session, id, result, rest)

	var switch_word := ""
	if not ended_on.is_empty():
		switch_word = "on" if ended_on.all(func(v: bool) -> bool: return v) else (
			"off" if ended_on.all(func(v: bool) -> bool: return not v) else "toggled"
		)

	# A game whose speeds are a ladder applies the nearest step, and the reply and the room
	# are told the step: "set to 2.2x speed" about a player on 2x is the tool contradicting
	# its own record (`multiplier_of`, `modtools`) and the player's own line, which already
	# said 2. The typed number stands only when the targets landed on different steps.
	var said := rest

	if not applied.is_empty() and applied.all(
		func(v: float) -> bool: return is_equal_approx(v, float(applied[0]))
	):
		said = [_multiplier_text(float(applied[0]))] + rest.slice(1)

	_report(role, ctx, done, failures, skipped, rest, switch_word, said)


func _apply(
	role: String, ctx: Object, actor: StringName, actor_level: int,
	id: StringName, rest: Array
) -> DotResult:
	if TOGGLE_ROLES.has(role):
		var action: StringName = TOGGLE_ROLES[role]
		var want: Variant = _parse_switch(str(rest[0])) if rest.size() > 0 else null
		var timed := TIMED_TOGGLES.has(role)

		if rest.size() > 0 and want == null and timed and _number(rest, 0, 0.0) > 0.0:
			var seconds := _number(rest, 0, 0.0)
			var held: DotResult = await tools.toggle(actor, id, action, true, actor_level)
			if held.ok:
				tools.release_after(id, action, seconds)
			return held

		if rest.size() > 0 and want == null:
			return DotResult.fail(DotError.CODE_INVALID, (
				"Say on, off or a number of seconds, not '%s'." if timed
				else "Say on or off, not '%s'."
			) % str(rest[0]))

		return await tools.toggle(actor, id, action, want, actor_level)

	match role:
		"freeze":
			var seconds := _number(rest, 0, 0.0)
			var frozen: DotResult = await tools.toggle(
				actor, id, DotModTools.ACTION_FREEZE, true, actor_level
			)
			if frozen.ok and seconds > 0.0:
				tools.release_after(id, DotModTools.ACTION_FREEZE, seconds)
			return frozen
		"unfreeze":
			return await tools.toggle(actor, id, DotModTools.ACTION_FREEZE, false, actor_level)
		"slay":
			return await tools.perform(actor, id, DotModTools.ACTION_SLAY, {}, actor_level)
		"slap":
			return await tools.perform(
				actor, id, DotModTools.ACTION_SLAP, {"damage": _number(rest, 0, 0.0)}, actor_level
			)
		"respawn":
			return await tools.perform(actor, id, DotModTools.ACTION_RESPAWN, {}, actor_level)
		"rename":
			return await tools.perform(
				actor, id, DotModTools.ACTION_RENAME, {"name": " ".join(rest)}, actor_level
			)
		"burn":
			return await tools.perform(
				actor, id, DotModTools.ACTION_BURN, {"seconds": _number(rest, 0, 5.0)}, actor_level
			)
		"hp":
			if rest.is_empty() or not str(rest[0]).is_valid_float():
				return DotResult.fail(DotError.CODE_INVALID, "Give a number for their health.")
			return await tools.perform(
				actor, id, DotModTools.ACTION_HEALTH, {"value": str(rest[0]).to_float()}, actor_level
			)
		"speed", "gravity":
			if rest.is_empty() or not str(rest[0]).is_valid_float():
				return DotResult.fail(DotError.CODE_INVALID, "Give a multiplier; 1 is normal.")
			var action := DotModTools.ACTION_SPEED if role == "speed" else DotModTools.ACTION_GRAVITY
			return await tools.perform(
				actor, id, action, {"scale": str(rest[0]).to_float()}, actor_level
			)
		"give":
			return await tools.perform(
				actor, id, DotModTools.ACTION_GIVE, {"item": " ".join(rest)}, actor_level
			)
		"strip":
			return await tools.perform(actor, id, DotModTools.ACTION_STRIP, {}, actor_level)
		"bring":
			return await tools.bring(actor, id, actor_level)
		"goto":
			# The caller is the one who moves, so the target is not asked about immunity —
			# DotModTools.goto's own rule.
			return await tools.goto(actor, id)
		"send":
			var destination := _single(ctx, str(rest[0]) if rest.size() > 0 else "")
			if not destination.ok:
				return destination
			return await tools.send(actor, id, _id_of(destination.value as Object), actor_level)
		"return":
			return await tools.return_player(actor, id, actor_level)

	return DotResult.fail(DotError.CODE_UNSUPPORTED, "Unknown mod tool '%s'." % role)


## What has to happen outside the tools once an action lands.
func _after(
	role: String, _ctx: Object, session: Object, id: StringName, result: DotResult, rest: Array
) -> void:
	# The server's own idea of the name, too. Chat, `status` and the scoreboard read
	# `display_name`, and a rename the game applied and the server did not is a player
	# called one thing in the world and another in every line they type.
	if role == "rename" and "display_name" in session:
		var wanted := " ".join(rest).strip_edges()
		var applied: Variant = result.value
		session.set("display_name", str(applied) if applied is String and str(applied) != "" else wanted)

	if not notify_target:
		return

	var chat: Variant = server.get("chat")

	if chat is Object and (chat as Object).has_method("send_system_to"):
		var line := _target_line(role, id, result, rest)
		if line != "":
			(chat as Object).call("send_system_to", session, line)


func _report(
	role: String, ctx: Object, done: PackedStringArray, failures: PackedStringArray,
	skipped: int, rest: Array, switch_word: String, said: Array = []
) -> void:
	for line in failures:
		_reply(ctx, line)

	if skipped > 0:
		_reply(ctx, "%d player%s skipped: equal or higher immunity than you." % [
			skipped, "" if skipped == 1 else "s"
		])

	if done.is_empty():
		if failures.is_empty() and skipped == 0:
			_reply(ctx, "Nobody matched.")
		return

	var who := done[0] if done.size() == 1 else "%d players" % done.size()
	var what := _summary(role, said if not said.is_empty() else rest, switch_word)

	_reply(ctx, "%s %s." % [who, what])

	var audit: Variant = server.get("audit")

	if audit is Object and (audit as Object).has_method("record"):
		(audit as Object).call("record", command_name(role), _caller(ctx), ", ".join(done), {
			"args": " ".join(rest),
		})

	if announce and role != "goto":
		var chat: Variant = server.get("chat")
		if chat is Object and (chat as Object).has_method("announce_action"):
			(chat as Object).call("announce_action", "%s %s." % [who, what])


## `2`, not `2.0`; `0.25` stays `0.25`. An admin typed a number and reads one back.
static func _multiplier_text(value: float) -> String:
	return str(int(value)) if is_equal_approx(value, roundf(value)) else str(snappedf(value, 0.01))


func _summary(role: String, rest: Array, switch_word: String = "") -> String:
	if TOGGLE_ROLES.has(role):
		return "had %s turned %s" % [role, switch_word if switch_word != "" else "on"]

	match role:
		"hp":
			return "set to %s health" % str(rest[0])
		"speed", "gravity":
			return "set to %s× %s" % [str(rest[0]), role]
		"give":
			return "given %s" % " ".join(rest)
		"rename":
			return "renamed to %s" % " ".join(rest)
		"slap":
			var damage := _number(rest, 0, 0.0)
			return "slapped" if damage <= 0.0 else "slapped for %s" % str(damage)

	return str(DONE.get(role, role))


## What the player is told. Never who did it.
func _target_line(role: String, id: StringName, result: DotResult, rest: Array) -> String:
	if TOGGLE_ROLES.has(role):
		var action: StringName = TOGGLE_ROLES[role]
		return "An admin turned %s %s for you." % [
			String(action), "on" if tools.is_active(id, action) else "off"
		]

	match role:
		"speed", "gravity":
			var applied: Variant = result.value
			return "An admin set your %s to %s×." % [
				role,
				_multiplier_text(float(applied)) if applied is float or applied is int
					else str(rest[0])
			]
		"goto", "return":
			return ""

	return "You were %s by an admin." % _summary(role, rest)


func _status(ctx: Object, args: PackedStringArray) -> void:
	if args.is_empty():
		ctx.call("reply_lines", tools.describe_lines())
		return

	var found := _single(ctx, args[0])

	if not found.ok:
		_reply(ctx, found.error.message)
		return

	var session := found.value as Object
	var active := tools.active_on(_id_of(session))
	_reply(ctx, "%s: %s" % [
		str(session.get("display_name")),
		", ".join(active) if not active.is_empty() else "nothing on them",
	])


# --- Targets -----------------------------------------------------------------

## Who a command acts on: `{sessions: Array, skipped: int}`.
func _targets(ctx: Object, text: String) -> DotResult:
	var lowered := text.strip_edges().to_lower()
	var caller: Variant = ctx.get("session")

	if lowered == "" or lowered == "@me" or lowered == "@self":
		if caller == null:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"The console has no body to act on. Name a player.",
				"@all, @alive, @dead, @others, @team:<name>, or a name"
			)
		return DotResult.success({"sessions": [caller], "skipped": 0})

	if lowered.begins_with("@") and not lowered.begins_with("@ip:"):
		return _group(ctx, lowered)

	var one := _single(ctx, text)

	if not one.ok:
		return one

	return DotResult.success({"sessions": [one.value], "skipped": 0})


## One player, by any form dot-server understands, immunity checked the way kick checks it.
func _single(ctx: Object, text: String) -> DotResult:
	var caller: Variant = ctx.get("session")

	if text.strip_edges() == "":
		return DotResult.fail(DotError.CODE_INVALID, "Name a player.")

	# Yourself first, so that naming yourself is not refused for immunity — see the class note.
	if caller != null and server.has_method("find_sessions"):
		var matches: Variant = server.call("find_sessions", text, caller)
		if matches is Array and (matches as Array).size() == 1 and (matches as Array)[0] == caller:
			return DotResult.success(caller)

	var resolved: Variant = server.call("resolve_target", ctx, text)

	if resolved is DotResult:
		return resolved

	return DotResult.fail(DotError.CODE_STATE, "The server could not resolve '%s'." % text)


func _group(ctx: Object, selector: String) -> DotResult:
	var everyone: Variant = server.call("playing_sessions") if server.has_method("playing_sessions") else []
	var caller: Variant = ctx.get("session")
	var picked: Array = []

	match selector:
		"@all":
			picked = (everyone as Array).duplicate()
		"@others":
			for session: Variant in everyone:
				if session != caller:
					picked.append(session)
		"@alive", "@dead":
			if not alive_fn.is_valid():
				return DotResult.fail(
					DotError.CODE_UNSUPPORTED, "This game does not say who is alive."
				)
			var want_alive := selector == "@alive"
			for session: Variant in everyone:
				if bool(alive_fn.call(_id_of(session as Object))) == want_alive:
					picked.append(session)
		_:
			if not selector.begins_with("@team:"):
				return DotResult.fail(
					DotError.CODE_INVALID,
					"Unknown selector '%s'." % selector,
					"@me, @all, @others, @alive, @dead, @team:<name>"
				)
			if not team_fn.is_valid():
				return DotResult.fail(DotError.CODE_UNSUPPORTED, "This game has no teams.")
			var wanted := selector.substr(6)
			for session: Variant in everyone:
				if str(team_fn.call(_id_of(session as Object))).to_lower() == wanted:
					picked.append(session)

	# Immunity per player, exactly as resolve_target applies it to one — and skipped
	# rather than refused, because "@all" on a server with one senior admin on it should
	# not do nothing to everybody else.
	var allowed: Array = []
	var skipped := 0

	for session: Variant in picked:
		if session == caller or bool(ctx.call("outranks", int((session as Object).get("immunity")))):
			allowed.append(session)
		else:
			skipped += 1

	return DotResult.success({"sessions": allowed, "skipped": skipped})


# --- Completion ----------------------------------------------------------------

func _completer_for(role: String) -> Callable:
	return func(partial: String, index: int) -> PackedStringArray:
		if index == 0 and role != "modtools":
			return _complete_players(partial, true)
		if index == 0:
			return _complete_players(partial, false)
		if index == 1 and role == "send":
			return _complete_players(partial, false)
		if index == 1 and role == "give" and items_fn.is_valid():
			return _complete_from(items_fn.call(), partial)
		if index == 1 and TOGGLE_ROLES.has(role):
			return _complete_from(PackedStringArray(["on", "off"]), partial)
		return PackedStringArray()


func _complete_players(partial: String, selectors: bool) -> PackedStringArray:
	var out := PackedStringArray()
	var lowered := partial.to_lower()

	if selectors:
		for selector in ["@me", "@all", "@others"]:
			if selector.begins_with(lowered):
				out.append(selector)
		if alive_fn.is_valid():
			for selector in ["@alive", "@dead"]:
				if selector.begins_with(lowered):
					out.append(selector)

	var everyone: Variant = server.call("playing_sessions") if server.has_method("playing_sessions") else []

	for session: Variant in everyone:
		var shown := str((session as Object).get("display_name"))
		if lowered == "" or shown.to_lower().begins_with(lowered):
			# Quoted, as dot-server's own completer does: a name with a space would
			# otherwise tokenize into two arguments.
			out.append("\"%s\"" % shown if shown.contains(" ") else shown)

	return out


func _complete_from(values: Variant, partial: String) -> PackedStringArray:
	var out := PackedStringArray()
	var list: Array = []

	if values is PackedStringArray:
		list = Array(values as PackedStringArray)
	elif values is Array:
		list = values as Array

	for value: Variant in list:
		if str(value).to_lower().begins_with(partial.to_lower()):
			out.append(str(value))

	return out


# --- Context helpers -------------------------------------------------------------

func _id_of(session: Object) -> StringName:
	if id_fn.is_valid():
		return StringName(str(id_fn.call(session)))

	return StringName(str(session.get("userid")))


func _actor_id(ctx: Object) -> StringName:
	var session: Variant = ctx.get("session")

	if session is Object:
		return _id_of(session as Object)

	return &"console"


## The caller's immunity as the console knows it. Root, and the local console, outrank
## everybody; dot-server's `outranks` says the same thing about the same context.
func _actor_immunity(ctx: Object) -> int:
	if ctx.has_method("has_permission") and bool(ctx.call("has_permission", "root")):
		return 100

	var level: Variant = ctx.get("immunity")
	return int(level) if level != null else 0


func _caller(ctx: Object) -> String:
	return str(ctx.call("caller_label")) if ctx.has_method("caller_label") else "console"


func _args(ctx: Object) -> PackedStringArray:
	var args: Variant = ctx.get("args")
	return args as PackedStringArray if args is PackedStringArray else PackedStringArray()


func _reply(ctx: Object, text: String) -> void:
	ctx.call("reply", text)


func _console_of(host: Object) -> Object:
	if host.has_method("command") and host.has_method("has_name"):
		return host

	var console: Variant = host.get("console")
	return console as Object if console is Object else null


static func _parse_switch(text: String) -> Variant:
	match text.strip_edges().to_lower():
		"on", "1", "true", "yes", "enable":
			return true
		"off", "0", "false", "no", "disable":
			return false
	return null


static func _number(rest: Array, index: int, fallback: float) -> float:
	if index < rest.size() and str(rest[index]).is_valid_float():
		return str(rest[index]).to_float()
	return fallback
