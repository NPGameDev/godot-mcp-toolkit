@tool
extends RefCounted
## Pins the debugger plugin's match of its session to the editor's debugger node, the
## node whose breaked signal carries the reason text for a break. Stand-in nodes and
## sessions take the place of the editor's debugger tabs, which the headless runner
## does not build; finding the candidates in the live editor, in _setup_session, is
## left to the sweep's parse-error legs.

const Testing := preload("res://test/units/testing.gd")
const DebugBridge := preload("res://addons/godot_mcp_toolkit/transport/debug_bridge.gd")


static func run(testing: Testing) -> void:
	_test_match_picks_node_the_session_connects_to(testing)
	_test_match_skips_two_argument_breaked(testing)


static func _test_match_picks_node_the_session_connects_to(testing: Testing) -> void:
	testing.begin("debug bridge picks the debugger node its session connects to")
	var session := _SessionStandIn.new()
	var other_session := _SessionStandIn.new()
	var ours := _ReasonDebuggerNodeStandIn.new()
	var theirs := _ReasonDebuggerNodeStandIn.new()
	theirs.breaked.connect(other_session.on_breaked)
	ours.breaked.connect(session.on_breaked)
	var picked := DebugBridge.find_session_debugger_node([theirs, ours], session)
	var none_connected := DebugBridge.find_session_debugger_node(
			[theirs, ours], _SessionStandIn.new())
	# Compared before the frees: a freed node equals null.
	var picked_is_ours := picked == ours
	var none_picked := none_connected == null
	ours.free()
	theirs.free()

	testing.ok(picked_is_ours, "two debugger nodes → the one whose breaked connects to the session")
	testing.ok(none_picked, "no node's breaked connects to the session → none")
	print("")


static func _test_match_skips_two_argument_breaked(testing: Testing) -> void:
	testing.begin("debug bridge skips a debugger node whose breaked has another signature")
	var session := _SessionStandIn.new()
	var two_argument := _TwoArgumentDebuggerNodeStandIn.new()
	two_argument.breaked.connect(session.on_two_argument_breaked)
	var picked := DebugBridge.find_session_debugger_node([two_argument], session)
	# Compared before the free: a freed node equals null.
	var none_picked := picked == null
	two_argument.free()

	testing.ok(none_picked, "a two-argument breaked connected to the session → none")
	print("")


# The editor's debugger node: its breaked carries the reason text.
class _ReasonDebuggerNodeStandIn:
	extends Node

	signal breaked(reallydid: bool, can_debug: bool, reason: String, has_stackdump: bool)


# A debugger node whose breaked has another signature.
class _TwoArgumentDebuggerNodeStandIn:
	extends Node

	signal breaked(reallydid: bool, can_debug: bool)


# The editor's debugger session, as far as the match sees it: an object with a
# handler connected to its node's breaked.
class _SessionStandIn:
	extends RefCounted

	func on_breaked(_really_did: bool, _can_debug: bool, _reason: String, _has_stackdump: bool) -> void:
		pass

	func on_two_argument_breaked(_really_did: bool, _can_debug: bool) -> void:
		pass
