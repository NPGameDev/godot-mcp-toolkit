@tool
extends EditorDebuggerPlugin
## EditorDebuggerPlugin subclass — tracks debugger session state and
## provides continue-execution via send_message.
##
## Registered/unregistered by plugin.gd via add_debugger_plugin /
## remove_debugger_plugin (I12 symmetry). Session signals feed the
## debug.state command; send_message("continue") feeds debug.continue.

## Shared error-entry shape (timestamp + type vary by source; rest pass-through).
const PlaytestLogReader := preload("res://addons/godot_mcp_toolkit/commands/playtest_log_reader.gd")

const _ERROR_BUFFER_MAX := 50

var _session: EditorDebuggerSession = null
var _session_id: int = -1
var _active: bool = false
var _breaked: bool = false
var _can_debug: bool = false
var _error_buffer: Array = []


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


func _has_capture(capture: String) -> bool:
	return capture == "error"


func _capture(message: String, data: Array, session_id: int) -> bool:
	# Only process error messages (not error:clear_execution etc.).
	# message may be "error:error" (full) or "error" (prefix stripped).
	if not (message == "error" or message == "error:error"):
		return false
	_parse_and_buffer_error(data)
	return false  # Don't suppress built-in handling


func _on_started() -> void:
	_active = true
	_breaked = false
	_can_debug = false
	_error_buffer.clear()


func _on_stopped() -> void:
	_active = false
	_breaked = false
	_can_debug = false


func _on_breaked(can_debug: bool) -> void:
	_breaked = true
	_can_debug = can_debug
	# Fallback: if _capture didn't fire for this break (built-in debugger
	# may intercept error messages before plugins), record a generic entry.
	if can_debug and _error_buffer.is_empty():
		_buffer_error(PlaytestLogReader.make_error_entry(
				Time.get_ticks_msec(),
				"Game paused at error (details in editor Errors tab or log)",
				"", "", 0, "break"))


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


## Return the error buffer (copy) for the current/most-recent game session.
func get_error_buffer() -> Array:
	return _error_buffer.duplicate()


## Cleanup — called from plugin._exit_tree before remove_debugger_plugin.
func cleanup() -> void:
	_disconnect_session()
	_session = null
	_session_id = -1
	_active = false
	_breaked = false
	_can_debug = false
	_error_buffer.clear()


## Parse error data from the debugger protocol and append to the ring buffer.
##
## DEFENSIVE / forward-looking — currently unreachable on the live path: the
## engine routes the bare "error" message to the registered _msg_error handler
## (script_editor_debugger.cpp), so it never reaches plugins_capture / _capture.
## The _on_breaked and log-scan fallbacks are what actually populate the buffer
## today. Kept (and decoded correctly) in case a future engine version surfaces
## "error" to capture plugins.
##
## Data layout — DebuggerMarshalls::OutputError::serialize(), fields-first /
## stack-LAST, verified unchanged across Godot 4.0–4.7:
##   [0]=hr  [1]=min  [2]=sec  [3]=msec  [4]=source_file  [5]=source_func
##   [6]=source_line  [7]=error  [8]=error_descr  [9]=warning
##   [10]=callstack.size()*3   [11+]=(file, func, line) triples
func _parse_and_buffer_error(data: Array) -> void:
	if data.size() < 10:
		return  # Malformed — not enough fields for the fixed header

	var source_file := str(data[4])
	var source_func := str(data[5])
	var source_line: int = int(data[6])
	var error := str(data[7])
	var error_descr := str(data[8])
	var is_warning: bool = bool(data[9])

	if is_warning:
		return  # Only capture errors, not warnings

	# Prefer the human-readable description; fall back to the bare error text.
	var msg := error_descr if not error_descr.is_empty() else error

	_buffer_error(PlaytestLogReader.make_error_entry(
			Time.get_ticks_msec(), msg, source_file, source_func,
			source_line, "error"))


func _buffer_error(entry: Dictionary) -> void:
	_error_buffer.append(entry)
	if _error_buffer.size() > _ERROR_BUFFER_MAX:
		_error_buffer.pop_front()
