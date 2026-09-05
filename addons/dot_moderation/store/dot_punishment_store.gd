@tool
class_name DotPunishmentStore
extends RefCounted

## Where punishments live.
##
## [b]The interface exists so a community running eight servers can share one list.[/b]
## The default keeps them in a JSON file on the machine that issued them, which is right
## for one server and is the reason this works unconfigured. It is wrong the moment there
## are two: a player muted on the surf server walks into the deathmatch server and is not
## muted, which is the same "he just reconnects" complaint one level up.
##
## Subclass and point at a database or an HTTP service. Three rules the default obeys and
## a subclass must too, each of which is a specific failure:
##
## - [b]A failed load keeps whatever is already in force.[/b] Returning an empty list on
##   an error readmits everybody who was ever removed, and does it silently.
## - [b]Writes are awaited before the in-memory set changes[/b], so a store that refuses
##   does not leave a punishment that exists only on one server.
## - [b][method is_writable] returning false is legitimate[/b]: a server that enforces a
##   centrally managed list should say so rather than appear to work and lose the record
##   on the next refresh.

const CHANNEL := "moderation.store"


## Short name, for logs and for the console listing.
func store_name() -> String:
	return "none"


## Whether this store accepts writes.
func is_writable() -> bool:
	return false


## Loads every punishment. A failure must leave the caller's current set alone.
func load_all() -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "This store cannot load."
	)


## Persists one punishment. Awaited before the caller changes anything.
func put(_punishment: DotPunishment) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "This store is read only."
	)


## Persists an update to one already stored, such as a revoke.
func update(punishment: DotPunishment) -> DotResult:
	return await put(punishment)


## Removes one permanently. Rare: a revoke keeps the record, which is the point.
func remove(_id: String) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "This store is read only."
	)


func describe() -> Dictionary:
	return {"store": store_name(), "writable": is_writable()}
