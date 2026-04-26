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

const _CAPACITY := 500
const _POLL_INTERVAL_MS := 200

# -- Shared state (Mutex-protected) ------------------------------------------

static var _mutex: Mutex = Mutex.new()
static var _entries: Array = []
static var _next_id: int = 0

# -- Strategy tracking --------------------------------------------------------

static var _use_logger: bool = false
static var _setup_done: bool = false

# -- File-tail state (4.2-4.4 only) ------------------------------------------

static var _tail_offset: int = 0
static var _tail_path: String = ""
static var _last_poll_ms: int = 0


# =============================================================================
# Public API
# =============================================================================


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
		"message": message,
	}
	_next_id += 1
	if _entries.size() >= _CAPACITY:
		_entries.pop_front()
	_entries.append(entry)
	_mutex.unlock()


## Read entries from the buffer. Calls poll() first to ensure freshness.
static func get_entries(limit: int, level_filter: Array = [], since_id: int = -1) -> Dictionary:
	poll()

	_mutex.lock()
	var filtered: Array = []
	for entry in _entries:
		if since_id >= 0 and int(entry["id"]) <= since_id:
			continue
		if level_filter.size() > 0 and not (str(entry["level"]) in level_filter):
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


## Reset the buffer.
static func clear() -> void:
	_mutex.lock()
	_entries.clear()
	_next_id = 0
	_mutex.unlock()


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
	var logger = script.new()
	# Pass a reference to this script so the logger can call push().
	logger.set_meta("_log_buffer", load("res://addons/godot_mcp_toolkit/log_buffer.gd"))
	OS.add_logger(logger)


const _LOGGER_SOURCE := '
extends Logger

func _log_message(message: String, error: bool) -> void:
	var buf = get_meta("_log_buffer")
	if buf == null:
		return
	var level: String = "error" if error else "info"
	buf.push(level, message.strip_edges())

func _log_error(function: String, file: String, line: int,
		code: String, rationale: String, editor_notify: bool,
		error_type: int, script_backtraces) -> void:
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


static func _setup_file_tail() -> void:
	# Respect the user's configured log path.
	_tail_path = ProjectSettings.get_setting(
		"debug/file_logging/log_path", "user://logs/godot.log")
	# Seek to end of existing file so we only capture new output.
	if FileAccess.file_exists(_tail_path):
		var f := FileAccess.open(_tail_path, FileAccess.READ)
		if f != null:
			_tail_offset = f.get_length()
			f.close()


static func _tail_log_file() -> void:
	if _tail_path.is_empty():
		return
	if not FileAccess.file_exists(_tail_path):
		return
	var f := FileAccess.open(_tail_path, FileAccess.READ)
	if f == null:
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
		var level := _detect_log_level(stripped)
		push(level, stripped)


static func _detect_log_level(line: String) -> String:
	if line.begins_with("ERROR:") or line.begins_with("USER ERROR:") \
			or line.begins_with("SCRIPT ERROR:"):
		return "error"
	if line.begins_with("WARNING:") or line.begins_with("USER WARNING:") \
			or line.begins_with("SCRIPT WARNING:"):
		return "warning"
	return "info"
