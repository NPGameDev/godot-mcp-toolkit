@tool
extends EditorDebuggerPlugin
## The editor's debugger plugin: forwards the debugger session's events to the
## debug-session tracker and sends debug.continue to a game the debugger stopped.
##
## The plugin's composition root builds the tracker, registers this plugin, and its
## dispose() removes it. The tracker holds the session state, so it stays testable
## headless; this plugin holds only the live EditorDebuggerSession.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const DebugSessionTracker = Modules.DebugSessionTracker

var _session_tracker: DebugSessionTracker = null
var _session: EditorDebuggerSession = null


## [param session_tracker] is the debug-session tracker this plugin feeds.
func _init(session_tracker: DebugSessionTracker) -> void:
	_session_tracker = session_tracker


func _setup_session(session_id: int) -> void:
	var session := get_session(session_id)
	if session == null:
		return
	# Disconnect previous session signals (game restart scenario).
	_disconnect_session()
	_session = session
	session.started.connect(_session_tracker.on_session_started)
	session.stopped.connect(_session_tracker.on_session_stopped)
	session.breaked.connect(_session_tracker.on_session_breaked)
	session.continued.connect(_session_tracker.on_session_continued)


func _has_capture(capture: String) -> bool:
	return capture == "error"


func _capture(message: String, data: Array, _session_id: int) -> bool:
	# Only the error message itself, not error:clear_execution and the like. The
	# message arrives as "error:error" or, with its prefix stripped, "error".
	if message == "error" or message == "error:error":
		_session_tracker.buffer_debugger_error(data)
	return false  # Leave the built-in handling in place.


## Returns the debug.state payload of the latest session.
func get_debug_state() -> Dictionary:
	return _session_tracker.get_debug_state()


## Continues a game the debugger stopped. Returns [code]{success: true}[/code], or
## [code]{error: "GAME_NOT_RUNNING"}[/code] with no session attached, or
## [code]{error: "NOT_BREAKED"}[/code] when the debugger has not stopped the game.
func try_continue() -> Dictionary:
	if _session == null or not _session_tracker.is_active():
		return {"error": "GAME_NOT_RUNNING"}
	if not _session_tracker.is_breaked():
		return {"error": "NOT_BREAKED"}
	_session.send_message("continue", [])
	return {"success": true}


## Disconnects the session. Called from the composition root's dispose() before
## remove_debugger_plugin.
func cleanup() -> void:
	_disconnect_session()
	_session = null


func _disconnect_session() -> void:
	if _session == null:
		return
	if _session.started.is_connected(_session_tracker.on_session_started):
		_session.started.disconnect(_session_tracker.on_session_started)
	if _session.stopped.is_connected(_session_tracker.on_session_stopped):
		_session.stopped.disconnect(_session_tracker.on_session_stopped)
	if _session.breaked.is_connected(_session_tracker.on_session_breaked):
		_session.breaked.disconnect(_session_tracker.on_session_breaked)
	if _session.continued.is_connected(_session_tracker.on_session_continued):
		_session.continued.disconnect(_session_tracker.on_session_continued)
