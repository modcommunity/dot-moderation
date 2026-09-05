@tool
class_name DotPunishmentSubject
extends RefCounted

## How a [DotPunishment]'s subject is spelled, so two servers spell it the same way.
##
## [b]A subject is an opaque string and that is the problem this solves.[/b] Opaque is
## right — a deployment keys punishments on dot-user's pseudonymous id, an account uid or
## a device id, and this addon must not care which — but "opaque" and "however each caller
## felt like writing it" are not the same thing. A ban filed against
## [code]1.2.3.4[/code] and a check for [code]ip:1.2.3.4:51234[/code] are two strings that
## never meet, and nothing errors: the ban is in the file, the player walks in, and the
## moderator is told the system works.
##
## [codeblock]
## DotPunishmentSubject.for_uid("backbone:abc")     # "uid:backbone:abc"
## DotPunishmentSubject.for_address("1.2.3.4:5123") # "ip:1.2.3.4"   (port dropped)
## DotPunishmentSubject.is_address("ip:1.2.3.4")    # true
## [/codeblock]
##
## Anything already carrying a prefix is left alone, and anything with no prefix at all is
## still a legal subject — a deployment that has always written bare uids keeps working.

## Prefix for an account, a pseudonymous id, or a device id. Whatever a person is.
const PREFIX_UID := "uid:"

## Prefix for a network address. Whatever a machine is.
const PREFIX_IP := "ip:"

## Addresses that are never a sensible punishment subject.
##
## Banning loopback locks the operator out of their own listen server and is almost always
## a mistyped argument — the same refusal [method DotBanManager.ban_address] makes in
## dot-server, for the same reason.
const NEVER_BANNABLE := ["127.0.0.1", "::1", "localhost"]


## The subject for a durable person id.
static func for_uid(uid: String) -> String:
	var value := uid.strip_edges()

	if value == "":
		return ""

	if value.begins_with(PREFIX_UID) or value.begins_with(PREFIX_IP):
		return value

	return PREFIX_UID + value


## The subject for a network address, with any port and any URL decoration removed.
static func for_address(address: String) -> String:
	var host := normalise_address(address)

	if host == "":
		return ""

	return PREFIX_IP + host


## Strips a scheme, a path and a port, and returns the bare host.
##
## Peer addresses arrive with ports attached and in varying IPv6 forms, so without this a
## punishment against [code]1.2.3.4[/code] would not match the [code]1.2.3.4:51234[/code]
## a transport reports. [DotTransport] already knows how to take an address apart,
## including the bracketed IPv6 case, so this does not learn it a second time.
static func normalise_address(address: String) -> String:
	var raw := address.strip_edges()

	if raw == "":
		return ""

	if raw.begins_with(PREFIX_IP):
		raw = raw.substr(PREFIX_IP.length())

	var parts := DotTransport.normalise_address(raw, 0)
	var host := str(parts["host"])

	return (host if host != "" else raw).to_lower()


static func is_address(subject: String) -> bool:
	return subject.begins_with(PREFIX_IP)


static func is_uid(subject: String) -> bool:
	return subject.begins_with(PREFIX_UID)


## Whether an address may be punished at all.
static func is_bannable_address(address: String) -> bool:
	var host := normalise_address(address)
	return host != "" and host != "unknown" and not NEVER_BANNABLE.has(host)


## A short label for a listing: the kind of subject and the value.
static func describe(subject: String) -> String:
	if is_address(subject):
		return "address %s" % subject.substr(PREFIX_IP.length())
	if is_uid(subject):
		return "account %s" % subject.substr(PREFIX_UID.length())
	return subject
