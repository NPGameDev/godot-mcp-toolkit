@tool
extends Node

const PORT := 6505
const BIND := "127.0.0.1"
const JSONRPC_VERSION := "2.0"
# iter 13: throttle re-listen retries to avoid log spam when the port is
# briefly held by another process (e.g. a second editor instance, a stale
# debugger). 60 frames ≈ 1s at 60fps; the bridge's reconnect backoff sits
# on the same order so we don't pile retries on top of the bridge's.
const _RELISTEN_FRAME_INTERVAL := 60
# iter 13c: poll TCPServer/WebSocket peers every Nth frame instead of every
# frame. Godot 4.4.1 has a race between our per-frame poll and the main-loop
# work triggered by FileSystem-dock interactions; shrinking our collision
# window ~4x (15Hz vs 60Hz) drops the reproducibility threshold enough that
# incidental clicks stop crashing the editor in smoke + dogfood usage.
# Tune lower if latency regresses noticeably; 4 frames ≈ 67ms at 60fps.
# (Trial with interval=2 + `call_deferred` dispatch crashed at run 4 of 20
# in dirty-stress testing — the deferral didn't materially help and the
# interval reduction halved the protective margin. Reverted to interval=4.)
const _POLL_FRAME_INTERVAL := 4

var _tcp_server: TCPServer = null
var _peers: Array[WebSocketPeer] = []
var _relisten_countdown := 0
# Tracks the current run of consecutive _try_listen() failures so we can log
# the first one (with a hint), stay silent during retries, and announce the
# recovery with the attempt count. Reset on every successful listen.
var _consecutive_failures := 0
# iter 13c: counter for _POLL_FRAME_INTERVAL frame-skip.
var _poll_frame_counter := 0
# iter 15e: captured at start() so editor.get_console's log-file selection
# heuristic can prefer post-boot logs over stale rotated ones.
var _plugin_boot_time: int = 0


func start() -> void:
	_plugin_boot_time = int(Time.get_unix_time_from_system())
	# Initial listen attempt. _process picks up the retry slack on failure
	# (iter 13) — start() never blocks plugin enable on a transient bind
	# error; it just kicks off the loop.
	_relisten_countdown = 0
	_try_listen()


func stop() -> void:
	for peer in _peers:
		if peer != null:
			peer.close(1000)
	_peers.clear()
	if _tcp_server != null:
		_tcp_server.stop()
		_tcp_server = null
	_relisten_countdown = 0
	_consecutive_failures = 0
	print("[MCPServer] stopped")


# iter 13: idempotent re-listen. Called from start() and from _process when
# the TCPServer falls out of the listening state (port stolen, manual stop,
# etc.). Frame-throttled via _relisten_countdown so failures don't spam.
func _try_listen() -> void:
	if _relisten_countdown > 0:
		_relisten_countdown -= 1
		return
	if _tcp_server == null:
		_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(PORT, BIND)
	if err == OK:
		if _consecutive_failures > 0:
			print("[MCPServer] listening on %s:%d (recovered after %d failed attempts)" % [BIND, PORT, _consecutive_failures])
		else:
			print("[MCPServer] listening on %s:%d" % [BIND, PORT])
		_consecutive_failures = 0
		_relisten_countdown = 0
		return
	_consecutive_failures += 1
	# Log only the FIRST failure of a streak — silent retries afterward
	# until either success (recovery message above) or the user intervenes.
	# Avoids the iter-13 pattern of one push_warning per second for the
	# entire duration a zombie process holds the port.
	if _consecutive_failures == 1:
		# err 22 = ERR_ALREADY_IN_USE — usually a zombie Godot process from a
		# prior crash still holding the port. Surface that so the user doesn't
		# have to look up Godot error codes; a stale process check in Task
		# Manager / netstat is the typical fix.
		var hint := ""
		if err == ERR_ALREADY_IN_USE:
			hint = " (ERR_ALREADY_IN_USE — likely a stale Godot/MCP process holding the port; will retry silently every ~1s, watch for the listening / recovered message)"
		push_warning("[MCPServer] bind %s:%d failed (err %d)%s" % [BIND, PORT, err, hint])
	# Discard the (potentially-stuck) TCPServer instance so the next retry
	# allocates a fresh one. Without this, certain Godot-internal latch
	# states keep returning ERR_ALREADY_IN_USE even after the actual port
	# is freed — exactly the regression that made iter-13's retry loop
	# need a manual plugin disable+re-enable to recover (the disable path
	# happens to do the same fresh-allocate via stop() + null + start()).
	_tcp_server.stop()
	_tcp_server = null
	_relisten_countdown = _RELISTEN_FRAME_INTERVAL


func _process(_delta: float) -> void:
	# iter 13c: frame-skip to poll at ~15Hz. Race with editor main-loop work
	# on FS dock interactions (Godot 4.4.1) is dramatically less reproducible
	# when we're not fighting for main-thread cycles every frame. Re-listen
	# retries still respect _RELISTEN_FRAME_INTERVAL below, so a missed
	# listen-check here just delays recovery by a few frames at worst.
	_poll_frame_counter += 1
	if _poll_frame_counter < _POLL_FRAME_INTERVAL:
		return
	_poll_frame_counter = 0

	# iter 13: keep the listener up across editor cycles. If start() failed
	# transiently or the port dropped, retry here on the throttle.
	if _tcp_server == null or not _tcp_server.is_listening():
		_try_listen()
		return

	while _tcp_server.is_connection_available():
		var stream := _tcp_server.take_connection()
		var peer := WebSocketPeer.new()
		var accept_err := peer.accept_stream(stream)
		if accept_err != OK:
			push_warning("[MCPServer] accept_stream failed (%d)" % accept_err)
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
	# Godot's JSON parser returns every number as float; coerce whole-float ids
	# back to int so {"id": 1} round-trips as {"id": 1}, not {"id": 1.0}.
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
		"scene.get_tree":
			_cmd_scene_get_tree(peer, id)
		"scene.create_node":
			_cmd_scene_create_node(peer, id, params)
		"scene.delete_node":
			_cmd_scene_delete_node(peer, id, params)
		"scene.create":
			_cmd_scene_create(peer, id, params)
		"scene.delete":
			_cmd_scene_delete(peer, id, params)
		"script.delete":
			_cmd_script_delete(peer, id, params)
		"node.set_property":
			_cmd_node_set_property(peer, id, params)
		"node.get_property":
			_cmd_node_get_property(peer, id, params)
		"script.read":
			_cmd_script_read(peer, id, params)
		"script.write":
			_cmd_script_write(peer, id, params)
		"editor.get_errors":
			_cmd_editor_get_errors(peer, id, params)
		"editor.save_scene":
			_cmd_editor_save_scene(peer, id, params)
		"editor.screenshot":
			_cmd_editor_screenshot(peer, id, params)
		"editor.reload_scripts":
			_cmd_editor_reload_scripts(peer, id)
		"scene.open":
			_cmd_scene_open(peer, id, params)
		"project.get_settings":
			_cmd_project_get_settings(peer, id, params)
		"signal.list":
			_cmd_signal_list(peer, id, params)
		"signal.connect":
			_cmd_signal_connect(peer, id, params)
		"signal.disconnect":
			_cmd_signal_disconnect(peer, id, params)
		"signal.emit":
			_cmd_signal_emit(peer, id, params)
		"resource.load":
			_cmd_resource_load(peer, id, params)
		"resource.create":
			_cmd_resource_create(peer, id, params)
		"resource.save":
			_cmd_resource_save(peer, id, params)
		"resource.delete":
			_cmd_resource_delete(peer, id, params)
		"folder.create":
			_cmd_folder_create(peer, id, params)
		"folder.delete":
			_cmd_folder_delete(peer, id, params)
		"node.get_property_list":
			_cmd_node_get_property_list(peer, id, params)
		"scene.diff":
			_cmd_scene_diff(peer, id, params)
		"game.start":
			_cmd_game_start(peer, id, params)
		"game.stop":
			_cmd_game_stop(peer, id, params)
		"scene.instantiate":
			_cmd_scene_instantiate(peer, id, params)
		"node.call_method":
			_cmd_node_call_method(peer, id, params)
		"project.set_setting":
			_cmd_project_set_setting(peer, id, params)
		"input_map.add_action":
			_cmd_input_map_add_action(peer, id, params)
		"input_map.action_add_event":
			_cmd_input_map_action_add_event(peer, id, params)
		"input_map.action_remove_event":
			_cmd_input_map_action_remove_event(peer, id, params)
		"input_map.remove_action":
			_cmd_input_map_remove_action(peer, id, params)
		"animation.add_key":
			_cmd_animation_add_key(peer, id, params)
		"animation.remove_key":
			_cmd_animation_remove_key(peer, id, params)
		"animation.get_keys":
			_cmd_animation_get_keys(peer, id, params)
		"tilemap.set_cells":
			_cmd_tilemap_set_cells(peer, id, params)
		"editor.screenshot_node":
			_cmd_editor_screenshot_node(peer, id, params)
		"asset.list":
			_cmd_asset_list(peer, id, params)
		"asset.get_dependencies":
			_cmd_asset_get_dependencies(peer, id, params)
		"editor.get_console":
			_cmd_editor_get_console(peer, id, params)
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


# ---- Scene / node command helpers (iter 03) -------------------------------
#
# Domain errors flow back inside the JSON-RPC `result` payload as
# { code: "UPPER_SNAKE", error: "human message" } — distinct from the
# envelope `error` field used for transport-level failures (parse,
# method-not-found, etc.). The TS bridge (iter 05+) maps these to MCP
# isError=true responses per I1.


func _get_edited_root() -> Node:
	return EditorInterface.get_edited_scene_root()


# I1 error contract (iter 14). Canonical list of MCP tool-error codes —
# UPPER_SNAKE_CASE. Must stay in sync with src/types.ts `ErrorCode` union
# (server-repo) and the reference table in CLAUDE.md. Iter 16 (SOLID
# split) hoists this and `mcp_error` into a shared module; duplicated
# with mcp_runtime_server.gd for now to keep each file self-contained.
# ALREADY_EXISTS is listed for completeness even though I3 treats it as a
# non-error success payload (it travels in a happy-path dict, NOT through
# mcp_error). INVALID_PARAMS is JSON-RPC params-shape (e.g. missing
# required field); INVALID_CLASS is ClassDB rejection; INVALID_PATH is
# semantic path refusal (e.g. deleting scene root) distinct from
# PATH_DENIED (prefix / sandbox refusal — full form in iter 18).
const MCP_ERROR_CODES := [
	"ALREADY_EXISTS",
	"ALREADY_PLAYING",
	"CONNECT_FAILED",
	"CREATE_DIR_FAILED",
	"DELETE_FAILED",
	"DIR_NOT_EMPTY",
	"DISCONNECTED",
	"EDITED_SCENE",
	"EXECUTE_FAILED",
	"FEATURE_DISABLED",
	"FILE_TOO_LARGE",
	"FILESYSTEM_NOT_READY",
	"FOLDER_PROTECTED",
	"GAME_NOT_RUNNING",
	"INTERNAL",
	"INVALID_CLASS",
	"INVALID_METHOD",
	"INVALID_PARAMS",
	"INVALID_PATH",
	"LOAD_FAILED",
	"LOG_UNAVAILABLE",
	"NO_SCENE",
	"NOT_A_RESOURCE",
	"NOT_FOUND",
	"PACK_FAILED",
	"PARENT_NOT_FOUND",
	"PARSE_ERROR",
	"PATH_DENIED",
	"PATH_IN_USE",
	"READ_FAILED",
	"SAVE_FAILED",
	"TIMEOUT",
	"WRITE_FAILED",
]


# mcp_error — canonical failure envelope for tool responses (I1). Returned
# inside the JSON-RPC `result` payload (NOT the envelope `error` field —
# that's for transport-level failures). The TS bridge (server-repo)
# translates `success: false` into an MCP `isError: true` response.
static func mcp_error(code: String, message: String) -> Dictionary:
	return {"success": false, "error": message, "code": code}


# Returned paths are *relative to the edited scene root* — keeps responses
# compact (no editor-internal /@EditorNode@.../@SubViewport@.../... leak) and
# round-trips cleanly because Node.get_node_or_null() accepts relative paths.
# The root itself serialises as "." per NodePath convention.
func _path_in_scene(scene_root: Node, node: Node) -> String:
	return str(scene_root.get_path_to(node))


func _cmd_scene_get_tree(peer: WebSocketPeer, id) -> void:
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return
	# TODO(iter-18): wrap this tree in an <untrusted kind="scene_tree" source="godot"> envelope at the response layer.
	_send_result(peer, id, _walk_tree(root, root))


func _walk_tree(node: Node, scene_root: Node) -> Dictionary:
	var children: Array = []
	for child in node.get_children():
		children.append(_walk_tree(child, scene_root))
	return {
		"name": String(node.name),
		"class": node.get_class(),
		"path": _path_in_scene(scene_root, node),
		"children": children,
	}


func _cmd_scene_create_node(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return

	var cls := str(params.get("class_name", ""))
	var parent_path := str(params.get("parent", ""))
	# TODO(iter-18): filter `parent_path` through FileGuard.resolve_safe.
	var requested_name := str(params.get("name", cls))

	if cls.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing class_name"))
		return
	if not ClassDB.class_exists(cls):
		_send_result(peer, id, mcp_error("INVALID_CLASS", "unknown class: %s" % cls))
		return
	if not ClassDB.can_instantiate(cls):
		_send_result(peer, id, mcp_error("INVALID_CLASS", "class is not instantiable (abstract, virtual, or editor-only): %s" % cls))
		return
	if not ClassDB.is_parent_class(cls, "Node"):
		_send_result(peer, id, mcp_error("INVALID_CLASS", "not a Node subclass: %s" % cls))
		return

	var parent_node := root.get_node_or_null(parent_path) if not parent_path.is_empty() else root
	if parent_node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "parent not found: %s" % parent_path))
		return

	# I3 idempotency (iter 15 status discriminator): same-name child already
	# present → non-error success with status: "returned"; fresh creates emit
	# status: "created". `code` lives on error payloads only now.
	var existing := parent_node.get_node_or_null(NodePath(requested_name))
	if existing != null:
		_send_result(peer, id, {"success": true, "status": "returned", "path": _path_in_scene(root, existing)})
		return

	var instance = ClassDB.instantiate(cls)
	if instance == null or not (instance is Node):
		_send_result(peer, id, mcp_error("INVALID_CLASS", "instantiate failed: %s" % cls))
		return

	instance.name = requested_name
	parent_node.add_child(instance)
	instance.set_owner(root)
	_send_result(peer, id, {"success": true, "status": "created", "path": _path_in_scene(root, instance)})


func _cmd_scene_delete_node(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return

	var path := str(params.get("path", ""))
	# TODO(iter-18): filter `path` through FileGuard.resolve_safe.
	if path.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing path"))
		return

	var node := root.get_node_or_null(path)
	if node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "node not found: %s" % path))
		return
	if node == root:
		_send_result(peer, id, mcp_error("INVALID_PATH", "cannot delete edited scene root"))
		return

	# Editor-safe deletion via UndoRedo. Pattern matches godot-mcp-pro and
	# godotiq: the node is detached from the tree by the action, but
	# add_undo_reference(node) keeps a reference alive in the undo history,
	# so the editor's SceneTreeDock / Inspector never see a dangling pointer.
	# Plain queue_free() or synchronous free() on an editor-owned node is a
	# SIGSEGV hazard on Godot 4.4.1 Windows when any FileAccess write follows.
	var parent := node.get_parent()
	if parent == null:
		_send_result(peer, id, mcp_error("INTERNAL", "node has no parent: %s" % path))
		return
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("MCP: delete %s" % path)
	undo_redo.add_do_method(parent, "remove_child", node)
	undo_redo.add_undo_method(parent, "add_child", node)
	undo_redo.add_undo_method(node, "set_owner", root)
	undo_redo.add_undo_reference(node)
	undo_redo.commit_action()
	_send_result(peer, id, {"ok": true, "path": path})


func _cmd_node_set_property(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return

	var path := str(params.get("path", ""))
	var property := str(params.get("property", ""))
	var raw_value = params.get("value", null)
	# TODO(iter-18): filter `path` through FileGuard.resolve_safe.

	if path.is_empty() or property.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing path or property"))
		return

	var node := root.get_node_or_null(path)
	if node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "node not found: %s" % path))
		return

	# iter 15c: `{type:"Resource",path}` refs are load-bearing for node-level
	# properties (a null texture renders as a pink checkerboard at runtime);
	# surface a hard LOAD_FAILED instead of silently setting null.
	var missing := _check_resource_paths(raw_value)
	if missing != "":
		_send_result(peer, id, mcp_error("LOAD_FAILED", "failed to load resource at %s; verify the path or use resource.create to create it first" % missing))
		return

	var coerced = _coerce_value(raw_value)
	node.set(property, coerced)
	_send_result(peer, id, {"ok": true})


func _cmd_node_get_property(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return

	var path := str(params.get("path", ""))
	var property := str(params.get("property", ""))
	# TODO(iter-18): filter `path` through FileGuard.resolve_safe.

	if path.is_empty() or property.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing path or property"))
		return

	var node := root.get_node_or_null(path)
	if node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "node not found: %s" % path))
		return

	_send_result(peer, id, {"value": _serialize_value(node.get(property))})


func _coerce_value(v):
	# Dict-wrapped engine types: {type:"Vector2",x:..,y:..} -> Vector2(..).
	# Iter 15c: extended to Vector4/Rect2/NodePath and `{type:"Resource",path}`
	# (loaded via ResourceLoader — null on miss; callers gate with
	# `_check_resource_paths` before applying). Iter 15d: Vector2i/Vector3i/
	# Rect2i/Transform2D/Transform3D for animation keyframes + tilemap coords.
	# Arrays recurse so method args like `[{type:"Resource",...}, 42]` coerce
	# element-by-element. Plain JSON primitives / non-tagged dicts pass through
	# unchanged. Inverse symmetry lives in `_serialize_value` — keep tags +
	# fields aligned across edits or round-trip breaks.
	if typeof(v) == TYPE_ARRAY:
		var out: Array = []
		for el in v:
			out.append(_coerce_value(el))
		return out
	if typeof(v) != TYPE_DICTIONARY:
		return v
	match str(v.get("type", "")):
		"Resource":
			# TODO(iter-18): route path through FileGuard.resolve_safe.
			var p := str(v.get("path", ""))
			if p.is_empty():
				return null
			return ResourceLoader.load(p)
		"Vector2":
			return Vector2(float(v.get("x", 0.0)), float(v.get("y", 0.0)))
		"Vector3":
			return Vector3(float(v.get("x", 0.0)), float(v.get("y", 0.0)), float(v.get("z", 0.0)))
		"Vector4":
			return Vector4(float(v.get("x", 0.0)), float(v.get("y", 0.0)), float(v.get("z", 0.0)), float(v.get("w", 0.0)))
		"Vector2i":
			return Vector2i(int(v.get("x", 0)), int(v.get("y", 0)))
		"Vector3i":
			return Vector3i(int(v.get("x", 0)), int(v.get("y", 0)), int(v.get("z", 0)))
		"Color":
			return Color(float(v.get("r", 0.0)), float(v.get("g", 0.0)), float(v.get("b", 0.0)), float(v.get("a", 1.0)))
		"Rect2":
			return Rect2(float(v.get("x", 0.0)), float(v.get("y", 0.0)), float(v.get("w", 0.0)), float(v.get("h", 0.0)))
		"Rect2i":
			return Rect2i(int(v.get("x", 0)), int(v.get("y", 0)), int(v.get("w", 0)), int(v.get("h", 0)))
		"Transform2D":
			# Layout: { type, x_axis:{x,y}, y_axis:{x,y}, origin:{x,y} }.
			var x_axis: Dictionary = v.get("x_axis", {}) if typeof(v.get("x_axis", {})) == TYPE_DICTIONARY else {}
			var y_axis: Dictionary = v.get("y_axis", {}) if typeof(v.get("y_axis", {})) == TYPE_DICTIONARY else {}
			var origin2: Dictionary = v.get("origin", {}) if typeof(v.get("origin", {})) == TYPE_DICTIONARY else {}
			return Transform2D(
				Vector2(float(x_axis.get("x", 1.0)), float(x_axis.get("y", 0.0))),
				Vector2(float(y_axis.get("x", 0.0)), float(y_axis.get("y", 1.0))),
				Vector2(float(origin2.get("x", 0.0)), float(origin2.get("y", 0.0))),
			)
		"Transform3D":
			# Layout: { type, basis:{ x:{x,y,z}, y:{x,y,z}, z:{x,y,z} }, origin:{x,y,z} }.
			var basis_d: Dictionary = v.get("basis", {}) if typeof(v.get("basis", {})) == TYPE_DICTIONARY else {}
			var bx: Dictionary = basis_d.get("x", {}) if typeof(basis_d.get("x", {})) == TYPE_DICTIONARY else {}
			var by: Dictionary = basis_d.get("y", {}) if typeof(basis_d.get("y", {})) == TYPE_DICTIONARY else {}
			var bz: Dictionary = basis_d.get("z", {}) if typeof(basis_d.get("z", {})) == TYPE_DICTIONARY else {}
			var origin3: Dictionary = v.get("origin", {}) if typeof(v.get("origin", {})) == TYPE_DICTIONARY else {}
			var basis := Basis(
				Vector3(float(bx.get("x", 1.0)), float(bx.get("y", 0.0)), float(bx.get("z", 0.0))),
				Vector3(float(by.get("x", 0.0)), float(by.get("y", 1.0)), float(by.get("z", 0.0))),
				Vector3(float(bz.get("x", 0.0)), float(bz.get("y", 0.0)), float(bz.get("z", 1.0))),
			)
			return Transform3D(basis, Vector3(float(origin3.get("x", 0.0)), float(origin3.get("y", 0.0)), float(origin3.get("z", 0.0))))
		"NodePath":
			return NodePath(str(v.get("path", "")))
		_:
			return v


# Pre-coercion gate: recursively scan for `{type:"Resource",path:...}` entries
# and return the first path whose `ResourceLoader.load` returns null (file
# missing, corrupt, or non-res://). Empty string means "all Resource refs
# resolve". Callers translate a non-empty return into LOAD_FAILED (node.*)
# or a warnings[] entry (resource.*).
# TODO(iter-18): route each path through FileGuard.resolve_safe.
func _check_resource_paths(v) -> String:
	if typeof(v) == TYPE_DICTIONARY:
		if str(v.get("type", "")) == "Resource":
			var p := str(v.get("path", ""))
			if p.is_empty() or ResourceLoader.load(p) == null:
				return p if not p.is_empty() else "<empty path>"
		return ""
	if typeof(v) == TYPE_ARRAY:
		for el in v:
			var miss := _check_resource_paths(el)
			if miss != "":
				return miss
	return ""


func _serialize_value(v):
	# JSON-native scalars pass through. Godot typed values emit structured
	# dicts symmetric with `_coerce_value`'s type tags so JSON round-trips
	# cleanly. Node refs stringify to their scene-tree path; Resource refs
	# emit `{type:"Resource",path,class}`; Object refs that are neither → a
	# literal `"<unserialisable>"`. Iter 15d adds Vector2i/Vector3i/Rect2i/
	# Transform2D/Transform3D so animation.get_keys + node.get_property of
	# tilemap coords / 2D/3D transforms round-trip through `_coerce_value`.
	match typeof(v):
		TYPE_NIL:
			return null
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return v
		TYPE_VECTOR2:
			return {"type": "Vector2", "x": v.x, "y": v.y}
		TYPE_VECTOR3:
			return {"type": "Vector3", "x": v.x, "y": v.y, "z": v.z}
		TYPE_VECTOR4:
			return {"type": "Vector4", "x": v.x, "y": v.y, "z": v.z, "w": v.w}
		TYPE_VECTOR2I:
			return {"type": "Vector2i", "x": v.x, "y": v.y}
		TYPE_VECTOR3I:
			return {"type": "Vector3i", "x": v.x, "y": v.y, "z": v.z}
		TYPE_COLOR:
			return {"type": "Color", "r": v.r, "g": v.g, "b": v.b, "a": v.a}
		TYPE_RECT2:
			return {"type": "Rect2", "x": v.position.x, "y": v.position.y, "w": v.size.x, "h": v.size.y}
		TYPE_RECT2I:
			return {"type": "Rect2i", "x": v.position.x, "y": v.position.y, "w": v.size.x, "h": v.size.y}
		TYPE_TRANSFORM2D:
			return {
				"type": "Transform2D",
				"x_axis": {"x": v.x.x, "y": v.x.y},
				"y_axis": {"x": v.y.x, "y": v.y.y},
				"origin": {"x": v.origin.x, "y": v.origin.y},
			}
		TYPE_TRANSFORM3D:
			return {
				"type": "Transform3D",
				"basis": {
					"x": {"x": v.basis.x.x, "y": v.basis.x.y, "z": v.basis.x.z},
					"y": {"x": v.basis.y.x, "y": v.basis.y.y, "z": v.basis.y.z},
					"z": {"x": v.basis.z.x, "y": v.basis.z.y, "z": v.basis.z.z},
				},
				"origin": {"x": v.origin.x, "y": v.origin.y, "z": v.origin.z},
			}
		TYPE_NODE_PATH:
			return {"type": "NodePath", "path": str(v)}
		TYPE_STRING_NAME:
			return str(v)
		TYPE_ARRAY:
			var arr_out: Array = []
			for el in v:
				arr_out.append(_serialize_value(el))
			return arr_out
		TYPE_DICTIONARY:
			var dict_out: Dictionary = {}
			for k in v.keys():
				dict_out[str(k)] = _serialize_value(v[k])
			return dict_out
		TYPE_OBJECT:
			if v == null:
				return null
			if v is Node:
				return str((v as Node).get_path())
			if v is Resource:
				var r := v as Resource
				return {"type": "Resource", "path": r.resource_path, "class": r.get_class()}
			return "<unserialisable>"
		_:
			return var_to_str(v)


# ---- Script / editor command helpers (iter 04) ----------------------------


func _cmd_script_read(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	# TODO(iter-18): replace this prefix check with FileGuard.resolve_safe(path).
	if not path.begins_with("res://"):
		_send_result(peer, id, mcp_error("PATH_DENIED", "path must start with res://: %s" % path))
		return
	if not FileAccess.file_exists(path):
		_send_result(peer, id, mcp_error("NOT_FOUND", "file not found: %s" % path))
		return
	var content := FileAccess.get_file_as_string(path)
	var open_err := FileAccess.get_open_error()
	if open_err != OK:
		_send_result(peer, id, mcp_error("READ_FAILED", "FileAccess error %d reading %s" % [open_err, path]))
		return
	# TODO(iter-18): wrap content in <untrusted kind="script_content" source="<path>"> envelope.
	_send_result(peer, id, {"content": content})


func _cmd_script_write(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	# TODO(iter-18): replace this prefix check with FileGuard.resolve_safe(path).
	if not path.begins_with("res://"):
		_send_result(peer, id, mcp_error("PATH_DENIED", "path must start with res://: %s" % path))
		return
	# Iter 15b: extension allowlist — symmetric with script.delete. Prevents
	# using script.write as a catch-all file writer (e.g. stuffing a .tscn
	# under a misleading name). Shaders are text files so they route through
	# the same handler; a separate shader.* tool would be surface for no gain.
	var write_ext := path.get_extension().to_lower()
	if not (write_ext in ["gd", "cs", "gdshader", "gdshaderinc"]):
		_send_result(peer, id, mcp_error("INVALID_PATH", "script.write only writes .gd, .cs, .gdshader, or .gdshaderinc files (got %s); use scene.create for .tscn, resource.create for .tres/.res, or a different tool for other file types" % path))
		return
	if not params.has("content"):
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing content"))
		return
	var content := str(params.get("content", ""))
	# I5: never wrap user-destination content — `content` is written to disk verbatim.

	# Capture prior state so the UndoRedo undo path is correct. If the file
	# exists we read-and-restore; if it's new, undo deletes. FileAccess reads
	# can fail — surface that instead of silently losing undo coverage.
	var existed := FileAccess.file_exists(path)
	var prior_content := ""
	if existed:
		prior_content = FileAccess.get_file_as_string(path)
		var read_err := FileAccess.get_open_error()
		if read_err != OK:
			_send_result(peer, id, mcp_error("READ_FAILED", "could not read prior content of %s (err %d)" % [path, read_err]))
			return

	# Attempt the write up-front so failures surface as WRITE_FAILED instead of
	# silently landing as a push_warning during UndoRedo's deferred commit.
	var write_err := _write_file_raw(path, content)
	if write_err != OK:
		_send_result(peer, id, mcp_error("WRITE_FAILED", "could not open %s for write (err %d)" % [path, write_err]))
		return

	# Wire the already-performed write into the editor's UndoRedo history so
	# Ctrl-Z restores prior state (or deletes, for new files). `do_method` is
	# a no-op replay of the write we just committed; `undo_method` reverses it.
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("MCP script_write: %s" % path)
	undo_redo.add_do_method(self, "_write_file_silent", path, content)
	if existed:
		undo_redo.add_undo_method(self, "_write_file_silent", path, prior_content)
	else:
		undo_redo.add_undo_method(self, "_delete_file_silent", path)
	# execute=false so UndoRedo doesn't double-apply the do_method we already ran.
	undo_redo.commit_action(false)

	var bytes_written := content.to_utf8_buffer().size()
	_send_result(peer, id, {"ok": true, "bytes": bytes_written, "undoable": true})


func _write_file_raw(path: String, content: String) -> int:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(content)
	file.close()
	return OK


func _write_file_silent(path: String, content: String) -> void:
	var err := _write_file_raw(path, content)
	if err != OK:
		push_warning("[MCPServer] UndoRedo write of %s failed (err %d)" % [path, err])


func _delete_file_silent(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var err := DirAccess.remove_absolute(path)
	if err != OK:
		push_warning("[MCPServer] UndoRedo delete of %s failed (err %d)" % [path, err])


# Delegates to editor.get_console with level_filter=['error'] (iter 15e).
# For broader output — warnings, info, import logs — call editor.get_console directly.
func _cmd_editor_get_errors(peer: WebSocketPeer, id, params) -> void:
	var limit: int = 50
	if typeof(params) == TYPE_DICTIONARY:
		limit = int(params.get("limit", 50))
	var result := _read_console_log(limit, ["error"], -1)
	if result.get("success", false) == false:
		_send_result(peer, id, result)
		return
	# Wrap in the legacy editor.get_errors response shape for backwards compat
	# with iter-04/10's contract: { success, errors: [...], count }.
	_send_result(peer, id, {
		"success": true,
		"errors": result.get("entries", []),
		"count": result.get("count", 0),
	})


func _cmd_editor_save_scene(peer: WebSocketPeer, id, params) -> void:
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return
	var save_path := ""
	if typeof(params) == TYPE_DICTIONARY:
		save_path = str(params.get("path", ""))
	if save_path.is_empty():
		var err := EditorInterface.save_scene()
		if err != OK:
			_send_result(peer, id, mcp_error("SAVE_FAILED", "EditorInterface.save_scene returned %d" % err))
			return
	else:
		# TODO(iter-18): validate save_path through FileGuard.resolve_safe.
		if not save_path.begins_with("res://"):
			_send_result(peer, id, mcp_error("PATH_DENIED", "save path must start with res://: %s" % save_path))
			return
		EditorInterface.save_scene_as(save_path)
		# save_scene_as returns void in 4.4; verify by existence.
		if not FileAccess.file_exists(save_path):
			_send_result(peer, id, mcp_error("SAVE_FAILED", "save_scene_as did not produce %s" % save_path))
			return
	_send_result(peer, id, {"ok": true, "path": root.scene_file_path})


func _cmd_editor_screenshot(peer: WebSocketPeer, id, params) -> void:
	# Return PNG bytes inline as base64 — pattern from godot-mcp-pro / godotiq.
	# Avoids cross-process user:// path resolution and FS races: the TS bridge
	# never touches disk for this tool.
	#
	# Optional `save_path` persists the PNG to res:// for later reference
	# (e.g. commit-to-repo workflows). Inline bytes are ALWAYS returned —
	# save_path is additive, not a mode switch.
	var save_path := ""
	if typeof(params) == TYPE_DICTIONARY:
		save_path = str(params.get("save_path", ""))

	var viewport: SubViewport = EditorInterface.get_editor_viewport_2d()
	if viewport == null:
		viewport = EditorInterface.get_editor_viewport_3d(0)
	if viewport == null:
		_send_result(peer, id, mcp_error("INTERNAL", "no editor viewport available"))
		return
	var image := viewport.get_texture().get_image()
	if image == null:
		_send_result(peer, id, mcp_error("INTERNAL", "viewport texture unavailable (nothing rendered yet?)"))
		return

	var png_bytes := image.save_png_to_buffer()
	if png_bytes.is_empty():
		_send_result(peer, id, mcp_error("INTERNAL", "save_png_to_buffer returned empty"))
		return

	var persisted_path := ""
	if not save_path.is_empty():
		# TODO(iter-18): replace this res://-only prefix check with
		# FileGuard.resolve_safe(save_path). FileGuard also needs to handle the
		# res:// vs user:// distinction explicitly — today user:// is rejected
		# here even though it's a legitimate destination for disposable
		# screenshots, because we haven't yet defined the policy. See
		# project_delete_node_crash.md for the related editor-safety notes and
		# iter-07 follow-up work.
		if not save_path.begins_with("res://"):
			_send_result(peer, id, mcp_error("PATH_DENIED", "save_path must start with res://: %s" % save_path))
			return
		if not save_path.ends_with(".png"):
			_send_result(peer, id, mcp_error("INVALID_PARAMS", "save_path must end with .png: %s" % save_path))
			return
		var dir_path := save_path.get_base_dir()
		if not dir_path.is_empty():
			var dir_err := DirAccess.make_dir_recursive_absolute(dir_path)
			if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
				_send_result(peer, id, mcp_error("INTERNAL", "could not create %s (err %d)" % [dir_path, dir_err]))
				return
		var save_err := image.save_png(save_path)
		if save_err != OK:
			_send_result(peer, id, mcp_error("INTERNAL", "save_png failed (err %d) for %s" % [save_err, save_path]))
			return
		persisted_path = save_path

	var response := {
		"image_base64": Marshalls.raw_to_base64(png_bytes),
		"mime_type": "image/png",
		"width": image.get_width(),
		"height": image.get_height(),
		"bytes": png_bytes.size(),
	}
	if not persisted_path.is_empty():
		response["path"] = persisted_path
	_send_result(peer, id, response)


# ---- Tier 1 commands (iter 09) --------------------------------------------


func _cmd_editor_reload_scripts(peer: WebSocketPeer, id) -> void:
	# Godot 4.4 has no EditorInterface.reload_scripts() static despite what
	# older docs suggest (iter-09 plan was drafted against that assumption).
	# Portable flow: (1) rescan res:// so the FS cache sees on-disk changes,
	# (2) call Script.reload(true) on each script currently open in the
	# editor so the script editor + Inspector pick up new content. "true"
	# preserves runtime state when possible (matches godot-mcp-pro's
	# _reload_script helper).
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.scan()
	var reloaded := 0
	var script_editor := EditorInterface.get_script_editor()
	if script_editor != null:
		for open_script in script_editor.get_open_scripts():
			if open_script is Script:
				open_script.reload(true)
				reloaded += 1
	_send_result(peer, id, {"ok": true, "reloaded": reloaded})


func _cmd_scene_open(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	# TODO(iter-18): replace this prefix check with FileGuard.resolve_safe(path).
	if not path.begins_with("res://"):
		_send_result(peer, id, mcp_error("PATH_DENIED", "path must start with res://: %s" % path))
		return
	if not FileAccess.file_exists(path):
		_send_result(peer, id, mcp_error("NOT_FOUND", "scene not found: %s" % path))
		return
	EditorInterface.open_scene_from_path(path)
	_send_result(peer, id, {"ok": true, "path": path})


# MVP secret-key filter. `key` is over-eager (matches input keybinding names
# with "keycode" etc.) but that's the right default for "lean out of sight
# rather than risk exfil". Proper scrubbing lands in iter 20.
const _SECRET_KEY_REGEX := "(?i)password|token|secret|key"


func _cmd_project_get_settings(peer: WebSocketPeer, id, params) -> void:
	var prefix := ""
	if typeof(params) == TYPE_DICTIONARY:
		prefix = str(params.get("prefix", ""))

	var re := RegEx.new()
	var compile_err := re.compile(_SECRET_KEY_REGEX)
	if compile_err != OK:
		_send_result(peer, id, mcp_error("INTERNAL", "secret regex failed to compile (err %d)" % compile_err))
		return

	var settings := {}
	var filtered_secrets := 0
	for prop in ProjectSettings.get_property_list():
		var name := str(prop.get("name", ""))
		# Empty names and non-path-like Object meta entries are noise.
		if name.is_empty() or not name.contains("/"):
			continue
		if not prefix.is_empty() and not name.begins_with(prefix):
			continue
		if re.search(name) != null:
			filtered_secrets += 1
			continue
		settings[name] = _serialize_value(ProjectSettings.get_setting(name))

	_send_result(peer, id, {
		"settings": settings,
		"count": settings.size(),
		"filtered_secret_count": filtered_secrets,
	})


# ---- Tier 3 commands (iter 11) --------------------------------------------


# Shared resolver: "." / "" → edited scene root, otherwise NodePath lookup from root.
# Returns null (+ signals caller to emit NOT_FOUND) if the node can't be found.
func _resolve_scene_node(path: String):
	var root := _get_edited_root()
	if root == null:
		return null
	if path.is_empty() or path == ".":
		return root
	return root.get_node_or_null(path)


func _cmd_signal_list(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return
	var path := str(params.get("path", ""))
	var node = _resolve_scene_node(path)
	if node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "node not found: %s" % path))
		return
	_send_result(peer, id, {"path": path, "signals": _signal_list_of(node)})


func _signal_list_of(node: Object) -> Array:
	# Flattens get_signal_list() into JSON-friendly shape. `args` inside each
	# signal dict is itself an Array of property-info dicts; we keep name +
	# type (a TYPE_* int, TS consumer decodes).
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


# Resolves {source_path, signal, target_path, method} to concrete nodes +
# validates the signal + method exist. Returns a typed result dict that
# callers pattern-match on `error`/`code` vs the happy-path fields.
func _resolve_signal_pair(params) -> Dictionary:
	if typeof(params) != TYPE_DICTIONARY:
		return {"code": "INVALID_PARAMS", "error": "params must be an object"}
	var source_path := str(params.get("source_path", ""))
	var signal_name := str(params.get("signal", ""))
	var target_path := str(params.get("target_path", ""))
	var method_name := str(params.get("method", ""))
	if source_path.is_empty() or signal_name.is_empty() or target_path.is_empty() or method_name.is_empty():
		return {"code": "INVALID_PARAMS", "error": "source_path, signal, target_path, method are all required"}
	var root := _get_edited_root()
	if root == null:
		return {"code": "NO_SCENE", "error": "no edited scene"}
	var source = _resolve_scene_node(source_path)
	if source == null:
		return {"code": "NOT_FOUND", "error": "source node not found: %s" % source_path}
	var target = _resolve_scene_node(target_path)
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
	var r := _resolve_signal_pair(params)
	if r.has("error"):
		_send_result(peer, id, mcp_error(str(r["code"]), str(r["error"])))
		return
	var source = r["source"]
	var callable: Callable = r["callable"]
	var signal_name: String = str(r["signal_name"])
	var source_path: String = str(r["source_path"])
	var target_path: String = str(r["target_path"])
	var method_name: String = str(r["method_name"])
	# I3 idempotency (iter 15 status discriminator): same (signal, callable)
	# already connected → non-error success with status: "returned" instead
	# of re-registering. Fresh connects emit status: "created". `code` is
	# reserved for error payloads now — not carried on success.
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
	# Route through UndoRedo so the editor's signal-inspector picks this up
	# and Ctrl-Z reverses it. execute=true (default) runs the do_method now.
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("MCP: connect %s.%s -> %s.%s" % [source_path, signal_name, target_path, method_name])
	undo_redo.add_do_method(source, "connect", signal_name, callable)
	undo_redo.add_undo_method(source, "disconnect", signal_name, callable)
	undo_redo.commit_action()
	_send_result(peer, id, {
		"success": true,
		"status": "created",
		"source_path": source_path,
		"signal": signal_name,
		"target_path": target_path,
		"method": method_name,
	})


func _cmd_signal_disconnect(peer: WebSocketPeer, id, params) -> void:
	var r := _resolve_signal_pair(params)
	if r.has("error"):
		_send_result(peer, id, mcp_error(str(r["code"]), str(r["error"])))
		return
	var source = r["source"]
	var callable: Callable = r["callable"]
	var signal_name: String = str(r["signal_name"])
	var source_path: String = str(r["source_path"])
	var target_path: String = str(r["target_path"])
	var method_name: String = str(r["method_name"])
	if not source.is_connected(signal_name, callable):
		_send_result(peer, id, mcp_error("NOT_FOUND", "no connection to disconnect"))
		return
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("MCP: disconnect %s.%s -> %s.%s" % [source_path, signal_name, target_path, method_name])
	undo_redo.add_do_method(source, "disconnect", signal_name, callable)
	undo_redo.add_undo_method(source, "connect", signal_name, callable)
	undo_redo.commit_action()
	_send_result(peer, id, {"ok": true})


func _cmd_signal_emit(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return
	var path := str(params.get("path", ""))
	var signal_name := str(params.get("signal", ""))
	if signal_name.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing signal"))
		return
	var node = _resolve_scene_node(path)
	if node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "node not found: %s" % path))
		return
	if not node.has_signal(signal_name):
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "signal %s not on %s" % [signal_name, path]))
		return
	var raw_args = params.get("args", [])
	if typeof(raw_args) != TYPE_ARRAY:
		raw_args = []
	var coerced: Array = [signal_name]
	for a in raw_args:
		coerced.append(_coerce_value(a))
	node.callv("emit_signal", coerced)
	_send_result(peer, id, {"ok": true})


const _RESOURCE_SKIP_PROPERTIES: Array[String] = ["image", "mesh_arrays", "surface_arrays", "_data"]


func _cmd_resource_load(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	# TODO(iter-18): replace with FileGuard.resolve_safe(path).
	if not path.begins_with("res://"):
		_send_result(peer, id, mcp_error("PATH_DENIED", "path must start with res://: %s" % path))
		return
	if not ResourceLoader.exists(path):
		_send_result(peer, id, mcp_error("NOT_FOUND", "resource not found: %s" % path))
		return
	var resource := ResourceLoader.load(path)
	if resource == null:
		_send_result(peer, id, mcp_error("LOAD_FAILED", "ResourceLoader returned null for %s" % path))
		return
	var cls := resource.get_class()
	var props := {}
	for prop in resource.get_property_list():
		var usage: int = int(prop.get("usage", 0))
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		var pname := str(prop.get("name", ""))
		if pname.is_empty() or pname.begins_with("_"):
			continue
		# Heavy binary fields explicitly skipped — response caps in iter 20
		# formalise the limits, but the common offenders are worth pruning
		# now so tool calls stay usable.
		if pname in _RESOURCE_SKIP_PROPERTIES:
			continue
		props[pname] = _serialize_value(resource.get(pname))
	var metadata := {}
	if resource is Texture2D:
		metadata["width"] = resource.get_width()
		metadata["height"] = resource.get_height()
	_send_result(peer, id, {
		"class": cls,
		"path": path,
		"properties": props,
		"metadata": metadata,
	})


# scene.diff (iter 12): line-based JSON diff between a caller-supplied
# `before` snapshot (typically captured via scene.get_tree before mutating)
# and either an explicit `after` snapshot or the current edited tree.
# MVP heuristic: pretty-print both with sort_keys=true, take the symmetric
# difference of lines, label removed lines `- ` and added lines `+ `. A
# proper structural tree-diff (keyed by node path with property-level
# annotations) is post-MVP.
func _cmd_scene_diff(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	if not params.has("before"):
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing before"))
		return
	var before = params.get("before")
	var after = params.get("after", null)
	if after == null:
		var root := _get_edited_root()
		if root == null:
			_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
			return
		after = _walk_tree(root, root)
	# sort_keys=true so dict-key reordering doesn't show up as a diff.
	var before_str := JSON.stringify(before, "  ", true)
	var after_str := JSON.stringify(after, "  ", true)
	if before_str == after_str:
		_send_result(peer, id, {"changed": false, "diff": "", "added": 0, "removed": 0})
		return
	var before_lines := before_str.split("\n", false)
	var after_lines := after_str.split("\n", false)
	var before_set := {}
	for l in before_lines:
		before_set[l] = true
	var after_set := {}
	for l in after_lines:
		after_set[l] = true
	var diff_parts := PackedStringArray()
	var removed := 0
	for l in before_lines:
		if not after_set.has(l):
			diff_parts.append("- " + l)
			removed += 1
	var added := 0
	for l in after_lines:
		if not before_set.has(l):
			diff_parts.append("+ " + l)
			added += 1
	_send_result(peer, id, {
		"changed": true,
		"diff": "\n".join(diff_parts),
		"added": added,
		"removed": removed,
	})


func _cmd_node_get_property_list(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return
	var path := str(params.get("path", ""))
	var node = _resolve_scene_node(path)
	if node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "node not found: %s" % path))
		return
	var props: Array = []
	for prop in node.get_property_list():
		var usage: int = int(prop.get("usage", 0))
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		var pname := str(prop.get("name", ""))
		if pname.is_empty() or pname.begins_with("_"):
			continue
		props.append({
			"name": pname,
			"type": int(prop.get("type", 0)),
			"hint": int(prop.get("hint", 0)),
			"hint_string": str(prop.get("hint_string", "")),
		})
	_send_result(peer, id, {
		"path": path,
		"class": node.get_class(),
		"properties": props,
		"count": props.size(),
	})


# ---- Iter 15: file-level scene/script operations ------------------------
#
# scene.create / scene.delete / script.delete close the clean-start gap
# surfaced during Test 1 dogfood (no `.tscn` in the project → agent blocked).
# All three operate on files directly — no UndoRedo integration (those
# operate on the edited scene, which these tools do NOT assume). Error
# message templates are load-bearing for LLM recovery; keep wording stable
# across iter 16's SOLID split.


func _cmd_scene_create(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	var root_type := str(params.get("root_type", "Node"))
	var if_exists := str(params.get("if_exists", "return"))
	# TODO(iter-18): route `path` through FileGuard.resolve_safe.
	if not path.begins_with("res://"):
		_send_result(peer, id, mcp_error("INVALID_PATH", "path must start with res:// (got %s)" % path))
		return
	if path.get_extension().to_lower() != "tscn":
		_send_result(peer, id, mcp_error("INVALID_PATH", "path must end with .tscn (got %s; use script.write for .gd files)" % path))
		return
	var parent_dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(parent_dir):
		_send_result(peer, id, mcp_error("PARENT_NOT_FOUND", "parent directory %s does not exist; call folder.create first (scene.create does not auto-create directories)" % parent_dir))
		return
	# Class resolution: cache `resolved_kind` + `global_entry` so the
	# creation branch below doesn't re-scan the global class list.
	var resolved_kind := ""
	var global_entry: Dictionary = {}
	if ClassDB.class_exists(root_type):
		resolved_kind = "native"
	else:
		for entry in ProjectSettings.get_global_class_list():
			if str(entry.get("class", "")) == root_type:
				resolved_kind = "global"
				global_entry = entry
				break
	if resolved_kind.is_empty():
		_send_result(peer, id, mcp_error("INVALID_CLASS", "unknown class %s; checked ClassDB (engine classes) and ProjectSettings.get_global_class_list() (GDScript class_name + C# [GlobalClass])" % root_type))
		return
	if not _class_descends_from(root_type, "Node"):
		_send_result(peer, id, mcp_error("INVALID_CLASS", "%s is not a Node subclass (resolved base chain: %s); scene roots must descend from Node" % [root_type, _class_base_chain(root_type)]))
		return
	if not (if_exists in ["return", "fail", "replace"]):
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "if_exists must be one of 'return'|'fail'|'replace' (got %s); default is 'return'" % if_exists))
		return

	# Collision branch.
	var was_replace := false
	var prev_root_type := ""
	if FileAccess.file_exists(path):
		match if_exists:
			"return":
				_send_result(peer, id, {"success": true, "status": "returned", "path": path})
				return
			"fail":
				_send_result(peer, id, mcp_error("ALREADY_EXISTS", "file exists at %s; set if_exists:'replace' to overwrite" % path))
				return
			"replace":
				was_replace = true
				var prev_packed = ResourceLoader.load(path)
				if prev_packed == null or not (prev_packed is PackedScene):
					prev_root_type = "<unreadable>"
				else:
					var state := (prev_packed as PackedScene).get_state()
					if state == null or state.get_node_count() == 0:
						prev_root_type = "<empty>"
					else:
						prev_root_type = str(state.get_node_type(0))
				push_warning("MCP: scene.create replacing %s (was root=%s, now root=%s)" % [path, prev_root_type, root_type])
				# Fall through to creation logic below.

	# Creation logic (fresh path OR if_exists == "replace").
	var root: Node = null
	if resolved_kind == "native":
		root = ClassDB.instantiate(root_type)
	else:
		var script_path := str(global_entry.get("path", ""))
		var script = load(script_path)
		if script == null:
			_send_result(peer, id, mcp_error("INVALID_CLASS", "could not load script for %s at %s" % [root_type, script_path]))
			return
		# script.new() runs _init() — rare to matter for scene-root classes
		# but documented in the toolkit README as a known side-effect.
		root = script.new()
	if root == null:
		_send_result(peer, id, mcp_error("INVALID_CLASS", "instantiation returned null for %s" % root_type))
		return
	root.name = path.get_file().get_basename()
	var packed := PackedScene.new()
	var pack_err := packed.pack(root)
	if pack_err != OK:
		root.queue_free()
		_send_result(peer, id, mcp_error("PACK_FAILED", "PackedScene.pack returned %d (class=%s, path=%s)" % [pack_err, root_type, path]))
		return
	var save_err := ResourceSaver.save(packed, path)
	# PackedScene holds its own copy after pack(); free the template to
	# avoid a per-call Node leak in the editor process.
	root.queue_free()
	if save_err != OK:
		_send_result(peer, id, mcp_error("SAVE_FAILED", "ResourceSaver.save returned %d (path=%s)" % [save_err, path]))
		return

	var response := {"success": true, "path": path, "root_type": root_type}
	if was_replace:
		response["status"] = "replaced"
		response["previous_root_type"] = prev_root_type
	else:
		response["status"] = "created"
	_send_result(peer, id, response)


# Helper: does `type_name` descend from `base`? Walks ClassDB's native
# hierarchy first, then ProjectSettings.get_global_class_list() for
# custom GDScript `class_name` / C# `[GlobalClass]` chains. Bounded by
# hierarchy depth (<10 realistically); parser rejects cyclic inheritance.
# Iter 15b factor: `scene.create` passes `"Node"`, `resource.create` passes
# `"Resource"`. Iter 16 (SOLID split) will hoist this into a dedicated
# type-resolution module.
func _class_descends_from(type_name: String, base: String) -> bool:
	if ClassDB.class_exists(type_name):
		return ClassDB.is_parent_class(type_name, base)
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == type_name:
			return _class_descends_from(str(entry.get("base", "")), base)
	return false


# Helper: "A -> B -> C" base chain for INVALID_CLASS messages.
func _class_base_chain(type_name: String) -> String:
	var chain := PackedStringArray()
	var current := type_name
	var depth := 0
	while not current.is_empty() and depth < 16:
		chain.append(current)
		if ClassDB.class_exists(current):
			var base := ClassDB.get_parent_class(current)
			if base.is_empty():
				break
			current = base
		else:
			var found := false
			for entry in ProjectSettings.get_global_class_list():
				if str(entry.get("class", "")) == current:
					current = str(entry.get("base", ""))
					found = true
					break
			if not found:
				break
		depth += 1
	return " -> ".join(chain)


func _cmd_scene_delete(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	# TODO(iter-18): route `path` through FileGuard.resolve_safe.
	if not path.begins_with("res://"):
		_send_result(peer, id, mcp_error("INVALID_PATH", "path must start with res:// (got %s)" % path))
		return
	if path.get_extension().to_lower() != "tscn":
		_send_result(peer, id, mcp_error("INVALID_PATH", "scene.delete only removes .tscn files (got %s); use a different tool for other file types" % path))
		return
	if not FileAccess.file_exists(path):
		_send_result(peer, id, mcp_error("NOT_FOUND", "no file at %s" % path))
		return
	var edited_root := _get_edited_root()
	if edited_root != null and edited_root.scene_file_path == path:
		_send_result(peer, id, mcp_error("EDITED_SCENE", "cannot delete the currently-edited scene %s; open a different scene via scene.open first" % path))
		return
	var dir := DirAccess.open("res://")
	if dir == null:
		_send_result(peer, id, mcp_error("INTERNAL", "DirAccess.open(res://) returned null"))
		return
	var rel := path.substr("res://".length())
	var rm_err := dir.remove(rel)
	if rm_err != OK:
		_send_result(peer, id, mcp_error("DELETE_FAILED", "DirAccess.remove returned %d (path=%s)" % [rm_err, path]))
		return
	# Best-effort .uid companion removal (Godot 4.4+). Silent on miss.
	var uid_rel := rel + ".uid"
	if dir.file_exists(uid_rel):
		dir.remove(uid_rel)
	_send_result(peer, id, {"success": true, "path": path})


# Symmetric with scene.delete — same INVALID_PATH / NOT_FOUND / DELETE_FAILED
# shape, no "currently-edited" guard (script editor has no single "current"
# analog; matches Godot's own FileSystem-dock permissive delete behaviour).
func _cmd_script_delete(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	# TODO(iter-18): route `path` through FileGuard.resolve_safe.
	if not path.begins_with("res://"):
		_send_result(peer, id, mcp_error("INVALID_PATH", "path must start with res:// (got %s)" % path))
		return
	var ext := path.get_extension().to_lower()
	if not (ext in ["gd", "cs", "gdshader", "gdshaderinc"]):
		_send_result(peer, id, mcp_error("INVALID_PATH", "script.delete only removes .gd, .cs, .gdshader, or .gdshaderinc files (got %s); use scene.delete for .tscn, resource.delete for .tres/.res, or a different tool for other file types" % path))
		return
	if not FileAccess.file_exists(path):
		_send_result(peer, id, mcp_error("NOT_FOUND", "no file at %s" % path))
		return
	var dir := DirAccess.open("res://")
	if dir == null:
		_send_result(peer, id, mcp_error("INTERNAL", "DirAccess.open(res://) returned null"))
		return
	var rel := path.substr("res://".length())
	var rm_err := dir.remove(rel)
	if rm_err != OK:
		_send_result(peer, id, mcp_error("DELETE_FAILED", "DirAccess.remove returned %d (path=%s)" % [rm_err, path]))
		return
	# Best-effort .uid companion removal (Godot 4.4+ generates these for
	# scripts too, not just scenes). Silent on miss.
	var uid_rel := rel + ".uid"
	if dir.file_exists(uid_rel):
		dir.remove(uid_rel)
	_send_result(peer, id, {"success": true, "path": path})


# ---- Iter 15b: resource / folder operations -----------------------------
#
# resource.create / resource.save / resource.delete close the .tres/.res
# authoring gap (data-driven game content: EnemyData, DialogueNode, themes,
# materials). folder.create / folder.delete pair with iter 15's
# PARENT_NOT_FOUND error so agents have a recovery path. Same conventions as
# iter 15: `status` discriminator on creates, `if_exists` on file-level
# creates, message templates load-bearing for LLM recovery. All paths
# res://-only (user:// is iter 19b).


# Build a set of property-names from an Object's get_property_list(). Used
# by resource.create / resource.save to flag unknown keys. Godot's set()
# silently no-ops on unknown keys, so without this the agent gets false
# success on typoed property names.
func _property_names_of(obj: Object) -> Dictionary:
	var names := {}
	for prop in obj.get_property_list():
		var n := str(prop.get("name", ""))
		if not n.is_empty():
			names[n] = true
	return names


# Shared apply-properties helper for resource.create / resource.save. Coerces
# dict-wrapped engine types via _coerce_value, flags unknown keys into
# warnings, returns the warnings array. Resource is mutated in place.
func _apply_resource_properties(resource: Resource, properties: Dictionary, resource_class: String) -> Array[String]:
	var warnings: Array[String] = []
	var valid := _property_names_of(resource)
	for key in properties.keys():
		var key_str := str(key)
		if not valid.has(key_str):
			warnings.append("property '%s' unknown on %s; value ignored" % [key_str, resource_class])
			continue
		var raw_value = properties[key]
		# iter 15c: Resource refs surface as warnings, not errors — authoring
		# a .tres with a placeholder path is a valid probing workflow.
		var missing := _check_resource_paths(raw_value)
		if missing != "":
			warnings.append("property '%s': resource not found at %s; value left unchanged" % [key_str, missing])
			continue
		resource.set(key_str, _coerce_value(raw_value))
	return warnings


func _cmd_resource_create(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	var resource_class := str(params.get("resource_class", ""))
	var properties: Dictionary = params.get("properties", {}) if typeof(params.get("properties", {})) == TYPE_DICTIONARY else {}
	var if_exists := str(params.get("if_exists", "return"))
	# TODO(iter-18): route `path` through FileGuard.resolve_safe.
	if not path.begins_with("res://"):
		_send_result(peer, id, mcp_error("INVALID_PATH", "path must start with res:// (got %s)" % path))
		return
	var ext := path.get_extension().to_lower()
	if not (ext in ["tres", "res"]):
		_send_result(peer, id, mcp_error("INVALID_PATH", "resource.create only writes .tres (text) or .res (binary) files (got %s; use scene.create for .tscn, script.write for .gd/.cs)" % path))
		return
	var parent_dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(parent_dir):
		_send_result(peer, id, mcp_error("PARENT_NOT_FOUND", "parent directory %s does not exist; call folder.create first (resource.create does not auto-create directories)" % parent_dir))
		return
	if resource_class.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing resource_class"))
		return
	# Class resolution — native (ClassDB) then global (GDScript class_name /
	# C# [GlobalClass]). Cache for the creation branch below.
	var resolved_kind := ""
	var global_entry: Dictionary = {}
	if ClassDB.class_exists(resource_class):
		resolved_kind = "native"
	else:
		for entry in ProjectSettings.get_global_class_list():
			if str(entry.get("class", "")) == resource_class:
				resolved_kind = "global"
				global_entry = entry
				break
	if resolved_kind.is_empty():
		_send_result(peer, id, mcp_error("INVALID_CLASS", "unknown class %s; checked ClassDB (engine classes) and ProjectSettings.get_global_class_list() (GDScript class_name + C# [GlobalClass])" % resource_class))
		return
	if not _class_descends_from(resource_class, "Resource"):
		_send_result(peer, id, mcp_error("NOT_A_RESOURCE", "%s is not a Resource subclass (resolved base chain: %s); resource.create requires a Resource subclass — use scene.create for Node subclasses, script.write for source files" % [resource_class, _class_base_chain(resource_class)]))
		return
	if not (if_exists in ["return", "fail", "replace"]):
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "if_exists must be one of 'return'|'fail'|'replace' (got %s); default is 'return'" % if_exists))
		return

	# Collision branch.
	var was_replace := false
	var prev_class := ""
	if FileAccess.file_exists(path):
		match if_exists:
			"return":
				_send_result(peer, id, {"success": true, "status": "returned", "path": path})
				return
			"fail":
				_send_result(peer, id, mcp_error("ALREADY_EXISTS", "file exists at %s; set if_exists:'replace' to overwrite" % path))
				return
			"replace":
				was_replace = true
				var prev := ResourceLoader.load(path)
				prev_class = "<unreadable>" if prev == null else prev.get_class()
				push_warning("MCP: resource.create replacing %s (was class=%s, now class=%s)" % [path, prev_class, resource_class])
				# Fall through to creation logic.

	# Creation logic (fresh path OR if_exists == "replace").
	var resource: Resource = null
	if resolved_kind == "native":
		resource = ClassDB.instantiate(resource_class)
	else:
		var script_path := str(global_entry.get("path", ""))
		var script = load(script_path)
		if script == null:
			_send_result(peer, id, mcp_error("INVALID_CLASS", "could not load script for %s at %s" % [resource_class, script_path]))
			return
		# script.new() runs _init() — documented in README as a side-effect
		# callers should be aware of for custom Resource subclasses.
		resource = script.new()
	if resource == null:
		_send_result(peer, id, mcp_error("INVALID_CLASS", "instantiation returned null for %s" % resource_class))
		return

	var warnings := _apply_resource_properties(resource, properties, resource_class)

	var save_err := ResourceSaver.save(resource, path)
	# Resource is RefCounted — freed automatically when the local goes out of
	# scope (no queue_free like scene.create's Node template).
	if save_err != OK:
		_send_result(peer, id, mcp_error("SAVE_FAILED", "ResourceSaver.save returned %d (path=%s)" % [save_err, path]))
		return

	var response := {
		"success": true,
		"path": path,
		"resource_class": resource_class,
		"warnings": warnings,
	}
	if was_replace:
		response["status"] = "replaced"
		response["previous_class"] = prev_class
	else:
		response["status"] = "created"
	_send_result(peer, id, response)


func _cmd_resource_save(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	var raw_props = params.get("properties", null)
	if typeof(raw_props) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing properties (must be an object)"))
		return
	var properties: Dictionary = raw_props
	# TODO(iter-18): route `path` through FileGuard.resolve_safe.
	if not path.begins_with("res://"):
		_send_result(peer, id, mcp_error("INVALID_PATH", "path must start with res:// (got %s)" % path))
		return
	var ext := path.get_extension().to_lower()
	if not (ext in ["tres", "res"]):
		_send_result(peer, id, mcp_error("INVALID_PATH", "resource.save only updates .tres (text) or .res (binary) files (got %s; use scene.create for .tscn, script.write for .gd/.cs)" % path))
		return
	if not FileAccess.file_exists(path):
		_send_result(peer, id, mcp_error("NOT_FOUND", "no resource at %s; use resource.create to create" % path))
		return
	var resource := ResourceLoader.load(path)
	if resource == null:
		_send_result(peer, id, mcp_error("NOT_A_RESOURCE", "file at %s is not a readable Resource (corrupt or wrong extension)" % path))
		return
	var resource_class := resource.get_class()
	var warnings := _apply_resource_properties(resource, properties, resource_class)
	var save_err := ResourceSaver.save(resource, path)
	if save_err != OK:
		_send_result(peer, id, mcp_error("SAVE_FAILED", "ResourceSaver.save returned %d (path=%s)" % [save_err, path]))
		return
	# No `status` — resource.save is an update, not a create. The absence of
	# `status` is itself the discriminator vs resource.create.
	_send_result(peer, id, {
		"success": true,
		"path": path,
		"resource_class": resource_class,
		"warnings": warnings,
	})


func _cmd_resource_delete(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	# TODO(iter-18): route `path` through FileGuard.resolve_safe.
	if not path.begins_with("res://"):
		_send_result(peer, id, mcp_error("INVALID_PATH", "path must start with res:// (got %s)" % path))
		return
	var ext := path.get_extension().to_lower()
	if not (ext in ["tres", "res"]):
		_send_result(peer, id, mcp_error("INVALID_PATH", "resource.delete only removes .tres or .res files (got %s); use scene.delete for .tscn, script.delete for .gd/.cs/.gdshader/.gdshaderinc, or a different tool for other file types" % path))
		return
	if not FileAccess.file_exists(path):
		_send_result(peer, id, mcp_error("NOT_FOUND", "no file at %s" % path))
		return
	# No active-use check (deliberate): live-loaded Resources stay resident
	# in memory when the file is deleted on disk (RefCounted refs persist);
	# deleted file won't re-load but existing references don't crash. Agent
	# detects orphan refs via editor_get_errors. Matches Godot's own
	# FileSystem-dock permissive delete behaviour and script.delete's posture.
	var dir := DirAccess.open("res://")
	if dir == null:
		_send_result(peer, id, mcp_error("INTERNAL", "DirAccess.open(res://) returned null"))
		return
	var rel := path.substr("res://".length())
	var rm_err := dir.remove(rel)
	if rm_err != OK:
		_send_result(peer, id, mcp_error("DELETE_FAILED", "DirAccess.remove returned %d (path=%s)" % [rm_err, path]))
		return
	# Best-effort .uid companion removal (Godot 4.4+ generates these for
	# resources too, not just scenes). Silent on miss.
	var uid_rel := rel + ".uid"
	if dir.file_exists(uid_rel):
		dir.remove(uid_rel)
	_send_result(peer, id, {"success": true, "path": path})


func _cmd_folder_create(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	# TODO(iter-18): route `path` through FileGuard.resolve_safe.
	if not path.begins_with("res://"):
		_send_result(peer, id, mcp_error("INVALID_PATH", "path must start with res:// (got %s)" % path))
		return
	# No extension guard (directories have no extension; get_extension() of a
	# trailing path segment with no '.' returns empty — the signal itself).
	# No parent-dir guard (recursive create is the point — all intermediates
	# are auto-created by make_dir_recursive_absolute).
	var pre_existed := DirAccess.dir_exists_absolute(path)
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err != OK:
		_send_result(peer, id, mcp_error("CREATE_DIR_FAILED", "DirAccess.make_dir_recursive_absolute returned %d (path=%s)" % [err, path]))
		return
	var status := "returned" if pre_existed else "created"
	_send_result(peer, id, {"success": true, "status": status, "path": path})


# Recursive file+subdir walker for folder.delete's recursive:true branch.
# Returns {files: int, dirs: int, ok: bool, error: String} so the caller can
# translate the first failure into a DELETE_FAILED without silently
# half-deleting. Best-effort .uid companion removal rides along per file.
func _folder_delete_recursive(path: String) -> Dictionary:
	var dir := DirAccess.open(path)
	if dir == null:
		return {"files": 0, "dirs": 0, "ok": false, "error": "DirAccess.open(%s) returned null" % path}
	var files_removed := 0
	var dirs_removed := 0
	# Iterate files first, then subdirs. DirAccess.get_files/get_directories
	# return snapshots — safe to mutate the directory during iteration.
	for file_name in dir.get_files():
		# Skip .uid here — removed inline with their companion below.
		if file_name.ends_with(".uid"):
			continue
		var rm_err := dir.remove(file_name)
		if rm_err != OK:
			return {"files": files_removed, "dirs": dirs_removed, "ok": false, "error": "DirAccess.remove %s/%s returned %d" % [path, file_name, rm_err]}
		files_removed += 1
		var uid_companion := file_name + ".uid"
		if dir.file_exists(uid_companion):
			dir.remove(uid_companion)
	# Second pass: any stragglers (orphan .uid whose companion was deleted
	# earlier or never existed). Silent on miss.
	for file_name in dir.get_files():
		if file_name.ends_with(".uid"):
			dir.remove(file_name)
	for sub_name in dir.get_directories():
		var sub_path := path + "/" + sub_name
		var sub_result := _folder_delete_recursive(sub_path)
		files_removed += int(sub_result.get("files", 0))
		dirs_removed += int(sub_result.get("dirs", 0))
		if not bool(sub_result.get("ok", false)):
			return {"files": files_removed, "dirs": dirs_removed, "ok": false, "error": str(sub_result.get("error", "unknown"))}
		# Remove the now-empty subdir via the parent handle.
		var rm_sub_err := dir.remove(sub_name)
		if rm_sub_err != OK:
			return {"files": files_removed, "dirs": dirs_removed, "ok": false, "error": "DirAccess.remove (subdir) %s returned %d" % [sub_path, rm_sub_err]}
		dirs_removed += 1
	return {"files": files_removed, "dirs": dirs_removed, "ok": true, "error": ""}


func _cmd_folder_delete(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	var recursive := bool(params.get("recursive", false))
	# TODO(iter-18): route `path` through FileGuard.resolve_safe.
	if not path.begins_with("res://"):
		_send_result(peer, id, mcp_error("INVALID_PATH", "path must start with res:// (got %s)" % path))
		return
	# Root protection. "res://" and "res:///" both resolve to the project
	# root; refuse either form. get_base_dir() of "res://" returns "" — we
	# also refuse any path that would traverse above res://.
	if path == "res://" or path == "res:///" or path.get_base_dir() == "":
		_send_result(peer, id, mcp_error("FOLDER_PROTECTED", "cannot delete the project root res://; narrow the path"))
		return
	# Normalise trailing slash for equality checks below — "res://addons/"
	# and "res://addons" must both be refused.
	var norm := path
	if norm.ends_with("/"):
		norm = norm.substr(0, norm.length() - 1)
	if norm == "res://addons" or norm == "res://addons/godot_mcp_toolkit":
		_send_result(peer, id, mcp_error("FOLDER_PROTECTED", "cannot delete res://addons or the toolkit plugin directory (%s); agent cannot remove its own host" % norm))
		return
	if not DirAccess.dir_exists_absolute(path):
		_send_result(peer, id, mcp_error("NOT_FOUND", "no folder at %s" % path))
		return
	var norm_with_slash := norm + "/"
	# PATH_IN_USE — currently-edited scene under path.
	var edited := _get_edited_root()
	if edited != null:
		var scene_path := str(edited.scene_file_path)
		if not scene_path.is_empty() and (scene_path == norm or scene_path.begins_with(norm_with_slash)):
			_send_result(peer, id, mcp_error("PATH_IN_USE", "folder %s contains the currently-edited scene %s; open a different scene first via scene.open" % [path, scene_path]))
			return
	# PATH_IN_USE — open script editor tabs under path.
	var script_editor := EditorInterface.get_script_editor()
	if script_editor != null:
		for open_script in script_editor.get_open_scripts():
			if not (open_script is Resource):
				continue
			var rpath := str((open_script as Resource).resource_path)
			if rpath.is_empty():
				continue
			if rpath == norm or rpath.begins_with(norm_with_slash):
				_send_result(peer, id, mcp_error("PATH_IN_USE", "folder %s contains open script %s; close the script editor tab first" % [path, rpath]))
				return
	# DIR_NOT_EMPTY — count files + subdirs before we commit.
	var dir := DirAccess.open(path)
	if dir == null:
		_send_result(peer, id, mcp_error("INTERNAL", "DirAccess.open(%s) returned null" % path))
		return
	var file_count := dir.get_files().size()
	var subdir_count := dir.get_directories().size()
	if (file_count + subdir_count) > 0 and not recursive:
		_send_result(peer, id, mcp_error("DIR_NOT_EMPTY", "folder %s is not empty (contains %d files, %d subdirs); pass recursive:true to delete contents" % [path, file_count, subdir_count]))
		return
	# Execute delete.
	var files_deleted := 0
	var dirs_deleted := 0
	if recursive and (file_count + subdir_count) > 0:
		var result := _folder_delete_recursive(path)
		files_deleted = int(result.get("files", 0))
		dirs_deleted = int(result.get("dirs", 0))
		if not bool(result.get("ok", false)):
			_send_result(peer, id, mcp_error("DELETE_FAILED", str(result.get("error", "unknown"))))
			return
	# Remove the (now-empty) top-level folder via its parent.
	var parent_path := path.get_base_dir()
	var parent_dir := DirAccess.open(parent_path)
	if parent_dir == null:
		_send_result(peer, id, mcp_error("INTERNAL", "DirAccess.open(%s) returned null" % parent_path))
		return
	var top_rm := parent_dir.remove(path.get_file())
	if top_rm != OK:
		_send_result(peer, id, mcp_error("DELETE_FAILED", "DirAccess.remove returned %d (path=%s)" % [top_rm, path]))
		return
	if recursive and (file_count + subdir_count) > 0:
		push_warning("MCP: folder.delete recursive %s (%d files, %d subdirs)" % [path, files_deleted, dirs_deleted])
	_send_result(peer, id, {
		"success": true,
		"path": path,
		"recursive": recursive,
		"files_deleted": files_deleted,
		"directories_deleted": dirs_deleted,
	})


# ---- iter 15c — playtest + composition + runtime-method invocation --------

# Drive the editor's play button (Mode A). target ∈ {"main","current",res://*}.
# ALREADY_PLAYING is the stop-then-start discriminator (explicit over silent
# swap so the agent sees the transition). wait_for_runtime polls Mode B's
# port 9090 so the agent can chain runtime RPCs without a separate probe.
func _cmd_game_start(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		params = {}
	var target := str(params.get("target", "current"))
	var wait_for_runtime_raw = params.get("wait_for_runtime", true)
	var wait_for_runtime := bool(wait_for_runtime_raw) if typeof(wait_for_runtime_raw) == TYPE_BOOL else true

	if EditorInterface.is_playing_scene():
		_send_result(peer, id, mcp_error("ALREADY_PLAYING", "a game is already running; call game.stop first"))
		return

	match target:
		"main":
			EditorInterface.play_main_scene()
		"current":
			if EditorInterface.get_edited_scene_root() == null:
				_send_result(peer, id, mcp_error("NO_SCENE", "no currently-edited scene; use target:'main' or target:<res://path>, or scene.open first"))
				return
			EditorInterface.play_current_scene()
		_:
			# TODO(iter-18): route `target` through FileGuard.resolve_safe.
			if not target.begins_with("res://"):
				_send_result(peer, id, mcp_error("INVALID_PARAMS", "target must be 'main' | 'current' | a res:// scene path (got %s)" % target))
				return
			if target.get_extension().to_lower() != "tscn":
				_send_result(peer, id, mcp_error("INVALID_PATH", "game.start only plays .tscn files (got %s)" % target))
				return
			if not FileAccess.file_exists(target):
				_send_result(peer, id, mcp_error("NOT_FOUND", "no scene file at %s; use scene.create first" % target))
				return
			EditorInterface.play_custom_scene(target)

	var runtime_ready := false
	if wait_for_runtime:
		runtime_ready = _poll_runtime_ready("127.0.0.1", 9090, 5000)

	_send_result(peer, id, {
		"success": true,
		"target": target,
		"runtime_port": 9090,
		"runtime_ready": runtime_ready,
	})


# Idempotent in the stop direction: `was_running:false` when nothing was live
# lets the agent detect "called stop but it was already stopped" without an
# error payload (same update-shape rationale as resource.save's no-status).
func _cmd_game_stop(peer: WebSocketPeer, id, _params) -> void:
	var was_running := EditorInterface.is_playing_scene()
	EditorInterface.stop_playing_scene()
	_send_result(peer, id, {
		"success": true,
		"was_running": was_running,
	})


# Short-wait TCP probe for Mode B's runtime server. Blocks the editor main
# thread (up to timeout_ms) — wait_for_runtime=true is the caller's explicit
# opt-in. Returns false on timeout rather than erroring: some projects don't
# ship the Mode B autoload, and the agent can still drive the editor side.
func _poll_runtime_ready(host: String, port: int, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var stream := StreamPeerTCP.new()
		if stream.connect_to_host(host, port) == OK:
			var inner_deadline := Time.get_ticks_msec() + 150
			while Time.get_ticks_msec() < inner_deadline:
				stream.poll()
				var st := stream.get_status()
				if st == StreamPeerTCP.STATUS_CONNECTED:
					stream.disconnect_from_host()
					return true
				if st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE:
					break
				OS.delay_msec(10)
			stream.disconnect_from_host()
		OS.delay_msec(100)
	return false


# Drop a PackedScene under an edited-scene parent. UndoRedo-wrapped (crash
# guard per project_delete_node_crash.md). Recursive owner-set is mandatory:
# Godot silently drops un-owned children on editor_save_scene. Extends to
# children added by PackedScene @tool _init hooks, not just the root.
func _cmd_scene_instantiate(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no open scene; use scene.open or scene.create first"))
		return

	var parent_path := str(params.get("parent_path", ""))
	var packed_path := str(params.get("packed_path", ""))
	var as_name := str(params.get("as_name", ""))
	var transform_raw = params.get("transform", {})
	var transform: Dictionary = transform_raw if typeof(transform_raw) == TYPE_DICTIONARY else {}
	# TODO(iter-18): route `parent_path` + `packed_path` through FileGuard.resolve_safe.

	if parent_path.is_empty() or packed_path.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing parent_path or packed_path"))
		return

	var parent_node := root.get_node_or_null(parent_path)
	if parent_node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "no node at parent_path %s (must be under the currently-edited scene root)" % parent_path))
		return

	if not packed_path.begins_with("res://"):
		_send_result(peer, id, mcp_error("INVALID_PATH", "packed_path must start with res:// (got %s)" % packed_path))
		return
	if packed_path.get_extension().to_lower() != "tscn":
		_send_result(peer, id, mcp_error("INVALID_PATH", "scene.instantiate only instantiates .tscn files (got %s); use resource.create for .tres, script.write for .gd/.cs" % packed_path))
		return
	if not FileAccess.file_exists(packed_path):
		_send_result(peer, id, mcp_error("NOT_FOUND", "no scene file at %s; use scene.create first" % packed_path))
		return
	var packed := ResourceLoader.load(packed_path)
	if packed == null:
		_send_result(peer, id, mcp_error("LOAD_FAILED", "ResourceLoader.load returned null for %s (corrupt file or dependency error — check editor_get_errors)" % packed_path))
		return
	if not (packed is PackedScene):
		_send_result(peer, id, mcp_error("INVALID_CLASS", "file at %s is not a PackedScene (got %s); scene.instantiate only works on .tscn files" % [packed_path, packed.get_class()]))
		return

	# Node-level idempotency (silent return on name collision — same shape as
	# scene.create_node / signal.connect / folder.create).
	var target_name := as_name if as_name != "" else (packed as PackedScene).get_state().get_node_name(0)
	if parent_node.has_node(NodePath(target_name)):
		var existing := parent_node.get_node(NodePath(target_name))
		_send_result(peer, id, {
			"success": true,
			"status": "returned",
			"path": _path_in_scene(root, existing),
			"class_name": existing.get_class(),
		})
		return

	var instance: Node = (packed as PackedScene).instantiate()
	if instance == null:
		_send_result(peer, id, mcp_error("LOAD_FAILED", "PackedScene.instantiate returned null for %s" % packed_path))
		return

	if as_name != "":
		instance.name = as_name

	# Apply transform dict (e.g. {position:{type:"Vector2",x,y}}). `.set` is a
	# silent no-op on unknown properties — keeps the call subtype-agnostic
	# across Node2D/Node3D/Control without per-class has_method dispatch.
	if not transform.is_empty():
		for key in transform.keys():
			instance.set(str(key), _coerce_value(transform[key]))

	# UndoRedo per project_delete_node_crash.md — add_do_reference keeps the
	# instance alive in the undo history if the add is rolled back.
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("MCP: instantiate %s under %s" % [packed_path, parent_path])
	undo_redo.add_do_method(parent_node, "add_child", instance)
	undo_redo.add_do_method(self, "_set_owner_recursive", instance, root)
	undo_redo.add_do_reference(instance)
	undo_redo.add_undo_method(parent_node, "remove_child", instance)
	undo_redo.commit_action()

	_send_result(peer, id, {
		"success": true,
		"status": "created",
		"path": _path_in_scene(root, instance),
		"class_name": instance.get_class(),
	})


# Mode A only in 15c — edited-scene nodes via get_edited_scene_root. Mode B
# (runtime-live nodes via port 9090) is deferred per iter 15c handoff note;
# requires physics-step coherence + signal-handler + RefCounted-lifetime
# care that belongs in its own iter.
# TODO(iter-19): wrap in FeatureGate.is_enabled("node_call_method").
func _cmd_node_call_method(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no open scene; use scene.open or scene.create first"))
		return

	var path := str(params.get("path", ""))
	var method := str(params.get("method", ""))
	var args_raw = params.get("args", [])
	# TODO(iter-18): route `path` through FileGuard.resolve_safe; args may
	# contain `{type:"Resource",path:...}` refs that hit the filesystem.

	if path.is_empty() or method.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing path or method"))
		return
	if typeof(args_raw) != TYPE_ARRAY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "args must be an Array (got %s)" % typeof(args_raw)))
		return

	var node := root.get_node_or_null(path)
	if node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "no node at path %s" % path))
		return
	if not node.has_method(method):
		_send_result(peer, id, mcp_error("INVALID_METHOD", "node %s has no method '%s'; use scene.get_tree or inspect the script class via ClassDB" % [path, method]))
		return

	# Gate Resource refs in args — same load-bearing rationale as
	# node.set_property (null resource surfaces as runtime pink checkerboard).
	var missing := _check_resource_paths(args_raw)
	if missing != "":
		_send_result(peer, id, mcp_error("LOAD_FAILED", "failed to load resource at %s; verify the path or use resource.create to create it first" % missing))
		return

	var coerced_args = _coerce_value(args_raw)
	if typeof(coerced_args) != TYPE_ARRAY:
		coerced_args = []
	push_warning("MCP: node.call_method invoked %s.%s(%d args)" % [path, method, (coerced_args as Array).size()])
	var result = node.callv(method, coerced_args)

	_send_result(peer, id, {
		"success": true,
		"path": path,
		"method": method,
		"result": _serialize_value(result),
	})


# Depth-first owner-set. Required after PackedScene.instantiate because
# editor_save_scene drops any node whose owner is null. PackedScenes with
# @tool `_init` that add children need ALL descendants owned, not just root.
func _set_owner_recursive(node: Node, owner: Node) -> void:
	node.set_owner(owner)
	for child in node.get_children():
		_set_owner_recursive(child, owner)


# ---- Iter 15d: project / input_map / animation / tilemap / screenshot_node ----
#
# Five domains, ~10 new handlers. All honour the iter 15/15b/15c conventions:
# `status` discriminator on creates, actionable error messages, _coerce_value
# applied to property/arg/value ingest, TODO(iter-18) markers at every
# path-touching site. No new error codes minted (deliberate scope discipline —
# 14/15/15b/15c surface declared sufficient for authoring workflows).


# project.set_setting — write a ProjectSettings key + persist via
# ProjectSettings.save. UPDATE-shaped (no `status`); returns was_set_before
# + previous_value for observability. Refuses `mcp/unsafe/*` (those are the
# toolkit's own gates — use FeatureGate from iter 19) and `editor/*`
# (editor-session state, not project config). High blast-radius — gated
# behind FeatureGate in iter 19 (TODO marker below).
# TODO(iter-19): wrap in FeatureGate.is_enabled("project_set_setting").
func _cmd_project_set_setting(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var key := str(params.get("key", ""))
	if key.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "key must be a non-empty string"))
		return
	if key.begins_with("mcp/unsafe/"):
		_send_result(peer, id, mcp_error("INVALID_PATH", "refusing to write mcp/unsafe/* from project.set_setting (those are the toolkit's own gates — use the FeatureGate system in iter 19); got key=%s" % key))
		return
	if key.begins_with("editor/"):
		_send_result(peer, id, mcp_error("INVALID_PATH", "refusing to write editor/* ProjectSettings from project.set_setting (editor-session state, not project config); got key=%s" % key))
		return
	if not params.has("value"):
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing value"))
		return
	var raw_value = params.get("value", null)
	# TODO(iter-18): res:// strings (e.g. application/run/main_scene) and
	# Resource refs flow through _coerce_value unchanged; route through
	# FileGuard.resolve_safe at this site once the sandbox lands.
	var coerced = _coerce_value(raw_value)
	var was_set_before := ProjectSettings.has_setting(key)
	var previous_value = ProjectSettings.get_setting(key) if was_set_before else null
	ProjectSettings.set_setting(key, coerced)
	var save_err := ProjectSettings.save()
	if save_err != OK:
		_send_result(peer, id, mcp_error("SAVE_FAILED", "ProjectSettings.save returned %d (key=%s); change is in-memory but not persisted" % [save_err, key]))
		return
	_send_result(peer, id, {
		"success": true,
		"key": key,
		"value": _serialize_value(coerced),
		"was_set_before": was_set_before,
		"previous_value": _serialize_value(previous_value) if was_set_before else null,
	})


# ---- Iter 15d: input_map.* ----
#
# Four tools writing to the InputMap singleton + mirroring to ProjectSettings
# input/<action> entries so changes survive editor restart. Persistence is
# fail-open (push_warning + success) because the in-memory change IS
# observable for the current session — agent can retry persistence after
# fixing root cause. Built-in `ui_*` actions are protected from removal.
# TODO(iter-19): wrap input_map_* in FeatureGate.is_enabled (single-gate;
# low security risk but persistent ProjectSettings mutation).


# Built-in DefaultUIAction list, pinned from Godot 4.4 source. Worth a
# cross-check at iter 16/17 if upgrading the engine baseline.
const _BUILTIN_UI_ACTIONS: Array[String] = [
	"ui_accept", "ui_cancel", "ui_focus_next", "ui_focus_prev",
	"ui_up", "ui_down", "ui_left", "ui_right",
	"ui_page_up", "ui_page_down", "ui_home", "ui_end",
	"ui_cut", "ui_copy", "ui_paste", "ui_undo", "ui_redo",
	"ui_text_completion_query", "ui_text_completion_accept", "ui_text_completion_replace",
	"ui_text_newline", "ui_text_newline_blank", "ui_text_newline_above",
	"ui_text_backspace", "ui_text_backspace_word", "ui_text_backspace_all_to_left",
	"ui_text_delete", "ui_text_delete_word", "ui_text_delete_all_to_right",
	"ui_text_caret_left", "ui_text_caret_word_left",
	"ui_text_caret_right", "ui_text_caret_word_right",
	"ui_text_caret_up", "ui_text_caret_down",
	"ui_text_caret_line_start", "ui_text_caret_line_end",
	"ui_text_caret_page_up", "ui_text_caret_page_down",
	"ui_text_caret_document_start", "ui_text_caret_document_end",
	"ui_text_caret_add_below", "ui_text_caret_add_above",
	"ui_text_scroll_up", "ui_text_scroll_down",
	"ui_text_select_all", "ui_text_select_word_under_caret",
	"ui_text_add_selection_for_next_occurrence", "ui_text_clear_carets_and_selection",
	"ui_text_toggle_insert_mode", "ui_menu", "ui_text_submit",
	"ui_graph_duplicate", "ui_graph_delete",
	"ui_filedialog_up_one_level", "ui_filedialog_refresh", "ui_filedialog_show_hidden",
	"ui_swap_input_direction",
]


# Build an InputEvent from the documented JSON shape. Returns the event
# instance on success or `{"error": "...", "code": "..."}` on failure so the
# caller can pattern-match on shape (mirrors _resolve_signal_pair).
func _build_input_event(event):
	if typeof(event) != TYPE_DICTIONARY:
		return {"code": "INVALID_PARAMS", "error": "event must be an object"}
	var t := str(event.get("type", ""))
	match t:
		"key":
			var raw_kc = event.get("keycode", "")
			var resolved_kc := 0
			if typeof(raw_kc) == TYPE_STRING:
				resolved_kc = OS.find_keycode_from_string(raw_kc)
				if resolved_kc == 0:
					return {"code": "INVALID_PARAMS", "error": "unknown keycode '%s'; use symbolic names like 'SPACE' / 'A' / 'F1' or raw ints" % raw_kc}
			elif typeof(raw_kc) == TYPE_INT or typeof(raw_kc) == TYPE_FLOAT:
				resolved_kc = int(raw_kc)
			else:
				return {"code": "INVALID_PARAMS", "error": "event.keycode must be a string symbolic name or int"}
			var ek := InputEventKey.new()
			ek.physical_keycode = resolved_kc
			ek.shift_pressed = bool(event.get("shift", false))
			ek.ctrl_pressed = bool(event.get("ctrl", false))
			ek.alt_pressed = bool(event.get("alt", false))
			ek.meta_pressed = bool(event.get("meta", false))
			return ek
		"mouse_button":
			var emb := InputEventMouseButton.new()
			emb.button_index = int(event.get("button_index", 1))
			emb.pressed = bool(event.get("pressed", true))
			return emb
		"joypad_button":
			var ejb := InputEventJoypadButton.new()
			ejb.button_index = int(event.get("button_index", 0))
			ejb.device = int(event.get("device", -1))
			return ejb
		"joypad_motion":
			var ejm := InputEventJoypadMotion.new()
			ejm.axis = int(event.get("axis", 0))
			ejm.axis_value = float(event.get("axis_value", 0.0))
			ejm.device = int(event.get("device", -1))
			return ejm
		_:
			return {"code": "INVALID_PARAMS", "error": "event.type must be one of 'key' | 'mouse_button' | 'joypad_button' | 'joypad_motion' (got %s)" % t}


# Inverse of _build_input_event for response payloads. Stable schema across
# iter 16/17 — agents pattern-match on `type` to round-trip.
func _serialise_input_event(e: InputEvent) -> Dictionary:
	if e is InputEventKey:
		return {
			"type": "key",
			"keycode": int((e as InputEventKey).physical_keycode),
			"shift": (e as InputEventKey).shift_pressed,
			"ctrl": (e as InputEventKey).ctrl_pressed,
			"alt": (e as InputEventKey).alt_pressed,
			"meta": (e as InputEventKey).meta_pressed,
		}
	if e is InputEventMouseButton:
		return {
			"type": "mouse_button",
			"button_index": int((e as InputEventMouseButton).button_index),
			"pressed": (e as InputEventMouseButton).pressed,
		}
	if e is InputEventJoypadButton:
		return {
			"type": "joypad_button",
			"button_index": int((e as InputEventJoypadButton).button_index),
			"device": int((e as InputEventJoypadButton).device),
		}
	if e is InputEventJoypadMotion:
		return {
			"type": "joypad_motion",
			"axis": int((e as InputEventJoypadMotion).axis),
			"axis_value": float((e as InputEventJoypadMotion).axis_value),
			"device": int((e as InputEventJoypadMotion).device),
		}
	return {"type": "unknown", "class": e.get_class()}


# Shallow equality across the four supported InputEvent kinds. Used for
# action_add_event idempotency + action_remove_event match.
func _input_events_equivalent(a: InputEvent, b: InputEvent) -> bool:
	if a == null or b == null:
		return false
	if a.get_class() != b.get_class():
		return false
	if a is InputEventKey and b is InputEventKey:
		var ak := a as InputEventKey
		var bk := b as InputEventKey
		return ak.physical_keycode == bk.physical_keycode \
			and ak.shift_pressed == bk.shift_pressed \
			and ak.ctrl_pressed == bk.ctrl_pressed \
			and ak.alt_pressed == bk.alt_pressed \
			and ak.meta_pressed == bk.meta_pressed
	if a is InputEventMouseButton and b is InputEventMouseButton:
		var am := a as InputEventMouseButton
		var bm := b as InputEventMouseButton
		return am.button_index == bm.button_index and am.pressed == bm.pressed
	if a is InputEventJoypadButton and b is InputEventJoypadButton:
		var aj := a as InputEventJoypadButton
		var bj := b as InputEventJoypadButton
		return aj.button_index == bj.button_index and aj.device == bj.device
	if a is InputEventJoypadMotion and b is InputEventJoypadMotion:
		var amo := a as InputEventJoypadMotion
		var bmo := b as InputEventJoypadMotion
		return amo.axis == bmo.axis \
			and amo.device == bmo.device \
			and is_equal_approx(amo.axis_value, bmo.axis_value)
	return false


# Persist the current InputMap state for `action` to ProjectSettings input/<action>.
# Best-effort save: warnings on failure but caller still returns success
# (the in-memory change is observable for this session).
func _persist_input_action(action: String, deadzone: float) -> void:
	var events: Array = []
	for ev in InputMap.action_get_events(action):
		events.append(ev)
	ProjectSettings.set_setting("input/" + action, {
		"deadzone": deadzone,
		"events": events,
	})
	var err := ProjectSettings.save()
	if err != OK:
		push_warning("[MCPServer] ProjectSettings.save after input_map mutation failed (err %d, action=%s); change is in-memory only" % [err, action])


func _cmd_input_map_add_action(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var action := str(params.get("action", ""))
	if action.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "action must be a non-empty string"))
		return
	var deadzone_raw = params.get("deadzone", 0.5)
	var deadzone := float(deadzone_raw) if (typeof(deadzone_raw) == TYPE_FLOAT or typeof(deadzone_raw) == TYPE_INT) else 0.5
	if deadzone < 0.0 or deadzone > 1.0:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "deadzone must be in [0.0, 1.0] (got %f)" % deadzone))
		return
	# I3 idempotency: silent return on duplicate. Reports EXISTING deadzone
	# (observable state); caller would need a dedicated input_map.set_deadzone
	# tool to update — out of scope for 15d (handoff note).
	if InputMap.has_action(action):
		_send_result(peer, id, {
			"success": true,
			"status": "returned",
			"action": action,
			"deadzone": InputMap.action_get_deadzone(action),
		})
		return
	InputMap.add_action(action, deadzone)
	_persist_input_action(action, deadzone)
	_send_result(peer, id, {
		"success": true,
		"status": "created",
		"action": action,
		"deadzone": deadzone,
	})


func _cmd_input_map_action_add_event(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var action := str(params.get("action", ""))
	if action.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "action must be a non-empty string"))
		return
	if not InputMap.has_action(action):
		_send_result(peer, id, mcp_error("NOT_FOUND", "no action '%s'; call input_map.add_action first" % action))
		return
	var built: Variant = _build_input_event(params.get("event", null))
	if typeof(built) == TYPE_DICTIONARY and built.has("error"):
		_send_result(peer, id, mcp_error(str(built["code"]), str(built["error"])))
		return
	var ev: InputEvent = built
	# Idempotency: equivalent event already bound → silent return.
	for existing in InputMap.action_get_events(action):
		if _input_events_equivalent(existing, ev):
			_send_result(peer, id, {
				"success": true,
				"status": "returned",
				"action": action,
				"event": _serialise_input_event(existing),
			})
			return
	InputMap.action_add_event(action, ev)
	_persist_input_action(action, InputMap.action_get_deadzone(action))
	_send_result(peer, id, {
		"success": true,
		"status": "created",
		"action": action,
		"event": _serialise_input_event(ev),
	})


func _cmd_input_map_action_remove_event(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var action := str(params.get("action", ""))
	if action.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "action must be a non-empty string"))
		return
	if not InputMap.has_action(action):
		_send_result(peer, id, mcp_error("NOT_FOUND", "no action '%s'" % action))
		return
	var built: Variant = _build_input_event(params.get("event", null))
	if typeof(built) == TYPE_DICTIONARY and built.has("error"):
		_send_result(peer, id, mcp_error(str(built["code"]), str(built["error"])))
		return
	var ev: InputEvent = built
	var existing_events := InputMap.action_get_events(action)
	var matched: InputEvent = null
	for existing in existing_events:
		if _input_events_equivalent(existing, ev):
			matched = existing
			break
	if matched == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "no matching event on action '%s' (found %d events)" % [action, existing_events.size()]))
		return
	InputMap.action_erase_event(action, matched)
	_persist_input_action(action, InputMap.action_get_deadzone(action))
	# No `status` — symmetric removes are updates, not creates.
	_send_result(peer, id, {
		"success": true,
		"action": action,
		"event": _serialise_input_event(matched),
	})


func _cmd_input_map_remove_action(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var action := str(params.get("action", ""))
	if action.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "action must be a non-empty string"))
		return
	if not InputMap.has_action(action):
		_send_result(peer, id, mcp_error("NOT_FOUND", "no action '%s'" % action))
		return
	if action in _BUILTIN_UI_ACTIONS:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "refusing to remove built-in UI action '%s' (would break editor/engine keyboard navigation); use input_map.action_remove_event to clear its bindings instead" % action))
		return
	InputMap.erase_action(action)
	if ProjectSettings.has_setting("input/" + action):
		ProjectSettings.clear("input/" + action)
		var err := ProjectSettings.save()
		if err != OK:
			push_warning("[MCPServer] ProjectSettings.save after input_map.remove_action failed (err %d, action=%s)" % [err, action])
	_send_result(peer, id, {
		"success": true,
		"action": action,
	})


# ---- Iter 15d: animation.* ----
#
# Three tools authoring AnimationPlayer keyframes (TYPE_VALUE tracks only —
# transform2d/transform3d/bezier/method/audio deferred per handoff note).
# UndoRedo-wrapped per project_delete_node_crash.md (matches scene.instantiate).


# Resolve player_path → AnimationPlayer + animation_name → Animation.
# Returns the tuple via dict; caller pattern-matches on `error`/`code`.
func _resolve_animation(player_path: String, animation_name: String) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return {"code": "NO_SCENE", "error": "no edited scene"}
	if player_path.is_empty():
		return {"code": "INVALID_PARAMS", "error": "missing player_path"}
	var node = _resolve_scene_node(player_path)
	if node == null:
		return {"code": "NOT_FOUND", "error": "no node at player_path %s" % player_path}
	if not (node is AnimationPlayer):
		return {"code": "INVALID_CLASS", "error": "node at %s is not an AnimationPlayer (got %s)" % [player_path, node.get_class()]}
	var player := node as AnimationPlayer
	if animation_name.is_empty():
		return {"code": "INVALID_PARAMS", "error": "missing animation_name"}
	if not player.has_animation(animation_name):
		var available: Array = []
		for n in player.get_animation_list():
			available.append(str(n))
			if available.size() >= 10:
				available.append("…")
				break
		return {"code": "NOT_FOUND", "error": "no animation '%s' on player %s; available: %s" % [animation_name, player_path, ", ".join(available)]}
	return {
		"player": player,
		"anim": player.get_animation(animation_name),
	}


func _cmd_animation_add_key(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var player_path := str(params.get("player_path", ""))
	var animation_name := str(params.get("animation_name", ""))
	var track_path := str(params.get("track_path", ""))
	var time_raw = params.get("time", 0.0)
	var time := float(time_raw) if (typeof(time_raw) == TYPE_FLOAT or typeof(time_raw) == TYPE_INT) else -1.0
	var track_type := str(params.get("track_type", ""))
	if not params.has("value"):
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing value"))
		return
	var raw_value = params.get("value", null)
	if time < 0.0:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "time must be >= 0 (got %f)" % time))
		return
	if track_path.is_empty() or not track_path.contains(":"):
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "track_path must include a property (e.g. 'Sprite2D:position'); method/transform/bezier tracks not supported in 15d"))
		return
	if not track_type.is_empty() and track_type != "value":
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "track_type='%s' not supported in 15d (only 'value' / default); transform2d/transform3d/bezier/method/audio deferred" % track_type))
		return
	var resolved := _resolve_animation(player_path, animation_name)
	if resolved.has("error"):
		_send_result(peer, id, mcp_error(str(resolved["code"]), str(resolved["error"])))
		return
	var anim: Animation = resolved["anim"]
	# Resource-ref pre-coerce gate (same load-bearing rationale as
	# node.set_property — null Resource → pink checkerboard at runtime).
	# TODO(iter-18): _coerce_value Resource path should route through FileGuard.
	var missing := _check_resource_paths(raw_value)
	if missing != "":
		_send_result(peer, id, mcp_error("LOAD_FAILED", "failed to load resource at %s; verify the path or use resource.create to create it first" % missing))
		return
	var coerced = _coerce_value(raw_value)
	# Track resolution.
	var track_idx := -1
	var track_path_np := NodePath(track_path)
	for i in range(anim.get_track_count()):
		if anim.track_get_path(i) == track_path_np:
			track_idx = i
			break
	if track_idx == -1:
		track_idx = anim.add_track(Animation.TYPE_VALUE)
		anim.track_set_path(track_idx, track_path_np)
	# Idempotency: exact-time key already present → silent return with the
	# EXISTING value (observable state).
	var existing_idx := anim.track_find_key(track_idx, time, Animation.FIND_MODE_EXACT)
	if existing_idx != -1:
		_send_result(peer, id, {
			"success": true,
			"status": "returned",
			"player_path": player_path,
			"animation_name": animation_name,
			"track_path": track_path,
			"track_idx": track_idx,
			"time": time,
			"key_idx": existing_idx,
			"value": _serialize_value(anim.track_get_key_value(track_idx, existing_idx)),
		})
		return
	# UndoRedo wrap — matches scene.instantiate pattern.
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("MCP: animation.add_key %s @ %s" % [track_path, time])
	undo_redo.add_do_method(anim, "track_insert_key", track_idx, time, coerced)
	# Undo finds-and-removes by exact time (the index may shift if other
	# keys are added/removed between do and undo, so resolving fresh here
	# is more robust than capturing the index now).
	undo_redo.add_undo_method(self, "_animation_remove_key_at", anim, track_idx, time)
	undo_redo.add_undo_reference(anim)
	undo_redo.commit_action()
	var new_idx := anim.track_find_key(track_idx, time, Animation.FIND_MODE_EXACT)
	_send_result(peer, id, {
		"success": true,
		"status": "created",
		"player_path": player_path,
		"animation_name": animation_name,
		"track_path": track_path,
		"track_idx": track_idx,
		"time": time,
		"key_idx": new_idx,
		"value": _serialize_value(coerced),
	})


# Helper for UndoRedo undo branch — resolves time → key_idx at undo time
# rather than capturing at do time (more robust to intervening edits).
func _animation_remove_key_at(anim: Animation, track_idx: int, time: float) -> void:
	var idx := anim.track_find_key(track_idx, time, Animation.FIND_MODE_EXACT)
	if idx != -1:
		anim.track_remove_key(track_idx, idx)


func _animation_insert_key_silent(anim: Animation, track_idx: int, time: float, value) -> void:
	# UndoRedo undo branch for animation.remove_key — restores the captured
	# previous value at the same time. Silent; mirror of _animation_remove_key_at.
	anim.track_insert_key(track_idx, time, value)


func _cmd_animation_remove_key(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var player_path := str(params.get("player_path", ""))
	var animation_name := str(params.get("animation_name", ""))
	var track_path := str(params.get("track_path", ""))
	var time_raw = params.get("time", -1.0)
	var time := float(time_raw) if (typeof(time_raw) == TYPE_FLOAT or typeof(time_raw) == TYPE_INT) else -1.0
	if time < 0.0:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "time must be >= 0 (got %f)" % time))
		return
	if track_path.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing track_path"))
		return
	var resolved := _resolve_animation(player_path, animation_name)
	if resolved.has("error"):
		_send_result(peer, id, mcp_error(str(resolved["code"]), str(resolved["error"])))
		return
	var anim: Animation = resolved["anim"]
	var track_idx := -1
	var track_path_np := NodePath(track_path)
	for i in range(anim.get_track_count()):
		if anim.track_get_path(i) == track_path_np:
			track_idx = i
			break
	if track_idx == -1:
		_send_result(peer, id, mcp_error("NOT_FOUND", "no track '%s' on animation '%s'" % [track_path, animation_name]))
		return
	var key_idx := anim.track_find_key(track_idx, time, Animation.FIND_MODE_EXACT)
	if key_idx == -1:
		_send_result(peer, id, mcp_error("NOT_FOUND", "no key at time=%f on track '%s'" % [time, track_path]))
		return
	var captured_value = anim.track_get_key_value(track_idx, key_idx)
	var serialised_value = _serialize_value(captured_value)
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("MCP: animation.remove_key %s @ %s" % [track_path, time])
	undo_redo.add_do_method(self, "_animation_remove_key_at", anim, track_idx, time)
	undo_redo.add_undo_method(self, "_animation_insert_key_silent", anim, track_idx, time, captured_value)
	undo_redo.add_undo_reference(anim)
	undo_redo.commit_action()
	_send_result(peer, id, {
		"success": true,
		"player_path": player_path,
		"animation_name": animation_name,
		"track_path": track_path,
		"time": time,
		"removed_value": serialised_value,
	})


func _cmd_animation_get_keys(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var player_path := str(params.get("player_path", ""))
	var animation_name := str(params.get("animation_name", ""))
	var track_path := str(params.get("track_path", ""))
	if track_path.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing track_path"))
		return
	var resolved := _resolve_animation(player_path, animation_name)
	if resolved.has("error"):
		_send_result(peer, id, mcp_error(str(resolved["code"]), str(resolved["error"])))
		return
	var anim: Animation = resolved["anim"]
	var track_idx := -1
	var track_path_np := NodePath(track_path)
	for i in range(anim.get_track_count()):
		if anim.track_get_path(i) == track_path_np:
			track_idx = i
			break
	if track_idx == -1:
		_send_result(peer, id, mcp_error("NOT_FOUND", "no track '%s' on animation '%s'" % [track_path, animation_name]))
		return
	var keys: Array = []
	for k in range(anim.track_get_key_count(track_idx)):
		keys.append({
			"time": anim.track_get_key_time(track_idx, k),
			"value": _serialize_value(anim.track_get_key_value(track_idx, k)),
			"transition": anim.track_get_key_transition(track_idx, k),
		})
	_send_result(peer, id, {
		"success": true,
		"player_path": player_path,
		"animation_name": animation_name,
		"track_path": track_path,
		"track_idx": track_idx,
		"track_type": _animation_track_type_name(anim.track_get_type(track_idx)),
		"length": anim.length,
		"keys": keys,
	})


func _animation_track_type_name(t: int) -> String:
	match t:
		Animation.TYPE_VALUE: return "value"
		Animation.TYPE_POSITION_3D: return "position_3d"
		Animation.TYPE_ROTATION_3D: return "rotation_3d"
		Animation.TYPE_SCALE_3D: return "scale_3d"
		Animation.TYPE_BLEND_SHAPE: return "blend_shape"
		Animation.TYPE_METHOD: return "method"
		Animation.TYPE_BEZIER: return "bezier"
		Animation.TYPE_AUDIO: return "audio"
		Animation.TYPE_ANIMATION: return "animation"
		_: return "unknown(%d)" % t


# ---- Iter 15d: tilemap.set_cells ----
#
# Batch cell painting under a single UndoRedo action — collapses what would
# otherwise be N round-trips into one. Supports both TileMap (deprecated in
# 4.3, still functional in 4.4) and TileMapLayer (4.3+). source_id:-1 clears
# a cell. Returns cells_written + cells_unchanged for observability.


func _cmd_tilemap_set_cells(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var tilemap_path := str(params.get("tilemap_path", ""))
	var layer := int(params.get("layer", 0))
	var cells_raw = params.get("cells", null)
	# TODO(iter-18): route `tilemap_path` through FileGuard.resolve_safe.
	if tilemap_path.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing tilemap_path"))
		return
	if typeof(cells_raw) != TYPE_ARRAY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "cells must be an Array of { x, y, source_id, atlas_x, atlas_y, alternative_tile? } descriptors"))
		return
	var cells: Array = cells_raw
	var node = _resolve_scene_node(tilemap_path)
	if node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "no node at %s" % tilemap_path))
		return
	var is_layer := node is TileMapLayer
	var is_map := node is TileMap
	if not (is_layer or is_map):
		_send_result(peer, id, mcp_error("INVALID_CLASS", "node at %s is not a TileMap or TileMapLayer (got %s); tilemap.set_cells only accepts tilemap-family nodes" % [tilemap_path, node.get_class()]))
		return
	# Per-cell shape check; bail on first malformed entry.
	var required_keys := ["x", "y", "source_id", "atlas_x", "atlas_y"]
	for ci in range(cells.size()):
		var c = cells[ci]
		if typeof(c) != TYPE_DICTIONARY:
			_send_result(peer, id, mcp_error("INVALID_PARAMS", "cells[%d] must be an object" % ci))
			return
		for k in required_keys:
			if not c.has(k):
				_send_result(peer, id, mcp_error("INVALID_PARAMS", "cells[%d] missing required key '%s'" % [ci, k]))
				return
	if is_map:
		var tm := node as TileMap
		var layer_count := tm.get_layers_count()
		if layer < 0 or layer >= layer_count:
			_send_result(peer, id, mcp_error("INVALID_PARAMS", "layer %d out of range [0, %d) for TileMap %s" % [layer, layer_count, tilemap_path]))
			return
	# Capture before-state per cell so undo can restore. O(n) — handler comment
	# in the plan flags an optional skip_undo escape hatch for iter 22 if very
	# large grids surface as an issue.
	var before_state: Array = []
	for ci in range(cells.size()):
		var c: Dictionary = cells[ci]
		var coord := Vector2i(int(c["x"]), int(c["y"]))
		var prev_source: int
		var prev_atlas: Vector2i
		var prev_alt: int
		if is_layer:
			var tl := node as TileMapLayer
			prev_source = tl.get_cell_source_id(coord)
			prev_atlas = tl.get_cell_atlas_coords(coord)
			prev_alt = tl.get_cell_alternative_tile(coord)
		else:
			var tm2 := node as TileMap
			prev_source = tm2.get_cell_source_id(layer, coord)
			prev_atlas = tm2.get_cell_atlas_coords(layer, coord)
			prev_alt = tm2.get_cell_alternative_tile(layer, coord)
		before_state.append({
			"coord": coord,
			"source_id": prev_source,
			"atlas": prev_atlas,
			"alternative_tile": prev_alt,
		})
	# Compute write counts (observability — agent sees no-op writes).
	var cells_written := 0
	var cells_unchanged := 0
	for ci in range(cells.size()):
		var c: Dictionary = cells[ci]
		var prev: Dictionary = before_state[ci]
		var new_source := int(c["source_id"])
		var new_atlas := Vector2i(int(c["atlas_x"]), int(c["atlas_y"]))
		var new_alt := int(c.get("alternative_tile", 0))
		if int(prev["source_id"]) == new_source \
				and (prev["atlas"] as Vector2i) == new_atlas \
				and int(prev["alternative_tile"]) == new_alt:
			cells_unchanged += 1
		else:
			cells_written += 1
	# UndoRedo: single action across the whole batch.
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("MCP: tilemap.set_cells %s (%d cells)" % [tilemap_path, cells.size()])
	undo_redo.add_do_method(self, "_tilemap_apply_batch", node, layer, cells)
	undo_redo.add_undo_method(self, "_tilemap_restore_batch", node, layer, before_state)
	undo_redo.add_do_reference(node)
	undo_redo.commit_action()
	_send_result(peer, id, {
		"success": true,
		"tilemap_path": tilemap_path,
		"layer": layer,
		"cells_written": cells_written,
		"cells_unchanged": cells_unchanged,
		"total": cells.size(),
	})


func _tilemap_apply_batch(node: Node, layer: int, cells: Array) -> void:
	var is_layer := node is TileMapLayer
	for c in cells:
		var coord := Vector2i(int(c["x"]), int(c["y"]))
		var source_id := int(c["source_id"])
		var atlas := Vector2i(int(c["atlas_x"]), int(c["atlas_y"]))
		var alt := int(c.get("alternative_tile", 0))
		if is_layer:
			(node as TileMapLayer).set_cell(coord, source_id, atlas, alt)
		else:
			(node as TileMap).set_cell(layer, coord, source_id, atlas, alt)


func _tilemap_restore_batch(node: Node, layer: int, before_state: Array) -> void:
	var is_layer := node is TileMapLayer
	for s in before_state:
		var coord: Vector2i = s["coord"]
		var source_id := int(s["source_id"])
		var atlas: Vector2i = s["atlas"]
		var alt := int(s["alternative_tile"])
		if is_layer:
			(node as TileMapLayer).set_cell(coord, source_id, atlas, alt)
		else:
			(node as TileMap).set_cell(layer, coord, source_id, atlas, alt)


# ---- Iter 15d: editor.screenshot_node ----
#
# Focus + capture a specific node in the editor viewport. Atomic
# focus-restore (prior selection preserved). Inline base64 PNG matches iter
# 07's editor.screenshot pattern. Best-effort framing: edit_node selects the
# node in the inspector + scene-tree dock; viewport camera is left where it
# is — known limitation documented in the toolkit README.


func _cmd_editor_screenshot_node(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	if path.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing path"))
		return
	var size_d: Dictionary = params.get("size", {}) if typeof(params.get("size", {})) == TYPE_DICTIONARY else {}
	var width := int(size_d.get("width", 1280))
	var height := int(size_d.get("height", 720))
	if width < 64 or width > 4096 or height < 64 or height > 4096:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "size.width and size.height must be in [64, 4096] (got %dx%d)" % [width, height]))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return
	var node = _resolve_scene_node(path)
	if node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "no node at %s" % path))
		return
	# Capture prior selection so we can restore at the end.
	var sel := EditorInterface.get_selection()
	var prior_selection: Array = []
	if sel != null:
		for n in sel.get_selected_nodes():
			prior_selection.append(n)
		sel.clear()
		sel.add_node(node)
	EditorInterface.edit_node(node)
	# One frame for the editor to repaint with the new selection.
	await RenderingServer.frame_post_draw
	# Pick viewport: 3D for Node3D, otherwise the 2D viewport (covers Node2D,
	# Control, and any non-3D parent like Node).
	var viewport: SubViewport = null
	if node is Node3D:
		viewport = EditorInterface.get_editor_viewport_3d(0)
	if viewport == null:
		viewport = EditorInterface.get_editor_viewport_2d()
	if viewport == null:
		_send_result(peer, id, mcp_error("INTERNAL", "no editor viewport available"))
		return
	var image := viewport.get_texture().get_image()
	if image == null:
		_send_result(peer, id, mcp_error("INTERNAL", "viewport texture unavailable (nothing rendered yet?)"))
		return
	# Resize to requested dimensions; LANCZOS preserves detail better than
	# bilinear for mixed UI / sprite content.
	if image.get_width() != width or image.get_height() != height:
		image.resize(width, height, Image.INTERPOLATE_LANCZOS)
	# Restore prior selection. If no prior selection, leave cleared (matches
	# pre-capture state). Best-effort — if a node was freed between capture
	# and restore we silently skip (defensive against editor undo / external
	# scene mutation during the await).
	if sel != null:
		sel.clear()
		for n in prior_selection:
			if is_instance_valid(n):
				sel.add_node(n)
	var png_bytes := image.save_png_to_buffer()
	if png_bytes.is_empty():
		_send_result(peer, id, mcp_error("INTERNAL", "save_png_to_buffer returned empty"))
		return
	_send_result(peer, id, {
		"image_base64": Marshalls.raw_to_base64(png_bytes),
		"mime_type": "image/png",
		"width": image.get_width(),
		"height": image.get_height(),
		"bytes": png_bytes.size(),
		"path": path,
	})


# ---- Asset discovery (iter 15e) ---------------------------------------------


func _cmd_asset_list(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		params = {}
	var path_prefix: String = str(params.get("path_prefix", "res://"))
	var name_glob: String = str(params.get("name_glob", ""))
	var class_filter: String = str(params.get("class_filter", ""))
	var extension_filter: Array = params.get("extension_filter", [])
	if typeof(extension_filter) != TYPE_ARRAY:
		extension_filter = []
	var max_results: int = int(params.get("max_results", 500))

	# TODO(iter-18): filter path_prefix through FileGuard.resolve_safe.
	if not path_prefix.begins_with("res://"):
		_send_result(peer, id, mcp_error("INVALID_PATH", "path_prefix must start with res:// (got %s)" % path_prefix))
		return
	if max_results < 1 or max_results > 2000:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "max_results must be in [1, 2000] (got %d); iter-20 adds a configurable ceiling" % max_results))
		return
	var efs := EditorInterface.get_resource_filesystem()
	if efs.is_scanning():
		_send_result(peer, id, mcp_error("FILESYSTEM_NOT_READY", "Godot's EditorFileSystem is mid-scan; retry in 500-2000ms (a wait-for-idle tool is planned for iter 15f or NextSteps)"))
		return
	if class_filter != "":
		var found_in_classdb := ClassDB.class_exists(class_filter)
		var found_in_global := false
		if not found_in_classdb:
			for gcl in ProjectSettings.get_global_class_list():
				if gcl.get("class", "") == class_filter:
					found_in_global = true
					break
		if not found_in_classdb and not found_in_global:
			_send_result(peer, id, mcp_error("INVALID_PARAMS", "unknown class_filter '%s'; checked ClassDB (engine classes) and ProjectSettings.get_global_class_list() (GDScript class_name / C# [GlobalClass])" % class_filter))
			return

	# Normalize extension_filter to lowercase strings
	var ext_filter: Array[String] = []
	for ext in extension_filter:
		ext_filter.append(str(ext).to_lower())

	var root_dir := efs.get_filesystem_path(path_prefix)
	if root_dir == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "no indexed directory at %s (path may exist on disk but not yet scanned — call editor.reload_scripts or wait for is_scanning to clear)" % path_prefix))
		return

	var entries: Array = []
	var truncated := _walk_efs_dir(root_dir, name_glob, class_filter, ext_filter, entries, max_results)

	_send_result(peer, id, {
		"success": true,
		"entries": entries,
		"count": entries.size(),
		"truncated": truncated,
		"path_prefix": path_prefix,
		"filters_applied": {
			"name_glob": name_glob,
			"class_filter": class_filter,
			"extension_filter": ext_filter,
		},
	})


# TODO(iter-22): add cursor pagination if large-project feedback emerges
func _walk_efs_dir(dir: EditorFileSystemDirectory, name_glob: String, class_filter: String, ext_filter: Array[String], entries: Array, max_count: int) -> bool:
	for i in range(dir.get_file_count()):
		if entries.size() >= max_count:
			return true
		var file_path := dir.get_file_path(i)
		var file_name := dir.get_file(i)
		var file_type := dir.get_file_type(i)

		# Apply filters
		if name_glob != "" and not file_name.matchn(name_glob):
			continue
		if ext_filter.size() > 0 and not file_name.get_extension().to_lower() in ext_filter:
			continue
		if class_filter != "":
			if file_type != class_filter and not ClassDB.is_parent_class(file_type, class_filter):
				continue

		entries.append({
			"path": file_path,
			"class": file_type,
			"size_bytes": null,
			"modified_unix": FileAccess.get_modified_time(file_path),
		})

	for j in range(dir.get_subdir_count()):
		if entries.size() >= max_count:
			return true
		if _walk_efs_dir(dir.get_subdir(j), name_glob, class_filter, ext_filter, entries, max_count):
			return true

	return false


func _cmd_asset_get_dependencies(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path: String = str(params.get("path", ""))
	var include_transitive: bool = bool(params.get("include_transitive", false))
	var max_results: int = int(params.get("max_results", 200))

	# TODO(iter-18): filter path through FileGuard.resolve_safe.
	if not path.begins_with("res://"):
		_send_result(peer, id, mcp_error("INVALID_PATH", "path must start with res:// (got %s)" % path))
		return
	if not FileAccess.file_exists(path):
		_send_result(peer, id, mcp_error("NOT_FOUND", "no file at %s" % path))
		return
	var efs := EditorInterface.get_resource_filesystem()
	if efs.is_scanning():
		_send_result(peer, id, mcp_error("FILESYSTEM_NOT_READY", "Godot's EditorFileSystem is mid-scan; retry in 500-2000ms (a wait-for-idle tool is planned for iter 15f or NextSteps)"))
		return

	var deps: Array = []
	var visited: Dictionary = {}
	var queue: Array[String] = [path]
	visited[path] = true
	var truncated := false
	var depth := 0

	while queue.size() > 0 and not truncated:
		var current := queue.pop_front() as String
		var raw_deps := ResourceLoader.get_dependencies(current)
		for raw_dep in raw_deps:
			if deps.size() >= max_results:
				truncated = true
				break
			# Format varies by Godot version:
			# Godot 4.4+: "uid://hash::::res://path" or "uid://hash::Type::res://path"
			# Earlier:     "res://path::Type" or "res://path::Type::uid://hash"
			var raw_str := String(raw_dep)
			var parts: PackedStringArray = raw_str.split("::")
			var stripped := parts[0]
			var dep_class := ""
			# If the first segment is a UID, look for a res:// path in later segments.
			if stripped.begins_with("uid://"):
				for p_idx in range(1, parts.size()):
					if parts[p_idx].begins_with("res://"):
						stripped = parts[p_idx]
						break
			# Extract class from the first non-empty, non-path segment.
			for p_idx in range(parts.size()):
				var seg := parts[p_idx]
				if seg != "" and not seg.begins_with("uid://") and not seg.begins_with("res://"):
					dep_class = seg
					break
			if stripped.is_empty():
				continue
			if visited.has(stripped):
				continue
			visited[stripped] = true
			deps.append({
				"path": stripped,
				"raw_path": raw_str,
				"class": dep_class,
			})
			if include_transitive:
				if FileAccess.file_exists(stripped):
					queue.append(stripped)
		depth += 1
		if depth > 50:
			truncated = true

	var warnings: Array[String] = []
	if depth > 50:
		warnings.append("transitive walk exceeded 50 levels — truncated to prevent unbounded recursion")

	_send_result(peer, id, {
		"success": true,
		"path": path,
		"dependencies": deps,
		"count": deps.size(),
		"truncated": truncated,
		"include_transitive": include_transitive,
		"warnings": warnings,
	})


# ---- Editor console reading (iter 15e) -------------------------------------


static func _detect_log_level(line: String) -> String:
	if line.begins_with("ERROR:") or line.begins_with("USER ERROR:") or line.begins_with("SCRIPT ERROR:"):
		return "error"
	if line.begins_with("WARNING:") or line.begins_with("USER WARNING:") or line.begins_with("SCRIPT WARNING:"):
		return "warning"
	return "info"


# Core console-log reader shared by editor.get_console and editor.get_errors.
# Returns either a success dict or an mcp_error dict.
func _read_console_log(limit: int, level_filter: Array, since_id: int) -> Dictionary:
	# TODO(iter-18): user://logs/ read is a narrow read-only exception to the
	# res://-only rule, distinct from iter 19b's user:// write tools. Explicitly
	# allowlist in iter 18's FileGuard module (editor.get_console +
	# editor.get_errors only — no other tool may read user:// without going
	# through iter 19b's whitelisted save.* tools).
	var logs_dir := "user://logs"
	if not DirAccess.dir_exists_absolute(logs_dir):
		return mcp_error("LOG_UNAVAILABLE", "no readable log file under user://logs/ (verify ProjectSettings 'application/config/use_file_logging' is true — default is true; playtest may have rotated the editor's log mid-session)")

	var all_files := DirAccess.get_files_at(logs_dir)
	var log_files: Array[String] = []
	for f in all_files:
		if String(f).ends_with(".log"):
			log_files.append(String(f))

	if log_files.is_empty():
		return mcp_error("LOG_UNAVAILABLE", "no readable log file under user://logs/ (verify ProjectSettings 'application/config/use_file_logging' is true — default is true; playtest may have rotated the editor's log mid-session)")

	# Selection heuristic: prefer godot.log if recent, else most-recent .log
	var chosen_file := ""
	var chosen_mtime: int = 0
	var warnings: Array[String] = []

	var godot_log := logs_dir + "/godot.log"
	var godot_log_mtime: int = 0
	if FileAccess.file_exists(godot_log):
		godot_log_mtime = FileAccess.get_modified_time(godot_log)

	if godot_log_mtime > 0 and godot_log_mtime >= _plugin_boot_time:
		chosen_file = godot_log
		chosen_mtime = godot_log_mtime
	else:
		# Find most-recently-modified .log with mtime >= boot time
		var best_file := ""
		var best_mtime: int = 0
		for lf in log_files:
			var full_path := logs_dir + "/" + lf
			var mtime := FileAccess.get_modified_time(full_path)
			if mtime >= _plugin_boot_time and mtime > best_mtime:
				best_file = full_path
				best_mtime = mtime
		if best_file != "":
			chosen_file = best_file
			chosen_mtime = best_mtime
		else:
			# Fallback: most-recently-modified .log regardless
			for lf in log_files:
				var full_path := logs_dir + "/" + lf
				var mtime := FileAccess.get_modified_time(full_path)
				if mtime > best_mtime:
					best_file = full_path
					best_mtime = mtime
			if best_file != "":
				chosen_file = best_file
				chosen_mtime = best_mtime
				warnings.append("fallback to stale log — no post-boot log found")

	if chosen_file == "":
		return mcp_error("LOG_UNAVAILABLE", "no readable log file under user://logs/ (verify ProjectSettings 'application/config/use_file_logging' is true — default is true; playtest may have rotated the editor's log mid-session)")

	var fa := FileAccess.open(chosen_file, FileAccess.READ)
	if fa == null:
		return mcp_error("LOG_UNAVAILABLE", "cannot open %s (err %d)" % [chosen_file, FileAccess.get_open_error()])
	var content := fa.get_as_text()
	fa.close()

	var lines := content.split("\n")
	var entries: Array = []
	var char_offset: int = 0

	for line_idx in range(lines.size()):
		var line: String = lines[line_idx]
		if line.strip_edges().is_empty():
			char_offset += line.length() + 1
			continue

		var level := _detect_log_level(line)

		# Continuation heuristic: no level prefix (info) + starts with
		# whitespace + preceding entry is error/warning → append to previous.
		if level == "info" and entries.size() > 0 and line.length() > 0:
			var fc := line[0]
			if fc == " " or fc == "\t" or line.begins_with("   at:"):
				var prev: Dictionary = entries[-1]
				if prev["level"] == "error" or prev["level"] == "warning":
					prev["message"] += "\n" + line
					char_offset += line.length() + 1
					continue

		entries.append({
			"id": char_offset,
			"level": level,
			"message": line,
			"timestamp_unix": null,
		})
		char_offset += line.length() + 1

	# Apply level_filter
	if level_filter.size() > 0:
		var level_set: Array[String] = []
		for lf in level_filter:
			level_set.append(str(lf))
		var filtered: Array = []
		for entry in entries:
			if entry["level"] in level_set:
				filtered.append(entry)
		entries = filtered

	# Apply since_id
	if since_id >= 0:
		var filtered: Array = []
		for entry in entries:
			if entry["id"] > since_id:
				filtered.append(entry)
		entries = filtered

	# Slice to last `limit` entries
	var truncated := entries.size() > limit
	if truncated:
		entries = entries.slice(entries.size() - limit)

	var next_id: int = -1
	if entries.size() > 0:
		next_id = entries[-1]["id"]

	return {
		"success": true,
		"entries": entries,
		"count": entries.size(),
		"next_id": next_id,
		"truncated": truncated,
		"log_file": chosen_file,
		"log_mtime": chosen_mtime,
		"warnings": warnings,
	}


func _cmd_editor_get_console(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		params = {}
	var limit: int = int(params.get("limit", 200))
	var level_filter: Array = params.get("level_filter", [])
	if typeof(level_filter) != TYPE_ARRAY:
		level_filter = []
	var since_id: int = int(params.get("since_id", -1))

	# Guards
	if limit < 1 or limit > 1000:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "limit must be in [1, 1000] (got %d)" % limit))
		return
	var valid_levels := ["info", "warning", "error"]
	for lf in level_filter:
		if not str(lf) in valid_levels:
			_send_result(peer, id, mcp_error("INVALID_PARAMS", "level_filter entries must be one of 'info' | 'warning' | 'error' (got %s)" % str(lf)))
			return

	var result := _read_console_log(limit, level_filter, since_id)
	_send_result(peer, id, result)
