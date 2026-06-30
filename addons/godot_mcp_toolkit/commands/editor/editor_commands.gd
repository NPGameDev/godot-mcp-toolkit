@tool
extends RefCounted
## editor.* / execute.* command registration orchestrator — wires every editor.*
## and execute.* tool onto the registry and delegates each handler to its command
## child (log-reader, rescan, screenshot, execute). Holds no subdomain logic; the
## only handler it keeps local is the two-line editor.set_lsp_status server push.

const _LogReader := preload("res://addons/godot_mcp_toolkit/commands/editor/editor_log_reader.gd")
const _Rescan := preload("res://addons/godot_mcp_toolkit/commands/editor/editor_rescan.gd")
const _Screenshot := preload("res://addons/godot_mcp_toolkit/commands/editor/editor_screenshot.gd")
const _Execute := preload("res://addons/godot_mcp_toolkit/commands/editor/editor_execute.gd")


static func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:
	registry.add("editor.save_scene", func(parameters: Dictionary) -> Dictionary:
		# Route through the public safety class: C2 scan-idle guard + the C1
		# _in_dispatch flag around the synchronous save (see
		# mcp_toolkit_safe_scene_ops.gd). NEVER call EditorInterface.save_scene[_as]
		# directly — it can re-enter Main::iteration() mid-dispatch and crash/wedge.
		return await MCPToolkitSafeSceneOps.save_scene(str(parameters.get("file_path", "")))
	, MCPToolkitCommandOptions.new())
	registry.add("editor.screenshot", func(parameters: Dictionary) -> Dictionary:
		return await _Screenshot.cmd_screenshot(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only())
	registry.add("editor.refresh", func(parameters: Dictionary) -> Dictionary:
		return await _Rescan.cmd_refresh(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("editor.get_console", func(parameters: Dictionary) -> Dictionary:
		return _LogReader.cmd_get_console(server, parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
	registry.add("editor.wait_for_idle", func(parameters: Dictionary) -> Dictionary:
		return await _Rescan.cmd_wait_for_idle(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
	registry.add("execute.code", func(parameters: Dictionary) -> Dictionary:
		return _Execute.cmd_execute_code(parameters)
	, MCPToolkitCommandOptions.new())
	registry.add("editor.set_lsp_status", func(parameters: Dictionary) -> Dictionary:
		return _cmd_set_lsp_status(server, parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())


# -- Commands -----------------------------------------------------------------


## editor.set_lsp_status — the MCP server pushes its authoritative GDScript LSP
## verdict here (the editor can't read its own LSP bind status). Stored on the
## server for the dock to display. Internal command — not an MCP tool.
static func _cmd_set_lsp_status(server: Node, parameters: Dictionary) -> Dictionary:
	server.set_reported_lsp_status(parameters)
	return MCPToolkitSuccess.ok({"reported": true})
