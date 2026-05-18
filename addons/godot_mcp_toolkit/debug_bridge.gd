@tool
extends EditorDebuggerPlugin
## EditorDebuggerPlugin subclass — tracks debugger session state and
## provides continue-execution via send_message.
##
## Registered/unregistered by plugin.gd via add_debugger_plugin /
## remove_debugger_plugin (I12 symmetry). Session signals feed the
## debug.state command; send_message("continue") feeds debug.continue.

var _session: EditorDebuggerSession = null
var _session_id: int = -1
var _active: bool = false
var _breaked: bool = false
var _can_debug: bool = false


func _setup_session(session_id: int) -> void:
	var session := get_session(session_id)
	if session == null:
		return
	# Disconnect previous session signals (game restart scenario).
	_disconnect_session()
	_session = session
	_session_id = session_id
	session.started.connect(_on_started)
	session.stopped.connect(_on_stopped)
	session.breaked.connect(_on_breaked)
	session.continued.connect(_on_continued)


func _disconnect_session() -> void:
	if _session == null:
		return
	if _session.started.is_connected(_on_started):
		_session.started.disconnect(_on_started)
	if _session.stopped.is_connected(_on_stopped):
		_session.stopped.disconnect(_on_stopped)
	if _session.breaked.is_connected(_on_breaked):
		_session.breaked.disconnect(_on_breaked)
	if _session.continued.is_connected(_on_continued):
		_session.continued.disconnect(_on_continued)


func _on_started() -> void:
	_active = true
	_breaked = false
	_can_debug = false


func _on_stopped() -> void:
	_active = false
	_breaked = false
	_can_debug = false


func _on_breaked(can_debug: bool) -> void:
	_breaked = true
	_can_debug = can_debug


func _on_continued() -> void:
	_breaked = false
	_can_debug = false


## Return current debugger state for debug.state.
func get_debug_state() -> Dictionary:
	return {
		"active": _active,
		"breaked": _breaked,
		"can_debug": _can_debug,
	}


## Attempt to continue execution. Returns {success:true} or
## {error: "GAME_NOT_RUNNING"|"NOT_BREAKED"}.
func try_continue() -> Dictionary:
	if _session == null or not _active:
		return {"error": "GAME_NOT_RUNNING"}
	if not _breaked:
		return {"error": "NOT_BREAKED"}
	_session.send_message("continue", [])
	return {"success": true}


## Cleanup — called from plugin._exit_tree before remove_debugger_plugin.
func cleanup() -> void:
	_disconnect_session()
	_session = null
	_session_id = -1
	_active = false
	_breaked = false
	_can_debug = false
