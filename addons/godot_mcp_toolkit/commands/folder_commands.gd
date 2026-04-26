@tool
extends RefCounted
## folder.* command handlers — create and delete directories under res://.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPCommandRegistry = _Hub.MCPCommandRegistry
const MCPFileGuard = _Hub.MCPFileGuard


static func register(registry: MCPCommandRegistry, _server: Node) -> void:
	registry.add("folder.create", func(parameters: Dictionary) -> Dictionary:
		return _cmd_folder_create(parameters))
	registry.add("folder.delete", func(parameters: Dictionary) -> Dictionary:
		return _cmd_folder_delete(parameters))


# -- Commands -----------------------------------------------------------------


static func _cmd_folder_create(parameters: Dictionary) -> Dictionary:
	var err = MCPError.check_required(parameters, ["folder_path"])
	if err != null:
		return err
	var folder_path := str(parameters.get("folder_path", ""))
	var guard := MCPFileGuard.resolve_safe(folder_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	var pre_existed := DirAccess.dir_exists_absolute(folder_path)
	var error := DirAccess.make_dir_recursive_absolute(folder_path)
	if error != OK:
		return MCPError.make("CREATE_DIR_FAILED",
			"DirAccess.make_dir_recursive_absolute returned %d (path=%s)" % [error, folder_path])
	var status := "returned" if pre_existed else "created"
	return {"success": true, "status": status, "path": folder_path}


static func _cmd_folder_delete(parameters: Dictionary) -> Dictionary:
	var err = MCPError.check_required(parameters, ["folder_path"])
	if err != null:
		return err
	var folder_path := str(parameters.get("folder_path", ""))
	var recursive := bool(parameters.get("recursive", false))
	var guard := MCPFileGuard.resolve_safe(folder_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))

	if folder_path == "res://" or folder_path == "res:///" or folder_path.get_base_dir() == "":
		return MCPError.make("FOLDER_PROTECTED",
			"cannot delete the project root res://; narrow the path")

	var normalized := folder_path
	if normalized.ends_with("/"):
		normalized = normalized.substr(0, normalized.length() - 1)
	if normalized == "res://addons" or normalized == "res://addons/godot_mcp_toolkit":
		return MCPError.make("FOLDER_PROTECTED",
			"cannot delete res://addons or the toolkit plugin directory (%s); agent cannot remove its own host" % normalized)
	if not DirAccess.dir_exists_absolute(folder_path):
		return MCPError.make("NOT_FOUND", "no folder at %s" % folder_path)
	var normalized_with_slash := normalized + "/"

	var edited := EditorInterface.get_edited_scene_root()
	if edited != null:
		var scene_path := str(edited.scene_file_path)
		if not scene_path.is_empty() and (scene_path == normalized or scene_path.begins_with(normalized_with_slash)):
			return MCPError.make("PATH_IN_USE",
				"folder %s contains the currently-edited scene %s; open a different scene first via scene.open" % [
					folder_path, scene_path])

	var script_editor := EditorInterface.get_script_editor()
	if script_editor != null:
		for open_script in script_editor.get_open_scripts():
			if not (open_script is Resource):
				continue
			var resource_path := str((open_script as Resource).resource_path)
			if resource_path.is_empty():
				continue
			if resource_path == normalized or resource_path.begins_with(normalized_with_slash):
				return MCPError.make("PATH_IN_USE",
					"folder %s contains open script %s; close the script editor tab first" % [
						folder_path, resource_path])

	var directory := DirAccess.open(folder_path)
	if directory == null:
		return MCPError.make("INTERNAL",
			"DirAccess.open(%s) returned null" % folder_path)
	var file_count := directory.get_files().size()
	var subdir_count := directory.get_directories().size()
	if (file_count + subdir_count) > 0 and not recursive:
		return MCPError.make("DIR_NOT_EMPTY",
			"folder %s is not empty (contains %d files, %d subdirs); pass recursive:true to delete contents" % [
				folder_path, file_count, subdir_count])

	var files_deleted := 0
	var dirs_deleted := 0
	if recursive and (file_count + subdir_count) > 0:
		var result := _folder_delete_recursive(folder_path)
		files_deleted = int(result.get("files", 0))
		dirs_deleted = int(result.get("dirs", 0))
		if not bool(result.get("ok", false)):
			return MCPError.make("DELETE_FAILED", str(result.get("error", "unknown")))

	var parent_path := folder_path.get_base_dir()
	var parent_dir := DirAccess.open(parent_path)
	if parent_dir == null:
		return MCPError.make("INTERNAL",
			"DirAccess.open(%s) returned null" % parent_path)
	var top_remove := parent_dir.remove(folder_path.get_file())
	if top_remove != OK:
		return MCPError.make("DELETE_FAILED",
			"DirAccess.remove returned %d (path=%s)" % [top_remove, folder_path])
	if recursive and (file_count + subdir_count) > 0:
		push_warning("[MCPTools] folder.delete recursive %s (%d files, %d subdirs)" % [
			folder_path, files_deleted, dirs_deleted])
	return {
		"success": true,
		"path": folder_path,
		"recursive": recursive,
		"files_deleted": files_deleted,
		"directories_deleted": dirs_deleted,
	}


# -- Recursive delete helper --------------------------------------------------


static func _folder_delete_recursive(folder_path: String) -> Dictionary:
	var directory := DirAccess.open(folder_path)
	if directory == null:
		return {"files": 0, "dirs": 0, "ok": false,
			"error": "DirAccess.open(%s) returned null" % folder_path}
	var files_removed := 0
	var dirs_removed := 0
	for file_name in directory.get_files():
		if file_name.ends_with(".uid"):
			continue
		var remove_error := directory.remove(file_name)
		if remove_error != OK:
			return {"files": files_removed, "dirs": dirs_removed, "ok": false,
				"error": "DirAccess.remove %s/%s returned %d" % [folder_path, file_name, remove_error]}
		files_removed += 1
		var uid_companion := file_name + ".uid"
		if directory.file_exists(uid_companion):
			directory.remove(uid_companion)
	for file_name in directory.get_files():
		if file_name.ends_with(".uid"):
			directory.remove(file_name)
	for sub_name in directory.get_directories():
		var sub_path := folder_path + "/" + sub_name
		var sub_result := _folder_delete_recursive(sub_path)
		files_removed += int(sub_result.get("files", 0))
		dirs_removed += int(sub_result.get("dirs", 0))
		if not bool(sub_result.get("ok", false)):
			return {"files": files_removed, "dirs": dirs_removed, "ok": false,
				"error": str(sub_result.get("error", "unknown"))}
		var remove_sub_error := directory.remove(sub_name)
		if remove_sub_error != OK:
			return {"files": files_removed, "dirs": dirs_removed, "ok": false,
				"error": "DirAccess.remove (subdir) %s returned %d" % [sub_path, remove_sub_error]}
		dirs_removed += 1
	return {"files": files_removed, "dirs": dirs_removed, "ok": true, "error": ""}
