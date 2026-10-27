@tool
extends RefCounted
## Pins the debugger plugin's match of its session to the editor's debugger node, the
## node whose breaked signal carries the reason text for a break, and its connection
## of that node's breaked and stack_dump to the tracker. Stand-in nodes and sessions
## take the place of the editor's debugger tabs, which the headless runner does not
## build; finding the candidates in the live editor, in _setup_session, is left to
## the sweep's parse-error legs.

const Testing := preload("res://test/units/testing.gd")
const DebugBridge := preload("res://addons/godot_mcp_toolkit/transport/debug_bridge.gd")
const DebugSessionTracker := preload("res://addons/godot_mcp_toolkit/transport/debug_session_tracker.gd")


static func run(testing: Testing) -> void:
	_test_match_picks_node_the_session_connects_to(testing)
	_test_match_skips_two_argument_breaked(testing)
	_test_connect_takes_one_argument_stack_dump(testing)
	_test_connect_skips_other_stack_dump_signatures(testing)


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


static func _test_connect_takes_one_argument_stack_dump(testing: Testing) -> void:
	testing.begin("debug bridge connects the debugger node's one-argument stack_dump to the tracker")
	var tracker := DebugSessionTracker.new()
	var node := _StackDumpDebuggerNodeStandIn.new()
	DebugBridge.connect_debugger_node(node, tracker)
	var breaked_connected := node.breaked.is_connected(tracker.on_debugger_node_breaked)
	var stack_dump_connected := node.stack_dump.is_connected(tracker.on_debugger_node_stack_dump)
	tracker.on_session_started()
	tracker.on_session_breaked(false)
	node.stack_dump.emit([{"frame": 0, "file": "res://main.gd", "function": "_ready", "line": 7}])
	var buffer: Array = tracker.get_error_buffer()
	DebugBridge.disconnect_debugger_node(node, tracker)
	var breaked_after := node.breaked.is_connected(tracker.on_debugger_node_breaked)
	var stack_dump_after := node.stack_dump.is_connected(tracker.on_debugger_node_stack_dump)

	testing.ok(breaked_connected, "the node's four-argument breaked → connected")
	testing.ok(stack_dump_connected, "the node's one-argument stack_dump → connected")
	var entry: Dictionary = buffer[0] if buffer.size() == 1 else {}
	testing.eq(str(entry.get("source", "")), "res://main.gd", "an emitted stack_dump → the break entry's source")
	testing.eq(int(entry.get("line", 0)), 7, "an emitted stack_dump → the break entry's line")
	testing.ok(not breaked_after, "disconnected → breaked no longer connected")
	testing.ok(not stack_dump_after, "disconnected → stack_dump no longer connected")
	print("")


static func _test_connect_skips_other_stack_dump_signatures(testing: Testing) -> void:
	testing.begin("debug bridge skips a stack_dump with another signature")
	var tracker := DebugSessionTracker.new()
	var two_argument := _TwoArgumentStackDumpNodeStandIn.new()
	DebugBridge.connect_debugger_node(two_argument, tracker)
	var breaked_connected := two_argument.breaked.is_connected(tracker.on_debugger_node_breaked)
	var two_argument_connected := two_argument.stack_dump.get_connections().size() > 0
	DebugBridge.disconnect_debugger_node(two_argument, tracker)
	var without_stack_dump := _ReasonDebuggerNodeStandIn.new()
	DebugBridge.connect_debugger_node(without_stack_dump, tracker)
	var reason_only_connected := without_stack_dump.breaked.is_connected(tracker.on_debugger_node_breaked)
	DebugBridge.disconnect_debugger_node(without_stack_dump, tracker)
	var reason_only_after := without_stack_dump.breaked.is_connected(tracker.on_debugger_node_breaked)
	without_stack_dump.free()

	testing.ok(breaked_connected, "a two-argument stack_dump → breaked still connected")
	testing.ok(not two_argument_connected, "a two-argument stack_dump → not connected")
	testing.ok(reason_only_connected, "no stack_dump → breaked still connected")
	testing.ok(not reason_only_after, "no stack_dump, disconnected → breaked no longer connected")
	print("")


# The editor's debugger node: its breaked carries the reason text.
class _ReasonDebuggerNodeStandIn:
	extends Node

	signal breaked(reallydid: bool, can_debug: bool, reason: String, has_stackdump: bool)


# The editor's debugger node with its stack_dump: the frames of a break as one Array.
class _StackDumpDebuggerNodeStandIn:
	extends RefCounted

	signal breaked(reallydid: bool, can_debug: bool, reason: String, has_stackdump: bool)
	signal stack_dump(frames: Array)


# A debugger node whose stack_dump has another signature.
class _TwoArgumentStackDumpNodeStandIn:
	extends RefCounted

	signal breaked(reallydid: bool, can_debug: bool, reason: String, has_stackdump: bool)
	signal stack_dump(frames: Array, thread_id: int)


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
