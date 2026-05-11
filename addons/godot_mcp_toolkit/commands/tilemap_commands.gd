@tool
extends RefCounted
## tilemap.* command handlers — batch cell painting with UndoRedo.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPFileGuard = _Hub.MCPFileGuard
const MCPHelpers = _Hub.MCPHelpers


static func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:
	registry.add("tilemap.set_cells", func(parameters: Dictionary) -> Dictionary:
		return _cmd_tilemap_set_cells(server, parameters))
	registry.add("tileset.create", func(parameters: Dictionary) -> Dictionary:
		return _cmd_tileset_create(parameters))
	registry.add("tileset.edit", func(parameters: Dictionary) -> Dictionary:
		return _cmd_tileset_edit(parameters))


# -- Helpers ------------------------------------------------------------------


static func _resolve_scene_node(node_path: String) -> Variant:
	return MCPHelpers.resolve_scene_node(node_path)


# -- Commands -----------------------------------------------------------------


static func _cmd_tilemap_set_cells(
	server: Node, parameters: Dictionary,
) -> Dictionary:
	var tilemap_path := str(parameters.get("tilemap_path", ""))
	tilemap_path = MCPHelpers.normalize_editor_path(tilemap_path)
	var layer := int(parameters.get("layer", 0))
	var cells_raw = parameters.get("cells", null)
	if tilemap_path.is_empty():
		return MCPError.make("INVALID_PARAMS", "missing tilemap_path")
	if typeof(cells_raw) != TYPE_ARRAY:
		return MCPError.make("INVALID_PARAMS",
			"cells must be an Array of { x, y, source_id, atlas_x, atlas_y, alternative_tile? } descriptors")
	var cells: Array = cells_raw
	var node = _resolve_scene_node(tilemap_path)
	if node == null:
		return MCPError.make("NOT_FOUND", "no node at %s" % tilemap_path, MCPError.HINT_NODE_PATH)
	var is_layer: bool = node.is_class("TileMapLayer")  # dynamic — avoids parse error on < 4.3
	var is_map := node is TileMap
	if not (is_layer or is_map):
		return MCPError.make("INVALID_CLASS",
			"node at %s is not a TileMap or TileMapLayer (got %s); tilemap.set_cells only accepts tilemap-family nodes" % [
				tilemap_path, node.get_class()])

	var required_keys := ["x", "y", "source_id", "atlas_x", "atlas_y"]
	for cell_index in range(cells.size()):
		var cell = cells[cell_index]
		if typeof(cell) != TYPE_DICTIONARY:
			return MCPError.make("INVALID_PARAMS",
				"cells[%d] must be an object" % cell_index)
		for key in required_keys:
			if not cell.has(key):
				return MCPError.make("INVALID_PARAMS",
					"cells[%d] missing required key '%s'" % [cell_index, key])

	if is_map:
		var tile_map := node as TileMap
		var layer_count := tile_map.get_layers_count()
		if layer < 0 or layer >= layer_count:
			return MCPError.make("INVALID_PARAMS",
				"layer %d out of range [0, %d) for TileMap %s" % [
					layer, layer_count, tilemap_path])

	var before_state: Array = []
	for cell_index in range(cells.size()):
		var cell: Dictionary = cells[cell_index]
		var coord := Vector2i(int(cell["x"]), int(cell["y"]))
		var previous_source: int
		var previous_atlas: Vector2i
		var previous_alternative: int
		if is_layer:
			previous_source = node.get_cell_source_id(coord)
			previous_atlas = node.get_cell_atlas_coords(coord)
			previous_alternative = node.get_cell_alternative_tile(coord)
		else:
			var tile_map := node as TileMap
			previous_source = tile_map.get_cell_source_id(layer, coord)
			previous_atlas = tile_map.get_cell_atlas_coords(layer, coord)
			previous_alternative = tile_map.get_cell_alternative_tile(layer, coord)
		before_state.append({
			"coord": coord,
			"source_id": previous_source,
			"atlas": previous_atlas,
			"alternative_tile": previous_alternative,
		})

	var cells_written := 0
	var cells_unchanged := 0
	for cell_index in range(cells.size()):
		var cell: Dictionary = cells[cell_index]
		var previous: Dictionary = before_state[cell_index]
		var new_source := int(cell["source_id"])
		var new_atlas := Vector2i(int(cell["atlas_x"]), int(cell["atlas_y"]))
		var new_alternative := int(cell.get("alternative_tile", 0))
		if int(previous["source_id"]) == new_source \
				and (previous["atlas"] as Vector2i) == new_atlas \
				and int(previous["alternative_tile"]) == new_alternative:
			cells_unchanged += 1
		else:
			cells_written += 1

	var undo_redo = _Hub.get_undo_redo()
	if undo_redo != null:
		undo_redo.create_action(
			"MCP: tilemap.set_cells %s (%d cells)" % [tilemap_path, cells.size()])
		undo_redo.add_do_method(
			server.undo_helpers, "_tilemap_apply_batch", node, layer, cells)
		undo_redo.add_undo_method(
			server.undo_helpers, "_tilemap_restore_batch", node, layer, before_state)
		undo_redo.add_do_reference(node)
		undo_redo.commit_action()
	else:
		server.undo_helpers._tilemap_apply_batch(node, layer, cells)
	return {
		"success": true,
		"tilemap_path": tilemap_path,
		"layer": layer,
		"cells_written": cells_written,
		"cells_unchanged": cells_unchanged,
		"total": cells.size(),
	}


static func _cmd_tileset_create(parameters: Dictionary) -> Dictionary:
	var err = MCPError.check_required(parameters, ["file_path", "texture_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var texture_path := str(parameters.get("texture_path", ""))
	var tile_size_raw = parameters.get("tile_size", {"x": 16, "y": 16})
	var tile_w := int(tile_size_raw.get("x", 16)) if typeof(tile_size_raw) == TYPE_DICTIONARY else 16
	var tile_h := int(tile_size_raw.get("y", 16)) if typeof(tile_size_raw) == TYPE_DICTIONARY else 16

	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	if not file_path.get_extension().to_lower() in ["tres", "res"]:
		return MCPError.make("INVALID_PATH",
			"tileset_create writes .tres/.res files (got %s)" % file_path)

	# Load texture
	var texture: Texture2D = load(texture_path) as Texture2D
	if texture == null:
		return MCPError.make("NOT_FOUND",
			"texture not found or not a Texture2D: %s" % texture_path)

	# Create TileSet
	var ts := TileSet.new()
	ts.tile_size = Vector2i(tile_w, tile_h)

	# Physics layer (optional, on by default)
	var physics: bool = parameters.get("physics", true)
	if physics:
		ts.add_physics_layer()
		var collision_layer := int(parameters.get("collision_layer", 1))
		var collision_mask := int(parameters.get("collision_mask", 1))
		ts.set_physics_layer_collision_layer(0, collision_layer)
		ts.set_physics_layer_collision_mask(0, collision_mask)

	# Atlas source from texture
	var source := TileSetAtlasSource.new()
	source.texture = texture
	source.texture_region_size = Vector2i(tile_w, tile_h)
	var source_id := ts.add_source(source)

	# Auto-create tiles for every grid cell in the texture
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
				td.set_collision_polygon_points(0, 0, full_tile_polygon)
			tiles_created += 1

	# Save
	var dir_result := MCPHelpers.ensure_parent_dir(file_path, "tileset.create")
	if dir_result.has("error"):
		return dir_result
	var save_err := ResourceSaver.save(ts, file_path)
	if save_err != OK:
		return MCPError.make("SAVE_FAILED",
			"ResourceSaver.save returned %d (path=%s)" % [save_err, file_path])
	ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	MCPHelpers.ensure_file_indexed(file_path)

	return {
		"success": true,
		"path": file_path,
		"tile_size": {"x": tile_w, "y": tile_h},
		"source_id": source_id,
		"atlas_grid": {"columns": cols, "rows": rows},
		"tiles_created": tiles_created,
		"physics": physics,
	}


static func _cmd_tileset_edit(parameters: Dictionary) -> Dictionary:
	var err = MCPError.check_required(parameters, ["file_path"])
	if err != null:
		return err

	var file_path := str(parameters.get("file_path", ""))
	var source_id := int(parameters.get("source_id", 0))
	var tiles_raw = parameters.get("tiles", null)
	var add_source_raw = parameters.get("add_source", null)
	var layers_raw = parameters.get("layers", null)

	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	if not FileAccess.file_exists(file_path):
		return MCPError.make("NOT_FOUND", "TileSet not found: %s" % file_path)

	var ts = ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if ts == null or not (ts is TileSet):
		return MCPError.make("INVALID_CLASS",
			"Resource at %s is not a TileSet" % file_path)

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
			return MCPError.make("NOT_FOUND",
				"No source with id %d in TileSet" % source_id)
		var source = ts.get_source(source_id)
		if not (source is TileSetAtlasSource):
			return MCPError.make("INVALID_CLASS",
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
				if r.is_empty():
					modified = true
				else:
					tile_errors.append("tiles[%d]: %s" % [i, r])

			if modified:
				tiles_modified += 1

	# -- Save --
	var save_err := ResourceSaver.save(ts, file_path)
	if save_err != OK:
		return MCPError.make("SAVE_FAILED",
			"ResourceSaver.save returned %d (path=%s)" % [save_err, file_path])
	ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	MCPHelpers.ensure_file_indexed(file_path)

	var result := {
		"success": true,
		"path": file_path,
		"tiles_modified": tiles_modified,
		"errors": tile_errors,
	}
	if new_source_id != null:
		result["new_source_id"] = new_source_id
	return result


# -- tileset.edit sub-helpers ------------------------------------------------


static func _apply_add_source(ts: TileSet, cfg: Dictionary) -> Dictionary:
	var tex_path := str(cfg.get("texture_path", ""))
	if tex_path.is_empty():
		return MCPError.make("INVALID_PARAMS", "add_source.texture_path required")
	var texture: Texture2D = load(tex_path) as Texture2D
	if texture == null:
		return MCPError.make("NOT_FOUND",
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

	# Navigation layers
	if layers.has("navigation_layers"):
		var want := int(layers["navigation_layers"])
		while ts.get_navigation_layers_count() < want:
			ts.add_navigation_layer()

	# Occlusion layers
	if layers.has("occlusion_layers"):
		var want := int(layers["occlusion_layers"])
		while ts.get_occlusion_layers_count() < want:
			ts.add_occlusion_layer()

	# Physics layers
	if layers.has("physics_layers"):
		var want := int(layers["physics_layers"])
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


static func _apply_physics_polygon(
	td: TileData, tile: Dictionary, tile_size: Vector2i
) -> String:
	var val = tile["physics_polygon"]
	var physics_layer := int(tile.get("physics_layer", 0))
	if typeof(val) == TYPE_STRING:
		match val:
			"full":
				td.set_collision_polygon_points(physics_layer, 0,
					_build_full_tile_polygon(tile_size))
			"none":
				td.set_collision_polygon_points(physics_layer, 0,
					PackedVector2Array())
			"one_way":
				td.set_collision_polygon_points(physics_layer, 0,
					_build_full_tile_polygon(tile_size))
				td.set_collision_polygon_one_way(physics_layer, 0, true)
			_:
				return "unknown physics_polygon shorthand: %s" % val
	elif typeof(val) == TYPE_ARRAY:
		var points := PackedVector2Array()
		for pt in val:
			if typeof(pt) == TYPE_DICTIONARY:
				points.append(Vector2(float(pt.get("x", 0)), float(pt.get("y", 0))))
		td.set_collision_polygon_points(physics_layer, 0, points)
	else:
		return "physics_polygon must be string or Array[{x,y}]"
	if tile.has("one_way_collision"):
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


static func _apply_navigation_polygon(
	td: TileData, tile: Dictionary, tile_size: Vector2i
) -> String:
	var val = tile["navigation_polygon"]
	var nav_layer := int(tile.get("navigation_layer", 0))
	if typeof(val) == TYPE_STRING:
		match val:
			"full":
				var np := NavigationPolygon.new()
				var hw := tile_size.x / 2.0
				var hh := tile_size.y / 2.0
				var verts := PackedVector2Array([
					Vector2(-hw, -hh), Vector2(hw, -hh),
					Vector2(hw, hh), Vector2(-hw, hh)])
				np.add_outline(verts)
				np.make_polygons_from_outlines()
				td.set_navigation_polygon(nav_layer, np)
			"none":
				td.set_navigation_polygon(nav_layer, null)
			_:
				return "unknown navigation_polygon shorthand: %s" % val
	elif typeof(val) == TYPE_ARRAY:
		var np := NavigationPolygon.new()
		var verts := PackedVector2Array()
		for pt in val:
			if typeof(pt) == TYPE_DICTIONARY:
				verts.append(Vector2(float(pt.get("x", 0)), float(pt.get("y", 0))))
		np.add_outline(verts)
		np.make_polygons_from_outlines()
		td.set_navigation_polygon(nav_layer, np)
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
) -> String:
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
	return ""
