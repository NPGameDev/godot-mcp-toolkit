@tool
extends RefCounted
## tileset.edit_* per-tile data commands: apply a verb-scoped set of per-tile
## TileData edits (physics / terrain / navigation / occlusion+animation / custom
## data), rejecting any key owned by a different edit verb.
##
## One parametric operation — cmd_edit(parameters, verb) — with a verb-indexed
## strategy table. The per-tile-edit policy (which keys are legal per verb, the
## _EDIT_* tables + _foreign_key_error gate) and its mechanism (how each key
## mutates TileData, the _apply_* flows + geometry builders) are inseparable, so
## they live together here. Persistence, the layer-node hint, and the full-tile
## polygon come from the shared tileset_io.gd leaf (_IO); consumed by
## tileset_commands.gd via a `preload` alias.

const _IO := preload("res://addons/godot_mcp_toolkit/commands/tileset/tileset_io.gd")


# -- Per-verb key enforcement -------------------------------------------------
#
# Each tileset.edit_* tool owns exactly one tile-data concern. The five tools all
# share cmd_edit, so without enforcement a key meant for one verb (e.g.
# terrain_set) applied silently under another (e.g. edit_physics). These tables
# make the verb authoritative: a verb accepts only its own per-tile keys plus the
# universal coordinate selectors, and any foreign key is rejected with a hint that
# names the tool that DOES own it (reverse lookup via _EDIT_KEY_OWNER).

## Coordinate selectors every verb needs to address a tile.
const _EDIT_COORD_KEYS := ["atlas_x", "atlas_y"]

## Per-tile keys each verb is allowed to read/apply. The key sets are mutually
## exclusive — one key belongs to exactly one verb — which is what lets a single
## reverse lookup name the owning tool for a rejection hint.
const _EDIT_KEY_SETS := {
	"physics": ["physics_polygon", "physics_layer", "one_way_collision"],
	"terrain": ["terrain_set", "terrain", "terrain_peering"],
	"navigation": ["navigation_polygon", "navigation_layer"],
	"visuals": ["occlusion_polygon", "occlusion_layer", "animation", "probability"],
	"custom_data": ["custom_data"],
}

## Reverse map: per-tile key -> the tool that owns it, for the rejection hint.
const _EDIT_KEY_OWNER := {
	"physics_polygon": "tileset.edit_physics",
	"physics_layer": "tileset.edit_physics",
	"one_way_collision": "tileset.edit_physics",
	"terrain_set": "tileset.edit_terrain",
	"terrain": "tileset.edit_terrain",
	"terrain_peering": "tileset.edit_terrain",
	"navigation_polygon": "tileset.edit_navigation",
	"navigation_layer": "tileset.edit_navigation",
	"occlusion_polygon": "tileset.edit_visuals",
	"occlusion_layer": "tileset.edit_visuals",
	"animation": "tileset.edit_visuals",
	"probability": "tileset.edit_visuals",
	"custom_data": "tileset.edit_custom_data",
}


## Reject the first per-tile key that does not belong to `verb`. Returns "" when
## every key is allowed, otherwise an INVALID_PARAMS message that names the tool
## owning the offending key. Pure (no engine state) so it is unit-testable.
static func _foreign_key_error(verb: String, tile: Dictionary) -> String:
	var allowed: Array = _EDIT_KEY_SETS.get(verb, [])
	for key in tile:
		var key_str := str(key)
		if key_str in _EDIT_COORD_KEYS or key_str in allowed:
			continue
		if _EDIT_KEY_OWNER.has(key_str):
			return "key '%s' belongs to %s, not tileset.edit_%s" % [
				key_str, _EDIT_KEY_OWNER[key_str], verb]
		return "unknown key '%s' for tileset.edit_%s" % [key_str, verb]
	return ""


static func cmd_edit(parameters: Dictionary, verb: String) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path"])
	if err != null:
		return err

	var file_path := str(parameters.get("file_path", ""))
	var source_id := int(parameters.get("source_id", 0))
	var tiles_raw = parameters.get("tiles", null)

	var ts_or_err = _IO.load_tileset(file_path)
	if ts_or_err is Dictionary:
		return ts_or_err
	var ts: TileSet = ts_or_err

	var tile_errors: Array = []
	var tiles_modified := 0

	# -- per-tile edits --
	if tiles_raw != null and typeof(tiles_raw) == TYPE_ARRAY:
		if not ts.has_source(source_id):
			return MCPToolkitError.fail("NOT_FOUND",
				"No source with id %d in TileSet" % source_id)
		var source = ts.get_source(source_id)
		if not (source is TileSetAtlasSource):
			return MCPToolkitError.fail("INVALID_CLASS",
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
			# Enforce the verb: a key for another tool is a caller mistake, so
			# reject the whole call (don't silently apply the wrong concern).
			var foreign := _foreign_key_error(verb, tile)
			if foreign != "":
				return MCPToolkitError.fail("INVALID_PARAMS",
					"tiles[%d]: %s" % [i, foreign])
			var coord := Vector2i(int(tile["atlas_x"]), int(tile["atlas_y"]))
			if not atlas.has_tile(coord):
				tile_errors.append("tiles[%d]: tile (%d,%d) not found in source %d" % [
					i, coord.x, coord.y, source_id])
				continue
			var td: TileData = atlas.get_tile_data(coord, 0)

			# Count a tile only when at least one real edit key was applied — a
			# tile carrying just the coord selectors applies nothing, so it must
			# not be counted (matches the pre-split per-tile `modified` flag).
			var has_real_edit := false
			for k in tile:
				if not str(k) in _EDIT_COORD_KEYS:
					has_real_edit = true
					break
			var feature_errors: Array = _apply_verb(verb, atlas, coord, td, tile, tile_size)
			if feature_errors.is_empty():
				if has_real_edit:
					tiles_modified += 1
			else:
				for fe in feature_errors:
					tile_errors.append("tiles[%d]: %s" % [i, str(fe)])

	# -- Save --
	var save_result := await _IO.save_tileset(ts, file_path)
	if save_result.has("error"):
		return save_result

	var edit_result := {
		"path": file_path,
		"tiles_modified": tiles_modified,
		"errors": tile_errors,
		"hint": _IO.layer_node_hint(
			"Edit more tile properties with tileset.edit_*, or paint tiles onto a ",
			" with tilemap.set_cells."),
	}
	return MCPToolkitSuccess.ok(edit_result)


# -- Intent-named per-verb flows ----------------------------------------------
#
# One flow per tool, each applying ONLY its own concern's keys to a single tile.
# Each returns the soft per-tile errors it accumulated ([] = fully applied); the
# caller folds those into the per-tile errors[] array exactly as before.


## Route one tile to the flow that matches `verb`. Keys are already verb-checked.
static func _apply_verb(
	verb: String, atlas: TileSetAtlasSource, coord: Vector2i,
	td: TileData, tile: Dictionary, tile_size: Vector2i
) -> Array:
	match verb:
		"physics":
			return _apply_physics(td, tile, tile_size)
		"terrain":
			return _apply_terrain(td, tile)
		"navigation":
			return _apply_navigation(td, tile, tile_size)
		"visuals":
			return _apply_visuals(atlas, coord, td, tile, tile_size)
		"custom_data":
			return _apply_custom_data(td, tile)
	return ["unknown tileset edit verb: %s" % verb]


## Collision polygon + one-way flag (tileset.edit_physics).
static func _apply_physics(td: TileData, tile: Dictionary, tile_size: Vector2i) -> Array:
	var errors: Array = []
	if tile.has("physics_polygon"):
		var r := _apply_physics_polygon(td, tile, tile_size)
		if not r.is_empty():
			errors.append(r)
	return errors


## Terrain set, terrain index, and peering bits (tileset.edit_terrain).
static func _apply_terrain(td: TileData, tile: Dictionary) -> Array:
	var errors: Array = []
	if tile.has("terrain_set"):
		td.terrain_set = int(tile["terrain_set"])
	if tile.has("terrain"):
		td.terrain = int(tile["terrain"])
	if tile.has("terrain_peering") and typeof(tile["terrain_peering"]) == TYPE_DICTIONARY:
		var r := _apply_terrain_peering(td, tile["terrain_peering"])
		if not r.is_empty():
			errors.append(r)
	return errors


## Navigation polygon (tileset.edit_navigation).
static func _apply_navigation(td: TileData, tile: Dictionary, tile_size: Vector2i) -> Array:
	var errors: Array = []
	if tile.has("navigation_polygon"):
		var r := _apply_navigation_polygon(td, tile, tile_size)
		if not r.is_empty():
			errors.append(r)
	return errors


## Occlusion, animation, and probability (tileset.edit_visuals). This tool
## deliberately bundles all three appearance concerns for a tile.
static func _apply_visuals(
	atlas: TileSetAtlasSource, coord: Vector2i,
	td: TileData, tile: Dictionary, tile_size: Vector2i
) -> Array:
	var errors: Array = []
	if tile.has("occlusion_polygon"):
		var r := _apply_occlusion_polygon(td, tile, tile_size)
		if not r.is_empty():
			errors.append(r)
	if tile.has("animation") and typeof(tile["animation"]) == TYPE_DICTIONARY:
		var r := _apply_animation(atlas, coord, tile["animation"])
		if not r.is_empty():
			errors.append(r)
	if tile.has("probability"):
		td.probability = float(tile["probability"])
	return errors


## Custom data layer values (tileset.edit_custom_data).
static func _apply_custom_data(td: TileData, tile: Dictionary) -> Array:
	if tile.has("custom_data") and typeof(tile["custom_data"]) == TYPE_DICTIONARY:
		var cd: Dictionary = tile["custom_data"]
		for layer_name in cd:
			td.set_custom_data(str(layer_name), cd[layer_name])
	return []


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
					_IO.build_full_tile_polygon(tile_size))
			"none":
				while td.get_collision_polygons_count(physics_layer) > 0:
					td.remove_collision_polygon(physics_layer, 0)
			"one_way":
				_ensure_collision_polygon(td, physics_layer)
				td.set_collision_polygon_points(physics_layer, 0,
					_IO.build_full_tile_polygon(tile_size))
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
				var verts := _IO.build_full_tile_polygon(tile_size)
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
				op.polygon = _IO.build_full_tile_polygon(tile_size)
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
