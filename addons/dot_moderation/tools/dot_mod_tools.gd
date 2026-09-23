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
##
## [b]The rest of the community admin set — noclip, god, buddha, freeze, slay, slap,
## respawn, health, speed, gravity, give, strip, rename, burn, blind, beacon — is a table of
## handlers, one per ability, that the game fills in.[/b] Same reasoning as the two
## callables above, one step further: this addon cannot know what "god mode" means in a
## deathmatch or whether a lobby has a body to slay, so it owns everything that is the
## same in every game — the immunity check, the audit record, who has which toggle on and
## who turned it on, clearing it when they leave or respawn — and a game supplies only the
## verb:
##
## [codeblock]
## tools.handlers[DotModTools.ACTION_NOCLIP] = func(id: StringName, args: Dictionary) -> DotResult:
##     return DotFpsAdminModifiers.set_noclip(world.player(id).controller, args["on"])
## tools.unsupported_reasons[DotModTools.ACTION_GIVE] = "There is nothing to give here."
##
## await tools.toggle(&"admin:sarah", &"uid:bob", DotModTools.ACTION_NOCLIP)   # on
## await tools.slap(&"admin:sarah", &"uid:bob", 10.0)
## [/codeblock]
##
## An ability with no handler is refused with [constant DotError.CODE_UNSUPPORTED] and the
## game's reason when it gave one, and [method describe_lines] lists what this game
## supports — because "the command exists and does nothing" is indistinguishable from a
## broken command, and an admin is owed the difference.

const CHANNEL := "moderation.tools"
const SERVICE := &"dot_mod_tools"

## An action was carried out.
signal acted(action: StringName, actor: StringName, target: StringName, detail: Dictionary)

## An action was refused. [param reason] is one of `unknown`, `immune`, `no_position`,
## `no_teleport`, `nothing_to_return_to`, `unsupported`, `invalid`, `failed`.
signal refused(action: StringName, actor: StringName, target: StringName, reason: String)

## A toggle changed, by an admin or because its target left or respawned. [param by] is
## empty when nobody chose it — a respawn clearing a freeze.
signal toggled(action: StringName, target: StringName, on: bool, by: StringName)

const ACTION_TELEPORT := &"teleport"
const ACTION_BRING := &"bring"
const ACTION_GOTO := &"goto"
const ACTION_SEND := &"send"
const ACTION_RETURN := &"return"

# The abilities a game supplies handlers for. Names, not an enum, so a game's own verb
# ("launch", "shrink") is a first-class entry in the same table rather than a fork.
const ACTION_NOCLIP := &"noclip"
const ACTION_GOD := &"god"
const ACTION_BUDDHA := &"buddha"
const ACTION_FREEZE := &"freeze"
const ACTION_BLIND := &"blind"
const ACTION_BEACON := &"beacon"
const ACTION_SLAY := &"slay"
const ACTION_SLAP := &"slap"
const ACTION_RESPAWN := &"respawn"
const ACTION_HEALTH := &"health"
const ACTION_SPEED := &"speed"
const ACTION_GRAVITY := &"gravity"
const ACTION_GIVE := &"give"
const ACTION_STRIP := &"strip"
const ACTION_RENAME := &"rename"
const ACTION_BURN := &"burn"

## Abilities that are on or off, and are TRACKED: who has one, and who turned it on.
##
## Tracked here rather than asked of the game, because "is bob frozen, and by whom" is the
## question a second moderator asks before undoing it, and a game that only knows the
## modifier is on cannot answer the second half.
const TOGGLES: Array[StringName] = [
	ACTION_NOCLIP, ACTION_GOD, ACTION_BUDDHA, ACTION_FREEZE, ACTION_BLIND, ACTION_BEACON,
]

## Abilities that hold a multiplier, where 1.0 means none. Tracked like a toggle.
const MULTIPLIERS: Array[StringName] = [ACTION_SPEED, ACTION_GRAVITY]

## Every ability this addon names, in the order [method describe_lines] lists them.
const ABILITIES: Array[StringName] = [
	ACTION_NOCLIP, ACTION_GOD, ACTION_BUDDHA, ACTION_FREEZE, ACTION_SLAY, ACTION_SLAP,
	ACTION_RESPAWN, ACTION_HEALTH, ACTION_SPEED, ACTION_GRAVITY, ACTION_GIVE, ACTION_STRIP,
	ACTION_RENAME, ACTION_BURN, ACTION_BLIND, ACTION_BEACON,
]

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

## Toggles and multipliers that SURVIVE a respawn, re-applied to the new body by
## [method respawned]. Everything else tracked is switched off.
##
## God and buddha persist because an admin who godded somebody to test a map means "for as
## long as I say", and a death is exactly when it would otherwise silently end. Noclip and
## freeze do not: a respawn is a new body in a spawn room, and arriving there frozen or
## flying through the floor is the respawn being broken, not the admin's intent.
@export var persist_on_respawn: PackedStringArray = PackedStringArray(["god", "buddha"])

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

## One handler per ability. `func(target: StringName, args: Dictionary) -> DotResult`.
##
## [param args] always carries `actor`; a toggle adds `on` (bool), a multiplier `scale`,
## [constant ACTION_SLAP] `damage`, [constant ACTION_HEALTH] `value`,
## [constant ACTION_GIVE] `item`, [constant ACTION_RENAME] `name`, [constant ACTION_BURN]
## `seconds`. A multiplier handler should return the value it actually applied as the
## result's value — a game whose speeds are a ladder applies the nearest step, and the
## admin is owed the number they got rather than the one they typed.
var handlers: Dictionary = {}

## Why this game refuses an ability it has no handler for. StringName -> String.
##
## Optional, and worth filling in: "not in this game" is an answer, "there is nothing to
## give in a lobby" is an explanation.
var unsupported_reasons: Dictionary = {}

## Diagnostics.
var actions_taken: int = 0
var actions_refused: int = 0

## id -> Array of previous positions, newest last.
var _history: Dictionary = {}

## action -> {target -> {"by": StringName, "at": int}}, for TOGGLES.
var _toggles: Dictionary = {}

## action -> {target -> {"value": float, "by": StringName}}, for MULTIPLIERS.
var _multipliers: Dictionary = {}

## Counts grants, so a timed release can tell its own grant from a later one made within
## the same second.
var _grants: int = 0


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
func teleport(
	actor: StringName, target: StringName, to: Variant, actor_immunity: int = -1
) -> DotResult:
	return await _move(ACTION_TELEPORT, actor, target, to, {"to": to}, actor_immunity)


## Brings a player to the moderator.
func bring(actor: StringName, target: StringName, actor_immunity: int = -1) -> DotResult:
	var at := _position_of(actor)

	if at == null:
		return _refuse(ACTION_BRING, actor, target, "no_position",
			"Cannot find where you are.")

	return await _move(ACTION_BRING, actor, target, at, {"to": at}, actor_immunity)


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
func send(
	actor: StringName, target: StringName, destination: StringName,
	actor_immunity: int = -1
) -> DotResult:
	var at := _position_of(destination)

	if at == null:
		return _refuse(ACTION_SEND, actor, target, "no_position",
			"Cannot find where they are.")

	return await _move(
		ACTION_SEND, actor, target, _stand_off(at, _position_of(target)),
		{"to": at, "destination": String(destination)}, actor_immunity
	)


## Puts a player back where they were before the last move.
##
## [b]The action that makes the rest of them safe to use.[/b] Without it, "bring" is
## something a moderator hesitates to do mid-round because they cannot undo it, and a
## moderator who hesitates does not moderate. Every move here saves a position, including
## a `goto`, so a moderator can put themselves back too.
func return_player(
	actor: StringName, target: StringName, actor_immunity: int = -1
) -> DotResult:
	var stack: Array = _history.get(target, [])

	if stack.is_empty():
		return _refuse(ACTION_RETURN, actor, target, "nothing_to_return_to",
			"There is nowhere to put them back to.")

	if not teleport_fn.is_valid():
		return _refuse(ACTION_RETURN, actor, target, "no_teleport",
			"This game cannot teleport.")

	var blocked := _immunity_refusal(actor, target, actor_immunity)
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

	# Their toggles too, without calling a handler: the body they applied to is gone, and
	# the next person given this id must not inherit somebody else's noclip.
	for action in _toggles.keys():
		var holders: Dictionary = _toggles[action]
		if holders.erase(target):
			toggled.emit(action, target, false, &"")

	for action in _multipliers.keys():
		(_multipliers[action] as Dictionary).erase(target)


func clear_history() -> void:
	_history.clear()


# --- Abilities -------------------------------------------------------------

## Whether this game supplied a handler for [param action].
func supports(action: StringName) -> bool:
	var handler: Variant = handlers.get(action)
	return handler is Callable and (handler as Callable).is_valid()


## The abilities this game supports, standard ones first and then its own.
func abilities() -> PackedStringArray:
	var out := PackedStringArray()

	for action in ABILITIES:
		if supports(action):
			out.append(String(action))

	for action: Variant in handlers.keys():
		if not ABILITIES.has(StringName(action)) and supports(StringName(action)):
			out.append(String(action))

	return out


## Runs one ability on a player: the immunity check, the handler, the record.
##
## [param actor_immunity] is the caller's immunity when the caller already knows it — a
## console command has it on its context, and asking [member immunity_fn] about an actor
## called "console" answers for a player who does not exist. Left at -1, [member
## immunity_fn] is asked.
##
## [b]Acting on yourself is never an immunity question.[/b] Equal cannot act on equal, and
## everybody is equal to themselves, so without this rule an admin could noclip everybody
## on the server except the one person who asked.
func perform(
	actor: StringName,
	target: StringName,
	action: StringName,
	args: Dictionary = {},
	actor_immunity: int = -1
) -> DotResult:
	if not supports(action):
		var why: String = str(unsupported_reasons.get(action, ""))
		return _refuse(action, actor, target, "unsupported",
			why if why != "" else "This game does not support %s." % String(action))

	var invalid := _validate(action, args)
	if invalid != "":
		return _refuse(action, actor, target, "invalid", invalid)

	var blocked := _immunity_refusal(actor, target, actor_immunity)
	if blocked != "":
		return _refuse(action, actor, target, "immune", blocked)

	var call_args := args.duplicate()
	call_args["actor"] = String(actor)

	var handler: Callable = handlers[action]
	var answer: Variant = await handler.call(target, call_args)
	var result: DotResult = answer if answer is DotResult else DotResult.success(answer)

	if not result.ok:
		actions_refused += 1
		refused.emit(action, actor, target, "failed")
		DotLog.info(CHANNEL, "a game refused an ability", {
			"action": String(action), "target": String(target),
			"why": result.error.message if result.error != null else "",
		})
		return result

	_track(action, actor, target, call_args, result)

	actions_taken += 1
	var detail := call_args.duplicate()
	detail.erase("actor")
	acted.emit(action, actor, target, detail)

	await _record(target, action, actor, target, detail)

	return result


## Turns a toggle on or off. [param on] null flips it.
func toggle(
	actor: StringName,
	target: StringName,
	action: StringName,
	on: Variant = null,
	actor_immunity: int = -1
) -> DotResult:
	var want := not is_active(target, action) if on == null else bool(on)
	return await perform(actor, target, action, {"on": want}, actor_immunity)


func noclip(actor: StringName, target: StringName, on: Variant = null) -> DotResult:
	return await toggle(actor, target, ACTION_NOCLIP, on)


func god(actor: StringName, target: StringName, on: Variant = null) -> DotResult:
	return await toggle(actor, target, ACTION_GOD, on)


func buddha(actor: StringName, target: StringName, on: Variant = null) -> DotResult:
	return await toggle(actor, target, ACTION_BUDDHA, on)


func freeze(actor: StringName, target: StringName, on: Variant = true) -> DotResult:
	return await toggle(actor, target, ACTION_FREEZE, on)


func slay(actor: StringName, target: StringName) -> DotResult:
	return await perform(actor, target, ACTION_SLAY)


## A shove, and optionally some damage. Zero damage is the classic slap: humiliating,
## harmless, and exactly as audited as a slay.
func slap(actor: StringName, target: StringName, damage: float = 0.0) -> DotResult:
	return await perform(actor, target, ACTION_SLAP, {"damage": damage})


func respawn(actor: StringName, target: StringName) -> DotResult:
	return await perform(actor, target, ACTION_RESPAWN)


func set_health(actor: StringName, target: StringName, value: float) -> DotResult:
	return await perform(actor, target, ACTION_HEALTH, {"value": value})


func set_speed(actor: StringName, target: StringName, scale: float) -> DotResult:
	return await perform(actor, target, ACTION_SPEED, {"scale": scale})


func set_gravity(actor: StringName, target: StringName, scale: float) -> DotResult:
	return await perform(actor, target, ACTION_GRAVITY, {"scale": scale})


func give(actor: StringName, target: StringName, item: String) -> DotResult:
	return await perform(actor, target, ACTION_GIVE, {"item": item})


func strip(actor: StringName, target: StringName) -> DotResult:
	return await perform(actor, target, ACTION_STRIP)


func rename(actor: StringName, target: StringName, new_name: String) -> DotResult:
	return await perform(actor, target, ACTION_RENAME, {"name": new_name})


func burn(actor: StringName, target: StringName, seconds: float = 5.0) -> DotResult:
	return await perform(actor, target, ACTION_BURN, {"seconds": seconds})


# --- What is on whom ---------------------------------------------------------

func is_active(target: StringName, action: StringName) -> bool:
	return (_toggles.get(action, {}) as Dictionary).has(target)


## Who turned [param action] on for [param target], or empty.
func applied_by(target: StringName, action: StringName) -> StringName:
	var entry: Variant = (_toggles.get(action, {}) as Dictionary).get(target)

	if entry == null:
		entry = (_multipliers.get(action, {}) as Dictionary).get(target)

	return StringName(str((entry as Dictionary).get("by", ""))) if entry is Dictionary else &""


## The multiplier [param target] is on, 1.0 when none.
func multiplier_of(target: StringName, action: StringName) -> float:
	var entry: Variant = (_multipliers.get(action, {}) as Dictionary).get(target)
	return float((entry as Dictionary).get("value", 1.0)) if entry is Dictionary else 1.0


## Every toggle and multiplier on [param target], as short words: `noclip`, `speed 2`.
func active_on(target: StringName) -> PackedStringArray:
	var out := PackedStringArray()

	for action in TOGGLES:
		if is_active(target, action):
			out.append(String(action))

	for action in MULTIPLIERS:
		var value := multiplier_of(target, action)
		if not is_equal_approx(value, 1.0):
			out.append("%s %s" % [String(action), str(snappedf(value, 0.01))])

	return out


## Switches a toggle off with nobody behind it: a timed freeze running out, a game that
## ends a run. No immunity check, because nobody is acting on anybody; still audited, as
## the system.
func release(target: StringName, action: StringName) -> DotResult:
	if not is_active(target, action):
		return DotResult.success(false)

	return await perform(&"system", target, action, {"on": false}, 100)


## [method release] after [param seconds], if it is still on then.
##
## [b]Only if the same grant is still in force.[/b] A moderator who froze somebody for ten
## seconds, unfroze them at five and froze them again indefinitely at six did not ask for
## the first timer to end the second freeze. The grant's timestamp is what tells them apart.
func release_after(target: StringName, action: StringName, seconds: float) -> void:
	if seconds <= 0.0 or not is_inside_tree():
		return

	var entry: Variant = (_toggles.get(action, {}) as Dictionary).get(target)
	var granted_at: int = int((entry as Dictionary).get("at", 0)) if entry is Dictionary else 0
	var serial: int = int((entry as Dictionary).get("serial", 0)) if entry is Dictionary else 0

	get_tree().create_timer(seconds).timeout.connect(
		func() -> void:
			var now: Variant = (_toggles.get(action, {}) as Dictionary).get(target)
			if now is Dictionary and int((now as Dictionary).get("at", 0)) == granted_at \
					and int((now as Dictionary).get("serial", 0)) == serial:
				var _released: DotResult = await release(target, action)
	)


## A player came back with a new body. Call from the game's own spawn path.
##
## What persists ([member persist_on_respawn]) is applied to the new body, because the body
## a handler changed is gone; everything else tracked is switched off, through its handler,
## so the game's state and this record cannot disagree about it.
##
## [b]Handlers are called here without awaiting them.[/b] This runs inside a game's spawn,
## which must not wait — the same reason a loadout is applied a frame later. A handler that
## suspends still runs; its result simply is not read.
func respawned(target: StringName) -> void:
	for action in TOGGLES:
		if not is_active(target, action):
			continue

		var keep := persist_on_respawn.has(String(action))
		var by: StringName = applied_by(target, action)

		if supports(action):
			(handlers[action] as Callable).call(target, {"on": keep, "actor": String(by)})

		if not keep:
			(_toggles[action] as Dictionary).erase(target)
			toggled.emit(action, target, false, &"")

	for action in MULTIPLIERS:
		var value := multiplier_of(target, action)

		if is_equal_approx(value, 1.0):
			continue

		var keep_value := persist_on_respawn.has(String(action))

		if supports(action):
			(handlers[action] as Callable).call(
				target, {"scale": value if keep_value else 1.0, "actor": ""}
			)

		if not keep_value:
			(_multipliers[action] as Dictionary).erase(target)


# --- Internals -------------------------------------------------------------

func _move(
	action: StringName,
	actor: StringName,
	target: StringName,
	to: Variant,
	detail: Dictionary,
	actor_immunity: int = -1
) -> DotResult:
	if to == null:
		return _refuse(action, actor, target, "no_position", "There is nowhere to go.")

	if not teleport_fn.is_valid():
		return _refuse(action, actor, target, "no_teleport",
			"This game cannot teleport.")

	var blocked := _immunity_refusal(actor, target, actor_immunity)
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
func _immunity_refusal(
	actor: StringName, target: StringName, actor_immunity: int = -1
) -> String:
	# Yourself is never an immunity question; see perform().
	if actor == target:
		return ""

	if not immunity_fn.is_valid():
		return ""

	var actor_level := actor_immunity if actor_immunity >= 0 else int(immunity_fn.call(actor))
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
	var code := DotError.CODE_STATE

	match reason:
		"immune":
			code = DotError.CODE_FORBIDDEN
		"unsupported":
			code = DotError.CODE_UNSUPPORTED
		"invalid":
			code = DotError.CODE_INVALID

	return DotResult.fail(
		code,
		message,
		"%s %s -> %s" % [action, actor, target]
	)


## Why [param args] cannot be what [param action] means, or empty.
##
## Here rather than in each game's handler because every game would write the same four
## lines, and the one that forgot would be the one where "health 0" slays somebody through
## a command that is not supposed to.
func _validate(action: StringName, args: Dictionary) -> String:
	match action:
		ACTION_HEALTH:
			var value := float(args.get("value", 0.0))
			if value <= 0.0:
				return "Health has to be above zero. Use slay to kill somebody."
		ACTION_SPEED, ACTION_GRAVITY:
			if float(args.get("scale", 0.0)) <= 0.0:
				return "A multiplier has to be above zero."
		ACTION_SLAP:
			if float(args.get("damage", 0.0)) < 0.0:
				return "A slap cannot heal."
		ACTION_GIVE:
			if str(args.get("item", "")).strip_edges() == "":
				return "Give what?"
		ACTION_RENAME:
			if str(args.get("name", "")).strip_edges() == "":
				return "Rename them to what?"
		ACTION_BURN:
			if float(args.get("seconds", 0.0)) <= 0.0:
				return "Burn for how long?"

	if TOGGLES.has(action) and not (args.get("on") is bool):
		return "Say whether to turn %s on or off." % String(action)

	return ""


func _track(
	action: StringName, actor: StringName, target: StringName,
	args: Dictionary, result: DotResult
) -> void:
	if TOGGLES.has(action):
		var holders: Dictionary = _toggles.get(action, {})

		if bool(args.get("on", false)):
			_grants += 1
			holders[target] = {
				"by": actor, "at": int(Time.get_unix_time_from_system()), "serial": _grants,
			}
		else:
			holders.erase(target)

		_toggles[action] = holders
		toggled.emit(action, target, bool(args.get("on", false)), actor)
		return

	if MULTIPLIERS.has(action):
		var applied := float(args.get("scale", 1.0))

		if result.value is float or result.value is int:
			applied = float(result.value)

		var entries: Dictionary = _multipliers.get(action, {})

		if is_equal_approx(applied, 1.0):
			entries.erase(target)
		else:
			entries[target] = {"value": applied, "by": actor}

		_multipliers[action] = entries
		return

	# A slay deliberately untracks nothing. The body keeps whatever the handlers put on it
	# until the game respawns it, and respawned() is what switches those off through their
	# handlers — untracking here would leave a frozen modifier on a body this record says
	# is free, and the next respawn would carry it.


## Puts the action on somebody's moderation history.
##
## As a WARN, because a warning is the kind that enforces nothing and exists to be read.
## A teleport is not a punishment and must not read as one; what it needs is to be
## answerable when a player asks why they moved.
func _record(
	subject: StringName, action: StringName, actor: StringName, target: StringName,
	detail: Dictionary = {}
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
	var evidence := {
		"action": String(action),
		"actor": String(actor),
		"target": String(target),
	}

	# What was done, not only that something was: "slapped for 90" and "slapped for 0" are
	# different conversations with the player who asks.
	for key: Variant in detail:
		var value: Variant = detail[key]
		if value is bool or value is int or value is float or value is String:
			evidence[str(key)] = value

	punishment.evidence = evidence


func describe() -> Dictionary:
	return {
		"taken": actions_taken,
		"refused": actions_refused,
		"tracked": _history.size(),
		"can_teleport": teleport_fn.is_valid(),
		"can_locate": position_fn.is_valid(),
		"abilities": abilities(),
		"toggled": _count_tracked(),
	}


func _count_tracked() -> int:
	var total := 0
	for action in _toggles:
		total += (_toggles[action] as Dictionary).size()
	for action in _multipliers:
		total += (_multipliers[action] as Dictionary).size()
	return total


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("actions   %d taken, %d refused" % [actions_taken, actions_refused])
	out.append("wiring    %s%s" % [
		"position_fn set" if position_fn.is_valid() else "NO position_fn",
		", teleport_fn set" if teleport_fn.is_valid() else ", NO teleport_fn",
	])

	if not teleport_fn.is_valid() or not position_fn.is_valid():
		# Surfaced where an operator looks. Without both callables every move here
		# refuses, which is safe and is also indistinguishable from nobody using it.
		out.append("WARNING   without both callables every teleport is refused")

	out.append("returns   %d players have somewhere to go back to" % _history.size())

	var supported := abilities()
	out.append("abilities %s" % (", ".join(supported) if not supported.is_empty() else "none"))

	var refused_list := PackedStringArray()
	for action in ABILITIES:
		if not supports(action):
			var why: String = str(unsupported_reasons.get(action, ""))
			refused_list.append(String(action) if why == "" else "%s (%s)" % [String(action), why])

	if not refused_list.is_empty():
		out.append("refused   %s" % "; ".join(refused_list))

	for action in TOGGLES:
		var holders: Dictionary = _toggles.get(action, {})
		for target: Variant in holders:
			out.append("on        %s %s, by %s" % [
				String(action), str(target), str((holders[target] as Dictionary).get("by", "?"))
			])

	for action in MULTIPLIERS:
		var entries: Dictionary = _multipliers.get(action, {})
		for target: Variant in entries:
			var entry: Dictionary = entries[target]
			out.append("on        %s %s x%s, by %s" % [
				String(action), str(target), str(snappedf(float(entry.get("value", 1.0)), 0.01)),
				str(entry.get("by", "?")),
			])

	return out
