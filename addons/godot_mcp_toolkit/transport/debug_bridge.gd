@tool
extends EditorDebuggerPlugin
## The editor's debugger plugin: forwards the debugger session's events, and the
## editor debugger's reason text for an error break, to the debug-session tracker,
## and sends debug.continue to a game the debugger stopped.
##
## The plugin's composition root builds the tracker, registers this plugin, and its
## dispose() removes it. The tracker holds the session state, so it stays testable
## headless; this plugin holds only the live EditorDebuggerSession and the editor's
## debugger node behind it.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const DebugSessionTracker = Modules.DebugSessionTracker

const _DEBUGGER_NODE_CLASS := "ScriptEditorDebugger"
const _BREAKED := &"breaked"
# reallydid, can_debug, reason, has_stackdump: the same on 4.2 to 4.7.
const _REASON_BREAKED_ARG_COUNT := 4

var _session_tracker: DebugSessionTracker = null
var _session: EditorDebuggerSession = null
# The editor's debugger node behind _session. Its own breaked signal carries the
# reason text for a break, which the session's breaked drops.
var _debugger_node: Object = null


## Returns the node among [param candidates] that [param session] belongs to: the one
## whose four-argument [code]breaked[/code] signal has a connection to
## [param session]. The editor builds one session per debugger node and connects it to
## that node's [code]breaked[/code], so the match holds whatever the tabs' order.
## Returns null when no candidate matches or its [code]breaked[/code] has another
## signature.
static func find_session_debugger_node(candidates: Array, session: Object) -> Object:
	for candidate: Object in candidates:
		if candidate == null or not _has_reason_breaked_signal(candidate):
			continue
		for connection: Dictionary in candidate.get_signal_connection_list(_BREAKED):
			var target: Callable = connection.get("callable", Callable())
			if target.get_object() == session:
				return candidate
	return null


## Returns whether [param candidate] has a [code]breaked[/code] signal with the
## editor debugger node's four arguments, the third the reason text.
static func _has_reason_breaked_signal(candidate: Object) -> bool:
	if not candidate.has_signal(_BREAKED):
		return false
	for signal_info: Dictionary in candidate.get_signal_list():
		if str(signal_info.get("name", "")) == String(_BREAKED):
			var arguments: Array = signal_info.get("args", [])
			return arguments.size() == _REASON_BREAKED_ARG_COUNT
	return false


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
	var candidates: Array = EditorInterface.get_base_control().find_children(
			"*", _DEBUGGER_NODE_CLASS, true, false)
	var debugger_node := find_session_debugger_node(candidates, session)
	# Without the node, an error break's entry goes without the reason text.
	if debugger_node != null:
		_debugger_node = debugger_node
		_debugger_node.connect(_BREAKED, _session_tracker.on_debugger_node_breaked)


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
	if is_instance_valid(_debugger_node) \
			and _debugger_node.is_connected(_BREAKED, _session_tracker.on_debugger_node_breaked):
		_debugger_node.disconnect(_BREAKED, _session_tracker.on_debugger_node_breaked)
	_debugger_node = null
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
