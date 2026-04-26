@tool
extends RefCounted
## scene.* command handlers — tree read, scene create/open/close/delete,
## node creation, instantiation.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPCoerce = _Hub.MCPCoerce
const MCPCommandRegistry = _Hub.MCPCommandRegistry
const MCPFileGuard = _Hub.MCPFileGuard
const MCPUntrusted = _Hub.MCPUntrusted


static func register(registry: MCPCommandRegistry, server: Node) -> void:
	registry.add("scene.get_tree", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_get_tree(parameters))
	registry.add("scene.create", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_create(parameters))
	registry.add("scene.open", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_open(parameters))
	registry.add("scene.close", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_close(parameters))
	registry.add("scene.delete", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_delete(parameters))
	registry.add("scene.create_node", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_create_node(parameters))
	registry.add("scene.delete_node", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_delete_node(parameters))
	registry.add("scene.instantiate", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_instantiate(server, parameters))
	registry.add("scene.diff", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_diff(server, parameters))


# -- Helpers ------------------------------------------------------------------


static func _get_edited_root() -> Node:
	return EditorInterface.get_edited_scene_root()


static func _path_in_scene(scene_root: Node, node: Node) -> String:
	return str(scene_root.get_path_to(node))


static func _walk_tree(
	node: Node, scene_root: Node, depth: int, include_properties: bool,
) -> Dictionary:
	var result := {
		"name": String(node.name),
		"class": node.get_class(),
		"path": _path_in_scene(scene_root, node),
	}
	if include_properties:
		var props := {}
		for property in node.get_property_list():
			var usage: int = int(property.get("usage", 0))
			if not (usage & PROPERTY_USAGE_EDITOR):
				continue
			var property_name := str(property.get("name", ""))
			if property_name.is_empty() or property_name.begins_with("_"):
				continue
			props[property_name] = MCPCoerce.serialize_value(node.get(property_name))
		result["properties"] = props
	if depth != 0:
		var children: Array = []
		for child in node.get_children():
			children.append(_walk_tree(
				child, scene_root,
				depth - 1 if depth > 0 else -1,
				include_properties))
		result["children"] = children
	else:
		result["children"] = []
	return result


static func _class_descends_from(type_name: String, base: String) -> bool:
	if ClassDB.class_exists(type_name):
		return ClassDB.is_parent_class(type_name, base)
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == type_name:
			return _class_descends_from(str(entry.get("base", "")), base)
	return false


static func _class_base_chain(type_name: String) -> String:
	var chain := PackedStringArray()
	var current := type_name
	var depth := 0
	while not current.is_empty() and depth < 16:
		chain.append(current)
		if ClassDB.class_exists(current):
			var base := ClassDB.get_parent_class(current)
			if base.is_empty():
				break
			current = base
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


# -- Commands -----------------------------------------------------------------


static func _cmd_scene_get_tree(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return MCPError.make("NO_SCENE", "no edited scene")
	var depth_raw = parameters.get("depth", 2)
	var depth: int = int(depth_raw) \
		if (typeof(depth_raw) == TYPE_INT or typeof(depth_raw) == TYPE_FLOAT) else 2
	var include_properties: bool = bool(parameters.get("include_properties", false))
	var tree := _walk_tree(root, root, depth, include_properties)
	return {"tree": MCPUntrusted.wrap(
		"scene_tree", str(root.scene_file_path), JSON.stringify(tree))}


static func _cmd_scene_create(parameters: Dictionary) -> Dictionary:
	var err = MCPError.check_required(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var root_type := str(parameters.get("root_type", "Node"))
	var if_exists := str(parameters.get("if_exists", "return"))
	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	if file_path.get_extension().to_lower() != "tscn":
		return MCPError.make("INVALID_PATH",
			"path must end with .tscn (got %s; use script.write for .gd files)" % file_path)
	var parent_dir := file_path.get_base_dir()
	var dirs_created := false
	if not DirAccess.dir_exists_absolute(parent_dir):
		var mkdir_err := DirAccess.make_dir_recursive_absolute(parent_dir)
		if mkdir_err != OK:
			return MCPError.make("PARENT_NOT_FOUND",
				"parent directory %s does not exist and auto-create failed (err %d); call folder.create manually" % [parent_dir, mkdir_err])
		push_warning("[MCPTools] auto-created directory %s for scene.create" % parent_dir)
		dirs_created = true

	var resolved_kind := ""
	var global_entry: Dictionary = {}
	if ClassDB.class_exists(root_type):
		resolved_kind = "native"
	else:
		for entry in ProjectSettings.get_global_class_list():
			if str(entry.get("class", "")) == root_type:
				resolved_kind = "global"
				global_entry = entry
				break
	if resolved_kind.is_empty():
		return MCPError.make("INVALID_CLASS",
			"unknown class %s; checked ClassDB (engine classes) and ProjectSettings.get_global_class_list() (GDScript class_name + C# [GlobalClass])" % root_type, MCPError.HINT_CLASS_NAME)
	if not _class_descends_from(root_type, "Node"):
		return MCPError.make("INVALID_CLASS",
			"%s is not a Node subclass (resolved base chain: %s); scene roots must descend from Node" % [root_type, _class_base_chain(root_type)])
	if not (if_exists in ["return", "fail", "replace"]):
		return MCPError.make("INVALID_PARAMS",
			"if_exists must be one of 'return'|'fail'|'replace' (got %s); default is 'return'" % if_exists)

	var was_replace := false
	var previous_root_type := ""
	if FileAccess.file_exists(file_path):
		match if_exists:
			"return":
				return {"success": true, "status": "returned", "path": file_path,
					"root_name": file_path.get_file().get_basename(), "root_path": "."}
			"fail":
				return MCPError.make("ALREADY_EXISTS",
					"file exists at %s; set if_exists:'replace' to overwrite" % file_path)
			"replace":
				was_replace = true
				var previous_packed = ResourceLoader.load(file_path)
				if previous_packed == null or not (previous_packed is PackedScene):
					previous_root_type = "<unreadable>"
				else:
					var state := (previous_packed as PackedScene).get_state()
					if state == null or state.get_node_count() == 0:
						previous_root_type = "<empty>"
					else:
						previous_root_type = str(state.get_node_type(0))
				push_warning("[MCPTools] scene.create replacing %s (was root=%s, now root=%s)" % [
					file_path, previous_root_type, root_type])

	var root: Node = null
	if resolved_kind == "native":
		root = ClassDB.instantiate(root_type)
	else:
		var script_path := str(global_entry.get("path", ""))
		var script = load(script_path)
		if script == null:
			return MCPError.make("INVALID_CLASS",
				"could not load script for %s at %s" % [root_type, script_path])
		root = script.new()
	if root == null:
		return MCPError.make("INVALID_CLASS",
			"instantiation returned null for %s" % root_type)
	root.name = file_path.get_file().get_basename()
	var packed := PackedScene.new()
	var pack_error := packed.pack(root)
	if pack_error != OK:
		root.queue_free()
		return MCPError.make("PACK_FAILED",
			"PackedScene.pack returned %d (class=%s, path=%s)" % [pack_error, root_type, file_path])
	var save_error := ResourceSaver.save(packed, file_path)
	root.queue_free()
	if save_error != OK:
		return MCPError.make("SAVE_FAILED",
			"ResourceSaver.save returned %d (path=%s)" % [save_error, file_path])

	var response := {"success": true, "path": file_path, "root_type": root_type,
		"root_name": file_path.get_file().get_basename(), "root_path": "."}
	if dirs_created:
		response["dirs_created"] = true
	if was_replace:
		response["status"] = "replaced"
		response["previous_root_type"] = previous_root_type
	else:
		response["status"] = "created"
	return response


static func _cmd_scene_open(parameters: Dictionary) -> Dictionary:
	var err = MCPError.check_required(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	if not FileAccess.file_exists(file_path):
		return MCPError.make("NOT_FOUND", "scene not found: %s" % file_path, MCPError.HINT_FILE_PATH)
	EditorInterface.open_scene_from_path(file_path)
	return {"ok": true, "path": file_path}


static func _cmd_scene_close(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("file_path", ""))
	if file_path.is_empty():
		return MCPError.make("INVALID_PARAMS", "path is required")
	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	var open_scenes := EditorInterface.get_open_scenes()
	if not open_scenes.has(file_path):
		return MCPError.make("NOT_FOUND",
			"scene is not open in any editor tab: %s" % file_path, MCPError.HINT_FILE_PATH)
	if open_scenes.size() <= 1:
		return MCPError.make("EDITED_SCENE",
			"cannot close the last open scene tab; open another scene via scene.open first")
	var current_root := _get_edited_root()
	var current_path := current_root.scene_file_path if current_root else ""
	if not EditorInterface.has_method("close_scene"):
		return MCPError.make("UNSUPPORTED",
			"scene.close requires Godot 4.5+ (connected: 4.%d)" % _Hub.godot_minor())
	if current_path != file_path:
		EditorInterface.open_scene_from_path(file_path)
	EditorInterface.call("close_scene")
	return {"success": true, "path": file_path}


static func _cmd_scene_delete(parameters: Dictionary) -> Dictionary:
	var err = MCPError.check_required(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	if file_path.get_extension().to_lower() != "tscn":
		return MCPError.make("INVALID_PATH",
			"scene.delete only removes .tscn files (got %s); use a different tool for other file types" % file_path)
	if not FileAccess.file_exists(file_path):
		return MCPError.make("NOT_FOUND", "no file at %s" % file_path, MCPError.HINT_FILE_PATH)
	var edited_root := _get_edited_root()
	if edited_root != null and edited_root.scene_file_path == file_path:
		return MCPError.make("EDITED_SCENE",
			"cannot delete the currently-edited scene %s; close it via scene.close first, or open a different scene via scene.open" % file_path)
	var directory := DirAccess.open("res://")
	if directory == null:
		return MCPError.make("INTERNAL", "DirAccess.open(res://) returned null")
	var relative_path := file_path.substr("res://".length())
	var remove_error := directory.remove(relative_path)
	if remove_error != OK:
		return MCPError.make("DELETE_FAILED",
			"DirAccess.remove returned %d (path=%s)" % [remove_error, file_path])
	var uid_relative := relative_path + ".uid"
	if directory.file_exists(uid_relative):
		directory.remove(uid_relative)
	return {"success": true, "path": file_path}


static func _cmd_scene_create_node(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return MCPError.make("NO_SCENE", "no edited scene")

	var class_name_param := str(parameters.get("class_name", ""))
	var parent_path := str(parameters.get("parent_path", ""))
	var requested_name := str(parameters.get("node_name", class_name_param))

	if class_name_param.is_empty():
		return MCPError.make("INVALID_PARAMS", "missing class_name")

	var resolved_kind := ""
	var global_entry: Dictionary = {}
	if ClassDB.class_exists(class_name_param):
		resolved_kind = "native"
		if not ClassDB.can_instantiate(class_name_param):
			return MCPError.make("INVALID_CLASS",
				"class is not instantiable (abstract, virtual, or editor-only): %s" % class_name_param)
	else:
		for entry in ProjectSettings.get_global_class_list():
			if str(entry.get("class", "")) == class_name_param:
				resolved_kind = "global"
				global_entry = entry
				break
	if resolved_kind.is_empty():
		return MCPError.make("INVALID_CLASS",
			"unknown class %s; checked ClassDB (engine classes) and ProjectSettings.get_global_class_list() (GDScript class_name + C# [GlobalClass])" % class_name_param, MCPError.HINT_CLASS_NAME)
	if not _class_descends_from(class_name_param, "Node"):
		return MCPError.make("INVALID_CLASS",
			"%s is not a Node subclass (resolved base chain: %s); scene roots must descend from Node" % [
				class_name_param, _class_base_chain(class_name_param)])

	var parent_node := root.get_node_or_null(parent_path) if not parent_path.is_empty() else root
	if parent_node == null:
		return MCPError.make("NOT_FOUND", "parent not found: %s" % parent_path, MCPError.HINT_NODE_PATH)

	var existing := parent_node.get_node_or_null(NodePath(requested_name))
	if existing != null:
		return {"success": true, "status": "returned", "path": _path_in_scene(root, existing)}

	var instance: Node = null
	if resolved_kind == "native":
		instance = ClassDB.instantiate(class_name_param)
	else:
		var script_path := str(global_entry.get("path", ""))
		var script = load(script_path)
		if script == null:
			return MCPError.make("INVALID_CLASS",
				"could not load script for %s at %s" % [class_name_param, script_path])
		instance = script.new()
	if instance == null or not (instance is Node):
		return MCPError.make("INVALID_CLASS", "instantiate failed: %s" % class_name_param)

	instance.name = requested_name
	parent_node.add_child(instance)
	instance.set_owner(root)
	return {"success": true, "status": "created", "path": _path_in_scene(root, instance)}


static func _cmd_scene_delete_node(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return MCPError.make("NO_SCENE", "no edited scene")

	var node_path := str(parameters.get("node_path", ""))
	if node_path.is_empty():
		return MCPError.make("INVALID_PARAMS", "missing node_path")

	var node := root.get_node_or_null(node_path)
	if node == null:
		return MCPError.make("NOT_FOUND", "node not found: %s" % node_path, MCPError.HINT_NODE_PATH)
	if node == root:
		return MCPError.make("INVALID_PATH", "cannot delete edited scene root")

	var parent := node.get_parent()
	if parent == null:
		return MCPError.make("INTERNAL", "node has no parent: %s" % node_path)
	var undo_redo = _Hub.get_undo_redo()
	if undo_redo != null:
		undo_redo.create_action("MCP: delete %s" % node_path)
		undo_redo.add_do_method(parent, "remove_child", node)
		undo_redo.add_undo_method(parent, "add_child", node)
		undo_redo.add_undo_method(node, "set_owner", root)
		undo_redo.add_undo_reference(node)
		undo_redo.commit_action()
	else:
		parent.remove_child(node)
		node.queue_free()
	return {"ok": true, "path": node_path}


static func _cmd_scene_instantiate(server: Node, parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return MCPError.make("NO_SCENE", "no open scene; use scene.open or scene.create first")

	var parent_path := str(parameters.get("parent_path", ""))
	var packed_path := str(parameters.get("packed_path", ""))
	var as_name := str(parameters.get("as_name", ""))
	var transform_raw = parameters.get("transform", {})
	var transform: Dictionary = transform_raw if typeof(transform_raw) == TYPE_DICTIONARY else {}

	if parent_path.is_empty() or packed_path.is_empty():
		return MCPError.make("INVALID_PARAMS", "missing parent_path or packed_path")

	var parent_node := root.get_node_or_null(parent_path)
	if parent_node == null:
		return MCPError.make("NOT_FOUND",
			"no node at parent_path %s (must be under the currently-edited scene root)" % parent_path, MCPError.HINT_NODE_PATH)

	var guard := MCPFileGuard.resolve_safe(packed_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	if packed_path.get_extension().to_lower() != "tscn":
		return MCPError.make("INVALID_PATH",
			"scene.instantiate only instantiates .tscn files (got %s); use resource.write for .tres, script.write for .gd/.cs" % packed_path)
	if not FileAccess.file_exists(packed_path):
		return MCPError.make("NOT_FOUND",
			"no scene file at %s; use scene.create first" % packed_path, MCPError.HINT_FILE_PATH)
	var packed := ResourceLoader.load(packed_path)
	if packed == null:
		return MCPError.make("LOAD_FAILED",
			"ResourceLoader.load returned null for %s (corrupt file or dependency error — check editor_get_errors)" % packed_path)
	if not (packed is PackedScene):
		return MCPError.make("INVALID_CLASS",
			"file at %s is not a PackedScene (got %s); scene.instantiate only works on .tscn files" % [
				packed_path, packed.get_class()])

	var target_name := as_name if as_name != "" else (packed as PackedScene).get_state().get_node_name(0)
	if parent_node.has_node(NodePath(target_name)):
		var existing_node := parent_node.get_node(NodePath(target_name))
		return {
			"success": true,
			"status": "returned",
			"path": _path_in_scene(root, existing_node),
			"class_name": existing_node.get_class(),
		}

	var instance: Node = (packed as PackedScene).instantiate()
	if instance == null:
		return MCPError.make("LOAD_FAILED",
			"PackedScene.instantiate returned null for %s" % packed_path)

	if as_name != "":
		instance.name = as_name

	if not transform.is_empty():
		for key in transform.keys():
			instance.set(str(key), MCPCoerce.coerce_value(transform[key]))

	var undo_redo = _Hub.get_undo_redo()
	if undo_redo != null:
		undo_redo.create_action("MCP: instantiate %s under %s" % [packed_path, parent_path])
		undo_redo.add_do_method(parent_node, "add_child", instance)
		undo_redo.add_do_method(server.undo_helpers, "_set_owner_recursive", instance, root)
		undo_redo.add_do_reference(instance)
		undo_redo.add_undo_method(parent_node, "remove_child", instance)
		undo_redo.commit_action()
	else:
		parent_node.add_child(instance)
		server.undo_helpers._set_owner_recursive(instance, root)

	return {
		"success": true,
		"status": "created",
		"path": _path_in_scene(root, instance),
		"class_name": instance.get_class(),
	}


static func _cmd_scene_diff(server: Node, parameters: Dictionary) -> Dictionary:
	if not parameters.has("before"):
		return MCPError.make("INVALID_PARAMS", "missing before")
	var before = parameters.get("before")
	var after = parameters.get("after", null)
	if after == null:
		var root := _get_edited_root()
		if root == null:
			return MCPError.make("NO_SCENE", "no edited scene")
		after = _walk_tree(root, root, -1, false)
	var before_string := JSON.stringify(before, "  ", true)
	var after_string := JSON.stringify(after, "  ", true)
	if before_string == after_string:
		return {"changed": false, "diff": "", "added": 0, "removed": 0}
	var before_lines := before_string.split("\n", false)
	var after_lines := after_string.split("\n", false)
	var before_set := {}
	for line in before_lines:
		before_set[line] = true
	var after_set := {}
	for line in after_lines:
		after_set[line] = true
	var diff_parts := PackedStringArray()
	var removed := 0
	for line in before_lines:
		if not after_set.has(line):
			diff_parts.append("- " + line)
			removed += 1
	var added := 0
	for line in after_lines:
		if not before_set.has(line):
			diff_parts.append("+ " + line)
			added += 1
	return {
		"changed": true,
		"diff": "\n".join(diff_parts),
		"added": added,
		"removed": removed,
	}
