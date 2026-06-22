@tool
extends RefCounted
## tileset.* command registration orchestrator — wires every tileset.* tool onto
## the registry and delegates each handler to its command child (structure,
## alternatives, tile-data). Holds no command logic itself; the I/O spine lives on
## the shared tileset_io.gd leaf, consumed by the children.

const _Structure := preload("res://addons/godot_mcp_toolkit/commands/tileset/tileset_structure.gd")
const _Alternatives := preload("res://addons/godot_mcp_toolkit/commands/tileset/tileset_alternatives.gd")
const _TileData := preload("res://addons/godot_mcp_toolkit/commands/tileset/tileset_tile_data.gd")


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
		return await _Alternatives.cmd_add_alternative(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("tileset.remove_alternative", func(parameters: Dictionary) -> Dictionary:
		return await _Alternatives.cmd_remove_alternative(parameters)
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
