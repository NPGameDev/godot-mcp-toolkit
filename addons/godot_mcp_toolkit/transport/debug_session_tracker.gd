@tool
extends RefCounted
## The state of the editor's latest debugger session: whether a game is attached and
## stopped at a break, the errors it reported, and whose game it is.
##
## The debug commands read the attach and pause state. The debugger log reader reads
## whose game the latest session is, since this machine's godot.log belongs only to a
## playtest this editor ran. The debugger plugin feeds the session events in, and the
## one editor fact the tracker needs, whether the editor is running a playtest, comes
## through an injected port: any object with [code]is_playing_scene() -> bool[/code],
## such as [code]EditorInterface[/code].

## Whose game the latest debugger session is.
enum LatestSession {
	## No playtest or debugger session yet this editor session.
	NONE,
	## A playtest this editor ran on this machine.
	LOCAL,
	## A game this editor did not run on this machine: a one-click deploy, or a game
	## attached from outside.
	ELSEWHERE,
}

const _ERROR_BUFFER_MAX := 50

var _editor_port: Object = null
var _active: bool = false
var _breaked: bool = false
var _can_debug: bool = false
var _error_buffer: Array = []
var _latest_session: LatestSession = LatestSession.NONE
var _break_reason: String = ""
# The entry the current error break recorded, empty when it recorded none, so a
# reason that arrives after the break can complete its message.
var _break_entry: Dictionary = {}
# Set by a remote-debug deploy's export, which runs after the editor's build step and
# before the deployed game attaches, so the next session start can tell that game
# from a playtest.
var _remote_deploy_pending: bool = false


## The error-entry shape of [code]debug_state[/code] and [code]error_buffer[/code]
## responses. [param timestamp_ms] and [param entry_type] depend on the source (a
## debugger capture, a break, a log scan); the other fields pass through. Returns
## a Dictionary with [code]timestamp_ms[/code], [code]message[/code],
## [code]source[/code], [code]function[/code], [code]line[/code] and
## [code]type[/code].
static func make_error_entry(timestamp_ms: int, message: String, source: String,
		function: String, line: int, entry_type: String) -> Dictionary:
	return {
		"timestamp_ms": timestamp_ms,
		"message": message,
		"source": source,
		"function": function,
		"line": line,
		"type": entry_type,
	}


static func _error_break_message(reason: String) -> String:
	var reason_clause := "" if reason.is_empty() else ": " + reason
	return ("Game paused at a script error it cannot continue from%s. Find the file and "
			+ "line with script_check or lsp_project_diagnostics, fix it, then game_stop "
			+ "and game_start.") % reason_clause


## [param editor_port] answers [code]is_playing_scene()[/code]; null reads as never
## playing, for a tracker no editor feeds.
func _init(editor_port: Object = null) -> void:
	_editor_port = editor_port


## A debugger session started. It is the latest session from now on: a playtest of
## this editor when the editor is running one and no remote-debug deploy is pending,
## else a game elsewhere.
func on_session_started() -> void:
	_active = true
	_breaked = false
	_can_debug = false
	_forget_break()
	_error_buffer.clear()
	if _is_editor_playing() and not _remote_deploy_pending:
		_latest_session = LatestSession.LOCAL
	else:
		_latest_session = LatestSession.ELSEWHERE


func on_session_stopped() -> void:
	_active = false
	_breaked = false
	_can_debug = false
	_forget_break()


## The debugger stopped the game: at a breakpoint pause when [param can_debug] is
## true, else at an error break, which the game cannot continue from.
func on_session_breaked(can_debug: bool) -> void:
	_breaked = true
	_can_debug = can_debug
	# An error break's message reaches only the editor's own debugger, never a
	# plugin's capture, so an error break with nothing buffered records the entry
	# itself. A breakpoint pause is no error; debug_state's breaked reports it.
	if not can_debug and _error_buffer.is_empty():
		_break_entry = make_error_entry(Time.get_ticks_msec(),
				_error_break_message(_break_reason), "", "", 0, "break")
		_buffer_error(_break_entry)


## The editor's debugger node stopped the game ([param really_did] true) or let it
## go on, the payload of its own [code]breaked[/code] signal. For an error break
## (not [param can_debug]) its [param reason] text, such as
## [code]"Parser Error: <message>"[/code], goes into the entry the break recorded,
## if it recorded one, as a new entry in its place, so a buffer an earlier
## [method get_error_buffer] returned never changes. Otherwise the reason is only
## available from [method get_break_reason], which returns it until the game
## continues or its session ends. The editor's session hears the node first, so the
## break usually reaches [method on_session_breaked] before this; a reason noted
## first is kept for the entry the break then records.
func on_debugger_node_breaked(really_did: bool, can_debug: bool, reason: String,
		_has_stackdump: bool) -> void:
	if not really_did or can_debug:
		return
	_break_reason = reason.strip_edges().trim_suffix(".")
	if _break_entry.is_empty():
		return
	var index := _error_buffer.find(_break_entry)
	_break_entry = _break_entry.duplicate()
	_break_entry["message"] = _error_break_message(_break_reason)
	if index != -1:
		_error_buffer[index] = _break_entry


func on_session_continued() -> void:
	_breaked = false
	_can_debug = false
	_forget_break()


## Buffers the error in [param data], an "error" debugger message's payload laid out by
## the engine's [code]DebuggerMarshalls::OutputError::serialize()[/code], the same on
## 4.2 to 4.7: [code][hour, minute, second, msec, source_file, source_func,
## source_line, error, error_descr, warning, callstack_size, (file, func, line)...][/code].
## Warnings and payloads shorter than the fixed fields are ignored. The engine routes
## this message to its own error handler before a plugin's capture on 4.2 to 4.7, so a
## live session fills the buffer from the break fallback instead; this keeps a payload
## that does reach a plugin decoded the same way.
func buffer_debugger_error(data: Array) -> void:
	if data.size() < 10:
		return
	var source_file := str(data[4])
	var source_func := str(data[5])
	var source_line: int = int(data[6])
	var error := str(data[7])
	var error_descr := str(data[8])
	var is_warning: bool = bool(data[9])
	if is_warning:
		return
	var message := error_descr if not error_descr.is_empty() else error
	_buffer_error(make_error_entry(
			Time.get_ticks_msec(), message, source_file, source_func,
			source_line, "error"))


## The editor is about to run the project, as a playtest or a one-click deploy with
## remote debug. The editor runs this build step before either, so it clears any
## pending deploy.
func note_editor_build() -> void:
	_remote_deploy_pending = false


## A one-click deploy with remote debug exported the project. Its game attaches next,
## so that session counts as elsewhere. The latest session's state is unchanged.
func note_remote_debug_deploy() -> void:
	_remote_deploy_pending = true


## game.start launched a playtest of this editor, so the latest session is local
## before its debugger session starts.
func mark_local_playtest() -> void:
	_latest_session = LatestSession.LOCAL


## Returns the [enum LatestSession] of the latest debugger session.
func latest_session() -> LatestSession:
	return _latest_session


## Returns the debug.state payload: [code]active[/code], [code]breaked[/code] and
## [code]can_debug[/code], all bool.
func get_debug_state() -> Dictionary:
	return {
		"active": _active,
		"breaked": _breaked,
		"can_debug": _can_debug,
	}


func is_active() -> bool:
	return _active


func is_breaked() -> bool:
	return _breaked


## Returns a copy of the latest session's buffered errors, oldest first, at most 50.
func get_error_buffer() -> Array:
	return _error_buffer.duplicate()


## Returns the editor debugger's text for the error break the game is at, without a
## trailing period, or an empty String when it gave none or the game is not at one.
func get_break_reason() -> String:
	return _break_reason


func _forget_break() -> void:
	_break_reason = ""
	_break_entry = {}


func _is_editor_playing() -> bool:
	if _editor_port == null:
		return false
	return bool(_editor_port.call("is_playing_scene"))


func _buffer_error(entry: Dictionary) -> void:
	_error_buffer.append(entry)
	if _error_buffer.size() > _ERROR_BUFFER_MAX:
		_error_buffer.pop_front()
