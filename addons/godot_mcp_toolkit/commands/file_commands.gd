@tool
extends RefCounted
## file.* command handlers — generic file deletion for any res:// path.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPCommandRegistry = _Hub.MCPCommandRegistry


static func register(registry: MCPCommandRegistry, _server: Node) -> void:
	registry.add("file.delete", func(parameters: Dictionary) -> Dictionary:
		return _cmd_file_delete(parameters), "full")


# -- Commands -----------------------------------------------------------------


static func _cmd_file_delete(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("file_path", ""))
	if file_path.is_empty():
		return MCPError.make("INVALID_PARAMS", "missing file_path")
	# TODO(iter-18): replace this prefix check with FileGuard.resolve_safe(path).
	if not file_path.begins_with("res://"):
		return MCPError.make("INVALID_PATH",
			"path must start with res:// (got %s)" % file_path)
	if file_path.begins_with("res://addons/godot_mcp_toolkit/"):
		return MCPError.make("PATH_DENIED",
			"cannot delete files inside the MCP toolkit plugin directory")
	if not FileAccess.file_exists(file_path):
		return MCPError.make("NOT_FOUND", "file not found: %s" % file_path)
	var edited_root := EditorInterface.get_edited_scene_root()
	if edited_root != null and edited_root.scene_file_path == file_path:
		return MCPError.make("EDITED_SCENE",
			"cannot delete the currently-edited scene %s; close it via scene.close first, or use scene.delete after closing" % file_path)
	var directory := DirAccess.open("res://")
	if directory == null:
		return MCPError.make("INTERNAL", "DirAccess.open(res://) returned null")
	var relative_path := file_path.substr("res://".length())
	var remove_error := directory.remove(relative_path)
	if remove_error != OK:
		return MCPError.make("DELETE_FAILED",
			"DirAccess.remove returned %d (path=%s)" % [remove_error, file_path])
	var import_relative := relative_path + ".import"
	if directory.file_exists(import_relative):
		directory.remove(import_relative)
	var uid_relative := relative_path + ".uid"
	if directory.file_exists(uid_relative):
		directory.remove(uid_relative)
	return {"success": true, "path": file_path}
