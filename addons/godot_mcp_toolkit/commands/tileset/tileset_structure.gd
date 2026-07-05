@tool
extends RefCounted
## tileset.* structure commands: define a TileSet's atlas-source set and layer
## skeleton — create-from-texture, add/remove source, and setup the layer counts.
##
## Stateless — every handler takes its parameters Dictionary and returns the
## response Dictionary. Persistence, the layer-node hint, and the full-tile polygon
## come from the shared tileset_io.gd leaf (_IO); this module owns only the
## structural-shape logic. An extracted submodule of the tileset-command group,
## reached via a `preload` alias.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const _IO := preload("res://addons/godot_mcp_toolkit/commands/tileset/tileset_io.gd")
const Coerce = Modules.Coerce
const FileGuard = Modules.FileGuard
const Helpers = Modules.CommandHelpers


# -- Commands -----------------------------------------------------------------


static func cmd_create(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path", "texture_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var texture_path := str(parameters.get("texture_path", ""))
	var tile_size_raw = parameters.get("tile_size", {"x": 16, "y": 16})
	var tile_w := int(tile_size_raw.get("x", 16)) if typeof(tile_size_raw) == TYPE_DICTIONARY else 16
	var tile_h := int(tile_size_raw.get("y", 16)) if typeof(tile_size_raw) == TYPE_DICTIONARY else 16

	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if not file_path.get_extension().to_lower() in ["tres", "res"]:
		return MCPToolkitError.fail("INVALID_PATH",
			"tileset_create writes .tres/.res files (got %s)" % file_path)

	var texture: Texture2D = load(texture_path) as Texture2D
	if texture == null:
		return MCPToolkitError.fail("NOT_FOUND",
			"texture not found or not a Texture2D: %s" % texture_path)

	var ts := TileSet.new()
	ts.tile_size = Vector2i(tile_w, tile_h)

	var physics: bool = parameters.get("physics", true)
	if physics:
		ts.add_physics_layer()
		var collision_layer := Coerce.layers_to_mask(parameters.get("collision_layer", 1))
		var collision_mask := Coerce.layers_to_mask(parameters.get("collision_mask", 1))
		ts.set_physics_layer_collision_layer(0, collision_layer)
		ts.set_physics_layer_collision_mask(0, collision_mask)

	var source := TileSetAtlasSource.new()
	source.texture = texture
	source.texture_region_size = Vector2i(tile_w, tile_h)
	var source_id := ts.add_source(source)

	var tex_size := texture.get_size()
	var cols := int(tex_size.x) / tile_w
	var rows := int(tex_size.y) / tile_h
	var tiles_created := 0
	var full_tile_polygon := _IO.build_full_tile_polygon(ts.tile_size)
	for row in range(rows):
		for col in range(cols):
			var atlas_coord := Vector2i(col, row)
			source.create_tile(atlas_coord)
			if physics:
				var td: TileData = source.get_tile_data(atlas_coord, 0)
				td.add_collision_polygon(0)
				td.set_collision_polygon_points(0, 0, full_tile_polygon)
			tiles_created += 1

	var dir_result := Helpers.ensure_parent_dir(file_path, "tileset.create")
	if dir_result.has("error"):
		return dir_result
	var save_err := ResourceSaver.save(ts, file_path)
	if save_err != OK:
		return MCPToolkitError.fail("SAVE_FAILED",
			"ResourceSaver.save returned %d (path=%s)" % [save_err, file_path])
	var loaded := ResourceLoader.load(file_path, "TileSet", ResourceLoader.CACHE_MODE_REPLACE)
	if loaded == null or not (loaded is TileSet):
		return MCPToolkitError.fail("SAVE_FAILED",
			"tileset saved but reload failed — file may be corrupt: %s" % file_path)
	await Helpers.ensure_file_indexed(file_path)

	var create_result := {
		"path": file_path,
		"tile_size": {"x": tile_w, "y": tile_h},
		"source_id": source_id,
		"atlas_grid": {"columns": cols, "rows": rows},
		"tiles_created": tiles_created,
		"physics": physics,
	}
	create_result["hint"] = _IO.layer_node_hint("Assign this TileSet to a ", " node.")
	return MCPToolkitSuccess.ok(create_result)


static func cmd_add_source(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path", "texture_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var ts_or_err = _IO.load_tileset(file_path)
	if ts_or_err is Dictionary:
		return ts_or_err
	var ts: TileSet = ts_or_err
	var result = _apply_add_source(ts, parameters)
	if result.has("error"):
		return result
	var save_result := await _IO.save_tileset(ts, file_path)
	if save_result.has("error"):
		return save_result
	var source_id: int = result["source_id"]
	return MCPToolkitSuccess.ok({
		"path": file_path,
		"new_source_id": source_id,
		"hint": _IO.layer_node_hint(
			"Configure tiles on source %d with tileset.edit_* tools, or paint onto a " % source_id,
			" with tilemap.set_cells."),
	})


static func cmd_remove_source(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path", "source_id"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var source_id := int(parameters.get("source_id", 0))
	var ts_or_err = _IO.load_tileset(file_path)
	if ts_or_err is Dictionary:
		return ts_or_err
	var ts: TileSet = ts_or_err
	if not ts.has_source(source_id):
		return MCPToolkitError.fail("NOT_FOUND",
			"No source with id %d in TileSet" % source_id)
	ts.remove_source(source_id)
	var save_result := await _IO.save_tileset(ts, file_path)
	if save_result.has("error"):
		return save_result
	return MCPToolkitSuccess.ok({
		"path": file_path,
		"removed_source_id": source_id,
		"hint": _IO.layer_node_hint(
			"", " cells referencing source %d may become invalid. Check with tilemap.read_cells." % source_id),
	})


static func cmd_setup_layers(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var ts_or_err = _IO.load_tileset(file_path)
	if ts_or_err is Dictionary:
		return ts_or_err
	var ts: TileSet = ts_or_err
	var result = _apply_layers(ts, parameters)
	if result.has("error"):
		return result
	var save_result := await _IO.save_tileset(ts, file_path)
	if save_result.has("error"):
		return save_result
	return MCPToolkitSuccess.ok({
		"path": file_path,
		"hint": _IO.layer_node_hint(
			"Layers configured. Assign per-tile data with tileset.edit_physics, tileset.edit_terrain, etc., then paint onto a ",
			" with tilemap.set_cells."),
	})


# -- structure sub-helpers ----------------------------------------------------


static func _apply_add_source(ts: TileSet, cfg: Dictionary) -> Dictionary:
	var tex_path := str(cfg.get("texture_path", ""))
	if tex_path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "add_source.texture_path required")
	var texture: Texture2D = load(tex_path) as Texture2D
	if texture == null:
		return MCPToolkitError.fail("NOT_FOUND",
			"add_source texture not found: %s" % tex_path)
	var source := TileSetAtlasSource.new()
	source.texture = texture
	var tile_w := int(cfg.get("tile_size", {}).get("x", ts.tile_size.x))
	var tile_h := int(cfg.get("tile_size", {}).get("y", ts.tile_size.y))
	source.texture_region_size = Vector2i(tile_w, tile_h)
	var sid := ts.add_source(source)
	# Auto-create tiles
	var tex_size := texture.get_size()
	var cols := int(tex_size.x) / tile_w
	var rows := int(tex_size.y) / tile_h
	for row in range(rows):
		for col in range(cols):
			source.create_tile(Vector2i(col, row))
	return {"source_id": sid}


static func _apply_layers(ts: TileSet, layers: Dictionary) -> Dictionary:
	# Terrain sets
	if layers.has("terrain_sets") and typeof(layers["terrain_sets"]) == TYPE_ARRAY:
		for ts_def in layers["terrain_sets"]:
			if typeof(ts_def) != TYPE_DICTIONARY:
				continue
			var idx := ts.get_terrain_sets_count()
			ts.add_terrain_set()
			var mode_str := str(ts_def.get("mode", "match_corners_and_sides"))
			var mode: int = TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES
			if mode_str == "match_corners":
				mode = TileSet.TERRAIN_MODE_MATCH_CORNERS
			elif mode_str == "match_sides":
				mode = TileSet.TERRAIN_MODE_MATCH_SIDES
			ts.set_terrain_set_mode(idx, mode)
			if ts_def.has("terrains") and typeof(ts_def["terrains"]) == TYPE_ARRAY:
				for t_name in ts_def["terrains"]:
					ts.add_terrain(idx)
					var t_idx := ts.get_terrains_count(idx) - 1
					ts.set_terrain_name(idx, t_idx, str(t_name))

	# Custom data layers
	if layers.has("custom_data") and typeof(layers["custom_data"]) == TYPE_ARRAY:
		for cd_def in layers["custom_data"]:
			if typeof(cd_def) != TYPE_DICTIONARY:
				continue
			var layer_name := str(cd_def.get("name", ""))
			if layer_name.is_empty():
				continue
			# Check if layer already exists
			var exists := false
			for li in range(ts.get_custom_data_layers_count()):
				if ts.get_custom_data_layer_name(li) == layer_name:
					exists = true
					break
			if exists:
				continue
			ts.add_custom_data_layer()
			var li := ts.get_custom_data_layers_count() - 1
			ts.set_custom_data_layer_name(li, layer_name)
			var type_str := str(cd_def.get("type", "int")).to_lower()
			ts.set_custom_data_layer_type(li, _variant_type_from_string(type_str))

	# Navigation layers (safe coercion via str() for non-int input)
	if layers.has("navigation_layers"):
		var want := int(str(layers["navigation_layers"]))
		while ts.get_navigation_layers_count() < want:
			ts.add_navigation_layer()

	# Occlusion layers
	if layers.has("occlusion_layers"):
		var want := int(str(layers["occlusion_layers"]))
		while ts.get_occlusion_layers_count() < want:
			ts.add_occlusion_layer()

	# Physics layers
	if layers.has("physics_layers"):
		var want := int(str(layers["physics_layers"]))
		while ts.get_physics_layers_count() < want:
			ts.add_physics_layer()

	return {}


static func _variant_type_from_string(s: String) -> int:
	match s:
		"int":     return TYPE_INT
		"float":   return TYPE_FLOAT
		"bool":    return TYPE_BOOL
		"string":  return TYPE_STRING
		"vector2": return TYPE_VECTOR2
		"vector2i": return TYPE_VECTOR2I
		"vector3": return TYPE_VECTOR3
		"color":   return TYPE_COLOR
		_:         return TYPE_INT
