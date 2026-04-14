@tool
extends Node

const PORT := 6505
const BIND := "127.0.0.1"
const JSONRPC_VERSION := "2.0"

var _tcp_server: TCPServer = null
var _peers: Array[WebSocketPeer] = []


func start() -> void:
	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(PORT, BIND)
	if err != OK:
		push_error("[MCPServer] failed to bind %s:%d (error %d)" % [BIND, PORT, err])
		_tcp_server = null
		return
	print("[MCPServer] listening on %s:%d" % [BIND, PORT])


func stop() -> void:
	for peer in _peers:
		if peer != null:
			peer.close(1000)
	_peers.clear()
	if _tcp_server != null:
		_tcp_server.stop()
		_tcp_server = null
	print("[MCPServer] stopped")


func _process(_delta: float) -> void:
	if _tcp_server == null:
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
		"node.set_property":
			_cmd_node_set_property(peer, id, params)
		"node.get_property":
			_cmd_node_get_property(peer, id, params)
		"script.read":
			_cmd_script_read(peer, id, params)
		"script.write":
			_cmd_script_write(peer, id, params)
		"editor.get_errors":
			_cmd_editor_get_errors(peer, id)
		"editor.save_scene":
			_cmd_editor_save_scene(peer, id, params)
		"editor.screenshot":
			_cmd_editor_screenshot(peer, id, params)
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


func _err(code: String, error: String) -> Dictionary:
	return {"code": code, "error": error}


# Returned paths are *relative to the edited scene root* — keeps responses
# compact (no editor-internal /@EditorNode@.../@SubViewport@.../... leak) and
# round-trips cleanly because Node.get_node_or_null() accepts relative paths.
# The root itself serialises as "." per NodePath convention.
func _path_in_scene(scene_root: Node, node: Node) -> String:
	return str(scene_root.get_path_to(node))


func _cmd_scene_get_tree(peer: WebSocketPeer, id) -> void:
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, _err("NO_SCENE", "no edited scene"))
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
		_send_result(peer, id, _err("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, _err("NO_SCENE", "no edited scene"))
		return

	var cls := str(params.get("class_name", ""))
	var parent_path := str(params.get("parent", ""))
	# TODO(iter-18): filter `parent_path` through FileGuard.resolve_safe.
	var requested_name := str(params.get("name", cls))

	if cls.is_empty():
		_send_result(peer, id, _err("INVALID_PARAMS", "missing class_name"))
		return
	if not ClassDB.class_exists(cls):
		_send_result(peer, id, _err("INVALID_CLASS", "unknown class: %s" % cls))
		return
	if not ClassDB.can_instantiate(cls):
		_send_result(peer, id, _err("INVALID_CLASS", "class is not instantiable (abstract, virtual, or editor-only): %s" % cls))
		return
	if not ClassDB.is_parent_class(cls, "Node"):
		_send_result(peer, id, _err("INVALID_CLASS", "not a Node subclass: %s" % cls))
		return

	var parent_node := root.get_node_or_null(parent_path) if not parent_path.is_empty() else root
	if parent_node == null:
		_send_result(peer, id, _err("NOT_FOUND", "parent not found: %s" % parent_path))
		return

	# I3 idempotency: same-name child already present -> return it, don't duplicate.
	var existing := parent_node.get_node_or_null(NodePath(requested_name))
	if existing != null:
		_send_result(peer, id, {"path": _path_in_scene(root, existing), "code": "ALREADY_EXISTS"})
		return

	var instance = ClassDB.instantiate(cls)
	if instance == null or not (instance is Node):
		_send_result(peer, id, _err("INVALID_CLASS", "instantiate failed: %s" % cls))
		return

	instance.name = requested_name
	parent_node.add_child(instance)
	instance.set_owner(root)
	_send_result(peer, id, {"path": _path_in_scene(root, instance)})


func _cmd_scene_delete_node(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, _err("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, _err("NO_SCENE", "no edited scene"))
		return

	var path := str(params.get("path", ""))
	# TODO(iter-18): filter `path` through FileGuard.resolve_safe.
	if path.is_empty():
		_send_result(peer, id, _err("INVALID_PARAMS", "missing path"))
		return

	var node := root.get_node_or_null(path)
	if node == null:
		_send_result(peer, id, _err("NOT_FOUND", "node not found: %s" % path))
		return
	if node == root:
		_send_result(peer, id, _err("INVALID_PATH", "cannot delete edited scene root"))
		return

	# Editor-safe deletion via UndoRedo. Pattern matches godot-mcp-pro and
	# godotiq: the node is detached from the tree by the action, but
	# add_undo_reference(node) keeps a reference alive in the undo history,
	# so the editor's SceneTreeDock / Inspector never see a dangling pointer.
	# Plain queue_free() or synchronous free() on an editor-owned node is a
	# SIGSEGV hazard on Godot 4.4.1 Windows when any FileAccess write follows.
	var parent := node.get_parent()
	if parent == null:
		_send_result(peer, id, _err("INTERNAL", "node has no parent: %s" % path))
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
		_send_result(peer, id, _err("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, _err("NO_SCENE", "no edited scene"))
		return

	var path := str(params.get("path", ""))
	var property := str(params.get("property", ""))
	var raw_value = params.get("value", null)
	# TODO(iter-18): filter `path` through FileGuard.resolve_safe.

	if path.is_empty() or property.is_empty():
		_send_result(peer, id, _err("INVALID_PARAMS", "missing path or property"))
		return

	var node := root.get_node_or_null(path)
	if node == null:
		_send_result(peer, id, _err("NOT_FOUND", "node not found: %s" % path))
		return

	var coerced = _coerce_value(raw_value)
	node.set(property, coerced)
	_send_result(peer, id, {"ok": true})


func _cmd_node_get_property(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, _err("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, _err("NO_SCENE", "no edited scene"))
		return

	var path := str(params.get("path", ""))
	var property := str(params.get("property", ""))
	# TODO(iter-18): filter `path` through FileGuard.resolve_safe.

	if path.is_empty() or property.is_empty():
		_send_result(peer, id, _err("INVALID_PARAMS", "missing path or property"))
		return

	var node := root.get_node_or_null(path)
	if node == null:
		_send_result(peer, id, _err("NOT_FOUND", "node not found: %s" % path))
		return

	_send_result(peer, id, {"value": _serialize_value(node.get(property))})


func _coerce_value(v):
	# Dict-wrapped engine types: {type:"Vector2",x:..,y:..} -> Vector2(..).
	# Plain JSON primitives pass through unchanged.
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


func _serialize_value(v):
	# JSON-native scalars pass through. Engine types (Vector2, Color, NodePath, ...)
	# get the lossless var_to_str string form so the TS side can round-trip via str_to_var.
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return v
		_:
			return var_to_str(v)


# ---- Script / editor command helpers (iter 04) ----------------------------


func _cmd_script_read(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, _err("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	# TODO(iter-18): replace this prefix check with FileGuard.resolve_safe(path).
	if not path.begins_with("res://"):
		_send_result(peer, id, _err("PATH_DENIED", "path must start with res://: %s" % path))
		return
	if not FileAccess.file_exists(path):
		_send_result(peer, id, _err("NOT_FOUND", "file not found: %s" % path))
		return
	var content := FileAccess.get_file_as_string(path)
	var open_err := FileAccess.get_open_error()
	if open_err != OK:
		_send_result(peer, id, _err("READ_FAILED", "FileAccess error %d reading %s" % [open_err, path]))
		return
	# TODO(iter-18): wrap content in <untrusted kind="script_content" source="<path>"> envelope.
	_send_result(peer, id, {"content": content})


func _cmd_script_write(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, _err("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	# TODO(iter-18): replace this prefix check with FileGuard.resolve_safe(path).
	if not path.begins_with("res://"):
		_send_result(peer, id, _err("PATH_DENIED", "path must start with res://: %s" % path))
		return
	if not params.has("content"):
		_send_result(peer, id, _err("INVALID_PARAMS", "missing content"))
		return
	var content := str(params.get("content", ""))
	# I5: never wrap user-destination content — `content` is written to disk verbatim.
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		var open_err := FileAccess.get_open_error()
		_send_result(peer, id, _err("WRITE_FAILED", "could not open %s for write (err %d)" % [path, open_err]))
		return
	file.store_string(content)
	file.close()
	# Byte count (UTF-8 encoded), not char count — matters for non-ASCII.
	var bytes_written := content.to_utf8_buffer().size()
	_send_result(peer, id, {"ok": true, "bytes": bytes_written})


func _cmd_editor_get_errors(peer: WebSocketPeer, id) -> void:
	# MVP stub. Iter 10 (debugger_get_log) replaces this with proper
	# EngineDebugger capture of script parse errors and runtime exceptions
	# routed through the editor's debugger subsystem. Returning an empty
	# errors list here is explicit about being incomplete so callers can
	# detect the stub by checking `stub == true`.
	_send_result(peer, id, {
		"errors": [],
		"stub": true,
		"note": "MVP stub; full error capture lands in iter 10 (debugger_get_log)",
	})


func _cmd_editor_save_scene(peer: WebSocketPeer, id, params) -> void:
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, _err("NO_SCENE", "no edited scene"))
		return
	var save_path := ""
	if typeof(params) == TYPE_DICTIONARY:
		save_path = str(params.get("path", ""))
	if save_path.is_empty():
		var err := EditorInterface.save_scene()
		if err != OK:
			_send_result(peer, id, _err("SAVE_FAILED", "EditorInterface.save_scene returned %d" % err))
			return
	else:
		# TODO(iter-18): validate save_path through FileGuard.resolve_safe.
		if not save_path.begins_with("res://"):
			_send_result(peer, id, _err("PATH_DENIED", "save path must start with res://: %s" % save_path))
			return
		EditorInterface.save_scene_as(save_path)
		# save_scene_as returns void in 4.4; verify by existence.
		if not FileAccess.file_exists(save_path):
			_send_result(peer, id, _err("SAVE_FAILED", "save_scene_as did not produce %s" % save_path))
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
		_send_result(peer, id, _err("INTERNAL", "no editor viewport available"))
		return
	var image := viewport.get_texture().get_image()
	if image == null:
		_send_result(peer, id, _err("INTERNAL", "viewport texture unavailable (nothing rendered yet?)"))
		return

	var png_bytes := image.save_png_to_buffer()
	if png_bytes.is_empty():
		_send_result(peer, id, _err("INTERNAL", "save_png_to_buffer returned empty"))
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
			_send_result(peer, id, _err("PATH_DENIED", "save_path must start with res://: %s" % save_path))
			return
		if not save_path.ends_with(".png"):
			_send_result(peer, id, _err("INVALID_PARAMS", "save_path must end with .png: %s" % save_path))
			return
		var dir_path := save_path.get_base_dir()
		if not dir_path.is_empty():
			var dir_err := DirAccess.make_dir_recursive_absolute(dir_path)
			if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
				_send_result(peer, id, _err("INTERNAL", "could not create %s (err %d)" % [dir_path, dir_err]))
				return
		var save_err := image.save_png(save_path)
		if save_err != OK:
			_send_result(peer, id, _err("INTERNAL", "save_png failed (err %d) for %s" % [save_err, save_path]))
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
