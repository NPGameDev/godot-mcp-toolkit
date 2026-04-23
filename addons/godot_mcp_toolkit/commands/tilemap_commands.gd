@tool
extends RefCounted
## tilemap.* command handlers — batch cell painting with UndoRedo.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPCommandRegistry = _Hub.MCPCommandRegistry


static func register(registry: MCPCommandRegistry, server: Node) -> void:
	registry.add("tilemap.set_cells", func(parameters: Dictionary) -> Dictionary:
		return _cmd_tilemap_set_cells(server, parameters))


# -- Helpers ------------------------------------------------------------------


static func _resolve_scene_node(node_path: String) -> Variant:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	if node_path.is_empty() or node_path == ".":
		return root
	return root.get_node_or_null(node_path)


# -- Commands -----------------------------------------------------------------


static func _cmd_tilemap_set_cells(
	server: Node, parameters: Dictionary,
) -> Dictionary:
	var tilemap_path := str(parameters.get("tilemap_path", ""))
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
		return MCPError.make("NOT_FOUND", "no node at %s" % tilemap_path)
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
			server, "_tilemap_apply_batch", node, layer, cells)
		undo_redo.add_undo_method(
			server, "_tilemap_restore_batch", node, layer, before_state)
		undo_redo.add_do_reference(node)
		undo_redo.commit_action()
	else:
		server._tilemap_apply_batch(node, layer, cells)
	return {
		"success": true,
		"tilemap_path": tilemap_path,
		"layer": layer,
		"cells_written": cells_written,
		"cells_unchanged": cells_unchanged,
		"total": cells.size(),
	}
