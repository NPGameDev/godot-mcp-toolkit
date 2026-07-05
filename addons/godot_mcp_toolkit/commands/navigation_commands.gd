@tool
extends RefCounted
## navigation.* command handlers — NavigationRegion2D polygon editing + baking.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Helpers = Modules.CommandHelpers


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("navigation.edit_polygon", func(parameters: Dictionary) -> Dictionary:
		return _cmd_edit_polygon(parameters)
	, MCPToolkitCommandOptions.new())


static func _cmd_edit_polygon(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["node_path", "action"])
	if err != null:
		return err

	var node_path := str(parameters["node_path"])
	var action := str(parameters["action"])

	var edited_scene := EditorInterface.get_edited_scene_root()
	if edited_scene == null:
		return MCPToolkitError.fail("NO_SCENE", "No scene is currently open in the editor")

	node_path = Helpers.normalize_editor_path(node_path)
	var node := edited_scene.get_node_or_null(NodePath(node_path))
	if node == null:
		return MCPToolkitError.fail("NOT_FOUND", "Node not found: " + node_path)

	if not (node is NavigationRegion2D):
		return MCPToolkitError.fail("INVALID_CLASS",
			"Expected NavigationRegion2D, got " + node.get_class())

	var region := node as NavigationRegion2D

	# Ensure the region has a NavigationPolygon resource
	var nav_poly := region.navigation_polygon
	if nav_poly == null:
		nav_poly = NavigationPolygon.new()
		region.navigation_polygon = nav_poly

	match action:
		"set":
			return _action_set(region, parameters, nav_poly)
		"add_outline":
			return _action_add_outline(region, parameters, nav_poly)
		"remove_outline":
			return _action_remove_outline(region, parameters, nav_poly)
		"clear":
			return _action_clear(region, nav_poly)
		"bake":
			return _action_bake(region, nav_poly)
		_:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"Unknown action '%s'; valid actions: set, add_outline, remove_outline, clear, bake" % action)


static func _action_set(region: NavigationRegion2D, parameters: Dictionary, nav_poly: NavigationPolygon) -> Dictionary:
	var outlines = parameters.get("outlines", null)
	if outlines == null or typeof(outlines) != TYPE_ARRAY or outlines.size() == 0:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"'outlines' must be a non-empty Array of outline arrays")

	# Capture old state for undo.
	var old_poly := nav_poly.duplicate() as NavigationPolygon
	nav_poly.clear_outlines()
	for outline_data in outlines:
		if typeof(outline_data) != TYPE_ARRAY:
			continue
		var packed := PackedVector2Array()
		for pt in outline_data:
			if typeof(pt) == TYPE_DICTIONARY:
				packed.append(Vector2(float(pt.get("x", 0)), float(pt.get("y", 0))))
		if packed.size() >= 3:
			nav_poly.add_outline(packed)

	_wrap_undo_redo(region, nav_poly, old_poly, "navigation.edit_polygon set")
	return _make_result(nav_poly)


static func _action_add_outline(region: NavigationRegion2D, parameters: Dictionary, nav_poly: NavigationPolygon) -> Dictionary:
	var outline_data = parameters.get("outline", null)
	if outline_data == null or typeof(outline_data) != TYPE_ARRAY:
		return MCPToolkitError.fail("INVALID_PARAMS", "'outline' must be an Array of {x, y} points")

	var packed := PackedVector2Array()
	for pt in outline_data:
		if typeof(pt) == TYPE_DICTIONARY:
			packed.append(Vector2(float(pt.get("x", 0)), float(pt.get("y", 0))))

	if packed.size() < 3:
		return MCPToolkitError.fail("INVALID_PARAMS", "Outline must have at least 3 points")

	var old_poly := nav_poly.duplicate() as NavigationPolygon
	nav_poly.add_outline(packed)

	_wrap_undo_redo(region, nav_poly, old_poly, "navigation.edit_polygon add_outline")
	return _make_result(nav_poly)


static func _action_remove_outline(region: NavigationRegion2D, parameters: Dictionary, nav_poly: NavigationPolygon) -> Dictionary:
	var index = parameters.get("index", null)
	if index == null:
		return MCPToolkitError.fail("INVALID_PARAMS", "'index' is required for remove_outline")

	var idx := int(index)
	if idx < 0 or idx >= nav_poly.get_outline_count():
		return MCPToolkitError.fail("INVALID_PARAMS",
			"Outline index %d out of range (0..%d)" % [idx, nav_poly.get_outline_count() - 1])

	var old_poly := nav_poly.duplicate() as NavigationPolygon
	nav_poly.remove_outline(idx)

	_wrap_undo_redo(region, nav_poly, old_poly, "navigation.edit_polygon remove_outline")
	return _make_result(nav_poly)


static func _action_clear(region: NavigationRegion2D, nav_poly: NavigationPolygon) -> Dictionary:
	var old_poly := nav_poly.duplicate() as NavigationPolygon
	nav_poly.clear_outlines()
	nav_poly.clear_polygons()

	_wrap_undo_redo(region, nav_poly, old_poly, "navigation.edit_polygon clear")
	return MCPToolkitSuccess.ok({"outline_count": 0, "vertex_count": 0})


static func _action_bake(region: NavigationRegion2D, nav_poly: NavigationPolygon) -> Dictionary:
	if nav_poly.get_outline_count() == 0:
		return MCPToolkitError.fail("INVALID_PARAMS", "Cannot bake: no outlines defined")

	# NavigationServer2D baking (parse/bake_from_source_geometry_data) is present on
	# all supported versions (4.2-4.7); has_method() guards it defensively.
	if NavigationServer2D.has_method("bake_from_source_geometry_data"):
		var source := NavigationMeshSourceGeometryData2D.new()
		NavigationServer2D.parse_source_geometry_data(nav_poly, source, region)
		NavigationServer2D.bake_from_source_geometry_data(nav_poly, source)
	else:
		# Deprecated fallback — unreachable on 4.2-4.7 (bake API present since 4.2)
		nav_poly.make_polygons_from_outlines()

	var vertex_count := 0
	for i in nav_poly.get_polygon_count():
		vertex_count += nav_poly.get_polygon(i).size()

	return MCPToolkitSuccess.ok({
		"outline_count": nav_poly.get_outline_count(),
		"polygon_count": nav_poly.get_polygon_count(),
		"vertex_count": vertex_count,
	})


# -- Undo/Redo ---------------------------------------------------------------


# Register the already-applied polygon mutation with the editor's UndoRedo (same
# node-hosted-resource shape as path2d.edit_curve): redo re-assigns the mutated
# polygon, undo restores the pre-mutation duplicate; both resources are reference-
# pinned so neither can be collected while the history entry lives. bake is
# deliberately NOT wrapped — baked polygons are derivative of the outlines.
static func _wrap_undo_redo(region: NavigationRegion2D, nav_poly: NavigationPolygon,
		old_poly: NavigationPolygon, action_name: String) -> void:
	MCPToolkitUndoRedoAction.begin(action_name, region) \
		.do_property(region, &"navigation_polygon", nav_poly) \
		.undo_property(region, &"navigation_polygon", old_poly) \
		.do_reference(nav_poly) \
		.undo_reference(old_poly) \
		.commit_recorded()


static func _make_result(nav_poly: NavigationPolygon) -> Dictionary:
	var total_vertices := 0
	for i in nav_poly.get_outline_count():
		total_vertices += nav_poly.get_outline(i).size()
	return MCPToolkitSuccess.ok({
		"outline_count": nav_poly.get_outline_count(),
		"vertex_count": total_vertices,
	})
