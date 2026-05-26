@tool
extends RefCounted
## tileset.* command handlers — TileSet resource creation, editing, and management.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const McpError = _Hub.McpError
const Coerce = _Hub.Coerce
const FileGuard = _Hub.FileGuard
const Helpers = _Hub.Helpers


static func register(registry: MCPToolkitCommandRegistry) -> void:
	# -- tileset group (structural) --
	registry.add("tileset.create", func(parameters: Dictionary) -> Dictionary:
		return _cmd_tileset_create(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.add_source", func(parameters: Dictionary) -> Dictionary:
		return _cmd_tileset_add_source(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.remove_source", func(parameters: Dictionary) -> Dictionary:
		return _cmd_tileset_remove_source(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.add_alternative", func(parameters: Dictionary) -> Dictionary:
		return _cmd_tileset_add_alternative(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.remove_alternative", func(parameters: Dictionary) -> Dictionary:
		return _cmd_tileset_remove_alternative(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.setup_layers", func(parameters: Dictionary) -> Dictionary:
		return _cmd_tileset_setup_layers(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	# -- tileset_edit group (per-tile properties) --
	registry.add("tileset.edit_physics", func(parameters: Dictionary) -> Dictionary:
		return _cmd_tileset_edit(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.edit_terrain", func(parameters: Dictionary) -> Dictionary:
		return _cmd_tileset_edit(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.edit_navigation", func(parameters: Dictionary) -> Dictionary:
		return _cmd_tileset_edit(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.edit_visuals", func(parameters: Dictionary) -> Dictionary:
		return _cmd_tileset_edit(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.edit_custom_data", func(parameters: Dictionary) -> Dictionary:
		return _cmd_tileset_edit(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())


# -- Helpers ------------------------------------------------------------------


## Load and validate a TileSet from file_path. Returns TileSet or error Dictionary.
static func _load_tileset(file_path: String) -> Variant:
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return McpError.make("PATH_DENIED", str(guard["reason"]))
	if not FileAccess.file_exists(file_path):
		return McpError.make("NOT_FOUND", "TileSet not found: %s" % file_path)
	var ts = ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if ts == null or not (ts is TileSet):
		return McpError.make("INVALID_CLASS",
			"Resource at %s is not a TileSet" % file_path)
	return ts


## Save a TileSet, reload cache, and index. Returns empty dict on success or error.
static func _save_tileset(ts: TileSet, file_path: String) -> Dictionary:
	var save_err := ResourceSaver.save(ts, file_path)
	if save_err != OK:
		return McpError.make("SAVE_FAILED",
			"ResourceSaver.save returned %d (path=%s)" % [save_err, file_path])
	ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	Helpers.ensure_file_indexed(file_path)
	return {}


static func _layer_node_hint(prefix: String, suffix: String) -> String:
	var ver := _Hub.VersionUtils.get_engine_version_pair()
	var has_tilemaplayer := _Hub.VersionUtils.is_version_in_range(ver, "4.3", "")
	var node_name := "TileMapLayer" if has_tilemaplayer else "TileMap"
	return prefix + node_name + suffix


# -- Commands -----------------------------------------------------------------


static func _cmd_tileset_create(parameters: Dictionary) -> Dictionary:
	var err = McpError.check_required(parameters, ["file_path", "texture_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var texture_path := str(parameters.get("texture_path", ""))
	var tile_size_raw = parameters.get("tile_size", {"x": 16, "y": 16})
	var tile_w := int(tile_size_raw.get("x", 16)) if typeof(tile_size_raw) == TYPE_DICTIONARY else 16
	var tile_h := int(tile_size_raw.get("y", 16)) if typeof(tile_size_raw) == TYPE_DICTIONARY else 16

	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return McpError.make("PATH_DENIED", str(guard["reason"]))
	if not file_path.get_extension().to_lower() in ["tres", "res"]:
		return McpError.make("INVALID_PATH",
			"tileset_create writes .tres/.res files (got %s)" % file_path)

	var texture: Texture2D = load(texture_path) as Texture2D
	if texture == null:
		return McpError.make("NOT_FOUND",
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
	var half_w := tile_w / 2.0
	var half_h := tile_h / 2.0
	var full_tile_polygon := PackedVector2Array([
		Vector2(-half_w, -half_h), Vector2(half_w, -half_h),
		Vector2(half_w, half_h), Vector2(-half_w, half_h)])
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
		return McpError.make("SAVE_FAILED",
			"ResourceSaver.save returned %d (path=%s)" % [save_err, file_path])
	var loaded := ResourceLoader.load(file_path, "TileSet", ResourceLoader.CACHE_MODE_REPLACE)
	if loaded == null or not (loaded is TileSet):
		return McpError.make("SAVE_FAILED",
			"tileset saved but reload failed — file may be corrupt: %s" % file_path)
	Helpers.ensure_file_indexed(file_path)

	var create_result := {
		"success": true,
		"path": file_path,
		"tile_size": {"x": tile_w, "y": tile_h},
		"source_id": source_id,
		"atlas_grid": {"columns": cols, "rows": rows},
		"tiles_created": tiles_created,
		"physics": physics,
	}
	create_result["hint"] = _layer_node_hint("Assign this TileSet to a ", " node.")
	return create_result


static func _cmd_tileset_add_source(parameters: Dictionary) -> Dictionary:
	var err = McpError.check_required(parameters, ["file_path", "texture_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var ts_or_err = _load_tileset(file_path)
	if ts_or_err is Dictionary:
		return ts_or_err
	var ts: TileSet = ts_or_err
	var result = _apply_add_source(ts, parameters)
	if result.has("error"):
		return result
	var save_result := _save_tileset(ts, file_path)
	if save_result.has("error"):
		return save_result
	var source_id: int = result["source_id"]
	return {
		"success": true,
		"path": file_path,
		"new_source_id": source_id,
		"hint": _layer_node_hint(
			"Configure tiles on source %d with tileset.edit_* tools, or paint onto a " % source_id,
			" with tilemap.set_cells."),
	}


static func _cmd_tileset_remove_source(parameters: Dictionary) -> Dictionary:
	var err = McpError.check_required(parameters, ["file_path", "source_id"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var source_id := int(parameters.get("source_id", 0))
	var ts_or_err = _load_tileset(file_path)
	if ts_or_err is Dictionary:
		return ts_or_err
	var ts: TileSet = ts_or_err
	if not ts.has_source(source_id):
		return McpError.make("NOT_FOUND",
			"No source with id %d in TileSet" % source_id)
	ts.remove_source(source_id)
	var save_result := _save_tileset(ts, file_path)
	if save_result.has("error"):
		return save_result
	return {
		"success": true,
		"path": file_path,
		"removed_source_id": source_id,
		"hint": _layer_node_hint(
			"", " cells referencing source %d may become invalid. Check with tilemap.read_cells." % source_id),
	}


static func _cmd_tileset_add_alternative(parameters: Dictionary) -> Dictionary:
	var err = McpError.check_required(parameters, ["file_path", "atlas_x", "atlas_y"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var source_id := int(parameters.get("source_id", 0))
	var ts_or_err = _load_tileset(file_path)
	if ts_or_err is Dictionary:
		return ts_or_err
	var ts: TileSet = ts_or_err
	if not ts.has_source(source_id):
		return McpError.make("NOT_FOUND",
			"No source with id %d in TileSet" % source_id)
	var source = ts.get_source(source_id)
	if not (source is TileSetAtlasSource):
		return McpError.make("INVALID_CLASS",
			"Source %d is not a TileSetAtlasSource" % source_id)
	var atlas: TileSetAtlasSource = source
	var coord := Vector2i(int(parameters["atlas_x"]), int(parameters["atlas_y"]))
	if not atlas.has_tile(coord):
		return McpError.make("NOT_FOUND",
			"tile (%d,%d) not found in source %d" % [coord.x, coord.y, source_id])
	var r = _apply_alternative(atlas, coord, parameters)
	if r.has("error"):
		return McpError.make("FAILED", r["error"])
	var alt_id: int = r["alt_id"]
	var save_result := _save_tileset(ts, file_path)
	if save_result.has("error"):
		return save_result
	return {
		"success": true,
		"path": file_path,
		"tile": {"atlas_x": coord.x, "atlas_y": coord.y},
		"new_alternative_id": alt_id,
		"hint": "Alternative %d inherits base tile properties. Customize with tileset.edit_* tools." % alt_id,
	}


static func _cmd_tileset_remove_alternative(parameters: Dictionary) -> Dictionary:
	var err = McpError.check_required(parameters, ["file_path", "atlas_x", "atlas_y", "alternative_id"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var source_id := int(parameters.get("source_id", 0))
	var atlas_x := int(parameters.get("atlas_x", 0))
	var atlas_y := int(parameters.get("atlas_y", 0))
	var alt_id := int(parameters.get("alternative_id", 0))
	var ts_or_err = _load_tileset(file_path)
	if ts_or_err is Dictionary:
		return ts_or_err
	var ts: TileSet = ts_or_err
	if not ts.has_source(source_id):
		return McpError.make("NOT_FOUND",
			"No source with id %d in TileSet" % source_id)
	var source = ts.get_source(source_id)
	if not (source is TileSetAtlasSource):
		return McpError.make("INVALID_CLASS",
			"Source %d is not a TileSetAtlasSource" % source_id)
	var atlas: TileSetAtlasSource = source
	var coord := Vector2i(atlas_x, atlas_y)
	if not atlas.has_tile(coord):
		return McpError.make("NOT_FOUND",
			"tile (%d,%d) not found in source %d" % [atlas_x, atlas_y, source_id])
	if not atlas.has_alternative_tile(coord, alt_id):
		return McpError.make("NOT_FOUND",
			"alternative %d not found for tile (%d,%d)" % [alt_id, atlas_x, atlas_y])
	atlas.remove_alternative_tile(coord, alt_id)
	var save_result := _save_tileset(ts, file_path)
	if save_result.has("error"):
		return save_result
	return {
		"success": true,
		"path": file_path,
		"removed_alternative_id": alt_id,
		"tile": {"atlas_x": atlas_x, "atlas_y": atlas_y},
		"hint": _layer_node_hint(
			"", " cells using alternative %d revert to the base tile (alternative 0). Check with tilemap.read_cells." % alt_id),
	}


static func _cmd_tileset_setup_layers(parameters: Dictionary) -> Dictionary:
	var err = McpError.check_required(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var ts_or_err = _load_tileset(file_path)
	if ts_or_err is Dictionary:
		return ts_or_err
	var ts: TileSet = ts_or_err
	var result = _apply_layers(ts, parameters)
	if result.has("error"):
		return result
	var save_result := _save_tileset(ts, file_path)
	if save_result.has("error"):
		return save_result
	return {
		"success": true,
		"path": file_path,
		"hint": _layer_node_hint(
			"Layers configured. Assign per-tile data with tileset.edit_physics, tileset.edit_terrain, etc., then paint onto a ",
			" with tilemap.set_cells."),
	}


static func _cmd_tileset_edit(parameters: Dictionary) -> Dictionary:
	var err = McpError.check_required(parameters, ["file_path"])
	if err != null:
		return err

	var file_path := str(parameters.get("file_path", ""))
	var source_id := int(parameters.get("source_id", 0))
	var tiles_raw = parameters.get("tiles", null)
	var add_source_raw = parameters.get("add_source", null)
	var layers_raw = parameters.get("layers", null)

	var ts_or_err = _load_tileset(file_path)
	if ts_or_err is Dictionary:
		return ts_or_err
	var ts: TileSet = ts_or_err

	var tile_errors: Array = []
	var tiles_modified := 0
	var new_source_id: Variant = null

	# -- add_source (before per-tile edits) --
	if add_source_raw != null and typeof(add_source_raw) == TYPE_DICTIONARY:
		var result = _apply_add_source(ts, add_source_raw)
		if result.has("error"):
			return result
		new_source_id = result["source_id"]

	# -- layers (before per-tile edits) --
	if layers_raw != null and typeof(layers_raw) == TYPE_DICTIONARY:
		var result = _apply_layers(ts, layers_raw)
		if result.has("error"):
			return result

	# -- per-tile edits --
	if tiles_raw != null and typeof(tiles_raw) == TYPE_ARRAY:
		if not ts.has_source(source_id):
			return McpError.make("NOT_FOUND",
				"No source with id %d in TileSet" % source_id)
		var source = ts.get_source(source_id)
		if not (source is TileSetAtlasSource):
			return McpError.make("INVALID_CLASS",
				"Source %d is not a TileSetAtlasSource" % source_id)
		var atlas: TileSetAtlasSource = source
		var tile_size: Vector2i = ts.tile_size

		for i in range(tiles_raw.size()):
			var tile = tiles_raw[i]
			if typeof(tile) != TYPE_DICTIONARY:
				tile_errors.append("tiles[%d]: not a dictionary" % i)
				continue
			if not tile.has("atlas_x") or not tile.has("atlas_y"):
				tile_errors.append("tiles[%d]: missing atlas_x/atlas_y" % i)
				continue
			var coord := Vector2i(int(tile["atlas_x"]), int(tile["atlas_y"]))
			if not atlas.has_tile(coord):
				tile_errors.append("tiles[%d]: tile (%d,%d) not found in source %d" % [
					i, coord.x, coord.y, source_id])
				continue
			var td: TileData = atlas.get_tile_data(coord, 0)
			var modified := false

			# Feature 1: physics_polygon
			if tile.has("physics_polygon"):
				var r = _apply_physics_polygon(td, tile, tile_size)
				if r.is_empty():
					modified = true
				else:
					tile_errors.append("tiles[%d]: %s" % [i, r])

			# Feature 2: terrain
			if tile.has("terrain_set"):
				td.terrain_set = int(tile["terrain_set"])
				modified = true
			if tile.has("terrain"):
				td.terrain = int(tile["terrain"])
				modified = true

			# Feature 2b: terrain peering bits
			if tile.has("terrain_peering") and typeof(tile["terrain_peering"]) == TYPE_DICTIONARY:
				var r = _apply_terrain_peering(td, tile["terrain_peering"])
				if r.is_empty():
					modified = true
				else:
					tile_errors.append("tiles[%d]: %s" % [i, r])

			# Feature 3: navigation_polygon
			if tile.has("navigation_polygon"):
				var r = _apply_navigation_polygon(td, tile, tile_size)
				if r.is_empty():
					modified = true
				else:
					tile_errors.append("tiles[%d]: %s" % [i, r])

			# Feature 4: occlusion_polygon
			if tile.has("occlusion_polygon"):
				var r = _apply_occlusion_polygon(td, tile, tile_size)
				if r.is_empty():
					modified = true
				else:
					tile_errors.append("tiles[%d]: %s" % [i, r])

			# Feature 5: custom_data
			if tile.has("custom_data") and typeof(tile["custom_data"]) == TYPE_DICTIONARY:
				for layer_name in tile["custom_data"]:
					td.set_custom_data(str(layer_name), tile["custom_data"][layer_name])
				modified = true

			# Feature 6: animation
			if tile.has("animation") and typeof(tile["animation"]) == TYPE_DICTIONARY:
				var r = _apply_animation(atlas, coord, tile["animation"])
				if r.is_empty():
					modified = true
				else:
					tile_errors.append("tiles[%d]: %s" % [i, r])

			# Feature 7: probability
			if tile.has("probability"):
				td.probability = float(tile["probability"])
				modified = true

			# Feature 8: alternative tile
			if tile.has("alternative") and typeof(tile["alternative"]) == TYPE_DICTIONARY:
				var r = _apply_alternative(atlas, coord, tile["alternative"])
				if r.has("error"):
					tile_errors.append("tiles[%d]: %s" % [i, r["error"]])
				else:
					modified = true

			if modified:
				tiles_modified += 1

	# -- Save --
	var save_result := _save_tileset(ts, file_path)
	if save_result.has("error"):
		return save_result

	var edit_result := {
		"success": true,
		"path": file_path,
		"tiles_modified": tiles_modified,
		"errors": tile_errors,
		"hint": _layer_node_hint(
			"Edit more tile properties with tileset.edit_*, or paint tiles onto a ",
			" with tilemap.set_cells."),
	}
	if new_source_id != null:
		edit_result["new_source_id"] = new_source_id
	return edit_result


# -- tileset sub-helpers ------------------------------------------------------


static func _apply_add_source(ts: TileSet, cfg: Dictionary) -> Dictionary:
	var tex_path := str(cfg.get("texture_path", ""))
	if tex_path.is_empty():
		return McpError.make("INVALID_PARAMS", "add_source.texture_path required")
	var texture: Texture2D = load(tex_path) as Texture2D
	if texture == null:
		return McpError.make("NOT_FOUND",
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

	# Navigation layers (FIX-2: safe coercion via str() for non-int input)
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


static func _build_full_tile_polygon(tile_size: Vector2i) -> PackedVector2Array:
	var hw := tile_size.x / 2.0
	var hh := tile_size.y / 2.0
	return PackedVector2Array([
		Vector2(-hw, -hh), Vector2(hw, -hh),
		Vector2(hw, hh), Vector2(-hw, hh)])


static func _ensure_collision_polygon(td: TileData, physics_layer: int) -> void:
	if td.get_collision_polygons_count(physics_layer) == 0:
		td.add_collision_polygon(physics_layer)


static func _apply_physics_polygon(
	td: TileData, tile: Dictionary, tile_size: Vector2i
) -> String:
	var val = tile["physics_polygon"]
	var physics_layer := int(tile.get("physics_layer", 0))
	if typeof(val) == TYPE_STRING:
		match val:
			"full":
				_ensure_collision_polygon(td, physics_layer)
				td.set_collision_polygon_points(physics_layer, 0,
					_build_full_tile_polygon(tile_size))
			"none":
				while td.get_collision_polygons_count(physics_layer) > 0:
					td.remove_collision_polygon(physics_layer, 0)
			"one_way":
				_ensure_collision_polygon(td, physics_layer)
				td.set_collision_polygon_points(physics_layer, 0,
					_build_full_tile_polygon(tile_size))
				td.set_collision_polygon_one_way(physics_layer, 0, true)
			_:
				return "unknown physics_polygon shorthand: %s" % val
	elif typeof(val) == TYPE_ARRAY:
		_ensure_collision_polygon(td, physics_layer)
		var points := PackedVector2Array()
		for pt in val:
			if typeof(pt) == TYPE_DICTIONARY:
				points.append(Vector2(float(pt.get("x", 0)), float(pt.get("y", 0))))
		td.set_collision_polygon_points(physics_layer, 0, points)
	else:
		return "physics_polygon must be string or Array[{x,y}]"
	if tile.has("one_way_collision"):
		_ensure_collision_polygon(td, physics_layer)
		td.set_collision_polygon_one_way(physics_layer, 0, bool(tile["one_way_collision"]))
	return ""


const _PEERING_MAP := {
	"right": TileSet.CELL_NEIGHBOR_RIGHT_SIDE,
	"bottom_right": TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER,
	"bottom": TileSet.CELL_NEIGHBOR_BOTTOM_SIDE,
	"bottom_left": TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,
	"left": TileSet.CELL_NEIGHBOR_LEFT_SIDE,
	"top_left": TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER,
	"top": TileSet.CELL_NEIGHBOR_TOP_SIDE,
	"top_right": TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER,
}


static func _apply_terrain_peering(td: TileData, peering: Dictionary) -> String:
	for key in peering:
		if key == "center":
			td.terrain = int(peering[key])
			continue
		if not _PEERING_MAP.has(key):
			return "unknown peering bit: %s" % key
		td.set_terrain_peering_bit(_PEERING_MAP[key], int(peering[key]))
	return ""


static func _build_nav_polygon(verts: PackedVector2Array) -> NavigationPolygon:
	var np := NavigationPolygon.new()
	np.set_vertices(verts)
	var indices := PackedInt32Array()
	for i in range(verts.size()):
		indices.append(i)
	np.add_polygon(indices)
	return np


static func _apply_navigation_polygon(
	td: TileData, tile: Dictionary, tile_size: Vector2i
) -> String:
	var val = tile["navigation_polygon"]
	var nav_layer := int(tile.get("navigation_layer", 0))
	if typeof(val) == TYPE_STRING:
		match val:
			"full":
				var hw := tile_size.x / 2.0
				var hh := tile_size.y / 2.0
				var verts := PackedVector2Array([
					Vector2(-hw, -hh), Vector2(hw, -hh),
					Vector2(hw, hh), Vector2(-hw, hh)])
				td.set_navigation_polygon(nav_layer, _build_nav_polygon(verts))
			"none":
				td.set_navigation_polygon(nav_layer, null)
			_:
				return "unknown navigation_polygon shorthand: %s" % val
	elif typeof(val) == TYPE_ARRAY:
		var verts := PackedVector2Array()
		for pt in val:
			if typeof(pt) == TYPE_DICTIONARY:
				verts.append(Vector2(float(pt.get("x", 0)), float(pt.get("y", 0))))
		td.set_navigation_polygon(nav_layer, _build_nav_polygon(verts))
	else:
		return "navigation_polygon must be string or Array[{x,y}]"
	return ""


static func _apply_occlusion_polygon(
	td: TileData, tile: Dictionary, tile_size: Vector2i
) -> String:
	var val = tile["occlusion_polygon"]
	var occ_layer := int(tile.get("occlusion_layer", 0))
	if typeof(val) == TYPE_STRING:
		match val:
			"full":
				var op := OccluderPolygon2D.new()
				var hw := tile_size.x / 2.0
				var hh := tile_size.y / 2.0
				op.polygon = PackedVector2Array([
					Vector2(-hw, -hh), Vector2(hw, -hh),
					Vector2(hw, hh), Vector2(-hw, hh)])
				td.set_occluder(occ_layer, op)
			"none":
				td.set_occluder(occ_layer, null)
			_:
				return "unknown occlusion_polygon shorthand: %s" % val
	elif typeof(val) == TYPE_ARRAY:
		var op := OccluderPolygon2D.new()
		var verts := PackedVector2Array()
		for pt in val:
			if typeof(pt) == TYPE_DICTIONARY:
				verts.append(Vector2(float(pt.get("x", 0)), float(pt.get("y", 0))))
		op.polygon = verts
		td.set_occluder(occ_layer, op)
	else:
		return "occlusion_polygon must be string or Array[{x,y}]"
	return ""


static func _apply_animation(
	atlas: TileSetAtlasSource, coord: Vector2i, anim: Dictionary
) -> String:
	var frame_count := int(anim.get("frame_count", anim.get("frames", []).size()))
	if frame_count < 2:
		return "animation needs frame_count >= 2"
	var columns := int(anim.get("columns", frame_count))
	var duration := float(anim.get("frame_duration", 1.0))
	# Remove tiles that the animation area would cover (except the base tile)
	var rows_needed := ceili(float(frame_count) / float(columns))
	for fy in range(rows_needed):
		for fx in range(columns):
			if fx == 0 and fy == 0:
				continue
			var covered := coord + Vector2i(fx, fy)
			if atlas.has_tile(covered):
				atlas.remove_tile(covered)
	atlas.set_tile_animation_columns(coord, columns)
	atlas.set_tile_animation_frames_count(coord, frame_count)
	for f in range(frame_count):
		atlas.set_tile_animation_frame_duration(coord, f, duration)
	if anim.has("separation"):
		var sep = anim["separation"]
		if typeof(sep) == TYPE_DICTIONARY:
			atlas.set_tile_animation_separation(coord,
				Vector2i(int(sep.get("x", 0)), int(sep.get("y", 0))))
	return ""


static func _apply_alternative(
	atlas: TileSetAtlasSource, coord: Vector2i, alt: Dictionary
) -> Dictionary:
	var alt_id := atlas.create_alternative_tile(coord)
	var alt_td: TileData = atlas.get_tile_data(coord, alt_id)
	if alt.has("flip_h"):
		alt_td.flip_h = bool(alt["flip_h"])
	if alt.has("flip_v"):
		alt_td.flip_v = bool(alt["flip_v"])
	if alt.has("transpose"):
		alt_td.transpose = bool(alt["transpose"])
	if alt.has("modulate"):
		var m = alt["modulate"]
		if typeof(m) == TYPE_DICTIONARY:
			alt_td.modulate = Color(
				float(m.get("r", 1.0)), float(m.get("g", 1.0)),
				float(m.get("b", 1.0)), float(m.get("a", 1.0)))
	return {"alt_id": alt_id}
