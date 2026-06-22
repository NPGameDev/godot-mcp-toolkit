@tool
extends RefCounted
## meta.* transport-level commands — server-side limit overrides.


static func register(registry: MCPToolkitCommandRegistry) -> void:
	registry.add("meta.set_limits", func(parameters: Dictionary) -> Dictionary:
		return _cmd_set_limits(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())


## The sanctioned writer for `mcp_toolkit/limits/*` — `project.set_setting`
## deliberately refuses that prefix, routing limit changes here so the floor
## clamps are always applied (script/save read caps >= 64 KB, ws_buffer >= 256 KB).
static func _cmd_set_limits(parameters: Dictionary) -> Dictionary:
	var script_cap = parameters.get("script_read_cap_kb", null)
	var save_cap = parameters.get("save_read_cap_kb", null)
	var ws_buf = parameters.get("ws_buffer_kb", null)
	if script_cap != null:
		ProjectSettings.set_setting("mcp_toolkit/limits/script_read_cap_kb",
			maxi(int(script_cap), 64))
	if save_cap != null:
		ProjectSettings.set_setting("mcp_toolkit/limits/save_read_cap_kb",
			maxi(int(save_cap), 64))
	if ws_buf != null:
		ProjectSettings.set_setting("mcp_toolkit/limits/ws_buffer_kb",
			maxi(int(ws_buf), 256))
	return MCPToolkitSuccess.ok({
		"script_read_cap_kb": int(ProjectSettings.get_setting(
			"mcp_toolkit/limits/script_read_cap_kb", 256)),
		"save_read_cap_kb": int(ProjectSettings.get_setting(
			"mcp_toolkit/limits/save_read_cap_kb", 256)),
		"ws_buffer_kb": int(ProjectSettings.get_setting(
			"mcp_toolkit/limits/ws_buffer_kb", 1024)),
	})
