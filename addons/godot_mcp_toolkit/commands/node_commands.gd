@tool
extends RefCounted
## node.* command handlers — property get/set/list, method calls, script attachment.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const Coerce = _Hub.Coerce
const FileGuard = _Hub.FileGuard
const Helpers = _Hub.Helpers


const COMMON_PROPERTIES_BY_CLASS := {
	"Node": ["name", "process_mode"],
	"Node2D": ["position", "rotation", "scale", "z_index", "visible", "modulate"],
	"Node3D": ["position", "rotation", "scale", "visible"],
	"Control": ["position", "size", "anchor_left", "anchor_right", "anchor_top",
		"anchor_bottom", "visible", "modulate", "size_flags_horizontal", "size_flags_vertical"],
	"Sprite2D": ["texture", "centered", "offset", "flip_h", "flip_v", "hframes", "vframes", "frame"],
	"Sprite3D": ["texture", "centered", "offset", "flip_h", "flip_v"],
	"CollisionShape2D": ["shape", "disabled"],
	"CollisionShape3D": ["shape", "disabled"],
	"RigidBody2D": ["mass", "gravity_scale", "linear_velocity", "angular_velocity"],
	"RigidBody3D": ["mass", "gravity_scale", "linear_velocity", "angular_velocity"],
	"CharacterBody2D": ["velocity", "floor_max_angle", "up_direction"],
	"CharacterBody3D": ["velocity", "floor_max_angle", "up_direction"],
	"Camera2D": ["zoom", "offset", "position_smoothing_enabled"],
	"Camera3D": ["fov", "near", "far", "current"],
	"Area2D": ["monitoring", "monitorable", "gravity"],
	"Area3D": ["monitoring", "monitorable", "gravity"],
	"AnimationPlayer": ["current_animation", "autoplay", "speed_scale"],
	"Timer": ["wait_time", "one_shot", "autostart"],
	"Label": ["text", "horizontal_alignment", "vertical_alignment", "autowrap_mode"],
	"Button": ["text", "disabled", "flat"],
	"TextureRect": ["texture", "stretch_mode"],
	"AudioStreamPlayer": ["stream", "volume_db", "pitch_scale", "autoplay"],
	"AudioStreamPlayer2D": ["stream", "volume_db", "pitch_scale", "max_distance"],
	"AudioStreamPlayer3D": ["stream", "volume_db", "pitch_scale", "max_distance"],
	"MeshInstance3D": ["mesh", "material_override"],
	"Light2D": ["energy", "color", "shadow_enabled"],
	"DirectionalLight3D": ["light_energy", "light_color", "shadow_enabled"],
	"GPUParticles2D": ["process_material", "emitting", "amount", "lifetime"],
	"GPUParticles3D": ["process_material", "emitting", "amount", "lifetime"],
	"LineEdit": ["text", "placeholder_text", "editable", "max_length"],
	"TextEdit": ["text", "editable"],
	"RichTextLabel": ["text", "bbcode_enabled"],
}


static func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:
	registry.add("node.get_property", func(parameters: Dictionary) -> Dictionary:
		return _cmd_node_get_property(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only())
	registry.add("node.set_property", func(parameters: Dictionary) -> Dictionary:
		return _cmd_node_set_property(server, parameters)
	, MCPToolkitCommandOptions.new())
	registry.add("node.get_property_list", func(parameters: Dictionary) -> Dictionary:
		return _cmd_node_get_property_list(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only())
	registry.add("node.call_method", func(parameters: Dictionary) -> Dictionary:
		return _cmd_node_call_method(parameters)
	, MCPToolkitCommandOptions.new())
	registry.add("node.set_script", func(parameters: Dictionary) -> Dictionary:
		return _cmd_node_set_script(parameters)
	, MCPToolkitCommandOptions.new())
	registry.add("node.manage", func(parameters: Dictionary) -> Dictionary:
		return _cmd_node_manage(parameters)
	, MCPToolkitCommandOptions.new())
	registry.add("node.groups", func(parameters: Dictionary) -> Dictionary:
		return _cmd_node_groups(parameters)
	, MCPToolkitCommandOptions.new())
	registry.add("node.collision_from_sprite", func(parameters: Dictionary) -> Dictionary:
		return _cmd_collision_from_sprite(parameters)
	, MCPToolkitCommandOptions.new())
	registry.add("control.set_layout", func(parameters: Dictionary) -> Dictionary:
		return _cmd_control_set_layout(parameters)
	, MCPToolkitCommandOptions.new())


# -- Helpers ------------------------------------------------------------------


static func _get_edited_root() -> Node:
	return Helpers.get_edited_root()


static func _resolve_scene_node(node_path: String) -> Variant:
	return Helpers.resolve_scene_node(node_path)


## Detect silent compound-path set failure by comparing readback to expected.
static func _iscompound_set_failure(expected: Variant, actual: Variant) -> bool:
	if expected == null:
		return false  # Setting null — nothing to verify
	if actual == null:
		return true  # Expected non-null, got null
	if typeof(actual) == TYPE_DICTIONARY and (actual as Dictionary).is_empty():
		if expected is Resource:
			return true  # Expected resource, got empty dict
		if typeof(expected) == TYPE_DICTIONARY and not (expected as Dictionary).is_empty():
			return true  # Expected populated dict, got empty dict
	return false


## Short string representation of a value for warning messages.
static func _brief_value(value: Variant) -> String:
	if value == null:
		return "null"
	if typeof(value) == TYPE_DICTIONARY and (value as Dictionary).is_empty():
		return "{} (empty)"
	var s := var_to_str(value)
	if s.length() > 60:
		s = s.left(57) + "..."
	return s


# -- Commands -----------------------------------------------------------------


static func _cmd_node_get_property(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return MCPToolkitError.fail("NO_SCENE", "no edited scene")

	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)
	var property_name := str(parameters.get("property", ""))

	if node_path.is_empty() or property_name.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing node_path or property")

	var node := root.get_node_or_null(node_path)
	if node == null:
		return MCPToolkitError.fail("NOT_FOUND", "node not found: %s" % node_path, MCPToolkitError.HINT_NODE_PATH)

	# Compound paths (colon-chained sub-resource paths like
	# "material:shader_parameter/value") use the centralized handler which
	# tries node-level override first, then falls back to sub-resource read.
	if ":" in property_name:
		var result := Helpers.get_property_compound(node, property_name)
		if not result.get("ok", false):
			return MCPToolkitError.fail(
				result.get("code", "NOT_FOUND"),
				str(result.get("error", "")))
		return MCPToolkitSuccess.ok({"value": result["value"]})

	return MCPToolkitSuccess.ok({"value": Coerce.serialize_value(node.get(property_name))})


static func _cmd_node_set_property(server: Node, parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return MCPToolkitError.fail("NO_SCENE", "no edited scene")

	# FIX-7: Batch mode — set multiple properties in a single UndoRedo action.
	var batch_raw = parameters.get("batch", null)
	if batch_raw != null and typeof(batch_raw) == TYPE_ARRAY and (batch_raw as Array).size() > 0:
		return _batch_set_properties(server, root, batch_raw as Array)

	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)
	var property_name := str(parameters.get("property", ""))
	var raw_value = parameters.get("value", null)

	if node_path.is_empty() or property_name.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing node_path or property")

	var node := root.get_node_or_null(node_path)
	if node == null:
		return MCPToolkitError.fail("NOT_FOUND", "node not found: %s" % node_path, MCPToolkitError.HINT_NODE_PATH)

	# P-002: "groups" is not a regular property — it lives in the .tscn node
	# header and must be set via add_to_group / remove_from_group.
	if property_name == "groups":
		var new_groups: Array = []
		if typeof(raw_value) == TYPE_ARRAY:
			for g in raw_value:
				new_groups.append(str(g))
		elif typeof(raw_value) == TYPE_STRING:
			new_groups.append(str(raw_value))
		else:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"groups value must be a string or array of strings")
		var old_groups: Array = []
		for g in node.get_groups():
			var gs := str(g)
			if not gs.begins_with("_"):  # skip engine-internal groups
				old_groups.append(gs)
		for g in old_groups:
			if g not in new_groups:
				node.remove_from_group(g)
		for g in new_groups:
			if g not in old_groups:
				node.add_to_group(g, true)
		var action = MCPToolkitUndoRedoAction.begin("set %s groups" % node_path, node)
		for g in old_groups:
			if g not in new_groups:
				action.do_method(node.remove_from_group.bind(g))
				action.undo_method(node.add_to_group.bind(g, true))
		for g in new_groups:
			if g not in old_groups:
				action.do_method(node.add_to_group.bind(g, true))
				action.undo_method(node.remove_from_group.bind(g))
		action.commit_recorded()
		return MCPToolkitSuccess.ok({"groups": new_groups})

	# Compound / colon-chained paths (e.g. "libraries/test",
	# "material:shader_parameter/value", "theme_override_colors/font_color").
	# Centralized handler in editor_helpers.gd handles sub-resource navigation,
	# shader_parameter/ dedicated setter, value coercion, and readback.
	# Returns _undo info for UndoRedo registration (commit_recorded()).
	if ":" in property_name or "/" in property_name:
		var do_unique := bool(parameters.get("make_unique", false))
		var result := Helpers.set_property_compound(
			node, property_name, raw_value, do_unique)
		if not result.get("ok", false):
			return MCPToolkitError.fail(
				result.get("code", "INVALID_VALUE"),
				str(result.get("error", "")))

		# Register UndoRedo for compound paths. All do/undo methods route
		# through server.undo_helpers.compound_set for consistent
		# EditorUndoRedoManager context (avoids history mismatch errors).
		var ui: Dictionary = result.get("_undo", {})
		var undo_type: String = str(ui.get("type", ""))
		if undo_type != "":
			var undo_path: String = ui["path"]
			var new_val = ui.get("new", node.get(undo_path))
			var action = MCPToolkitUndoRedoAction.begin("set %s.%s" % [node_path, property_name], node)
			action.do_method(server.undo_helpers.compound_set.bind(
				node, undo_path, new_val))
			action.undo_method(server.undo_helpers.compound_set.bind(
				node, undo_path, ui["old"]))
			# make_unique: undo restores original external resource.
			if ui.has("old_resource_prop"):
				var res_prop: String = ui["old_resource_prop"]
				var new_res = node.get(res_prop)
				action.do_method(server.undo_helpers.compound_set.bind(
					node, res_prop, new_res))
				action.undo_method(server.undo_helpers.compound_set.bind(
					node, res_prop, ui["old_resource"]))
				if new_res is Resource:
					action.do_reference(new_res)
				if ui["old_resource"] is Resource:
					action.undo_reference(ui["old_resource"])
			action.commit_recorded()

		var response := {}
		if result.has("made_unique"):
			response["made_unique"] = result["made_unique"]
		if result.has("warning"):
			response["warning"] = result["warning"]
		return MCPToolkitSuccess.ok(response)

	var coerce_result := Helpers.coerce_for_property(node, property_name, raw_value)
	if not coerce_result.get("ok", false):
		return MCPToolkitError.fail(
			coerce_result.get("code", "INVALID_VALUE"),
			str(coerce_result.get("error", "")))
	var coerced = coerce_result["value"]

	var old_value = node.get(property_name)

	node.set(property_name, coerced)
	var action = MCPToolkitUndoRedoAction.begin("set %s.%s" % [node_path, property_name], node)
	action.do_property(node, property_name, coerced)
	action.undo_property(node, property_name, old_value)
	if coerced is Resource:
		action.do_reference(coerced)
	if old_value is Resource:
		action.undo_reference(old_value)
	action.commit_recorded()
	# FIX-F: Detect bare res:// strings silently failing on Resource-typed properties.
	if typeof(raw_value) == TYPE_STRING and str(raw_value).begins_with("res://") \
			and not (coerced is Resource):
		var readback = node.get(property_name)
		if not (readback is String):
			return MCPToolkitError.fail("INVALID_VALUE",
				"property '%s' expects a Resource, not a bare string path. " % property_name +
				"Use {\"type\": \"Resource\", \"path\": \"%s\"} as the value." % str(raw_value))
	return MCPToolkitSuccess.ok()


## FIX-7: Batch set multiple properties in one UndoRedo action.
## Compound paths (: or /) use set_property_compound() and add their undo
## info to the same batch action when possible (property-type paths only).
static func _batch_set_properties(server: Node, root: Node, entries: Array) -> Dictionary:
	var action = MCPToolkitUndoRedoAction.begin("batch set %d properties" % entries.size(), root)

	var results: Array = []
	for entry in entries:
		if typeof(entry) != TYPE_DICTIONARY:
			results.append({"success": false, "error": "entry must be an object"})
			continue
		var np := str(entry.get("node_path", ""))
		np = Helpers.normalize_editor_path(np)
		var prop := str(entry.get("property", ""))
		var raw_val = entry.get("value", null)

		if np.is_empty() or prop.is_empty():
			results.append({"node_path": np, "property": prop,
				"success": false, "error": "missing node_path or property"})
			continue

		var node := root.get_node_or_null(np)
		if node == null:
			results.append({"node_path": np, "property": prop,
				"success": false, "error": "node not found"})
			continue

		# Compound paths: route through set_property_compound() which handles
		# colon→slash conversion, sub-resource navigation, and readback.
		# All compound undo uses server.undo_helpers.compound_set to keep
		# the entire batch in a consistent EditorUndoRedoManager context.
		if ":" in prop or "/" in prop:
			var do_unique := bool(entry.get("make_unique", false))
			var result := Helpers.set_property_compound(
				node, prop, raw_val, do_unique)
			if result.get("ok", false):
				var ui: Dictionary = result.get("_undo", {})
				var undo_type: String = str(ui.get("type", ""))
				if undo_type != "":
					var undo_path: String = ui["path"]
					var new_val = ui.get("new", node.get(undo_path))
					action.do_method(server.undo_helpers.compound_set.bind(
						node, undo_path, new_val))
					action.undo_method(server.undo_helpers.compound_set.bind(
						node, undo_path, ui["old"]))
					if ui.has("old_resource_prop"):
						var res_prop: String = ui["old_resource_prop"]
						var new_res = node.get(res_prop)
						action.do_method(server.undo_helpers.compound_set.bind(
							node, res_prop, new_res))
						action.undo_method(server.undo_helpers.compound_set.bind(
							node, res_prop, ui["old_resource"]))
						if new_res is Resource:
							action.do_reference(new_res)
						if ui["old_resource"] is Resource:
							action.undo_reference(ui["old_resource"])
				var res_entry := {"node_path": np, "property": prop, "success": true}
				if result.has("made_unique"):
					res_entry["made_unique"] = result["made_unique"]
				if result.has("warning"):
					res_entry["warning"] = result["warning"]
				results.append(res_entry)
			else:
				results.append({"node_path": np, "property": prop,
					"success": false, "error": str(result.get("error", ""))})
			continue

		var missing := Coerce.check_resource_paths(raw_val)
		if missing != "":
			results.append({"node_path": np, "property": prop,
				"success": false, "error": "resource not found: %s" % missing})
			continue

		var coerced = Coerce.coerce_value(raw_val)
		if typeof(coerced) == TYPE_DICTIONARY and (coerced as Dictionary).has("_coerce_error"):
			results.append({"node_path": np, "property": prop,
				"success": false, "error": str(coerced["_coerce_error"])})
			continue

		var old_value = node.get(prop)
		if typeof(old_value) == TYPE_NODE_PATH and typeof(coerced) == TYPE_STRING:
			coerced = NodePath(str(coerced))

		# Apply mutation unconditionally, then record for undo.
		node.set(prop, coerced)
		action.do_method(server.undo_helpers.compound_set.bind(node, prop, coerced))
		action.undo_method(server.undo_helpers.compound_set.bind(node, prop, old_value))
		if coerced is Resource:
			action.do_reference(coerced)
		if old_value is Resource:
			action.undo_reference(old_value)
		results.append({"node_path": np, "property": prop, "success": true})

	action.commit_recorded()

	# Aggregate warnings for non-persisting external sub-resource mutations.
	var non_persisting: PackedStringArray = []
	for r in results:
		if r.has("warning"):
			non_persisting.append(str(r.get("property", "")))
	var response := {"results": results}
	if non_persisting.size() > 0:
		response["warning"] = (
			"These compound paths were set on shared external sub-resources "
			+ "and may not persist after save/reload: %s. " % ", ".join(non_persisting)
			+ "Retry those entries with make_unique: true to auto-duplicate "
			+ "them as inline copies that persist.")
	return MCPToolkitSuccess.ok(response)


static func _resolve_common_property_names(node: Object) -> Array[String]:
	var result: Array[String] = []
	var current := node.get_class()
	var depth := 0
	while not current.is_empty() and depth < 16:
		if COMMON_PROPERTIES_BY_CLASS.has(current):
			for prop_name in COMMON_PROPERTIES_BY_CLASS[current]:
				if prop_name not in result:
					result.append(prop_name)
		if ClassDB.class_exists(current):
			current = ClassDB.get_parent_class(current)
		else:
			break
		depth += 1
	return result


static func _cmd_node_get_property_list(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return MCPToolkitError.fail("NO_SCENE", "no edited scene")
	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)
	var node = _resolve_scene_node(node_path)
	if node == null:
		return MCPToolkitError.fail("NOT_FOUND", "node not found: %s" % node_path, MCPToolkitError.HINT_NODE_PATH)
	var mask := str(parameters.get("mask", "common"))
	if not (mask in ["common", "all", "groups", "script"]):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"mask must be 'common', 'all', 'groups', or 'script' (got '%s')" % mask)
	var visibility_filter := str(parameters.get("visibility", "all"))
	if mask == "script" and not (visibility_filter in ["public", "private", "all"]):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"visibility must be 'public', 'private', or 'all' (got '%s')" % visibility_filter)
	var common_names: Array[String] = []
	if mask == "common":
		common_names = _resolve_common_property_names(node)
	var properties: Array = []
	if mask == "script":
		# Use Script.get_script_property_list() directly — it works for both
		# @tool and non-@tool scripts, unlike node.get_property_list() which
		# may omit PROPERTY_USAGE_SCRIPT_VARIABLE for non-@tool scripts.
		var script: Script = node.get_script() as Script
		if script != null:
			for property in script.get_script_property_list():
				var usage: int = int(property.get("usage", 0))
				if not (usage & PROPERTY_USAGE_EDITOR):
					continue
				var property_name := str(property.get("name", ""))
				if property_name.is_empty():
					continue
				var vis := "private" if property_name.begins_with("_") else "public"
				if visibility_filter != "all" and vis != visibility_filter:
					continue
				properties.append({
					"name": property_name,
					"type": int(property.get("type", 0)),
					"hint": int(property.get("hint", 0)),
					"hint_string": str(property.get("hint_string", "")),
					"visibility": vis,
				})
	else:
		for property in node.get_property_list():
			var usage: int = int(property.get("usage", 0))
			var property_name := str(property.get("name", ""))
			if property_name.is_empty():
				continue
			if not (usage & PROPERTY_USAGE_EDITOR):
				continue
			if property_name.begins_with("_"):
				continue
			if mask == "common" and property_name not in common_names:
				continue
			if mask == "groups":
				properties.append({
					"name": property_name,
					"usage": usage,
				})
			else:
				properties.append({
					"name": property_name,
					"type": int(property.get("type", 0)),
					"hint": int(property.get("hint", 0)),
					"hint_string": str(property.get("hint_string", "")),
				})
	return MCPToolkitSuccess.ok({
		"path": node_path,
		"class": node.get_class(),
		"mask": mask,
		"properties": properties,
		"count": properties.size(),
	})


## 41m-bis-bis: returns the version-tailored stale-live-instance recovery hint when
## the target node's ON-DISK .gd defines `method_name` (and compiles) but the live
## instance lacks it on Godot < 4.4 — i.e. the instance is stale, not the call wrong.
## "" otherwise (no script / non-.gd / method genuinely absent / disk won't compile /
## 4.4+). The pure decision lives in StaleInstanceHint; this just reads the running
## version + the on-disk source. Called only on the INVALID_METHOD error path.
static func _stale_method_hint(node: Object, method_name: String) -> String:
	var scr = node.get_script()
	if scr == null:
		return ""
	var scr_path := str(scr.resource_path)
	if not scr_path.to_lower().ends_with(".gd") or not FileAccess.file_exists(scr_path):
		return ""
	var disk_source := FileAccess.get_file_as_string(scr_path)
	var vi := Engine.get_version_info()
	var minor := int(vi["minor"])
	var disk_has := _Hub.StaleInstanceHint.source_has_method(disk_source, method_name)
	var disk_ok := _Hub.StaleInstanceHint.source_compiles(disk_source)
	if not _Hub.StaleInstanceHint.should_hint_on_call(false, disk_has, disk_ok, true, int(vi["major"]), minor):
		return ""
	return _Hub.StaleInstanceHint.recovery_message("%d.%d" % [int(vi["major"]), minor])


static func _cmd_node_call_method(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return MCPToolkitError.fail("NO_SCENE", "no open scene; use scene.open or scene.create first")

	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)
	var method_name := str(parameters.get("method_name", ""))
	var args_raw = parameters.get("args", [])
	# Resource refs in args are validated via Coerce.check_resource_paths,
	# which gates through FileGuard. node_path is a scene-tree path, not filesystem.

	if node_path.is_empty() or method_name.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing node_path or method_name")
	if typeof(args_raw) != TYPE_ARRAY:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"args must be an Array (got %s)" % typeof(args_raw))

	var node := root.get_node_or_null(node_path)
	if node == null:
		return MCPToolkitError.fail("NOT_FOUND",
			"no node at path %s. This tool is editor-only — for runtime nodes use execute_code or runtime_get_node_state." % node_path)
	if not node.has_method(method_name):
		var no_method_msg := "node %s has no method '%s'; use scene.get_tree or inspect the script class via ClassDB" % [
			node_path, method_name]
		var stale_hint := _stale_method_hint(node, method_name)
		if stale_hint != "":
			return MCPToolkitError.fail("INVALID_METHOD", no_method_msg, stale_hint)
		return MCPToolkitError.fail("INVALID_METHOD", no_method_msg)

	var missing := Coerce.check_resource_paths(args_raw)
	if missing != "":
		return MCPToolkitError.fail("LOAD_FAILED",
			"failed to load resource at %s; verify the path or use resource.write to create it first" % missing)

	var coerced_args = Coerce.coerce_value(args_raw)
	if typeof(coerced_args) != TYPE_ARRAY:
		coerced_args = []
	for arg in coerced_args:
		if typeof(arg) == TYPE_DICTIONARY and (arg as Dictionary).has("_coerce_error"):
			return MCPToolkitError.fail("INVALID_PARAMS", str(arg["_coerce_error"]))
	print("[MCPTools] node.call_method invoked %s.%s(%d args)" % [
		node_path, method_name, (coerced_args as Array).size()])
	var result = node.callv(method_name, coerced_args)

	var response := {
		"path": node_path,
		"method": method_name,
		"result": Coerce.serialize_value(result),
	}
	if result == null:
		var script = node.get_script()
		if script != null and script.resource_path.ends_with(".cs"):
			response["hint"] = "Return value was null. C# methods cannot execute in editor mode without the [Tool] attribute — Godot registers the method signature but does not instantiate the managed .NET object. Properties and signals work normally. Use game.start + execute_code to call C# methods at runtime, or set state via node.set_property (most C# logic runs in _Ready() at startup)."
		else:
			response["hint"] = "Return value was null. Editor-side callv() on non-@tool scripts may return null if the method relies on uninitialized state (_Ready() has not run). Use game.start + runtime tools (runtime_get_node_state, execute_code) to drive and observe runtime state."
	return MCPToolkitSuccess.ok(response)


static func _cmd_node_set_script(parameters: Dictionary) -> Dictionary:
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

	var script_path := str(parameters.get("script_path", ""))

	if script_path.is_empty():
		var old_script = node.get_script()
		node.set_script(null)
		var clear_action = MCPToolkitUndoRedoAction.begin("clear script on %s" % node_path, node)
		clear_action.do_property(node, &"script", null)
		clear_action.undo_property(node, &"script", old_script)
		if old_script is Resource:
			clear_action.undo_reference(old_script)
		clear_action.commit_recorded()
		return MCPToolkitSuccess.ok({"path": node_path, "script": null, "properties": []})

	var guard := FileGuard.resolve_safe(script_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))

	var loaded = ResourceLoader.load(script_path)
	if loaded == null:
		return MCPToolkitError.fail("LOAD_FAILED",
			"cannot load script at %s; verify the path or use script.write to create it first" % script_path)
	if not (loaded is Script):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"resource at %s is not a Script (got %s)" % [script_path, loaded.get_class()])

	var old_script = node.get_script()
	node.set_script(loaded)
	var set_action = MCPToolkitUndoRedoAction.begin("set script %s on %s" % [script_path, node_path], node)
	set_action.do_property(node, &"script", loaded)
	set_action.undo_property(node, &"script", old_script)
	set_action.do_reference(loaded)
	if old_script is Resource:
		set_action.undo_reference(old_script)
	set_action.commit_recorded()

	var exports: Array = []
	for property in loaded.get_script_property_list():
		var usage: int = int(property.get("usage", 0))
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		var property_name := str(property.get("name", ""))
		if property_name.is_empty() or property_name.begins_with("_"):
			continue
		exports.append({
			"name": property_name,
			"type": int(property.get("type", 0)),
			"hint": int(property.get("hint", 0)),
			"hint_string": str(property.get("hint_string", "")),
		})

	return MCPToolkitSuccess.ok({"path": node_path, "script": script_path, "properties": exports})


static func _cmd_node_manage(parameters: Dictionary) -> Dictionary:
	var action := str(parameters.get("action", ""))
	if action.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing action (rename|reparent|reorder|duplicate)")

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

	match action:
		"rename":
			return _manage_rename(root, node, node_path, parameters)
		"reparent":
			return _manage_reparent(root, node, node_path, parameters)
		"reorder":
			return _manage_reorder(root, node, node_path, parameters)
		"duplicate":
			return _manage_duplicate(root, node, node_path, parameters)
		_:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"unknown action '%s'; must be rename|reparent|reorder|duplicate" % action)


static func _manage_rename(
	root: Node, node: Node, node_path: String, parameters: Dictionary,
) -> Dictionary:
	var new_name := str(parameters.get("new_name", ""))
	if new_name.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "rename requires new_name")
	if node == root:
		return MCPToolkitError.fail("INVALID_PATH", "cannot rename the scene root")

	var old_name := String(node.name)
	node.name = new_name
	MCPToolkitUndoRedoAction.begin("rename %s -> %s" % [old_name, new_name], node) \
		.do_property(node, &"name", new_name) \
		.undo_property(node, &"name", old_name) \
		.commit_recorded()

	var parent := node.get_parent()
	var new_path := str(root.get_path_to(node))
	return MCPToolkitSuccess.ok({"action": "rename", "old_name": old_name,
		"new_name": String(node.name), "new_path": new_path})


static func _manage_reparent(
	root: Node, node: Node, node_path: String, parameters: Dictionary,
) -> Dictionary:
	var new_parent_path := str(parameters.get("new_parent_path", ""))
	new_parent_path = Helpers.normalize_editor_path(new_parent_path)
	if new_parent_path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "reparent requires new_parent_path")
	if node == root:
		return MCPToolkitError.fail("INVALID_PATH", "cannot reparent the scene root")

	var new_parent := root.get_node_or_null(new_parent_path)
	if new_parent == null:
		return MCPToolkitError.fail("NOT_FOUND",
			"new parent not found: %s" % new_parent_path, MCPToolkitError.HINT_NODE_PATH)
	# Prevent reparenting a node under itself (would create a cycle).
	if new_parent == node or node.is_ancestor_of(new_parent):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"cannot reparent a node under itself or a descendant")

	var keep_global := bool(parameters.get("keep_global_transform", true))
	var old_parent := node.get_parent()
	var old_index := node.get_index()

	node.reparent(new_parent, keep_global)
	node.set_owner(root)
	MCPToolkitUndoRedoAction.begin("reparent %s -> %s" % [node_path, new_parent_path], node) \
		.do_method(node.reparent.bind(new_parent, keep_global)) \
		.do_method(node.set_owner.bind(root)) \
		.undo_method(node.reparent.bind(old_parent, keep_global)) \
		.undo_method(old_parent.move_child.bind(node, old_index)) \
		.undo_method(node.set_owner.bind(root)) \
		.commit_recorded()

	var new_path := str(root.get_path_to(node))
	return MCPToolkitSuccess.ok({"action": "reparent", "new_path": new_path})


static func _manage_reorder(
	root: Node, node: Node, node_path: String, parameters: Dictionary,
) -> Dictionary:
	if not parameters.has("new_index"):
		return MCPToolkitError.fail("INVALID_PARAMS", "reorder requires new_index")
	var new_index := int(parameters.get("new_index", 0))
	if node == root:
		return MCPToolkitError.fail("INVALID_PATH", "cannot reorder the scene root")

	var parent := node.get_parent()
	if parent == null:
		return MCPToolkitError.fail("INTERNAL", "node has no parent")
	var old_index := node.get_index()
	var child_count := parent.get_child_count()
	if new_index < 0 or new_index >= child_count:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"new_index %d out of range [0, %d)" % [new_index, child_count])

	parent.move_child(node, new_index)
	MCPToolkitUndoRedoAction.begin("reorder %s to index %d" % [node_path, new_index], node) \
		.do_method(parent.move_child.bind(node, new_index)) \
		.undo_method(parent.move_child.bind(node, old_index)) \
		.commit_recorded()

	return MCPToolkitSuccess.ok({"action": "reorder", "path": node_path,
		"old_index": old_index, "new_index": node.get_index()})


static func _manage_duplicate(
	root: Node, node: Node, node_path: String, parameters: Dictionary,
) -> Dictionary:
	if node == root:
		return MCPToolkitError.fail("INVALID_PATH", "cannot duplicate the scene root")

	var dup := node.duplicate()
	if dup == null:
		return MCPToolkitError.fail("INTERNAL", "Node.duplicate() returned null for %s" % node_path)

	var new_name := str(parameters.get("new_name", ""))
	if not new_name.is_empty():
		dup.name = new_name

	var parent_path := str(parameters.get("parent_path", ""))
	parent_path = Helpers.normalize_editor_path(parent_path)
	var target_parent: Node
	if parent_path.is_empty():
		target_parent = node.get_parent()
	else:
		target_parent = root.get_node_or_null(parent_path)
		if target_parent == null:
			dup.queue_free()
			return MCPToolkitError.fail("NOT_FOUND",
				"parent not found: %s" % parent_path, MCPToolkitError.HINT_NODE_PATH)

	target_parent.add_child(dup)
	dup.set_owner(root)
	MCPToolkitUndoRedoAction.begin("duplicate %s" % node_path, target_parent) \
		.do_method(target_parent.add_child.bind(dup)) \
		.do_method(dup.set_owner.bind(root)) \
		.do_reference(dup) \
		.undo_method(target_parent.remove_child.bind(dup)) \
		.commit_recorded()

	# Apply optional property overrides (position, scale, etc.).
	# Use coerce_value_hint so untagged dicts like {x:200,y:300}
	# are inferred as Vector2/Vector3/Color from the property type.
	var props_raw = parameters.get("properties", null)
	if typeof(props_raw) == TYPE_DICTIONARY:
		for key in (props_raw as Dictionary):
			var prop_name := str(key)
			var existing = dup.get(prop_name)
			var coerced = Coerce.coerce_value_hint(props_raw[key], existing)
			if typeof(coerced) == TYPE_DICTIONARY and (coerced as Dictionary).has("_coerce_error"):
				return MCPToolkitError.fail("INVALID_PARAMS", str(coerced["_coerce_error"]))
			dup.set(prop_name, coerced)

	var dup_path := str(root.get_path_to(dup))
	return MCPToolkitSuccess.ok({"action": "duplicate", "path": dup_path,
		"class": dup.get_class()})


static func _cmd_node_groups(parameters: Dictionary) -> Dictionary:
	var action := str(parameters.get("action", ""))
	if action.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing action (add|remove|list)")

	var root := _get_edited_root()
	if root == null:
		return MCPToolkitError.fail("NO_SCENE", "no edited scene")

	# Batch mode: entries array present → process N node+group pairs in one UndoRedo action.
	var entries_raw = parameters.get("entries", null)
	if typeof(entries_raw) == TYPE_ARRAY and (entries_raw as Array).size() > 0:
		if action == "list":
			return MCPToolkitError.fail("INVALID_PARAMS",
				"batch entries not supported with action 'list'; use single mode per node")
		return _batch_node_groups(root, action, entries_raw as Array)

	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)
	if node_path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing node_path")

	var node := root.get_node_or_null(node_path)
	if node == null:
		return MCPToolkitError.fail("NOT_FOUND", "node not found: %s" % node_path, MCPToolkitError.HINT_NODE_PATH)

	match action:
		"add":
			var group := str(parameters.get("group", ""))
			if group.is_empty():
				return MCPToolkitError.fail("INVALID_PARAMS", "add requires group name")
			var persistent := bool(parameters.get("persistent", true))
			node.add_to_group(group, persistent)
			MCPToolkitUndoRedoAction.begin("add %s to group %s" % [node_path, group], node) \
				.do_method(node.add_to_group.bind(group, persistent)) \
				.undo_method(node.remove_from_group.bind(group)) \
				.commit_recorded()
			return MCPToolkitSuccess.ok({"action": "add", "node": node_path, "group": group})

		"remove":
			var group := str(parameters.get("group", ""))
			if group.is_empty():
				return MCPToolkitError.fail("INVALID_PARAMS", "remove requires group name")
			if not node.is_in_group(group):
				return MCPToolkitError.fail("NOT_FOUND",
					"node %s is not in group '%s'" % [node_path, group])
			node.remove_from_group(group)
			MCPToolkitUndoRedoAction.begin("remove %s from group %s" % [node_path, group], node) \
				.do_method(node.remove_from_group.bind(group)) \
				.undo_method(node.add_to_group.bind(group, true)) \
				.commit_recorded()
			return MCPToolkitSuccess.ok({"action": "remove", "node": node_path, "group": group})

		"list":
			var groups: Array[String] = []
			for g in node.get_groups():
				var gs := str(g)
				if not gs.begins_with("_"):
					groups.append(gs)
			return MCPToolkitSuccess.ok({"action": "list", "node": node_path,
				"groups": groups, "count": groups.size()})

		_:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"unknown action '%s'; must be add|remove|list" % action)


static func _batch_node_groups(root: Node, batch_action: String, entries: Array) -> Dictionary:
	var undo_action = MCPToolkitUndoRedoAction.begin(
		"batch %s groups (%d entries)" % [batch_action, entries.size()], root)

	var results: Array = []
	for entry in entries:
		var e: Dictionary = entry if typeof(entry) == TYPE_DICTIONARY else {}
		var np := str(e.get("node_path", ""))
		np = Helpers.normalize_editor_path(np)
		var group := str(e.get("group", ""))
		if np.is_empty() or group.is_empty():
			results.append({"node_path": np, "group": group, "error": "missing node_path or group"})
			continue
		var node := root.get_node_or_null(np)
		if node == null:
			results.append({"node_path": np, "group": group, "error": "node not found"})
			continue
		match batch_action:
			"add":
				node.add_to_group(group, true)
				undo_action.do_method(node.add_to_group.bind(group, true))
				undo_action.undo_method(node.remove_from_group.bind(group))
				results.append({"node_path": np, "group": group, "status": "added"})
			"remove":
				if not node.is_in_group(group):
					results.append({"node_path": np, "group": group, "error": "not in group"})
					continue
				node.remove_from_group(group)
				undo_action.do_method(node.remove_from_group.bind(group))
				undo_action.undo_method(node.add_to_group.bind(group, true))
				results.append({"node_path": np, "group": group, "status": "removed"})

	undo_action.commit_recorded()

	return MCPToolkitSuccess.ok({"action": batch_action, "results": results, "count": results.size()})


const _LAYOUT_PRESETS := {
	"PRESET_TOP_LEFT": Control.PRESET_TOP_LEFT,
	"PRESET_TOP_RIGHT": Control.PRESET_TOP_RIGHT,
	"PRESET_BOTTOM_LEFT": Control.PRESET_BOTTOM_LEFT,
	"PRESET_BOTTOM_RIGHT": Control.PRESET_BOTTOM_RIGHT,
	"PRESET_CENTER_LEFT": Control.PRESET_CENTER_LEFT,
	"PRESET_CENTER_TOP": Control.PRESET_CENTER_TOP,
	"PRESET_CENTER_RIGHT": Control.PRESET_CENTER_RIGHT,
	"PRESET_CENTER_BOTTOM": Control.PRESET_CENTER_BOTTOM,
	"PRESET_CENTER": Control.PRESET_CENTER,
	"PRESET_LEFT_WIDE": Control.PRESET_LEFT_WIDE,
	"PRESET_TOP_WIDE": Control.PRESET_TOP_WIDE,
	"PRESET_RIGHT_WIDE": Control.PRESET_RIGHT_WIDE,
	"PRESET_BOTTOM_WIDE": Control.PRESET_BOTTOM_WIDE,
	"PRESET_VCENTER_WIDE": Control.PRESET_VCENTER_WIDE,
	"PRESET_HCENTER_WIDE": Control.PRESET_HCENTER_WIDE,
	"PRESET_FULL_RECT": Control.PRESET_FULL_RECT,
}


static func _cmd_control_set_layout(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return MCPToolkitError.fail("NO_SCENE", "no edited scene")

	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)
	var preset_name := str(parameters.get("preset", ""))
	var resize_mode_str := str(parameters.get("resize_mode", "keep_size"))
	var margins_raw = parameters.get("margins", null)

	if node_path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing node_path")
	if preset_name.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing preset")

	var node := root.get_node_or_null(node_path)
	if node == null:
		return MCPToolkitError.fail("NOT_FOUND", "node not found: %s" % node_path, MCPToolkitError.HINT_NODE_PATH)
	if not (node is Control):
		return MCPToolkitError.fail("INVALID_CLASS",
			"node at %s is %s — control.set_layout requires a Control node" % [
				node_path, node.get_class()])

	var ctrl: Control = node as Control

	if not _LAYOUT_PRESETS.has(preset_name):
		var available := ", ".join(PackedStringArray(_LAYOUT_PRESETS.keys()))
		return MCPToolkitError.fail("INVALID_PARAMS",
			"unknown preset '%s'. Available: %s" % [preset_name, available])

	var preset_enum: int = _LAYOUT_PRESETS[preset_name]
	var mode: int = Control.PRESET_MODE_KEEP_SIZE \
		if resize_mode_str == "keep_size" \
		else Control.PRESET_MODE_MINSIZE

	# Capture state for UndoRedo
	var old_anchor_left := ctrl.anchor_left
	var old_anchor_top := ctrl.anchor_top
	var old_anchor_right := ctrl.anchor_right
	var old_anchor_bottom := ctrl.anchor_bottom
	var old_offset_left := ctrl.offset_left
	var old_offset_top := ctrl.offset_top
	var old_offset_right := ctrl.offset_right
	var old_offset_bottom := ctrl.offset_bottom

	# Apply preset + margins directly so margin offsets are relative to the
	# NEW anchor positions, not the old ones (UndoRedo queues do-methods, so
	# margin values would be computed against stale offsets if queued).
	ctrl.set_anchors_and_offsets_preset(preset_enum, mode)
	if margins_raw != null and typeof(margins_raw) == TYPE_DICTIONARY:
		if margins_raw.has("left"):
			ctrl.offset_left += float(margins_raw["left"])
		if margins_raw.has("right"):
			ctrl.offset_right += float(margins_raw["right"])
		if margins_raw.has("top"):
			ctrl.offset_top += float(margins_raw["top"])
		if margins_raw.has("bottom"):
			ctrl.offset_bottom += float(margins_raw["bottom"])

	# Record for undo using the final property values (already applied).
	MCPToolkitUndoRedoAction.begin("control.set_layout %s %s" % [node_path, preset_name], ctrl) \
		.do_property(ctrl, &"anchor_left", ctrl.anchor_left) \
		.do_property(ctrl, &"anchor_top", ctrl.anchor_top) \
		.do_property(ctrl, &"anchor_right", ctrl.anchor_right) \
		.do_property(ctrl, &"anchor_bottom", ctrl.anchor_bottom) \
		.do_property(ctrl, &"offset_left", ctrl.offset_left) \
		.do_property(ctrl, &"offset_top", ctrl.offset_top) \
		.do_property(ctrl, &"offset_right", ctrl.offset_right) \
		.do_property(ctrl, &"offset_bottom", ctrl.offset_bottom) \
		.undo_property(ctrl, &"anchor_left", old_anchor_left) \
		.undo_property(ctrl, &"anchor_top", old_anchor_top) \
		.undo_property(ctrl, &"anchor_right", old_anchor_right) \
		.undo_property(ctrl, &"anchor_bottom", old_anchor_bottom) \
		.undo_property(ctrl, &"offset_left", old_offset_left) \
		.undo_property(ctrl, &"offset_top", old_offset_top) \
		.undo_property(ctrl, &"offset_right", old_offset_right) \
		.undo_property(ctrl, &"offset_bottom", old_offset_bottom) \
		.commit_recorded()

	var response := {
		"path": node_path,
		"preset": preset_name,
		"final_rect": {
			"position": {"x": ctrl.position.x, "y": ctrl.position.y},
			"size": {"x": ctrl.size.x, "y": ctrl.size.y},
		},
	}

	# Warn if the Control is inside a Container
	var parent := ctrl.get_parent()
	if parent != null and parent is Container:
		response["warning"] = (
			"This Control is inside a %s container. " % parent.get_class() +
			"The container will override layout on the next layout pass. " +
			"Consider using size_flags or moving the node outside the container.")

	return MCPToolkitSuccess.ok(response)


static func _cmd_collision_from_sprite(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["sprite_path"])
	if err != null:
		return err

	var root := Helpers.get_edited_root()
	if root == null:
		return MCPToolkitError.fail("NO_SCENE", "no edited scene")

	var sprite_path := str(parameters.get("sprite_path", ""))
	sprite_path = Helpers.normalize_editor_path(sprite_path)
	var node = Helpers.resolve_scene_node(sprite_path)
	if node == null:
		return MCPToolkitError.fail("NOT_FOUND", "node not found: %s" % sprite_path, MCPToolkitError.HINT_NODE_PATH)

	if not (node is Sprite2D or node is TextureRect):
		return MCPToolkitError.fail("INVALID_CLASS",
			"node at %s is %s — expected Sprite2D or TextureRect" % [sprite_path, node.get_class()])

	var tex = node.get("texture") as Texture2D
	if tex == null:
		return MCPToolkitError.fail("INVALID_PARAMS", "sprite has no texture")

	var img := tex.get_image()
	if img == null:
		return MCPToolkitError.fail("INVALID_PARAMS", "cannot read image data")

	var simplification := float(parameters.get("simplification", 2.0))

	var bitmap := BitMap.new()
	bitmap.create_from_image_alpha(img, 0.1)
	var polygons := bitmap.opaque_to_polygons(
		Rect2(Vector2.ZERO, Vector2(img.get_width(), img.get_height())),
		simplification)

	if polygons.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "no opaque regions found in texture")

	# Resolve target parent
	var target_parent: Node
	var target_parent_path := str(parameters.get("target_parent", ""))
	if target_parent_path.is_empty():
		target_parent = node.get_parent()
	else:
		target_parent_path = Helpers.normalize_editor_path(target_parent_path)
		target_parent = root.get_node_or_null(target_parent_path)
		if target_parent == null:
			return MCPToolkitError.fail("NOT_FOUND",
				"target parent not found: %s" % target_parent_path, MCPToolkitError.HINT_NODE_PATH)

	var sprite_name := String(node.name)
	var base_name := str(parameters.get("target_name", "%s_collision" % sprite_name))
	var total_points := 0
	var first_path := ""

	var coll_action = MCPToolkitUndoRedoAction.begin("collision from sprite", target_parent)

	for i in range(polygons.size()):
		var coll := CollisionPolygon2D.new()
		if polygons.size() == 1:
			coll.name = base_name
		else:
			coll.name = "%s_%d" % [base_name, i]
		coll.polygon = polygons[i]
		total_points += (polygons[i] as PackedVector2Array).size()

		target_parent.add_child(coll)
		coll.set_owner(root)
		coll_action.do_method(target_parent.add_child.bind(coll))
		coll_action.do_method(coll.set_owner.bind(root))
		coll_action.do_reference(coll)
		coll_action.undo_method(target_parent.remove_child.bind(coll))

		if i == 0:
			first_path = str(root.get_path_to(coll))

	coll_action.commit_recorded()

	return MCPToolkitSuccess.ok({
		"path": first_path,
		"polygon_count": polygons.size(),
		"total_points": total_points,
	})
