@tool
class_name DotModTools
extends Node

## What a moderator does to a player who is standing in front of them.
##
## Punishments are the record; this is the live action. Teleporting somebody out of a
## spot they are exploiting, pulling them over to be talked to, going to them to watch
## what they are doing, and putting them back afterwards.
##
## [codeblock]
## var tools := DotModTools.new()
## tools.position_fn = func(id): return world.player(id).global_position
## tools.teleport_fn = func(id, to): world.player(id).global_position = to
## add_child(tools)
##
## tools.bring(&"admin:sarah", &"uid:bob")     # bob comes to sarah
## tools.return_player(&"admin:sarah", &"uid:bob")   # and goes back
## [/codeblock]
##
## [b]It knows nothing about your world, and it cannot.[/b] This addon depends only on
## dot-core, so it has no scene, no player list, no idea whether the game is 2D or 3D and
## no way to move anything. Positions come from [member position_fn] and moves go through
## [member teleport_fn], both supplied by the host. That is the same shape
## [DotVoiceRouter] uses for teams and positions, and the reason dot-timer can serve a 3D
## surf map and a 2D course from one implementation.
##
## Positions are [Variant] rather than [Vector3] for exactly that reason: a
## [Vector2] game is a first-class user of this, and naming [Vector3] in a signature would
## make it one a 2D game has to work around.
##
## [b]Every action is recorded.[/b] Teleporting a player is a moderator power and it is
## the one that looks most like cheating from the outside: "an admin moved me" and "an
## admin moved themselves behind me" are both things a player will complain about. When a
## [DotModerationManager] is attached, each action goes on that player's history as a
## [constant DotPunishment.Kind.WARN] carrying what happened, so there is an answer.

const CHANNEL := "moderation.tools"
const SERVICE := &"dot_mod_tools"

## An action was carried out.
signal acted(action: StringName, actor: StringName, target: StringName, detail: Dictionary)

## An action was refused. [param reason] is one of `unknown`, `immune`, `no_position`,
## `no_teleport`, `nothing_to_return_to`.
signal refused(action: StringName, actor: StringName, target: StringName, reason: String)

const ACTION_TELEPORT := &"teleport"
const ACTION_BRING := &"bring"
const ACTION_GOTO := &"goto"
const ACTION_SEND := &"send"
const ACTION_RETURN := &"return"

@export_group("Behaviour")

## How many previous positions are kept per player, for [method return_player].
##
## [b]More than one, and that is the point.[/b] A moderator who brings a player, looks at
## them, sends them to somebody else and then wants to undo needs more than the last hop.
## Ten is enough for any sequence a person performs by hand and small enough that a full
## server costs nothing.
@export_range(1, 64, 1) var return_depth: int = 10

## Metres a `goto` stops short of the target, so the moderator does not land inside them.
##
## Two bodies in the same place is at best a stuck player and at worst a physics
## explosion, and it happens every single time without this.
@export_range(0.0, 20.0, 0.1) var goto_standoff: float = 1.5

## Record actions on the target's history when a manager is attached.
@export var record_actions: bool = true

@export_group("Service")

@export var register_service: bool = true

## Where a player is now. `func(id: StringName) -> Vector2/Vector3`.
var position_fn: Callable = Callable()

## Move a player. `func(id: StringName, to: Variant) -> void`.
var teleport_fn: Callable = Callable()

## Immunity of an actor or target, so a junior cannot move a senior.
## `func(id: StringName) -> int`. Optional; without it nobody is immune.
var immunity_fn: Callable = Callable()

## Optional [DotModerationManager], for the history.
var manager: DotModerationManager = null

## Diagnostics.
var actions_taken: int = 0
var actions_refused: int = 0

## id -> Array of previous positions, newest last.
var _history: Dictionary = {}


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if register_service:
		DotRegistry.register(SERVICE, self)


func _exit_tree() -> void:
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)


# --- Actions ---------------------------------------------------------------

## Moves a player to a position.
func teleport(actor: StringName, target: StringName, to: Variant) -> DotResult:
	return await _move(ACTION_TELEPORT, actor, target, to, {"to": to})


## Brings a player to the moderator.
func bring(actor: StringName, target: StringName) -> DotResult:
	var at := _position_of(actor)

	if at == null:
		return _refuse(ACTION_BRING, actor, target, "no_position",
			"Cannot find where you are.")

	return await _move(ACTION_BRING, actor, target, at, {"to": at})


## Moves the moderator to a player.
##
## The actor is the one being moved here, so it is the actor's position that is saved for
## a return and the [b]target's[/b] immunity that is not consulted: going to look at
## somebody is not something to be immune from, and a moderator who cannot observe a
## senior admin cannot do their job.
func goto(actor: StringName, target: StringName) -> DotResult:
	var at := _position_of(target)

	if at == null:
		return _refuse(ACTION_GOTO, actor, target, "no_position",
			"Cannot find where they are.")

	var landing := _stand_off(at, _position_of(actor))

	if not teleport_fn.is_valid():
		return _refuse(ACTION_GOTO, actor, target, "no_teleport",
			"This game cannot teleport.")

	_remember(actor)
	teleport_fn.call(actor, landing)
	actions_taken += 1
	acted.emit(ACTION_GOTO, actor, target, {"to": landing})

	# Recorded against the actor, because the actor is who moved. A moderator's own
	# movements are the ones an audit is actually about.
	await _record(actor, ACTION_GOTO, actor, target)

	return DotResult.success(landing)


## Sends a player to another player.
func send(actor: StringName, target: StringName, destination: StringName) -> DotResult:
	var at := _position_of(destination)

	if at == null:
		return _refuse(ACTION_SEND, actor, target, "no_position",
			"Cannot find where they are.")

	return await _move(
		ACTION_SEND, actor, target, _stand_off(at, _position_of(target)),
		{"to": at, "destination": String(destination)}
	)


## Puts a player back where they were before the last move.
##
## [b]The action that makes the rest of them safe to use.[/b] Without it, "bring" is
## something a moderator hesitates to do mid-round because they cannot undo it, and a
## moderator who hesitates does not moderate. Every move here saves a position, including
## a `goto`, so a moderator can put themselves back too.
func return_player(actor: StringName, target: StringName) -> DotResult:
	var stack: Array = _history.get(target, [])

	if stack.is_empty():
		return _refuse(ACTION_RETURN, actor, target, "nothing_to_return_to",
			"There is nowhere to put them back to.")

	if not teleport_fn.is_valid():
		return _refuse(ACTION_RETURN, actor, target, "no_teleport",
			"This game cannot teleport.")

	var blocked := _immunity_refusal(actor, target)
	if blocked != "":
		return _refuse(ACTION_RETURN, actor, target, "immune", blocked)

	var to: Variant = stack.pop_back()
	_history[target] = stack

	teleport_fn.call(target, to)
	actions_taken += 1
	acted.emit(ACTION_RETURN, actor, target, {"to": to})

	await _record(target, ACTION_RETURN, actor, target)

	return DotResult.success(to)


## Whether a player has somewhere to be put back to.
func can_return(target: StringName) -> bool:
	return not (_history.get(target, []) as Array).is_empty()


## Forgets a player's return history. Call when they disconnect.
##
## Not optional on a long-running server: a position per player per action, held for ever,
## against ids that are never reused is a slow leak, and the entries are meaningless once
## the player is gone.
func forget(target: StringName) -> void:
	_history.erase(target)


func clear_history() -> void:
	_history.clear()


# --- Internals -------------------------------------------------------------

func _move(
	action: StringName,
	actor: StringName,
	target: StringName,
	to: Variant,
	detail: Dictionary
) -> DotResult:
	if to == null:
		return _refuse(action, actor, target, "no_position", "There is nowhere to go.")

	if not teleport_fn.is_valid():
		return _refuse(action, actor, target, "no_teleport",
			"This game cannot teleport.")

	var blocked := _immunity_refusal(actor, target)
	if blocked != "":
		return _refuse(action, actor, target, "immune", blocked)

	_remember(target)
	teleport_fn.call(target, to)
	actions_taken += 1
	acted.emit(action, actor, target, detail)

	await _record(target, action, actor, target)

	return DotResult.success(to)


## Saves where a player is, so a return has somewhere to go.
##
## Saved BEFORE the move and only when a position can actually be read. Saving after
## would record the destination, so a return would put them where they already are, which
## looks exactly like the return being broken.
func _remember(id: StringName) -> void:
	var at := _position_of(id)

	if at == null:
		return

	var stack: Array = _history.get(id, [])
	stack.append(at)

	while stack.size() > return_depth:
		stack.pop_front()

	_history[id] = stack


func _position_of(id: StringName) -> Variant:
	if not position_fn.is_valid():
		return null

	var at: Variant = position_fn.call(id)

	# Vector2 and Vector3 both, because a 2D game is a first-class user of this.
	if at is Vector2 or at is Vector3:
		return at

	return null


## Moves a landing point back toward the arriving player, so nobody lands inside anybody.
func _stand_off(destination: Variant, arriving_from: Variant) -> Variant:
	if goto_standoff <= 0.0:
		return destination

	if destination is Vector3:
		var to3 := destination as Vector3
		var from3 := arriving_from as Vector3 if arriving_from is Vector3 else Vector3.ZERO
		var away3 := to3 - from3
		# A zero-length direction means the two are already in the same place, which is
		# the case the stand-off exists for, so any direction beats normalising zero.
		if away3.length_squared() < 0.0001:
			away3 = Vector3.BACK
		return to3 - away3.normalized() * goto_standoff

	if destination is Vector2:
		var to2 := destination as Vector2
		var from2 := arriving_from as Vector2 if arriving_from is Vector2 else Vector2.ZERO
		var away2 := to2 - from2
		if away2.length_squared() < 0.0001:
			away2 = Vector2.UP
		return to2 - away2.normalized() * goto_standoff

	return destination


## The refusal message when an actor may not act on a target, or empty when they may.
func _immunity_refusal(actor: StringName, target: StringName) -> String:
	if not immunity_fn.is_valid():
		return ""

	var actor_level := int(immunity_fn.call(actor))
	var target_level := int(immunity_fn.call(target))

	if target_level <= 0:
		return ""

	if actor_level > target_level:
		return ""

	# Equal cannot act on equal, the same rule DotModerationManager applies to
	# punishments and for the same reason: two moderators at the same level teleporting
	# each other around has no correct resolution.
	return "They are protected by a higher immunity (theirs %d, yours %d)." % [
		target_level, actor_level
	]


func _refuse(
	action: StringName, actor: StringName, target: StringName,
	reason: String, message: String
) -> DotResult:
	actions_refused += 1
	refused.emit(action, actor, target, reason)
	return DotResult.fail(
		DotError.CODE_FORBIDDEN if reason == "immune" else DotError.CODE_STATE,
		message,
		"%s %s -> %s" % [action, actor, target]
	)


## Puts the action on somebody's moderation history.
##
## As a WARN, because a warning is the kind that enforces nothing and exists to be read.
## A teleport is not a punishment and must not read as one; what it needs is to be
## answerable when a player asks why they moved.
func _record(
	subject: StringName, action: StringName, actor: StringName, target: StringName
) -> void:
	if not record_actions or manager == null:
		return

	var result: DotResult = await manager.issue(
		DotPunishment.Kind.WARN,
		String(subject),
		"%s by %s" % [String(action), String(actor)],
		String(actor),
		0
	)

	if not result.ok:
		DotLog.debug(CHANNEL, "could not record a moderator action", {
			"why": result.error.message
		})
		return

	var punishment: DotPunishment = result.value
	punishment.evidence = {
		"action": String(action),
		"actor": String(actor),
		"target": String(target),
	}


func describe() -> Dictionary:
	return {
		"taken": actions_taken,
		"refused": actions_refused,
		"tracked": _history.size(),
		"can_teleport": teleport_fn.is_valid(),
		"can_locate": position_fn.is_valid(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("actions   %d taken, %d refused" % [actions_taken, actions_refused])
	out.append("wiring    %s%s" % [
		"position_fn set" if position_fn.is_valid() else "NO position_fn",
		", teleport_fn set" if teleport_fn.is_valid() else ", NO teleport_fn",
	])

	if not teleport_fn.is_valid() or not position_fn.is_valid():
		# Surfaced where an operator looks. Without both callables every action here
		# refuses, which is safe and is also indistinguishable from nobody using it.
		out.append("WARNING   without both callables every action is refused")

	out.append("returns   %d players have somewhere to go back to" % _history.size())

	return out
