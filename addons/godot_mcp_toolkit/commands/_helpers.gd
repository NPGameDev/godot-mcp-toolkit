@tool
extends RefCounted
## Shared helpers used across multiple command handlers.
## Eliminates duplication of scene-node resolution, class hierarchy
## checks, file deletion, directory creation, log-level detection,
## and profile string conversion.

## NOTE: This file is preloaded by _hub.gd, so it CANNOT import _hub.gd
## (circular dependency). Use direct preloads for dependencies instead.
const MCPError := preload("res://addons/godot_mcp_toolkit/mcp_error.gd")


# -- Scene node resolution -----------------------------------------------------


static func get_edited_root() -> Node:
	return EditorInterface.get_edited_scene_root()


static func resolve_scene_node(node_path: String) -> Variant:
	var root := get_edited_root()
	if root == null:
		return null
	if node_path.is_empty() or node_path == ".":
		return root
	return root.get_node_or_null(node_path)


# -- Class hierarchy checks ----------------------------------------------------


static func class_descends_from(type_name: String, base: String) -> bool:
	if ClassDB.class_exists(type_name):
		return ClassDB.is_parent_class(type_name, base)
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == type_name:
			return class_descends_from(str(entry.get("base", "")), base)
	return false


static func class_base_chain(type_name: String) -> String:
	var chain := PackedStringArray()
	var current := type_name
	var depth := 0
	while not current.is_empty() and depth < 16:
		chain.append(current)
		if ClassDB.class_exists(current):
			var parent := ClassDB.get_parent_class(current)
			if parent.is_empty():
				break
			current = parent
		else:
			var found := false
			for entry in ProjectSettings.get_global_class_list():
				if str(entry.get("class", "")) == current:
					current = str(entry.get("base", ""))
					found = true
					break
			if not found:
				break
		depth += 1
	return " -> ".join(chain)


# -- File operations -----------------------------------------------------------


## Delete a res:// file and its companion files (.uid, .import).
## Returns {success: true, path: String} or an MCPError dict.
static func delete_res_file(file_path: String, companions: Array = [".uid"]) -> Dictionary:
	var directory := DirAccess.open("res://")
	if directory == null:
		return MCPError.make("INTERNAL", "DirAccess.open(res://) returned null")
	var relative_path := file_path.substr("res://".length())
	var remove_error := directory.remove(relative_path)
	if remove_error != OK:
		return MCPError.make("DELETE_FAILED",
			"DirAccess.remove returned %d (path=%s)" % [remove_error, file_path])
	for suffix in companions:
		var companion_relative: String = relative_path + str(suffix)
		if directory.file_exists(companion_relative):
			directory.remove(companion_relative)
	return {"success": true, "path": file_path}


## Ensure parent directory exists, auto-creating if needed.
## Returns {ok: true, dirs_created: bool} or an MCPError dict on failure.
static func ensure_parent_dir(file_path: String, context: String = "") -> Dictionary:
	var parent_dir := file_path.get_base_dir()
	if DirAccess.dir_exists_absolute(parent_dir):
		return {"ok": true, "dirs_created": false}
	var mkdir_err := DirAccess.make_dir_recursive_absolute(parent_dir)
	if mkdir_err != OK:
		return MCPError.make("PARENT_NOT_FOUND",
			"parent directory %s does not exist and auto-create failed (err %d); call folder.create manually" % [parent_dir, mkdir_err])
	if not context.is_empty():
		push_warning("[MCPTools] auto-created directory %s for %s" % [parent_dir, context])
	return {"ok": true, "dirs_created": true}


# -- Log level detection -------------------------------------------------------


static func detect_log_level(line: String) -> String:
	if line.begins_with("ERROR:") or line.begins_with("USER ERROR:") \
			or line.begins_with("SCRIPT ERROR:"):
		return "error"
	if line.begins_with("WARNING:") or line.begins_with("USER WARNING:") \
			or line.begins_with("SCRIPT WARNING:"):
		return "warning"
	return "info"


# -- Profile conversion --------------------------------------------------------


static func profile_to_string(profile: int) -> String:
	match profile:
		0: return "minimal"
		1: return "standard"
		2: return "power_user"
		_: return "standard"


static func string_to_profile(s: String) -> int:
	match s.to_lower():
		"minimal": return 0
		"standard": return 1
		"power_user", "full": return 2
		_: return 1
