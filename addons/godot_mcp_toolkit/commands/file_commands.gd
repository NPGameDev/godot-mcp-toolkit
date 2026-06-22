@tool
extends RefCounted
## file.* command handlers — generic file deletion for any res:// path.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const FileGuard = Modules.FileGuard
const Helpers = Modules.CommandHelpers

const _TAB_CLOSE_NOISE_HINT := "Closing a non-active scene tab may produce a _set_main_scene_state error in the editor console. This is benign Godot engine noise — safe to ignore."


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("file.delete", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_file_delete(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())


# -- Commands -----------------------------------------------------------------


static func _cmd_file_delete(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("file_path", ""))
	if file_path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing file_path")
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if file_path.begins_with("res://addons/godot_mcp_toolkit/"):
		return MCPToolkitError.fail("PATH_DENIED",
			"cannot delete files inside the MCP toolkit plugin directory")
	if not FileAccess.file_exists(file_path):
		return MCPToolkitError.fail("NOT_FOUND", "file not found: %s" % file_path, MCPToolkitError.HINT_FILE_PATH)

	# For scene files (.tscn/.scn), attempt to close the editor tab first.
	var tab_closed := false
	var tab_result := {}
	var warnings: Array[String] = []
	var ext := file_path.get_extension().to_lower()
	var is_scene := (ext == "tscn" or ext == "scn")

	if is_scene:
		tab_result = await Helpers.close_scene_tab_safe(file_path)
		tab_closed = tab_result.get("closed", false)
		if not tab_closed:
			var reason := str(tab_result.get("reason", ""))
			if reason == "no_api":
				# 4.2–4.4: no close API. Block active-scene deletion (Ctrl+S
				# would silently recreate the file). Non-active tabs proceed
				# with a phantom warning.
				var edited_root := Helpers.get_edited_root()
				if edited_root != null and edited_root.scene_file_path == file_path:
					return MCPToolkitError.fail("EDITED_SCENE",
						"cannot delete the currently-edited scene %s on Godot 4.2-4.4 (no programmatic tab-close API); close the scene tab manually, then retry file_delete" % file_path)
				warnings.append(
					"phantom tab: scene tab for %s remains open; Godot 4.2-4.4 has no API to close tabs — it will vanish on editor restart or manual close" % file_path)

	var delete_result: Dictionary = await Helpers.delete_res_file_and_deindex(
		file_path, [".uid", ".import"])
	if is_scene:
		delete_result["tab_closed"] = tab_closed
		if tab_closed and tab_result.get("switched", false):
			delete_result["hint"] = _TAB_CLOSE_NOISE_HINT
	if not warnings.is_empty():
		delete_result["warnings"] = warnings
	return delete_result
