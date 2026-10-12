@tool
extends RefCounted
## meta.* transport-level commands — the server's env overrides of the response limits.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const ResponseLimits = Modules.ResponseLimits


static func register(registry: MCPToolkitCommandRegistry) -> void:
	registry.add("meta.set_limits", func(parameters: Dictionary) -> Dictionary:
		return _cmd_set_limits(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())


## Sets the server's env overrides of the response limits: each limit present and
## not null becomes an env override, held for this editor session and never saved
## to project.godot. The push replaces the whole previous set, so a limit left out
## falls back to its project value and an empty push clears them all. With several
## MCP clients connected, the last push wins: the handler cannot tell which peer
## sent it. Replies with the three effective values, floors applied.
static func _cmd_set_limits(parameters: Dictionary) -> Dictionary:
	ResponseLimits.replace_env_overrides(parameters)
	var effective := {}
	for key in ResponseLimits.KEYS:
		effective[key] = ResponseLimits.effective_value(key)
	return MCPToolkitSuccess.ok(effective)
