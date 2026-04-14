@tool
extends Node
## Mode B — runtime-only WebSocket server that lets the MCP bridge reach
## into the LIVE game (not the edited scene). Registered as the
## `MCPRuntimeServer` autoload by plugin.gd (iter 10).
##
## The same script file is loaded at edit time (because it's in an
## @tool-enabled plugin) AND at runtime (because it's an autoload). We
## self-destruct in two cases:
##   1. Engine.is_editor_hint() — editor process loaded us, not the game.
##      Keeping a second WS listener on 9090 while editing is a bug.
##   2. not OS.is_debug_build() — release export. Mode B must NOT ship
##      to end users' shipped games. iter 10 Risk section calls this out
##      as security-critical.

const PORT := 9090
const BIND := "127.0.0.1"
const JSONRPC_VERSION := "2.0"

var _tcp_server: TCPServer = null
var _peers: Array[WebSocketPeer] = []


func _ready() -> void:
	# I11 + Risk — do not run in the editor process.
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
	# Debug-build gate: shipped (release) games must not listen on 9090.
	# Same quiescent approach — an empty Node at scene-tree root is cheaper
	# than the subtle edge cases of auto-freeing during SceneTree setup.
	if not OS.is_debug_build():
		set_process(false)
		return
	_start_server()


func _exit_tree() -> void:
	_stop_server()


func _start_server() -> void:
	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(PORT, BIND)
	if err != OK:
		push_error("[MCPRuntimeServer] failed to bind %s:%d (error %d)" % [BIND, PORT, err])
		_tcp_server = null
		return
	print("[MCPRuntimeServer] listening on %s:%d" % [BIND, PORT])


func _stop_server() -> void:
	for peer in _peers:
		if peer != null:
			peer.close(1000)
	_peers.clear()
	if _tcp_server != null:
		_tcp_server.stop()
		_tcp_server = null


func _process(_delta: float) -> void:
	if _tcp_server == null:
		return

	while _tcp_server.is_connection_available():
		var stream := _tcp_server.take_connection()
		var peer := WebSocketPeer.new()
		var accept_err := peer.accept_stream(stream)
		if accept_err != OK:
			push_warning("[MCPRuntimeServer] accept_stream failed (%d)" % accept_err)
			continue
		_peers.append(peer)

	var closed_peers: Array[WebSocketPeer] = []
	for peer in _peers:
		peer.poll()
		var state := peer.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			closed_peers.append(peer)
			continue
		if state != WebSocketPeer.STATE_OPEN:
			continue
		while peer.get_available_packet_count() > 0:
			var text := peer.get_packet().get_string_from_utf8()
			_handle_message(peer, text)

	for peer in closed_peers:
		_peers.erase(peer)


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


func _err(code: String, error: String) -> Dictionary:
	return {"code": code, "error": error}


func _serialize_value(v):
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return v
		_:
			return var_to_str(v)


# ---- Runtime command helpers (iter 10) ------------------------------------


func _cmd_runtime_screenshot(peer: WebSocketPeer, id) -> void:
	var viewport := get_viewport()
	if viewport == null:
		_send_result(peer, id, _err("INTERNAL", "no viewport available"))
		return

	# Wait for any queued draw calls to complete. Without this, get_image
	# can return an uninitialised texture on the first call after game
	# launch. Pattern matches godot-mcp-pro's frame capture setup.
	await RenderingServer.frame_post_draw

	var image := viewport.get_texture().get_image()
	if image == null:
		_send_result(peer, id, _err("INTERNAL", "viewport texture unavailable"))
		return

	var png_bytes := image.save_png_to_buffer()
	if png_bytes.is_empty():
		_send_result(peer, id, _err("INTERNAL", "save_png_to_buffer returned empty"))
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
		_send_result(peer, id, _err("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	if path.is_empty():
		_send_result(peer, id, _err("INVALID_PARAMS", "missing path"))
		return

	var tree := get_tree()
	if tree == null or tree.root == null:
		_send_result(peer, id, _err("INTERNAL", "scene tree unavailable"))
		return

	var node := tree.root.get_node_or_null(path)
	if node == null:
		_send_result(peer, id, _err("NOT_FOUND", "node not found: %s" % path))
		return

	var props := {}
	for prop in node.get_property_list():
		var usage: int = int(prop.get("usage", 0))
		# Only inspector-visible properties — avoids engine-internal state
		# and category headers. Iter 20 adds response-cap enforcement.
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		var pname := str(prop.get("name", ""))
		if pname.is_empty() or pname.begins_with("_"):
			continue
		props[pname] = _serialize_value(node.get(pname))

	_send_result(peer, id, {
		"name": String(node.name),
		"class": node.get_class(),
		"path": path,
		"properties": props,
	})


const _DEFAULT_LOG_LIMIT := 200


func _cmd_debugger_get_log(peer: WebSocketPeer, id, params) -> void:
	# MVP strategy: read Godot's default log file (`user://logs/godot.log`).
	# Godot 4 writes this automatically when `application/run/flush_stdout_on_print`
	# / logging are enabled (the defaults). Ring-buffer + EngineDebugger
	# hooks are deferred to iter 11+ if needed — the log file covers the
	# "what did the game print recently" workflow.
	var limit := _DEFAULT_LOG_LIMIT
	if typeof(params) == TYPE_DICTIONARY and params.has("limit"):
		limit = max(1, int(params.get("limit", _DEFAULT_LOG_LIMIT)))

	var log_path := "user://logs/godot.log"
	if not FileAccess.file_exists(log_path):
		_send_result(peer, id, {
			"lines": [],
			"count": 0,
			"total": 0,
			"path": log_path,
			"note": "log file not yet written — new game with no prints, or flush_stdout_on_print disabled",
		})
		return

	var file := FileAccess.open(log_path, FileAccess.READ)
	if file == null:
		var open_err := FileAccess.get_open_error()
		_send_result(peer, id, _err("READ_FAILED", "could not open %s (err %d)" % [log_path, open_err]))
		return
	var text := file.get_as_text()
	file.close()

	var all_lines := text.split("\n", false)
	var total := all_lines.size()
	var start := max(0, total - limit)
	var slice: Array = []
	for i in range(start, total):
		slice.append(all_lines[i])

	# TODO(iter-18): wrap `slice` in an <untrusted kind="game_log" source="godot">
	# envelope at the response layer. Do not envelope here — the plugin never
	# writes envelopes.
	_send_result(peer, id, {
		"lines": slice,
		"count": slice.size(),
		"total": total,
		"path": log_path,
	})


# ---- Tier 3 signal commands (iter 11 — Mode B mirror of editor handlers) --


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
		_send_result(peer, id, _err("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	var node = _resolve_runtime_node(path)
	if node == null:
		_send_result(peer, id, _err("NOT_FOUND", "node not found: %s" % path))
		return
	_send_result(peer, id, {"path": path, "signals": _signal_list_of(node)})


# Returns the same shape as editor _resolve_signal_pair — see mcp_server.gd.
# Duplicated here because runtime autoload can't see EditorInterface types;
# iter 16 SOLID split will hoist this into a shared module.
func _resolve_runtime_signal_pair(params) -> Dictionary:
	if typeof(params) != TYPE_DICTIONARY:
		return {"code": "INVALID_PARAMS", "error": "params must be an object"}
	var source_path := str(params.get("source_path", ""))
	var signal_name := str(params.get("signal", ""))
	var target_path := str(params.get("target_path", ""))
	var method_name := str(params.get("method", ""))
	if source_path.is_empty() or signal_name.is_empty() or target_path.is_empty() or method_name.is_empty():
		return {"code": "INVALID_PARAMS", "error": "source_path, signal, target_path, method are all required"}
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
		_send_result(peer, id, _err(str(r["code"]), str(r["error"])))
		return
	var source = r["source"]
	var callable: Callable = r["callable"]
	var signal_name: String = str(r["signal_name"])
	var source_path: String = str(r["source_path"])
	var target_path: String = str(r["target_path"])
	var method_name: String = str(r["method_name"])
	if source.is_connected(signal_name, callable):
		_send_result(peer, id, {
			"code": "ALREADY_EXISTS",
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
		_send_result(peer, id, _err("CONNECT_FAILED", "connect returned %d" % err))
		return
	_send_result(peer, id, {"ok": true})


func _cmd_signal_disconnect(peer: WebSocketPeer, id, params) -> void:
	var r := _resolve_runtime_signal_pair(params)
	if r.has("error"):
		_send_result(peer, id, _err(str(r["code"]), str(r["error"])))
		return
	var source = r["source"]
	var callable: Callable = r["callable"]
	var signal_name: String = str(r["signal_name"])
	if not source.is_connected(signal_name, callable):
		_send_result(peer, id, _err("NOT_FOUND", "no connection to disconnect"))
		return
	source.disconnect(signal_name, callable)
	_send_result(peer, id, {"ok": true})


func _coerce_value(v):
	# Mirror of mcp_server.gd._coerce_value for runtime signal.emit args.
	if typeof(v) != TYPE_DICTIONARY:
		return v
	match str(v.get("type", "")):
		"Vector2":
			return Vector2(float(v.get("x", 0.0)), float(v.get("y", 0.0)))
		"Vector3":
			return Vector3(float(v.get("x", 0.0)), float(v.get("y", 0.0)), float(v.get("z", 0.0)))
		"Color":
			return Color(float(v.get("r", 0.0)), float(v.get("g", 0.0)), float(v.get("b", 0.0)), float(v.get("a", 1.0)))
		_:
			return v


func _cmd_signal_emit(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, _err("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	var signal_name := str(params.get("signal", ""))
	if signal_name.is_empty():
		_send_result(peer, id, _err("INVALID_PARAMS", "missing signal"))
		return
	var node = _resolve_runtime_node(path)
	if node == null:
		_send_result(peer, id, _err("NOT_FOUND", "node not found: %s" % path))
		return
	if not node.has_signal(signal_name):
		_send_result(peer, id, _err("INVALID_PARAMS", "signal %s not on %s" % [signal_name, path]))
		return
	var raw_args = params.get("args", [])
	if typeof(raw_args) != TYPE_ARRAY:
		raw_args = []
	var coerced: Array = [signal_name]
	for a in raw_args:
		coerced.append(_coerce_value(a))
	node.callv("emit_signal", coerced)
	_send_result(peer, id, {"ok": true})


# ---- Tier 3 playtest commands (iter 12) -----------------------------------


# input.simulate: build an InputEvent from a JSON-friendly {event_type, event_data}
# pair and feed it through Input.parse_input_event so it dispatches as if it
# came from the OS. Limited to events the engine recognises — OS-level
# global hotkeys aren't reachable from inside a running Godot instance.
func _cmd_input_simulate(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, _err("INVALID_PARAMS", "params must be an object"))
		return
	var event_type := str(params.get("event_type", ""))
	var event_data: Dictionary = {}
	var raw_data = params.get("event_data", null)
	if typeof(raw_data) == TYPE_DICTIONARY:
		event_data = raw_data
	var ev: InputEvent = null
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
			ev = key_ev
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
			ev = mb
		"mouse_motion":
			var mm := InputEventMouseMotion.new()
			var mpos = event_data.get("position", null)
			if typeof(mpos) == TYPE_DICTIONARY:
				mm.position = Vector2(float(mpos.get("x", 0.0)), float(mpos.get("y", 0.0)))
			var rel = event_data.get("relative", null)
			if typeof(rel) == TYPE_DICTIONARY:
				mm.relative = Vector2(float(rel.get("x", 0.0)), float(rel.get("y", 0.0)))
			ev = mm
		"action":
			var act := InputEventAction.new()
			act.action = StringName(str(event_data.get("action", "")))
			act.pressed = bool(event_data.get("pressed", true))
			if event_data.has("strength"):
				act.strength = float(event_data.get("strength", 1.0))
			ev = act
		_:
			_send_result(peer, id, _err("INVALID_PARAMS", "unknown event_type: %s (expected key|mouse_button|mouse_motion|action)" % event_type))
			return
	Input.parse_input_event(ev)
	_send_result(peer, id, {"ok": true, "event_type": event_type})


# animation_player.control: drive an AnimationPlayer in the live SceneTree.
# Returns post-op state so the caller can confirm the seek/play landed
# without an extra round-trip.
func _cmd_animation_player_control(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, _err("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	if path.is_empty():
		_send_result(peer, id, _err("INVALID_PARAMS", "missing path"))
		return
	var node = _resolve_runtime_node(path)
	if node == null:
		_send_result(peer, id, _err("NOT_FOUND", "node not found: %s" % path))
		return
	if not (node is AnimationPlayer):
		_send_result(peer, id, _err("INVALID_PARAMS", "node is not AnimationPlayer: %s (got %s)" % [path, node.get_class()]))
		return
	var ap: AnimationPlayer = node
	var op := str(params.get("op", ""))
	match op:
		"play":
			var anim := str(params.get("animation", ""))
			if anim.is_empty():
				ap.play()
			else:
				if not ap.has_animation(anim):
					_send_result(peer, id, _err("NOT_FOUND", "animation not found: %s" % anim))
					return
				ap.play(anim)
		"pause":
			ap.pause()
		"stop":
			ap.stop()
		"seek":
			ap.seek(float(params.get("time", 0.0)), true)
		_:
			_send_result(peer, id, _err("INVALID_PARAMS", "unknown op: %s (expected play|pause|stop|seek)" % op))
			return
	_send_result(peer, id, {
		"ok": true,
		"current_animation": String(ap.current_animation),
		"current_animation_position": ap.current_animation_position,
	})


# game.eval: DANGER — evaluates GDScript via Expression in the running game's
# context. Even though the TS-side gate (GODOT_MCP_ALLOW_GAME_EVAL) keeps
# this absent from the MCP catalogue by default, the runtime command itself
# is always reachable on port 9090 from anything that can speak the JSON-RPC
# protocol. Iter 19 generalises this into a proper FeatureGate. For the
# iter 12-19 dogfood window we mitigate by:
#   - logging every invocation with a truncated code string to stdout so
#     accidental use is auditable.
#   - returning EXECUTE_FAILED via Expression's error path (no stack trace
#     leak to the bridge).
const _GAME_EVAL_LOG_CAP := 256


func _cmd_game_eval(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, _err("INVALID_PARAMS", "params must be an object"))
		return
	var code := str(params.get("code", ""))
	if code.is_empty():
		_send_result(peer, id, _err("INVALID_PARAMS", "missing code"))
		return

	var truncated := code.substr(0, _GAME_EVAL_LOG_CAP)
	if code.length() > _GAME_EVAL_LOG_CAP:
		truncated += "...[+%d chars]" % (code.length() - _GAME_EVAL_LOG_CAP)
	print("[game.eval] %s" % truncated)

	var scope_node: Node = null
	var scope_path := str(params.get("scope_path", ""))
	if scope_path.is_empty():
		var tree := get_tree()
		if tree == null or tree.root == null:
			_send_result(peer, id, _err("INTERNAL", "scene tree unavailable"))
			return
		scope_node = tree.root
	else:
		scope_node = _resolve_runtime_node(scope_path)
		if scope_node == null:
			_send_result(peer, id, _err("NOT_FOUND", "scope node not found: %s" % scope_path))
			return

	var expr := Expression.new()
	var parse_err := expr.parse(code, PackedStringArray())
	if parse_err != OK:
		_send_result(peer, id, _err("PARSE_ERROR", expr.get_error_text()))
		return
	var result = expr.execute([], scope_node, false)
	if expr.has_execute_failed():
		_send_result(peer, id, _err("EXECUTE_FAILED", expr.get_error_text()))
		return
	_send_result(peer, id, {"result": _serialize_value(result)})
