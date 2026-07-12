@tool
extends RefCounted
## resource.* command handlers — load, write (create/update upsert), delete for .tres/.res files.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Coerce = Modules.Coerce
const FileGuard = Modules.FileGuard
const Untrusted = Modules.Untrusted
const Helpers = Modules.CommandHelpers

const RESOURCE_SKIP_PROPERTIES: Array[String] = [
	"image", "mesh_arrays", "surface_arrays", "_data",
]


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("resource.load", func(parameters: Dictionary) -> Dictionary:
		return _cmd_resource_load(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
	registry.add("resource.write", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_resource_write(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("resource.delete", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_resource_delete(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())


# -- Helpers ------------------------------------------------------------------


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
		var raw_value = properties[key]
		var missing := Coerce.check_resource_paths(raw_value)
		if missing != "":
			warnings.append(
				"property '%s': resource not found at %s; value left unchanged" % [key_string, missing])
			continue
		var coerced = Coerce.coerce_value(raw_value)
		if typeof(coerced) == TYPE_DICTIONARY and (coerced as Dictionary).has("_coerce_error"):
			warnings.append(
				"property '%s': %s; value left unchanged" % [key_string, str(coerced["_coerce_error"])])
			continue
		# Compound paths (e.g. "sources/0", "tiles/0:0/0") route through
		# Object._set() which many built-in types (TileSet, AnimationLibrary)
		# use for sub-resource slots not exposed in get_property_list().
		if "/" in key_string:
			var before = resource.get(key_string)
			resource.set(key_string, coerced)
			var after = resource.get(key_string)
			if typeof(after) == typeof(before) and after == before:
				if resource_class == "ShaderMaterial" and key_string.begins_with("shader_parameter/"):
					# shader_parameter/<name> is an inspector-only projection; Object.set()
					# on it does not reliably route to set_shader_parameter, and no-ops when
					# the uniform isn't declared or no shader is assigned.
					warnings.append(
						"property '%s' on ShaderMaterial: set() had no effect. Set shader uniforms via set_shader_parameter(name, value); ensure the ShaderMaterial has a shader assigned and the uniform is declared. The shader_parameter/<name> path is inspector-only." % key_string)
				else:
					warnings.append(
						"property '%s' on %s: set() had no effect (may need a different API)" % [key_string, resource_class])
		elif not valid.has(key_string):
			warnings.append(
				"property '%s' unknown on %s; value ignored" % [key_string, resource_class])
		else:
			resource.set(key_string, coerced)
	return warnings


# -- Commands -----------------------------------------------------------------


static func _cmd_resource_load(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if not ResourceLoader.exists(file_path):
		return MCPToolkitError.fail("NOT_FOUND", "resource not found: %s" % file_path, MCPToolkitError.HINT_FILE_PATH)
	var resource := ResourceLoader.load(file_path)
	if resource == null:
		return MCPToolkitError.fail("LOAD_FAILED",
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
		properties[property_name] = Coerce.serialize_value(resource.get(property_name))
	var metadata := {}
	if resource is Texture2D:
		metadata["width"] = resource.get_width()
		metadata["height"] = resource.get_height()
	return MCPToolkitSuccess.ok({
		"class": resource_class,
		"path": file_path,
		"properties": Untrusted.wrap(
			"resource", file_path, JSON.stringify(properties)),
		"metadata": metadata,
	})


static func _cmd_resource_write(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	var extension := file_path.get_extension().to_lower()
	if not (extension in ["tres", "res"]):
		return MCPToolkitError.fail("INVALID_PATH",
			"resource.write only writes .tres/.res files (got %s); use script.write for .gd/.cs" % file_path)
	var properties: Dictionary = parameters.get("properties", {}) \
		if typeof(parameters.get("properties", {})) == TYPE_DICTIONARY else {}
	if FileAccess.file_exists(file_path):
		var resource := ResourceLoader.load(file_path)
		if resource == null:
			return MCPToolkitError.fail("NOT_A_RESOURCE",
				"file at %s is not a readable Resource" % file_path)
		var resource_class := resource.get_class()
		var warnings := _apply_resource_properties(resource, properties, resource_class)
		# type only selects the class when creating; an existing file keeps its own
		# class. Disclose a passed type so it doesn't read as a silent retype.
		if parameters.has("type"):
			warnings.append("ignored type '%s' — resource already exists; type only applies when creating" % str(parameters.get("type", "")))
		var save_error := ResourceSaver.save(resource, file_path)
		if save_error != OK:
			return MCPToolkitError.fail("SAVE_FAILED",
				"ResourceSaver.save returned %d (path=%s)" % [save_error, file_path])
		# Refresh cache so subsequent ResourceRef loads get the updated version
		ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		var update_index := await Helpers.ensure_file_indexed(file_path)
		return MCPToolkitSuccess.ok({
			"path": file_path,
			"resource_class": resource_class,
			"warnings": warnings,
			"indexed": update_index["indexed"],
		})
	var resource_class := str(parameters.get("type", ""))
	if resource_class.is_empty():
		return MCPToolkitError.fail("NOT_FOUND",
			"resource not found at %s; provide 'type' to create it" % file_path, MCPToolkitError.HINT_FILE_PATH)
	var dir_result := Helpers.ensure_parent_dir(file_path, "resource.write")
	if dir_result.has("error"):
		return dir_result
	var dirs_created: bool = dir_result["dirs_created"]
	var rk := Helpers.resolve_class_kind(resource_class)
	var resolved_kind: String = rk["kind"]
	var global_entry: Dictionary = rk["entry"]
	if resolved_kind.is_empty():
		return MCPToolkitError.fail("INVALID_CLASS",
			"unknown class %s; check ClassDB or ProjectSettings global class list" % resource_class, MCPToolkitError.HINT_CLASS_NAME)
	if not Helpers.class_descends_from(resource_class, "Resource"):
		return MCPToolkitError.fail("NOT_A_RESOURCE",
			"%s is not a Resource subclass (base chain: %s)" % [
				resource_class, Helpers.class_base_chain(resource_class)])
	var resource: Resource = null
	if resolved_kind == "native":
		resource = ClassDB.instantiate(resource_class)
	else:
		var script_path := str(global_entry.get("path", ""))
		var script = load(script_path)
		if script == null:
			return MCPToolkitError.fail("INVALID_CLASS",
				"could not load script for %s at %s" % [resource_class, script_path])
		resource = script.new()
	if resource == null:
		return MCPToolkitError.fail("INVALID_CLASS",
			"instantiation returned null for %s" % resource_class)
	var warnings := _apply_resource_properties(resource, properties, resource_class)
	var save_error := ResourceSaver.save(resource, file_path)
	if save_error != OK:
		return MCPToolkitError.fail("SAVE_FAILED",
			"ResourceSaver.save returned %d (path=%s)" % [save_error, file_path])
	# Refresh cache so subsequent ResourceRef loads get the new resource
	ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	var create_index := await Helpers.ensure_file_indexed(file_path)
	var create_result := {
		"status": "created",
		"path": file_path,
		"resource_class": resource_class,
		"warnings": warnings,
		"indexed": create_index["indexed"],
	}
	if dirs_created:
		create_result["dirs_created"] = true
	return MCPToolkitSuccess.ok(create_result)


static func _cmd_resource_delete(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	var extension := file_path.get_extension().to_lower()
	if not (extension in ["tres", "res"]):
		return MCPToolkitError.fail("INVALID_PATH",
			"resource.delete only removes .tres or .res files (got %s); use scene.delete for .tscn, script.delete for .gd/.cs/.gdshader/.gdshaderinc, or a different tool for other file types" % file_path)
	if not FileAccess.file_exists(file_path):
		return MCPToolkitError.fail("NOT_FOUND", "no file at %s" % file_path, MCPToolkitError.HINT_FILE_PATH)
	var delete_result: Dictionary = await Helpers.delete_res_file_and_deindex(file_path)
	return delete_result
