@tool
extends RefCounted
## scene.* command handlers — tree read, scene create/open/close/delete,
## node creation, instantiation.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const McpError = _Hub.McpError
const Coerce = _Hub.Coerce
const FileGuard = _Hub.FileGuard
const Untrusted = _Hub.Untrusted
const Helpers = _Hub.Helpers

const _TAB_CLOSE_NOISE_HINT := "Closing a non-active scene tab may produce a _set_main_scene_state error in the editor console. This is benign Godot engine noise — safe to ignore."


static func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:
	registry.add("scene.get_tree", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_get_tree(parameters)
	, {"is_read_only": true})
	registry.add("scene.create", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_scene_create(parameters)
	, {"is_active_scene_required": false})
	registry.add("scene.open", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_scene_open(parameters)
	, {"is_active_scene_required": false})
	registry.add("scene.close", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_scene_close(parameters)
	, {"is_active_scene_required": false})
	registry.add("scene.delete", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_scene_delete(parameters)
	, {"is_active_scene_required": false})
	registry.add("scene.create_node", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_create_node(parameters))
	registry.add("scene.delete_node", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_delete_node(parameters))
	registry.add("scene.instantiate", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_instantiate(server, parameters))
	registry.add("scene.diff", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_diff(server, parameters)
	, {"is_read_only": true})
	registry.add("scene.create_inherited", func(parameters: Dictionary) -> Dictionary:
		return _cmd_create_inherited(parameters)
	, {"is_active_scene_required": false})
	registry.add("scene.query", func(p: Dictionary) -> Dictionary:
		return _cmd_scene_query(p)
	, {"is_read_only": true})


# -- Helpers ------------------------------------------------------------------


static func _get_edited_root() -> Node:
	return Helpers.get_edited_root()


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
			props[property_name] = Coerce.serialize_value(node.get(property_name))
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
	return Helpers.class_descends_from(type_name, base)


static func _class_base_chain(type_name: String) -> String:
	return Helpers.class_base_chain(type_name)


# -- Commands -----------------------------------------------------------------


static func _cmd_scene_get_tree(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return McpError.make("NO_SCENE", "no edited scene")
	var depth_raw = parameters.get("depth", 2)
	var depth: int = int(depth_raw) \
		if (typeof(depth_raw) == TYPE_INT or typeof(depth_raw) == TYPE_FLOAT) else 2
	var include_properties: bool = bool(parameters.get("include_properties", false))
	var tree := _walk_tree(root, root, depth, include_properties)
	return {"tree": Untrusted.wrap(
		"scene_tree", str(root.scene_file_path), JSON.stringify(tree))}


static func _cmd_scene_create(parameters: Dictionary) -> Dictionary:
	var err = McpError.check_required(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var root_type := str(parameters.get("root_type", "Node"))
	var if_exists := str(parameters.get("if_exists", "return"))
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return McpError.make("PATH_DENIED", str(guard["reason"]))
	if file_path.get_extension().to_lower() != "tscn":
		return McpError.make("INVALID_PATH",
			"path must end with .tscn (got %s; use script.write for .gd/.cs files)" % file_path)
	var dir_result := Helpers.ensure_parent_dir(file_path, "scene.create")
	if dir_result.has("error"):
		return dir_result
	var dirs_created: bool = dir_result["dirs_created"]

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
		return McpError.make("INVALID_CLASS",
			"unknown class %s; checked ClassDB (engine classes) and ProjectSettings.get_global_class_list() (GDScript class_name + C# [GlobalClass])" % root_type, McpError.HINT_CLASS_NAME)
	if not _class_descends_from(root_type, "Node"):
		return McpError.make("INVALID_CLASS",
			"%s is not a Node subclass (resolved base chain: %s); scene roots must descend from Node" % [root_type, _class_base_chain(root_type)])
	if not (if_exists in ["return", "fail", "replace"]):
		return McpError.make("INVALID_PARAMS",
			"if_exists must be one of 'return'|'fail'|'replace' (got %s); default is 'return'" % if_exists)

	var was_replace := false
	var previous_root_type := ""
	if FileAccess.file_exists(file_path):
		match if_exists:
			"return":
				return {"success": true, "status": "returned", "path": file_path,
					"root_name": file_path.get_file().get_basename(), "root_path": "."}
			"fail":
				return McpError.make("ALREADY_EXISTS",
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
			return McpError.make("INVALID_CLASS",
				"could not load script for %s at %s" % [root_type, script_path])
		root = script.new()
	if root == null:
		return McpError.make("INVALID_CLASS",
			"instantiation returned null for %s" % root_type)
	root.name = file_path.get_file().get_basename()
	var packed := PackedScene.new()
	var pack_error := packed.pack(root)
	if pack_error != OK:
		root.queue_free()
		return McpError.make("PACK_FAILED",
			"PackedScene.pack returned %d (class=%s, path=%s)" % [pack_error, root_type, file_path])
	var save_error := ResourceSaver.save(packed, file_path)
	root.queue_free()
	if save_error != OK:
		return McpError.make("SAVE_FAILED",
			"ResourceSaver.save returned %d (path=%s)" % [save_error, file_path])

	var scene_index := Helpers.ensure_file_indexed(file_path)
	var response := {"success": true, "path": file_path, "root_type": root_type,
		"root_name": file_path.get_file().get_basename(), "root_path": ".",
		"indexed": scene_index["indexed"],
		"hint": "Scene saved. Open it for editing with scene_open."}
	if dirs_created:
		response["dirs_created"] = true
	if was_replace:
		response["status"] = "replaced"
		response["previous_root_type"] = previous_root_type
		# P-003: If the replaced scene is currently open in the editor, reload
		# it from disk so the in-memory tree matches the fresh file.
		var open_scenes := EditorInterface.get_open_scenes()
		if file_path in open_scenes:
			await Helpers.open_scene_deferred(file_path)
			response["reloaded"] = true
			response["hint"] = "Scene replaced and reloaded in editor."
	else:
		response["status"] = "created"
	return response


static func _cmd_scene_open(parameters: Dictionary) -> Dictionary:
	var err = McpError.check_required(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return McpError.make("PATH_DENIED", str(guard["reason"]))
	if not FileAccess.file_exists(file_path):
		return McpError.make("NOT_FOUND", "scene not found: %s" % file_path, McpError.HINT_FILE_PATH)
	await Helpers.open_scene_deferred(file_path)
	return {"success": true, "path": file_path}


static func _cmd_scene_close(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("file_path", ""))
	if file_path.is_empty():
		return McpError.make("INVALID_PARAMS", "path is required")
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return McpError.make("PATH_DENIED", str(guard["reason"]))
	var result := await Helpers.close_scene_tab_safe(file_path)
	if result.get("closed", false):
		var response := {"success": true, "path": file_path}
		if result.get("switched", false):
			response["hint"] = _TAB_CLOSE_NOISE_HINT
		return response
	var reason := str(result.get("reason", ""))
	if reason == "not_open":
		return McpError.make("NOT_FOUND",
			"scene is not open in any editor tab: %s" % file_path, McpError.HINT_FILE_PATH)
	if reason == "no_api":
		return McpError.make("UNSUPPORTED",
			"scene.close requires Godot 4.5+ (connected: 4.%d)" % _Hub.godot_minor())
	return McpError.make("INTERNAL", "unexpected close_scene_tab_safe reason: %s" % reason)


static func _cmd_scene_delete(parameters: Dictionary) -> Dictionary:
	var err = McpError.check_required(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return McpError.make("PATH_DENIED", str(guard["reason"]))
	if file_path.get_extension().to_lower() != "tscn":
		return McpError.make("INVALID_PATH",
			"scene.delete only removes .tscn files (got %s); use a different tool for other file types" % file_path)
	if not FileAccess.file_exists(file_path):
		return McpError.make("NOT_FOUND", "no file at %s" % file_path, McpError.HINT_FILE_PATH)

	# Attempt to close the editor tab before deleting the file.
	var tab_result := await Helpers.close_scene_tab_safe(file_path)
	var tab_closed := tab_result.get("closed", false)
	var warnings: Array[String] = []

	if not tab_closed:
		var reason := str(tab_result.get("reason", ""))
		if reason == "no_api":
			# 4.2–4.4: no close API. Block active-scene deletion (Ctrl+S
			# would silently recreate the file). Non-active tabs proceed
			# with a phantom warning.
			var edited_root := _get_edited_root()
			if edited_root != null and edited_root.scene_file_path == file_path:
				return McpError.make("EDITED_SCENE",
					"cannot delete the currently-edited scene %s on Godot 4.2-4.4 (no tab-close API); open a different scene via scene.open first" % file_path)
			warnings.append(
				"phantom tab: scene tab for %s remains open; Godot 4.2-4.4 has no API to close tabs — it will vanish on editor restart or manual close" % file_path)

	var delete_result := Helpers.delete_res_file(file_path)
	if delete_result.get("success", false):
		var removal := Helpers.ensure_file_removed(file_path)
		delete_result["deindexed"] = removal["removed"]
	delete_result["tab_closed"] = tab_closed
	if tab_closed and tab_result.get("switched", false):
		delete_result["hint"] = _TAB_CLOSE_NOISE_HINT
	if not warnings.is_empty():
		delete_result["warnings"] = warnings
	return delete_result


static func _cmd_scene_create_node(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return McpError.make("NO_SCENE", "no edited scene")

	var class_name_param := str(parameters.get("class_name", ""))
	var parent_path := str(parameters.get("parent_path", ""))
	parent_path = Helpers.normalize_editor_path(parent_path)
	var requested_name := str(parameters.get("node_name", class_name_param))

	if class_name_param.is_empty():
		return McpError.make("INVALID_PARAMS", "missing class_name")

	var resolved_kind := ""
	var global_entry: Dictionary = {}
	if ClassDB.class_exists(class_name_param):
		resolved_kind = "native"
		if not ClassDB.can_instantiate(class_name_param):
			return McpError.make("INVALID_CLASS",
				"class is not instantiable (abstract, virtual, or editor-only): %s" % class_name_param)
	else:
		for entry in ProjectSettings.get_global_class_list():
			if str(entry.get("class", "")) == class_name_param:
				resolved_kind = "global"
				global_entry = entry
				break
	if resolved_kind.is_empty():
		return McpError.make("INVALID_CLASS",
			"unknown class %s; checked ClassDB (engine classes) and ProjectSettings.get_global_class_list() (GDScript class_name + C# [GlobalClass])" % class_name_param, McpError.HINT_CLASS_NAME)
	if not _class_descends_from(class_name_param, "Node"):
		return McpError.make("INVALID_CLASS",
			"%s is not a Node subclass (resolved base chain: %s); scene roots must descend from Node" % [
				class_name_param, _class_base_chain(class_name_param)])

	var parent_node := root.get_node_or_null(parent_path) if not parent_path.is_empty() else root
	if parent_node == null:
		var extra := ""
		if parent_path == root.name:
			extra = "; to reference the scene root use parent_path=\".\" (not the root node's name)"
		return McpError.make("NOT_FOUND", "parent not found: %s%s" % [parent_path, extra], McpError.HINT_NODE_PATH)

	var existing := parent_node.get_node_or_null(NodePath(requested_name))
	if existing != null:
		var class_match := false
		var existing_script := existing.get_script() as Script
		if resolved_kind == "native":
			class_match = existing.is_class(class_name_param)
		elif existing_script != null:
			class_match = existing_script.get_global_name() == class_name_param
		if class_match:
			return {"success": true, "status": "returned", "path": _path_in_scene(root, existing)}
		var actual := existing_script.get_global_name() if existing_script != null and existing_script.get_global_name() != "" else existing.get_class()
		return McpError.make("CLASS_MISMATCH",
			"node '%s' already exists under '%s' as %s, not %s; rename or remove it first" % [
				requested_name, _path_in_scene(root, parent_node), actual, class_name_param])

	var instance: Node = null
	if resolved_kind == "native":
		instance = ClassDB.instantiate(class_name_param)
	else:
		var script_path := str(global_entry.get("path", ""))
		var script = load(script_path)
		if script == null:
			return McpError.make("INVALID_CLASS",
				"could not load script for %s at %s" % [class_name_param, script_path])
		instance = script.new()
	if instance == null or not (instance is Node):
		return McpError.make("INVALID_CLASS", "instantiate failed: %s" % class_name_param)

	instance.name = requested_name
	var undo_redo = _Hub.get_undo_redo()
	if undo_redo != null:
		undo_redo.create_action("MCP: create %s" % requested_name)
		undo_redo.add_do_method(parent_node, "add_child", instance)
		undo_redo.add_do_method(instance, "set_owner", root)
		undo_redo.add_do_reference(instance)
		undo_redo.add_undo_method(parent_node, "remove_child", instance)
		undo_redo.commit_action()
	else:
		parent_node.add_child(instance)
		instance.set_owner(root)

	# layout_mode: match Godot editor behavior for Control children of Containers.
	# Default (-1) auto-detects: sets layout_mode=1 when parent is a Container.
	var layout_mode_param: int = int(parameters.get("layout_mode", -1))
	if instance is Control:
		if layout_mode_param >= 0:
			instance.set("layout_mode", layout_mode_param)
		elif parent_node is Container:
			instance.set("layout_mode", 1)

	# unique_name: mark node for scene-unique access (%Name in scripts).
	var unique_param = parameters.get("unique_name", null)
	var response := {"success": true, "status": "created", "path": _path_in_scene(root, instance)}
	if unique_param != null and (unique_param == true or str(unique_param).to_lower() == "true"):
		var existing_unique := root.get_node_or_null("%" + str(instance.name))
		if existing_unique != null and existing_unique != instance:
			response["warning"] = "Node '%s' was previously the unique '%s' — it has lost its unique status. %%Name references to it in scripts will now resolve to this new node instead." % [
				_path_in_scene(root, existing_unique), str(instance.name)]
		instance.unique_name_in_owner = true
		response["unique_name"] = true
	return response


static func _cmd_scene_delete_node(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return McpError.make("NO_SCENE", "no edited scene")

	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)
	if node_path.is_empty():
		return McpError.make("INVALID_PARAMS", "missing node_path")

	var node := root.get_node_or_null(node_path)
	if node == null:
		return McpError.make("NOT_FOUND", "node not found: %s" % node_path, McpError.HINT_NODE_PATH)
	if node == root:
		return McpError.make("INVALID_PATH", "cannot delete edited scene root")

	var parent := node.get_parent()
	if parent == null:
		return McpError.make("INTERNAL", "node has no parent: %s" % node_path)
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
	return {"success": true, "path": node_path}


static func _cmd_scene_instantiate(server: Node, parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return McpError.make("NO_SCENE", "no open scene; use scene.open or scene.create first")

	var parent_path := str(parameters.get("parent_path", ""))
	parent_path = Helpers.normalize_editor_path(parent_path)
	var packed_path := str(parameters.get("scene_path", parameters.get("packed_path", "")))

	if parent_path.is_empty() or packed_path.is_empty():
		return McpError.make("INVALID_PARAMS", "missing parent_path or scene_path")

	var parent_node := root.get_node_or_null(parent_path)
	if parent_node == null:
		return McpError.make("NOT_FOUND",
			"no node at parent_path %s (must be under the currently-edited scene root)" % parent_path, McpError.HINT_NODE_PATH)

	var guard := FileGuard.resolve_safe(packed_path)
	if guard["error"] != null:
		return McpError.make("PATH_DENIED", str(guard["reason"]))
	if packed_path.get_extension().to_lower() != "tscn":
		return McpError.make("INVALID_PATH",
			"scene.instantiate only instantiates .tscn files (got %s); use resource.write for .tres, script.write for .gd/.cs" % packed_path)
	if not FileAccess.file_exists(packed_path):
		return McpError.make("NOT_FOUND",
			"no scene file at %s; use scene.create first" % packed_path, McpError.HINT_FILE_PATH)
	var packed := ResourceLoader.load(packed_path)
	if packed == null:
		return McpError.make("LOAD_FAILED",
			"ResourceLoader.load returned null for %s (corrupt file or dependency error — check editor_get_console)" % packed_path)
	if not (packed is PackedScene):
		return McpError.make("INVALID_CLASS",
			"file at %s is not a PackedScene (got %s); scene.instantiate only works on .tscn files" % [
				packed_path, packed.get_class()])

	# Batch mode: instances array present → instantiate N copies in one UndoRedo action.
	var instances_raw = parameters.get("instances", null)
	if typeof(instances_raw) == TYPE_ARRAY and (instances_raw as Array).size() > 0:
		return _batch_instantiate(server, root, parent_node, packed as PackedScene,
			packed_path, parent_path, instances_raw as Array)

	# Single mode (original behavior).
	var as_name := str(parameters.get("as_name", ""))
	var transform_raw = parameters.get("transform", {})
	var transform: Dictionary = transform_raw if typeof(transform_raw) == TYPE_DICTIONARY else {}

	var target_name := as_name if as_name != "" else (packed as PackedScene).get_state().get_node_name(0)
	if parent_node.has_node(NodePath(target_name)):
		if as_name != "":
			# Explicit name — idempotent return.
			var existing_node := parent_node.get_node(NodePath(target_name))
			return {
				"success": true,
				"status": "returned",
				"path": _path_in_scene(root, existing_node),
				"class_name": existing_node.get_class(),
			}
		# FIX-K: Auto-rename on collision (Player, Player2, Player3...) —
		# matches Godot editor's own drag-drop naming convention.
		var suffix := 2
		while parent_node.has_node(NodePath(target_name + str(suffix))):
			suffix += 1
		target_name = target_name + str(suffix)

	var instance: Node = (packed as PackedScene).instantiate()
	if instance == null:
		return McpError.make("LOAD_FAILED",
			"PackedScene.instantiate returned null for %s" % packed_path)

	instance.name = target_name

	if not transform.is_empty():
		for key in transform.keys():
			instance.set(str(key), Coerce.coerce_value(transform[key]))

	# FIX-9: Only set owner on instance root — child nodes keep their internal
	# ownership from PackedScene. _set_owner_recursive caused full property
	# expansion, breaking Godot's scene inheritance model.
	var undo_redo = _Hub.get_undo_redo()
	if undo_redo != null:
		undo_redo.create_action("MCP: instantiate %s under %s" % [packed_path, parent_path])
		undo_redo.add_do_method(parent_node, "add_child", instance)
		undo_redo.add_do_method(instance, "set_owner", root)
		undo_redo.add_do_reference(instance)
		undo_redo.add_undo_method(parent_node, "remove_child", instance)
		undo_redo.commit_action()
	else:
		parent_node.add_child(instance)
		instance.set_owner(root)

	return {
		"success": true,
		"status": "created",
		"path": _path_in_scene(root, instance),
		"class_name": instance.get_class(),
	}


static func _batch_instantiate(
	server: Node, root: Node, parent_node: Node, packed: PackedScene,
	packed_path: String, parent_path: String, instances: Array,
) -> Dictionary:
	var node_refs: Array = []
	var undo_redo = _Hub.get_undo_redo()
	if undo_redo != null:
		undo_redo.create_action("MCP: batch instantiate %d × %s" % [instances.size(), packed_path])

	for entry in instances:
		var inst_dict: Dictionary = entry if typeof(entry) == TYPE_DICTIONARY else {}
		var instance: Node = packed.instantiate()
		if instance == null:
			continue

		var inst_name := str(inst_dict.get("name", ""))
		if not inst_name.is_empty():
			instance.name = inst_name

		# Apply transform properties (position, rotation, scale).
		for key in ["position", "rotation", "scale"]:
			if inst_dict.has(key):
				instance.set(key, Coerce.coerce_value(inst_dict[key]))

		# Apply arbitrary property overrides (e.g. exports like key_type).
		var props = inst_dict.get("properties", null)
		if typeof(props) == TYPE_DICTIONARY:
			for key in (props as Dictionary).keys():
				instance.set(str(key), Coerce.coerce_value(props[key]))

		# FIX-9: Only set owner on instance root (same as single-instance path).
		if undo_redo != null:
			undo_redo.add_do_method(parent_node, "add_child", instance)
			undo_redo.add_do_method(instance, "set_owner", root)
			undo_redo.add_do_reference(instance)
			undo_redo.add_undo_method(parent_node, "remove_child", instance)
		else:
			parent_node.add_child(instance)
			instance.set_owner(root)

		node_refs.append(instance)

	if undo_redo != null:
		undo_redo.commit_action()

	# Collect paths AFTER commit_action — instances are now in the tree,
	# so get_path_to() can find the common parent.
	var created: Array = []
	for inst in node_refs:
		created.append({
			"path": _path_in_scene(root, inst),
			"class": inst.get_class(),
			"name": String(inst.name),
		})

	return {"success": true, "status": "created", "count": created.size(),
		"instances": created}


static func _cmd_create_inherited(parameters: Dictionary) -> Dictionary:
	var err = McpError.check_required(parameters, ["file_path", "base_scene"])
	if err != null:
		return err

	var file_path := str(parameters.get("file_path", ""))
	var base_scene := str(parameters.get("base_scene", ""))
	var root_name := str(parameters.get("root_name", ""))

	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return McpError.make("PATH_DENIED", str(guard["reason"]))
	if not file_path.ends_with(".tscn"):
		return McpError.make("INVALID_PARAMS", "file_path must end with .tscn")

	var base_guard := FileGuard.resolve_safe(base_scene)
	if base_guard["error"] != null:
		return McpError.make("PATH_DENIED", str(base_guard["reason"]))
	if not ResourceLoader.exists(base_scene):
		return McpError.make("NOT_FOUND", "base scene not found: %s" % base_scene)

	if root_name.is_empty():
		var base := ResourceLoader.load(base_scene) as PackedScene
		if base == null:
			return McpError.make("INTERNAL", "failed to load base scene: %s" % base_scene)
		var instance := base.instantiate()
		root_name = instance.name
		instance.free()

	# Idempotency: check if target already exists.
	if FileAccess.file_exists(file_path):
		return {"success": true, "status": "returned", "file_path": file_path,
			"base_scene": base_scene, "root_name": root_name,
			"message": "file already exists — no changes made"}

	var dir_result := Helpers.ensure_parent_dir(file_path, "scene.create_inherited")
	if dir_result.has("error"):
		return dir_result

	var tscn_text := '[gd_scene load_steps=2 format=3]\n\n'
	tscn_text += '[ext_resource type="PackedScene" path="%s" id="1"]\n\n' % base_scene
	tscn_text += '[node name="%s" instance=ExtResource("1")]\n' % root_name

	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		return McpError.make("INTERNAL",
			"cannot write to %s: error %d" % [file_path, FileAccess.get_open_error()])
	file.store_string(tscn_text)
	file.close()

	Helpers.ensure_file_indexed(file_path)

	return {"success": true, "file_path": file_path, "base_scene": base_scene, "root_name": root_name}


static func _cmd_scene_diff(server: Node, parameters: Dictionary) -> Dictionary:
	if not parameters.has("before"):
		return McpError.make("INVALID_PARAMS", "missing before")
	var before = parameters.get("before")
	var after = parameters.get("after", null)
	if after == null:
		var root := _get_edited_root()
		if root == null:
			return McpError.make("NO_SCENE", "no edited scene")
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


static func _cmd_scene_query(parameters: Dictionary) -> Dictionary:
	var class_filter = parameters.get("class_filter", null)
	var group_filter = parameters.get("group_filter", null)
	var name_pattern = parameters.get("name_pattern", null)
	var property_filters = parameters.get("property_filters", null)
	var root_path = parameters.get("root_path", null)
	var max_depth: int = int(parameters.get("max_depth", -1))
	var include_properties = parameters.get("include_properties", null)
	var limit: int = int(parameters.get("limit", 50))

	# At least one filter must be provided
	if class_filter == null and group_filter == null and name_pattern == null \
			and (property_filters == null \
			or (typeof(property_filters) == TYPE_ARRAY and property_filters.size() == 0)):
		return McpError.make("INVALID_PARAMS",
			"At least one filter is required: class_filter, group_filter, name_pattern, or property_filters")

	var edited_scene := EditorInterface.get_edited_scene_root()
	if edited_scene == null:
		return McpError.make("NO_SCENE", "No scene is currently open in the editor")

	# Determine root node
	var root: Node = edited_scene
	if root_path != null and str(root_path) != "":
		var rp := str(root_path)
		rp = Helpers.normalize_editor_path(rp)
		root = edited_scene.get_node_or_null(NodePath(rp))
		if root == null:
			return McpError.make("NOT_FOUND", "Root node not found: " + rp)

	var results: Array[Dictionary] = []
	_query_recursive(root, edited_scene, class_filter, group_filter, name_pattern,
		property_filters, include_properties, max_depth, 0, limit, results)

	return {"success": true, "count": results.size(), "nodes": results}


static func _query_recursive(node: Node, scene_root: Node, class_filter, group_filter,
		name_pattern, property_filters, include_properties, max_depth: int,
		current_depth: int, limit: int, results: Array[Dictionary]) -> void:
	if results.size() >= limit:
		return

	var matches := true

	# Class filter (inheritance-aware)
	if matches and class_filter != null:
		var cf := str(class_filter)
		if not node.is_class(cf):
			matches = false

	# Group filter
	if matches and group_filter != null:
		if not node.is_in_group(str(group_filter)):
			matches = false

	# Name pattern (glob)
	if matches and name_pattern != null:
		if not node.name.match(str(name_pattern)):
			matches = false

	# Property filters
	if matches and property_filters != null and typeof(property_filters) == TYPE_ARRAY:
		for pf in property_filters:
			if typeof(pf) != TYPE_DICTIONARY:
				continue
			var prop_name = pf.get("property", "")
			var expected_value = pf.get("value", null)
			var op := str(pf.get("operator", "eq"))
			var actual_value = node.get(StringName(str(prop_name)))
			if not _compare_values(actual_value, expected_value, op):
				matches = false
				break

	if matches:
		var entry: Dictionary = {
			"path": str(scene_root.get_path_to(node)),
			"class": node.get_class(),
			"name": str(node.name),
		}
		if include_properties != null and typeof(include_properties) == TYPE_ARRAY:
			for prop_name in include_properties:
				entry[str(prop_name)] = Coerce.serialize_value(
					node.get(StringName(str(prop_name))))
		results.append(entry)

	# Recurse children
	if max_depth < 0 or current_depth < max_depth:
		for child in node.get_children():
			if results.size() >= limit:
				return
			_query_recursive(child, scene_root, class_filter, group_filter, name_pattern,
				property_filters, include_properties, max_depth, current_depth + 1, limit, results)


static func _compare_values(actual, expected, op: String) -> bool:
	match op:
		"eq":
			return str(actual) == str(expected)  # String comparison for cross-type safety
		"ne":
			return str(actual) != str(expected)
		"gt":
			if actual is float or actual is int:
				return float(actual) > float(expected)
			return false
		"lt":
			if actual is float or actual is int:
				return float(actual) < float(expected)
			return false
	return false
