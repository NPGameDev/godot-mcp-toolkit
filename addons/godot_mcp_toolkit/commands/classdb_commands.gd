@tool
extends RefCounted
## classdb.* command handlers — ClassDB and global class introspection.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")

const _VALID_SECTIONS: Array[String] = ["properties", "methods", "signals", "constants"]
const _MAX_ENTRIES_PER_SECTION := 200
const _MAX_SEARCH_RESULTS := 200


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("classdb.get_info", func(parameters: Dictionary) -> Dictionary:
		return _cmd_classdb_get_info(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
	registry.add("classdb.search", func(parameters: Dictionary) -> Dictionary:
		return _cmd_classdb_search(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())


# -- Command -----------------------------------------------------------------


## Resolves the optional caller `limit` for a classdb page against [param hard_max].
## A missing limit defaults to [param hard_max] (behavior-preserving); a value above it
## clamps to [param hard_max] and flags the clamp; a non-positive value is rejected.
## Returns {"limit": <effective cap>, "clamped": <bool>, "error": null} on success, or
## {"error": <MCPToolkitError dict>} when the limit is out of range.
static func _resolve_limit(parameters: Dictionary, hard_max: int) -> Dictionary:
	if not parameters.has("limit"):
		return {"limit": hard_max, "clamped": false, "error": null}
	var requested := int(parameters.get("limit", hard_max))
	if requested < 1:
		return {"error": MCPToolkitError.fail("INVALID_PARAMS",
			"limit must be >= 1 (got %d)" % requested)}
	return {
		"limit": mini(requested, hard_max),
		"clamped": requested > hard_max,
		"error": null,
	}


static func _cmd_classdb_get_info(parameters: Dictionary) -> Dictionary:
	var cls: String = str(parameters.get("class_name", ""))
	if cls == "":
		return MCPToolkitError.fail("INVALID_PARAMS", "class_name is required")

	var include_inherited: bool = bool(parameters.get("include_inherited", false))
	var offset: int = maxi(int(parameters.get("offset", 0)), 0)
	var limit_res := _resolve_limit(parameters, _MAX_ENTRIES_PER_SECTION)
	if limit_res["error"] != null:
		return limit_res["error"]
	var section_cap: int = limit_res["limit"]
	var sections: Array = parameters.get("sections", [])
	if typeof(sections) != TYPE_ARRAY:
		sections = []
	for s in sections:
		if str(s) not in _VALID_SECTIONS:
			return MCPToolkitError.fail("INVALID_PARAMS",
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
		return MCPToolkitError.fail("UNKNOWN_CLASS",
			"class not found in ClassDB or global class list: %s" % cls, MCPToolkitError.HINT_CLASS_NAME)

	var result: Dictionary = {"class_name": cls}
	var has_more := false

	if is_native:
		result["source"] = "native"
		result["parent"] = ClassDB.get_parent_class(cls)
		result["inheritance_chain"] = _build_chain(cls)
		var no_inheritance := not include_inherited
		if want_properties:
			has_more = _add_property_section(result, ClassDB.class_get_property_list(cls, no_inheritance), offset, section_cap) or has_more
		if want_methods:
			has_more = _add_method_section(result, ClassDB.class_get_method_list(cls, no_inheritance), offset, section_cap) or has_more
		if want_signals:
			has_more = _add_signal_section(result, ClassDB.class_get_signal_list(cls, no_inheritance), offset, section_cap) or has_more
		if want_constants:
			has_more = _add_constants_native(result, cls, no_inheritance, offset, section_cap) or has_more
	else:
		result["source"] = "global"
		result["script_path"] = script_path
		result["parent"] = str(global_entry.get("base", ""))
		result["inheritance_chain"] = _build_chain_global(cls, global_entry)
		var script := ResourceLoader.load(script_path) as Script
		if script == null:
			return MCPToolkitError.fail("LOAD_FAILED",
				"could not load script at %s for class %s" % [script_path, cls])
		if want_properties:
			has_more = _add_property_section(result, script.get_script_property_list(), offset, section_cap) or has_more
		if want_methods:
			has_more = _add_method_section(result, script.get_script_method_list(), offset, section_cap) or has_more
		if want_signals:
			has_more = _add_signal_section(result, script.get_script_signal_list(), offset, section_cap) or has_more
		if want_constants:
			result["constants"] = {}
			result["total_constants"] = 0
			result["enums"] = {}
			result["total_enums"] = 0

	# has_more is ALWAYS present (false on a complete read). On a single-section
	# overflow the hint builder also adds a structured next_offset resume field.
	result["has_more"] = has_more
	if limit_res["clamped"]:
		result["limit_clamped"] = true
	if has_more:
		var hint := _build_truncation_hint(result, offset)
		if hint != "":
			result["hint"] = hint
	return MCPToolkitSuccess.ok(result)


static func _cmd_classdb_search(parameters: Dictionary) -> Dictionary:
	var base_class: String = str(parameters.get("base_class", ""))
	var pattern: String = str(parameters.get("pattern", ""))
	var instantiable_only: bool = bool(parameters.get("instantiable_only", true))
	var include_global: bool = bool(parameters.get("include_global", true))
	var offset: int = maxi(int(parameters.get("offset", 0)), 0)
	var limit_res := _resolve_limit(parameters, _MAX_SEARCH_RESULTS)
	if limit_res["error"] != null:
		return limit_res["error"]
	var page_cap: int = limit_res["limit"]

	if base_class != "":
		var base_exists := ClassDB.class_exists(base_class)
		if not base_exists:
			for entry in ProjectSettings.get_global_class_list():
				if entry.get("class", "") == base_class:
					base_exists = true
					break
		if not base_exists:
			return MCPToolkitError.fail("UNKNOWN_CLASS",
				"base_class not found in ClassDB or global class list: %s" % base_class, MCPToolkitError.HINT_CLASS_NAME)

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
		if total > offset and matches.size() < page_cap:
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
			if total > offset and matches.size() < page_cap:
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
		var top_page := Modules.Pagination.build(
			{"classes": top_level}, "classes", top_level.size(), top_level.size(),
			false, "", 0, "")
		# Informational nudge — shown regardless of paging, so it is set after the
		# envelope rather than through the builder's has_more-gated hint.
		top_page["hint"] = "No filter provided; showing direct children of Object only. Use base_class or pattern to search."
		return MCPToolkitSuccess.ok(top_page)

	matches.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))
	# Canonical fields: total_classes + has_more ALWAYS present; on more, the builder
	# adds the next_offset resume field beside the prose hint composed here.
	var has_more := offset + matches.size() < total
	var hint := ""
	if has_more:
		hint = "more classes remain — re-call classdb.search with offset = next_offset (%d) until has_more is false" % (offset + matches.size())
	var extras: Dictionary = {}
	if limit_res["clamped"]:
		extras["limit_clamped"] = true
		var clamp_clause := "requested limit exceeds max %d — page with next_offset to see the rest" % _MAX_SEARCH_RESULTS
		hint = clamp_clause if hint.is_empty() else "%s. %s" % [hint, clamp_clause]
	return MCPToolkitSuccess.ok(Modules.Pagination.list_page(
		{"classes": matches}, matches, offset, "classes", total, hint, extras))


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


# -- Section builders --------------------------------------------------------
# Each builder paginates a pre-fetched metadata list (`raw`) and writes its
# section + "total_<section>" into `result`. The caller supplies `raw` from
# whichever source applies — ClassDB.class_get_*_list() for native classes,
# script.get_script_*_list() for global (class_name) classes — so the builders
# depend only on the rows, not on how they were fetched.


static func _add_property_section(result: Dictionary, raw: Array, offset: int, cap: int) -> bool:
	var total := raw.size()
	result["total_properties"] = total
	var out: Array = []
	var skipped := 0
	for p in raw:
		if skipped < offset:
			skipped += 1
			continue
		if out.size() >= cap:
			break
		out.append({
			"name": p.get("name", ""),
			"type": p.get("type", 0),
			"hint": p.get("hint", 0),
			"hint_string": p.get("hint_string", ""),
		})
	result["properties"] = out
	return offset + out.size() < total


static func _add_method_section(result: Dictionary, raw: Array, offset: int, cap: int) -> bool:
	var total := raw.size()
	result["total_methods"] = total
	var out: Array = []
	var skipped := 0
	for m in raw:
		if skipped < offset:
			skipped += 1
			continue
		if out.size() >= cap:
			break
		out.append({
			"name": m.get("name", ""),
			"args": _format_args(m.get("args", [])),
			"return_type": _resolve_type(m.get("return", {}), true),
			"flags": m.get("flags", 0),
		})
	result["methods"] = out
	return offset + out.size() < total


static func _add_signal_section(result: Dictionary, raw: Array, offset: int, cap: int) -> bool:
	var total := raw.size()
	result["total_signals"] = total
	var out: Array = []
	var skipped := 0
	for s in raw:
		if skipped < offset:
			skipped += 1
			continue
		if out.size() >= cap:
			break
		out.append({
			"name": s.get("name", ""),
			"args": _format_args(s.get("args", [])),
		})
	result["signals"] = out
	return offset + out.size() < total


# -- Native-only sections (constants + enums; no script twin) -----------------


static func _add_constants_native(
	result: Dictionary, cls: String, no_inheritance: bool, offset: int, cap: int,
) -> bool:
	var const_list := ClassDB.class_get_integer_constant_list(cls, no_inheritance)
	var const_total := const_list.size()
	result["total_constants"] = const_total
	var constants: Dictionary = {}
	var skipped := 0
	for c_name in const_list:
		if skipped < offset:
			skipped += 1
			continue
		if constants.size() >= cap:
			break
		constants[c_name] = ClassDB.class_get_integer_constant(cls, c_name)
	result["constants"] = constants

	var enum_list := ClassDB.class_get_enum_list(cls, no_inheritance)
	var enum_total := enum_list.size()
	result["total_enums"] = enum_total
	var enums: Dictionary = {}
	var enum_skipped := 0
	for enum_name in enum_list:
		if enum_skipped < offset:
			enum_skipped += 1
			continue
		if enums.size() >= cap:
			break
		var members: Array[String] = []
		for ec in ClassDB.class_get_enum_constants(cls, enum_name, no_inheritance):
			members.append(ec)
		enums[enum_name] = members
	result["enums"] = enums
	return offset + constants.size() < const_total or offset + enums.size() < enum_total


# -- Truncation hint builder --------------------------------------------------


static func _build_truncation_hint(result: Dictionary, offset: int) -> String:
	var parts: Array[String] = []
	var single_section := ""
	var single_next_offset := 0
	for section in ["properties", "methods", "signals", "constants", "enums"]:
		var total_key: String = "total_" + section
		if not result.has(total_key):
			continue
		var total: int = result[total_key]
		var returned := 0
		if result.has(section):
			var val = result[section]
			if val is Array:
				returned = val.size()
			elif val is Dictionary:
				returned = val.size()
		var remaining := total - offset - returned
		if remaining > 0:
			parts.append("%d %s" % [remaining, section])
			single_section = section
			single_next_offset = offset + returned
	if parts.is_empty():
		return ""
	if parts.size() == 1:
		# Surface the resume field as a structured next_offset alongside the prose loop hint.
		result["next_offset"] = single_next_offset
		return "more %s remain — re-call classdb.get_info with offset = next_offset (%d) until has_more is false" % [
			single_section, single_next_offset]
	return "%s has more entries — page each section with sections + offset until has_more is false." % " + ".join(parts)


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
