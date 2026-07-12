@tool
extends RefCounted
## scene.* command handlers — tree read, scene create/open/close/delete,
## node creation, instantiation.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Coerce = Modules.Coerce
const FileGuard = Modules.FileGuard
const Untrusted = Modules.Untrusted
const Helpers = Modules.CommandHelpers

const _TAB_CLOSE_NOISE_HINT := "Closing a non-active scene tab may produce a _set_main_scene_state error in the editor console. This is benign Godot engine noise — safe to ignore."

# Max scene.query page size. Caps a single page so it can't exceed the transport
# frame budget; a larger requested limit is clamped and disclosed in-band.
const _QUERY_MAX_LIMIT := 200


static func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:
	registry.add("scene.get_tree", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_get_tree(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only())
	registry.add("scene.create", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_scene_create(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("scene.open", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_scene_open(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("scene.close", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_scene_close(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent().with_min_godot_version("4.5"))
	registry.add("scene.delete", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_scene_delete(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("scene.create_node", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_create_node(parameters)
	, MCPToolkitCommandOptions.new())
	registry.add("scene.delete_node", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_delete_node(parameters)
	, MCPToolkitCommandOptions.new())
	registry.add("scene.instantiate", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_instantiate(server, parameters)
	, MCPToolkitCommandOptions.new())
	registry.add("scene.diff", func(parameters: Dictionary) -> Dictionary:
		return _cmd_scene_diff(server, parameters)
	, MCPToolkitCommandOptions.new().mark_read_only())
	registry.add("scene.create_inherited", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_create_inherited(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("scene.query", func(p: Dictionary) -> Dictionary:
		return _cmd_scene_query(p)
	, MCPToolkitCommandOptions.new().mark_read_only())


# -- Helpers ------------------------------------------------------------------


static func _get_edited_root() -> Node:
	return Helpers.get_edited_root()


## Returns the subset of [param candidate_keys] that [param parameters] actually
## carries, preserving the given order.
##
## An idempotent-return branch parses caller args it will not apply when the node
## already exists; this names only the args the caller truly passed, so the
## disclosure stays actionable and never fires on args nobody sent.
static func _passed_keys(parameters: Dictionary, candidate_keys: Array[String]) -> Array[String]:
	var passed: Array[String] = []
	for key in candidate_keys:
		if parameters.has(key):
			passed.append(key)
	return passed


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


# -- Commands -----------------------------------------------------------------


static func _cmd_scene_get_tree(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return MCPToolkitError.fail("NO_SCENE", "no edited scene")
	var depth_raw = parameters.get("max_depth", 2)
	var depth: int = int(depth_raw) \
		if (typeof(depth_raw) == TYPE_INT or typeof(depth_raw) == TYPE_FLOAT) else 2
	var include_properties: bool = bool(parameters.get("include_properties", false))
	var tree := _walk_tree(root, root, depth, include_properties)
	return MCPToolkitSuccess.ok({"tree": Untrusted.wrap(
		"scene_tree", str(root.scene_file_path), JSON.stringify(tree))})


static func _cmd_scene_create(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var root_type := str(parameters.get("root_type", "Node"))
	var if_exists := str(parameters.get("if_exists", "return"))
	# Optional root_name; empty falls back to the filename stem (preserves the prior default).
	var root_name := str(parameters.get("root_name", ""))
	if root_name.is_empty():
		root_name = file_path.get_file().get_basename()
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if file_path.get_extension().to_lower() != "tscn":
		return MCPToolkitError.fail("INVALID_PATH",
			"path must end with .tscn (got %s; use script.write for .gd/.cs files)" % file_path)
	var dir_result := Helpers.ensure_parent_dir(file_path, "scene.create")
	if dir_result.has("error"):
		return dir_result
	var dirs_created: bool = dir_result["dirs_created"]

	var rk := Helpers.resolve_class_kind(root_type)
	var resolved_kind: String = rk["kind"]
	var global_entry: Dictionary = rk["entry"]
	if resolved_kind.is_empty():
		return MCPToolkitError.fail("INVALID_CLASS",
			"unknown class %s; checked ClassDB (engine classes) and ProjectSettings.get_global_class_list() (GDScript class_name + C# [GlobalClass])" % root_type, MCPToolkitError.HINT_CLASS_NAME)
	if not Helpers.class_descends_from(root_type, "Node"):
		return MCPToolkitError.fail("INVALID_CLASS",
			"%s is not a Node subclass (resolved base chain: %s); scene roots must descend from Node" % [root_type, Helpers.class_base_chain(root_type)])
	var collision := Helpers.resolve_create_collision(file_path, if_exists)
	if not collision["valid"]:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"if_exists must be one of 'return'|'fail'|'replace' (got %s); default is 'return'" % if_exists)

	var was_replace := false
	var previous_root_type := ""
	if collision["existed"]:
		match collision["action"]:
			"return":
				return MCPToolkitSuccess.ok({"status": "returned", "path": file_path,
					"root_name": root_name, "root_path": "."})
			"fail":
				return MCPToolkitError.fail("ALREADY_EXISTS",
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
			return MCPToolkitError.fail("INVALID_CLASS",
				"could not load script for %s at %s" % [root_type, script_path])
		root = script.new()
	if root == null:
		return MCPToolkitError.fail("INVALID_CLASS",
			"instantiation returned null for %s" % root_type)
	root.name = root_name
	var packed := PackedScene.new()
	var pack_error := packed.pack(root)
	if pack_error != OK:
		root.queue_free()
		return MCPToolkitError.fail("PACK_FAILED",
			"PackedScene.pack returned %d (class=%s, path=%s)" % [pack_error, root_type, file_path])
	var save_error := ResourceSaver.save(packed, file_path)
	root.queue_free()
	if save_error != OK:
		return MCPToolkitError.fail("SAVE_FAILED",
			"ResourceSaver.save returned %d (path=%s)" % [save_error, file_path])

	var scene_index := await Helpers.ensure_file_indexed(file_path)
	var response := MCPToolkitSuccess.ok({"path": file_path, "root_type": root_type,
		"root_name": root_name, "root_path": ".",
		"indexed": scene_index["indexed"],
		"hint": "Scene saved. Open it for editing with scene_open."})
	if dirs_created:
		response["dirs_created"] = true
	if was_replace:
		response["status"] = "replaced"
		response["previous_root_type"] = previous_root_type
		# P-003: If the replaced scene is currently open in the editor, reload
		# it from disk so the in-memory tree matches the fresh file.
		var open_scenes := EditorInterface.get_open_scenes()
		if file_path in open_scenes:
			if await Helpers.open_scene_deferred(file_path):
				response["reloaded"] = true
				response["hint"] = "Scene replaced and reloaded in editor."
			else:
				response["reloaded"] = false
				response["hint"] = "Scene replaced; reload skipped (filesystem scanning) — reopen with scene_open."
	else:
		response["status"] = "created"
	return response


static func _cmd_scene_open(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if not FileAccess.file_exists(file_path):
		return MCPToolkitError.fail("NOT_FOUND", "scene not found: %s" % file_path, MCPToolkitError.HINT_FILE_PATH)
	if not await Helpers.open_scene_deferred(file_path):
		return MCPToolkitError.fail("TIMEOUT",
			"could not open %s — EditorFileSystem still scanning; retry shortly" % file_path)
	return MCPToolkitSuccess.ok({"path": file_path})


static func _cmd_scene_close(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("file_path", ""))
	if file_path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "path is required")
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	var result := await Helpers.close_scene_tab_safe(file_path)
	if result.get("closed", false):
		var response := MCPToolkitSuccess.ok({"path": file_path})
		if result.get("switched", false):
			response["hint"] = _TAB_CLOSE_NOISE_HINT
		# Disclose discarded unsaved edits where the editor can report them (4.7+);
		# the helper omits the key below 4.7, so absence here means "not detectable".
		if result.has("unsaved_changes_discarded"):
			response["unsaved_changes_discarded"] = result["unsaved_changes_discarded"]
		return response
	var reason := str(result.get("reason", ""))
	if reason == "not_open":
		return MCPToolkitError.fail("NOT_FOUND",
			"scene is not open in any editor tab: %s" % file_path, MCPToolkitError.HINT_FILE_PATH)
	if reason == "no_api":
		return MCPToolkitError.fail("UNSUPPORTED",
			"scene.close requires Godot 4.5+ (connected: %s)" % Modules.VersionUtils.get_engine_version_pair())
	return MCPToolkitError.fail("INTERNAL", "unexpected close_scene_tab_safe reason: %s" % reason)


static func _cmd_scene_delete(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if file_path.get_extension().to_lower() != "tscn":
		return MCPToolkitError.fail("INVALID_PATH",
			"scene.delete only removes .tscn files (got %s); use a different tool for other file types" % file_path)
	if not FileAccess.file_exists(file_path):
		return MCPToolkitError.fail("NOT_FOUND", "no file at %s" % file_path, MCPToolkitError.HINT_FILE_PATH)

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
				return MCPToolkitError.fail("EDITED_SCENE",
					"cannot delete the currently-edited scene %s on Godot 4.2-4.4 (no tab-close API); open a different scene via scene.open first" % file_path)
			warnings.append(
				"phantom tab: scene tab for %s remains open; Godot 4.2-4.4 has no API to close tabs — it will vanish on editor restart or manual close" % file_path)

	var delete_result: Dictionary = await Helpers.delete_res_file_and_deindex(file_path)
	delete_result["tab_closed"] = tab_closed
	if tab_closed and tab_result.get("switched", false):
		delete_result["hint"] = _TAB_CLOSE_NOISE_HINT
	if not warnings.is_empty():
		delete_result["warnings"] = warnings
	return delete_result


static func _cmd_scene_create_node(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return MCPToolkitError.fail("NO_SCENE", "no edited scene")

	var class_name_param := str(parameters.get("class_name", ""))
	var parent_path := str(parameters.get("parent_path", ""))
	parent_path = Helpers.normalize_editor_path(parent_path)
	var requested_name := str(parameters.get("node_name", class_name_param))

	if class_name_param.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing class_name")

	var resolved_kind := ""
	var global_entry: Dictionary = {}
	if ClassDB.class_exists(class_name_param):
		resolved_kind = "native"
		if not ClassDB.can_instantiate(class_name_param):
			return MCPToolkitError.fail("INVALID_CLASS",
				"class is not instantiable (abstract, virtual, or editor-only): %s" % class_name_param)
	else:
		for entry in ProjectSettings.get_global_class_list():
			if str(entry.get("class", "")) == class_name_param:
				resolved_kind = "global"
				global_entry = entry
				break
	if resolved_kind.is_empty():
		return MCPToolkitError.fail("INVALID_CLASS",
			"unknown class %s; checked ClassDB (engine classes) and ProjectSettings.get_global_class_list() (GDScript class_name + C# [GlobalClass])" % class_name_param, MCPToolkitError.HINT_CLASS_NAME)
	if not Helpers.class_descends_from(class_name_param, "Node"):
		return MCPToolkitError.fail("INVALID_CLASS",
			"%s is not a Node subclass (resolved base chain: %s); scene roots must descend from Node" % [
				class_name_param, Helpers.class_base_chain(class_name_param)])

	var parent_node := root.get_node_or_null(parent_path) if not parent_path.is_empty() else root
	if parent_node == null:
		var extra := ""
		if parent_path == root.name:
			extra = "; to reference the scene root use parent_path=\".\" (not the root node's name)"
		return MCPToolkitError.fail("NOT_FOUND", "parent not found: %s%s" % [parent_path, extra], MCPToolkitError.HINT_NODE_PATH)

	var existing := parent_node.get_node_or_null(NodePath(requested_name))
	if existing != null:
		var class_match := false
		var existing_script := existing.get_script() as Script
		var existing_global_name := ""
		if existing_script != null:
			if existing_script.has_method("get_global_name"):
				# 4.3+: script-direct, authoritative and current -- the same value the
				# old static call returned (dynamic dispatch so 4.2 never resolves it).
				existing_global_name = str(existing_script.call("get_global_name"))
			else:
				# 4.2: get_global_name is an unbound virtual -- invisible to GDScript.
				# Reverse-lookup the class list by resource_path (4.2-safe; also C#).
				for entry in ProjectSettings.get_global_class_list():
					if str(entry.get("path", "")) == existing_script.resource_path:
						existing_global_name = str(entry.get("class", ""))
						break
		if resolved_kind == "native":
			class_match = existing.is_class(class_name_param)
		elif existing_script != null:
			class_match = existing_global_name == class_name_param
		if class_match:
			var returned := {"status": "returned", "path": _path_in_scene(root, existing)}
			# The existing node is handed back untouched: properties/layout_mode/
			# unique_name only apply while creating. Name any the caller passed so a
			# silent no-op doesn't read as "applied".
			var ignored := _passed_keys(parameters, ["properties", "layout_mode", "unique_name"])
			if not ignored.is_empty():
				returned["warning"] = "node already existed; ignored %s (only applied when a node is created, not returned)" % ", ".join(ignored)
			return MCPToolkitSuccess.ok(returned)
		var actual := existing_global_name if existing_global_name != "" else existing.get_class()
		return MCPToolkitError.fail("CLASS_MISMATCH",
			"node '%s' already exists under '%s' as %s, not %s; rename or remove it first" % [
				requested_name, _path_in_scene(root, parent_node), actual, class_name_param])

	var instance: Node = null
	if resolved_kind == "native":
		instance = ClassDB.instantiate(class_name_param)
	else:
		var script_path := str(global_entry.get("path", ""))
		var script = load(script_path)
		if script == null:
			return MCPToolkitError.fail("INVALID_CLASS",
				"could not load script for %s at %s" % [class_name_param, script_path])
		instance = script.new()
	if instance == null or not (instance is Node):
		return MCPToolkitError.fail("INVALID_CLASS", "instantiate failed: %s" % class_name_param)

	instance.name = requested_name

	# Pre-coerce inline properties before UndoRedo (validation only). The raw wire
	# value rides along so the post-set readback guard can give the bare-res://-string
	# tagged-form hint (parity with node.set_property).
	var properties_raw = parameters.get("properties", null)
	var prop_coerced: Array = []  # [{name, value, old_value, raw}] — simple props (candidate for UndoRedo)
	var prop_compound: Array = []  # [{name, raw_value}] — compound paths (direct set)
	var prop_failed: Array = []
	if properties_raw != null and typeof(properties_raw) == TYPE_DICTIONARY:
		for key in (properties_raw as Dictionary).keys():
			var prop_name := str(key)
			# Compound paths (: or /) bypass coerce_for_property and use
			# centralized set_property_compound (handles shader_parameter/ etc.)
			if ":" in prop_name or "/" in prop_name:
				prop_compound.append({"name": prop_name, "raw_value": properties_raw[key]})
			else:
				var result := Helpers.coerce_for_property(
					instance, prop_name, properties_raw[key])
				if result.get("ok", false):
					prop_coerced.append({
						"name": prop_name,
						"value": result["value"],
						"old_value": instance.get(prop_name),
						"raw": properties_raw[key],
					})
				else:
					prop_failed.append({
						"name": prop_name,
						"error": str(result.get("error", "")),
					})

	parent_node.add_child(instance)
	instance.set_owner(root)
	# Set each simple prop, then read it back and classify the write. Coercion says a
	# value is well-formed; it does NOT prove Object.set() stored it — set() is void and
	# silently discards a wrong-type Variant. A DROPPED write is restored, reported in
	# properties_failed, and excluded from both the UndoRedo rows and properties_set, so
	# the response reflects only the writes that stored. Only landed props are undoable.
	var landed: Array = []  # coerced props that stored (clean or engine-adjusted)
	var warnings: Array[String] = []
	for prop in prop_coerced:
		var prop_name: String = str(prop["name"])
		# Disarm the Godot 4.3 tooltip-timer UAF before an editor_description write
		# (no-op otherwise). Usually a no-op here — the new row is (re)built deferred —
		# but it keeps every built-in editor_description write behind one guard.
		Helpers.disarm_tooltip_uaf(instance, prop_name)
		instance.set(prop_name, prop["value"])
		var after = instance.get(prop_name)
		# Bare res:// string on a Resource-typed property: a bare path silently fails to
		# load, so steer to the tagged {type:"Resource", path:…} form BEFORE the generic
		# drop guard (which would fire first with a vaguer message). Message mirrors
		# node.set_property's scalar path so both tools report the same mistake identically.
		var raw = prop["raw"]
		if typeof(raw) == TYPE_STRING and str(raw).begins_with("res://") \
				and not (prop["value"] is Resource) and not (after is String):
			instance.set(prop_name, prop["old_value"])
			prop_failed.append({"name": prop_name, "error":
				"property '%s' expects a Resource, not a bare string path. " % prop_name +
				"Use {\"type\": \"Resource\", \"path\": \"%s\"} as the value." % str(raw)})
			continue
		var outcome := Helpers.describe_set_drop(
			prop["old_value"], after, prop["value"], prop_name)
		match str(outcome.get("status", "")):
			"dropped":
				# A bound setter may have Variant-converted the wrong type to a ZERO and
				# stored it; restore the prior so the drop is truly non-destructive.
				instance.set(prop_name, prop["old_value"])
				prop_failed.append({"name": prop_name, "error": str(outcome.get("error", ""))})
			"adjusted":
				warnings.append(str(outcome.get("warning", "")))
				landed.append(prop)
			_:
				landed.append(prop)
	var _undo := MCPToolkitUndoRedoAction.begin("create %s" % requested_name, parent_node) \
		.do_method(parent_node.add_child.bind(instance)) \
		.do_method(instance.set_owner.bind(root)) \
		.do_reference(instance)
	for prop in landed:
		_undo.do_property(instance, prop["name"], prop["value"])
		_undo.undo_property(instance, prop["name"], prop["old_value"])
	_undo.undo_method(parent_node.remove_child.bind(instance)) \
		.commit_recorded()

	# Apply compound properties after node is in tree (can't go through UndoRedo).
	for prop in prop_compound:
		var result := Helpers.set_property_compound(instance, prop["name"], prop["raw_value"])
		if not result.get("ok", false):
			prop_failed.append({"name": prop["name"], "error": str(result.get("error", ""))})

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
	var response := MCPToolkitSuccess.ok({"status": "created", "path": _path_in_scene(root, instance)})

	# Report inline property results. properties_set counts only props that actually
	# landed (a dropped write is excluded); properties_failed lists both coercion
	# rejections and post-set drops; adjusted writes stored, so they count as set and
	# surface their delta in warnings.
	if not landed.is_empty() or not prop_failed.is_empty():
		response["properties_set"] = landed.size()
		if not prop_failed.is_empty():
			response["properties_failed"] = prop_failed
			response["hint"] = "%d propert%s failed. Use node_set_property to retry." % [
				prop_failed.size(),
				"y" if prop_failed.size() == 1 else "ies"]
	if not warnings.is_empty():
		response["warnings"] = warnings

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
		return MCPToolkitError.fail("NO_SCENE", "no edited scene")

	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)
	if node_path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing node_path")

	var node := root.get_node_or_null(node_path)
	if node == null:
		return MCPToolkitError.fail("NOT_FOUND", "node not found: %s" % node_path, MCPToolkitError.HINT_NODE_PATH)
	if node == root:
		return MCPToolkitError.fail("INVALID_PATH", "cannot delete edited scene root")

	var parent := node.get_parent()
	if parent == null:
		return MCPToolkitError.fail("INTERNAL", "node has no parent: %s" % node_path)
	parent.remove_child(node)
	MCPToolkitUndoRedoAction.begin("delete %s" % node_path, parent) \
		.do_method(parent.remove_child.bind(node)) \
		.undo_method(parent.add_child.bind(node)) \
		.undo_method(node.set_owner.bind(root)) \
		.undo_reference(node) \
		.commit_recorded()
	return MCPToolkitSuccess.ok({"path": node_path})


static func _cmd_scene_instantiate(server: Node, parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return MCPToolkitError.fail("NO_SCENE", "no open scene; use scene.open or scene.create first")

	var parent_path := str(parameters.get("parent_path", ""))
	parent_path = Helpers.normalize_editor_path(parent_path)
	var packed_path := str(parameters.get("scene_path", ""))

	if parent_path.is_empty() or packed_path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing parent_path or scene_path")

	var parent_node := root.get_node_or_null(parent_path)
	if parent_node == null:
		return MCPToolkitError.fail("NOT_FOUND",
			"no node at parent_path %s (must be under the currently-edited scene root)" % parent_path, MCPToolkitError.HINT_NODE_PATH)

	var guard := FileGuard.resolve_safe(packed_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if packed_path.get_extension().to_lower() != "tscn":
		return MCPToolkitError.fail("INVALID_PATH",
			"scene.instantiate only instantiates .tscn files (got %s); use resource.write for .tres, script.write for .gd/.cs" % packed_path)
	if not FileAccess.file_exists(packed_path):
		return MCPToolkitError.fail("NOT_FOUND",
			"no scene file at %s; use scene.create first" % packed_path, MCPToolkitError.HINT_FILE_PATH)
	var packed := ResourceLoader.load(packed_path)
	if packed == null:
		return MCPToolkitError.fail("LOAD_FAILED",
			"ResourceLoader.load returned null for %s (corrupt file or dependency error — check editor_get_console)" % packed_path)
	if not (packed is PackedScene):
		return MCPToolkitError.fail("INVALID_CLASS",
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
			var returned := {
				"status": "returned",
				"path": _path_in_scene(root, existing_node),
				"class_name": existing_node.get_class(),
			}
			# transform applies only to a freshly-instantiated node; the existing
			# one is returned as-is. Disclose a passed transform so it doesn't read
			# as silently applied.
			if not transform.is_empty():
				returned["warning"] = "node already existed; ignored transform (only applied to a newly-instantiated node)"
			return MCPToolkitSuccess.ok(returned)
		# Auto-rename on collision (Player, Player2, Player3...) —
		# matches Godot editor's own drag-drop naming convention.
		var suffix := 2
		while parent_node.has_node(NodePath(target_name + str(suffix))):
			suffix += 1
		target_name = target_name + str(suffix)

	var instance: Node = (packed as PackedScene).instantiate()
	if instance == null:
		return MCPToolkitError.fail("LOAD_FAILED",
			"PackedScene.instantiate returned null for %s" % packed_path)

	instance.name = target_name

	if not transform.is_empty():
		for key in transform.keys():
			var outcome := _coerce_transform_value(transform[key])
			if not outcome["ok"]:
				# instance is instantiated but not yet in the tree — free the
				# orphan before bailing so a malformed transform can't leak a node.
				instance.queue_free()
				return MCPToolkitError.fail("INVALID_PARAMS", str(outcome["error"]))
			instance.set(str(key), outcome["value"])

	# Only set owner on instance root — child nodes keep their internal
	# ownership from PackedScene. _set_owner_recursive caused full property
	# expansion, breaking Godot's scene inheritance model.
	parent_node.add_child(instance)
	instance.set_owner(root)
	MCPToolkitUndoRedoAction.begin("instantiate %s under %s" % [packed_path, parent_path], parent_node) \
		.do_method(parent_node.add_child.bind(instance)) \
		.do_method(instance.set_owner.bind(root)) \
		.do_reference(instance) \
		.undo_method(parent_node.remove_child.bind(instance)) \
		.commit_recorded()

	return MCPToolkitSuccess.ok({
		"status": "created",
		"path": _path_in_scene(root, instance),
		"class_name": instance.get_class(),
	})


## Coerce one transform value (position/rotation/scale) for an instantiate call.
## Returns {"ok": true, "value": <coerced>} on success, else
## {"ok": false, "error": <message>}.
##
## A bare {x, y} / {x, y, z} dict carries no "type" tag, so [method Coerce.coerce_value]
## returns it as a plain dict (not a typed Vector). set()-ing that dict onto a Vector
## property is a silent no-op, so it is rejected here with a hint to tag it — an honest
## failure in place of a dropped transform.
static func _coerce_transform_value(raw: Variant) -> Dictionary:
	var coerced = Coerce.coerce_value(raw)
	if typeof(coerced) == TYPE_DICTIONARY:
		if (coerced as Dictionary).has("_coerce_error"):
			return {"ok": false, "error": str(coerced["_coerce_error"])}
		return {"ok": false, "error":
			"position/rotation/scale expect a tagged Vector2 {type:'Vector2', x, y} (or Vector3 {type:'Vector3', x, y, z} for 3D) — a bare {x, y} is not coerced"}
	return {"ok": true, "value": coerced}


static func _batch_instantiate(
	server: Node, root: Node, parent_node: Node, packed: PackedScene,
	packed_path: String, parent_path: String, instances: Array,
) -> Dictionary:
	var node_refs: Array = []
	# Per-entry outcome record: every entry — success OR failure —
	# gets a dict so a partial batch no longer hides its failures. Built parallel
	# to `node_refs`; success entries are backfilled with their post-commit path
	# below. `results[i]` lines up with `instances[i]`. `_result_slots` maps each
	# surviving node to its slot so the deferred path read patches the right row.
	var results: Array = []
	var _result_slots: Array = []
	var _undo := MCPToolkitUndoRedoAction.begin(
		"batch instantiate %d × %s" % [instances.size(), packed_path], parent_node)

	for i in instances.size():
		var entry = instances[i]
		var inst_dict: Dictionary = entry if typeof(entry) == TYPE_DICTIONARY else {}
		var inst_name := str(inst_dict.get("name", ""))
		var instance: Node = packed.instantiate()
		if instance == null:
			# Previously a silent `continue` — the failed entry vanished. Record it.
			results.append({
				"index": i,
				"success": false,
				"name": inst_name,
				"error": "PackedScene.instantiate returned null for %s" % packed_path,
			})
			continue

		if not inst_name.is_empty():
			instance.name = inst_name

		# Per-key coerce failures used to `continue` the inner loop silently — the
		# node still lands but the key was dropped invisibly. Capture each into
		# `property_errors` on this (succeeding) entry instead of losing it.
		var property_errors: Array = []

		# Apply transform properties (position, rotation, scale).
		for key in ["position", "rotation", "scale"]:
			if inst_dict.has(key):
				var outcome := _coerce_transform_value(inst_dict[key])
				if not outcome["ok"]:
					property_errors.append({"property": key, "error": str(outcome["error"])})
					continue
				instance.set(key, outcome["value"])

		# Apply arbitrary property overrides (e.g. exports like key_type).
		# Compound paths (: or /) use the centralized handler.
		var props = inst_dict.get("properties", null)
		if typeof(props) == TYPE_DICTIONARY:
			for key in (props as Dictionary).keys():
				var prop_name := str(key)
				if ":" in prop_name or "/" in prop_name:
					Helpers.set_property_compound(instance, prop_name, props[key])
				else:
					var coerced = Coerce.coerce_value(props[key])
					if typeof(coerced) == TYPE_DICTIONARY and (coerced as Dictionary).has("_coerce_error"):
						property_errors.append({"property": prop_name, "error": str(coerced["_coerce_error"])})
						continue
					instance.set(prop_name, coerced)

		# Only set owner on instance root (same as single-instance path).
		parent_node.add_child(instance)
		instance.set_owner(root)
		_undo.do_method(parent_node.add_child.bind(instance)) \
			.do_method(instance.set_owner.bind(root)) \
			.do_reference(instance) \
			.undo_method(parent_node.remove_child.bind(instance))

		node_refs.append(instance)
		# Success row — path/class are filled after commit (see below). Carry any
		# per-key coerce failures so they're no longer invisible.
		var slot := {"index": i, "success": true}
		if not property_errors.is_empty():
			slot["property_errors"] = property_errors
		results.append(slot)
		_result_slots.append(slot)

	_undo.commit_recorded()

	# Collect paths AFTER commit_action — instances are now in the tree,
	# so get_path_to() can find the common parent.
	var created: Array = []
	for idx in node_refs.size():
		var inst: Node = node_refs[idx]
		var inst_path := _path_in_scene(root, inst)
		var inst_class := inst.get_class()
		var resolved_name := String(inst.name)
		created.append({
			"path": inst_path,
			"class": inst_class,
			"name": resolved_name,
		})
		# Backfill the matching success row with its now-resolvable path/class/name.
		var slot: Dictionary = _result_slots[idx]
		slot["path"] = inst_path
		slot["class"] = inst_class
		slot["name"] = resolved_name

	# Roll any failed entries up into a top-level `failed` + `hint` (no-op when all
	# succeeded — `instances`/`count` stay exactly as before).
	return MCPToolkitSuccess.ok(Helpers.summarize_batch({"status": "created",
		"count": created.size(), "instances": created, "results": results}, "results"))


static func _cmd_create_inherited(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path", "base_scene"])
	if err != null:
		return err

	var file_path := str(parameters.get("file_path", ""))
	var base_scene := str(parameters.get("base_scene", ""))
	var root_name := str(parameters.get("root_name", ""))

	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if not file_path.ends_with(".tscn"):
		return MCPToolkitError.fail("INVALID_PARAMS", "file_path must end with .tscn")

	var base_guard := FileGuard.resolve_safe(base_scene)
	if base_guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(base_guard["reason"]))
	if not ResourceLoader.exists(base_scene):
		return MCPToolkitError.fail("NOT_FOUND", "base scene not found: %s" % base_scene)

	if root_name.is_empty():
		var base := ResourceLoader.load(base_scene) as PackedScene
		if base == null:
			return MCPToolkitError.fail("INTERNAL", "failed to load base scene: %s" % base_scene)
		var instance := base.instantiate()
		root_name = instance.name
		instance.free()

	# Idempotency: check if target already exists.
	if FileAccess.file_exists(file_path):
		return MCPToolkitSuccess.ok({"status": "returned", "file_path": file_path,
			"base_scene": base_scene, "root_name": root_name,
			"message": "file already exists — no changes made"})

	var dir_result := Helpers.ensure_parent_dir(file_path, "scene.create_inherited")
	if dir_result.has("error"):
		return dir_result

	var tscn_text := '[gd_scene load_steps=2 format=3]\n\n'
	tscn_text += '[ext_resource type="PackedScene" path="%s" id="1"]\n\n' % base_scene
	tscn_text += '[node name="%s" instance=ExtResource("1")]\n' % root_name

	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		return MCPToolkitError.fail("INTERNAL",
			"cannot write to %s: error %d" % [file_path, FileAccess.get_open_error()])
	file.store_string(tscn_text)
	file.close()

	await Helpers.ensure_file_indexed(file_path)

	return MCPToolkitSuccess.ok({"file_path": file_path, "base_scene": base_scene, "root_name": root_name})


static func _cmd_scene_diff(server: Node, parameters: Dictionary) -> Dictionary:
	if not parameters.has("before"):
		return MCPToolkitError.fail("INVALID_PARAMS", "missing before")
	var before = parameters.get("before")
	var after = parameters.get("after", null)
	if after == null:
		var root := _get_edited_root()
		if root == null:
			return MCPToolkitError.fail("NO_SCENE", "no edited scene")
		after = _walk_tree(root, root, -1, false)
	var before_string := JSON.stringify(before, "  ", true)
	var after_string := JSON.stringify(after, "  ", true)
	if before_string == after_string:
		return MCPToolkitSuccess.ok({"changed": false, "diff": "", "added": 0, "removed": 0})
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
	return MCPToolkitSuccess.ok({
		"changed": true,
		"diff": "\n".join(diff_parts),
		"added": added,
		"removed": removed,
	})


static func _cmd_scene_query(parameters: Dictionary) -> Dictionary:
	var class_filter = parameters.get("class_filter", null)
	var group_filter = parameters.get("group_filter", null)
	var name_pattern = parameters.get("name_pattern", null)
	var property_filters = parameters.get("property_filters", null)
	var root_path = parameters.get("root_path", null)
	var max_depth: int = int(parameters.get("max_depth", -1))
	var include_properties = parameters.get("include_properties", null)
	# Never trust the caller's window bounds: floor offset at 0 and cap limit so a
	# single page can't exceed the transport frame budget (a huge include_properties
	# page is the residual bloat vector). The clamp is disclosed in-band below.
	var requested_limit: int = int(parameters.get("limit", 50))
	var limit: int = mini(requested_limit, _QUERY_MAX_LIMIT)
	var limit_clamped := limit < requested_limit
	var offset: int = maxi(0, int(parameters.get("offset", 0)))

	# At least one filter must be provided
	if class_filter == null and group_filter == null and name_pattern == null \
			and (property_filters == null \
			or (typeof(property_filters) == TYPE_ARRAY and property_filters.size() == 0)):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"At least one filter is required: class_filter, group_filter, name_pattern, or property_filters")

	var edited_scene := EditorInterface.get_edited_scene_root()
	if edited_scene == null:
		return MCPToolkitError.fail("NO_SCENE", "No scene is currently open in the editor")

	# Determine root node
	var root: Node = edited_scene
	if root_path != null and str(root_path) != "":
		var rp := str(root_path)
		rp = Helpers.normalize_editor_path(rp)
		root = edited_scene.get_node_or_null(NodePath(rp))
		if root == null:
			return MCPToolkitError.fail("NOT_FOUND", "Root node not found: " + rp)

	# Single ordered DFS pre-order pass counts every match and materializes only the
	# [offset, offset+limit) window (see _query_recursive). total_ref[0] is the
	# running match count threaded by reference.
	var results: Array[Dictionary] = []
	var total_ref: Array[int] = [0]
	_query_recursive(root, edited_scene, class_filter, group_filter, name_pattern,
		property_filters, include_properties, max_depth, 0, offset, limit, total_ref, results)
	var total_matches := total_ref[0]

	return _build_query_page(results, offset, limit, total_matches, limit_clamped)


## Assembles the self-describing pagination envelope for scene.query.
##
## [param limit] is the effective (already-clamped) page size; [param limit_clamped]
## records that the caller's request was capped, so this discloses the flag and appends a
## clamp clause to the resume hint. Routes through the shared [code]Pagination[/code]
## builder so the invariants and the [code]next_offset[/code] resume field match every
## other paginating tool; the hint wording is scene.query's own.
static func _build_query_page(results: Array[Dictionary], offset: int, limit: int,
		total_matches: int, limit_clamped: bool) -> Dictionary:
	var returned := results.size()
	var has_more := offset + returned < total_matches
	var hint := ""
	if has_more:
		hint = "more matches remain — re-call scene_query with offset = next_offset (%d) until has_more is false" % (offset + returned)
	var extras: Dictionary = {}
	if limit_clamped:
		extras["limit_clamped"] = true
		var clamp_clause := "requested limit exceeds max %d; returned %d — page with next_offset, or add filters to narrow" % [
			_QUERY_MAX_LIMIT, limit]
		hint = clamp_clause if hint.is_empty() else "%s. %s" % [hint, clamp_clause]
	var page := Modules.Pagination.list_page(
		{"nodes": results, "offset": offset, "limit": limit},
		results, offset, "matches", total_matches, hint, extras)
	return MCPToolkitSuccess.ok(page)


static func _query_recursive(node: Node, scene_root: Node, class_filter, group_filter,
		name_pattern, property_filters, include_properties, max_depth: int,
		current_depth: int, offset: int, limit: int, total_ref: Array[int],
		results: Array[Dictionary]) -> void:
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
		# Count every match for total_matches; serialize the entry only when this
		# match's 0-based index falls in the requested window. The count and the
		# window both derive from this one ordered pass, so paging stays coherent.
		var match_index := total_ref[0]
		total_ref[0] = match_index + 1
		if match_index >= offset and results.size() < limit:
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

	# Recurse children in child-index order — the only ordering; no early-stop, so
	# every match past the window is still counted into total_matches.
	if max_depth < 0 or current_depth < max_depth:
		for child in node.get_children():
			_query_recursive(child, scene_root, class_filter, group_filter, name_pattern,
				property_filters, include_properties, max_depth, current_depth + 1,
				offset, limit, total_ref, results)


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
