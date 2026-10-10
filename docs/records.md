# Punishments as records

## Why this exists next to dot-server, which already bans

dot-server has bans, kicks, admin flags with immunity and an audit log, and none of that changes. What it does not have is a **mute that outlives a session**: `DotClientSession.muted`, `gagged` and `mute_expires_at` live on a session that is destroyed when its player disconnects, so a muted player reconnects and can talk. That is the first thing anybody who has been muted tries, and the most common complaint on any community server.

**Bans persisting and mutes not is not a design.** It is an accident of where the state happened to live. Here a mute is the same kind of record a ban is: stored, expiring, scoped, revocable, and on the player's history.

There is a **deliberate overlap**: this does bans too, for a project not using dot-server. A deployment should pick one list rather than run both, and the README says so.

## A punishment is a record, not a flag

`BAN`, `KICK`, `VOICE_MUTE`, `GAG` and `WARN` are one record with a different kind, because a server asks the same four questions about each: is it in force, who did it, why, and when does it end.

- **A kick and a warning are never active.** They happened; they are not still happening. A kick that read as active would keep a player out for ever.
- **`expires_at == 0` means permanent.** The alternative reading, "expired at the epoch", is exactly the bug that lets everybody back in.
- **A revoke keeps the record.** The history is the point.
- **The player message never names the moderator.** That is how a moderator gets harassed, and it is not information a player needs in order to appeal.
- **`kind_token()` is the storage key and `kind_name()` is for humans.** The human name of `VOICE_MUTE` is `"voice muted"`, with a space; writing that and reading it back fell through to `WARN`, which enforces nothing ([history](history.md)).
- **An empty scope on either side means everything** (`applies_to`): a single server that never sets a scope must still see punishments that name one.

## Expiry is answered on read, never swept

A punishment that has expired but not yet been noticed is indistinguishable from one still in force, and the read path is the only place it matters. A sweep additionally means a server that was off overnight comes up enforcing yesterday's mutes until its timer fires. Same choice `DotClientSession.is_silenced()` and `DotBanManager` make.

## The subject is never a peer id

A peer id is reused within minutes and means nothing after a disconnect, so a punishment keyed on one is a punishment against whoever connects next.

`DotModerationManager.key_for_peer` is where a deployment's identity model plugs in: dot-user's pseudonymous id, an account uid, a device id for a guest. **Left unset the mapping is `str(peer)`, which is correct for a single-process test and wrong on a real server in a way that enforces nothing and reports nothing.** It warns once on the first lookup and again in `describe_lines()`, because that is where an operator looks.

## An address is a subject too, and how it is spelled is the whole trick

A subject is opaque, but opaque and "however each caller wrote it" are not the same thing. A ban filed against `1.2.3.4` and a check for the `1.2.3.4:51234` a transport actually reports are two strings that never meet, and nothing errors. `DotPunishmentSubject.for_address` strips the port, the scheme and the brackets; `for_uid` adds the prefix if it is not already there; a subject with no prefix at all is still legal, because a deployment that has always written bare ids keeps working.

`ban_address` and `ban_uid` exist as a pair on purpose. An account ban is exact and only works on somebody who has an account; a guest comes back as a different guest, which is most of the people a server has to remove. An address ban catches a household and everybody behind one NAT and is defeated by a router reboot. Neither is sufficient alone; dot-server's `DotBanManager` reached the same conclusion first.

Loopback is refused, as is an address the transport could not report. Both are a mistyped argument far more often than a decision: one locks the operator out of their own listen server and the other bans everybody at once.

## `dot_ban_source`, or the ban that stops nobody

**Nothing in this addon can refuse a connection.** There is no session list here and no socket. So a `BAN` recorded with nothing asking about it is a row in a file, and the moderator who issued it has no way to tell the difference.

So the manager registers under `dot_ban_source` (`register_ban_source`, on by default) and answers `check_admission(uid: String, address: String) -> DotResult`. dot-server calls it twice per join: on the address before the client has said who it is, and on both once it has. dot-server's `examples/dedicated_server.gd` loads this addon by path, registers it, and asserts a real `DotServer` refuses a real connection.

- **Both spellings of a person are checked.** `check_admission("backbone:evil", …)` and `check_admission("uid:backbone:evil", …)` both refuse, because this addon cannot know which convention a deployment writes, and checking one spelling enforces nothing for the other, silently.
- **`describe_lines()` warns when bans are in force and nothing is registered.** The likeliest misconfiguration is the one where every part is correct and nobody is asking.

## The join with dot-voice, and why it is tested

`DotModerationManager` publishes itself in `DotRegistry` under `dot_mute_source` and answers `is_voice_muted(peer)`. `DotVoiceRouter` looks that name up and calls that method. Neither addon imports the other, and a project with only one of them works.

**That shape is exactly how every expensive bug in this family has started** (a call by name on a client that offered different names; four call sites finding a null service without one erroring). So `_test_voice_actually_asks` runs both halves for real: a moderator mutes a player, the router silences them without being told, the manager is destroyed and rebuilt from the file, and the player is still silenced. The suite links `addons/dot_voice` for it, and that section fails loudly rather than skipping without it: "0 failures" from a suite that ran nothing is how a family ships two ends that never met.

## Immunity, in both directions

Immunity is about who may be **acted on**, not only who may act, and the second half is the one that usually gets left out: without it a junior can quietly reverse every decision above them.

**Equal cannot act on equal** by default. Two moderators at the same level muting each other in a loop has no correct resolution, so it is forbidden rather than raced.

**Zero means no immunity, not the highest rank.** Requiring strictly greater immunity unconditionally meant a punishment issued at the default of 0 could never be lifted by a caller at the default of 0, which is every ordinary `unmute` on a server that has not configured immunity.

**Acting on yourself is never an immunity question**: everybody is equal to themselves, so the rule as written would refuse an admin noclipping themselves.

## Deliberately not here

- **Console commands for punishments.** `mute`, `gag` and `ban` belong to dot-server's console, which has permission checking, chat triggers, player targeting and an audit trail. This is the record behind them, and `dot_ban_source` is how the two halves meet. The live tools are the one exception ([mod-tools.md](mod-tools.md)): dot-server cannot know what they mean.
- **A per-address connection limit.** Admission belongs where the sessions are: `sv_max_connections_per_ip` and `DotAddressGuard`, in dot-server.
- **Kicking anybody.** No session list, no socket. It records that a kick happened.
- **An appeals workflow.** `evidence` holds a ticket number; the workflow is a website.
- **Chat filtering.** dot-server sanitises chat already, and a word list is a policy rather than a mechanism.
