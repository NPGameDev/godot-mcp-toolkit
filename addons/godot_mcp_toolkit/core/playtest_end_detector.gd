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
##
## Why poll every frame instead of connecting to a signal?  Godot exposes no
## public, ClassDB-bound, cross-version (4.2–4.7) play-state signal an addon can
## connect to.  The engine's play/stop signals live on the internal run-bar node
## (EditorNode.project_run_bar ≤4.4 / EditorRunBar 4.5+), which is not registered
## in ClassDB and is reachable only from inside the editor.  is_playing_scene() is
## therefore the only public cross-version surface for the play→stop edge, and
## per-frame polling is the pragmatic norm.  A coarse Timer is rejected: it would
## delay the runtime-clear + game_stopped broadcast past the stop edge; the poll
## body is O(1) (one bound bool call + a cached-flag compare).
## (Verified against Godot 4.2–4.7 engine source.)

const RegistryClient := preload("res://addons/godot_mcp_toolkit/registry/registry_client.gd")

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
