@tool
extends RefCounted
## classdb.* command handlers — ClassDB and global class introspection.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPCommandRegistry = _Hub.MCPCommandRegistry

const _VALID_SECTIONS: Array[String] = ["properties", "methods", "signals", "constants"]
const _MAX_ENTRIES_PER_SECTION := 200
const _MAX_SEARCH_RESULTS := 200


static func register(registry: MCPCommandRegistry, _server: Node) -> void:
	registry.add("classdb.get_info", func(parameters: Dictionary) -> Dictionary:
		return _cmd_classdb_get_info(parameters), "lite")
	registry.add("classdb.search", func(parameters: Dictionary) -> Dictionary:
		return _cmd_classdb_search(parameters), "lite")


# -- Command -----------------------------------------------------------------


static func _cmd_classdb_get_info(parameters: Dictionary) -> Dictionary:
	var cls: String = str(parameters.get("class_name", ""))
	if cls == "":
		return MCPError.make("INVALID_PARAMS", "class_name is required")

	var include_inherited: bool = bool(parameters.get("include_inherited", false))
	var sections: Array = parameters.get("sections", [])
	if typeof(sections) != TYPE_ARRAY:
		sections = []
	for s in sections:
		if str(s) not in _VALID_SECTIONS:
			return MCPError.make("INVALID_PARAMS",
				"invalid section '%s'; valid: %s" % [s, ", ".join(_VALID_SECTIONS)])

	var want_all := sections.is_empty()
	var want_properties := want_all or "properties" in sections
	var want_methods := want_all or "methods" in sections
	var want_signals := want_all or "signals" in sections
	var want_constants := want_all or "constants" in sections

	# Two-stage resolution: ClassDB (native engine classes) first,
	# then global class list (user-defined class_name classes).
	var is_native := ClassDB.class_exists(cls)
	var is_global := false
	var global_entry: Dictionary = {}
	var script_path := ""

	if not is_native:
		for entry in ProjectSettings.get_global_class_list():
			if entry.get("class", "") == cls:
				is_global = true
				global_entry = entry
				script_path = str(entry.get("path", ""))
				break

	if not is_native and not is_global:
		return MCPError.make("UNKNOWN_CLASS",
			"class not found in ClassDB or global class list: %s" % cls)

	var result: Dictionary = {"success": true, "class_name": cls}
	var truncated := false

	if is_native:
		result["source"] = "native"
		result["parent"] = ClassDB.get_parent_class(cls)
		result["inheritance_chain"] = _build_chain(cls)
		var no_inheritance := not include_inherited
		if want_properties:
			truncated = _add_properties_native(result, cls, no_inheritance) or truncated
		if want_methods:
			truncated = _add_methods_native(result, cls, no_inheritance) or truncated
		if want_signals:
			truncated = _add_signals_native(result, cls, no_inheritance) or truncated
		if want_constants:
			_add_constants_native(result, cls, no_inheritance)
	else:
		result["source"] = "global"
		result["script_path"] = script_path
		result["parent"] = str(global_entry.get("base", ""))
		result["inheritance_chain"] = _build_chain_global(cls, global_entry)
		var script := ResourceLoader.load(script_path) as Script
		if script == null:
			return MCPError.make("LOAD_FAILED",
				"could not load script at %s for class %s" % [script_path, cls])
		if want_properties:
			truncated = _add_properties_script(result, script) or truncated
		if want_methods:
			truncated = _add_methods_script(result, script) or truncated
		if want_signals:
			truncated = _add_signals_script(result, script) or truncated
		if want_constants:
			result["constants"] = {}
			result["enums"] = {}

	if truncated:
		result["truncated"] = true
	return result


static func _cmd_classdb_search(parameters: Dictionary) -> Dictionary:
	var base_class: String = str(parameters.get("base_class", ""))
	var pattern: String = str(parameters.get("pattern", ""))
	var instantiable_only: bool = bool(parameters.get("instantiable_only", true))
	var include_global: bool = bool(parameters.get("include_global", true))

	# Validate base_class exists if provided.
	if base_class != "":
		var base_exists := ClassDB.class_exists(base_class)
		if not base_exists:
			for entry in ProjectSettings.get_global_class_list():
				if entry.get("class", "") == base_class:
					base_exists = true
					break
		if not base_exists:
			return MCPError.make("UNKNOWN_CLASS",
				"base_class not found in ClassDB or global class list: %s" % base_class)

	var pattern_lower := pattern.to_lower()
	var matches: Array = []
	var total := 0

	# Native classes from ClassDB.
	for cls in ClassDB.get_class_list():
		if base_class != "" and cls != base_class \
				and not ClassDB.is_parent_class(cls, base_class):
			continue
		if pattern_lower != "" and cls.to_lower().find(pattern_lower) == -1:
			continue
		if instantiable_only and not ClassDB.can_instantiate(cls):
			continue
		total += 1
		if matches.size() < _MAX_SEARCH_RESULTS:
			matches.append({
				"name": cls,
				"parent": ClassDB.get_parent_class(cls),
				"instantiable": ClassDB.can_instantiate(cls),
				"source": "native",
			})

	# Global (user-defined class_name) classes.
	if include_global:
		for entry in ProjectSettings.get_global_class_list():
			var cls: String = str(entry.get("class", ""))
			var base: String = str(entry.get("base", ""))
			if cls == "":
				continue
			if base_class != "":
				if cls != base_class and base != base_class:
					var ancestor_match := false
					var current := base
					while current != "":
						if current == base_class:
							ancestor_match = true
							break
						if ClassDB.class_exists(current):
							current = ClassDB.get_parent_class(current)
						else:
							var found := false
							for g in ProjectSettings.get_global_class_list():
								if g.get("class", "") == current:
									current = str(g.get("base", ""))
									found = true
									break
							if not found:
								break
					if not ancestor_match:
						continue
			if pattern_lower != "" and cls.to_lower().find(pattern_lower) == -1:
				continue
			total += 1
			if matches.size() < _MAX_SEARCH_RESULTS:
				matches.append({
					"name": cls,
					"parent": base,
					"instantiable": true,
					"source": "global",
					"script_path": str(entry.get("path", "")),
				})

	# If neither filter was given, return only direct children of Object
	# to avoid dumping 1000+ classes.
	if base_class == "" and pattern == "":
		var top_level: Array = []
		for m in matches:
			if m["parent"] == "Object" or m["parent"] == "":
				top_level.append(m)
		top_level.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))
		return {
			"success": true,
			"count": top_level.size(),
			"classes": top_level,
			"_hint": "No filter provided; showing direct children of Object only. Use base_class or pattern to search.",
		}

	matches.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))
	var result: Dictionary = {
		"success": true,
		"count": matches.size(),
		"classes": matches,
	}
	if matches.size() < total:
		result["truncated"] = true
		result["total"] = total
	return result


# -- Inheritance chain -------------------------------------------------------


static func _build_chain(cls: String) -> Array[String]:
	var chain: Array[String] = []
	var current := cls
	while current != "":
		chain.append(current)
		current = ClassDB.get_parent_class(current)
	return chain


static func _build_chain_global(cls: String, entry: Dictionary) -> Array[String]:
	var chain: Array[String] = [cls]
	var current: String = str(entry.get("base", ""))
	while current != "":
		chain.append(current)
		if ClassDB.class_exists(current):
			current = ClassDB.get_parent_class(current)
		else:
			var found := false
			for g in ProjectSettings.get_global_class_list():
				if g.get("class", "") == current:
					current = str(g.get("base", ""))
					found = true
					break
			if not found:
				break
	return chain


# -- Native class sections ---------------------------------------------------


static func _add_properties_native(
	result: Dictionary, cls: String, no_inheritance: bool,
) -> bool:
	var raw := ClassDB.class_get_property_list(cls, no_inheritance)
	var out: Array = []
	var capped := false
	for p in raw:
		if out.size() >= _MAX_ENTRIES_PER_SECTION:
			capped = true
			break
		out.append({
			"name": p.get("name", ""),
			"type": p.get("type", 0),
			"hint": p.get("hint", 0),
			"hint_string": p.get("hint_string", ""),
		})
	result["properties"] = out
	return capped


static func _add_methods_native(
	result: Dictionary, cls: String, no_inheritance: bool,
) -> bool:
	var raw := ClassDB.class_get_method_list(cls, no_inheritance)
	var out: Array = []
	var capped := false
	for m in raw:
		if out.size() >= _MAX_ENTRIES_PER_SECTION:
			capped = true
			break
		out.append({
			"name": m.get("name", ""),
			"args": _format_args(m.get("args", [])),
			"return_type": _resolve_type(m.get("return", {}), true),
			"flags": m.get("flags", 0),
		})
	result["methods"] = out
	return capped


static func _add_signals_native(
	result: Dictionary, cls: String, no_inheritance: bool,
) -> bool:
	var raw := ClassDB.class_get_signal_list(cls, no_inheritance)
	var out: Array = []
	var capped := false
	for s in raw:
		if out.size() >= _MAX_ENTRIES_PER_SECTION:
			capped = true
			break
		out.append({
			"name": s.get("name", ""),
			"args": _format_args(s.get("args", [])),
		})
	result["signals"] = out
	return capped


static func _add_constants_native(
	result: Dictionary, cls: String, no_inheritance: bool,
) -> void:
	var constants: Dictionary = {}
	for c_name in ClassDB.class_get_integer_constant_list(cls, no_inheritance):
		constants[c_name] = ClassDB.class_get_integer_constant(cls, c_name)
	result["constants"] = constants

	var enums: Dictionary = {}
	for enum_name in ClassDB.class_get_enum_list(cls, no_inheritance):
		var members: Array[String] = []
		for ec in ClassDB.class_get_enum_constants(cls, enum_name, no_inheritance):
			members.append(ec)
		enums[enum_name] = members
	result["enums"] = enums


# -- Script (global class) sections ------------------------------------------


static func _add_properties_script(result: Dictionary, script: Script) -> bool:
	var raw := script.get_script_property_list()
	var out: Array = []
	var capped := false
	for p in raw:
		if out.size() >= _MAX_ENTRIES_PER_SECTION:
			capped = true
			break
		out.append({
			"name": p.get("name", ""),
			"type": p.get("type", 0),
			"hint": p.get("hint", 0),
			"hint_string": p.get("hint_string", ""),
		})
	result["properties"] = out
	return capped


static func _add_methods_script(result: Dictionary, script: Script) -> bool:
	var raw := script.get_script_method_list()
	var out: Array = []
	var capped := false
	for m in raw:
		if out.size() >= _MAX_ENTRIES_PER_SECTION:
			capped = true
			break
		out.append({
			"name": m.get("name", ""),
			"args": _format_args(m.get("args", [])),
			"return_type": _resolve_type(m.get("return", {}), true),
			"flags": m.get("flags", 0),
		})
	result["methods"] = out
	return capped


static func _add_signals_script(result: Dictionary, script: Script) -> bool:
	var raw := script.get_script_signal_list()
	var out: Array = []
	var capped := false
	for s in raw:
		if out.size() >= _MAX_ENTRIES_PER_SECTION:
			capped = true
			break
		out.append({
			"name": s.get("name", ""),
			"args": _format_args(s.get("args", [])),
		})
	result["signals"] = out
	return capped


# -- Shared formatting helpers -----------------------------------------------


static func _format_args(args: Array) -> Array:
	var out: Array = []
	for a in args:
		out.append({
			"name": a.get("name", ""),
			"type": _resolve_type(a, false),
		})
	return out


static func _resolve_type(info: Variant, is_return: bool) -> String:
	if typeof(info) != TYPE_DICTIONARY:
		return "void" if is_return else "Variant"
	var type_id: int = info.get("type", 0)
	if type_id == TYPE_OBJECT:
		var cls_name: String = str(info.get("class_name", ""))
		if cls_name != "":
			return cls_name
		return "Object"
	if type_id == TYPE_NIL:
		return "void" if is_return else "Variant"
	return type_string(type_id)
