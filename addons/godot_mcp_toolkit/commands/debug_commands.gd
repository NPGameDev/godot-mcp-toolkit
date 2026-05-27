@tool
extends RefCounted
## debug.* command handlers — breakpoint management + debug state.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const FileGuard = _Hub.FileGuard


static func register(registry: MCPToolkitCommandRegistry, debug_bridge: RefCounted) -> void:
	registry.add("debug.state", func(_params: Dictionary) -> Dictionary:
		return _cmd_debug_state(debug_bridge)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
	registry.add("debug.list_breakpoints", func(_params: Dictionary) -> Dictionary:
		return _cmd_debug_list_breakpoints()
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
	registry.add("debug.set_breakpoint", func(params: Dictionary) -> Dictionary:
		return _cmd_debug_set_breakpoint(params)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("debug.continue", func(_params: Dictionary) -> Dictionary:
		return _cmd_debug_continue(debug_bridge)
	, MCPToolkitCommandOptions.new().mark_scene_independent())


# -- Commands -----------------------------------------------------------------


static func _cmd_debug_state(debug_bridge: RefCounted) -> Dictionary:
	var state := debug_bridge.get_debug_state() as Dictionary
	return MCPToolkitSuccess.ok(state)


static func _cmd_debug_list_breakpoints() -> Dictionary:
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return MCPToolkitSuccess.ok({"breakpoints": [], "count": 0,
			"note": "GDScript breakpoints only"})

	var open_scripts := script_editor.get_open_scripts()
	var breakpoints := []

	# Save the current script to restore after iteration.
	var original_script = script_editor.get_current_script()

	for script in open_scripts:
		if not (script is Script):
			continue
		if not script.resource_path.ends_with(".gd"):
			continue  # GDScript only — C# breakpoints are IDE-managed.

		# Switch to this script's tab to access its CodeEdit.
		EditorInterface.edit_script(script, -1, 0, false)

		var editor := script_editor.get_current_editor()
		if editor == null:
			continue
		var code_edit := editor.get_base_editor() as CodeEdit
		if code_edit == null:
			continue

		for line_idx in code_edit.get_line_count():
			if code_edit.is_line_breakpointed(line_idx):
				breakpoints.append({
					"file_path": script.resource_path,
					"line": line_idx + 1,  # 1-based for the API consumer.
				})

	# Restore the original script tab.
	if original_script != null and original_script is Script:
		EditorInterface.edit_script(original_script, -1, 0, false)

	return MCPToolkitSuccess.ok({"breakpoints": breakpoints, "count": breakpoints.size(),
		"note": "GDScript breakpoints only"})


static func _cmd_debug_set_breakpoint(params: Dictionary) -> Dictionary:
	var file_path := str(params.get("file_path", ""))
	var line: int = int(params.get("line", 0))
	var enabled: bool = true
	if params.has("enabled"):
		enabled = bool(params.get("enabled"))

	if file_path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "file_path is required")
	if line < 1:
		return MCPToolkitError.fail("INVALID_PARAMS", "line must be >= 1")

	# Reject non-GDScript files.
	if file_path.ends_with(".cs"):
		return MCPToolkitError.fail("UNSUPPORTED_FILE_TYPE",
			"Breakpoint management supports GDScript (.gd) files only. "
			+ "C# breakpoints should be set in your IDE (VS Code, Rider).")
	if not file_path.ends_with(".gd"):
		return MCPToolkitError.fail("UNSUPPORTED_FILE_TYPE",
			"Breakpoint management supports GDScript (.gd) files only.")

	# I4: FileGuard path validation.
	if not file_path.begins_with("res://"):
		return MCPToolkitError.fail("INVALID_PATH", "file_path must start with res://")
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))

	if not FileAccess.file_exists(file_path):
		return MCPToolkitError.fail("NOT_FOUND",
			"no file at %s" % file_path, MCPToolkitError.HINT_FILE_PATH)

	# Load and open the script in the editor.
	var script: Script = ResourceLoader.load(file_path) as Script
	if script == null:
		return MCPToolkitError.fail("LOAD_FAILED",
			"could not load %s as Script" % file_path)

	EditorInterface.edit_script(script, line)

	# Get the CodeEdit from the now-current editor.
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return MCPToolkitError.fail("INTERNAL", "ScriptEditor not available")
	var editor := script_editor.get_current_editor()
	if editor == null:
		return MCPToolkitError.fail("INTERNAL",
			"no current script editor after edit_script")
	var code_edit := editor.get_base_editor() as CodeEdit
	if code_edit == null:
		return MCPToolkitError.fail("INTERNAL", "CodeEdit not available")

	# Validate line number against file length.
	var line_count := code_edit.get_line_count()
	if line > line_count:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"line %d exceeds file length (%d lines)" % [line, line_count])

	# Set or clear the breakpoint (0-based internally).
	code_edit.set_line_as_breakpoint(line - 1, enabled)

	return MCPToolkitSuccess.ok({"file_path": file_path, "line": line, "enabled": enabled})


static func _cmd_debug_continue(debug_bridge: RefCounted) -> Dictionary:
	var result := debug_bridge.try_continue() as Dictionary
	if result.has("error"):
		var code: String = result["error"]
		match code:
			"GAME_NOT_RUNNING":
				return MCPToolkitError.fail("GAME_NOT_RUNNING",
					"no active debug session — start a game with game.start first")
			"NOT_BREAKED":
				return MCPToolkitError.fail("NOT_BREAKED",
					"debug session is active but not paused at a breakpoint")
			_:
				return MCPToolkitError.fail("INTERNAL", str(result))
	return MCPToolkitSuccess.ok(result)
