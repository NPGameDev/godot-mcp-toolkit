@tool
extends RefCounted
## game.* command handlers — start/stop editor playtest (Mode A).

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const McpError = _Hub.McpError
const FileGuard = _Hub.FileGuard
const RegistryClient = _Hub.RegistryClient
const Helpers = _Hub.Helpers
const MCPAuth := preload("res://addons/godot_mcp_toolkit/auth.gd")

const RUNTIME_HOST := "127.0.0.1"
const RUNTIME_POLL_TIMEOUT_MS := 5000
const _REGISTRY_POLL_INTERVAL_MS := 100

# Log-file offset snapshot at game_start — bytes after this offset belong to
# the current/most-recent game session. The log file (user://logs/godot.log)
# is shared by editor + game processes, so reading from this offset gives us
# game output even though the Logger API is process-local (4.5+).
static var _game_session_file_offset: int = -1

# Debug bridge reference — injected at register() time.
# Used by debugger.get_log to include error_buffer + debug_state.
static var _debug_bridge: RefCounted = null


static func register(registry: MCPToolkitCommandRegistry, _server: Node,
		debug_bridge: RefCounted = null) -> void:
	_debug_bridge = debug_bridge
	registry.add("game.start", func(parameters: Dictionary) -> Dictionary:
		return _cmd_game_start(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_exclusive_execution())
	registry.add("game.stop", func(parameters: Dictionary) -> Dictionary:
		return _cmd_game_stop(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_exclusive_execution().mark_scene_independent())
	registry.add("debugger.get_log", func(parameters: Dictionary) -> Dictionary:
		return _cmd_debugger_get_log_cached(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())


static func clear_debug_bridge() -> void:
	_debug_bridge = null


# -- Commands -----------------------------------------------------------------


static func _cmd_game_start(parameters: Dictionary) -> Dictionary:
	var target := str(parameters.get("scene_path", "current"))
	var wait_for_runtime_raw = parameters.get("wait_for_runtime", true)
	var wait_for_runtime := bool(wait_for_runtime_raw) \
		if typeof(wait_for_runtime_raw) == TYPE_BOOL else true
	var runtime_poll_raw = parameters.get("runtime_poll", false)
	var runtime_poll := bool(runtime_poll_raw) \
		if typeof(runtime_poll_raw) == TYPE_BOOL else false
	var if_running := str(parameters.get("if_running", "fail"))

	if not (if_running in ["return", "fail"]):
		return McpError.make("INVALID_PARAMS",
			"if_running must be 'return' or 'fail' (got %s); default is 'fail'" % if_running)

	if runtime_poll:
		if not EditorInterface.is_playing_scene():
			var comp := _scan_compilation_errors()
			if comp["found"]:
				return McpError.make("COMPILATION_FAILED",
					"Game failed to start — likely a compilation error. Recent errors:\n" + "\n".join(comp["errors"]))
			return McpError.make("COMPILATION_FAILED",
				"Game is not running — it likely failed to compile or crashed on startup. "
				+ ("No errors captured in log buffer (file-tail mode on Godot 4.2-4.4 may miss errors). " if not _Hub.LogBuffer.uses_logger_api() else "No errors in log buffer. ")
				+ "Call editor_refresh to retrigger compilation errors, then editor_get_console for details.")
	else:
		if EditorInterface.is_playing_scene():
			if if_running == "return":
				var runtime_port := RegistryClient.get_runtime_port()
				return {"success": true, "status": "already_running",
					"runtime_port": runtime_port if runtime_port > 0 else null}
			return McpError.make("ALREADY_PLAYING",
				"a game is already running; call game.stop first, or use runtime_poll:true to re-probe the runtime connection")

		# Snapshot the log file size so the editor-side debugger.get_log
		# cache only returns output from THIS game session. The log file
		# is shared by editor + game, so bytes after this offset = game output.
		_game_session_file_offset = _get_log_file_size()

		match target:
			"main":
				EditorInterface.play_main_scene()
			"current":
				if Helpers.get_edited_root() == null:
					return McpError.make("NO_SCENE",
						"no currently-edited scene; use target:'main' or target:<res://path>, or scene.open first")
				EditorInterface.play_current_scene()
			_:
				var guard := FileGuard.resolve_safe(target)
				if guard["error"] != null:
					return McpError.make("PATH_DENIED", str(guard["reason"]))
				if target.get_extension().to_lower() != "tscn":
					return McpError.make("INVALID_PATH",
						"game.start only plays .tscn files (got %s)" % target)
				if not FileAccess.file_exists(target):
					return McpError.make("NOT_FOUND",
						"no scene file at %s; use scene.create first" % target, McpError.HINT_FILE_PATH)
				EditorInterface.play_custom_scene(target)

	# Runtime readiness check.
	var runtime_port := -1
	var runtime_ready := false
	var runtime_failure := ""
	var bridge_discovery := false

	if runtime_poll:
		# Explicit re-probe: full poll loop (runtime_poll:true path).
		var deadline := Time.get_ticks_msec() + RUNTIME_POLL_TIMEOUT_MS
		while Time.get_ticks_msec() < deadline:
			runtime_port = RegistryClient.get_runtime_port()
			if runtime_port > 0:
				break
			OS.delay_msec(_REGISTRY_POLL_INTERVAL_MS)
		if runtime_port > 0:
			var remaining := maxi(500, deadline - Time.get_ticks_msec())
			var probe := _poll_runtime_ready(
				RUNTIME_HOST, runtime_port, remaining)
			runtime_ready = probe["ready"]
			if not runtime_ready:
				runtime_failure = str(probe.get("failure", "unknown"))
		else:
			runtime_failure = "registry_timeout"
	elif wait_for_runtime:
		# Godot's editor is single-threaded: play_custom_scene() defers
		# game launch to the event loop, so blocking polls can never
		# succeed here (main thread blocked → game cannot spawn).
		# The agent must follow up with:
		#   game_start(if_running:"return", runtime_poll:true)
		bridge_discovery = true

	var response := {
		"success": true,
		"target": target,
		"runtime_port": runtime_port if runtime_port > 0 else null,
		"runtime_ready": runtime_ready,
	}
	if bridge_discovery:
		response["runtime_discovery"] = "bridge"
		# Hint text suppressed when wait_for_runtime=true — the MCP server
		# absorbs the async gap and returns a single combined response.
		# Non-server clients can key off runtime_discovery:"bridge" to follow
		# up with game_start(if_running:'return', runtime_poll:true).
		if not wait_for_runtime:
			response["hint"] = (
				"Game launched but runtime not yet connected (Godot defers the "
				+ "game process — it cannot start during a blocking call). "
				+ "Follow up with game_start(if_running:'return', runtime_poll:true) "
				+ "to wait for runtime readiness."
			)
	if runtime_poll:
		response["runtime_poll"] = true
	if (wait_for_runtime or runtime_poll) and not runtime_ready and not bridge_discovery:
		response["runtime_failure"] = runtime_failure
		match runtime_failure:
			"registry_timeout":
				if not EditorInterface.is_playing_scene():
					var comp := _scan_compilation_errors()
					if comp["found"]:
						response["compilation_failed"] = true
						response["compilation_errors"] = comp["errors"]
						response["hint"] = "Game failed to start (compilation error). Errors:\n" + "\n".join(comp["errors"])
					else:
						response["compilation_failed"] = true
						response["hint"] = "Game never started — likely a compilation error. " \
							+ ("No errors in log buffer (file-tail mode may miss errors). " if not _Hub.LogBuffer.uses_logger_api() else "") \
							+ "Call editor_refresh to retrigger compilation errors, then editor_get_console for details."
				else:
					response["hint"] = "Runtime port never appeared in registry within the timeout. The game may need more time to start. Try game_start with runtime_poll:true to re-probe, or check editor_get_console for startup errors."
			"token_read_failed":
				response["hint"] = "Could not read auth token — the token file may be missing or empty. Re-enable the plugin in Project Settings > Plugins."
			"ws_connect_timeout":
				response["hint"] = "Port %d found but WebSocket connection failed — the runtime server may have crashed on startup. Check editor_get_console for errors." % runtime_port
			"auth_timeout":
				response["hint"] = "WebSocket connected but auth handshake timed out — the token may be stale. Re-enable the plugin in Project Settings > Plugins to regenerate it."
			"ping_timeout":
				response["hint"] = "Authenticated but ping/pong timed out — the runtime server may be overloaded. Use runtime_poll:true to retry without restarting the game."
			_:
				response["hint"] = "Runtime not ready (%s). Checklist: (1) Is the MCP Runtime autoload enabled? (2) Is port 6570 available? (3) Check editor_get_console for errors. (4) For Standard profile: call discover_tools({request: 'runtime'}) to load runtime tools." % runtime_failure
	# P-006: When no poll was requested and runtime isn't ready, warn that
	# runtime tools will block/fail. Prevents agents from calling
	# runtime_screenshot / input_simulate on a game that didn't connect.
	elif not runtime_ready and not wait_for_runtime and not runtime_poll:
		response["hint"] = (
			"runtime_ready is false — runtime tools (runtime_screenshot, input_simulate, "
			+ "execute_code, etc.) will NOT work until the runtime connects. "
			+ "Call game_start with wait_for_runtime:true to wait for connection, "
			+ "or use runtime_poll:true to re-probe. "
			+ "Check debugger_get_log or editor_get_console for startup errors."
		)
	return response


static func _cmd_game_stop(_parameters: Dictionary) -> Dictionary:
	var was_running := EditorInterface.is_playing_scene()
	EditorInterface.stop_playing_scene()
	return {"success": true, "was_running": was_running}


## Editor-side debugger.get_log — returns cached log entries from the most
## recent game session. Reads from the LOG FILE (shared by editor + game
## processes) rather than the in-memory LogBuffer (which is process-local
## and only captures editor output on 4.5+).
## When a debug bridge is available, merges the error buffer and debug state
## into the response — gives the server a single call for full crash context.
static func _cmd_debugger_get_log_cached(parameters: Dictionary) -> Dictionary:
	var limit: int = max(1, int(parameters.get("limit", 200)))
	var text_filter: String = str(parameters.get("text_filter", ""))
	var tf := Helpers.compile_text_filter(parameters)
	var text_regex: RegEx = tf[0]
	if tf[1] != null:
		return tf[1]
	var regex_warning: String = tf[2]

	# Auto-stop: if debug bridge says session is dead but editor still thinks
	# game is running, stop it to clean up state and flush the log file.
	if _debug_bridge != null:
		var ds: Dictionary = _debug_bridge.get_debug_state()
		if not ds.get("active", false) and EditorInterface.is_playing_scene():
			EditorInterface.stop_playing_scene()

	if _game_session_file_offset < 0:
		var response := {
			"success": true,
			"lines": [],
			"count": 0,
			"source": "cache",
			"note": "No game session recorded yet (game_start was never called this editor session)",
		}
		_merge_debug_bridge_data(response)
		return response

	# Read the log file from the offset where the game session started.
	var log_path: String = _resolve_log_path()
	if not FileAccess.file_exists(log_path):
		var response := {
			"success": true,
			"lines": [],
			"count": 0,
			"source": "cache",
			"note": "Log file not found. Enable debug/file_logging/enable_file_logging in ProjectSettings and restart.",
		}
		_merge_debug_bridge_data(response)
		return response

	var file := FileAccess.open(log_path, FileAccess.READ)
	if file == null:
		return McpError.make("LOG_BUSY",
			"Log file exists but cannot be read (err %d) — retry in 1-2s" % FileAccess.get_open_error())

	var file_len: int = file.get_length()
	if file_len <= _game_session_file_offset:
		file.close()
		var response := {
			"success": true,
			"lines": [],
			"count": 0,
			"source": "cache",
			"note": "No new output since game_start (log file unchanged).",
		}
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
		var stripped := Helpers.strip_ansi(line.strip_edges())
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
	var truncated := filtered.size() > limit
	if truncated:
		filtered = filtered.slice(filtered.size() - limit)

	var response := {
		"success": true,
		"lines": filtered,
		"count": filtered.size(),
		"truncated": truncated,
		"source": "cache",
	}
	# Pass unfiltered lines so error scan always has full context.
	_merge_debug_bridge_data(response, stripped_lines)
	if not regex_warning.is_empty():
		response["warning"] = regex_warning
	return response


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
			errors.append({
				"timestamp_ms": 0,
				"message": msg,
				"source": source,
				"function": func_name,
				"line": source_line,
				"type": "log_scan",
			})
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


# -- Runtime probe ------------------------------------------------------------


## WebSocket health-check: connect, authenticate, send ping, wait for response.
## Only reports true when the full JSON-RPC layer is operational (no false
## positives from a TCP-only probe).
## Returns {"ready": true} on success, or {"ready": false, "failure": <stage>}
## where stage is one of: token_read_failed, ws_connect_timeout, auth_timeout,
## ping_timeout.
static func _poll_runtime_ready(
	host: String, port: int, timeout_ms: int,
) -> Dictionary:
	var token_path := MCPAuth.get_token_path()
	var token_file := FileAccess.open(token_path, FileAccess.READ)
	if token_file == null:
		return {"ready": false, "failure": "token_read_failed"}
	var token := token_file.get_as_text().strip_edges()
	token_file.close()
	if token.is_empty():
		return {"ready": false, "failure": "token_read_failed"}

	var furthest := "ws_connect_timeout"
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var ws := WebSocketPeer.new()
		var err := ws.connect_to_url("ws://%s:%d" % [host, port])
		if err != OK:
			OS.delay_msec(100)
			continue

		var auth_sent := false
		var ping_sent := false
		while Time.get_ticks_msec() < deadline:
			ws.poll()
			var state := ws.get_ready_state()
			if state == WebSocketPeer.STATE_CLOSED \
					or state == WebSocketPeer.STATE_CLOSING:
				break
			if state != WebSocketPeer.STATE_OPEN:
				OS.delay_msec(10)
				continue

			if furthest == "ws_connect_timeout":
				furthest = "auth_timeout"

			if not auth_sent:
				ws.send_text(JSON.stringify({"auth": token}))
				auth_sent = true
				OS.delay_msec(10)
				continue

			while ws.get_available_packet_count() > 0:
				var text := ws.get_packet().get_string_from_utf8()
				var parser := JSON.new()
				if parser.parse(text) != OK:
					continue
				var msg = parser.data
				if typeof(msg) != TYPE_DICTIONARY:
					continue
				if not ping_sent:
					if msg.get("authed", false) == true:
						ws.send_text(JSON.stringify({
							"jsonrpc": "2.0", "method": "ping", "id": 0}))
						ping_sent = true
						furthest = "ping_timeout"
				else:
					if msg.has("result"):
						ws.close(1000)
						return {"ready": true}

			OS.delay_msec(10)

		ws.close()
		OS.delay_msec(100)
	return {"ready": false, "failure": furthest}


## Scan LogBuffer for recent errors — used to detect compilation failures
## when the game fails to start.
static func _scan_compilation_errors() -> Dictionary:
	var buf := _Hub.LogBuffer.get_entries(10, ["error"])
	var errors: Array = []
	for entry in buf.get("entries", []):
		errors.append(str(entry.get("message", "")))
	return {
		"found": errors.size() > 0,
		"errors": errors,
		"source": "logger" if _Hub.LogBuffer.uses_logger_api() else "file_tail",
	}
