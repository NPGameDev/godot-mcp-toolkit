@tool
extends RefCounted
## Play-Session Control (editor side): start or stop the editor playtest and
## confirm the live runtime's readiness.
##
## Owns the game.start / game.stop handlers (Mode A — start/stop a play session
## via EditorInterface.play_*/stop_playing_scene), the runtime-readiness probe
## (a WebSocket connect→auth→ping health-check over the live game's Mode-B
## server), and start-failure diagnosis (a LogBuffer scan that explains why the
## game never started). game.start marks the debug-log session as started by
## calling the log-reader's public mark_session_started() — the one-datum
## handoff to the Debug-Log Retrieval child.
## An extracted submodule of the playtest-command group, reached via a `preload` alias.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const FileGuard = Modules.FileGuard
const RegistryClient = Modules.RegistryClient
const Helpers = Modules.CommandHelpers
const MCPAuth := preload("res://addons/godot_mcp_toolkit/security/auth.gd")
const _LogReader := preload("res://addons/godot_mcp_toolkit/commands/playtest_log_reader.gd")

const RUNTIME_HOST := "127.0.0.1"
const RUNTIME_POLL_TIMEOUT_MS := 5000
const _REGISTRY_POLL_INTERVAL_MS := 100


# -- Commands -----------------------------------------------------------------


static func cmd_game_start(parameters: Dictionary) -> Dictionary:
	# A headless editor cannot launch the game process, so the runtime (Mode B) never
	# comes up — the pre-guard success:true was a false-success (nothing stays playing).
	# Fail deterministically like editor.screenshot so an LLM branches instead of polling
	# a runtime that will never connect. Display path is byte-identical below the guard.
	if Modules.VersionUtils.is_headless():
		return MCPToolkitError.fail("HEADLESS_UNSUPPORTED",
			"playtest requires a display server (the game process cannot be launched headless) — use script_check, scene/node inspection, or editor_get_console for verification.")

	var target := str(parameters.get("scene_path", "current"))
	var wait_for_runtime_raw = parameters.get("wait_for_runtime", true)
	var wait_for_runtime := bool(wait_for_runtime_raw) \
		if typeof(wait_for_runtime_raw) == TYPE_BOOL else true
	var runtime_poll_raw = parameters.get("runtime_poll", false)
	var runtime_poll := bool(runtime_poll_raw) \
		if typeof(runtime_poll_raw) == TYPE_BOOL else false
	var if_running := str(parameters.get("if_running", "fail"))

	if not (if_running in ["return", "fail"]):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"if_running must be 'return' or 'fail' (got %s); default is 'fail'" % if_running)

	if runtime_poll:
		if not EditorInterface.is_playing_scene():
			# runtime_poll never launches the game (probe-only), so reaching here means
			# nothing was running to probe. An empty buffer can't prove a compile failure,
			# so diagnose by captured evidence rather than asserting a cause.
			var comp := _scan_compilation_errors()
			var diag := _diagnose_startup(comp, false, Modules.VersionUtils.get_engine_version_pair())
			return MCPToolkitError.fail(diag["code"], diag["message"], diag["hint"])
	else:
		if EditorInterface.is_playing_scene():
			if if_running == "return":
				var runtime_port := RegistryClient.get_runtime_port()
				return MCPToolkitSuccess.ok({"status": "already_running",
					"runtime_port": runtime_port if runtime_port > 0 else null})
			return MCPToolkitError.fail("ALREADY_PLAYING",
				"a game is already running; call game.stop first, or use runtime_poll:true to re-probe the runtime connection")

		# Mark that a play session has started so the editor-side debugger.get_log
		# cache reads the game's log. The engine truncates godot.log fresh on every
		# launch, so the whole file is this session (the reader reads from byte 0).
		_LogReader.mark_session_started()

		match target:
			"main":
				# Pre-guard: play_main_scene() with no main scene defined pops an
				# undismissable "No main scene has ever been defined" modal and returns,
				# leaving the plugin to falsely report success (a later runtime_poll then
				# misreads it as COMPILATION_FAILED). Fail deterministically instead —
				# mirrors the "current" branch's NO_SCENE guard.
				if _main_scene_missing():
					return MCPToolkitError.fail("NO_SCENE",
						"no main scene set — set one in Project Settings > Application > Run > Main Scene "
						+ "(or project_set_setting application/run/main_scene='res://YourScene.tscn'), "
						+ "or use target:'current' or a res:// scene path.")
				EditorInterface.play_main_scene()
			"current":
				if Helpers.get_edited_root() == null:
					return MCPToolkitError.fail("NO_SCENE",
						"no currently-edited scene; use target:'main' or target:<res://path>, or scene.open first")
				EditorInterface.play_current_scene()
			_:
				var guard := FileGuard.resolve_safe(target)
				if guard["error"] != null:
					return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
				if target.get_extension().to_lower() != "tscn":
					return MCPToolkitError.fail("INVALID_PATH",
						"game.start only plays .tscn files (got %s)" % target)
				if not FileAccess.file_exists(target):
					return MCPToolkitError.fail("NOT_FOUND",
						"no scene file at %s; use scene.create first" % target, MCPToolkitError.HINT_FILE_PATH)
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
			await Engine.get_main_loop().create_timer(_REGISTRY_POLL_INTERVAL_MS / 1000.0).timeout
		if runtime_port > 0:
			var remaining := maxi(500, deadline - Time.get_ticks_msec())
			var probe := await _poll_runtime_ready(
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

	var response := MCPToolkitSuccess.ok({
		"target": target,
		"runtime_port": runtime_port if runtime_port > 0 else null,
		"runtime_ready": runtime_ready,
	})
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
					# The game was playing when the poll began but has stopped — a
					# ran-then-died soft path, framed as a runtime crash (it began
					# running, so a compile error is unlikely). runtime_ready:false +
					# runtime_failure:"registry_timeout" are the honest structured signals.
					var comp := _scan_compilation_errors()
					var diag := _diagnose_startup(comp, true, Modules.VersionUtils.get_engine_version_pair())
					response["hint"] = diag["hint"]
					if not (diag["errors"] as Array).is_empty():
						response["compilation_errors"] = diag["errors"]
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
				response["hint"] = "Runtime not ready (%s). Checklist: (1) Is the MCP Runtime autoload enabled? (2) Is the runtime port (default 6570) available? (3) Check editor_get_console for errors. (4) If runtime tools aren't loaded yet, call discover_tools({request: 'runtime'})." % runtime_failure
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


## True when no main scene is configured (application/run/main_scene unset or blank).
## Read FRESH from ProjectSettings — not a cached value — so a just-written setting is
## honored. Backs the game.start "main" pre-guard: fail deterministically rather than
## let play_main_scene() pop the engine's undismissable "No main scene has ever been
## defined" modal (which returns silently → a false success). Pure query; unit-tested.
static func _main_scene_missing() -> bool:
	return str(ProjectSettings.get_setting("application/run/main_scene", "")).strip_edges().is_empty()


static func cmd_game_stop(_parameters: Dictionary) -> Dictionary:
	var was_running := EditorInterface.is_playing_scene()
	EditorInterface.stop_playing_scene()
	return MCPToolkitSuccess.ok({"was_running": was_running})


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
			await Engine.get_main_loop().create_timer(0.1).timeout
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
				await Engine.get_main_loop().create_timer(0.01).timeout
				continue

			if furthest == "ws_connect_timeout":
				furthest = "auth_timeout"

			if not auth_sent:
				ws.send_text(JSON.stringify({"auth": token}))
				auth_sent = true
				await Engine.get_main_loop().create_timer(0.01).timeout
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

			await Engine.get_main_loop().create_timer(0.01).timeout

		ws.close()
		await Engine.get_main_loop().create_timer(0.1).timeout
	return {"ready": false, "failure": furthest}


## Scan LogBuffer for recent errors — used to detect compilation failures
## when the game fails to start.
static func _scan_compilation_errors() -> Dictionary:
	var buf := Modules.LogBuffer.get_entries(10, ["error"])
	var errors: Array = []
	for entry in buf.get("entries", []):
		errors.append(str(entry.get("message", "")))
	return {
		"found": errors.size() > 0,
		"errors": errors,
		"source": "logger" if Modules.LogBuffer.uses_logger_api() else "file_tail",
	}


## Phase-aware diagnosis of why a runtime probe found no live game, given the
## log-scan result and whether the game was observed running.
##
## Pure over its inputs so the whole decision is headless-unit-testable. Takes the
## [param comp] scan dict from [method _scan_compilation_errors]
## ([code]{"found", "errors", "source"}[/code]), [param was_running] (true when the
## game was seen playing this call — the soft "ran-then-died" path, false when
## nothing was ever confirmed running — the hard "never-started" path), and the
## running-engine [param version_pair] (e.g. [code]"4.5"[/code]) for the file-tail
## caveat. Returns [code]{"code", "message", "hint", "errors"}[/code].[br]
## [br]
## The framing only claims a compile failure when errors are actually in hand
## ([code]found[/code]) AND the game never ran: an empty buffer proves nothing about
## compilation (a cold-start parse error may not have landed, and 4.2–4.4 file-tail
## mode can miss parse errors entirely), so an empty buffer states the
## [code]GAME_NOT_RUNNING[/code] fact and offers both hypotheses rather than asserting
## a cause. A game that ran then stopped is framed as a runtime crash, not a compile
## error (it began running).
static func _diagnose_startup(
	comp: Dictionary, was_running: bool, version_pair: String,
) -> Dictionary:
	# comp[...] is Variant at the JSON-shaped scan boundary → coerce, never infer.
	var found := bool(comp.get("found", false))
	var errors: Array = comp.get("errors", [])
	var is_file_tail := str(comp.get("source", "")) == "file_tail"
	# The file-tail signal is version-gated (4.2–4.4); name the version only there so
	# the agent knows the empty buffer may be a capture limit, not a clean startup.
	var file_tail_caveat := (
		" (Godot %s tails the log file and can miss compile errors.)" % version_pair
		if is_file_tail else ""
	)

	if found:
		var joined := "\n".join(errors)
		if was_running:
			return {
				"code": "GAME_NOT_RUNNING",
				"message": "Game stopped mid-probe with errors captured — likely a runtime crash:\n" + joined,
				"hint": "The game began running, so a compile error is unlikely. Check debugger_get_log or editor_get_console for the crash." + file_tail_caveat,
				"errors": errors,
			}
		return {
			"code": "COMPILATION_FAILED",
			"message": "Game failed to start — likely a startup or parse error. Recent errors:\n" + joined,
			"hint": "Fix the errors shown, then call game_start again." + file_tail_caveat,
			"errors": errors,
		}

	if was_running:
		return {
			"code": "GAME_NOT_RUNNING",
			"message": "Game started then stopped before the probe completed.",
			"hint": "Likely a runtime crash or early exit (it began running, so a compile error is unlikely). Check debugger_get_log or editor_get_console." + file_tail_caveat,
			"errors": errors,
		}
	return {
		"code": "GAME_NOT_RUNNING",
		"message": "No running game to probe.",
		"hint": (
			"Either (a) nothing launched yet / still cold-starting — call game_start (without runtime_poll), "
			+ "or retry runtime_poll:true shortly; or (b) it failed to compile. To surface a compile error not "
			+ "in the buffer, editor_refresh then editor_get_console." + file_tail_caveat
		),
		"errors": errors,
	}
