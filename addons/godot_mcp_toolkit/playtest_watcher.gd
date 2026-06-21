@tool
extends RefCounted
## Edge-detects the play→stop transition during a playtest.
##
## The plugin polls poll() each _process. On a play→stop edge this clears the
## runtime registry and proactively tells the MCP server bridge the game stopped,
## so the runtime channel is torn down immediately — no wait for the next
## callRuntime() to discover the dead connection.
##
## Editor-only: uses EditorInterface.is_playing_scene(), so it is constructed by
## the editor-only plugin.gd and never reached by the runtime autoload.

const RegistryClient := preload("res://addons/godot_mcp_toolkit/registry_client.gd")

var _server: Node = null
# Playtest-end detection for runtime port cleanup.
var _was_playing: bool = false


func _init(server: Node) -> void:
	_server = server


func poll() -> void:
	var playing := EditorInterface.is_playing_scene()
	if _was_playing and not playing:
		RegistryClient.clear_runtime()
		# Proactive notification: tell the MCP server bridge the game stopped
		# so it can tear down the runtime channel immediately — no need to wait
		# for the next callRuntime() to discover the dead connection.
		_server.broadcast_notification("game_stopped")
	_was_playing = playing
