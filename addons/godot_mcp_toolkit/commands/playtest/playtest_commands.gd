@tool
extends RefCounted
## game.* / debugger.get_log command registration orchestrator — wires the play
## session lifecycle (game.start / game.stop) and the cached debugger.get_log
## reader onto the registry, and injects/tears down the debug bridge. Holds no
## subdomain logic: game.start/stop delegate to the Play-Session Control child,
## debugger.get_log delegates to the Debug-Log Retrieval child, and the bridge
## inject (register) + teardown (clear_debug_bridge) are forwarded to the
## log-reader child that owns the bridge state.

const _Control := preload("res://addons/godot_mcp_toolkit/commands/playtest/playtest_control.gd")
const _LogReader := preload("res://addons/godot_mcp_toolkit/commands/playtest_log_reader.gd")


static func register(registry: MCPToolkitCommandRegistry, _server: Node,
		debug_bridge: RefCounted = null) -> void:
	_LogReader.set_debug_bridge(debug_bridge)
	# game.start / game.stop mutate (launch / stop a play session), so they are
	# NOT read-only. Exclusive-execution is the sole serialization driver: it
	# forces single-in-flight ordering regardless of read-only status, which is
	# what these session-lifecycle mutators require.
	registry.add("game.start", func(parameters: Dictionary) -> Dictionary:
		return await _Control.cmd_game_start(parameters)
	, MCPToolkitCommandOptions.new().mark_exclusive_execution())
	registry.add("game.stop", func(parameters: Dictionary) -> Dictionary:
		return _Control.cmd_game_stop(parameters)
	, MCPToolkitCommandOptions.new().mark_exclusive_execution().mark_scene_independent())
	registry.add("debugger.get_log", func(parameters: Dictionary) -> Dictionary:
		return _LogReader.cmd_debugger_get_log(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())


static func clear_debug_bridge() -> void:
	_LogReader.clear_debug_bridge()
