@tool
class_name DotPunishment
extends Resource

## One moderation action against one player, as a record rather than as a flag.
##
## [b]A ban, a gag, a voice mute and a warning are the same thing with a different
## kind.[/b] They all have a subject, a reason, somebody who issued them, a moment they
## were issued and a moment they expire, and a server needs the same four questions
## answered about each: is it in force, who did it, why, and when does it end. Modelling
## them separately is how a codebase ends up with bans that persist and mutes that do not,
## which is the single most common complaint on any community server: [i]he just
## reconnects.[/i]
##
## [codeblock]
## var mute := DotPunishment.create(
##     DotPunishment.Kind.VOICE_MUTE, "uid:1234", "mic spam", "admin:sarah", 3600
## )
## [/codeblock]

enum Kind {
	## Cannot connect at all.
	BAN = 0,
	## Removed from the server once. Has no duration; it is history, not a state.
	KICK = 1,
	## May not use voice.
	VOICE_MUTE = 2,
	## May not use text chat. Usually called a gag, and so it is here.
	GAG = 3,
	## On record, enforcing nothing. What a moderator issues before they issue anything
	## else, and what makes the next decision defensible.
	WARN = 4,
}

## Stable id, so a revoke names one record rather than "the most recent mute".
@export var id: String = ""

@export var kind: Kind = Kind.WARN

## Who this is against.
##
## [b]An opaque key, and deliberately not a peer id.[/b] A peer id is reused within
## minutes and means nothing after a disconnect, so a punishment keyed on one is a
## punishment against whoever connects next. What goes here is whatever a deployment
## uses as a durable identity: dot-user's pseudonymous id, an account uid, or a device
## id for a guest. [DotModerationManager.key_for_peer] is where that mapping lives.
@export var subject: String = ""

## Shown to the player. The one field they actually read, so it is required.
@export var reason: String = ""

## Who issued it, as a label rather than as an id: "console", "admin:sarah", "vote".
@export var issuer: String = ""

## Unix seconds.
@export var issued_at: int = 0

## Unix seconds, or 0 for indefinite.
##
## [b]Zero means for ever, and that is worth being explicit about[/b] because the
## alternative reading, "expired at the epoch", is exactly the bug that lets everybody
## walk back in.
@export var expires_at: int = 0

## Which servers this applies to. Empty applies everywhere.
##
## A community running a surf server and a deathmatch server does not always want a mute
## on one to be a mute on the other.
@export var scope: String = ""

## Immunity level of whoever issued it, so a junior cannot revoke a senior's action.
@export var issuer_immunity: int = 0

## Set when the punishment has been lifted early. Kept rather than deleted, because the
## history is the point.
@export var revoked: bool = false
@export var revoked_by: String = ""
@export var revoked_at: int = 0
@export var revoke_reason: String = ""

## Free-form, for a link to a demo, a chat log excerpt, or a ticket number.
@export var evidence: Dictionary = {}


static func create(
	p_kind: Kind,
	p_subject: String,
	p_reason: String,
	p_issuer: String = "console",
	duration_sec: int = 0,
	p_scope: String = ""
) -> DotPunishment:
	var punishment := DotPunishment.new()
	punishment.kind = p_kind
	punishment.subject = p_subject
	punishment.reason = p_reason
	punishment.issuer = p_issuer
	punishment.issued_at = int(Time.get_unix_time_from_system())
	punishment.expires_at = (
		punishment.issued_at + duration_sec if duration_sec > 0 else 0
	)
	punishment.scope = p_scope
	punishment.id = DotHash.random_hex(8)
	return punishment


## Whether this is in force at [param now].
##
## [b]Expiry is answered on read and never swept on a timer.[/b] A punishment that has
## expired but not yet been noticed is indistinguishable from one still in force, and the
## read path is the only place it matters. A sweep additionally means a server that was
## off overnight comes up enforcing yesterday's mutes until its timer fires.
func is_active(now: int = 0) -> bool:
	if revoked:
		return false

	# A kick is an event, not a state. It happened; it is not still happening.
	if kind == Kind.KICK or kind == Kind.WARN:
		return false

	if expires_at == 0:
		return true

	var at := now if now > 0 else int(Time.get_unix_time_from_system())
	return at < expires_at


## Whether this record applies on a server running [param server_scope].
##
## Empty on either side means everything: a punishment with no scope applies wherever it
## is read, and a server with no scope enforces whatever it is given. The second half is
## the one that matters in practice, because it is the unconfigured case: a community
## with one server never sets a scope, and a punishment that named one would otherwise be
## invisible to the only server there is.
func applies_to(server_scope: String) -> bool:
	return scope == "" or server_scope == "" or scope == server_scope


## Seconds left, or -1 for indefinite, or 0 for expired.
func remaining(now: int = 0) -> int:
	if expires_at == 0:
		return -1
	var at := now if now > 0 else int(Time.get_unix_time_from_system())
	return maxi(0, expires_at - at)


func is_permanent() -> bool:
	return expires_at == 0


## What a player is told. Never names the issuer.
##
## [b]Deliberate.[/b] Telling a player which moderator muted them is how a moderator gets
## harassed, and it is information the player does not need in order to appeal through
## whatever channel the community actually uses.
func player_message() -> String:
	var what := kind_name(kind)
	var reason_text := reason if reason != "" else "no reason given"

	if is_permanent():
		return "You are %s: %s" % [what, reason_text]

	var left := remaining()

	if left <= 0:
		return "You are %s: %s" % [what, reason_text]

	return "You are %s for %s: %s" % [what, format_duration(left), reason_text]


## The machine-readable token a record is stored under.
##
## [b]Separate from [method kind_name], and that separation is a bug this suite
## found.[/b] `to_dictionary` wrote `kind_name(VOICE_MUTE)`, which is the string a player
## reads: "voice muted", with a space. `kind_from_name` had no case for it, so it fell
## through to the default and every stored voice mute loaded back as a `WARN` — and a
## warning enforces nothing, so the mute silently stopped existing the moment the file
## was read again. Which is to say: the one thing the addon is for, persisting a mute
## across a reconnect, was the thing that did not work, and nothing errored.
##
## The two ends of a serialisation are exactly as capable of never meeting as the two
## ends of a wire, and this family has been caught by both.
static func kind_token(k: Kind) -> String:
	match k:
		Kind.BAN: return "ban"
		Kind.KICK: return "kick"
		Kind.VOICE_MUTE: return "voice_mute"
		Kind.GAG: return "gag"
		Kind.WARN: return "warn"
	return "warn"


## What a player is shown. Never used as a storage key; see [method kind_token].
static func kind_name(k: Kind) -> String:
	match k:
		Kind.BAN: return "banned"
		Kind.KICK: return "kicked"
		Kind.VOICE_MUTE: return "voice muted"
		Kind.GAG: return "gagged"
		Kind.WARN: return "warned"
	return "punished"


static func kind_from_name(name: String) -> Kind:
	match name.strip_edges().to_lower():
		"ban", "banned": return Kind.BAN
		"kick", "kicked": return Kind.KICK
		"mute", "voice_mute", "voice": return Kind.VOICE_MUTE
		"gag", "gagged", "chat": return Kind.GAG
		_: return Kind.WARN


## Human duration, for a console listing and for the player message.
static func format_duration(seconds: int) -> String:
	if seconds <= 0:
		return "0s"
	if seconds < 60:
		return "%ds" % seconds
	if seconds < 3600:
		return "%dm" % int(seconds / 60)
	if seconds < 86400:
		return "%dh %dm" % [int(seconds / 3600), int((seconds % 3600) / 60)]
	return "%dd %dh" % [int(seconds / 86400), int((seconds % 86400) / 3600)]


func validate() -> DotResult:
	if subject.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "A punishment needs somebody to be against."
		)

	if id.strip_edges() == "":
		return DotResult.fail(DotError.CODE_INVALID, "A punishment needs an id.")

	if expires_at != 0 and expires_at <= issued_at:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A punishment that expires before it was issued enforces nothing.",
			"issued %d, expires %d" % [issued_at, expires_at]
		)

	return DotResult.success(true)


func to_dictionary() -> Dictionary:
	var out := {
		"id": id,
		"kind": kind_token(kind),
		"subject": subject,
		"reason": reason,
		"issuer": issuer,
		"issued_at": issued_at,
		"expires_at": expires_at,
	}

	# Sparse, because a moderation file on a community server is a file a person opens
	# in a text editor when something has gone wrong.
	if scope != "":
		out["scope"] = scope
	if issuer_immunity != 0:
		out["issuer_immunity"] = issuer_immunity
	if revoked:
		out["revoked"] = true
		out["revoked_by"] = revoked_by
		out["revoked_at"] = revoked_at
		if revoke_reason != "":
			out["revoke_reason"] = revoke_reason
	if not evidence.is_empty():
		# Duplicated, not handed out. A Dictionary is a reference in GDScript, and this
		# family has already shipped that bug three times: every scoped leaderboard and
		# the template it came from were one object.
		out["evidence"] = evidence.duplicate(true)

	return out


static func from_dictionary(data: Dictionary) -> DotPunishment:
	var punishment := DotPunishment.new()

	punishment.id = str(data.get("id", ""))
	punishment.kind = kind_from_name(str(data.get("kind", "warn")))
	punishment.subject = str(data.get("subject", ""))
	punishment.reason = str(data.get("reason", ""))
	punishment.issuer = str(data.get("issuer", ""))
	punishment.issued_at = int(data.get("issued_at", 0))
	punishment.expires_at = int(data.get("expires_at", 0))
	punishment.scope = str(data.get("scope", ""))
	punishment.issuer_immunity = int(data.get("issuer_immunity", 0))
	punishment.revoked = bool(data.get("revoked", false))
	punishment.revoked_by = str(data.get("revoked_by", ""))
	punishment.revoked_at = int(data.get("revoked_at", 0))
	punishment.revoke_reason = str(data.get("revoke_reason", ""))

	var evidence_value: Variant = data.get("evidence", {})
	punishment.evidence = (
		(evidence_value as Dictionary).duplicate(true)
		if evidence_value is Dictionary else {}
	)

	return punishment


func describe() -> Dictionary:
	return to_dictionary()


func _to_string() -> String:
	return "DotPunishment(%s %s %s)" % [kind_name(kind), subject, id]
