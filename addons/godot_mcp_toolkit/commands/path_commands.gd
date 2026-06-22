@tool
extends RefCounted
## path2d.* command handlers — edit Path2D Curve2D points.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Helpers = Modules.CommandHelpers


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("path2d.edit_curve", func(parameters: Dictionary) -> Dictionary:
		return _cmd_edit_curve2d(parameters)
	, MCPToolkitCommandOptions.new())


# -- Commands -----------------------------------------------------------------


## Edits the **Curve2D** on a Path2D scene node (tool `path2d.edit_curve`). NOT
## `procedural.edit_curve`, which authors a 1D **Curve** .tres resource —
## different engine type, different aggregate. The private name carries the
## `2d` suffix so even internal symbols distinguish Curve from Curve2D.
static func _cmd_edit_curve2d(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["node_path", "action"])
	if err != null:
		return err

	var node_path := str(parameters.get("node_path", ""))
	var action := str(parameters.get("action", ""))
	var points_raw = parameters.get("points", null)
	var index_raw = parameters.get("index", null)

	if action not in ["set", "add", "remove", "clear"]:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"action must be one of: set, add, remove, clear (got '%s')" % action)

	var node = Helpers.resolve_scene_node(node_path)
	if node == null:
		return MCPToolkitError.fail("NODE_NOT_FOUND",
			"no node at path '%s' in edited scene" % node_path)
	if not (node is Path2D):
		return MCPToolkitError.fail("INVALID_CLASS",
			"node at '%s' is not a Path2D (got %s)" % [node_path, node.get_class()])

	var curve: Curve2D = node.curve
	if curve == null:
		curve = Curve2D.new()
		node.curve = curve

	match action:
		"set":
			if points_raw == null or typeof(points_raw) != TYPE_ARRAY:
				return MCPToolkitError.fail("INVALID_PARAMS",
					"action 'set' requires a 'points' array")
			return _action_set(node, curve, points_raw as Array)
		"add":
			if points_raw == null or typeof(points_raw) != TYPE_ARRAY:
				return MCPToolkitError.fail("INVALID_PARAMS",
					"action 'add' requires a 'points' array")
			var index: int = int(index_raw) if index_raw != null else -1
			return _action_add(node, curve, points_raw as Array, index)
		"remove":
			if index_raw == null:
				return MCPToolkitError.fail("INVALID_PARAMS",
					"action 'remove' requires an 'index'")
			return _action_remove(node, curve, int(index_raw))
		"clear":
			return _action_clear(node, curve)

	return MCPToolkitError.fail("INVALID_PARAMS", "unknown action '%s'" % action)


# -- Action helpers -----------------------------------------------------------


static func _action_set(node: Path2D, curve: Curve2D, points: Array) -> Dictionary:
	# Capture old state for undo.
	var old_curve := curve.duplicate() as Curve2D
	curve.clear_points()
	for i in range(points.size()):
		var pt = points[i]
		if typeof(pt) != TYPE_DICTIONARY or not pt.has("position"):
			return MCPToolkitError.fail("INVALID_PARAMS",
				"points[%d] must have a 'position' key with {x, y}" % i)
		var pos := _to_vec2(pt["position"])
		var in_h := _to_vec2(pt.get("in_handle")) if pt.has("in_handle") else Vector2.ZERO
		var out_h := _to_vec2(pt.get("out_handle")) if pt.has("out_handle") else Vector2.ZERO
		curve.add_point(pos, in_h, out_h)

	_wrap_undo_redo(node, curve, old_curve, "MCP: path2d.edit_curve set")
	return _ok(curve)


static func _action_add(node: Path2D, curve: Curve2D, points: Array, index: int) -> Dictionary:
	var old_curve := curve.duplicate() as Curve2D
	for i in range(points.size()):
		var pt = points[i]
		if typeof(pt) != TYPE_DICTIONARY or not pt.has("position"):
			return MCPToolkitError.fail("INVALID_PARAMS",
				"points[%d] must have a 'position' key with {x, y}" % i)
		var pos := _to_vec2(pt["position"])
		var in_h := _to_vec2(pt.get("in_handle")) if pt.has("in_handle") else Vector2.ZERO
		var out_h := _to_vec2(pt.get("out_handle")) if pt.has("out_handle") else Vector2.ZERO
		if index >= 0:
			curve.add_point(pos, in_h, out_h, index + i)
		else:
			curve.add_point(pos, in_h, out_h)

	_wrap_undo_redo(node, curve, old_curve, "MCP: path2d.edit_curve add")
	return _ok(curve)


static func _action_remove(node: Path2D, curve: Curve2D, index: int) -> Dictionary:
	if index < 0 or index >= curve.point_count:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"index %d out of range (point_count=%d)" % [index, curve.point_count])
	var old_curve := curve.duplicate() as Curve2D
	curve.remove_point(index)

	_wrap_undo_redo(node, curve, old_curve, "MCP: path2d.edit_curve remove")
	return _ok(curve)


static func _action_clear(node: Path2D, curve: Curve2D) -> Dictionary:
	var old_curve := curve.duplicate() as Curve2D
	curve.clear_points()

	_wrap_undo_redo(node, curve, old_curve, "MCP: path2d.edit_curve clear")
	return _ok(curve)


# -- Undo/Redo ---------------------------------------------------------------


static func _wrap_undo_redo(node: Path2D, curve: Curve2D, old_curve: Curve2D, action_name: String) -> void:
	MCPToolkitUndoRedoAction.begin(action_name.trim_prefix("MCP: "), node) \
		.do_property(node, &"curve", curve) \
		.undo_property(node, &"curve", old_curve) \
		.do_reference(curve) \
		.undo_reference(old_curve) \
		.commit_recorded()


# -- Helpers ------------------------------------------------------------------


static func _to_vec2(val) -> Vector2:
	if val == null:
		return Vector2.ZERO
	if val is Vector2:
		return val
	if typeof(val) == TYPE_DICTIONARY:
		return Vector2(float(val.get("x", 0.0)), float(val.get("y", 0.0)))
	return Vector2.ZERO


static func _ok(curve: Curve2D) -> Dictionary:
	return MCPToolkitSuccess.ok({
		"point_count": curve.point_count,
		"baked_length": curve.get_baked_length(),
	})
