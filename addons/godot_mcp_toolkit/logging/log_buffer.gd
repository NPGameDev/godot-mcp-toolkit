@tool
extends RefCounted
## In-memory ring buffer capturing ALL console output.
##
## Two capture strategies, selected automatically at setup():
##
## Godot 4.5+  — Logger subclass (compiled at runtime via GDScript.new()
##               to avoid parse errors on older versions). Captures
##               print(), printerr(), push_warning(), push_error(),
##               engine errors, shader errors. Zero latency.
##
## Godot 4.2–4.4 — Log file tailing. poll() reads new bytes from the
##                  configured log path since the last read offset.
##                  ~500ms polling interval, subject to Godot's
##                  file-flush timing.
##
## Thread safety: Logger callbacks can fire from any thread.
## All buffer access is Mutex-protected.

const LogHelpers := preload("res://addons/godot_mcp_toolkit/logging/log_helpers.gd")
# Export-clean (core APIs only) — safe in the runtime autoload's preload closure,
# which pulls this file in.
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")

const _CAPACITY := 500
const _POLL_INTERVAL_MS := 200
const _SCRIPT_ERROR_LATCH_CAPACITY := 16

# -- Shared state (Mutex-protected) ------------------------------------------

static var _mutex: Mutex = Mutex.new()
static var _entries: Array = []
static var _next_id: int = 0
# Structured {id, file, line} locations of captured SCRIPT errors (Logger
# error_type 2), latched beside their console entries. A separate side-channel
# on purpose: console entries keep their {id, timestamp_unix, level, message}
# wire shape, while script_check recovers the real parse line of a reload it
# just ran. Only the 4.5+ Logger fills it — the 4.2-4.4 file tail has no
# structured line data.
static var _script_error_locations: Array = []

# -- Strategy tracking --------------------------------------------------------

static var _use_logger: bool = false
static var _setup_done: bool = false
static var _logger_ref = null  # prevent GC — OS.add_logger() holds a raw C++ pointer

# -- File-tail state (4.2-4.4 only) ------------------------------------------

static var _tail_offset: int = 0
static var _tail_path: String = ""
static var _last_poll_ms: int = 0
static var _tail_open_failures: int = 0
## Last detected level in the tail stream, so a continuation ("   at: …") line inherits
## the preceding error/warning level instead of "info" (the location line carries the
## script path). Reset on (re)setup. See LogHelpers.is_continuation_line.
static var _last_tail_level: String = "info"


# =============================================================================
# Public API
# =============================================================================


## Returns true when the Logger API (4.5+) is active, false when using file
## tailing (4.2-4.4). Callers use this to decide whether source="buffer" is
## independent of file-logging settings.
static func uses_logger_api() -> bool:
	return _use_logger


## Call once from plugin.gd _enter_tree().
static func setup() -> void:
	if _setup_done:
		return
	_setup_done = true

	if ClassDB.class_exists(&"Logger"):
		_setup_logger()
	else:
		_setup_file_tail()


## Push an entry into the ring buffer. Thread-safe.
## Called by Logger callbacks (4.5+) or file tailer (4.2-4.4).
static func push(level: String, message: String) -> void:
	_mutex.lock()
	_append_entry_unlocked(level, message)
	_mutex.unlock()


## Push a SCRIPT error (Logger error_type 2): the console entry plus its
## structured {id, file, line} location latch, atomically — the latch id is
## exactly the entry's id, so since-cursor correlation can never misattribute.
## Thread-safe. The console entry shape is identical to [method push].
static func push_script_error(level: String, message: String, file: String, line: int) -> void:
	_mutex.lock()
	var entry_id := _append_entry_unlocked(level, message)
	_script_error_locations.append({"id": entry_id, "file": file, "line": line})
	if _script_error_locations.size() > _SCRIPT_ERROR_LATCH_CAPACITY:
		_script_error_locations.pop_front()
	_mutex.unlock()


## Line of the first in-memory script error captured after [param since_id],
## or -1 when none was.
##
## Serves script_check's reload validation: a GDScript built from source (no
## disk path) reports under a synthetic "gdscript://…" path ("built-in" on
## engines predating that scheme), so matching that shape picks the caller's
## own just-triggered reload error and never a threaded editor-scan error on a
## res:// script that lands in the same window. Returns -1 on 4.2-4.4 (the
## file tail latches nothing) — callers omit their line field then.
static func find_script_error_line_since(since_id: int) -> int:
	_mutex.lock()
	var found := -1
	for location in _script_error_locations:
		if int(location["id"]) <= since_id:
			continue
		var file := str(location["file"])
		if file == "built-in" or file.begins_with("gdscript://"):
			found = int(location["line"])
			break
	_mutex.unlock()
	return found


# Appends one entry and returns its id. Caller must hold _mutex.
static func _append_entry_unlocked(level: String, message: String) -> int:
	var entry := {
		"id": _next_id,
		"timestamp_unix": int(Time.get_unix_time_from_system()),
		"level": level,
		"message": LogHelpers.strip_ansi(message),
	}
	_next_id += 1
	if _entries.size() >= _CAPACITY:
		_entries.pop_front()
	_entries.append(entry)
	return int(entry["id"])


## Read entries from the buffer. Calls poll() first to ensure freshness.
##
## Returns the capped tail of the filtered entries plus the pagination fields both
## log readers stamp onto the wire envelope: {entries, returned, next_id, has_more,
## total_lines}. [param since_id] is a resume cursor (entries with id <= it are
## dropped); the returned next_id is the last entry's id for the next call.
static func get_entries(limit: int, level_filter: Array = [], since_id: int = -1, text_filter: String = "", text_regex: RegEx = null) -> Dictionary:
	poll()

	_mutex.lock()
	var filtered: Array = []
	for entry in _entries:
		if since_id >= 0 and int(entry["id"]) <= since_id:
			continue
		if level_filter.size() > 0 and not (str(entry["level"]) in level_filter):
			continue
		if text_filter != "":
			var msg: String = str(entry["message"])
			if text_regex != null:
				if not text_regex.search(msg):
					continue
			else:
				if msg.findn(text_filter) < 0:
					continue
		filtered.append(entry.duplicate())
	_mutex.unlock()

	# Capture the pre-slice filtered count for total_lines before the
	# slice below reassigns `filtered` to the capped tail.
	var total_lines := filtered.size()
	var has_more := filtered.size() > limit
	if has_more:
		filtered = filtered.slice(filtered.size() - limit)

	var next_id: int = -1
	if filtered.size() > 0:
		next_id = int(filtered[-1]["id"])

	# Shared source for the log-paging envelope: both the editor console reader and
	# the runtime debugger.get_log read these keys and stamp the final wire envelope,
	# so the field names here follow the standard pagination vocabulary.
	return {
		"entries": filtered,
		"returned": filtered.size(),
		"next_id": next_id,
		"has_more": has_more,
		"total_lines": total_lines,
	}


## Returns the ID that will be assigned to the next pushed entry.
## Snapshot this before game_start to filter entries by game session.
static func get_cursor() -> int:
	_mutex.lock()
	var cursor := _next_id
	_mutex.unlock()
	return cursor


## Reset the buffer (script-error location latch included — its ids reset too).
static func clear() -> void:
	_mutex.lock()
	_entries.clear()
	_script_error_locations.clear()
	_next_id = 0
	_mutex.unlock()


## Remove entries matching a specific level (e.g. "error"). Returns count removed.
static func clear_level(level: String) -> int:
	_mutex.lock()
	var kept: Array = []
	var removed := 0
	for entry in _entries:
		if str(entry["level"]) == level:
			removed += 1
		else:
			kept.append(entry)
	_entries = kept
	_mutex.unlock()
	return removed


## No-op on 4.5+ (Logger handles everything).
## On 4.2-4.4, tails the log file for new lines. Self-throttled.
## Safe to call every frame — returns immediately if interval not elapsed.
static func poll() -> void:
	if _use_logger:
		return
	var now := Time.get_ticks_msec()
	if now - _last_poll_ms < _POLL_INTERVAL_MS:
		return
	_last_poll_ms = now
	_tail_log_file()


# =============================================================================
# Logger strategy (Godot 4.5+)
# =============================================================================


## Compose the console message for a structured engine error (the Logger `_log_error`
## callback). Mirrors the engine StdLogger's two-line
## "PREFIX: <detail>\n   at: <function> (<file>:<line>)" shape.
##
## When [param append_location] is true the "   at:" line is appended so the source path
## lives inside the entry. Editors up to 4.6 emit a separate path-bearing "Failed to load
## script" error during script scans, so the caller passes false there and the path is not
## duplicated; Godot 4.7 dropped that separate message from the scan path, leaving the path
## only in this callback's file arg, so the caller passes true to keep the filename
## captured (text/console filters match on it). A fileless / "built-in" source has no
## useful path, so the location is skipped. Pure — no editor symbols — so it is unit-tested
## headless.
static func compose_error_message(prefix: String, code: String, rationale: String,
		function_name: String, file_path: String, line: int, append_location: bool) -> String:
	var detail := code
	if rationale != "":
		detail = code + ": " + rationale
	var full := prefix + ": " + detail
	if append_location and file_path != "" and file_path != "built-in":
		full += "\n   at: " + function_name + " (" + file_path + ":" + str(line) + ")"
	return full


static func _setup_logger() -> void:
	_use_logger = true
	# Compile the Logger subclass at runtime so no file on disk contains
	# "extends Logger" — avoids parse errors on Godot 4.2-4.4.
	var script := GDScript.new()
	script.source_code = _LOGGER_SOURCE
	var err := script.reload()
	if err != OK:
		push_warning("[LogBuffer] Logger hook compile failed (err %d), falling back to file tail" % err)
		_use_logger = false
		_setup_file_tail()
		return
	_logger_ref = script.new()
	# Pass a reference to this script so the logger can call push() / compose_error_message().
	_logger_ref.set_meta("_log_buffer", load("res://addons/godot_mcp_toolkit/logging/log_buffer.gd"))
	# Godot 4.7 stopped surfacing the separate path-bearing "Failed to load script" error
	# during editor script scans, leaving the script path only in the structured _log_error
	# callback's file arg. Flag 4.7+ so the logger appends the engine-style "   at:" location
	# line to script errors and the filename stays captured; 4.5/4.6 keep prior byte-for-byte
	# output (their separate load error already carries the path).
	_logger_ref.set_meta("_append_error_location",
		VersionUtils.is_at_least(VersionUtils.get_engine_version_pair(), "4.7"))
	# Dynamic call — OS.add_logger() only exists in 4.5+; static reference
	# causes a parse error on 4.2-4.4 even inside a guarded branch.
	OS.call("add_logger", _logger_ref)


const _LOGGER_SOURCE := '
extends Logger

func _log_message(message: String, error: bool) -> void:
	var buf = get_meta("_log_buffer")
	if buf == null:
		return
	var level: String = "error" if error else "info"
	buf.push(level, message.strip_edges())

func _log_error(function_name: String, file_path: String, line: int,
		code: String, rationale: String, _editor_notify: bool,
		error_type: int, _script_backtraces) -> void:
	var buf = get_meta("_log_buffer")
	if buf == null:
		return
	var level: String = "warning" if error_type == 1 else "error"
	var prefix: String = "WARNING" if error_type == 1 else "ERROR"
	# error_type 2 == Logger.ERR_SCRIPT: only script errors carry a .gd source path worth
	# preserving. The 4.7+ flag (set at setup from the engine version) enables the location
	# line; see compose_error_message.
	var append_location: bool = bool(get_meta("_append_error_location", false)) and error_type == 2
	var composed: String = buf.compose_error_message(prefix, code, rationale, function_name, file_path, line, append_location)
	if error_type == 2:
		# Script errors also latch their structured {file, line}: the composed
		# message drops both for in-memory scripts, and script_check needs the
		# real parse line of a reload it just ran.
		buf.push_script_error(level, composed, file_path, line)
	else:
		buf.push(level, composed)
'


# =============================================================================
# File-tail strategy (Godot 4.2-4.4)
# =============================================================================


## Re-resolve the log tail path after a config/name change shifts user://.
## No-op when using Logger API (4.5+).
static func reset_tail_path() -> void:
	if _use_logger:
		return
	_tail_path = LogHelpers.resolve_log_path()
	# Don't reset offset — if the engine kept writing to the same file
	# (and the absolute path didn't change), we keep our position.
	# If it's a genuinely new file, _tail_log_file() handles the
	# file_len < _tail_offset case by resetting automatically.


static func _setup_file_tail() -> void:
	# Resolve to an absolute OS path so casual user:// resolution shifts
	# (e.g. from config/name changes) don't silently break tailing.
	# UserPathMonitor calls reset_tail_path() on rename to re-resolve.
	_tail_path = LogHelpers.resolve_log_path()
	# Start from beginning so the buffer captures the full current-session log.
	# On Windows, Godot holds the log file open with buffered writes — new
	# content written after plugin load may not be visible to our read handle
	# until flushed. Starting from 0 ensures startup messages are captured.
	_tail_offset = 0
	_last_tail_level = "info"


static func _tail_log_file() -> void:
	if _tail_path.is_empty():
		return
	if not FileAccess.file_exists(_tail_path):
		return
	var f := FileAccess.open(_tail_path, FileAccess.READ)
	if f == null:
		_tail_open_failures += 1
		return
	var file_len: int = f.get_length()
	if file_len <= _tail_offset:
		if file_len < _tail_offset:
			# File was truncated/rotated — reset.
			_tail_offset = 0
		f.close()
		return
	f.seek(_tail_offset)
	var remaining: int = file_len - _tail_offset
	var new_bytes := f.get_buffer(remaining)
	_tail_offset = file_len
	f.close()

	var new_text := new_bytes.get_string_from_utf8()
	if new_text.is_empty():
		return
	var lines := new_text.split("\n")
	for line in lines:
		var stripped := line.strip_edges()
		if stripped.is_empty():
			continue
		# A continuation ("   at: …") line inherits the preceding error/warning level so
		# a multi-line error stays error-leveled (its location line carries the script
		# path) — matching the source=file reader's coalescing and the 4.5+ Logger's
		# one-entry-per-error. See LogHelpers.is_continuation_line.
		var level: String
		if LogHelpers.is_continuation_line(line) \
				and (_last_tail_level == "error" or _last_tail_level == "warning"):
			level = _last_tail_level
		else:
			level = _detect_log_level(stripped)
		push(level, stripped)
		_last_tail_level = level


static func _detect_log_level(line: String) -> String:
	return LogHelpers.detect_log_level(line)
