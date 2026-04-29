@tool
extends RefCounted
## game.* command handlers — start/stop editor playtest (Mode A).

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPCommandRegistry = _Hub.MCPCommandRegistry
const MCPFileGuard = _Hub.MCPFileGuard
const MCPRegistryClient = _Hub.MCPRegistryClient
const MCPHelpers = _Hub.MCPHelpers
const MCPAuth := preload("res://addons/godot_mcp_toolkit/auth.gd")

const RUNTIME_HOST := "127.0.0.1"
const RUNTIME_POLL_TIMEOUT_MS := 5000
const _DEFAULT_POLL_TIMEOUT_MS := 10000
const _LAUNCH_SETTLE_MS := 1500  # let the game process spawn before polling
const _REGISTRY_POLL_INTERVAL_MS := 100


static func register(registry: MCPCommandRegistry, _server: Node) -> void:
	registry.add("game.start", func(parameters: Dictionary) -> Dictionary:
		return _cmd_game_start(parameters))
	registry.add("game.stop", func(parameters: Dictionary) -> Dictionary:
		return _cmd_game_stop(parameters))


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
		return MCPError.make("INVALID_PARAMS",
			"if_running must be 'return' or 'fail' (got %s); default is 'fail'" % if_running)

	if runtime_poll:
		if not EditorInterface.is_playing_scene():
			return MCPError.make("GAME_NOT_RUNNING",
				"no game is running; call game.start first")
	else:
		if EditorInterface.is_playing_scene():
			if if_running == "return":
				var runtime_port := MCPRegistryClient.get_runtime_port()
				return {"success": true, "status": "already_running",
					"runtime_port": runtime_port if runtime_port > 0 else null}
			return MCPError.make("ALREADY_PLAYING",
				"a game is already running; call game.stop first, or use runtime_poll:true to re-probe the runtime connection")

		match target:
			"main":
				EditorInterface.play_main_scene()
			"current":
				if MCPHelpers.get_edited_root() == null:
					return MCPError.make("NO_SCENE",
						"no currently-edited scene; use target:'main' or target:<res://path>, or scene.open first")
				EditorInterface.play_current_scene()
			_:
				var guard := MCPFileGuard.resolve_safe(target)
				if guard["error"] != null:
					return MCPError.make("PATH_DENIED", str(guard["reason"]))
				if target.get_extension().to_lower() != "tscn":
					return MCPError.make("INVALID_PATH",
						"game.start only plays .tscn files (got %s)" % target)
				if not FileAccess.file_exists(target):
					return MCPError.make("NOT_FOUND",
						"no scene file at %s; use scene.create first" % target, MCPError.HINT_FILE_PATH)
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
			runtime_port = MCPRegistryClient.get_runtime_port()
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
		# Poll registry for the runtime port. The game process needs
		# time to spawn + load project + init autoloads + bind port +
		# register in registry. Give it a head start before polling.
		OS.delay_msec(_LAUNCH_SETTLE_MS)
		var deadline := Time.get_ticks_msec() + _DEFAULT_POLL_TIMEOUT_MS
		while Time.get_ticks_msec() < deadline:
			runtime_port = MCPRegistryClient.get_runtime_port()
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
			bridge_discovery = true
			runtime_failure = "registry_timeout"

	var response := {
		"success": true,
		"target": target,
		"runtime_port": runtime_port if runtime_port > 0 else null,
		"runtime_ready": runtime_ready,
	}
	if bridge_discovery:
		response["runtime_discovery"] = "bridge"
	if runtime_poll:
		response["runtime_poll"] = true
	if (wait_for_runtime or runtime_poll) and not runtime_ready and not bridge_discovery:
		response["runtime_failure"] = runtime_failure
		match runtime_failure:
			"registry_timeout":
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
				response["hint"] = "Runtime not ready (%s). Checklist: (1) Is the MCP Runtime autoload enabled? (2) Is port 6525 available? (3) Check editor_get_console for errors. (4) For Standard profile: call enable_tool_group(['runtime']) to load runtime tools." % runtime_failure
	# P-006: When no poll was requested and runtime isn't ready, warn that
	# runtime tools will block/fail. Prevents agents from calling
	# runtime_screenshot / input_simulate on a game that didn't connect.
	elif not runtime_ready and not wait_for_runtime and not runtime_poll:
		response["hint"] = (
			"runtime_ready is false — runtime tools (runtime_screenshot, input_simulate, "
			+ "game_eval, etc.) will NOT work until the runtime connects. "
			+ "Call game_start with wait_for_runtime:true to wait for connection, "
			+ "or use runtime_poll:true to re-probe. "
			+ "Check debugger_get_log or editor_get_console for startup errors."
		)
	return response


static func _cmd_game_stop(_parameters: Dictionary) -> Dictionary:
	var was_running := EditorInterface.is_playing_scene()
	EditorInterface.stop_playing_scene()
	return {"success": true, "was_running": was_running}


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
