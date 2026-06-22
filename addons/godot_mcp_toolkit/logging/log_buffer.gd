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

const _CAPACITY := 500
const _POLL_INTERVAL_MS := 200

# -- Shared state (Mutex-protected) ------------------------------------------

static var _mutex: Mutex = Mutex.new()
static var _entries: Array = []
static var _next_id: int = 0

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
## script path). Reset on (re)setup. See LogHelpers.is_continuation_line / 41m-ter.
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
	_mutex.unlock()


## Read entries from the buffer. Calls poll() first to ensure freshness.
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

	var truncated := filtered.size() > limit
	if truncated:
		filtered = filtered.slice(filtered.size() - limit)

	var next_id: int = -1
	if filtered.size() > 0:
		next_id = int(filtered[-1]["id"])

	return {
		"entries": filtered,
		"count": filtered.size(),
		"next_id": next_id,
		"truncated": truncated,
	}


## Returns the ID that will be assigned to the next pushed entry.
## Snapshot this before game_start to filter entries by game session.
static func get_cursor() -> int:
	_mutex.lock()
	var cursor := _next_id
	_mutex.unlock()
	return cursor


## Reset the buffer.
static func clear() -> void:
	_mutex.lock()
	_entries.clear()
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
	# Pass a reference to this script so the logger can call push().
	_logger_ref.set_meta("_log_buffer", load("res://addons/godot_mcp_toolkit/logging/log_buffer.gd"))
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

func _log_error(_function: String, _file: String, _line: int,
		code: String, rationale: String, _editor_notify: bool,
		error_type: int, _script_backtraces) -> void:
	var buf = get_meta("_log_buffer")
	if buf == null:
		return
	var level: String = "warning" if error_type == 1 else "error"
	var prefix: String = "WARNING" if error_type == 1 else "ERROR"
	var msg: String = code
	if rationale != "":
		msg = code + ": " + rationale
	buf.push(level, prefix + ": " + msg)
'


# =============================================================================
# File-tail strategy (Godot 4.2-4.4)
# =============================================================================


## Re-resolve the log tail path after a config/name change shifts user://.
## Called by plugin.gd via UserPathMonitor. No-op when using Logger API (4.5+).
static func reset_tail_path() -> void:
	if _use_logger:
		return
	_tail_path = _resolve_log_path()
	# Don't reset offset — if the engine kept writing to the same file
	# (and the absolute path didn't change), we keep our position.
	# If it's a genuinely new file, _tail_log_file() handles the
	# file_len < _tail_offset case by resetting automatically.


static func _resolve_log_path() -> String:
	var configured := ProjectSettings.get_setting(
		"debug/file_logging/log_path", "user://logs/godot.log") as String
	if configured.begins_with("user://") or configured.begins_with("res://"):
		return ProjectSettings.globalize_path(configured)
	return configured


static func _setup_file_tail() -> void:
	# Resolve to an absolute OS path so casual user:// resolution shifts
	# (e.g. from config/name changes) don't silently break tailing.
	# UserPathMonitor calls reset_tail_path() on rename to re-resolve.
	_tail_path = _resolve_log_path()
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
		# one-entry-per-error. See LogHelpers.is_continuation_line (41m-ter).
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
