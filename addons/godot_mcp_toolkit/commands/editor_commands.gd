@tool
extends RefCounted
## editor.* command handlers — errors, save, screenshot, reload, console, wait-for-idle.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const _LogReader := preload("res://addons/godot_mcp_toolkit/commands/editor_log_reader.gd")
const _Rescan := preload("res://addons/godot_mcp_toolkit/commands/editor_rescan.gd")
const _Screenshot := preload("res://addons/godot_mcp_toolkit/commands/editor_screenshot.gd")
const Untrusted = _Hub.Untrusted
const Scrubber = _Hub.Scrubber
const Helpers = _Hub.Helpers
const LogHelpers = _Hub.LogHelpers
const Coerce = _Hub.Coerce


static func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:
	registry.add("editor.get_errors", func(parameters: Dictionary) -> Dictionary:
		return _LogReader.cmd_get_errors(server, parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
	registry.add("editor.save_scene", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_editor_save_scene(parameters)
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
		return _cmd_execute_code(parameters)
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


static func _cmd_editor_save_scene(parameters: Dictionary) -> Dictionary:
	# Route through the public safety class: C2 scan-idle guard + the C1
	# _in_dispatch flag around the synchronous save (see
	# mcp_toolkit_safe_scene_ops.gd). NEVER call EditorInterface.save_scene[_as]
	# directly — it can re-enter Main::iteration() mid-dispatch and crash/wedge.
	return await MCPToolkitSafeSceneOps.save_scene(str(parameters.get("file_path", "")))


static func _cmd_execute_code(parameters: Dictionary) -> Dictionary:
	var code := str(parameters.get("code", ""))
	if code.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing code")

	# Statement keyword guard (same as runtime handler).
	var trimmed := code.strip_edges()
	for kw in ["var", "return", "func", "if", "for", "while", "class", "const", "match"]:
		if trimmed == kw or trimmed.begins_with(kw + " ") or trimmed.begins_with(kw + "\t") or trimmed.begins_with(kw + "\n"):
			return MCPToolkitError.fail("PARSE_ERROR",
				"execute_code only supports expressions, not statements. '%s' is a statement keyword. " % kw +
				"Use method calls, property access, or arithmetic instead.")

	# Resolve scope node.
	var scope_node: Node = null
	var scope_path := str(parameters.get("scope_path", ""))
	if scope_path.is_empty():
		var edited := EditorInterface.get_edited_scene_root()
		if edited != null:
			scope_node = edited
		else:
			# Fallback to editor base control so expressions still have a Node scope
			scope_node = EditorInterface.get_base_control()
	else:
		var edited := EditorInterface.get_edited_scene_root()
		if edited == null:
			return MCPToolkitError.fail("NO_SCENE", "No scene open — cannot resolve scope_path")
		scope_path = Helpers.normalize_editor_path(scope_path)
		scope_node = edited.get_node_or_null(NodePath(scope_path))
		if scope_node == null:
			return MCPToolkitError.fail("NOT_FOUND", "scope node not found: " + scope_path)

	var expr := Expression.new()
	var parse_err := expr.parse(code, PackedStringArray())
	if parse_err != OK:
		return MCPToolkitError.fail("PARSE_ERROR", expr.get_error_text())
	var result = expr.execute([], scope_node, false)
	if expr.has_execute_failed():
		var err_text := expr.get_error_text()
		# FIX-4: Detect known singletons in error and append recovery hints.
		var singletons := ["EditorInterface", "Engine", "OS", "Input",
			"DisplayServer", "ProjectSettings", "ResourceLoader", "ResourceSaver",
			"RenderingServer", "PhysicsServer2D", "PhysicsServer3D"]
		for singleton in singletons:
			if singleton in err_text:
				err_text += "\n\nHint: '%s' is a global singleton not accessible in Expression.execute(). Use dedicated MCP tools instead (e.g., editor_refresh, project_get_settings, node_call_method)." % singleton
				break
		# Detect chained property access failure on returned objects.
		if "Invalid named index" in err_text and "base type Object" in err_text:
			err_text += "\n\nHint: Expression.execute() cannot chain property access on returned objects. Use runtime_get_node_state or node_call_method for multi-step property access."
		# FIX-H: Detect load() call failures — Expression cannot call load().
		if "call to 'load'" in err_text.to_lower():
			err_text += _make_load_hint(code)
		return MCPToolkitError.fail("EXECUTE_FAILED", err_text)
	return MCPToolkitSuccess.ok({"result": Coerce.serialize_value(result)})


## Build a context-aware hint when Expression.execute() fails on load().
## If the load() target is a .gd script, suggest the editor-side tool workflow;
## otherwise, suggest node_set_property with Resource type tags.
static func _make_load_hint(code: String) -> String:
	var re := RegEx.new()
	re.compile("load\\s*\\(\\s*[\"']([^\"']+)[\"']\\s*\\)")
	var m := re.search(code)
	if m != null and m.get_string(1).ends_with(".gd"):
		return (
			"\n\nHint: Expression.execute() cannot call load() in any context (editor or runtime). "
			+ "To run GDScript logic in the editor: "
			+ "(1) write a @tool script with script_write, "
			+ "(2) create a temporary node with scene_create_node, "
			+ "(3) attach the script with node_set_script, "
			+ "(4) call the method with node_call_method, "
			+ "(5) delete the temp node with node_manage(action:'delete')."
		)
	return (
		"\n\nHint: Expression.execute() cannot call load() in any context (editor or runtime). "
		+ "Assign resources via node_set_property with {\"type\": \"Resource\", \"path\": \"res://...\"}."
	)
