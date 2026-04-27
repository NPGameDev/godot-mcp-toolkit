@tool
extends RefCounted
## signal.* command handlers — list, manage (connect/disconnect), emit on edited-scene nodes.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPCoerce = _Hub.MCPCoerce
const MCPCommandRegistry = _Hub.MCPCommandRegistry
const MCPHelpers = _Hub.MCPHelpers


static func register(registry: MCPCommandRegistry, _server: Node) -> void:
	registry.add("signal.list", func(parameters: Dictionary) -> Dictionary:
		return _cmd_signal_list(parameters))
	registry.add("signal.manage", func(parameters: Dictionary) -> Dictionary:
		return _cmd_signal_manage(parameters))
	registry.add("signal.emit", func(parameters: Dictionary) -> Dictionary:
		return _cmd_signal_emit(parameters))


# -- Helpers ------------------------------------------------------------------


static func _get_edited_root() -> Node:
	return MCPHelpers.get_edited_root()


static func _resolve_scene_node(node_path: String) -> Variant:
	return MCPHelpers.resolve_scene_node(node_path)


static func _signal_list_of(node: Object) -> Array:
	var result: Array = []
	for signal_info in node.get_signal_list():
		var arguments: Array = []
		for argument in signal_info.get("args", []):
			arguments.append({
				"name": str(argument.get("name", "")),
				"type": int(argument.get("type", 0)),
			})
		result.append({
			"name": str(signal_info.get("name", "")),
			"args": arguments,
		})
	return result


static func _resolve_signal_pair(parameters: Variant) -> Dictionary:
	if typeof(parameters) != TYPE_DICTIONARY:
		return {"code": "INVALID_PARAMS", "error": "params must be an object"}
	var source_path := str(parameters.get("source_path", ""))
	var signal_name := str(parameters.get("signal_name", ""))
	var target_path := str(parameters.get("target_path", ""))
	var method_name := str(parameters.get("method_name", ""))
	if source_path.is_empty() or signal_name.is_empty() \
			or target_path.is_empty() or method_name.is_empty():
		return {"code": "INVALID_PARAMS",
			"error": "source_path, signal_name, target_path, method_name are all required"}
	var root := _get_edited_root()
	if root == null:
		return {"code": "NO_SCENE", "error": "no edited scene"}
	var source = _resolve_scene_node(source_path)
	if source == null:
		return {"code": "NOT_FOUND",
			"error": "source node not found: %s" % source_path}
	var target = _resolve_scene_node(target_path)
	if target == null:
		return {"code": "NOT_FOUND",
			"error": "target node not found: %s" % target_path}
	if not source.has_signal(signal_name):
		return {"code": "INVALID_PARAMS",
			"error": "signal %s not on %s" % [signal_name, source_path]}
	if not target.has_method(method_name):
		return {"code": "INVALID_PARAMS",
			"error": "method %s not on %s" % [method_name, target_path]}
	return {
		"source": source,
		"target": target,
		"source_path": source_path,
		"target_path": target_path,
		"signal_name": signal_name,
		"method_name": method_name,
		"callable": Callable(target, method_name),
	}


# -- Commands -----------------------------------------------------------------


static func _cmd_signal_list(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return MCPError.make("NO_SCENE", "no edited scene")
	var node_path := str(parameters.get("node_path", ""))
	var node = _resolve_scene_node(node_path)
	if node == null:
		return MCPError.make("NOT_FOUND", "node not found: %s" % node_path, MCPError.HINT_NODE_PATH)
	return {"path": node_path, "signals": _signal_list_of(node)}


static func _cmd_signal_manage(parameters: Dictionary) -> Dictionary:
	var action := str(parameters.get("action", ""))
	if not (action in ["connect", "disconnect"]):
		return MCPError.make("INVALID_PARAMS",
			"action must be 'connect' or 'disconnect' (got '%s')" % action)
	var resolved := _resolve_signal_pair(parameters)
	if resolved.has("error"):
		return MCPError.make(str(resolved["code"]), str(resolved["error"]))
	var source = resolved["source"]
	var callable: Callable = resolved["callable"]
	var signal_name: String = str(resolved["signal_name"])
	var source_path: String = str(resolved["source_path"])
	var target_path: String = str(resolved["target_path"])
	var method_name: String = str(resolved["method_name"])
	if action == "connect":
		if source.is_connected(signal_name, callable):
			return {
				"success": true,
				"status": "returned",
				"source_path": source_path,
				"signal": signal_name,
				"target_path": target_path,
				"method": method_name,
			}
		var undo_redo = _Hub.get_undo_redo()
		if undo_redo != null:
			undo_redo.create_action("MCP: connect %s.%s -> %s.%s" % [
				source_path, signal_name, target_path, method_name])
			undo_redo.add_do_method(source, "connect", signal_name, callable)
			undo_redo.add_undo_method(source, "disconnect", signal_name, callable)
			undo_redo.commit_action()
		else:
			source.connect(signal_name, callable)
		return {
			"success": true,
			"status": "created",
			"source_path": source_path,
			"signal": signal_name,
			"target_path": target_path,
			"method": method_name,
		}
	else:
		if not source.is_connected(signal_name, callable):
			return MCPError.make("NOT_FOUND", "no connection to disconnect")
		var undo_redo = _Hub.get_undo_redo()
		if undo_redo != null:
			undo_redo.create_action("MCP: disconnect %s.%s -> %s.%s" % [
				source_path, signal_name, target_path, method_name])
			undo_redo.add_do_method(source, "disconnect", signal_name, callable)
			undo_redo.add_undo_method(source, "connect", signal_name, callable)
			undo_redo.commit_action()
		else:
			source.disconnect(signal_name, callable)
		return {
			"success": true,
			"source_path": source_path,
			"signal": signal_name,
			"target_path": target_path,
			"method": method_name,
		}


static func _cmd_signal_emit(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return MCPError.make("NO_SCENE", "no edited scene")
	var node_path := str(parameters.get("node_path", ""))
	var signal_name := str(parameters.get("signal_name", ""))
	if signal_name.is_empty():
		return MCPError.make("INVALID_PARAMS", "missing signal")
	var node = _resolve_scene_node(node_path)
	if node == null:
		return MCPError.make("NOT_FOUND", "node not found: %s" % node_path, MCPError.HINT_NODE_PATH)
	if not node.has_signal(signal_name):
		return MCPError.make("INVALID_PARAMS",
			"signal %s not on %s" % [signal_name, node_path])
	var raw_args = parameters.get("args", [])
	if typeof(raw_args) != TYPE_ARRAY:
		raw_args = []
	var coerced: Array = [signal_name]
	for argument in raw_args:
		coerced.append(MCPCoerce.coerce_value(argument))
	node.callv("emit_signal", coerced)
	return {"success": true}
