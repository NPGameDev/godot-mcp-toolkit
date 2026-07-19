@tool
extends RefCounted
## Headless unit shield for the Mode-B runtime autoload's lifecycle invariants.
## Pure property assertions — no tree, no port bind, no editor.

const RuntimeServer := preload("res://addons/godot_mcp_toolkit/runtime/mcp_runtime_server.gd")


static func run(testing) -> void:
	_test_process_mode_always(testing)


# The runtime WebSocket server must keep polling while the game tree is paused (a
# pause menu / gameplay-pausing quit dialog). PROCESS_MODE_ALWAYS keeps its
# _process → pump() loop running under get_tree().paused; the Node default
# (PAUSABLE) would freeze every runtime tool until the game unpaused. Assert the
# node carries that mode from construction so a pause can never freeze Mode B.
static func _test_process_mode_always(testing) -> void:
	testing.begin("runtime server — PROCESS_MODE_ALWAYS (pause-immune)")
	var server := RuntimeServer.new()
	testing.eq(server.process_mode, Node.PROCESS_MODE_ALWAYS,
		"runtime autoload is PROCESS_MODE_ALWAYS so it keeps polling while the tree is paused")
	server.free()
	print("")
