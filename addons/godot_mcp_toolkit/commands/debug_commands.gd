@tool
extends RefCounted
## debug.* command handlers — breakpoint management + debug state.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const McpError = _Hub.McpError
const FileGuard = _Hub.FileGuard


static func register(registry: MCPToolkitCommandRegistry, debug_bridge: RefCounted) -> void:
	registry.add("debug.state", func(_params: Dictionary) -> Dictionary:
		return _cmd_debug_state(debug_bridge)
	, {"is_read_only": true, "is_active_scene_required": false})
	registry.add("debug.list_breakpoints", func(_params: Dictionary) -> Dictionary:
		return _cmd_debug_list_breakpoints()
	, {"is_read_only": true, "is_active_scene_required": false})
	registry.add("debug.set_breakpoint", func(params: Dictionary) -> Dictionary:
		return _cmd_debug_set_breakpoint(params)
	, {"is_active_scene_required": false})
	registry.add("debug.continue", func(_params: Dictionary) -> Dictionary:
		return _cmd_debug_continue(debug_bridge)
	, {"is_active_scene_required": false})


# -- Commands -----------------------------------------------------------------


static func _cmd_debug_state(debug_bridge: RefCounted) -> Dictionary:
	var state := debug_bridge.get_debug_state() as Dictionary
	state["success"] = true
	return state


static func _cmd_debug_list_breakpoints() -> Dictionary:
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return {"success": true, "breakpoints": [], "count": 0,
			"note": "GDScript breakpoints only"}

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

	return {"success": true, "breakpoints": breakpoints, "count": breakpoints.size(),
		"note": "GDScript breakpoints only"}


static func _cmd_debug_set_breakpoint(params: Dictionary) -> Dictionary:
	var file_path := str(params.get("file_path", ""))
	var line: int = int(params.get("line", 0))
	var enabled: bool = true
	if params.has("enabled"):
		enabled = bool(params.get("enabled"))

	if file_path.is_empty():
		return McpError.make("INVALID_PARAMS", "file_path is required")
	if line < 1:
		return McpError.make("INVALID_PARAMS", "line must be >= 1")

	# Reject non-GDScript files.
	if file_path.ends_with(".cs"):
		return McpError.make("UNSUPPORTED_FILE_TYPE",
			"Breakpoint management supports GDScript (.gd) files only. "
			+ "C# breakpoints should be set in your IDE (VS Code, Rider).")
	if not file_path.ends_with(".gd"):
		return McpError.make("UNSUPPORTED_FILE_TYPE",
			"Breakpoint management supports GDScript (.gd) files only.")

	# I4: FileGuard path validation.
	if not file_path.begins_with("res://"):
		return McpError.make("INVALID_PATH", "file_path must start with res://")
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return McpError.make("PATH_DENIED", str(guard["reason"]))

	if not FileAccess.file_exists(file_path):
		return McpError.make("NOT_FOUND",
			"no file at %s" % file_path, McpError.HINT_FILE_PATH)

	# Load and open the script in the editor.
	var script: Script = ResourceLoader.load(file_path) as Script
	if script == null:
		return McpError.make("LOAD_FAILED",
			"could not load %s as Script" % file_path)

	EditorInterface.edit_script(script, line)

	# Get the CodeEdit from the now-current editor.
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return McpError.make("INTERNAL", "ScriptEditor not available")
	var editor := script_editor.get_current_editor()
	if editor == null:
		return McpError.make("INTERNAL",
			"no current script editor after edit_script")
	var code_edit := editor.get_base_editor() as CodeEdit
	if code_edit == null:
		return McpError.make("INTERNAL", "CodeEdit not available")

	# Validate line number against file length.
	var line_count := code_edit.get_line_count()
	if line > line_count:
		return McpError.make("INVALID_PARAMS",
			"line %d exceeds file length (%d lines)" % [line, line_count])

	# Set or clear the breakpoint (0-based internally).
	code_edit.set_line_as_breakpoint(line - 1, enabled)

	return {"success": true, "file_path": file_path, "line": line, "enabled": enabled}


static func _cmd_debug_continue(debug_bridge: RefCounted) -> Dictionary:
	var result := debug_bridge.try_continue() as Dictionary
	if result.has("error"):
		var code: String = result["error"]
		match code:
			"GAME_NOT_RUNNING":
				return McpError.make("GAME_NOT_RUNNING",
					"no active debug session — start a game with game.start first")
			"NOT_BREAKED":
				return McpError.make("NOT_BREAKED",
					"debug session is active but not paused at a breakpoint")
			_:
				return McpError.make("INTERNAL", str(result))
	return result
