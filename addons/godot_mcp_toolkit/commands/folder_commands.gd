@tool
extends RefCounted
## folder.* command handlers — create and delete directories under res://.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const FileGuard = Modules.FileGuard
const Helpers = Modules.CommandHelpers


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("folder.create", func(parameters: Dictionary) -> Dictionary:
		return _cmd_folder_create(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("folder.delete", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_folder_delete(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())


# -- Commands -----------------------------------------------------------------


static func _cmd_folder_create(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["path"])
	if err != null:
		return err
	var path := str(parameters.get("path", ""))
	var guard := FileGuard.resolve_safe(path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	var pre_existed := DirAccess.dir_exists_absolute(path)
	var error := DirAccess.make_dir_recursive_absolute(path)
	if error != OK:
		return MCPToolkitError.fail("CREATE_DIR_FAILED",
			"DirAccess.make_dir_recursive_absolute returned %d (path=%s)" % [error, path])
	var status := "returned" if pre_existed else "created"
	return MCPToolkitSuccess.ok({"status": status, "path": path})


static func _cmd_folder_delete(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["path"])
	if err != null:
		return err
	var path := str(parameters.get("path", ""))
	var recursive := bool(parameters.get("recursive", false))
	var guard := FileGuard.resolve_safe(path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))

	if path == "res://" or path == "res:///" or path.get_base_dir() == "":
		return MCPToolkitError.fail("FOLDER_PROTECTED",
			"cannot delete the project root res://; narrow the path")

	var normalized := path
	if normalized.ends_with("/"):
		normalized = normalized.substr(0, normalized.length() - 1)
	if normalized == "res://addons" or normalized == "res://addons/godot_mcp_toolkit":
		return MCPToolkitError.fail("FOLDER_PROTECTED",
			"cannot delete res://addons or the toolkit plugin directory (%s); agent cannot remove its own host" % normalized)
	if not DirAccess.dir_exists_absolute(path):
		return MCPToolkitError.fail("NOT_FOUND", "no folder at %s" % path)
	var normalized_with_slash := normalized + "/"

	# Collect open scene tabs inside vs outside the target folder.
	var open_scenes := EditorInterface.get_open_scenes()
	var inside_scenes: Array[String] = []
	var outside_scenes: Array[String] = []
	for scene_path in open_scenes:
		var sp := str(scene_path)
		if sp == normalized or sp.begins_with(normalized_with_slash):
			inside_scenes.append(sp)
		else:
			outside_scenes.append(sp)

	var edited := Helpers.get_edited_root()
	var active_path := ""
	if edited != null:
		active_path = str(edited.scene_file_path)
	var active_inside := not active_path.is_empty() and (active_path == normalized or active_path.begins_with(normalized_with_slash))

	# Scene tab handling strategy:
	# - Exactly 1 scene inside + on 4.5+: close it via helper (single
	#   open+close cycle is safe; avoids phantom tab entirely).
	# - Multiple scenes inside: cannot close in a loop (deferred-queue
	#   crash). Switch active away, return stale_tabs for agent follow-up
	#   via scene.close (MCP round-trip provides sequencing).
	# - On 4.2–4.4: no close API — always switch-away + stale_tabs.
	var stale_tabs: Array[String] = []
	var warnings: Array[String] = []
	var single_closed := false
	# close_scene is 4.5+; on 4.2–4.4 there is no API to close scene tabs, so the
	# stale-tab follow-up hint must not steer to the (absent) scene_close tool.
	var can_close := EditorInterface.has_method("close_scene")

	if inside_scenes.size() == 1 and can_close:
		# Single scene — safe to close via helper (handles active or not).
		var tab_result := await Helpers.close_scene_tab_safe(inside_scenes[0])
		single_closed = tab_result.get("closed", false)
		if not single_closed:
			# no_api shouldn't happen (we checked has_method), but be safe.
			stale_tabs = inside_scenes
	elif inside_scenes.size() > 0:
		# Multiple scenes (or 4.2–4.4): switch active away, list phantoms.
		if active_inside:
			if outside_scenes.is_empty():
				return MCPToolkitError.fail("PATH_IN_USE",
					"all open scene tabs are inside %s; open a scene outside the folder first via scene_open, then retry folder_delete" % path)
			if not await Helpers.open_scene_deferred(outside_scenes[0]):
				return MCPToolkitError.fail("TIMEOUT",
					"could not switch active scene away from %s — filesystem scanning; retry shortly" % path)
		stale_tabs = inside_scenes
		if not can_close:
			warnings.append(
				"phantom tabs: Godot 4.2-4.4 has no API to close scene tabs — %d tab(s) inside %s will remain as phantoms until editor restart" % [inside_scenes.size(), path])

	var script_editor := EditorInterface.get_script_editor()
	if script_editor != null:
		for open_script in script_editor.get_open_scripts():
			if not (open_script is Resource):
				continue
			var resource_path := str((open_script as Resource).resource_path)
			if resource_path.is_empty():
				continue
			if resource_path == normalized or resource_path.begins_with(normalized_with_slash):
				return MCPToolkitError.fail("PATH_IN_USE",
					"folder %s contains open script %s; close the script editor tab manually (no programmatic close API for script tabs), then retry folder_delete" % [
						path, resource_path])

	var directory := DirAccess.open(path)
	if directory == null:
		return MCPToolkitError.fail("INTERNAL",
			"DirAccess.open(%s) returned null" % path)
	var file_count := directory.get_files().size()
	var subdir_count := directory.get_directories().size()
	if (file_count + subdir_count) > 0 and not recursive:
		return MCPToolkitError.fail("DIR_NOT_EMPTY",
			"folder %s is not empty (contains %d files, %d subdirs); pass recursive:true to delete contents" % [
				path, file_count, subdir_count])

	var files_deleted := 0
	var dirs_deleted := 0
	if recursive and (file_count + subdir_count) > 0:
		var result := _folder_delete_recursive(path)
		files_deleted = int(result.get("files", 0))
		dirs_deleted = int(result.get("dirs", 0))
		if not bool(result.get("success", false)):
			return MCPToolkitError.fail("DELETE_FAILED", str(result.get("error", "unknown")))

	var parent_path := path.get_base_dir()
	var parent_dir := DirAccess.open(parent_path)
	if parent_dir == null:
		return MCPToolkitError.fail("INTERNAL",
			"DirAccess.open(%s) returned null" % parent_path)
	var top_remove := parent_dir.remove(path.get_file())
	if top_remove != OK:
		return MCPToolkitError.fail("DELETE_FAILED",
			"DirAccess.remove returned %d (path=%s)" % [top_remove, path])
	if recursive and (file_count + subdir_count) > 0:
		push_warning("[MCPTools] folder.delete recursive %s (%d files, %d subdirs)" % [
			path, files_deleted, dirs_deleted])
	# The target folder itself was just removed above — count it alongside any
	# nested subdirectories the recursive pass deleted. Previously omitted, so a
	# flat folder reported directories_deleted:0 despite the folder being gone.
	dirs_deleted += 1
	# Targeted deindex: update_file() on a directory path is a no-op in most
	# Godot versions, so fall back to scan() for folder removal. Folder deletes
	# are rare and the scan cost is acceptable.
	var removal := await Helpers.ensure_file_removed(path)
	var result := {
		"path": path,
		"recursive": recursive,
		"files_deleted": files_deleted,
		"directories_deleted": dirs_deleted,
		"deindexed": removal["removed"],
	}
	if single_closed:
		result["tab_closed"] = inside_scenes[0]
	if not stale_tabs.is_empty():
		result["stale_tabs"] = stale_tabs
		if can_close:
			result["hint"] = "Phantom scene tabs remain for %d file(s) inside the deleted folder. Close them one at a time via scene_close. Note: each scene_close may produce a _set_main_scene_state error in the editor console — this is benign Godot engine noise, safe to ignore." % stale_tabs.size()
		else:
			result["hint"] = "Phantom scene tabs remain for %d file(s) inside the deleted folder. Godot 4.2–4.4 has no API to close scene tabs — restart the editor to clear them." % stale_tabs.size()
	if active_inside and not single_closed:
		result["switched_to"] = outside_scenes[0]
	if not warnings.is_empty():
		result["warnings"] = warnings
	return MCPToolkitSuccess.ok(result)


# -- Recursive delete helper --------------------------------------------------


static func _folder_delete_recursive(path: String) -> Dictionary:
	var directory := DirAccess.open(path)
	if directory == null:
		return {"files": 0, "dirs": 0, "success": false,
			"error": "DirAccess.open(%s) returned null" % path}
	var files_removed := 0
	var dirs_removed := 0
	for file_name in directory.get_files():
		if file_name.ends_with(".uid"):
			continue
		var full_res_path := path + "/" + file_name
		var uid: int = ResourceLoader.get_resource_uid(full_res_path)
		var remove_error := directory.remove(file_name)
		if remove_error != OK:
			return {"files": files_removed, "dirs": dirs_removed, "success": false,
				"error": "DirAccess.remove %s/%s returned %d" % [path, file_name, remove_error]}
		files_removed += 1
		var uid_companion := file_name + ".uid"
		if directory.file_exists(uid_companion):
			directory.remove(uid_companion)
		if uid != -1 and ResourceUID.has_id(uid):
			ResourceUID.remove_id(uid)
	for file_name in directory.get_files():
		if file_name.ends_with(".uid"):
			directory.remove(file_name)
	for sub_name in directory.get_directories():
		var sub_path := path + "/" + sub_name
		var sub_result := _folder_delete_recursive(sub_path)
		files_removed += int(sub_result.get("files", 0))
		dirs_removed += int(sub_result.get("dirs", 0))
		if not bool(sub_result.get("success", false)):
			return {"files": files_removed, "dirs": dirs_removed, "success": false,
				"error": str(sub_result.get("error", "unknown"))}
		var remove_sub_error := directory.remove(sub_name)
		if remove_sub_error != OK:
			return {"files": files_removed, "dirs": dirs_removed, "success": false,
				"error": "DirAccess.remove (subdir) %s returned %d" % [sub_path, remove_sub_error]}
		dirs_removed += 1
	return {"files": files_removed, "dirs": dirs_removed, "success": true, "error": ""}
