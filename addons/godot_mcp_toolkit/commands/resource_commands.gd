@tool
extends RefCounted
## resource.* command handlers — load, write (create/update upsert), delete for .tres/.res files.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPCoerce = _Hub.MCPCoerce
const MCPCommandRegistry = _Hub.MCPCommandRegistry
const MCPFileGuard = _Hub.MCPFileGuard
const MCPUntrusted = _Hub.MCPUntrusted

const RESOURCE_SKIP_PROPERTIES: Array[String] = [
	"image", "mesh_arrays", "surface_arrays", "_data",
]


static func register(registry: MCPCommandRegistry, _server: Node) -> void:
	registry.add("resource.load", func(parameters: Dictionary) -> Dictionary:
		return _cmd_resource_load(parameters))
	registry.add("resource.write", func(parameters: Dictionary) -> Dictionary:
		return _cmd_resource_write(parameters))
	registry.add("resource.delete", func(parameters: Dictionary) -> Dictionary:
		return _cmd_resource_delete(parameters))


# -- Helpers ------------------------------------------------------------------


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


static func _property_names_of(object: Object) -> Dictionary:
	var names := {}
	for property in object.get_property_list():
		var property_name := str(property.get("name", ""))
		if not property_name.is_empty():
			names[property_name] = true
	return names


static func _apply_resource_properties(
	resource: Resource, properties: Dictionary, resource_class: String,
) -> Array[String]:
	var warnings: Array[String] = []
	var valid := _property_names_of(resource)
	for key in properties.keys():
		var key_string := str(key)
		if not valid.has(key_string):
			warnings.append(
				"property '%s' unknown on %s; value ignored" % [key_string, resource_class])
			continue
		var raw_value = properties[key]
		var missing := MCPCoerce.check_resource_paths(raw_value)
		if missing != "":
			warnings.append(
				"property '%s': resource not found at %s; value left unchanged" % [key_string, missing])
			continue
		resource.set(key_string, MCPCoerce.coerce_value(raw_value))
	return warnings


# -- Commands -----------------------------------------------------------------


static func _cmd_resource_load(parameters: Dictionary) -> Dictionary:
	var err = MCPError.check_required(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	if not ResourceLoader.exists(file_path):
		return MCPError.make("NOT_FOUND", "resource not found: %s" % file_path, MCPError.HINT_FILE_PATH)
	var resource := ResourceLoader.load(file_path)
	if resource == null:
		return MCPError.make("LOAD_FAILED",
			"ResourceLoader returned null for %s" % file_path)
	var resource_class := resource.get_class()
	var properties := {}
	for property in resource.get_property_list():
		var usage: int = int(property.get("usage", 0))
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		var property_name := str(property.get("name", ""))
		if property_name.is_empty() or property_name.begins_with("_"):
			continue
		if property_name in RESOURCE_SKIP_PROPERTIES:
			continue
		properties[property_name] = MCPCoerce.serialize_value(resource.get(property_name))
	var metadata := {}
	if resource is Texture2D:
		metadata["width"] = resource.get_width()
		metadata["height"] = resource.get_height()
	return {
		"class": resource_class,
		"path": file_path,
		"properties": MCPUntrusted.wrap(
			"resource", file_path, JSON.stringify(properties)),
		"metadata": metadata,
	}


static func _cmd_resource_write(parameters: Dictionary) -> Dictionary:
	var err = MCPError.check_required(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	var extension := file_path.get_extension().to_lower()
	if not (extension in ["tres", "res"]):
		return MCPError.make("INVALID_PATH",
			"resource.write only writes .tres/.res files (got %s); use script.write for .gd" % file_path)
	var properties: Dictionary = parameters.get("properties", {}) \
		if typeof(parameters.get("properties", {})) == TYPE_DICTIONARY else {}
	if FileAccess.file_exists(file_path):
		var resource := ResourceLoader.load(file_path)
		if resource == null:
			return MCPError.make("NOT_A_RESOURCE",
				"file at %s is not a readable Resource" % file_path)
		var resource_class := resource.get_class()
		var warnings := _apply_resource_properties(resource, properties, resource_class)
		var save_error := ResourceSaver.save(resource, file_path)
		if save_error != OK:
			return MCPError.make("SAVE_FAILED",
				"ResourceSaver.save returned %d (path=%s)" % [save_error, file_path])
		return {
			"success": true,
			"path": file_path,
			"resource_class": resource_class,
			"warnings": warnings,
		}
	var resource_class := str(parameters.get("type", ""))
	if resource_class.is_empty():
		return MCPError.make("NOT_FOUND",
			"resource not found at %s; provide 'type' to create it" % file_path, MCPError.HINT_FILE_PATH)
	var parent_dir := file_path.get_base_dir()
	var dirs_created := false
	if not DirAccess.dir_exists_absolute(parent_dir):
		var mkdir_err := DirAccess.make_dir_recursive_absolute(parent_dir)
		if mkdir_err != OK:
			return MCPError.make("PARENT_NOT_FOUND",
				"parent directory %s does not exist and auto-create failed (err %d); call folder.create manually" % [parent_dir, mkdir_err])
		push_warning("MCP: auto-created directory %s for resource.write" % parent_dir)
		dirs_created = true
	var resolved_kind := ""
	var global_entry: Dictionary = {}
	if ClassDB.class_exists(resource_class):
		resolved_kind = "native"
	else:
		for entry in ProjectSettings.get_global_class_list():
			if str(entry.get("class", "")) == resource_class:
				resolved_kind = "global"
				global_entry = entry
				break
	if resolved_kind.is_empty():
		return MCPError.make("INVALID_CLASS",
			"unknown class %s; check ClassDB or ProjectSettings global class list" % resource_class, MCPError.HINT_CLASS_NAME)
	if not _class_descends_from(resource_class, "Resource"):
		return MCPError.make("NOT_A_RESOURCE",
			"%s is not a Resource subclass (base chain: %s)" % [
				resource_class, _class_base_chain(resource_class)])
	var resource: Resource = null
	if resolved_kind == "native":
		resource = ClassDB.instantiate(resource_class)
	else:
		var script_path := str(global_entry.get("path", ""))
		var script = load(script_path)
		if script == null:
			return MCPError.make("INVALID_CLASS",
				"could not load script for %s at %s" % [resource_class, script_path])
		resource = script.new()
	if resource == null:
		return MCPError.make("INVALID_CLASS",
			"instantiation returned null for %s" % resource_class)
	var warnings := _apply_resource_properties(resource, properties, resource_class)
	var save_error := ResourceSaver.save(resource, file_path)
	if save_error != OK:
		return MCPError.make("SAVE_FAILED",
			"ResourceSaver.save returned %d (path=%s)" % [save_error, file_path])
	var create_result := {
		"success": true,
		"status": "created",
		"path": file_path,
		"resource_class": resource_class,
		"warnings": warnings,
	}
	if dirs_created:
		create_result["dirs_created"] = true
	return create_result


static func _cmd_resource_delete(parameters: Dictionary) -> Dictionary:
	var err = MCPError.check_required(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	var extension := file_path.get_extension().to_lower()
	if not (extension in ["tres", "res"]):
		return MCPError.make("INVALID_PATH",
			"resource.delete only removes .tres or .res files (got %s); use scene.delete for .tscn, script.delete for .gd/.cs/.gdshader/.gdshaderinc, or a different tool for other file types" % file_path)
	if not FileAccess.file_exists(file_path):
		return MCPError.make("NOT_FOUND", "no file at %s" % file_path, MCPError.HINT_FILE_PATH)
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
