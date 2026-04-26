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
##      Keeping a second WS listener on 6525 while editing is a bug.
##   2. not OS.is_debug_build() — release export. Mode B must NOT ship
##      to end users' shipped games. This is security-critical.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPCoerce = _Hub.MCPCoerce
const MCPUntrusted = _Hub.MCPUntrusted
const MCPAuth := preload("res://addons/godot_mcp_toolkit/auth.gd")
const MCPFeatureGate = _Hub.MCPFeatureGate
const MCPScrubber = _Hub.MCPScrubber
const MCPRegistryClient = _Hub.MCPRegistryClient

const PORT_BASE := 6525
const PORT_RANGE := 16  # 6525..6540 inclusive
const BIND := "127.0.0.1"
const JSONRPC_VERSION := "2.0"
# Throttle re-listen retries. Mirrors mcp_server.gd's editor-side loop.
# Runtime restarts on F5 each game session, so the typical "missed bind"
# recoverable case is a stale debug session that hasn't released 6525
# yet — usually clears in 1-2 frames.
const _RELISTEN_FRAME_INTERVAL := 60
const _AUTH_TIMEOUT_MS := 2000

var _tcp_server: TCPServer = null
var _peers: Array[WebSocketPeer] = []
var _relisten_countdown := 0
# Mirror of mcp_server.gd._consecutive_failures — log first-failure-of-streak
# then go silent until success/recovery. See that file for rationale.
var _consecutive_failures := 0
var _session_token: String = ""
var _peer_authed: Dictionary = {}
var _peer_connect_ms: Dictionary = {}
# -1 = never bound.
var _bound_port: int = -1


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
	# Debug-build gate: shipped (release) games must not listen on 6525.
	# Same quiescent approach — an empty Node at scene-tree root is cheaper
	# than the subtle edge cases of auto-freeing during SceneTree setup.
	if not OS.is_debug_build():
		set_process(false)
		return
	_start_server()


func _exit_tree() -> void:
	_stop_server()


func _start_server() -> void:
	_Hub.LogBuffer.setup()
	_relisten_countdown = 0
	_bound_port = -1
	# Runtime uses the same token file as the editor server so the bridge can
	# authenticate against both with one read. The editor server writes first
	# (plugin enable runs before game launch). If the file doesn't exist yet
	# (edge case: game launched standalone without plugin), generate our own
	# token.
	var token_path := MCPAuth.get_token_path()
	var file := FileAccess.open(token_path, FileAccess.READ)
	if file != null:
		_session_token = file.get_as_text().strip_edges()
		file.close()
	if _session_token.is_empty():
		_session_token = MCPAuth.generate_token()
		MCPAuth.write_token(_session_token)
	_scan_and_listen()


func _stop_server() -> void:
	set_process(false)
	for peer in _peers:
		if peer != null:
			peer.close(1000)
	_peers.clear()
	_peer_authed.clear()
	_peer_connect_ms.clear()
	if _tcp_server != null:
		_tcp_server.stop()
		_tcp_server = null
	_relisten_countdown = 0
	_consecutive_failures = 0
	_bound_port = -1
	# Best-effort registry cleanup (game may be force-killed).
	MCPRegistryClient.clear_runtime()


# First-time port scan. Tries PORT_BASE..PORT_BASE+PORT_RANGE-1 and binds
# the first free port. On success, writes runtime_port to registry.
func _scan_and_listen() -> void:
	for offset in range(PORT_RANGE):
		var candidate := PORT_BASE + offset
		var server := TCPServer.new()
		var err := server.listen(candidate, BIND)
		if err == OK:
			_tcp_server = server
			_bound_port = candidate
			_consecutive_failures = 0
			_relisten_countdown = 0
			print("[MCPRuntimeServer] listening on %s:%d" % [BIND, _bound_port])
			MCPRegistryClient.set_runtime(_bound_port)
			return
		server.stop()
	# All ports in range exhausted — Mode B disabled this session.
	_consecutive_failures += 1
	if _consecutive_failures == 1:
		push_warning("[MCPRuntimeServer] no free port in %d–%d; Mode B tools disabled this session" % [PORT_BASE, PORT_BASE + PORT_RANGE - 1])
	_tcp_server = null
	_relisten_countdown = _RELISTEN_FRAME_INTERVAL


# Idempotent re-listen. If we already found a port (_bound_port > 0),
# retry that specific port. Otherwise re-scan.
func _try_listen() -> void:
	if _relisten_countdown > 0:
		_relisten_countdown -= 1
		return
	if _bound_port < 0:
		_scan_and_listen()
		return
	if _tcp_server == null:
		_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(_bound_port, BIND)
	if err == OK:
		if _consecutive_failures > 0:
			print("[MCPRuntimeServer] listening on %s:%d (recovered after %d failed attempts)" % [BIND, _bound_port, _consecutive_failures])
		_consecutive_failures = 0
		_relisten_countdown = 0
		return
	_consecutive_failures += 1
	if _consecutive_failures == 1:
		var hint := ""
		if err == ERR_ALREADY_IN_USE:
			hint = " (ERR_ALREADY_IN_USE — will retry silently every ~1s)"
		push_warning("[MCPRuntimeServer] rebind %s:%d failed (err %d)%s" % [BIND, _bound_port, err, hint])
	_tcp_server.stop()
	_tcp_server = null
	_relisten_countdown = _RELISTEN_FRAME_INTERVAL


func _process(_delta: float) -> void:
	_Hub.LogBuffer.poll()
	# Keep the listener up across transient socket loss. Editor / release
	# gating from _ready prevents _process from running where it shouldn't
	# (set_process(false)), so reaching here = debug-build runtime.
	if _tcp_server == null or not _tcp_server.is_listening():
		_try_listen()
		return

	while _tcp_server.is_connection_available():
		var stream := _tcp_server.take_connection()
		var peer := WebSocketPeer.new()
		peer.inbound_buffer_size = 1048576
		peer.outbound_buffer_size = 1048576
		var accept_err := peer.accept_stream(stream)
		if accept_err != OK:
			push_warning("[MCPRuntimeServer] accept_stream failed (%d)" % accept_err)
			continue
		_peers.append(peer)
		_peer_connect_ms[peer] = Time.get_ticks_msec()

	var closed_peers: Array[WebSocketPeer] = []
	var now_ms := Time.get_ticks_msec()
	for peer in _peers:
		peer.poll()
		var state := peer.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			closed_peers.append(peer)
			continue
		if state != WebSocketPeer.STATE_OPEN:
			continue
		if not _peer_authed.has(peer):
			if now_ms - int(_peer_connect_ms.get(peer, 0)) > _AUTH_TIMEOUT_MS:
				peer.close(1008, "auth timeout")
				closed_peers.append(peer)
				continue
		while peer.get_available_packet_count() > 0:
			var text := peer.get_packet().get_string_from_utf8()
			_handle_message(peer, text)

	for peer in closed_peers:
		_peers.erase(peer)
		_peer_authed.erase(peer)
		_peer_connect_ms.erase(peer)


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

	# Auth handshake.
	if not _peer_authed.has(peer):
		if MCPAuth.validate(msg, _session_token):
			_peer_authed[peer] = true
			peer.send_text(JSON.stringify({"authed": true}))
		else:
			peer.close(1008, "invalid token")
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
			_send_result(peer, id, {"ok": true})
		"runtime.screenshot":
			_cmd_runtime_screenshot(peer, id)
		"runtime.get_node_state":
			_cmd_runtime_get_node_state(peer, id, params)
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
		"game.eval":
			_cmd_game_eval(peer, id, params)
		_:
			_send_error(peer, id, -32601, "Method not found: %s" % method)


func _send_result(peer: WebSocketPeer, id, result) -> void:
	var response := {
		"jsonrpc": JSONRPC_VERSION,
		"id": id,
		"result": result,
	}
	peer.send_text(JSON.stringify(response))


func _send_error(peer: WebSocketPeer, id, code: int, message: String) -> void:
	var response := {
		"jsonrpc": JSONRPC_VERSION,
		"id": id,
		"error": {
			"code": code,
			"message": message,
		},
	}
	peer.send_text(JSON.stringify(response))



# ---- Runtime command helpers ------------------------------------------------


func _cmd_runtime_screenshot(peer: WebSocketPeer, id) -> void:
	var viewport := get_viewport()
	if viewport == null:
		_send_result(peer, id, MCPError.make("INTERNAL", "no viewport available"))
		return

	# Wait for any queued draw calls to complete. Without this, get_image
	# can return an uninitialised texture on the first call after game
	# launch. Pattern matches godot-mcp-pro's frame capture setup.
	await RenderingServer.frame_post_draw

	var image := viewport.get_texture().get_image()
	if image == null:
		_send_result(peer, id, MCPError.make("INTERNAL", "viewport texture unavailable"))
		return

	var png_bytes := image.save_png_to_buffer()
	if png_bytes.is_empty():
		_send_result(peer, id, MCPError.make("INTERNAL", "save_png_to_buffer returned empty"))
		return

	_send_result(peer, id, {
		"image_base64": Marshalls.raw_to_base64(png_bytes),
		"mime_type": "image/png",
		"width": image.get_width(),
		"height": image.get_height(),
		"bytes": png_bytes.size(),
	})


func _cmd_runtime_get_node_state(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, MCPError.make("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("node_path", ""))
	if path.is_empty():
		_send_result(peer, id, MCPError.make("INVALID_PARAMS", "missing node_path"))
		return

	var tree := get_tree()
	if tree == null or tree.root == null:
		_send_result(peer, id, MCPError.make("INTERNAL", "scene tree unavailable"))
		return

	var node := tree.root.get_node_or_null(path)
	if node == null:
		_send_result(peer, id, MCPError.make("NOT_FOUND", "node not found: %s" % path))
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
		props[pname] = MCPCoerce.serialize_value(node.get(pname))

	_send_result(peer, id, {
		"name": String(node.name),
		"class": node.get_class(),
		"path": path,
		"properties": props,
	})


const _DEFAULT_LOG_LIMIT := 200


func _cmd_debugger_get_log(peer: WebSocketPeer, id, params) -> void:
	var limit := _DEFAULT_LOG_LIMIT
	if typeof(params) == TYPE_DICTIONARY and params.has("limit"):
		limit = max(1, int(params.get("limit", _DEFAULT_LOG_LIMIT)))
	var source: String = "buffer"
	if typeof(params) == TYPE_DICTIONARY and params.has("source"):
		source = str(params.get("source", "buffer"))
	if not (source in ["buffer", "file"]):
		_send_result(peer, id, MCPError.make("INVALID_PARAMS",
			"source must be 'buffer' or 'file' (got %s)" % source))
		return

	if source == "buffer":
		var buf_result: Dictionary = _Hub.LogBuffer.get_entries(limit, [], -1)
		var entries: Array = buf_result["entries"]
		for entry in entries:
			var scrubbed := MCPScrubber.scrub(str(entry["message"]), "debugger.get_log")
			entry["message"] = scrubbed["text"]
		_send_result(peer, id, {
			"lines": MCPUntrusted.wrap("game_log", "buffer", JSON.stringify(entries)),
			"count": buf_result["count"],
			"next_id": buf_result["next_id"],
			"truncated": buf_result["truncated"],
			"source": "buffer",
		})
		return

	# source == "file" — original log-file reader.
	var log_path := "user://logs/godot.log"
	if not FileAccess.file_exists(log_path):
		_send_result(peer, id, {
			"lines": [],
			"count": 0,
			"total": 0,
			"path": log_path,
			"source": "file",
			"note": "log file not yet written — new game with no prints, or flush_stdout_on_print disabled",
		})
		return

	var file := FileAccess.open(log_path, FileAccess.READ)
	if file == null:
		var open_err := FileAccess.get_open_error()
		if FileAccess.file_exists(log_path):
			_send_result(peer, id, MCPError.make("LOG_BUSY",
				"log file exists but cannot be read right now (err %d) — transient lock during flush, retry in 1-2s; consider source=\"buffer\" instead" % open_err))
		else:
			_send_result(peer, id, MCPError.make("LOG_UNAVAILABLE",
				"log file disappeared at %s — possible log rotation; retry or use source=\"buffer\"" % log_path))
		return
	var text := file.get_as_text()
	file.close()

	var all_lines := text.split("\n", false)
	var total := all_lines.size()
	var start := max(0, total - limit)
	var slice: Array = []
	for i in range(start, total):
		slice.append(all_lines[i])

	var json_slice := JSON.stringify(slice)
	var scrubbed := MCPScrubber.scrub(json_slice, "debugger.get_log")
	_send_result(peer, id, {
		"lines": MCPUntrusted.wrap("game_log", "godot", scrubbed["text"]),
		"count": slice.size(),
		"total": total,
		"path": log_path,
		"source": "file",
	})


# ---- Signal commands (Mode B mirror of editor handlers) ---------------------


# Runtime equivalent of the editor's _resolve_scene_node — uses the LIVE
# SceneTree root rather than EditorInterface.get_edited_scene_root(). Bare
# "" / "." resolves to the tree root so callers that just want a top-level
# signal on the main scene don't need to type the full path.
func _resolve_runtime_node(path: String):
	var tree := get_tree()
	if tree == null or tree.root == null:
		return null
	if path.is_empty() or path == ".":
		return tree.root
	return tree.root.get_node_or_null(path)


func _signal_list_of(node: Object) -> Array:
	var out: Array = []
	for sig in node.get_signal_list():
		var args: Array = []
		for arg in sig.get("args", []):
			args.append({
				"name": str(arg.get("name", "")),
				"type": int(arg.get("type", 0)),
			})
		out.append({
			"name": str(sig.get("name", "")),
			"args": args,
		})
	return out


func _cmd_signal_list(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, MCPError.make("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("node_path", ""))
	var node = _resolve_runtime_node(path)
	if node == null:
		_send_result(peer, id, MCPError.make("NOT_FOUND", "node not found: %s" % path))
		return
	_send_result(peer, id, {"path": path, "signals": _signal_list_of(node)})


# Returns the same shape as editor SignalCommands._resolve_signal_pair.
# Duplicated here because runtime uses _resolve_runtime_node (live SceneTree)
# instead of EditorInterface; the node-resolution difference prevents sharing.
func _resolve_runtime_signal_pair(params) -> Dictionary:
	if typeof(params) != TYPE_DICTIONARY:
		return {"code": "INVALID_PARAMS", "error": "params must be an object"}
	var source_path := str(params.get("source_path", ""))
	var signal_name := str(params.get("signal_name", ""))
	var target_path := str(params.get("target_path", ""))
	var method_name := str(params.get("method_name", ""))
	if source_path.is_empty() or signal_name.is_empty() or target_path.is_empty() or method_name.is_empty():
		return {"code": "INVALID_PARAMS", "error": "source_path, signal_name, target_path, method_name are all required"}
	var source = _resolve_runtime_node(source_path)
	if source == null:
		return {"code": "NOT_FOUND", "error": "source node not found: %s" % source_path}
	var target = _resolve_runtime_node(target_path)
	if target == null:
		return {"code": "NOT_FOUND", "error": "target node not found: %s" % target_path}
	if not source.has_signal(signal_name):
		return {"code": "INVALID_PARAMS", "error": "signal %s not on %s" % [signal_name, source_path]}
	if not target.has_method(method_name):
		return {"code": "INVALID_PARAMS", "error": "method %s not on %s" % [method_name, target_path]}
	return {
		"source": source,
		"target": target,
		"source_path": source_path,
		"target_path": target_path,
		"signal_name": signal_name,
		"method_name": method_name,
		"callable": Callable(target, method_name),
	}


func _cmd_signal_connect(peer: WebSocketPeer, id, params) -> void:
	var r := _resolve_runtime_signal_pair(params)
	if r.has("error"):
		_send_result(peer, id, MCPError.make(str(r["code"]), str(r["error"])))
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
		_send_result(peer, id, MCPError.make("CONNECT_FAILED", "connect returned %d" % err))
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
		_send_result(peer, id, MCPError.make(str(r["code"]), str(r["error"])))
		return
	var source = r["source"]
	var callable: Callable = r["callable"]
	var signal_name: String = str(r["signal_name"])
	if not source.is_connected(signal_name, callable):
		_send_result(peer, id, MCPError.make("NOT_FOUND", "no connection to disconnect"))
		return
	source.disconnect(signal_name, callable)
	_send_result(peer, id, {"ok": true})



func _cmd_signal_emit(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, MCPError.make("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("node_path", ""))
	var signal_name := str(params.get("signal_name", ""))
	if signal_name.is_empty():
		_send_result(peer, id, MCPError.make("INVALID_PARAMS", "missing signal_name"))
		return
	var node = _resolve_runtime_node(path)
	if node == null:
		_send_result(peer, id, MCPError.make("NOT_FOUND", "node not found: %s" % path))
		return
	if not node.has_signal(signal_name):
		_send_result(peer, id, MCPError.make("INVALID_PARAMS", "signal %s not on %s" % [signal_name, path]))
		return
	var raw_args = params.get("args", [])
	if typeof(raw_args) != TYPE_ARRAY:
		raw_args = []
	var coerced: Array = [signal_name]
	for a in raw_args:
		coerced.append(MCPCoerce.coerce_value(a))
	node.callv("emit_signal", coerced)
	_send_result(peer, id, {"ok": true})


# ---- Playtest commands ------------------------------------------------------


# input.simulate: process an array of {event_type, event_data, delay_ms?} and
# feed them through Input.parse_input_event sequentially with optional delays.
func _cmd_input_simulate(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, MCPError.make("INVALID_PARAMS", "params must be an object"))
		return

	var events = params.get("events", null)
	if typeof(events) != TYPE_ARRAY or events.is_empty():
		_send_result(peer, id, MCPError.make("INVALID_PARAMS",
			"events array is required and must not be empty"))
		return

	var summary_mode: bool = bool(params.get("summary", true))
	var total: int = events.size()
	var results: Array = []
	var processed := 0

	for i in total:
		var event = events[i]
		if typeof(event) != TYPE_DICTIONARY:
			var err := MCPError.make("INVALID_PARAMS", "event at index %d must be an object" % i)
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
			OS.delay_msec(delay_before_ms)
		var event_result := {"index": i, "total": total, "type": et, "dispatched": true}
		if et == "click":
			var click_delay := int(ed.get("click_delay_ms", 50))
			_dispatch_click(ed)
			event_result["click_delay_ms"] = click_delay
		else:
			var ev := _build_input_event(et, ed)
			if ev == null:
				event_result["dispatched"] = false
				event_result["error"] = "unknown event_type (expected key|mouse_button|mouse_motion|action|click)"
				results.append(event_result)
				var err := MCPError.make("INVALID_PARAMS",
					"unknown event_type at index %d: %s" % [i, et])
				err["events_processed"] = processed
				if summary_mode:
					err["failed_at"] = event_result
				else:
					err["results"] = results
				_send_result(peer, id, err)
				return
			Input.parse_input_event(ev)
		results.append(event_result)
		processed += 1
		if delay_after_ms > 0:
			OS.delay_msec(delay_after_ms)

	if summary_mode:
		_send_result(peer, id, {"ok": true, "events_processed": processed,
			"total": total, "last_event": results.back()})
	else:
		_send_result(peer, id, {"ok": true, "events_processed": processed,
			"total": total, "results": results})


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
			var pos = event_data.get("position", null)
			if typeof(pos) == TYPE_DICTIONARY:
				mb.position = Vector2(float(pos.get("x", 0.0)), float(pos.get("y", 0.0)))
			mb.shift_pressed = bool(event_data.get("shift", false))
			mb.ctrl_pressed = bool(event_data.get("ctrl", false))
			mb.alt_pressed = bool(event_data.get("alt", false))
			mb.meta_pressed = bool(event_data.get("meta", false))
			return mb
		"mouse_motion":
			var mm := InputEventMouseMotion.new()
			var mpos = event_data.get("position", null)
			if typeof(mpos) == TYPE_DICTIONARY:
				mm.position = Vector2(float(mpos.get("x", 0.0)), float(mpos.get("y", 0.0)))
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
func _dispatch_click(event_data: Dictionary) -> void:
	var mb_press := InputEventMouseButton.new()
	mb_press.button_index = int(event_data.get("button_index", MOUSE_BUTTON_LEFT))
	mb_press.pressed = true
	var pos = event_data.get("position", null)
	if typeof(pos) == TYPE_DICTIONARY:
		mb_press.position = Vector2(float(pos.get("x", 0.0)), float(pos.get("y", 0.0)))
	mb_press.shift_pressed = bool(event_data.get("shift", false))
	mb_press.ctrl_pressed = bool(event_data.get("ctrl", false))
	mb_press.alt_pressed = bool(event_data.get("alt", false))
	mb_press.meta_pressed = bool(event_data.get("meta", false))
	Input.parse_input_event(mb_press)
	var click_delay := int(event_data.get("click_delay_ms", 50))
	OS.delay_msec(click_delay)
	var mb_release := InputEventMouseButton.new()
	mb_release.button_index = mb_press.button_index
	mb_release.pressed = false
	mb_release.position = mb_press.position
	mb_release.shift_pressed = mb_press.shift_pressed
	mb_release.ctrl_pressed = mb_press.ctrl_pressed
	mb_release.alt_pressed = mb_press.alt_pressed
	mb_release.meta_pressed = mb_press.meta_pressed
	Input.parse_input_event(mb_release)


# animation_player.control: drive an AnimationPlayer in the live SceneTree.
# Returns post-op state so the caller can confirm the seek/play landed
# without an extra round-trip.
func _cmd_animation_player_control(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, MCPError.make("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("node_path", ""))
	if path.is_empty():
		_send_result(peer, id, MCPError.make("INVALID_PARAMS", "missing node_path"))
		return
	var node = _resolve_runtime_node(path)
	if node == null:
		_send_result(peer, id, MCPError.make("NOT_FOUND", "node not found: %s" % path))
		return
	if not (node is AnimationPlayer):
		_send_result(peer, id, MCPError.make("INVALID_PARAMS", "node is not AnimationPlayer: %s (got %s)" % [path, node.get_class()]))
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
					_send_result(peer, id, MCPError.make("NOT_FOUND", "animation not found: %s" % anim))
					return
				ap.play(anim)
		"pause":
			ap.pause()
		"stop":
			ap.stop()
		"seek":
			ap.seek(float(params.get("time", 0.0)), true)
		_:
			_send_result(peer, id, MCPError.make("INVALID_PARAMS", "unknown op: %s (expected play|pause|stop|seek)" % op))
			return
	_send_result(peer, id, {
		"ok": true,
		"current_animation": String(ap.current_animation),
		"current_animation_position": ap.current_animation_position,
	})


# game.eval: DANGER — evaluates GDScript via Expression in the running game's
# context. Dual-gated: requires BOTH env var AND ProjectSettings flag.
# Defence-in-depth: even if the TS catalogue exposes the tool (env var set),
# this handler blocks unless PS is also on.
const _GAME_EVAL_LOG_CAP := 256

func _cmd_game_eval(peer: WebSocketPeer, id, params) -> void:
	if not MCPFeatureGate.is_enabled("game_eval"):
		_send_result(peer, id, MCPFeatureGate.disabled_error("game_eval"))
		return
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, MCPError.make("INVALID_PARAMS", "params must be an object"))
		return
	var code := str(params.get("code", ""))
	if code.is_empty():
		_send_result(peer, id, MCPError.make("INVALID_PARAMS", "missing code"))
		return

	var truncated := code.substr(0, _GAME_EVAL_LOG_CAP)
	if code.length() > _GAME_EVAL_LOG_CAP:
		truncated += "...[+%d chars]" % (code.length() - _GAME_EVAL_LOG_CAP)
	print("[MCPTools] game.eval: %s" % truncated)

	var scope_node: Node = null
	var scope_path := str(params.get("scope_path", ""))
	if scope_path.is_empty():
		var tree := get_tree()
		if tree == null or tree.root == null:
			_send_result(peer, id, MCPError.make("INTERNAL", "scene tree unavailable"))
			return
		scope_node = tree.root
	else:
		scope_node = _resolve_runtime_node(scope_path)
		if scope_node == null:
			_send_result(peer, id, MCPError.make("NOT_FOUND", "scope node not found: %s" % scope_path))
			return

	var expr := Expression.new()
	var parse_err := expr.parse(code, PackedStringArray())
	if parse_err != OK:
		_send_result(peer, id, MCPError.make("PARSE_ERROR", expr.get_error_text()))
		return
	var result = expr.execute([], scope_node, false)
	if expr.has_execute_failed():
		_send_result(peer, id, MCPError.make("EXECUTE_FAILED", expr.get_error_text()))
		return
	_send_result(peer, id, {"result": MCPCoerce.serialize_value(result)})
