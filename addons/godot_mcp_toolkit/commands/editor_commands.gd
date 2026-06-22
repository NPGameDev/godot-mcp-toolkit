@tool
extends RefCounted
## editor.* command handlers — errors, save, screenshot, reload, console, wait-for-idle.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const _LogReader := preload("res://addons/godot_mcp_toolkit/commands/editor_log_reader.gd")
const FileGuard = _Hub.FileGuard
const Untrusted = _Hub.Untrusted
const Scrubber = _Hub.Scrubber
const Helpers = _Hub.Helpers
const LogHelpers = _Hub.LogHelpers
const Coerce = _Hub.Coerce
const MIN_SCREENSHOT_SIZE := 64
const MAX_SCREENSHOT_SIZE := 4096


static func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:
	registry.add("editor.get_errors", func(parameters: Dictionary) -> Dictionary:
		return _LogReader.cmd_get_errors(server, parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
	registry.add("editor.save_scene", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_editor_save_scene(parameters)
	, MCPToolkitCommandOptions.new())
	registry.add("editor.screenshot", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_editor_screenshot(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only())
	registry.add("editor.refresh", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_editor_refresh(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("editor.get_console", func(parameters: Dictionary) -> Dictionary:
		return _LogReader.cmd_get_console(server, parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
	registry.add("editor.wait_for_idle", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_editor_wait_for_idle(parameters)
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


static func _cmd_editor_screenshot(parameters: Dictionary) -> Dictionary:
	if _Hub.VersionUtils.is_headless():
		return MCPToolkitError.fail("HEADLESS_UNSUPPORTED",
			"editor.screenshot requires a display server (no viewport in headless mode)")

	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)

	# Node-focused screenshot: select + capture a specific node, then restore.
	if not node_path.is_empty():
		var size_dict: Dictionary = parameters.get("size", {}) if typeof(parameters.get("size", {})) == TYPE_DICTIONARY else {}
		var width := int(size_dict.get("width", 1280))
		var height := int(size_dict.get("height", 720))
		if width < MIN_SCREENSHOT_SIZE or width > MAX_SCREENSHOT_SIZE \
				or height < MIN_SCREENSHOT_SIZE or height > MAX_SCREENSHOT_SIZE:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"size.width and size.height must be in [64, 4096] (got %dx%d)" % [width, height])
		var root := Helpers.get_edited_root()
		if root == null:
			return MCPToolkitError.fail("NO_SCENE", "no edited scene")
		var node: Variant = null
		if node_path == ".":
			node = root
		else:
			node = root.get_node_or_null(node_path)
		if node == null:
			return MCPToolkitError.fail("NOT_FOUND", "no node at %s" % node_path, MCPToolkitError.HINT_NODE_PATH)

		var selection := EditorInterface.get_selection()
		var prior_selection: Array = []
		if selection != null:
			for selected_node in selection.get_selected_nodes():
				prior_selection.append(selected_node)
			selection.clear()
			selection.add_node(node)
		EditorInterface.edit_node(node)
		await RenderingServer.frame_post_draw

		var viewport: SubViewport = null
		if node is Node3D:
			viewport = EditorInterface.get_editor_viewport_3d(0)
		if viewport == null:
			viewport = EditorInterface.get_editor_viewport_2d()
		if viewport == null:
			return MCPToolkitError.fail("INTERNAL", "no editor viewport available")
		var image := viewport.get_texture().get_image()
		if image == null:
			return MCPToolkitError.fail("INTERNAL",
				"viewport texture unavailable (nothing rendered yet?)")
		if image.get_width() != width or image.get_height() != height:
			image.resize(width, height, Image.INTERPOLATE_LANCZOS)

		if selection != null:
			selection.clear()
			for selected_node in prior_selection:
				if is_instance_valid(selected_node):
					selection.add_node(selected_node)
		var png_bytes := image.save_png_to_buffer()
		if png_bytes.is_empty():
			return MCPToolkitError.fail("EMPTY_CONTENT",
				"node '%s' produced no visible image. Node may lack visual content (no texture, no mesh). Use editor_screenshot without node_path for a full viewport capture instead." % node_path)
		return MCPToolkitSuccess.ok({
			"image_base64": Marshalls.raw_to_base64(png_bytes),
			"mime_type": "image/png",
			"width": image.get_width(),
			"height": image.get_height(),
			"bytes": png_bytes.size(),
			"path": node_path,
		})

	# Standard viewport screenshot.
	var save_path := str(parameters.get("save_path", ""))
	var viewport: SubViewport = EditorInterface.get_editor_viewport_2d()
	if viewport == null:
		viewport = EditorInterface.get_editor_viewport_3d(0)
	if viewport == null:
		return MCPToolkitError.fail("INTERNAL", "no editor viewport available")
	var image := viewport.get_texture().get_image()
	if image == null:
		return MCPToolkitError.fail("INTERNAL",
			"viewport texture unavailable (nothing rendered yet?)")

	var png_bytes := image.save_png_to_buffer()
	if png_bytes.is_empty():
		return MCPToolkitError.fail("INTERNAL", "save_png_to_buffer returned empty")

	var persisted_path := ""
	if not save_path.is_empty():
		var guard := FileGuard.resolve_safe(
			save_path, ["res://", "user://screenshots/"])
		if guard["error"] != null:
			return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
		if not save_path.ends_with(".png"):
			return MCPToolkitError.fail("INVALID_PARAMS",
				"save_path must end with .png: %s" % save_path)
		var directory_path := save_path.get_base_dir()
		if not directory_path.is_empty():
			var mkdir_error := DirAccess.make_dir_recursive_absolute(directory_path)
			if mkdir_error != OK and mkdir_error != ERR_ALREADY_EXISTS:
				return MCPToolkitError.fail("INTERNAL",
					"could not create %s (err %d)" % [directory_path, mkdir_error])
		var save_error := image.save_png(save_path)
		if save_error != OK:
			return MCPToolkitError.fail("INTERNAL",
				"save_png failed (err %d) for %s" % [save_error, save_path])
		persisted_path = save_path

	var response := {
		"image_base64": Marshalls.raw_to_base64(png_bytes),
		"mime_type": "image/png",
		"width": image.get_width(),
		"height": image.get_height(),
		"bytes": png_bytes.size(),
	}
	if image.get_width() < 16 or image.get_height() < 16:
		response["warning"] = "Screenshot captured only %dx%d — editor may be minimized or running headless. Use script_check and editor_get_console for non-visual verification." % [image.get_width(), image.get_height()]
	if not persisted_path.is_empty():
		response["path"] = persisted_path
	return MCPToolkitSuccess.ok(response)


## Whether an open script should be reloaded after a full editor.refresh scan:
## only scripts the scan actually changed, and NEVER the toolkit's own (reloading
## an unchanged or toolkit-own script would cancel a suspended coroutine — the
## C1/C3 crash class; 41l-tricies). Pure logic so it can be unit-tested.
static func should_reload_open_script(resource_path: String, changed: Dictionary) -> bool:
	return changed.has(resource_path) and not resource_path.begins_with("res://addons/godot_mcp_toolkit/")


static func _cmd_editor_refresh(parameters: Dictionary) -> Dictionary:
	# Flush stale errors before reload — fresh parse errors will be captured
	# with new IDs so editor_get_console returns only current-state errors.
	var errors_cleared := _Hub.LogBuffer.clear_level("error")

	var file_paths_raw = parameters.get("file_paths", null)
	var targeted := file_paths_raw != null and typeof(file_paths_raw) == TYPE_ARRAY \
		and (file_paths_raw as Array).size() > 0

	var filesystem := EditorInterface.get_resource_filesystem()
	var scan_waited_ms := 0

	if targeted:
		# Targeted mode: update_file() per path — O(1) per file.
		var paths: Array = file_paths_raw as Array
		if filesystem != null:
			for path in paths:
				filesystem.update_file(str(path))
		var reloaded := 0
		var script_editor := EditorInterface.get_script_editor()
		if script_editor != null:
			var target_set := {}
			for path in paths:
				target_set[str(path)] = true
			for open_script in script_editor.get_open_scripts():
				if open_script is Script:
					if target_set.has(open_script.resource_path):
						open_script.reload(true)
						reloaded += 1
		return MCPToolkitSuccess.ok({"mode": "targeted", "file_count": paths.size(),
			"reloaded": reloaded, "errors_cleared": errors_cleared})

	# Full mode: scan(), then reload ONLY the scripts the scan actually changed
	# (captured via the resources_reload signal — present in all of 4.2-4.6), and
	# only if they're open. NEVER reload an unchanged script: reload(true) cancels
	# any suspended coroutine in it, which would break the user's @tool plugins and
	# (for the toolkit's own scripts) leak the mutation dispatch lock (C3 root cause;
	# 41l-tricies). The toolkit's own scripts are skipped even when changed.
	var changed := {}
	var collector := func(resources: PackedStringArray) -> void:
		for r in resources:
			changed[str(r)] = true
	if filesystem != null:
		filesystem.resources_reload.connect(collector)
		filesystem.scan()
		var scan_start := Time.get_ticks_msec()
		var scan_deadline := scan_start + 5000
		while filesystem.is_scanning() and Time.get_ticks_msec() < scan_deadline:
			await Engine.get_main_loop().create_timer(0.1).timeout
		scan_waited_ms = Time.get_ticks_msec() - scan_start
		if filesystem.resources_reload.is_connected(collector):
			filesystem.resources_reload.disconnect(collector)
	var reloaded := 0
	var script_editor := EditorInterface.get_script_editor()
	if script_editor != null:
		for open_script in script_editor.get_open_scripts():
			if not (open_script is Script):
				continue
			# Reload ONLY scan-changed, non-toolkit open scripts (see
			# should_reload_open_script — never cancel an unchanged/own coroutine).
			if not should_reload_open_script(str(open_script.resource_path), changed):
				continue
			open_script.reload(true)
			reloaded += 1
	return MCPToolkitSuccess.ok({"mode": "full", "reloaded": reloaded,
		"scan_waited_ms": scan_waited_ms, "errors_cleared": errors_cleared})



static func _cmd_editor_wait_for_idle(parameters: Dictionary) -> Dictionary:
	var timeout_ms: int = int(parameters.get("timeout_ms", 10000))
	if timeout_ms < 0 or timeout_ms > 30000:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"timeout_ms must be in [0, 30000] (got %d)" % timeout_ms)
	var filesystem := EditorInterface.get_resource_filesystem()
	if not filesystem.is_scanning():
		return MCPToolkitSuccess.ok({"was_scanning": false, "waited_ms": 0})
	var start := Time.get_ticks_msec()
	while filesystem.is_scanning() and Time.get_ticks_msec() - start < timeout_ms:
		await Engine.get_main_loop().create_timer(0.1).timeout
	var elapsed := Time.get_ticks_msec() - start
	if filesystem.is_scanning():
		return MCPToolkitError.fail("TIMEOUT",
			"EditorFileSystem still scanning after %dms; consider increasing timeout_ms or checking editor.get_console for import errors" % elapsed)
	return MCPToolkitSuccess.ok({"was_scanning": true, "waited_ms": elapsed})


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
