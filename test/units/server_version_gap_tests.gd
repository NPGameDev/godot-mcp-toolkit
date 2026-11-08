@tool
extends RefCounted
## Unit tests for the dock's server version gap: which state each connected server gets
## against the recommended version, the newest known toolkit and the exemptions, and
## which versions each state's line names. The rows pin the state, not the wording.

const Testing := preload("res://test/units/testing.gd")
const ServerVersionGap := preload("res://addons/godot_mcp_toolkit/ui/dock/status/server_version_gap.gd")
const PeerCompat := preload("res://addons/godot_mcp_toolkit/transport/peer_compat.gd")

const _RECOMMENDED := "1.1.2"
const _NEWER_TOOLKIT := "1.3.0"


static func run(testing: Testing) -> void:
	_test_state_table(testing)
	_test_recommended_comes_from_the_caller(testing)
	_test_prerelease_recommended_says_nothing(testing)
	_test_line_names_the_versions(testing)


# Each row: what the case is, the floor verdict's state, the server version, the newest
# known toolkit, the version setting, and the state the dock reports.
static func _test_state_table(testing: Testing) -> void:
	testing.begin("Server version gap: the state each connected server gets")
	var rows := [
		["a patch older", PeerCompat.STATE_OK, "1.1.1", "", "", ServerVersionGap.SERVER_OLDER],
		["a minor older", PeerCompat.STATE_OK, "1.0.0", "", "", ServerVersionGap.SERVER_OLDER],
		["a major older", PeerCompat.STATE_OK, "0.9.0", "", "", ServerVersionGap.SERVER_OLDER],
		["older, with a newer toolkit known", PeerCompat.STATE_OK, "1.1.1", _NEWER_TOOLKIT, "", ServerVersionGap.SERVER_OLDER],
		["a patch newer, no newer toolkit known", PeerCompat.STATE_OK, "1.1.3", "", "", ServerVersionGap.NONE],
		["a patch newer, a newer toolkit known", PeerCompat.STATE_OK, "1.1.3", _NEWER_TOOLKIT, "", ServerVersionGap.SERVER_NEWER],
		["a minor newer, a newer toolkit known", PeerCompat.STATE_OK, "1.2.0", _NEWER_TOOLKIT, "", ServerVersionGap.SERVER_NEWER],
		["a major newer, a newer toolkit known", PeerCompat.STATE_OK, "2.0.0", _NEWER_TOOLKIT, "", ServerVersionGap.SERVER_NEWER],
		["the same version", PeerCompat.STATE_OK, _RECOMMENDED, "", "", ServerVersionGap.NONE],
		["the same version, a newer toolkit known", PeerCompat.STATE_OK, _RECOMMENDED, _NEWER_TOOLKIT, "", ServerVersionGap.NONE],
		["a prerelease", PeerCompat.STATE_OK, "1.2.0-beta", _NEWER_TOOLKIT, "", ServerVersionGap.NONE],
		["no version", PeerCompat.STATE_OK, "", _NEWER_TOOLKIT, "", ServerVersionGap.NONE],
		["a leading zero only the skew reads", PeerCompat.STATE_OK, "01.1.1", _NEWER_TOOLKIT, "", ServerVersionGap.NONE],
		["a sign only the skew reads", PeerCompat.STATE_OK, "+1.1.1", _NEWER_TOOLKIT, "", ServerVersionGap.NONE],
		["a skipped check (local server)", PeerCompat.STATE_SKIPPED, "1.1.1", "", "", ServerVersionGap.NONE],
		["no peer", PeerCompat.STATE_NONE, "1.1.1", "", "", ServerVersionGap.NONE],
		["a server below the floor", PeerCompat.STATE_SERVER_BELOW_FLOOR, "1.1.1", "", "", ServerVersionGap.NONE],
		["a toolkit below the floor", PeerCompat.STATE_TOOLKIT_BELOW_FLOOR, "1.1.1", "", "", ServerVersionGap.NONE],
		["setting latest", PeerCompat.STATE_OK, "1.1.1", "", "latest", ServerVersionGap.NONE],
		["setting a version", PeerCompat.STATE_OK, "1.1.1", "", "1.1.1", ServerVersionGap.NONE],
		["setting only spaces", PeerCompat.STATE_OK, "1.1.1", "", "  ", ServerVersionGap.SERVER_OLDER],
	]
	for row: Array in rows:
		var actual: String = ServerVersionGap.state(str(row[1]), str(row[2]), _RECOMMENDED, str(row[3]), str(row[4]))
		var expected := str(row[5])
		testing.eq(actual, expected, "%s → %s" % [row[0], expected if not expected.is_empty() else "nothing"])
	print("")


# Far above the toolkit's own constant, so a state read from the constant gets both rows
# wrong: it would call each of these servers newer.
static func _test_recommended_comes_from_the_caller(testing: Testing) -> void:
	testing.begin("Server version gap: the recommended version passed in decides, not the toolkit's constant")
	var at_it := ServerVersionGap.state(PeerCompat.STATE_OK, "99.0.0", "99.0.0", _NEWER_TOOLKIT, "")
	var below_it := ServerVersionGap.state(PeerCompat.STATE_OK, "98.0.0", "99.0.0", _NEWER_TOOLKIT, "")
	testing.eq(at_it, ServerVersionGap.NONE, "a server at the version passed in → nothing")
	testing.eq(below_it, ServerVersionGap.SERVER_OLDER, "a server below it → older")
	print("")


static func _test_prerelease_recommended_says_nothing(testing: Testing) -> void:
	testing.begin("Server version gap: a prerelease recommended version compares as nothing")
	var below := ServerVersionGap.state(PeerCompat.STATE_OK, "1.1.1", "1.2.0-beta", _NEWER_TOOLKIT, "")
	var above := ServerVersionGap.state(PeerCompat.STATE_OK, "1.3.0", "1.2.0-beta", _NEWER_TOOLKIT, "")
	testing.eq(below, ServerVersionGap.NONE, "a server below it → nothing")
	testing.eq(above, ServerVersionGap.NONE, "a server above it → nothing")
	print("")


static func _test_line_names_the_versions(testing: Testing) -> void:
	testing.begin("Server version gap: each state's line names the versions it is about")
	var older := ServerVersionGap.line(ServerVersionGap.SERVER_OLDER, "1.1.1", _RECOMMENDED, "")
	var newer := ServerVersionGap.line(ServerVersionGap.SERVER_NEWER, "1.1.3", _RECOMMENDED, _NEWER_TOOLKIT)
	testing.ok("1.1.1" in older and _RECOMMENDED in older, "older → the server and the recommended version")
	testing.ok("1.1.3" in newer and _RECOMMENDED in newer and _NEWER_TOOLKIT in newer,
			"newer → the server, the recommended version and the newer toolkit")
	testing.eq(ServerVersionGap.line(ServerVersionGap.NONE, "1.1.1", _RECOMMENDED, ""), "", "nothing to say → no line")
	print("")
