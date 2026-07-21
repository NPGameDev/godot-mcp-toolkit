@tool
extends RefCounted
## The single enumeration of the built-in command surface.
##
## Runs every commands/*.register(...) call against the command registry — the
## one place the full plugin-side command set is named. The composer hands it the
## registry, the server, and the debug bridge; it owns no state of its own.
## Third-party extensions are loaded elsewhere (the composer) — they are dynamic,
## not part of this fixed surface.

const SceneCommands := preload("res://addons/godot_mcp_toolkit/commands/scene_commands.gd")
const NodeCommands := preload("res://addons/godot_mcp_toolkit/commands/node_commands.gd")
const ScriptCommands := preload("res://addons/godot_mcp_toolkit/commands/script_commands.gd")
const EditorCommands := preload("res://addons/godot_mcp_toolkit/commands/editor/editor_commands.gd")
const ResourceCommands := preload("res://addons/godot_mcp_toolkit/commands/resource_commands.gd")
const FolderCommands := preload("res://addons/godot_mcp_toolkit/commands/folder_commands.gd")
const FileCommands := preload("res://addons/godot_mcp_toolkit/commands/file_commands.gd")
const SignalCommands := preload("res://addons/godot_mcp_toolkit/commands/signal_commands.gd")
const PlaytestCommands := preload("res://addons/godot_mcp_toolkit/commands/playtest/playtest_commands.gd")
const ProjectCommands := preload("res://addons/godot_mcp_toolkit/commands/project_commands.gd")
const InputMapCommands := preload("res://addons/godot_mcp_toolkit/commands/input_map_commands.gd")
const AnimationCommands := preload("res://addons/godot_mcp_toolkit/commands/animation_commands.gd")
const TilemapCommands := preload("res://addons/godot_mcp_toolkit/commands/tilemap_commands.gd")
const TilesetCommands := preload("res://addons/godot_mcp_toolkit/commands/tileset/tileset_commands.gd")
const AssetCommands := preload("res://addons/godot_mcp_toolkit/commands/asset_commands.gd")
const SaveCommands := preload("res://addons/godot_mcp_toolkit/commands/save_commands.gd")
const ClassdbCommands := preload("res://addons/godot_mcp_toolkit/commands/classdb_commands.gd")
const ThemeCommands := preload("res://addons/godot_mcp_toolkit/commands/theme_commands.gd")
const PathCommands := preload("res://addons/godot_mcp_toolkit/commands/path_commands.gd")
const ThreeDCommands := preload("res://addons/godot_mcp_toolkit/commands/3d_commands.gd")
const AudioCommands := preload("res://addons/godot_mcp_toolkit/commands/audiobus_commands.gd")
const ProceduralCommands := preload("res://addons/godot_mcp_toolkit/commands/procedural_commands.gd")
const SpriteframesCommands := preload("res://addons/godot_mcp_toolkit/commands/spriteframes_commands.gd")
const ParticleCommands := preload("res://addons/godot_mcp_toolkit/commands/particle_commands.gd")
const NavigationCommands := preload("res://addons/godot_mcp_toolkit/commands/navigation_commands.gd")
const MetaCommands := preload("res://addons/godot_mcp_toolkit/commands/meta_commands.gd")
const DebugCommands := preload("res://addons/godot_mcp_toolkit/commands/debug_commands.gd")
const SpatialCommands := preload("res://addons/godot_mcp_toolkit/commands/spatial_commands.gd")
const TextureCommands := preload("res://addons/godot_mcp_toolkit/commands/texture_commands.gd")
const SoundCommands := preload("res://addons/godot_mcp_toolkit/commands/sound_commands.gd")


## Registers the entire built-in command surface onto the registry. The one
## place every commands/*.register(...) call is enumerated. The debug bridge is
## constructed by the composer and passed in (the playtest/debug commands need
## it); extensions are loaded separately by the composer.
static func register_all(registry: MCPToolkitCommandRegistry, server: Node, debug_bridge: RefCounted) -> void:
	SceneCommands.register(registry, server)
	NodeCommands.register(registry, server)
	ScriptCommands.register(registry, server)
	EditorCommands.register(registry, server)
	ResourceCommands.register(registry, server)
	FolderCommands.register(registry, server)
	FileCommands.register(registry, server)
	SignalCommands.register(registry, server)
	PlaytestCommands.register(registry, server, debug_bridge)
	ProjectCommands.register(registry, server)
	InputMapCommands.register(registry, server)
	AnimationCommands.register(registry, server)
	TilemapCommands.register(registry, server)
	TilesetCommands.register(registry)
	AssetCommands.register(registry, server)
	SaveCommands.register(registry, server)
	ClassdbCommands.register(registry, server)
	ThemeCommands.register(registry, server)
	PathCommands.register(registry, server)
	ThreeDCommands.register(registry, server)
	AudioCommands.register(registry, server)
	ProceduralCommands.register(registry, server)
	SpriteframesCommands.register(registry, server)
	ParticleCommands.register(registry, server)
	NavigationCommands.register(registry, server)
	MetaCommands.register(registry)
	DebugCommands.register(registry, debug_bridge)
	SpatialCommands.register(registry, server)
	TextureCommands.register(registry, server)
	SoundCommands.register(registry, server)
