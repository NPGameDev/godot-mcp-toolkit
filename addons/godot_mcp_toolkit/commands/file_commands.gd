@tool
extends RefCounted
## file.* command handlers — generic file deletion for any res:// path.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPCommandRegistry = _Hub.MCPCommandRegistry
const MCPFileGuard = _Hub.MCPFileGuard
const MCPHelpers = _Hub.MCPHelpers


static func register(registry: MCPCommandRegistry, _server: Node) -> void:
	registry.add("file.delete", func(parameters: Dictionary) -> Dictionary:
		return _cmd_file_delete(parameters))


# -- Commands -----------------------------------------------------------------


static func _cmd_file_delete(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("file_path", ""))
	if file_path.is_empty():
		return MCPError.make("INVALID_PARAMS", "missing file_path")
	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	if file_path.begins_with("res://addons/godot_mcp_toolkit/"):
		return MCPError.make("PATH_DENIED",
			"cannot delete files inside the MCP toolkit plugin directory")
	if not FileAccess.file_exists(file_path):
		return MCPError.make("NOT_FOUND", "file not found: %s" % file_path, MCPError.HINT_FILE_PATH)
	var edited_root := EditorInterface.get_edited_scene_root()
	if edited_root != null and edited_root.scene_file_path == file_path:
		return MCPError.make("EDITED_SCENE",
			"cannot delete the currently-edited scene %s; close it via scene.close first, or use scene.delete after closing" % file_path)
	return MCPHelpers.delete_res_file(file_path, [".uid", ".import"])
