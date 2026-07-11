@tool
extends RefCounted
## editor.* log/console reader: read the editor's captured output — from the
## in-memory LogBuffer (source="buffer") or a user://logs/*.log file
## (source="file") — filtered by level/text/since_id, scrubbed, and shaped into
## the entry list. Serves the console reader tool.
##
## Stateless — every handler takes (server, parameters) and returns the response
## Dictionary; the reader-spine helpers take their inputs as parameters. The log
## subsystem (LogBuffer / LogHelpers), the secret scrubber, the untrusted-content
## wrapper, and the text-filter compiler are consumed via Modules aliases. Consumed
## by editor_commands.gd via a `preload` alias.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Untrusted = Modules.Untrusted
const Scrubber = Modules.Scrubber
const Helpers = Modules.CommandHelpers
const LogHelpers = Modules.LogHelpers


# -- Commands -----------------------------------------------------------------


static func cmd_get_console(server: Node, parameters: Dictionary) -> Dictionary:
	# clear_buffer flushes stale log entries before reading.
	var clear_buffer: bool = parameters.get("clear_buffer", false) == true
	if clear_buffer:
		Modules.LogBuffer.clear()

	var limit: int = int(parameters.get("limit", 200))
	var level_filter: Array = parameters.get("level_filter", [])
	if typeof(level_filter) != TYPE_ARRAY:
		level_filter = []
	var since_id: int = int(parameters.get("since_id", -1))
	var source: String = str(parameters.get("source", "buffer"))

	if limit < 1 or limit > 1000:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"limit must be in [1, 1000] (got %d)" % limit)
	if not (source in ["buffer", "file"]):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"source must be 'buffer' or 'file' (got %s)" % source)
	var valid_levels := ["info", "warning", "error"]
	for level_filter_entry in level_filter:
		if not str(level_filter_entry) in valid_levels:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"level_filter entries must be one of 'info' | 'warning' | 'error' (got %s)" % str(level_filter_entry))

	var tf := _compile_text_filter(parameters)
	if tf[2] != null:
		return tf[2]
	var text_filter: String = tf[0]
	var text_regex: RegEx = tf[1]
	var regex_warning: String = tf[3]

	var result: Dictionary
	if source == "file":
		result = _read_console_log(server, limit, level_filter, since_id, text_filter, text_regex)
	else:
		result = _read_buffer_log(limit, level_filter, since_id, text_filter, text_regex)
	if not regex_warning.is_empty() and result.get("success", false):
		result["warning"] = regex_warning
	# Headless editors don't revalidate scripts, so an error-capture request returning
	# count:0 reads like "no matches" rather than "editor parse errors aren't captured
	# here". Steer to script_check whenever error capture is requested (level_filter has
	# "error" OR a text_filter is set) — regardless of match count. is_headless-gated, so
	# the display response is byte-identical; additive hint only, capture mechanics
	# untouched.
	if Modules.VersionUtils.is_headless() and result.get("success", false):
		var wants_error_capture := ("error" in level_filter) or (text_filter != "")
		if wants_error_capture:
			result["headless_hint"] = "headless editors don't revalidate scripts, so editor parse errors aren't captured here — use script_check(path) to validate a specific script's parse status."
	return result


# -- Helpers ------------------------------------------------------------------


## Compile text_filter params into [text_filter, RegEx-or-null, error-or-null, warning].
## Delegates to Helpers.compile_text_filter for regex compilation + double-escape detection.
static func _compile_text_filter(parameters: Dictionary) -> Array:
	var text_filter: String = str(parameters.get("text_filter", ""))
	var is_regex: bool = bool(parameters.get("is_regex", false))
	if text_filter == "" or not is_regex:
		return [text_filter, null, null, ""]
	var tf := Helpers.compile_text_filter(parameters)
	# tf = [RegEx-or-null, error-or-null, warning]
	if tf[1] != null:
		return ["", null, tf[1], ""]
	return [text_filter, tf[0], null, tf[2]]


static func _godot_error_name(code: int) -> String:
	match code:
		0: return "OK"
		7: return "ERR_FILE_NOT_FOUND"
		12: return "ERR_CANT_OPEN"
		13: return "ERR_CANT_WRITE"
		31: return "ERR_FILE_CANT_WRITE"
		32: return "ERR_FILE_CANT_READ"
		_: return "Error(%d)" % code


# -- Buffer log reader --------------------------------------------------------


static func _read_buffer_log(limit: int, level_filter: Array, since_id: int, text_filter: String = "", text_regex: RegEx = null) -> Dictionary:
	var buf_result: Dictionary = Modules.LogBuffer.get_entries(limit, level_filter, since_id, text_filter, text_regex)
	var entries: Array = buf_result["entries"]
	for entry in entries:
		var scrubbed := Scrubber.scrub(str(entry["message"]), "console")
		entry["message"] = scrubbed["text"]
	var has_more: bool = buf_result["has_more"]
	# Capped-tail line paging: the resume cursor is next_id (fed back via since_id),
	# not a next_offset, so this is cursor-less as far as the shared builder is concerned.
	var next_id: int = int(buf_result["next_id"])
	var hint := ""
	if has_more:
		hint = "more lines remain — re-call editor.get_console with since_id = next_id (%d) until has_more is false" % next_id
	var response := Modules.Pagination.build(
		{"entries": Untrusted.wrap("console", "buffer", JSON.stringify(entries))},
		"lines", int(buf_result["total_lines"]), int(buf_result["returned"]), has_more,
		"", 0, hint, {"next_id": next_id, "source": "buffer"})
	# On 4.2-4.4, buffer uses file tailing — warn if empty and file logging is off
	# or the log file couldn't be read (locked by OS on Windows). Pre-4.5 the console
	# only captures a running game's output (no editor-side capture), so an empty read
	# here can mean the output simply isn't reachable — steer to the compile-status tools.
	if entries.is_empty() and not Modules.LogBuffer.uses_logger_api():
		if not LogHelpers.is_file_logging_enabled():
			response["warning"] = "On Godot 4.2-4.4 the log buffer captures output by tailing the log file. Enable debug/file_logging/enable_file_logging in ProjectSettings and restart the editor for output capture to work. Editor-only output isn't captured pre-4.5 without a running game — to check compile status use script_check (one file) or lsp_project_diagnostics (whole project)."
		elif Modules.LogBuffer._tail_open_failures > 0:
			response["warning"] = "Log file could not be opened for reading (%d failed attempts) — the OS may be locking it. Use source=\"file\" as a fallback." % Modules.LogBuffer._tail_open_failures
	# Autoload hint — scan error entries for unresolved identifiers matching autoloads.
	if level_filter.is_empty() or ("error" in level_filter):
		var al_hint := _scan_autoload_hints(entries)
		if not al_hint.is_empty():
			response["autoload_hint"] = al_hint
	return MCPToolkitSuccess.ok(response)


## Scan console entries for "Identifier X not declared" errors that match
## registered autoloads, returning a combined hint string (empty if none).
static func _scan_autoload_hints(entries: Array) -> String:
	var re := RegEx.new()
	re.compile('Identifier "(\\w+)" not declared')
	var found: Array = []
	for entry in entries:
		var msg: String = str(entry.get("message", ""))
		var m := re.search(msg)
		if m == null:
			continue
		var ident: String = m.get_string(1)
		if ProjectSettings.has_setting("autoload/" + ident) and not (ident in found):
			found.append(ident)
	if found.is_empty():
		return ""
	return "Some errors reference registered autoloads (%s). The editor cache may be stale — call autoload_manage to re-register them." % ", ".join(found)


# -- Console log reader -------------------------------------------------------


static func _detect_log_level(line: String) -> String:
	return LogHelpers.detect_log_level(line)


## Builds a source="file" LOG_UNAVAILABLE failure with the version-gated recovery hint
## (buffer-steer only on Godot 4.5+), attaching a `headless_hint` when running headless.
## A headless `--editor` never writes `user://logs/godot.log` — file logging is
## hard-disabled in editor mode on every version (the engine's `!editor` guard term,
## main.cpp) — so the missing file is expected, not a misconfiguration; steer the caller
## to source="buffer". is_headless-gated, so the display response is byte-identical.
static func _log_unavailable_for_file(message: String) -> Dictionary:
	var result := MCPToolkitError.fail("LOG_UNAVAILABLE", message,
			MCPToolkitError.log_unavailable_hint(Modules.LogBuffer.uses_logger_api()))
	if Modules.VersionUtils.is_headless():
		result["headless_hint"] = "editor log file is unavailable — headless editors don't write one (file logging is disabled in editor mode) — use source=\"buffer\" (the default; in-memory, works headless on Godot 4.5+)."
	return result


static func _read_console_log(
	server: Node, limit: int, level_filter: Array, since_id: int,
	text_filter: String = "", text_regex: RegEx = null,
) -> Dictionary:
	# user://logs/ read is a narrow read-only exception to the res://-only rule.
	# Path is internally constructed (not user-supplied), so no FileGuard gate.
	# Honor a relocated debug/file_logging/log_path: dir-scan the configured log's
	# directory for its rotation siblings, preferring the configured filename. Uses
	# the RAW (un-globalized) configured path so the default stays user://logs and
	# the response's log_file metadata is byte-unchanged for the common case.
	var configured_log := LogHelpers.configured_log_path()
	var logs_dir := configured_log.get_base_dir()
	var preferred_name := configured_log.get_file()
	var file_logging_enabled: bool = LogHelpers.is_file_logging_enabled()
	if not DirAccess.dir_exists_absolute(logs_dir):
		if not file_logging_enabled:
			var _hint := "file logging is disabled — enable it in ProjectSettings → Debug → File Logging → Enable File Logging, then restart the editor"
			if Modules.LogBuffer.uses_logger_api():
				_hint += "; alternatively use source=\"buffer\" (default) which captures all output in real-time"
			else:
				_hint += ". On Godot 4.2-4.4 source=\"buffer\" also depends on file logging, so both sources require this setting"
			return _log_unavailable_for_file(_hint)
		return _log_unavailable_for_file(
			"no log directory at %s/ — verify file logging is enabled in ProjectSettings → Debug → File Logging → Enable File Logging" % logs_dir)

	var all_files := DirAccess.get_files_at(logs_dir)
	var log_files: Array[String] = []
	for file_name in all_files:
		if String(file_name).ends_with(".log"):
			log_files.append(String(file_name))
	if log_files.is_empty():
		if not file_logging_enabled:
			var _hint := "file logging is disabled — enable it in ProjectSettings → Debug → File Logging → Enable File Logging, then restart the editor"
			if Modules.LogBuffer.uses_logger_api():
				_hint += "; alternatively use source=\"buffer\" (default) which captures all output in real-time"
			else:
				_hint += ". On Godot 4.2-4.4 source=\"buffer\" also depends on file logging, so both sources require this setting"
			return _log_unavailable_for_file(_hint)
		return _log_unavailable_for_file(
			"no .log files under %s/ — verify file logging is enabled in ProjectSettings → Debug → File Logging → Enable File Logging" % logs_dir)

	var plugin_boot_time: int = server.get_plugin_boot_time()

	var chosen_file := ""
	var chosen_mtime: int = 0
	var warnings: Array[String] = []
	if not file_logging_enabled:
		if Modules.LogBuffer.uses_logger_api():
			warnings.append("file logging is disabled — data may be stale from a previous session; use source=\"buffer\" for real-time output")
		else:
			warnings.append("file logging is disabled — data may be stale from a previous session. On Godot 4.2-4.4 source=\"buffer\" also depends on file logging, so both sources may be stale")

	var preferred_log := logs_dir + "/" + preferred_name
	var preferred_log_mtime: int = 0
	if FileAccess.file_exists(preferred_log):
		preferred_log_mtime = FileAccess.get_modified_time(preferred_log)
	if preferred_log_mtime > 0 and preferred_log_mtime >= plugin_boot_time:
		chosen_file = preferred_log
		chosen_mtime = preferred_log_mtime
	else:
		var best_file := ""
		var best_mtime: int = 0
		for log_file_name in log_files:
			var full_path := logs_dir + "/" + log_file_name
			var mtime := FileAccess.get_modified_time(full_path)
			if mtime >= plugin_boot_time and mtime > best_mtime:
				best_file = full_path
				best_mtime = mtime
		if best_file != "":
			chosen_file = best_file
			chosen_mtime = best_mtime
		else:
			for log_file_name in log_files:
				var full_path := logs_dir + "/" + log_file_name
				var mtime := FileAccess.get_modified_time(full_path)
				if mtime > best_mtime:
					best_file = full_path
					best_mtime = mtime
			if best_file != "":
				chosen_file = best_file
				chosen_mtime = best_mtime
				warnings.append("fallback to stale log — no post-boot log found")

	# Windows 4.4.0 get_modified_time self-collision. The engine's logger opens the
	# live session log GENERIC_WRITE with a deny-nothing share (FileAccess WRITE never
	# sets backup_save -> _SH_DENYNO on every version), so a reader's open always
	# succeeds and the log is never truly locked. But on 4.4.0 get_modified_time makes
	# its own CreateFileW(GENERIC_READ, FILE_SHARE_READ) probe, which denies the live
	# writer -> sharing violation -> mtime reads 0. So the mtime>best_mtime loops above
	# never pick the live log even though the directory enumeration (attribute-level,
	# lock-immune) just listed it. Fall through with the live-log candidate (the
	# configured filename when present) and let the open decide. Scoped to 4.4.0
	# (relaxed in 4.4.1; 4.5 switched to FILE_READ_ATTRIBUTES with full sharing);
	# 4.2/4.3 use a handle-less _wstat that reads the live file fine, so they choose
	# normally via the loops. Unreachable on POSIX (stat succeeds against the deny-nothing writer).
	if chosen_file == "" and not log_files.is_empty():
		var live_name := preferred_name if log_files.has(preferred_name) else log_files[0]
		chosen_file = logs_dir + "/" + live_name

	if chosen_file == "":
		return _log_unavailable_for_file(
			"no readable log file under %s/ — verify file logging is enabled in ProjectSettings → Debug → File Logging → Enable File Logging; playtest may have rotated the editor's log mid-session" % logs_dir)

	var file_handle := FileAccess.open(chosen_file, FileAccess.READ)
	if file_handle == null:
		var open_err := FileAccess.get_open_error()
		# Present-but-unreadable -> LOG_BUSY; a genuinely absent file -> LOG_UNAVAILABLE.
		# On Windows this happens while a game runs: the editor enables safe-save
		# (FileAccess::backup_save), so our READ open requests _SH_DENYWR (deny-write),
		# which the OS refuses while the play process holds the log open for writing — the
		# game's own runtime reader (shared) and source=buffer are unaffected, and it clears
		# when the game exits. Rarer: an external holder (AV/file-sync/backup) with no game
		# running. POSIX has no mandatory share locking, so this path is unreachable there.
		if FileAccess.file_exists(chosen_file) or log_files.has(chosen_file.get_file()):
			return MCPToolkitError.fail("LOG_BUSY",
				"log file exists but could not be read (%s)" % _godot_error_name(open_err),
				MCPToolkitError.log_busy_hint(Modules.LogBuffer.uses_logger_api()))
		return MCPToolkitError.fail("LOG_UNAVAILABLE",
			"cannot open %s (%s)" % [chosen_file, _godot_error_name(open_err)],
			MCPToolkitError.log_unavailable_hint(Modules.LogBuffer.uses_logger_api()))
	var content := file_handle.get_as_text()
	file_handle.close()

	var lines := content.split("\n")
	var entries: Array = []
	var char_offset: int = 0

	for line_index in range(lines.size()):
		var line: String = LogHelpers.strip_ansi(lines[line_index])
		if line.strip_edges().is_empty():
			char_offset += line.length() + 1
			continue
		var level := _detect_log_level(line)
		if level == "info" and entries.size() > 0 and LogHelpers.is_continuation_line(line):
			var previous: Dictionary = entries[-1]
			if previous["level"] == "error" or previous["level"] == "warning":
				previous["message"] += "\n" + line
				char_offset += line.length() + 1
				continue
		entries.append({
			"id": char_offset,
			"level": level,
			"message": line,
			"timestamp_unix": null,
		})
		char_offset += line.length() + 1

	if level_filter.size() > 0:
		var level_set: Array[String] = []
		for filter_entry in level_filter:
			level_set.append(str(filter_entry))
		var filtered: Array = []
		for entry in entries:
			if entry["level"] in level_set:
				filtered.append(entry)
		entries = filtered

	if since_id >= 0:
		var filtered: Array = []
		for entry in entries:
			if entry["id"] > since_id:
				filtered.append(entry)
		entries = filtered

	if text_filter != "":
		var text_filtered: Array = []
		for entry in entries:
			var msg: String = str(entry["message"])
			if text_regex != null:
				if text_regex.search(msg):
					text_filtered.append(entry)
			else:
				if msg.findn(text_filter) >= 0:
					text_filtered.append(entry)
		entries = text_filtered

	# Capture the pre-slice entry count for total_lines before the slice
	# below reassigns `entries` to the capped tail.
	var total_lines := entries.size()
	var has_more := entries.size() > limit
	if has_more:
		entries = entries.slice(entries.size() - limit)

	var next_id: int = -1
	if entries.size() > 0:
		next_id = entries[-1]["id"]

	for entry in entries:
		var scrubbed := Scrubber.scrub(str(entry["message"]), "console")
		entry["message"] = scrubbed["text"]

	# Capped-tail line paging (resume via next_id → since_id, cursor-less for the builder).
	var hint := ""
	if has_more:
		hint = "more lines remain — re-call editor.get_console with since_id = next_id (%d) until has_more is false" % next_id
	var response := Modules.Pagination.build(
		{"entries": Untrusted.wrap("console", str(chosen_file), JSON.stringify(entries))},
		"lines", total_lines, entries.size(), has_more, "", 0, hint,
		{
			"next_id": next_id,
			"log_file": chosen_file,
			"log_mtime": chosen_mtime,
			"warnings": warnings,
		})
	return MCPToolkitSuccess.ok(response)
