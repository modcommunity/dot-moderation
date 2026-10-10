# Live mod tools and their commands

## Moving people

`DotModTools` is the live half: teleport, bring, goto, send, return, and the handler table below.

**`return_player` is what makes the rest usable.** Without an undo, "bring" is something a moderator hesitates to do mid-round, and a moderator who hesitates does not moderate. The position is saved **before** the move; saving after would record the destination, so a return would put them where they already are, which looks exactly like the return being broken.

- **`goto` stops short.** Two bodies in the same place is a stuck player at best and a physics explosion at worst. When the two are already in the same spot there is no direction to normalise, so a fallback is used rather than producing a NaN position.
- **Anybody may `goto` anybody.** Immunity blocks moving a player, not observing one: a moderator who cannot watch a senior admin cannot do their job.
- **Positions are `Variant`.** A 2D game is a first-class user; naming `Vector3` in a signature would make it something to work around.
- **The return history is capped.** A position per player per action, held for ever against ids that are never reused, is a slow leak on a long-running server.
- **Every action is recorded as a `WARN`**, which enforces nothing. A teleport is not a punishment and must not read as one, but "an admin moved me" needs an answer.

It knows nothing about the world: `position_fn` and `teleport_fn` are the host's, and without both every action refuses. `describe_lines()` says so, because refusing everything is indistinguishable from nobody using it.

## The rest of the admin set is a handler table

`DotModTools.handlers` is one `Callable` per ability (noclip, god, buddha, freeze, slay, slap, respawn, health, speed, gravity, give, strip, rename, burn, blind, beacon), and a game fills in the ones that mean something in it. **Everything that is the same in every game is here; only the verb is the game's.** That is why the addon can still depend on dot-core alone: god mode is `invulnerable` on a `DotHealth` in one game, a flag on a monster in another, and nothing at all in a lobby.

- **An ability with no handler is refused, loudly, with the game's reason.** `unsupported_reasons` exists because "not supported" is an answer and "a 2D arena has no walls to pass through" is an explanation, and a command that exists and silently does nothing is the one an admin files a bug about. `describe_lines()` lists both halves.
- **Toggles are tracked here, with who turned them on.** A game knows a modifier is on; it cannot say that the senior admin put it there, which is the question a second moderator asks before undoing it.
- **Respawn is a new body.** `respawned(id)` switches noclip and freeze off *through their handlers* (so the game's state and this record cannot disagree) and re-applies god and buddha (`persist_on_respawn`), because an admin who godded somebody meant "until I say". **A slay untracks nothing**; the body keeps its freeze until the respawn clears it.
- **Acting on yourself is never an immunity question**, and **a caller may state its own immunity** (`actor_immunity`): the console is not a player, so `immunity_fn("console")` answers about nobody.
- **Validation is here, not in each handler.** `health 0` is refused rather than becoming a second way to slay somebody, and a multiplier is tracked as what the handler *applied*: a game whose speeds are a ladder gives the nearest step, and the admin is told the number they got.
- **`blind` takes a number of seconds where the other toggles take only on|off** (`TIMED_TOGGLES`), because a blind is a spell rather than a state and freeze already worked that way. Only where the target is required: `noclip 5` means the player called 5. The switch words are read first, so `blind bob 1` holds until lifted rather than for one second.
- **A timed release checks it is still the same grant.** A ten-second freeze, lifted at five and re-applied indefinitely at six, must not be ended by the first timer; each grant carries a serial.

## The commands, and why they are here rather than in dot-server

`DotModToolCommands` registers them on any console-shaped host, duck-typed in the shape `DotVoteCommands` set, so this addon names no dot-server class. They cannot live in dot-server because dot-server does not know what a noclip is; they cannot be a game's because every game would write the same target parsing, and the one that got `@all` wrong would noclip a senior admin.

- **One player is the server's `resolve_target`**, the function `kick` uses: the same name forms, the same refusal of an ambiguous name, the same immunity rule. Added here only what the server cannot know: `@all`, `@others`, and `@alive`, `@dead` and `@team:` when the game supplies `alive_fn` and `team_fn`. A protected player is **skipped from a group and counted in the reply**, because `@all` on a server with one senior admin should not do nothing to everybody else.
- **A bare command is the caller**, and naming yourself is checked before `resolve_target`, which would refuse it for equal immunity.
- **A name somebody already has is not registered.** A console handed a duplicate returns the existing command, and a module then unregisters it on unload: someone else's command, gone. A game's own `respawn` wins, and the collision is logged.
- **Every command exists whether or not the game supports it**, so `!noclip` in a lobby answers with the lobby's reason rather than "unknown command".
- **Nothing a player is told names the moderator.**
- **Three flags**: `slay` for handling a person, `cheats` for changing the game, `teleport` for moving people. dot-server's `DotAdminFlags` names the first and last so a group file can grant them without an "unknown flag" warning.
