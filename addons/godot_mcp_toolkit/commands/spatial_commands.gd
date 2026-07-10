@tool
extends RefCounted
## scene.spatial_map — read-only 2D/3D spatial layout of the current edited scene.
##
## Closes the LLM spatial-reasoning blindspot: per-node world position, bounds
## (2D Rect2 / 3D AABB), size, and the computed relations LLMs can't easily
## derive blind — pairwise overlaps, containment, and nearest-neighbour gaps.
## Read-only and tab-dependent (operates on EditorInterface.get_edited_scene_root).
##
## Published under the `scene.*` prefix (`scene.spatial_map`) because it reads
## the currently edited scene — it belongs beside `scene.create`/`scene.delete`,
## not in a standalone "spatial" namespace. The file noun "spatial" is internal
## vocabulary; the scene-read is the contract.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Helpers = Modules.CommandHelpers

## Hard cap on nodes returned (also bounds the O(n^2) relation pass).
const DEFAULT_MAX_NODES := 200
const HARD_MAX_NODES := 1000


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("scene.spatial_map", func(parameters: Dictionary) -> Dictionary:
		return _cmd_spatial_map(parameters)
	, MCPToolkitCommandOptions.new()
		.mark_read_only()
		.with_success_hint(
			"Reason about clear positions from the overlaps/gaps, then place or move "
			+ "nodes with node_set_property (e.g. position / global_position)."))


static func _cmd_spatial_map(parameters: Dictionary) -> Dictionary:
	var root := Helpers.get_edited_root()
	if root == null:
		return MCPToolkitError.fail("NO_SCENE",
			"no scene is open in the editor; open a scene tab first (scene.open) before mapping its layout")

	var detail := str(parameters.get("detail", "normal")).to_lower()
	if detail not in ["brief", "normal", "full"]:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"detail must be one of 'brief', 'normal', 'full' (got '%s')" % detail)

	var class_filter := str(parameters.get("class", ""))
	var subtree_path := str(parameters.get("subtree", ""))
	var max_nodes := int(parameters.get("max_nodes", DEFAULT_MAX_NODES))
	if max_nodes <= 0 or max_nodes > HARD_MAX_NODES:
		max_nodes = DEFAULT_MAX_NODES

	# Optional region / radius filters (dimensionality decides 2D vs 3D scope).
	var region_filter = _parse_region(parameters.get("region", null))
	if typeof(region_filter) == TYPE_DICTIONARY and region_filter.has("error"):
		return region_filter
	var radius_filter = _parse_radius(parameters)
	if typeof(radius_filter) == TYPE_DICTIONARY and radius_filter.has("error"):
		return radius_filter

	# Resolve the walk root (whole scene, or a subtree).
	var walk_root: Node = root
	if subtree_path != "" and subtree_path != ".":
		walk_root = root.get_node_or_null(subtree_path)
		if walk_root == null:
			return MCPToolkitError.fail("NOT_FOUND",
				"subtree node not found: %s" % subtree_path, MCPToolkitError.HINT_NODE_PATH)

	# Gather spatial entries.
	var entries: Array = []
	var total_spatial := 0
	for node in _iter_tree(walk_root):
		if class_filter != "" and not _node_is_class(node, class_filter):
			continue
		var bounds = _world_bounds(node)
		if bounds == null:
			continue  # non-spatial node (plain Node, resources, etc.)
		if not _passes_filters(bounds, region_filter, radius_filter):
			continue
		total_spatial += 1
		if entries.size() >= max_nodes:
			continue  # keep counting total, stop collecting
		entries.append({
			"node": node,
			"path": _rel_path(root, node),
			"class": node.get_class(),
			"bounds": bounds,
		})

	# Compute relations (skipped for brief).
	if detail != "brief":
		_compute_relations(entries, detail)

	# Serialize.
	var nodes_out: Array = []
	var count_2d := 0
	var count_3d := 0
	for e in entries:
		var bounds = e["bounds"]
		var is_2d := typeof(bounds) == TYPE_RECT2
		if is_2d:
			count_2d += 1
		else:
			count_3d += 1
		var row := {
			"path": e["path"],
			"class": e["class"],
			"space": "2d" if is_2d else "3d",
			"position": _vec_to_array(bounds.position),
			"size": _vec_to_array(bounds.size),
		}
		if detail != "brief":
			row["bounds"] = {
				"position": _vec_to_array(bounds.position),
				"size": _vec_to_array(bounds.size),
			}
			row["overlaps"] = e.get("overlaps", [])
		if detail == "full":
			row["contains"] = e.get("contains", [])
			row["contained_by"] = e.get("contained_by", [])
			if e.has("nearest"):
				row["nearest"] = e["nearest"]
		nodes_out.append(row)

	var space := "empty"
	if count_2d > 0 and count_3d > 0:
		space = "mixed"
	elif count_2d > 0:
		space = "2d"
	elif count_3d > 0:
		space = "3d"

	# total_nodes: full match count (counted past the cap); cursor-less — narrow
	# with filters or raise max_nodes to resume.
	var has_more := total_spatial > nodes_out.size()
	var hint := ""
	if has_more:
		hint = ("%d of %d spatial nodes returned (capped at max_nodes) — narrow with "
			+ "subtree / class / region / radius, or raise max_nodes (<= %d).") % [
				nodes_out.size(), total_spatial, HARD_MAX_NODES]
	var result := Modules.Pagination.build(
		{"space": space, "detail": detail, "nodes": nodes_out},
		"nodes", total_spatial, nodes_out.size(), has_more, "", 0, hint)
	return MCPToolkitSuccess.ok(result)


# -- Geometry -----------------------------------------------------------------


## World-space bounds for a node: Rect2 (2D) or AABB (3D), or null if the node
## has no spatial representation.
static func _world_bounds(node: Node) -> Variant:
	if node is Control:
		return (node as Control).get_global_rect()
	if node is Node2D:
		var n2d := node as Node2D
		if n2d.has_method("get_rect"):
			var local_rect: Rect2 = n2d.call("get_rect")
			return _xform_rect2(n2d.get_global_transform(), local_rect)
		return Rect2(n2d.global_position, Vector2.ZERO)
	if node is VisualInstance3D:
		var vi := node as VisualInstance3D
		return _xform_aabb(vi.global_transform, vi.get_aabb())
	if node is Node3D:
		return AABB((node as Node3D).global_position, Vector3.ZERO)
	return null


## Transform a local Rect2 by a Transform2D into a world-space AABB (4 corners).
static func _xform_rect2(xform: Transform2D, rect: Rect2) -> Rect2:
	var p0 := xform * rect.position
	var corners := [
		p0,
		xform * (rect.position + Vector2(rect.size.x, 0)),
		xform * (rect.position + Vector2(0, rect.size.y)),
		xform * (rect.position + rect.size),
	]
	var out := Rect2(p0, Vector2.ZERO)
	for c in corners:
		out = out.expand(c)
	return out


## Transform a local AABB by a Transform3D into a world-space AABB (8 corners).
static func _xform_aabb(xform: Transform3D, aabb: AABB) -> AABB:
	var p0: Vector3 = xform * aabb.position
	var out := AABB(p0, Vector3.ZERO)
	for i in range(8):
		var corner := aabb.position + Vector3(
			aabb.size.x if (i & 1) else 0.0,
			aabb.size.y if (i & 2) else 0.0,
			aabb.size.z if (i & 4) else 0.0)
		out = out.expand(xform * corner)
	return out


## Pairwise overlap / containment / nearest-neighbour, same-space only.
static func _compute_relations(entries: Array, detail: String) -> void:
	for e in entries:
		e["overlaps"] = []
		if detail == "full":
			e["contains"] = []
			e["contained_by"] = []
	var n := entries.size()
	var nearest_dist := []
	nearest_dist.resize(n)
	nearest_dist.fill(INF)
	for i in range(n):
		var bi = entries[i]["bounds"]
		var i_is_2d := typeof(bi) == TYPE_RECT2
		for j in range(i + 1, n):
			var bj = entries[j]["bounds"]
			if (typeof(bj) == TYPE_RECT2) != i_is_2d:
				continue  # never relate across 2D/3D
			if bi.intersects(bj):
				entries[i]["overlaps"].append(entries[j]["path"])
				entries[j]["overlaps"].append(entries[i]["path"])
			if detail == "full":
				if bi.encloses(bj):
					entries[i]["contains"].append(entries[j]["path"])
					entries[j]["contained_by"].append(entries[i]["path"])
				elif bj.encloses(bi):
					entries[j]["contains"].append(entries[i]["path"])
					entries[i]["contained_by"].append(entries[j]["path"])
				var d: float = bi.get_center().distance_to(bj.get_center())
				if d < nearest_dist[i]:
					nearest_dist[i] = d
					entries[i]["nearest"] = {"path": entries[j]["path"], "distance": snappedf(d, 0.001)}
				if d < nearest_dist[j]:
					nearest_dist[j] = d
					entries[j]["nearest"] = {"path": entries[i]["path"], "distance": snappedf(d, 0.001)}


# -- Filters ------------------------------------------------------------------


## Parse an optional region filter: [x,y,w,h] (2D) or [x,y,z,sx,sy,sz] (3D).
## Returns null (no filter), a Rect2, an AABB, or an {error} dict.
static func _parse_region(raw: Variant) -> Variant:
	if raw == null:
		return null
	if typeof(raw) != TYPE_ARRAY:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"region must be an array [x,y,w,h] (2D) or [x,y,z,sx,sy,sz] (3D)")
	var a := raw as Array
	if a.size() == 4:
		return Rect2(float(a[0]), float(a[1]), float(a[2]), float(a[3]))
	if a.size() == 6:
		return AABB(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]))
	return MCPToolkitError.fail("INVALID_PARAMS",
		"region must have 4 numbers (2D [x,y,w,h]) or 6 (3D [x,y,z,sx,sy,sz]); got %d" % a.size())


## Parse an optional radius+center filter. Returns null or {center, radius, is_2d}
## or an {error} dict.
static func _parse_radius(parameters: Dictionary) -> Variant:
	if not parameters.has("radius"):
		return null
	var radius := float(parameters.get("radius", 0.0))
	if radius <= 0.0:
		return MCPToolkitError.fail("INVALID_PARAMS", "radius must be > 0")
	var center_raw = parameters.get("center", null)
	if typeof(center_raw) != TYPE_ARRAY:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"radius requires center: [x,y] (2D) or [x,y,z] (3D)")
	var c := center_raw as Array
	if c.size() == 2:
		return {"center": Vector2(c[0], c[1]), "radius": radius, "is_2d": true}
	if c.size() == 3:
		return {"center": Vector3(c[0], c[1], c[2]), "radius": radius, "is_2d": false}
	return MCPToolkitError.fail("INVALID_PARAMS",
		"center must have 2 numbers (2D) or 3 (3D); got %d" % c.size())


static func _passes_filters(bounds: Variant, region: Variant, radius: Variant) -> bool:
	var is_2d := typeof(bounds) == TYPE_RECT2
	if region != null:
		var region_is_2d := typeof(region) == TYPE_RECT2
		if region_is_2d != is_2d:
			return false
		if not bounds.intersects(region):
			return false
	if radius != null:
		if (radius["is_2d"] as bool) != is_2d:
			return false
		if bounds.get_center().distance_to(radius["center"]) > (radius["radius"] as float):
			return false
	return true


# -- Tree / class / serialization helpers -------------------------------------


## Depth-first iteration over a node and all its descendants.
static func _iter_tree(node: Node) -> Array:
	var out: Array = [node]
	for child in node.get_children():
		out.append_array(_iter_tree(child))
	return out


static func _node_is_class(node: Node, type_name: String) -> bool:
	if node.get_class() == type_name:
		return true
	if node.is_class(type_name):
		return true
	# Custom (class_name) scripts — match the script's resource_path against the
	# global class list. Script.get_global_name() is 4.3+, so this stays 4.2-safe
	# (same pattern as editor_helpers.class_descends_from).
	var script := node.get_script()
	if script != null and script is Script:
		var script_path := (script as Script).resource_path
		if script_path != "":
			for entry in ProjectSettings.get_global_class_list():
				if String(entry.get("path", "")) == script_path:
					return String(entry.get("class", "")) == type_name
	return false


static func _rel_path(root: Node, node: Node) -> String:
	if node == root:
		return "."
	return "./" + String(root.get_path_to(node))


static func _vec_to_array(v: Variant) -> Array:
	match typeof(v):
		TYPE_VECTOR2:
			return [snappedf(v.x, 0.001), snappedf(v.y, 0.001)]
		TYPE_VECTOR3:
			return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]
	return []
