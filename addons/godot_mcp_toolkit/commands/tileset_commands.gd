@tool
extends RefCounted
## tileset.* command handlers — TileSet resource creation, editing, and management.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const _IO := preload("res://addons/godot_mcp_toolkit/commands/tileset_io.gd")
const _Structure := preload("res://addons/godot_mcp_toolkit/commands/tileset_structure.gd")
const _TileData := preload("res://addons/godot_mcp_toolkit/commands/tileset_tile_data.gd")
const Coerce = _Hub.Coerce


static func register(registry: MCPToolkitCommandRegistry) -> void:
	# -- tileset group (structural) --
	registry.add("tileset.create", func(parameters: Dictionary) -> Dictionary:
		return await _Structure.cmd_create(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.add_source", func(parameters: Dictionary) -> Dictionary:
		return await _Structure.cmd_add_source(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.remove_source", func(parameters: Dictionary) -> Dictionary:
		return await _Structure.cmd_remove_source(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.add_alternative", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_tileset_add_alternative(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.remove_alternative", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_tileset_remove_alternative(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.setup_layers", func(parameters: Dictionary) -> Dictionary:
		return await _Structure.cmd_setup_layers(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	# -- tileset_edit group (per-tile properties) --
	# Each verb binds the shared _TileData.cmd_edit dispatcher but pins its own
	# VERB, so the handler enforces the per-tile key set its tool name promises (a
	# terrain key sent to edit_physics is rejected, not silently applied).
	registry.add("tileset.edit_physics", func(parameters: Dictionary) -> Dictionary:
		return await _TileData.cmd_edit(parameters, "physics")
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.edit_terrain", func(parameters: Dictionary) -> Dictionary:
		return await _TileData.cmd_edit(parameters, "terrain")
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.edit_navigation", func(parameters: Dictionary) -> Dictionary:
		return await _TileData.cmd_edit(parameters, "navigation")
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.edit_visuals", func(parameters: Dictionary) -> Dictionary:
		return await _TileData.cmd_edit(parameters, "visuals")
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.edit_custom_data", func(parameters: Dictionary) -> Dictionary:
		return await _TileData.cmd_edit(parameters, "custom_data")
	, MCPToolkitCommandOptions.new().mark_scene_independent())


# Load / save+reindex / the layer-node version hint / the full-tile polygon all
# live on the shared tileset_io.gd leaf (_IO) — they are the I/O spine every
# tileset.* command group relies on, so no single command child can own them.


# -- Commands -----------------------------------------------------------------


static func _cmd_tileset_add_alternative(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path", "atlas_x", "atlas_y"])
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
	var source = ts.get_source(source_id)
	if not (source is TileSetAtlasSource):
		return MCPToolkitError.fail("INVALID_CLASS",
			"Source %d is not a TileSetAtlasSource" % source_id)
	var atlas: TileSetAtlasSource = source
	var coord := Vector2i(int(parameters["atlas_x"]), int(parameters["atlas_y"]))
	if not atlas.has_tile(coord):
		return MCPToolkitError.fail("NOT_FOUND",
			"tile (%d,%d) not found in source %d" % [coord.x, coord.y, source_id])
	var r = _apply_alternative(atlas, coord, parameters)
	if r.has("error"):
		return MCPToolkitError.fail("FAILED", r["error"])
	var alt_id: int = r["alt_id"]
	var save_result := await _IO.save_tileset(ts, file_path)
	if save_result.has("error"):
		return save_result
	return MCPToolkitSuccess.ok({
		"path": file_path,
		"tile": {"atlas_x": coord.x, "atlas_y": coord.y},
		"new_alternative_id": alt_id,
		"hint": "Alternative %d inherits base tile properties. Customize with tileset.edit_* tools." % alt_id,
	})


static func _cmd_tileset_remove_alternative(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path", "atlas_x", "atlas_y", "alternative_id"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var source_id := int(parameters.get("source_id", 0))
	var atlas_x := int(parameters.get("atlas_x", 0))
	var atlas_y := int(parameters.get("atlas_y", 0))
	var alt_id := int(parameters.get("alternative_id", 0))
	var ts_or_err = _IO.load_tileset(file_path)
	if ts_or_err is Dictionary:
		return ts_or_err
	var ts: TileSet = ts_or_err
	if not ts.has_source(source_id):
		return MCPToolkitError.fail("NOT_FOUND",
			"No source with id %d in TileSet" % source_id)
	var source = ts.get_source(source_id)
	if not (source is TileSetAtlasSource):
		return MCPToolkitError.fail("INVALID_CLASS",
			"Source %d is not a TileSetAtlasSource" % source_id)
	var atlas: TileSetAtlasSource = source
	var coord := Vector2i(atlas_x, atlas_y)
	if not atlas.has_tile(coord):
		return MCPToolkitError.fail("NOT_FOUND",
			"tile (%d,%d) not found in source %d" % [atlas_x, atlas_y, source_id])
	if not atlas.has_alternative_tile(coord, alt_id):
		return MCPToolkitError.fail("NOT_FOUND",
			"alternative %d not found for tile (%d,%d)" % [alt_id, atlas_x, atlas_y])
	atlas.remove_alternative_tile(coord, alt_id)
	var save_result := await _IO.save_tileset(ts, file_path)
	if save_result.has("error"):
		return save_result
	return MCPToolkitSuccess.ok({
		"path": file_path,
		"removed_alternative_id": alt_id,
		"tile": {"atlas_x": atlas_x, "atlas_y": atlas_y},
		"hint": _IO.layer_node_hint(
			"", " cells using alternative %d revert to the base tile (alternative 0). Check with tilemap.read_cells." % alt_id),
	})


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
			alt_td.modulate = Coerce.color_from_dict(m)
	return {"alt_id": alt_id}
