@tool
extends RefCounted
## Debug-log retrieval (editor side): the cached debugger.get_log reader.
##
## Reads the most-recent play session's output from the engine log FILE
## (user://logs/godot.log — written by the game/play process; the editor process
## does not write it, engine !editor guard). The engine truncates that file fresh
## on every launch (RotatedFileLogger rotates the prior log to a timestamped backup
## and reopens the base path with FileAccess::WRITE), so the file is always exactly
## the current session starting at byte 0 — this reader reads the whole file.
## ANSI-strips, text-filters, and limits the lines, and merges the injected
## debug-session tracker's debug_state + error_buffer (falling back to a log-line error scan) into
## one crash-context response.
##
## The file belongs to the latest debugger session only when that session is a
## playtest this editor ran; the injected debug-session tracker says whose game the
## latest session is, so a read before any playtest, or after a remote deploy or an
## external attach, answers with a note instead of a log that is not that game's.
## An extracted submodule of the playtest-command group, reached via a `preload` alias.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Helpers = Modules.CommandHelpers
const LogHelpers = Modules.LogHelpers
const DebugSessionTracker = Modules.DebugSessionTracker

const _NO_PLAYTEST_NOTE := "No playtest has run from this editor session yet, so there is no local log to read. A game started outside this editor writes its log on its own machine."
const _ELSEWHERE_NOTE := "The latest debugger session is a game this editor did not run on this machine (a one-click deploy, or a game attached from outside); its log stays with that game. This machine's godot.log holds the last local playtest: read it with editor_get_console(source:\"file\")."
const _LOG_NOT_FOUND_NOTE := "Log file not found. Enable debug/file_logging/enable_file_logging in ProjectSettings and restart."
# The editor's safe-save setting makes its own READ open deny-write, and Windows
# refuses that open while the game holds the log open for writing. The file is
# there, but the editor cannot read it while the game process runs; a running game
# answers debugger.get_log itself.
const _LOG_UNREADABLE_NOTE := "This machine's log file exists, but the editor cannot open it while the game has it open for writing, as on Windows at an error break or a breakpoint pause. debug_state, and error_buffer when errors were caught, still describe the game. At an error break, stop the game with game_stop and read again for the full log; at a breakpoint pause, debug_continue lets the running game answer with its own log. With no game running, retry shortly: a backup, antivirus or sync tool may be holding the file."

# The tracker the composer injects. Until then, and after the composer clears it, a
# tracker no editor feeds stands in, so game.start's mark still reaches a reader.
static var _session_tracker: DebugSessionTracker = DebugSessionTracker.new()
# False while that stand-in is in place: with no debugger feeding it, a response
# carries no debug_state or error_buffer.
static var _session_tracker_injected: bool = false


# -- Session-start handoff ---------------------------------------------------


## Marks that game.start launched a playtest: debugger.get_log then reads the whole
## godot.log. The engine truncates that file fresh on every launch (RotatedFileLogger
## ctor → rotate_file → FileAccess::WRITE; source-verified 4.2–4.7), so once a
## playtest has started the whole file is that playtest, read from byte 0. The file is
## written by the game process (the editor does not write it — engine !editor guard),
## so reading it gives game output even though the Logger API is process-local (4.5+).
static func mark_session_started() -> void:
	_session_tracker.mark_local_playtest()


# -- Session-tracker injection ------------------------------------------------


static func set_session_tracker(session_tracker: DebugSessionTracker) -> void:
	_session_tracker = session_tracker
	_session_tracker_injected = true


## Drops the injected tracker for a fresh one no editor feeds.
static func clear_session_tracker() -> void:
	_session_tracker = DebugSessionTracker.new()
	_session_tracker_injected = false


## Returns the latest debugger session's debug.state payload ([code]active[/code],
## [code]breaked[/code], [code]can_debug[/code]); all false before a tracker is
## injected.
static func get_debug_state() -> Dictionary:
	return _session_tracker.get_debug_state()


## Returns the editor debugger's text for the error break the game is at, or an
## empty String when there is none.
static func get_break_reason() -> String:
	return _session_tracker.get_break_reason()


## Returns where the error break the game is at stopped ([code]source[/code],
## [code]function[/code], [code]line[/code]), or an empty Dictionary when the editor
## debugger gave no location or there is no error break.
static func get_break_location() -> Dictionary:
	return _session_tracker.get_break_location()


# -- Commands -----------------------------------------------------------------


## Editor-side debugger.get_log — returns cached log entries from the most
## recent game session. Reads from the LOG FILE (written by the game/play
## process — the editor does not write it) rather than the in-memory LogBuffer
## (which is process-local and only captures editor output on 4.5+).
## Once a tracker is injected, merges its error buffer and debug state into the
## response, which gives the server a single call for full crash context. A log
## file it cannot open, missing or held by the game, still answers with a page:
## a note says which, and the session state is merged as for any read.
static func cmd_debugger_get_log(parameters: Dictionary) -> Dictionary:
	var limit: int = max(1, int(parameters.get("limit", 200)))
	var text_filter: String = str(parameters.get("text_filter", ""))
	var tf := Helpers.compile_text_filter(parameters)
	var text_regex: RegEx = tf[0]
	if tf[1] != null:
		return tf[1]
	var regex_warning: String = tf[2]

	var latest_session := _session_tracker.latest_session()
	if latest_session == DebugSessionTracker.LatestSession.ELSEWHERE:
		var response := MCPToolkitSuccess.ok(_empty_log_page(_ELSEWHERE_NOTE))
		_merge_debug_session_data(response)
		return response

	if latest_session == DebugSessionTracker.LatestSession.NONE:
		var response := MCPToolkitSuccess.ok(_empty_log_page(_NO_PLAYTEST_NOTE))
		_merge_debug_session_data(response)
		return response

	# Read the current session's log file (the engine truncated it fresh at launch).
	var log_path: String = LogHelpers.resolve_log_path()
	var file := FileAccess.open(log_path, FileAccess.READ)
	if file == null:
		var note: String = _LOG_UNREADABLE_NOTE if LogHelpers.is_log_file_present(log_path) \
				else _LOG_NOT_FOUND_NOTE
		var response := MCPToolkitSuccess.ok(_empty_log_page(note))
		_merge_debug_session_data(response)
		return response

	var file_len: int = file.get_length()
	if file_len <= 0:
		file.close()
		var response := MCPToolkitSuccess.ok(_empty_log_page(
			"No game output yet (log file is empty)."))
		_merge_debug_session_data(response)
		return response

	# The engine truncates godot.log fresh on every launch (see mark_session_started),
	# so the whole file is this session — read it all from byte 0.
	var new_bytes := file.get_buffer(file_len)
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

	# Capped-tail pagination (oldest lines drop first, no cursor) — advise raising
	# limit / text_filter rather than a cursor.
	var hint := ""
	if truncated:
		hint = "more lines remain — raise limit or narrow with text_filter (capped tail: the oldest lines drop first, no cursor)."
	var response := MCPToolkitSuccess.ok(Modules.Pagination.build(
		{"lines": filtered}, "lines", total_lines, filtered.size(), truncated,
		"", 0, hint, {"source": "cache"}))
	# Pass unfiltered lines so error scan always has full context.
	_merge_debug_session_data(response, stripped_lines)
	if not regex_warning.is_empty():
		response["warning"] = regex_warning
	return response


# -- Helpers ------------------------------------------------------------------


## The empty cached-log page returned when no session output is available.
## [param note] explains which of the no-output conditions applies. Stamps the
## standard pagination invariants (empty, nothing more) so the shape matches a
## populated read.
static func _empty_log_page(note: String) -> Dictionary:
	return Modules.Pagination.build({"lines": []}, "lines", 0, 0, false, "", 0, "",
		{"source": "cache", "note": note})


## Merge the injected debug-session tracker's error buffer + state into a
## debugger.get_log response. all_lines: unfiltered log lines — error scan needs
## adjacent "at:" lines that text_filter might exclude.
static func _merge_debug_session_data(response: Dictionary,
		all_lines: Array = []) -> void:
	if not _session_tracker_injected:
		return
	response["debug_state"] = _session_tracker.get_debug_state()
	var buf: Array = _session_tracker.get_error_buffer()
	# The editor's own debugger takes the engine's error messages before a plugin's
	# capture, so the buffer usually holds at most an error break's entry, which
	# names only the place the game stopped. A runtime error's log lines carry each
	# error with its own file and line, so they win.
	if _holds_only_break_entries(buf) and not all_lines.is_empty():
		var scanned := _scan_lines_for_errors(all_lines)
		if not scanned.is_empty():
			buf = scanned
	if not buf.is_empty():
		response["error_buffer"] = buf


static func _holds_only_break_entries(entries: Array) -> bool:
	for entry: Dictionary in entries:
		if str(entry.get("type", "")) != "break":
			return false
	return true


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
			errors.append(DebugSessionTracker.make_error_entry(
				0, msg, source, func_name, source_line, "log_scan"))
		i += 1
	return errors
