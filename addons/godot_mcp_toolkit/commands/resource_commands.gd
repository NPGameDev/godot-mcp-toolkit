@tool
extends RefCounted
class_name ResourceCommands
## resource.* command handlers — load, create, save, delete for .tres/.res files.

const RESOURCE_SKIP_PROPERTIES: Array[String] = [
	"image", "mesh_arrays", "surface_arrays", "_data",
]


static func register(registry: MCPCommandRegistry, _server: Node) -> void:
	registry.add("resource.load", func(parameters: Dictionary) -> Dictionary:
		return _cmd_resource_load(parameters), "full")
	registry.add("resource.create", func(parameters: Dictionary) -> Dictionary:
		return _cmd_resource_create(parameters), "full")
	registry.add("resource.save", func(parameters: Dictionary) -> Dictionary:
		return _cmd_resource_save(parameters), "full")
	registry.add("resource.delete", func(parameters: Dictionary) -> Dictionary:
		return _cmd_resource_delete(parameters), "full")


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
	var file_path := str(parameters.get("path", ""))
	# TODO(iter-18): replace with FileGuard.resolve_safe(path).
	if not file_path.begins_with("res://"):
		return MCPError.make("PATH_DENIED", "path must start with res://: %s" % file_path)
	if not ResourceLoader.exists(file_path):
		return MCPError.make("NOT_FOUND", "resource not found: %s" % file_path)
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
		"properties": properties,
		"metadata": metadata,
	}


static func _cmd_resource_create(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("path", ""))
	var resource_class := str(parameters.get("resource_class", ""))
	var properties: Dictionary = parameters.get("properties", {}) \
		if typeof(parameters.get("properties", {})) == TYPE_DICTIONARY else {}
	var if_exists := str(parameters.get("if_exists", "return"))
	# TODO(iter-18): route file_path through FileGuard.resolve_safe.
	if not file_path.begins_with("res://"):
		return MCPError.make("INVALID_PATH",
			"path must start with res:// (got %s)" % file_path)
	var extension := file_path.get_extension().to_lower()
	if not (extension in ["tres", "res"]):
		return MCPError.make("INVALID_PATH",
			"resource.create only writes .tres (text) or .res (binary) files (got %s; use scene.create for .tscn, script.write for .gd/.cs)" % file_path)
	var parent_dir := file_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(parent_dir):
		return MCPError.make("PARENT_NOT_FOUND",
			"parent directory %s does not exist; call folder.create first (resource.create does not auto-create directories)" % parent_dir)
	if resource_class.is_empty():
		return MCPError.make("INVALID_PARAMS", "missing resource_class")

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
			"unknown class %s; checked ClassDB (engine classes) and ProjectSettings.get_global_class_list() (GDScript class_name + C# [GlobalClass])" % resource_class)
	if not _class_descends_from(resource_class, "Resource"):
		return MCPError.make("NOT_A_RESOURCE",
			"%s is not a Resource subclass (resolved base chain: %s); resource.create requires a Resource subclass — use scene.create for Node subclasses, script.write for source files" % [
				resource_class, _class_base_chain(resource_class)])
	if not (if_exists in ["return", "fail", "replace"]):
		return MCPError.make("INVALID_PARAMS",
			"if_exists must be one of 'return'|'fail'|'replace' (got %s); default is 'return'" % if_exists)

	var was_replace := false
	var previous_class := ""
	if FileAccess.file_exists(file_path):
		match if_exists:
			"return":
				return {"success": true, "status": "returned", "path": file_path}
			"fail":
				return MCPError.make("ALREADY_EXISTS",
					"file exists at %s; set if_exists:'replace' to overwrite" % file_path)
			"replace":
				was_replace = true
				var previous := ResourceLoader.load(file_path)
				previous_class = "<unreadable>" if previous == null else previous.get_class()
				push_warning("MCP: resource.create replacing %s (was class=%s, now class=%s)" % [
					file_path, previous_class, resource_class])

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

	var response := {
		"success": true,
		"path": file_path,
		"resource_class": resource_class,
		"warnings": warnings,
	}
	if was_replace:
		response["status"] = "replaced"
		response["previous_class"] = previous_class
	else:
		response["status"] = "created"
	return response


static func _cmd_resource_save(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("path", ""))
	var raw_properties = parameters.get("properties", null)
	if typeof(raw_properties) != TYPE_DICTIONARY:
		return MCPError.make("INVALID_PARAMS",
			"missing properties (must be an object)")
	var properties: Dictionary = raw_properties
	# TODO(iter-18): route file_path through FileGuard.resolve_safe.
	if not file_path.begins_with("res://"):
		return MCPError.make("INVALID_PATH",
			"path must start with res:// (got %s)" % file_path)
	var extension := file_path.get_extension().to_lower()
	if not (extension in ["tres", "res"]):
		return MCPError.make("INVALID_PATH",
			"resource.save only updates .tres (text) or .res (binary) files (got %s; use scene.create for .tscn, script.write for .gd/.cs)" % file_path)
	if not FileAccess.file_exists(file_path):
		return MCPError.make("NOT_FOUND",
			"no resource at %s; use resource.create to create" % file_path)
	var resource := ResourceLoader.load(file_path)
	if resource == null:
		return MCPError.make("NOT_A_RESOURCE",
			"file at %s is not a readable Resource (corrupt or wrong extension)" % file_path)
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


static func _cmd_resource_delete(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("path", ""))
	# TODO(iter-18): route file_path through FileGuard.resolve_safe.
	if not file_path.begins_with("res://"):
		return MCPError.make("INVALID_PATH",
			"path must start with res:// (got %s)" % file_path)
	var extension := file_path.get_extension().to_lower()
	if not (extension in ["tres", "res"]):
		return MCPError.make("INVALID_PATH",
			"resource.delete only removes .tres or .res files (got %s); use scene.delete for .tscn, script.delete for .gd/.cs/.gdshader/.gdshaderinc, or a different tool for other file types" % file_path)
	if not FileAccess.file_exists(file_path):
		return MCPError.make("NOT_FOUND", "no file at %s" % file_path)
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
