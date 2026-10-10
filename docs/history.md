# History

Bugs worth recognising if they come back. All parsed clean and none errored. The rule each left is in [records.md](records.md), [storage.md](storage.md) or [mod-tools.md](mod-tools.md).

- **A stored voice mute loaded back as a warning.** `to_dictionary` wrote `kind_name(VOICE_MUTE)`, the string a *player* reads (`"voice muted"`, with a space); `kind_from_name` had no case for it and fell through to `WARN`. The one thing this addon exists for, persisting a mute across a reconnect, did not work. **The two ends of a serialisation are exactly as capable of never meeting as the two ends of a wire.**
- **A punishment at the default immunity could never be lifted**: strictly-greater immunity at 0 against 0.
- **A server with no scope saw no scoped punishments**: `applies_to` required the scopes to match or the punishment to be unscoped.
- **The REST store reported "the API did not return an object" on every successful read**, because it reached for `.value["json"]` on a `DotHttp.get_json` result that was already the body: a failure blaming the far end for something on this side. Found by a real HTTP server; a mock would have passed.
- **The REST store read any JSON object as an empty list**, one default argument away from banning nobody.
- **dot-moderation carried its own SQL drivers and DDL**: the class names collided with dot-sql's in any project linking both, `CREATE INDEX IF NOT EXISTS` does not exist in MySQL 8, and a metadata column named `key` is a reserved word there (`ERROR 1064`). Moved to dot-sql.
