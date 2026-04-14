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

	node.queue_free()
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
