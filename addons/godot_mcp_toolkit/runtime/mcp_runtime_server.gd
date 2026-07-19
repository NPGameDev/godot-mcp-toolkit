@tool
extends Node
## Mode B — runtime-only WebSocket server that lets the MCP bridge reach
## into the LIVE game (not the edited scene). Registered as the
## `MCPRuntimeServer` autoload by plugin.gd.
##
## The same script file is loaded at edit time (because it's in an
## @tool-enabled plugin) AND at runtime (because it's an autoload). We
## self-destruct in two cases:
##   1. Engine.is_editor_hint() — editor process loaded us, not the game.
##      Keeping a second WS listener on 6570 while editing is a bug.
##   2. not OS.has_feature("editor") — any export template (debug AND
##      release). "editor" is true only under an editor launch (F5/F6) and
##      false in every export, so Mode B self-protects in ALL exports
##      regardless of export_strip nulling the autoload. Security-critical;
##      stronger than is_debug_build() (which is true in a debug export).

# Runtime dependency closure — direct preloads of export-clean scripts only.
# Deliberately NOT core/modules.gd: it statically names EditorInterface/EditorPlugin, which
# would parse-fail this autoload in an export template (godot#91713) — GDScript
# resolves identifiers at parse time, before any runtime guard can help.
const Coerce := preload("res://addons/godot_mcp_toolkit/contract/coerce.gd")
const ExecuteHints := preload("res://addons/godot_mcp_toolkit/contract/execute_hints.gd")
const Pagination := preload("res://addons/godot_mcp_toolkit/contract/pagination.gd")
const PropertySetCheck := preload("res://addons/godot_mcp_toolkit/contract/property_set_check.gd")
const ScreenshotResponse := preload("res://addons/godot_mcp_toolkit/contract/screenshot_response.gd")
const Untrusted := preload("res://addons/godot_mcp_toolkit/security/untrusted.gd")
const MCPAuth := preload("res://addons/godot_mcp_toolkit/security/auth.gd")
const Scrubber := preload("res://addons/godot_mcp_toolkit/security/scrubber.gd")
const LogHelpers := preload("res://addons/godot_mcp_toolkit/logging/log_helpers.gd")
const RegistryClient := preload("res://addons/godot_mcp_toolkit/registry/registry_client.gd")
const LogBuffer := preload("res://addons/godot_mcp_toolkit/logging/log_buffer.gd")
const Notifier := preload("res://addons/godot_mcp_toolkit/transport/notifier.gd")
const WsTransport := preload("res://addons/godot_mcp_toolkit/transport/ws_transport.gd")
const SignalPairResolver := preload("res://addons/godot_mcp_toolkit/scene/signal_pair_resolver.gd")
const TextInputSynth := preload("res://addons/godot_mcp_toolkit/runtime/text_input_synth.gd")
# Export-clean (core APIs only) — safe in this runtime autoload's preload closure.
const PortConfig := preload("res://addons/godot_mcp_toolkit/transport/port_config.gd")

# Default runtime (Mode B) scan band (inclusive). GODOT_MCP_RUNTIME_PORT pins an
# exact port (bind-exact-or-fail); GODOT_MCP_RUNTIME_PORT_MIN/_MAX relocate the
# band. Resolved by PortConfig; the two modes are mutually exclusive.
const PORT_MIN := 6570
const PORT_MAX := 6585  # 6570..6585 inclusive
const _ENV_PIN := "GODOT_MCP_RUNTIME_PORT"
const _ENV_PORT_MIN := "GODOT_MCP_RUNTIME_PORT_MIN"
const _ENV_PORT_MAX := "GODOT_MCP_RUNTIME_PORT_MAX"
const BIND := "127.0.0.1"
const JSONRPC_VERSION := "2.0"
# Throttle re-listen retries. Mirrors mcp_server.gd's editor-side loop.
# Runtime restarts on F5 each game session, so the typical "missed bind"
# recoverable case is a stale debug session that hasn't released 6570
# yet — usually clears in 1-2 frames.
const _RELISTEN_FRAME_INTERVAL := 60
const _AUTH_TIMEOUT_MS := 2000
# debugger.get_log default entry count when the caller passes no limit.
const _DEFAULT_LOG_LIMIT := 200
# execute.code console-echo cap — long snippets are truncated in the game log.
const _EXECUTE_CODE_LOG_CAP := 256
# Bound the wait for a fresh frame before falling back to the last-drawn one, in
# seconds. Non-critical and well under the server's 30 s call timeout — a
# redraw-on-demand game that is idle (not minimized) simply never fires
# frame_post_draw, so the wait must lapse rather than hang.
const _RUNTIME_FRAME_WAIT_SECONDS := 1.0

# Owns the TCP listener + WS peers + auth-handshake framing + the bound port +
# the session token. The runtime injects only the message router (its command
# match) and the bind-publish callback; auth-ack defaults to {authed:true} and
# there are no per-authed/per-closed side-effects (a running game has none).
# Drives it inline per _process (no call_deferred — a running game has no
# EditorFileSystem reentrancy to dodge).
var _transport: WsTransport = null


func _init() -> void:
	# Keep the Mode-B poll loop alive while the game tree is paused (a pause
	# menu, or a gameplay-pausing quit-confirm dialog). The default
	# PROCESS_MODE_PAUSABLE would halt _process -> pump() the moment the game
	# sets get_tree().paused = true, freezing every runtime tool until the game
	# unpaused. Pure Node API -- no editor dependency.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	# Do not run in the editor process.
	#
	# Stay in the SceneTree as an inert placeholder rather than freeing:
	# the autoload tracker holds a pointer to this Node until
	# `remove_autoload_singleton()` fires (on plugin disable). If we
	# queue_free ourselves here, that pointer becomes dangling and plugin
	# disable triggers `root.remove_child(null)` in Godot's internals.
	# `set_process(false)` + no TCPServer means zero work per frame and
	# no port bind — the Node's presence is purely bookkeeping.
	if Engine.is_editor_hint():
		set_process(false)
		return
	# --check-only is a parse-only pass — no runtime server needed.
	if "--check-only" in OS.get_cmdline_args():
		set_process(false)
		return
	# Export gate: shipped games (debug OR release export templates) must not
	# listen on 6570. has_feature("editor") is true only under an editor launch
	# (F5/F6) and false in EVERY export template — stronger than is_debug_build()
	# (true in a debug export), so the runtime server self-protects in all exports
	# independent of export_strip nulling the autoload. Same quiescent approach —
	# an empty Node at scene-tree root is cheaper than the subtle edge cases of
	# auto-freeing during SceneTree setup.
	if not OS.has_feature("editor"):
		set_process(false)
		return
	_start_server()


func _exit_tree() -> void:
	_stop_server()


func _start_server() -> void:
	LogBuffer.setup()
	var config := PortConfig.resolve(_ENV_PIN, _ENV_PORT_MIN, _ENV_PORT_MAX, PORT_MIN, PORT_MAX)
	_log_port_config(config)
	if not str(config.get("error", "")).is_empty():
		# Fatal config error — Mode B tools disabled this session (logged above).
		# No transport is built, so stop the per-frame pump too: without this,
		# _process would deref the null transport every frame.
		set_process(false)
		return
	_transport = WsTransport.new()
	var pinned: bool = config["mode"] == PortConfig.MODE_PINNED
	var base: int = int(config["port"]) if pinned else int(config["port_min"])
	var count: int = 1 if pinned else int(config["port_max"]) - int(config["port_min"]) + 1
	# await_messages = false: the runtime fire-and-forgets each frame so a coroutine
	# handler (runtime.screenshot) runs independently of the poll loop, as before.
	# A pinned-but-occupied port is a loud push_error in the game console (captured by
	# the console tools) — the child game process can't reach the editor dock, so the
	# transport's push_warning/push_error is the runtime-side surface.
	_transport.configure("[MCPRuntimeServer]", base, count, BIND,
		_RELISTEN_FRAME_INTERVAL, _AUTH_TIMEOUT_MS, false,
		"no free port in %d-%d; Mode B tools disabled this session", pinned,
		"Free the port, or change %s (or unset it to use the scanned band). Mode B tools are disabled this session." % _ENV_PIN)
	# Runtime seams: only the message router (its command match) and the
	# bind-publish callback (set_runtime). No auth-ack override ({authed:true}
	# default), no per-authed/per-closed side-effects, and no pin-conflict handler
	# (the transport's own push_error is the loud runtime surface — no dock to reach).
	_transport.set_handlers(_handle_message, Callable(), Callable(), Callable(),
		_on_bound)
	# Runtime uses the same token file as the editor server so the bridge can
	# authenticate against both with one read. The editor server writes first
	# (plugin enable runs before game launch). If the file doesn't exist yet
	# (edge case: game launched standalone without plugin), generate our own
	# token.
	var token := ""
	var token_path := MCPAuth.get_token_path()
	var file := FileAccess.open(token_path, FileAccess.READ)
	if file != null:
		token = file.get_as_text().strip_edges()
		file.close()
	if token.is_empty():
		token = MCPAuth.generate_token()
		MCPAuth.write_token(token)
	_transport.set_token(token)
	_transport.ensure_listening()


# Log the resolved Mode-B listen-port config at startup (so the game console
# tells WHY this port was chosen): the port + source, a one-line note when a pin
# makes the band moot, or a loud push_error on a config error — never a silent default.
func _log_port_config(config: Dictionary) -> void:
	var config_error := str(config.get("error", ""))
	if not config_error.is_empty():
		push_error("[MCPRuntimeServer] Invalid port config: %s - Mode B tools disabled this session." % config_error)
		return
	if bool(config.get("band_ignored", false)):
		print("[MCPRuntimeServer] note: %s pins an exact port, so the %s/%s band is ignored." % [
			_ENV_PIN, _ENV_PORT_MIN, _ENV_PORT_MAX])
	match str(config.get("source", "")):
		"env-pin":
			print("[MCPRuntimeServer] port %d (pinned via %s)" % [int(config["port"]), _ENV_PIN])
		"env-band":
			print("[MCPRuntimeServer] port: scanning %d-%d (band via %s/%s)" % [
				int(config["port_min"]), int(config["port_max"]), _ENV_PORT_MIN, _ENV_PORT_MAX])
		_:
			print("[MCPRuntimeServer] port: scanning %d-%d (default)" % [
				int(config["port_min"]), int(config["port_max"])])


func _stop_server() -> void:
	set_process(false)
	if _transport != null:
		_transport.close_all(1000, "")
		_transport.shutdown_listener()
	# Best-effort registry cleanup (game may be force-killed).
	RegistryClient.clear_runtime()


# Fired by the transport on a fresh bind (initial or late, both modes): publish
# the port so the bridge can discover Mode B. The editor mirrors this — its
# fresh-bind seam re-publishes the registry entry via the composition root.
func _on_bound(port: int) -> void:
	RegistryClient.set_runtime(port)


func _process(_delta: float) -> void:
	# A config-error start leaves no transport (set_process(false) already stops
	# this loop); the guard keeps a stray tick a no-op instead of a null deref —
	# the twin of the editor's null guard in _poll_connections.
	if _transport == null:
		return
	LogBuffer.poll()
	# Keep the listener up across transient socket loss. Editor / release
	# gating from _ready prevents _process from running where it shouldn't
	# (set_process(false)), so reaching here = debug-build runtime. Inline pump
	# (no call_deferred — a running game has no EditorFileSystem reentrancy).
	_transport.pump()


func _handle_message(peer: WebSocketPeer, text: String) -> void:
	var parser := JSON.new()
	var parse_err := parser.parse(text)
	if parse_err != OK:
		_send_error(peer, null, -32700, "Parse error: %s" % parser.get_error_message())
		return

	var msg = parser.data
	if typeof(msg) != TYPE_DICTIONARY:
		_send_error(peer, null, -32600, "Invalid Request: top-level must be an object")
		return

	# Auth handshake — the transport validates, marks authed, and sends the
	# default {authed:true} ack (the runtime supplies no ack override).
	if not _transport.is_authed(peer):
		_transport.validate_auth(peer, msg)
		return

	var id = msg.get("id", null)
	if typeof(id) == TYPE_FLOAT and int(id) == id:
		id = int(id)
	var method := str(msg.get("method", ""))
	var params = msg.get("params", null)

	if method.is_empty():
		_send_error(peer, id, -32600, "Invalid Request: missing method")
		return

	match method:
		"echo":
			_send_result(peer, id, params)
		"ping":
			_send_result(peer, id, {"success": true})
		"runtime.screenshot":
			_cmd_runtime_screenshot(peer, id, params)
		"runtime.get_node_state":
			_cmd_runtime_get_node_state(peer, id, params)
		"runtime.set_property":
			_cmd_runtime_set_property(peer, id, params)
		"debugger.get_log":
			_cmd_debugger_get_log(peer, id, params)
		"signal.list":
			_cmd_signal_list(peer, id, params)
		"signal.connect":
			_cmd_signal_connect(peer, id, params)
		"signal.disconnect":
			_cmd_signal_disconnect(peer, id, params)
		"signal.emit":
			_cmd_signal_emit(peer, id, params)
		"input.simulate":
			_cmd_input_simulate(peer, id, params)
		"animation_player.control":
			_cmd_animation_player_control(peer, id, params)
		"runtime.get_script_vars":
			_cmd_runtime_get_script_vars(peer, id, params)
		"execute.code":
			_cmd_execute_code(peer, id, params)
		_:
			_send_error(peer, id, -32601, "Method not found: %s" % method)


func _send_result(peer: WebSocketPeer, id, result) -> void:
	Notifier.send_result(peer, id, result, "[MCPRuntimeServer]")


func _send_error(peer: WebSocketPeer, id, code: int, message: String) -> void:
	Notifier.send_error(peer, id, code, message)



# ---- Runtime command helpers ------------------------------------------------


func _cmd_runtime_screenshot(peer: WebSocketPeer, id, params) -> void:
	var viewport := get_viewport()
	if viewport == null:
		_send_result(peer, id, MCPToolkitError.fail("INTERNAL", "no viewport available"))
		return

	var params_dict: Dictionary = params if typeof(params) == TYPE_DICTIONARY else {}

	# Reject a bad image_detail up front so a typo can't slip through as full-res (the
	# pure dims calculator treats an unknown value as native, so the guard is here).
	var detail := ScreenshotResponse.detail_of(params_dict)
	if detail.is_empty():
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS",
			"image_detail must be one of [full, mid, low] (got %s)"
			% str(params_dict.get("image_detail", ""))))
		return

	var force_foreground := bool(params_dict.get("force_foreground_game", false))

	var remediation: Array[String] = []
	var foreground_hint := ""

	# Honor force_foreground_game on request, regardless of the minimized read: an
	# embedded game (the editor's Game view) is an owner-linked top-level window
	# hard-gated to WINDOWED, never reported minimized even when the editor is, so
	# gating the lever on _window_is_minimized() would silently skip it.
	if force_foreground:
		foreground_hint = _foreground_game_if_requested(remediation)

	# Try to capture rather than short-circuit on window state: a window that still
	# composites (an embedded game, or a floating game merely unfocused) yields a
	# fresh frame. Bound the wait so a suspended window — or an idle redraw-on-demand
	# game that never fires frame_post_draw — does not park until the server's call
	# timeout.
	var frame_arrived := await _await_frame_or_timeout()

	# The wait lapsed AND the window cannot draw: rendering is genuinely suspended
	# (a floating/top-level game minimized, or fully occluded on macOS), so no frame
	# can be produced — return the diagnostic signal instead of a stale last-drawn
	# frame. A lapse while the window CAN draw means an idle redraw-on-demand game,
	# where the last-drawn frame IS the current state — fall through and return it.
	if _should_signal_minimized(frame_arrived, not DisplayServer.window_can_draw(0)):
		_send_result(peer, id, MCPToolkitError.fail("RUNTIME_WINDOW_MINIMIZED",
			"the running game window can't render — it is minimized or fully occluded, so rendering is suspended",
			"The running game window can't render (minimized or fully occluded), so no frame is produced — not a crash or timeout. Retry with force_foreground_game:true to raise and capture the game window, or restore/reveal it yourself."))
		return

	var image := viewport.get_texture().get_image()
	if image == null:
		_send_result(peer, id, MCPToolkitError.fail("INTERNAL", "viewport texture unavailable"))
		return

	# Full-res encode always — this is what a disk copy persists, unaffected by
	# image_detail (the cap is inline-only).
	var png_bytes := image.save_png_to_buffer()
	if png_bytes.is_empty():
		_send_result(peer, id, MCPToolkitError.fail("INTERNAL", "save_png_to_buffer returned empty"))
		return

	var inline := _downscale_inline_png(image, params_dict, detail)

	# Runtime save-path allowlist is user://screenshots/ only — a shipped game has no
	# res:// write access, and the editor server owns the res:// destination. The
	# send-path size guard sees the final (inline) buffer, so no byte check here.
	var response := ScreenshotResponse.build(
		params_dict, png_bytes, image.get_width(), image.get_height(),
		["user://screenshots/"],
		inline["png_bytes"], int(inline["width"]), int(inline["height"]))
	if response.get("success") == false:
		_send_result(peer, id, response)
		return
	if not remediation.is_empty():
		response["remediation"] = remediation
	# An embedded game can't be foregrounded (owner-linked, editor-controlled), so a
	# force_foreground_game request there took no effect — disclose why the window
	# didn't move rather than leaving the caller with a silent no-op. Append rather
	# than clobber a disk full-res hint the shaper may already have set.
	if not foreground_hint.is_empty():
		if response.has("hint"):
			response["hint"] = "%s %s" % [response["hint"], foreground_hint]
		else:
			response["hint"] = foreground_hint
	_send_result(peer, id, response)


# Encode the downscaled inline PNG for an image_detail cap, but only when an inline
# image is actually returned (inline/both mode) and the level shrinks the frame —
# disk-only returns the full-res file, so it needs no inline buffer. Returns
# {png_bytes, width, height}; png_bytes is empty (and dims -1) when no downscale
# applies, which ScreenshotResponse.build reads as "use the full-res buffer inline".
func _downscale_inline_png(image: Image, params_dict: Dictionary, detail: String) -> Dictionary:
	var empty := {"png_bytes": PackedByteArray(), "width": -1, "height": -1}
	if ScreenshotResponse.mode_of(params_dict) == "disk":
		return empty
	var target := ScreenshotResponse.image_detail_dims(image.get_width(), image.get_height(), detail)
	if target.x == image.get_width() and target.y == image.get_height():
		return empty
	# duplicate() is typed Ref<Resource>; the explicit Image local coerces (loud on a
	# mismatch, unlike `as`). Resize the copy so the full-res buffer stays intact for disk.
	var inline_image: Image = image.duplicate()
	inline_image.resize(target.x, target.y, Image.INTERPOLATE_LANCZOS)
	return {
		"png_bytes": inline_image.save_png_to_buffer(),
		"width": inline_image.get_width(),
		"height": inline_image.get_height(),
	}


# Raise the game window at the caller's explicit request. An embedded game (the
# editor's Game view) is owner-linked and editor-controlled: the engine hard-gates
# it to WINDOWED and re-asserts its z-order every frame, so window_set_mode /
# window_move_to_foreground are inert there — the lever can't work, so DON'T claim
# it. A top-level game DOES respond: un-minimize (only when actually minimized, so
# a windowed game isn't needlessly re-set) + move-to-foreground + focus is a real,
# visible side effect — claim "foregrounded_game" for both an un-minimize AND a
# raise-from-background. Returns a hint (empty when none) explaining an embedded
# no-op so the caller isn't left with a silent non-effect.
func _foreground_game_if_requested(remediation: Array[String]) -> String:
	if _is_embedded_in_editor():
		return ("The game runs embedded in the editor's Game view and can't be independently "
			+ "foregrounded — it is already composited in the Game dock. Raise or restore the "
			+ "editor window to view it.")
	if _window_is_minimized():
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED, 0)
	_ensure_game_focus()
	remediation.append("foregrounded_game")
	return ""


# True when the game was launched embedded in the editor's Game view. The API is
# 4.4+ (the release the embed feature landed); on the 4.2/4.3 floor the method is
# absent and embedding is impossible, so its absence correctly reads as top-level.
func _is_embedded_in_editor() -> bool:
	return Engine.has_method("is_embedded_in_editor") and bool(Engine.call("is_embedded_in_editor"))


# Decide whether to return the render-suspended signal after the bounded frame-wait.
# Signals ONLY when a fresh frame could not be produced AND the window cannot draw —
# the genuine suspended case (a top-level game minimized, or fully occluded on
# macOS, where the compositor stops presenting). A frame that arrived, or a lapse
# while the window can still draw (idle redraw-on-demand, last frame is current),
# both proceed to capture instead. Pure decision, extracted so it is unit-testable
# without a live game window.
static func _should_signal_minimized(frame_arrived: bool, window_suspended: bool) -> bool:
	return not frame_arrived and window_suspended


# True when the game's main window is minimized (render suspended).
func _window_is_minimized() -> bool:
	return DisplayServer.window_get_mode(0) == DisplayServer.WINDOW_MODE_MINIMIZED


# Await the next frame_post_draw, but give up after _RUNTIME_FRAME_WAIT_SECONDS so
# an idle redraw-on-demand window (which never fires it) does not hang the
# handler. Returns true as soon as a frame draws, false if the deadline lapses
# first — the caller uses that to tell a fresh capture from a suspended window.
# Polls the frame flag each process frame, which itself ticks even on an idle
# window, so the deadline is always reachable.
func _await_frame_or_timeout() -> bool:
	var got_frame := [false]
	var on_frame := func() -> void:
		got_frame[0] = true
	RenderingServer.frame_post_draw.connect(on_frame, CONNECT_ONE_SHOT)
	var deadline := Time.get_ticks_msec() + int(_RUNTIME_FRAME_WAIT_SECONDS * 1000.0)
	while not got_frame[0] and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not got_frame[0] and RenderingServer.frame_post_draw.is_connected(on_frame):
		RenderingServer.frame_post_draw.disconnect(on_frame)
	return got_frame[0]


func _cmd_runtime_get_node_state(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("node_path", ""))
	if path.is_empty():
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", "missing node_path"))
		return

	var tree := get_tree()
	if tree == null or tree.root == null:
		_send_result(peer, id, MCPToolkitError.fail("INTERNAL", "scene tree unavailable"))
		return

	var node := tree.root.get_node_or_null(path)
	if node == null:
		var hint := _build_not_found_hint(tree.root, path)
		_send_result(peer, id, MCPToolkitError.fail("NOT_FOUND", "node not found: %s%s" % [path, hint]))
		return

	var props := {}
	for prop in node.get_property_list():
		var usage: int = int(prop.get("usage", 0))
		# Only inspector-visible properties — avoids engine-internal state
		# and category headers.
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		var pname := str(prop.get("name", ""))
		if pname.is_empty() or pname.begins_with("_"):
			continue
		props[pname] = Coerce.serialize_value(node.get(pname))

	_send_result(peer, id, {
		"name": String(node.name),
		"class": node.get_class(),
		"path": path,
		"properties": props,
	})


func _cmd_runtime_get_script_vars(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("node_path", ""))
	if path.is_empty():
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", "missing node_path"))
		return

	var tree := get_tree()
	if tree == null or tree.root == null:
		_send_result(peer, id, MCPToolkitError.fail("INTERNAL", "scene tree unavailable"))
		return

	var node := tree.root.get_node_or_null(path)
	if node == null:
		var hint := _build_not_found_hint(tree.root, path)
		_send_result(peer, id, MCPToolkitError.fail("NOT_FOUND", "node not found: %s%s" % [path, hint]))
		return

	var script = node.get_script()
	if script == null:
		_send_result(peer, id, {
			"name": String(node.name),
			"class": node.get_class(),
			"script_path": "",
			"path": path,
			"variables": [],
			"count": 0,
		})
		return

	var visibility_filter := str(params.get("visibility", "all"))
	if not (visibility_filter in ["public", "private", "all"]):
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS",
			"visibility must be 'public', 'private', or 'all' (got '%s')" % visibility_filter))
		return

	var variables: Array = []
	for prop in node.get_property_list():
		var usage: int = int(prop.get("usage", 0))
		if not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var pname := str(prop.get("name", ""))
		if pname.is_empty():
			continue
		var vis := "private" if pname.begins_with("_") else "public"
		if visibility_filter != "all" and vis != visibility_filter:
			continue
		variables.append({
			"name": pname,
			"value": Coerce.serialize_value(node.get(pname)),
			"visibility": vis,
		})
	_send_result(peer, id, {
		"name": String(node.name),
		"class": node.get_class(),
		"script_path": script.resource_path,
		"path": path,
		"variables": variables,
		"count": variables.size(),
	})


## Walk path segments and report where resolution failed + list siblings.
func _build_not_found_hint(root: Node, path: String) -> String:
	var segments := path.split("/")
	var current := root
	# Skip leading empty segment from absolute paths (e.g. "/root/World" → ["", "root", "World"])
	var start := 1 if segments.size() > 0 and segments[0] == "" else 0
	# For absolute paths, the first real segment is "root" — skip it since we start at tree.root
	if start < segments.size() and segments[start] == "root":
		start += 1
	for i in range(start, segments.size()):
		var seg: String = segments[i]
		var child := current.get_node_or_null(seg)
		if child == null:
			var siblings: Array = []
			for c in current.get_children():
				siblings.append(str(c.name))
			if siblings.is_empty():
				return ". '%s' has no children." % str(current.get_path())
			return ". '%s' has children: %s" % [str(current.get_path()), str(siblings)]
		current = child
	return ""


func _cmd_runtime_set_property(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", "params must be an object"))
		return
	var node_path: String = str(params.get("node_path", ""))
	var property: String = str(params.get("property", ""))
	var value = params.get("value")

	if node_path.is_empty() or property.is_empty():
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS",
			"node_path and property are required"))
		return

	var tree := get_tree()
	if tree == null or tree.root == null:
		_send_result(peer, id, MCPToolkitError.fail("INTERNAL", "scene tree unavailable"))
		return

	var node := tree.root.get_node_or_null(node_path)
	if node == null:
		# Walk path segments and list siblings at the failing level.
		var hint := _build_not_found_hint(tree.root, node_path)
		_send_result(peer, id, MCPToolkitError.fail("NOT_FOUND",
			"node not found: %s%s" % [node_path, hint]))
		return

	# Verify property exists — for compound paths like "position:x", check
	# the base property name against the node's property list.
	var current = node.get(property)
	if current == null:
		var base_prop := property.split(":")[0] if ":" in property else property
		var found := false
		for p in node.get_property_list():
			if str(p.get("name", "")) == base_prop:
				found = true
				break
		if not found:
			_send_result(peer, id, MCPToolkitError.fail("NOT_FOUND",
				"property '%s' not found on %s" % [property, node_path]))
			return

	var coerced = Coerce.coerce_value(value)
	if typeof(coerced) == TYPE_DICTIONARY and (coerced as Dictionary).has("_coerce_error"):
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", str(coerced["_coerce_error"])))
		return
	# Auto-coerce string → NodePath when the property expects NodePath.
	if typeof(current) == TYPE_NODE_PATH and typeof(coerced) == TYPE_STRING:
		coerced = NodePath(str(coerced))

	node.set(property, coerced)

	# Read back to confirm
	var new_value = node.get(property)
	# Classify the write on scalar (non-colon) paths: DROPPED (silent wrong-type,
	# Godot's set() discards an unassignable Variant) → SET_FAILED; ADJUSTED (engine
	# reshaped the value, e.g. truncation 7.9→7) → success with a warning appended
	# below. A colon sub-path (e.g. "position:x") isn't read back through node.get()
	# (before/after both null), so it stays best-effort — mirrors the editor split.
	var adjusted_warning := ""
	if ":" not in property:
		var outcome := PropertySetCheck.describe_set_drop(current, new_value, coerced, property)
		if outcome.get("status", "") == "dropped":
			# A bound setter (position/modulate) may have Variant-converted the wrong
			# type to a ZERO and stored it; restore the prior value so SET_FAILED is
			# non-destructive on the live node.
			node.set(property, current)
			_send_result(peer, id, MCPToolkitError.fail("SET_FAILED", str(outcome.get("error", ""))))
			return
		if outcome.get("status", "") == "adjusted":
			adjusted_warning = str(outcome.get("warning", ""))
	var result := {
		"node_path": node_path,
		"property": property,
		"old_value": Coerce.serialize_value(current),
		"new_value": Coerce.serialize_value(new_value),
	}

	# Autoload hint: direct children of /root are autoloads — they persist
	# across scene transitions. Warn that changes carry forward unless the
	# game's own reset logic explicitly restores the property.
	if node.get_parent() == tree.root:
		result["warning"] = (
			"'%s' is an autoload — it persists across scene transitions. " % node.name +
			"This change will carry forward through restarts/level changes " +
			"unless the game explicitly resets '%s'." % property)

	# Accepted-but-adjusted note (engine reshaped the value). Combine with the
	# autoload warning if both apply so neither caveat is lost.
	if adjusted_warning != "":
		if result.has("warning"):
			result["warning"] = str(result["warning"]) + " " + adjusted_warning
		else:
			result["warning"] = adjusted_warning

	_send_result(peer, id, result)


func _cmd_debugger_get_log(peer: WebSocketPeer, id, params) -> void:
	var limit := _DEFAULT_LOG_LIMIT
	if typeof(params) == TYPE_DICTIONARY and params.has("limit"):
		limit = max(1, int(params.get("limit", _DEFAULT_LOG_LIMIT)))
	var source: String = "buffer"
	if typeof(params) == TYPE_DICTIONARY and params.has("source"):
		source = str(params.get("source", "buffer"))
	if not (source in ["buffer", "file"]):
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS",
			"source must be 'buffer' or 'file' (got %s)" % source))
		return

	var text_filter: String = ""
	var text_regex: RegEx = null
	if typeof(params) == TYPE_DICTIONARY and params.has("text_filter"):
		text_filter = str(params.get("text_filter", ""))
	if text_filter != "" and typeof(params) == TYPE_DICTIONARY:
		var is_regex: bool = bool(params.get("is_regex", false))
		if is_regex:
			text_regex = RegEx.new()
			if text_regex.compile("(?i)" + text_filter) != OK:
				_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS",
					"text_filter is not a valid regex (is_regex=true). "
					+ "To search for literal text, omit is_regex or set it to false. "
					+ "For regex, check for unbalanced groups () [] or unescaped metacharacters."))
				return

	var regex_warning := _detect_double_escaped_regex(text_filter) if text_regex != null else ""

	if source == "buffer":
		var buf_result: Dictionary = LogBuffer.get_entries(limit, [], -1, text_filter, text_regex)
		var entries: Array = buf_result["entries"]
		for entry in entries:
			var scrubbed := Scrubber.scrub(str(entry["message"]), "debugger.get_log")
			entry["message"] = scrubbed["text"]
		var has_more: bool = buf_result["has_more"]
		# Capped-tail pagination (oldest lines drop first, no cursor): on more, guide the caller to raise limit / narrow text_filter.
		var hint := ""
		if has_more:
			hint = "more lines remain — raise limit or narrow with text_filter (capped tail: the oldest lines drop first, no cursor)."
		var response := Pagination.build(
			{"lines": Untrusted.wrap("game_log", "buffer", JSON.stringify(entries))},
			"lines", int(buf_result["total_lines"]), int(buf_result["returned"]), has_more,
			"", 0, hint, {"next_id": buf_result["next_id"], "source": "buffer"})
		# On 4.2-4.4, buffer uses file tailing — warn if empty and file logging is off.
		if entries.is_empty() and not LogBuffer.uses_logger_api():
			if not LogHelpers.is_file_logging_enabled():
				response["warning"] = "On Godot 4.2-4.4 the log buffer captures output by tailing the log file. Enable debug/file_logging/enable_file_logging in ProjectSettings and restart the editor for output capture to work. Logs from before enabling will not be available."
		if not regex_warning.is_empty():
			response["warning"] = regex_warning
		_send_result(peer, id, response)
		return

	# source == "file" — original log-file reader.
	# Raw (un-globalized) configured path: honors a relocated
	# debug/file_logging/log_path while keeping the response's path metadata
	# byte-identical in the default case (FileAccess accepts a user:// path).
	var log_path := LogHelpers.configured_log_path()
	if not FileAccess.file_exists(log_path):
		var file_logging_enabled: bool = LogHelpers.is_file_logging_enabled()
		if not file_logging_enabled:
			var _hint := "file logging is disabled — enable it in ProjectSettings → Debug → File Logging → Enable File Logging, then restart"
			if LogBuffer.uses_logger_api():
				_hint += "; alternatively use source=\"buffer\" (default) which captures all output in real-time"
			else:
				_hint += ". On Godot 4.2-4.4 source=\"buffer\" also depends on file logging, so both sources require this setting"
			_send_result(peer, id, MCPToolkitError.fail("LOG_UNAVAILABLE", _hint,
				MCPToolkitError.log_unavailable_hint(LogBuffer.uses_logger_api())))
		else:
			_send_result(peer, id, Pagination.build(
				{"lines": []}, "lines", 0, 0, false, "", 0, "",
				{
					"path": log_path,
					"source": "file",
					"note": "log file not yet written — new game with no prints, or file flush pending",
				}))
		return

	var file := FileAccess.open(log_path, FileAccess.READ)
	if file == null:
		var open_err := FileAccess.get_open_error()
		if FileAccess.file_exists(log_path):
			_send_result(peer, id, MCPToolkitError.fail("LOG_BUSY",
				"log file exists but could not be read (err %d)" % open_err,
				MCPToolkitError.log_busy_hint(LogBuffer.uses_logger_api())))
		else:
			var _gone_hint := "log file disappeared at %s — possible log rotation; retry" % log_path
			if LogBuffer.uses_logger_api():
				_gone_hint += " or use source=\"buffer\""
			_send_result(peer, id, MCPToolkitError.fail("LOG_UNAVAILABLE", _gone_hint,
				MCPToolkitError.log_unavailable_hint(LogBuffer.uses_logger_api())))
		return
	var text := file.get_as_text()
	file.close()

	# Filter-then-slice — uniform with the buffer source (LogBuffer.get_entries):
	# strip ANSI and apply text_filter across ALL lines FIRST, then take the last
	# `limit` matches. total_lines counts the matching lines (pre-cap); truncated
	# means the matches exceeded limit so older matches were dropped. Capped tail, cursor-less.
	var all_lines := text.split("\n", false)
	var filtered: Array = []
	for raw_line in all_lines:
		var line: String = LogHelpers.strip_ansi(str(raw_line))
		if text_filter != "":
			if text_regex != null:
				if not text_regex.search(line):
					continue
			else:
				if line.findn(text_filter) < 0:
					continue
		filtered.append(line)

	var total := filtered.size()
	var file_truncated: bool = filtered.size() > limit
	if file_truncated:
		filtered = filtered.slice(filtered.size() - limit)
	var slice: Array = filtered

	var json_slice := JSON.stringify(slice)
	var scrubbed := Scrubber.scrub(json_slice, "debugger.get_log")
	# Capped-tail pagination (oldest lines drop first, no cursor).
	var file_hint := ""
	if file_truncated:
		file_hint = "more lines remain — raise limit or narrow with text_filter (capped tail: the oldest lines drop first, no cursor)."
	var file_response := Pagination.build(
		{"lines": Untrusted.wrap("game_log", "godot", scrubbed["text"])},
		"lines", total, slice.size(), file_truncated, "", 0, file_hint,
		{"path": log_path, "source": "file"})
	if not regex_warning.is_empty():
		file_response["warning"] = regex_warning
	_send_result(peer, id, file_response)


## Detect likely double-escaped regex metacharacters (same as editor_commands.gd).
func _detect_double_escaped_regex(pattern: String) -> String:
	for letter in ["d", "D", "w", "W", "s", "S", "b", "B"]:
		if pattern.find("\\\\" + letter) >= 0:
			return (
				"Pattern contains '\\\\%s' (literal backslash + '%s'). "
				+ "If you meant the regex metacharacter \\%s, your backslash "
				+ "is likely double-escaped. In JSON, use \"\\\\%s\" (one escaped "
				+ "backslash), not \"\\\\\\\\%s\" (two)."
			) % [letter, letter, letter, letter, letter]
	return ""


# ---- Signal commands (Mode B mirror of editor handlers) ---------------------


# The root-resolver injected into the shared SignalPairResolver: the LIVE SceneTree
# root (the editor injects EditorInterface.get_edited_scene_root() instead). Returns
# null when the tree isn't ready, which the resolver treats as "no node".
func _runtime_root() -> Node:
	var tree := get_tree()
	return tree.root if tree != null else null


# Runtime equivalent of the editor's _resolve_scene_node — resolves a path against
# the LIVE SceneTree root via the shared resolver. Bare "" / "." resolves to the
# tree root so callers that just want a top-level signal don't need the full path.
# Kept as a thin wrapper so the other runtime commands that resolve a node
# (signal.emit, animation_player.control, execute.code, …) share one seam.
func _resolve_runtime_node(path: String):
	return SignalPairResolver.resolve_node(path, _runtime_root())


func _cmd_signal_list(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("node_path", ""))
	var node = _resolve_runtime_node(path)
	if node == null:
		_send_result(peer, id, MCPToolkitError.fail("NOT_FOUND", "node not found: %s" % path))
		return
	_send_result(peer, id, {"path": path, "signals": SignalPairResolver.list_signals_of(node)})


# Validates a connect/disconnect quartet against the live tree via the shared
# resolver. Returns the same shape the editor's _resolve_signal_pair does (the
# editor wraps the same resolver and layers its hint enrichment); the runtime path
# is deliberately leaner — no instanced-scene / compilation-error hints.
func _resolve_runtime_signal_pair(params) -> Dictionary:
	return SignalPairResolver.resolve_pair(params, _runtime_root())


func _cmd_signal_connect(peer: WebSocketPeer, id, params) -> void:
	var r := _resolve_runtime_signal_pair(params)
	if r.has("error"):
		_send_result(peer, id, MCPToolkitError.fail(str(r["code"]), str(r["error"])))
		return
	var source = r["source"]
	var callable: Callable = r["callable"]
	var signal_name: String = str(r["signal_name"])
	var source_path: String = str(r["source_path"])
	var target_path: String = str(r["target_path"])
	var method_name: String = str(r["method_name"])
	# Idempotency — mirror of the editor copy in SignalCommands.
	if source.is_connected(signal_name, callable):
		_send_result(peer, id, {
			"success": true,
			"status": "returned",
			"source_path": source_path,
			"signal": signal_name,
			"target_path": target_path,
			"method": method_name,
		})
		return
	# No UndoRedo in runtime — connections are ephemeral for the game session
	# and die when the player exits. Direct connect; surface failure code.
	# Explicit int annotation because `source` is Variant (Dict value) — type
	# inference can't reach through to Object.connect's Error return.
	var err: int = source.connect(signal_name, callable)
	if err != OK:
		_send_result(peer, id, MCPToolkitError.fail("CONNECT_FAILED", "connect returned %d" % err))
		return
	_send_result(peer, id, {
		"success": true,
		"status": "created",
		"source_path": source_path,
		"signal": signal_name,
		"target_path": target_path,
		"method": method_name,
	})


func _cmd_signal_disconnect(peer: WebSocketPeer, id, params) -> void:
	var r := _resolve_runtime_signal_pair(params)
	if r.has("error"):
		_send_result(peer, id, MCPToolkitError.fail(str(r["code"]), str(r["error"])))
		return
	var source = r["source"]
	var callable: Callable = r["callable"]
	var signal_name: String = str(r["signal_name"])
	if not source.is_connected(signal_name, callable):
		_send_result(peer, id, MCPToolkitError.fail("NOT_FOUND", "no connection to disconnect"))
		return
	source.disconnect(signal_name, callable)
	_send_result(peer, id, {"success": true})



func _cmd_signal_emit(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("node_path", ""))
	var signal_name := str(params.get("signal_name", ""))
	if signal_name.is_empty():
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", "missing signal_name"))
		return
	var node = _resolve_runtime_node(path)
	if node == null:
		_send_result(peer, id, MCPToolkitError.fail("NOT_FOUND", "node not found: %s" % path))
		return
	if not node.has_signal(signal_name):
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", "signal %s not on %s" % [signal_name, path]))
		return
	var raw_args = params.get("args", [])
	if typeof(raw_args) != TYPE_ARRAY:
		raw_args = []
	var coerced: Array = [signal_name]
	for a in raw_args:
		var coerced_arg = Coerce.coerce_value(a)
		if typeof(coerced_arg) == TYPE_DICTIONARY and (coerced_arg as Dictionary).has("_coerce_error"):
			_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", str(coerced_arg["_coerce_error"])))
			return
		coerced.append(coerced_arg)
	node.callv("emit_signal", coerced)
	_send_result(peer, id, {"success": true})


# ---- Playtest commands ------------------------------------------------------


# input.simulate: process an array of {event_type, event_data, delay_ms?}
# sequentially with optional delays. key/action events feed the Input singleton
# via Input.parse_input_event; mouse and send_text events route through
# Viewport.push_input (driving gui_input/focus).
func _cmd_input_simulate(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", "params must be an object"))
		return

	var events = params.get("events", null)
	if typeof(events) != TYPE_ARRAY or events.is_empty():
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS",
			"events array is required and must not be empty"))
		return

	var summary_mode: bool = bool(params.get("summary", true))
	var total: int = events.size()
	var results: Array = []
	var processed := 0

	for i in total:
		var event = events[i]
		if typeof(event) != TYPE_DICTIONARY:
			var err := MCPToolkitError.fail("INVALID_PARAMS", "event at index %d must be an object" % i)
			err["events_processed"] = processed
			if not summary_mode:
				err["results"] = results
			_send_result(peer, id, err)
			return
		var et := str(event.get("event_type", ""))
		var ed: Dictionary = {}
		var raw = event.get("event_data", null)
		if typeof(raw) == TYPE_DICTIONARY:
			ed = raw
		var delay_before_ms := int(event.get("delay_before_ms", 0))
		var delay_after_ms := int(event.get("delay_after_ms", 0))
		if delay_before_ms > 0:
			await get_tree().create_timer(delay_before_ms / 1000.0).timeout
		var event_result := {"index": i, "total": total, "type": et, "dispatched": true}
		# Diagnostic: gui_has_focus = a GUI Control has focus (not OS window focus).
		var vp := get_viewport()
		if vp != null:
			event_result["gui_has_focus"] = vp.gui_get_focus_owner() != null
		event_result["tree_paused"] = get_tree().paused if get_tree() != null else false
		if et == "click":
			var click_delay := int(ed.get("click_delay_ms", 50))
			await _dispatch_click(ed)
			event_result["click_delay_ms"] = click_delay
		elif et == "click_node":
			var click_result := _dispatch_click_node(ed)
			event_result.merge(click_result, true)
		elif et == "action":
			# Hybrid dispatch: action_press/release for sustained
			# Input.is_action_pressed() state (movement), PLUS
			# parse_input_event(InputEventAction) to set the frame-
			# transition tracking that is_action_just_pressed() needs (jump).
			var action_name := StringName(str(ed.get("action", "")))
			# Reject an action not registered in the InputMap: dispatching it matches
			# nothing (a silent no-op that would otherwise report success:true, dispatched:true).
			# Aborts the batch like a malformed event, naming the unknown action. Only
			# the action path uses the InputMap — key/text/send_text modes don't.
			if not InputMap.has_action(action_name):
				var action_err := MCPToolkitError.fail("INVALID_PARAMS",
					"input action '%s' is not registered in the InputMap" % str(action_name),
					"Register it in Project Settings → Input Map (or check the name — "
					+ "action strings are case-sensitive). List actions with InputMap.get_actions().")
				action_err["events_processed"] = processed
				if not summary_mode:
					action_err["results"] = results
				_send_result(peer, id, action_err)
				return
			var is_pressed := bool(ed.get("pressed", true))
			var strength := float(ed.get("strength", 1.0))
			if is_pressed:
				Input.action_press(action_name, strength)
			else:
				Input.action_release(action_name)
			var act := InputEventAction.new()
			act.action = action_name
			act.pressed = is_pressed
			act.strength = strength
			Input.parse_input_event(act)
			event_result["action"] = str(action_name)
			event_result["pressed"] = is_pressed
		elif et == "send_text":
			# Type a string into a text surface via the focus owner so the real
			# gui_input → text_changed/text_submitted fire (set_property(.text)
			# skips them). event_data values are Variant — coerce each explicitly.
			var text_val: String = str(ed.get("text", ""))
			var node_path_str: String = str(ed.get("node_path", ""))
			var do_submit: bool = bool(ed.get("submit", false))

			# Focus precedence: an explicit Control node_path wins; otherwise type
			# into whatever currently holds GUI focus. A custom _input reader gets
			# the events regardless of focus, so "none" is a hint, not a failure.
			var target: Node = null
			var focus_source := "none"
			var node_path_problem := ""
			if not node_path_str.is_empty():
				# Resolve against /root (NOT click_node's current_scene resolver) so
				# absolute /root/... paths and autoloads resolve as documented.
				var resolved = _resolve_runtime_node(node_path_str)
				if resolved == null:
					node_path_problem = "not found"
				elif resolved is Control:
					target = resolved
					(resolved as Control).grab_focus()
					# One frame for the focus change to settle before typing.
					await get_tree().process_frame
					focus_source = "node_path"
				else:
					node_path_problem = "is not a Control (%s)" % resolved.get_class()
			if target == null:
				target = vp.gui_get_focus_owner() if vp != null else null
				focus_source = "existing" if target != null else "none"

			# Capture before/after only when the target exposes a readable String
			# `text`; a custom reader has none → text_changed stays null.
			var has_text := false
			var text_before := ""
			if target != null:
				var tb: Variant = target.get("text")
				if typeof(tb) == TYPE_STRING:
					has_text = true
					text_before = tb
			# Redact the echo when the target's `secret` is true (LineEdit.secret);
			# the change comparison below still reads the real value — only the echo masks.
			var is_secret := false
			if target != null:
				var sec: Variant = target.get("secret")
				is_secret = typeof(sec) == TYPE_BOOL and bool(sec)

			# Deliver via push_input (routes a key event to gui.key_focus); mirror
			# the mouse path's parse_input_event fallback when there is no viewport.
			for key_ev in TextInputSynth.synthesize_text_events(text_val):
				if vp != null:
					vp.push_input(key_ev)
				else:
					Input.parse_input_event(key_ev)
			if do_submit:
				for enter_ev in TextInputSynth.synthesize_enter():
					if vp != null:
						vp.push_input(enter_ev)
					else:
						Input.parse_input_event(enter_ev)
			var chars_sent := text_val.length()

			var text_changed: Variant = null
			if has_text:
				var ta: Variant = target.get("text")
				var raw_after: String = ta if typeof(ta) == TYPE_STRING else ""
				text_changed = raw_after != text_before
				event_result["text_after"] = TextInputSynth.format_text_after(raw_after, is_secret)
			event_result["chars_sent"] = chars_sent
			event_result["focus_source"] = focus_source
			if target != null:
				event_result["focus_target"] = {"path": str(target.get_path()), "class": target.get_class()}
			else:
				event_result["focus_target"] = null
			event_result["text_changed"] = text_changed

			if node_path_problem != "":
				event_result["hint"] = "node_path '%s' %s; pass a valid Control path or omit node_path to type into the focused field." % [node_path_str, node_path_problem]
			else:
				var focus_path := str(target.get_path()) if target != null else ""
				var focus_class := target.get_class() if target != null else ""
				var paused := bool(event_result.get("tree_paused", false))
				var send_text_hint := TextInputSynth.build_hint(
					focus_source, text_changed, focus_path, focus_class, chars_sent, paused)
				if send_text_hint != "":
					event_result["hint"] = send_text_hint
		else:
			var ev := _build_input_event(et, ed)
			if ev == null:
				event_result["dispatched"] = false
				event_result["error"] = "unknown event_type (expected key|mouse_button|mouse_motion|action|click|click_node|send_text)"
				results.append(event_result)
				var err := MCPToolkitError.fail("INVALID_PARAMS",
					"unknown event_type at index %d: %s" % [i, et])
				err["events_processed"] = processed
				if summary_mode:
					err["failed_at"] = event_result
				else:
					err["results"] = results
				_send_result(peer, id, err)
				return
			# Mouse events use push_input for proper GUI/CanvasLayer routing.
			# No OS-level focus — position + global_position fields are
			# sufficient for viewport hit-testing and parallel-safe.
			if ev is InputEventMouse:
				if get_viewport() != null:
					get_viewport().push_input(ev)
				else:
					Input.parse_input_event(ev)
			else:
				Input.parse_input_event(ev)
		results.append(event_result)
		processed += 1
		if delay_after_ms > 0:
			await get_tree().create_timer(delay_after_ms / 1000.0).timeout

	if summary_mode:
		_send_result(peer, id, {"success": true, "events_processed": processed,
			"total": total, "last_event": results.back()})
	else:
		_send_result(peer, id, {"success": true, "events_processed": processed,
			"total": total, "results": results})


## Parses mouse position from event_data. Accepts both flat {x, y} and
## nested {position: {x, y}} formats for LLM robustness.
func _parse_mouse_position(event_data: Dictionary) -> Vector2:
	var pos = event_data.get("position", null)
	if pos == null and event_data.has("x"):
		pos = {"x": event_data.get("x", 0.0), "y": event_data.get("y", 0.0)}
	if typeof(pos) == TYPE_DICTIONARY:
		return Vector2(float(pos.get("x", 0.0)), float(pos.get("y", 0.0)))
	return Vector2.ZERO


## Raise + focus the game's OS window. Only for an explicit opt-in
## (force_foreground_game): input synthesis does NOT need it — push_input() with
## correct position + global_position is enough for viewport hit-testing without
## OS focus. Hazard: during parallel multi-instance runs this makes sessions
## fight over the OS mouse and window focus, so it must stay opt-in.
func _ensure_game_focus() -> void:
	DisplayServer.window_move_to_foreground()
	var win := get_window()
	if win != null:
		win.grab_focus()


func _build_input_event(event_type: String, event_data: Dictionary) -> InputEvent:
	match event_type:
		"key":
			var key_ev := InputEventKey.new()
			key_ev.keycode = int(event_data.get("keycode", 0))
			key_ev.pressed = bool(event_data.get("pressed", true))
			if event_data.has("physical_keycode"):
				key_ev.physical_keycode = int(event_data.get("physical_keycode", 0))
			if event_data.has("unicode"):
				key_ev.unicode = int(event_data.get("unicode", 0))
			key_ev.shift_pressed = bool(event_data.get("shift", false))
			key_ev.ctrl_pressed = bool(event_data.get("ctrl", false))
			key_ev.alt_pressed = bool(event_data.get("alt", false))
			key_ev.meta_pressed = bool(event_data.get("meta", false))
			return key_ev
		"mouse_button":
			var mb := InputEventMouseButton.new()
			mb.button_index = int(event_data.get("button_index", MOUSE_BUTTON_LEFT))
			mb.pressed = bool(event_data.get("pressed", true))
			var mb_vec := _parse_mouse_position(event_data)
			mb.position = mb_vec
			mb.global_position = mb_vec
			if event_data.has("world_position"):
				var wp := _parse_mouse_position(
					{"position": event_data["world_position"]})
				var vp_pos: Vector2 = get_viewport().get_canvas_transform() * wp
				mb.position = vp_pos
				mb.global_position = vp_pos
			mb.shift_pressed = bool(event_data.get("shift", false))
			mb.ctrl_pressed = bool(event_data.get("ctrl", false))
			mb.alt_pressed = bool(event_data.get("alt", false))
			mb.meta_pressed = bool(event_data.get("meta", false))
			return mb
		"mouse_motion":
			var mm := InputEventMouseMotion.new()
			var mm_vec := _parse_mouse_position(event_data)
			mm.position = mm_vec
			mm.global_position = mm_vec
			if event_data.has("world_position"):
				var wp := _parse_mouse_position(
					{"position": event_data["world_position"]})
				var vp_pos: Vector2 = get_viewport().get_canvas_transform() * wp
				mm.position = vp_pos
				mm.global_position = vp_pos
			var rel = event_data.get("relative", null)
			if typeof(rel) == TYPE_DICTIONARY:
				mm.relative = Vector2(float(rel.get("x", 0.0)), float(rel.get("y", 0.0)))
			return mm
		"action":
			var act := InputEventAction.new()
			act.action = StringName(str(event_data.get("action", "")))
			act.pressed = bool(event_data.get("pressed", true))
			if event_data.has("strength"):
				act.strength = float(event_data.get("strength", 1.0))
			return act
		_:
			return null


## click: press + delay + release at a position (50 ms default internal delay).
## Uses push_input with position + global_position for GUI hit-testing.
## No OS-level warp_mouse or window focus — safe for parallel multi-instance runs.
func _dispatch_click(event_data: Dictionary) -> void:
	var mb_press := InputEventMouseButton.new()
	mb_press.button_index = int(event_data.get("button_index", MOUSE_BUTTON_LEFT))
	mb_press.pressed = true
	var vec := _parse_mouse_position(event_data)
	if event_data.has("world_position"):
		var wp := _parse_mouse_position(
			{"position": event_data["world_position"]})
		vec = get_viewport().get_canvas_transform() * wp
	mb_press.position = vec
	mb_press.global_position = vec
	mb_press.shift_pressed = bool(event_data.get("shift", false))
	mb_press.ctrl_pressed = bool(event_data.get("ctrl", false))
	mb_press.alt_pressed = bool(event_data.get("alt", false))
	mb_press.meta_pressed = bool(event_data.get("meta", false))
	var vp := get_viewport()
	if vp != null:
		vp.push_input(mb_press)
	else:
		Input.parse_input_event(mb_press)
	var click_delay := int(event_data.get("click_delay_ms", 50))
	await get_tree().create_timer(click_delay / 1000.0).timeout
	var mb_release := InputEventMouseButton.new()
	mb_release.button_index = mb_press.button_index
	mb_release.pressed = false
	mb_release.position = vec
	mb_release.global_position = vec
	mb_release.shift_pressed = mb_press.shift_pressed
	mb_release.ctrl_pressed = mb_press.ctrl_pressed
	mb_release.alt_pressed = mb_press.alt_pressed
	mb_release.meta_pressed = mb_press.meta_pressed
	if vp != null:
		vp.push_input(mb_release)
	else:
		Input.parse_input_event(mb_release)


## click_node: programmatic click on a node by path. Calls grab_focus() on
## Controls and emits pressed signal on BaseButtons. No coordinate guessing.
func _dispatch_click_node(event_data: Dictionary) -> Dictionary:
	var node_path_str := str(event_data.get("node_path", ""))
	if node_path_str.is_empty():
		return {"dispatched": false, "error": "node_path is required for click_node"}
	var root := get_tree().current_scene if get_tree() != null else null
	if root == null:
		return {"dispatched": false, "error": "no current scene"}
	var target := root.get_node_or_null(NodePath(node_path_str))
	if target == null:
		return {"dispatched": false, "error": "node not found: %s" % node_path_str}
	var result := {"dispatched": true, "node_path": node_path_str, "node_class": target.get_class()}
	if target is Control:
		target.grab_focus()
		result["focused"] = true
	if target is BaseButton:
		if target.toggle_mode:
			target.button_pressed = not target.button_pressed
			result["toggled_to"] = target.button_pressed
		target.emit_signal("pressed")
		result["pressed_emitted"] = true
	else:
		result["pressed_emitted"] = false
		result["note"] = "node is not a BaseButton; grab_focus applied if Control"
	return result


# animation_player.control: drive an AnimationPlayer in the live SceneTree.
# Returns post-op state so the caller can confirm the seek/play landed
# without an extra round-trip.
func _cmd_animation_player_control(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("node_path", ""))
	if path.is_empty():
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", "missing node_path"))
		return
	var node = _resolve_runtime_node(path)
	if node == null:
		_send_result(peer, id, MCPToolkitError.fail("NOT_FOUND", "node not found: %s" % path))
		return
	if not (node is AnimationPlayer):
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", "node is not AnimationPlayer: %s (got %s)" % [path, node.get_class()]))
		return
	var ap: AnimationPlayer = node
	var op := str(params.get("operation", ""))
	match op:
		"play":
			var anim := str(params.get("animation_name", ""))
			if anim.is_empty():
				ap.play()
			else:
				if not ap.has_animation(anim):
					_send_result(peer, id, MCPToolkitError.fail("NOT_FOUND", "animation not found: %s" % anim))
					return
				ap.play(anim)
		"pause":
			ap.pause()
		"stop":
			ap.stop()
		"seek":
			ap.seek(float(params.get("time", 0.0)), true)
		_:
			_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", "unknown op: %s (expected play|pause|stop|seek)" % op))
			return
	_send_result(peer, id, {
		"success": true,
		"current_animation": String(ap.current_animation),
		"current_animation_position": ap.current_animation_position,
	})


# execute.code: evaluates GDScript via Expression in the running game's context.
# Risk communicated via MCP annotations (destructiveHint: true) and
# security-recommendations.md; agent-side tool filtering is the enforcement layer.
func _cmd_execute_code(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", "params must be an object"))
		return
	var code := str(params.get("code", ""))
	if code.is_empty():
		_send_result(peer, id, MCPToolkitError.fail("INVALID_PARAMS", "missing code"))
		return

	var truncated := code.substr(0, _EXECUTE_CODE_LOG_CAP)
	if code.length() > _EXECUTE_CODE_LOG_CAP:
		truncated += "...[+%d chars]" % (code.length() - _EXECUTE_CODE_LOG_CAP)
	print("[MCPTools] execute.code: %s" % truncated)

	var scope_node: Node = null
	var scope_path := str(params.get("scope_path", ""))
	if scope_path.is_empty():
		var tree := get_tree()
		if tree == null or tree.root == null:
			_send_result(peer, id, MCPToolkitError.fail("INTERNAL", "scene tree unavailable"))
			return
		scope_node = tree.root
	else:
		scope_node = _resolve_runtime_node(scope_path)
		if scope_node == null:
			_send_result(peer, id, MCPToolkitError.fail("NOT_FOUND", "scope node not found: %s" % scope_path))
			return

	# Expression only supports expressions, not statements. Catch common
	# statement keywords early with a clear error instead of the cryptic
	# "Invalid named index 'var'" from Expression.parse().
	var _trimmed := code.strip_edges()
	for _kw in ["var", "return", "func", "if", "for", "while", "class", "const", "match"]:
		if _trimmed == _kw or _trimmed.begins_with(_kw + " ") or _trimmed.begins_with(_kw + "\t") or _trimmed.begins_with(_kw + "\n"):
			_send_result(peer, id, MCPToolkitError.fail("PARSE_ERROR",
				"execute_code only supports expressions, not statements. '%s' is a statement keyword. " % _kw +
				"Use method calls (node.method()), property access (node.property), or arithmetic instead."))
			return

	var expr := Expression.new()
	var parse_err := expr.parse(code, PackedStringArray())
	if parse_err != OK:
		_send_result(peer, id, MCPToolkitError.fail("PARSE_ERROR", expr.get_error_text()))
		return
	var result = expr.execute([], scope_node, false)
	if expr.has_execute_failed():
		var err_text := expr.get_error_text()
		# Enrich via the shared helper so editor and runtime give identical guidance.
		err_text += ExecuteHints.build_hint(err_text, code)
		_send_result(peer, id, MCPToolkitError.fail("EXECUTE_FAILED", err_text))
		return
	_send_result(peer, id, {"result": Coerce.serialize_value(result)})
