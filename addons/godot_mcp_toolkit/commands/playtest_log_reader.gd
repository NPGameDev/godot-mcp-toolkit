@tool
extends RefCounted
## Debug-log retrieval (editor side): the cached debugger.get_log reader.
##
## Reads the most-recent play session's output from the shared log FILE
## (user://logs/godot.log, written by both editor + game processes) starting at
## the byte offset snapshotted when game.start launched the session — bytes
## after that offset belong to the current/most-recent session. ANSI-strips,
## text-filters, and limits the lines; when an EditorDebuggerPlugin bridge is
## present, merges its debug_state + error_buffer (falling back to a log-line
## error scan) into one crash-context response.
##
## Owns the two pieces of state this subdomain depends on:
##   - the session-offset static (the log-read cursor) + the public
##     snapshot_session_offset() setter the Play-control side calls at
##     game.start to mark "read only output after here";
##   - the injected _debug_bridge (the EditorDebuggerPlugin, shared upstream with
##     debug_commands.gd) + set_debug_bridge()/clear_debug_bridge().
## An extracted submodule of the playtest-command group, reached via a `preload` alias.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Helpers = Modules.CommandHelpers
const LogHelpers = Modules.LogHelpers

# Log-file offset snapshot at game_start — bytes after this offset belong to
# the current/most-recent game session. The log file (user://logs/godot.log)
# is shared by editor + game processes, so reading from this offset gives us
# game output even though the Logger API is process-local (4.5+).
static var _game_session_file_offset: int = -1

# Debug bridge reference — injected at register() time.
# Used by debugger.get_log to include error_buffer + debug_state.
static var _debug_bridge: RefCounted = null


# -- Session-offset handoff ---------------------------------------------------


## Snapshot the current log-file size as the session-start offset — the
## debugger.get_log cache then returns only output written after this point.
## Called by Play-control (game.start) the moment a play session launches; the
## log file is shared by editor + game, so bytes after this offset = game output.
static func snapshot_session_offset() -> void:
	_game_session_file_offset = _get_log_file_size()


# -- Debug-bridge injection ---------------------------------------------------


static func set_debug_bridge(bridge: RefCounted) -> void:
	_debug_bridge = bridge


static func clear_debug_bridge() -> void:
	_debug_bridge = null


# -- Commands -----------------------------------------------------------------


## Editor-side debugger.get_log — returns cached log entries from the most
## recent game session. Reads from the LOG FILE (shared by editor + game
## processes) rather than the in-memory LogBuffer (which is process-local
## and only captures editor output on 4.5+).
## When a debug bridge is available, merges the error buffer and debug state
## into the response — gives the server a single call for full crash context.
static func cmd_debugger_get_log(parameters: Dictionary) -> Dictionary:
	var limit: int = max(1, int(parameters.get("limit", 200)))
	var text_filter: String = str(parameters.get("text_filter", ""))
	var tf := Helpers.compile_text_filter(parameters)
	var text_regex: RegEx = tf[0]
	if tf[1] != null:
		return tf[1]
	var regex_warning: String = tf[2]

	if _game_session_file_offset < 0:
		var response := MCPToolkitSuccess.ok({
			"lines": [],
			"count": 0,
			"truncated": false,
			"total_lines": 0,
			"source": "cache",
			"note": "No game session recorded yet (game_start was never called this editor session)",
		})
		_merge_debug_bridge_data(response)
		return response

	# Read the log file from the offset where the game session started.
	var log_path: String = _resolve_log_path()
	if not FileAccess.file_exists(log_path):
		var response := MCPToolkitSuccess.ok({
			"lines": [],
			"count": 0,
			"truncated": false,
			"total_lines": 0,
			"source": "cache",
			"note": "Log file not found. Enable debug/file_logging/enable_file_logging in ProjectSettings and restart.",
		})
		_merge_debug_bridge_data(response)
		return response

	var file := FileAccess.open(log_path, FileAccess.READ)
	if file == null:
		return MCPToolkitError.fail("LOG_BUSY",
			"Log file exists but cannot be read (err %d) — retry in 1-2s" % FileAccess.get_open_error())

	var file_len: int = file.get_length()
	if file_len <= _game_session_file_offset:
		file.close()
		var response := MCPToolkitSuccess.ok({
			"lines": [],
			"count": 0,
			"truncated": false,
			"total_lines": 0,
			"source": "cache",
			"note": "No new output since game_start (log file unchanged).",
		})
		_merge_debug_bridge_data(response)
		return response

	# Read only the bytes written since game_start.
	file.seek(_game_session_file_offset)
	var new_bytes := file.get_buffer(file_len - _game_session_file_offset)
	file.close()

	var new_text := new_bytes.get_string_from_utf8()
	var all_lines := new_text.split("\n", false)

	# Strip ANSI from all lines once (used for both filtering and error scan).
	var stripped_lines: Array = []
	for line in all_lines:
		var stripped := LogHelpers.strip_ansi(line.strip_edges())
		if not stripped.is_empty():
			stripped_lines.append(stripped)

	# Apply text filter.
	var filtered: Array = []
	for stripped in stripped_lines:
		if text_filter != "":
			if text_regex != null:
				if not text_regex.search(stripped):
					continue
			else:
				if stripped.findn(text_filter) < 0:
					continue
		filtered.append(stripped)

	# Apply limit (take last N lines).
	# Capture the pre-slice filtered count for total_lines before the
	# slice reassigns `filtered` to the capped tail.
	var total_lines := filtered.size()
	var truncated := filtered.size() > limit
	if truncated:
		filtered = filtered.slice(filtered.size() - limit)

	var response := MCPToolkitSuccess.ok({
		"lines": filtered,
		"count": filtered.size(),
		"truncated": truncated,
		"total_lines": total_lines,
		"source": "cache",
	})
	# Capped-tail pagination (oldest lines drop first, no cursor) — advise raising
	# limit / text_filter rather than a cursor.
	if truncated:
		response["hint"] = "more lines remain — raise limit or narrow with text_filter (capped tail: the oldest lines drop first, no cursor)."
	# Pass unfiltered lines so error scan always has full context.
	_merge_debug_bridge_data(response, stripped_lines)
	if not regex_warning.is_empty():
		response["warning"] = regex_warning
	return response


# -- Helpers ------------------------------------------------------------------


## Shared error-entry shape for debug_state/error_buffer responses.
## timestamp_ms + entry_type vary by source (live capture vs log scan); all
## other fields are pass-through. Explicit types so the builder never :=-infers
## from a Variant — message/source/function are str()-typed at the call sites.
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


## Merge debug bridge error buffer + state into a debugger.get_log response.
## all_lines: unfiltered log lines — error scan needs adjacent "at:" lines
## that text_filter might exclude.
static func _merge_debug_bridge_data(response: Dictionary,
		all_lines: Array = []) -> void:
	if _debug_bridge == null:
		return
	response["debug_state"] = _debug_bridge.get_debug_state()
	var buf: Array = _debug_bridge.get_error_buffer()
	# Fallback: if _capture didn't fire (Godot's built-in debugger handles
	# "error" messages before plugins see them), scan log lines for errors.
	if buf.is_empty() and not all_lines.is_empty():
		buf = _scan_lines_for_errors(all_lines)
	if not buf.is_empty():
		response["error_buffer"] = buf


## Scan log lines for error patterns and build synthetic error_buffer entries.
## Godot error lines follow the pattern:
##   "USER SCRIPT ERROR: <message>"    (script errors)
##   "SCRIPT ERROR: <message>"         (engine script errors)
##   "   at: <function> (<file>:<line>)"  (source location, follows the error)
## This fallback populates error_buffer when _capture doesn't fire.
static func _scan_lines_for_errors(lines: Array) -> Array:
	var errors: Array = []
	var i := 0
	while i < lines.size():
		var line: String = str(lines[i])
		var msg := ""
		if line.begins_with("USER SCRIPT ERROR:"):
			msg = line.substr(len("USER SCRIPT ERROR:")).strip_edges()
		elif line.begins_with("SCRIPT ERROR:"):
			msg = line.substr(len("SCRIPT ERROR:")).strip_edges()
		elif line.begins_with("ERROR:"):
			msg = line.substr(len("ERROR:")).strip_edges()
		if not msg.is_empty():
			var source := ""
			var func_name := ""
			var source_line := 0
			# Check the next line for "   at: func (file:line)" pattern.
			if i + 1 < lines.size():
				var next: String = str(lines[i + 1]).strip_edges()
				if next.begins_with("at:"):
					var at_info := next.substr(len("at:")).strip_edges()
					var paren_open := at_info.rfind("(")
					var paren_close := at_info.rfind(")")
					if paren_open >= 0 and paren_close > paren_open:
						func_name = at_info.left(paren_open).strip_edges()
						var loc := at_info.substr(paren_open + 1,
							paren_close - paren_open - 1)
						var colon := loc.rfind(":")
						if colon >= 0:
							source = loc.left(colon)
							source_line = int(loc.substr(colon + 1))
					i += 1  # Skip the "at:" line
			errors.append(make_error_entry(
				0, msg, source, func_name, source_line, "log_scan"))
		i += 1
	return errors


## Resolve the log file path (same logic as LogBuffer).
static func _resolve_log_path() -> String:
	var configured := ProjectSettings.get_setting(
		"debug/file_logging/log_path", "user://logs/godot.log") as String
	if configured.begins_with("user://") or configured.begins_with("res://"):
		return ProjectSettings.globalize_path(configured)
	return configured


## Get the current log file size (for offset snapshot at game_start).
static func _get_log_file_size() -> int:
	var log_path := _resolve_log_path()
	if not FileAccess.file_exists(log_path):
		return 0
	var file := FileAccess.open(log_path, FileAccess.READ)
	if file == null:
		return 0
	var size: int = file.get_length()
	file.close()
	return size
