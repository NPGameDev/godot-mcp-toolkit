@tool
extends RefCounted
## node.* command handlers — property get/set/list, method calls, script attachment.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const McpError = _Hub.McpError
const Coerce = _Hub.Coerce
const FileGuard = _Hub.FileGuard
const FeatureGate = _Hub.FeatureGate
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
		return _cmd_node_set_property(parameters)
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
static func _is_compound_set_failure(expected: Variant, actual: Variant) -> bool:
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
		return McpError.make("NO_SCENE", "no edited scene")

	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)
	var property_name := str(parameters.get("property", ""))

	if node_path.is_empty() or property_name.is_empty():
		return McpError.make("INVALID_PARAMS", "missing node_path or property")

	var node := root.get_node_or_null(node_path)
	if node == null:
		return McpError.make("NOT_FOUND", "node not found: %s" % node_path, McpError.HINT_NODE_PATH)

	# Handle colon-chained sub-resource paths (e.g. "material:shader_parameter/value").
	# Object.get() doesn't interpret ":" — split manually and navigate.
	var target: Object = node
	var final_prop := property_name
	if ":" in property_name:
		var parts := property_name.split(":")
		final_prop = parts[-1]
		for i in range(parts.size() - 1):
			var sub = target.get(parts[i])
			if sub == null or not (sub is Object):
				return McpError.make("NOT_FOUND",
					"sub-resource '%s' is null on %s" % [parts[i], node_path])
			target = sub

	return {"value": Coerce.serialize_value(target.get(final_prop))}


static func _cmd_node_set_property(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return McpError.make("NO_SCENE", "no edited scene")

	# FIX-7: Batch mode — set multiple properties in a single UndoRedo action.
	var batch_raw = parameters.get("batch", null)
	if batch_raw != null and typeof(batch_raw) == TYPE_ARRAY and (batch_raw as Array).size() > 0:
		return _batch_set_properties(root, batch_raw as Array)

	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)
	var property_name := str(parameters.get("property", ""))
	var raw_value = parameters.get("value", null)

	if node_path.is_empty() or property_name.is_empty():
		return McpError.make("INVALID_PARAMS", "missing node_path or property")

	var node := root.get_node_or_null(node_path)
	if node == null:
		return McpError.make("NOT_FOUND", "node not found: %s" % node_path, McpError.HINT_NODE_PATH)

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
			return McpError.make("INVALID_PARAMS",
				"groups value must be a string or array of strings")
		var old_groups: Array = []
		for g in node.get_groups():
			var gs := str(g)
			if not gs.begins_with("_"):  # skip engine-internal groups
				old_groups.append(gs)
		var undo_redo = _Hub.get_undo_redo()
		if undo_redo != null:
			undo_redo.create_action("MCP: set %s groups" % node_path)
			for g in old_groups:
				if g not in new_groups:
					undo_redo.add_do_method(node, "remove_from_group", g)
					undo_redo.add_undo_method(node, "add_to_group", g, true)
			for g in new_groups:
				if g not in old_groups:
					undo_redo.add_do_method(node, "add_to_group", g, true)
					undo_redo.add_undo_method(node, "remove_from_group", g)
			undo_redo.commit_action()
		else:
			for g in old_groups:
				if g not in new_groups:
					node.remove_from_group(g)
			for g in new_groups:
				if g not in old_groups:
					node.add_to_group(g, true)
		return {"success": true, "groups": new_groups}

	# Compound / colon-chained paths (e.g. "libraries/test",
	# "material:shader_parameter/value", "theme_override_colors/font_color").
	# ":" navigates sub-resources; "/" is a compound key inside _set/_get.
	# UndoRedo can't serialize these reliably. Split on ":", navigate to the
	# target object, then call set() with the final component intact.
	# Detect compound paths BEFORE coercion — coerce_for_property checks
	# _has_property on the node, but compound props live on sub-resources.
	if ":" in property_name or "/" in property_name:
		var target: Object = node
		var final_prop := property_name
		if ":" in property_name:
			var parts := property_name.split(":")
			final_prop = parts[-1]
			for i in range(parts.size() - 1):
				var sub = target.get(parts[i])
				if sub == null or not (sub is Object):
					return McpError.make("NOT_FOUND",
						"sub-resource '%s' is null on %s" % [parts[i], node_path])
				target = sub
		# Coerce the value directly — skip _has_property check because
		# compound sub-paths (e.g. shader_parameter/brightness) may not
		# appear in get_property_list() but are valid via _set()/_get().
		# Resource path validation still runs; readback catches silent failures.
		var missing := Coerce.check_resource_paths(raw_value)
		if missing != "":
			return McpError.make("LOAD_FAILED", "resource not found: %s" % missing)
		var coerced = Coerce.coerce_value(raw_value)
		if typeof(coerced) == TYPE_DICTIONARY \
				and (coerced as Dictionary).has("_coerce_error"):
			return McpError.make("INVALID_VALUE", str(coerced["_coerce_error"]))
		# ShaderMaterial shader_parameter/ prefix needs set_shader_parameter()
		# — the generic set() path doesn't persist the value.
		if final_prop.begins_with("shader_parameter/") and target is ShaderMaterial:
			var param_name := final_prop.trim_prefix("shader_parameter/")
			(target as ShaderMaterial).set_shader_parameter(param_name, coerced)
		else:
			target.set(final_prop, coerced)
		# Readback verification — compound set() can silently fail
		# (e.g. AnimationPlayer libraries/ with external Resource refs).
		var readback = target.get(final_prop)
		var response := {"success": true}
		if _is_compound_set_failure(coerced, readback):
			response["warning"] = (
				"set() reported no error but readback is %s for '%s'. "
				+ "Use node_call_method with the type's dedicated API instead "
				+ "(e.g. add_animation_library for AnimationPlayer)."
			) % [_brief_value(readback), property_name]
		return response

	var coerce_result := Helpers.coerce_for_property(node, property_name, raw_value)
	if not coerce_result.get("ok", false):
		return McpError.make(
			coerce_result.get("code", "INVALID_VALUE"),
			str(coerce_result.get("error", "")))
	var coerced = coerce_result["value"]

	var old_value = node.get(property_name)

	var undo_redo = _Hub.get_undo_redo()
	if undo_redo != null:
		undo_redo.create_action("MCP: set %s.%s" % [node_path, property_name])
		undo_redo.add_do_property(node, property_name, coerced)
		undo_redo.add_undo_property(node, property_name, old_value)
		if coerced is Resource:
			undo_redo.add_do_reference(coerced)
		if old_value is Resource:
			undo_redo.add_undo_reference(old_value)
		undo_redo.commit_action()
	else:
		node.set(property_name, coerced)
	# FIX-F: Detect bare res:// strings silently failing on Resource-typed properties.
	if typeof(raw_value) == TYPE_STRING and str(raw_value).begins_with("res://") \
			and not (coerced is Resource):
		var readback = node.get(property_name)
		if not (readback is String):
			return McpError.make("INVALID_VALUE",
				"property '%s' expects a Resource, not a bare string path. " % property_name +
				"Use {\"type\": \"Resource\", \"path\": \"%s\"} as the value." % str(raw_value))
	return {"success": true}


## FIX-7: Batch set multiple properties in one UndoRedo action.
static func _batch_set_properties(root: Node, entries: Array) -> Dictionary:
	var undo_redo = _Hub.get_undo_redo()
	if undo_redo != null:
		undo_redo.create_action("MCP: batch set %d properties" % entries.size())

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

		if undo_redo != null:
			undo_redo.add_do_property(node, prop, coerced)
			undo_redo.add_undo_property(node, prop, old_value)
			if coerced is Resource:
				undo_redo.add_do_reference(coerced)
			if old_value is Resource:
				undo_redo.add_undo_reference(old_value)
		else:
			node.set(prop, coerced)
		results.append({"node_path": np, "property": prop, "success": true})

	if undo_redo != null:
		undo_redo.commit_action()

	return {"success": true, "results": results}


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
		return McpError.make("NO_SCENE", "no edited scene")
	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)
	var node = _resolve_scene_node(node_path)
	if node == null:
		return McpError.make("NOT_FOUND", "node not found: %s" % node_path, McpError.HINT_NODE_PATH)
	var mask := str(parameters.get("mask", "common"))
	if not (mask in ["common", "all", "groups", "script"]):
		return McpError.make("INVALID_PARAMS",
			"mask must be 'common', 'all', 'groups', or 'script' (got '%s')" % mask)
	var visibility_filter := str(parameters.get("visibility", "all"))
	if mask == "script" and not (visibility_filter in ["public", "private", "all"]):
		return McpError.make("INVALID_PARAMS",
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
	return {
		"path": node_path,
		"class": node.get_class(),
		"mask": mask,
		"properties": properties,
		"count": properties.size(),
	}


static func _cmd_node_call_method(parameters: Dictionary) -> Dictionary:
	if not FeatureGate.is_enabled("node_call_method"):
		var err := FeatureGate.disabled_error("node_call_method")
		err["workaround"] = "Use script_write to add the logic in _ready() or a setup function, then editor_refresh to apply."
		return err
	var root := _get_edited_root()
	if root == null:
		return McpError.make("NO_SCENE", "no open scene; use scene.open or scene.create first")

	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)
	var method_name := str(parameters.get("method_name", ""))
	var args_raw = parameters.get("args", [])
	# Resource refs in args are validated via Coerce.check_resource_paths,
	# which gates through FileGuard. node_path is a scene-tree path, not filesystem.

	if node_path.is_empty() or method_name.is_empty():
		return McpError.make("INVALID_PARAMS", "missing node_path or method_name")
	if typeof(args_raw) != TYPE_ARRAY:
		return McpError.make("INVALID_PARAMS",
			"args must be an Array (got %s)" % typeof(args_raw))

	var node := root.get_node_or_null(node_path)
	if node == null:
		return McpError.make("NOT_FOUND",
			"no node at path %s. This tool is editor-only — for runtime nodes use execute_code or runtime_get_node_state." % node_path)
	if not node.has_method(method_name):
		return McpError.make("INVALID_METHOD",
			"node %s has no method '%s'; use scene.get_tree or inspect the script class via ClassDB" % [
				node_path, method_name])

	var missing := Coerce.check_resource_paths(args_raw)
	if missing != "":
		return McpError.make("LOAD_FAILED",
			"failed to load resource at %s; verify the path or use resource.write to create it first" % missing)

	var coerced_args = Coerce.coerce_value(args_raw)
	if typeof(coerced_args) != TYPE_ARRAY:
		coerced_args = []
	print("[MCPTools] node.call_method invoked %s.%s(%d args)" % [
		node_path, method_name, (coerced_args as Array).size()])
	var result = node.callv(method_name, coerced_args)

	var response := {
		"success": true,
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
	return response


static func _cmd_node_set_script(parameters: Dictionary) -> Dictionary:
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

	var script_path := str(parameters.get("script_path", ""))

	if script_path.is_empty():
		var old_script = node.get_script()
		var undo_redo_clear = _Hub.get_undo_redo()
		if undo_redo_clear != null:
			undo_redo_clear.create_action("MCP: clear script on %s" % node_path)
			undo_redo_clear.add_do_property(node, "script", null)
			undo_redo_clear.add_undo_property(node, "script", old_script)
			if old_script is Resource:
				undo_redo_clear.add_undo_reference(old_script)
			undo_redo_clear.commit_action()
		else:
			node.set_script(null)
		return {"success": true, "path": node_path, "script": null, "properties": []}

	var guard := FileGuard.resolve_safe(script_path)
	if guard["error"] != null:
		return McpError.make("PATH_DENIED", str(guard["reason"]))

	var loaded = ResourceLoader.load(script_path)
	if loaded == null:
		return McpError.make("LOAD_FAILED",
			"cannot load script at %s; verify the path or use script.write to create it first" % script_path)
	if not (loaded is Script):
		return McpError.make("INVALID_PARAMS",
			"resource at %s is not a Script (got %s)" % [script_path, loaded.get_class()])

	var old_script = node.get_script()
	var undo_redo = _Hub.get_undo_redo()
	if undo_redo != null:
		undo_redo.create_action("MCP: set script %s on %s" % [script_path, node_path])
		undo_redo.add_do_property(node, "script", loaded)
		undo_redo.add_undo_property(node, "script", old_script)
		undo_redo.add_do_reference(loaded)
		if old_script is Resource:
			undo_redo.add_undo_reference(old_script)
		undo_redo.commit_action()
	else:
		node.set_script(loaded)

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

	return {"success": true, "path": node_path, "script": script_path, "properties": exports}


static func _cmd_node_manage(parameters: Dictionary) -> Dictionary:
	var action := str(parameters.get("action", ""))
	if action.is_empty():
		return McpError.make("INVALID_PARAMS", "missing action (rename|reparent|reorder|duplicate)")

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
			return McpError.make("INVALID_PARAMS",
				"unknown action '%s'; must be rename|reparent|reorder|duplicate" % action)


static func _manage_rename(
	root: Node, node: Node, node_path: String, parameters: Dictionary,
) -> Dictionary:
	var new_name := str(parameters.get("new_name", ""))
	if new_name.is_empty():
		return McpError.make("INVALID_PARAMS", "rename requires new_name")
	if node == root:
		return McpError.make("INVALID_PATH", "cannot rename the scene root")

	var old_name := String(node.name)
	var undo_redo = _Hub.get_undo_redo()
	if undo_redo != null:
		undo_redo.create_action("MCP: rename %s → %s" % [old_name, new_name])
		undo_redo.add_do_property(node, "name", new_name)
		undo_redo.add_undo_property(node, "name", old_name)
		undo_redo.commit_action()
	else:
		node.name = new_name

	var parent := node.get_parent()
	var new_path := str(root.get_path_to(node))
	return {"success": true, "action": "rename", "old_name": old_name,
		"new_name": String(node.name), "new_path": new_path}


static func _manage_reparent(
	root: Node, node: Node, node_path: String, parameters: Dictionary,
) -> Dictionary:
	var new_parent_path := str(parameters.get("new_parent_path", ""))
	new_parent_path = Helpers.normalize_editor_path(new_parent_path)
	if new_parent_path.is_empty():
		return McpError.make("INVALID_PARAMS", "reparent requires new_parent_path")
	if node == root:
		return McpError.make("INVALID_PATH", "cannot reparent the scene root")

	var new_parent := root.get_node_or_null(new_parent_path)
	if new_parent == null:
		return McpError.make("NOT_FOUND",
			"new parent not found: %s" % new_parent_path, McpError.HINT_NODE_PATH)
	# Prevent reparenting a node under itself (would create a cycle).
	if new_parent == node or node.is_ancestor_of(new_parent):
		return McpError.make("INVALID_PARAMS",
			"cannot reparent a node under itself or a descendant")

	var keep_global := bool(parameters.get("keep_global_transform", true))
	var old_parent := node.get_parent()
	var old_index := node.get_index()

	var undo_redo = _Hub.get_undo_redo()
	if undo_redo != null:
		undo_redo.create_action("MCP: reparent %s → %s" % [node_path, new_parent_path])
		undo_redo.add_do_method(node, "reparent", new_parent, keep_global)
		undo_redo.add_do_method(node, "set_owner", root)
		undo_redo.add_undo_method(node, "reparent", old_parent, keep_global)
		undo_redo.add_undo_method(old_parent, "move_child", node, old_index)
		undo_redo.add_undo_method(node, "set_owner", root)
		undo_redo.commit_action()
	else:
		node.reparent(new_parent, keep_global)
		node.set_owner(root)

	var new_path := str(root.get_path_to(node))
	return {"success": true, "action": "reparent", "new_path": new_path}


static func _manage_reorder(
	root: Node, node: Node, node_path: String, parameters: Dictionary,
) -> Dictionary:
	if not parameters.has("new_index"):
		return McpError.make("INVALID_PARAMS", "reorder requires new_index")
	var new_index := int(parameters.get("new_index", 0))
	if node == root:
		return McpError.make("INVALID_PATH", "cannot reorder the scene root")

	var parent := node.get_parent()
	if parent == null:
		return McpError.make("INTERNAL", "node has no parent")
	var old_index := node.get_index()
	var child_count := parent.get_child_count()
	if new_index < 0 or new_index >= child_count:
		return McpError.make("INVALID_PARAMS",
			"new_index %d out of range [0, %d)" % [new_index, child_count])

	var undo_redo = _Hub.get_undo_redo()
	if undo_redo != null:
		undo_redo.create_action("MCP: reorder %s to index %d" % [node_path, new_index])
		undo_redo.add_do_method(parent, "move_child", node, new_index)
		undo_redo.add_undo_method(parent, "move_child", node, old_index)
		undo_redo.commit_action()
	else:
		parent.move_child(node, new_index)

	return {"success": true, "action": "reorder", "path": node_path,
		"old_index": old_index, "new_index": node.get_index()}


static func _manage_duplicate(
	root: Node, node: Node, node_path: String, parameters: Dictionary,
) -> Dictionary:
	if node == root:
		return McpError.make("INVALID_PATH", "cannot duplicate the scene root")

	var dup := node.duplicate()
	if dup == null:
		return McpError.make("INTERNAL", "Node.duplicate() returned null for %s" % node_path)

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
			return McpError.make("NOT_FOUND",
				"parent not found: %s" % parent_path, McpError.HINT_NODE_PATH)

	var undo_redo = _Hub.get_undo_redo()
	if undo_redo != null:
		undo_redo.create_action("MCP: duplicate %s" % node_path)
		undo_redo.add_do_method(target_parent, "add_child", dup)
		undo_redo.add_do_method(dup, "set_owner", root)
		undo_redo.add_do_reference(dup)
		undo_redo.add_undo_method(target_parent, "remove_child", dup)
		undo_redo.commit_action()
	else:
		target_parent.add_child(dup)
		dup.set_owner(root)

	# Apply optional property overrides (position, scale, etc.).
	# Use coerce_value_hint so untagged dicts like {x:200,y:300}
	# are inferred as Vector2/Vector3/Color from the property type.
	var props_raw = parameters.get("properties", null)
	if typeof(props_raw) == TYPE_DICTIONARY:
		for key in (props_raw as Dictionary):
			var prop_name := str(key)
			var existing = dup.get(prop_name)
			dup.set(prop_name, Coerce.coerce_value_hint(props_raw[key], existing))

	var dup_path := str(root.get_path_to(dup))
	return {"success": true, "action": "duplicate", "path": dup_path,
		"class": dup.get_class()}


static func _cmd_node_groups(parameters: Dictionary) -> Dictionary:
	var action := str(parameters.get("action", ""))
	if action.is_empty():
		return McpError.make("INVALID_PARAMS", "missing action (add|remove|list)")

	var root := _get_edited_root()
	if root == null:
		return McpError.make("NO_SCENE", "no edited scene")

	# Batch mode: entries array present → process N node+group pairs in one UndoRedo action.
	var entries_raw = parameters.get("entries", null)
	if typeof(entries_raw) == TYPE_ARRAY and (entries_raw as Array).size() > 0:
		if action == "list":
			return McpError.make("INVALID_PARAMS",
				"batch entries not supported with action 'list'; use single mode per node")
		return _batch_node_groups(root, action, entries_raw as Array)

	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)
	if node_path.is_empty():
		return McpError.make("INVALID_PARAMS", "missing node_path")

	var node := root.get_node_or_null(node_path)
	if node == null:
		return McpError.make("NOT_FOUND", "node not found: %s" % node_path, McpError.HINT_NODE_PATH)

	match action:
		"add":
			var group := str(parameters.get("group", ""))
			if group.is_empty():
				return McpError.make("INVALID_PARAMS", "add requires group name")
			var persistent := bool(parameters.get("persistent", true))
			var undo_redo = _Hub.get_undo_redo()
			if undo_redo != null:
				undo_redo.create_action("MCP: add %s to group %s" % [node_path, group])
				undo_redo.add_do_method(node, "add_to_group", group, persistent)
				undo_redo.add_undo_method(node, "remove_from_group", group)
				undo_redo.commit_action()
			else:
				node.add_to_group(group, persistent)
			return {"success": true, "action": "add", "node": node_path, "group": group}

		"remove":
			var group := str(parameters.get("group", ""))
			if group.is_empty():
				return McpError.make("INVALID_PARAMS", "remove requires group name")
			if not node.is_in_group(group):
				return McpError.make("NOT_FOUND",
					"node %s is not in group '%s'" % [node_path, group])
			var undo_redo = _Hub.get_undo_redo()
			if undo_redo != null:
				undo_redo.create_action("MCP: remove %s from group %s" % [node_path, group])
				undo_redo.add_do_method(node, "remove_from_group", group)
				undo_redo.add_undo_method(node, "add_to_group", group, true)
				undo_redo.commit_action()
			else:
				node.remove_from_group(group)
			return {"success": true, "action": "remove", "node": node_path, "group": group}

		"list":
			var groups: Array[String] = []
			for g in node.get_groups():
				var gs := str(g)
				if not gs.begins_with("_"):
					groups.append(gs)
			return {"success": true, "action": "list", "node": node_path,
				"groups": groups, "count": groups.size()}

		_:
			return McpError.make("INVALID_PARAMS",
				"unknown action '%s'; must be add|remove|list" % action)


static func _batch_node_groups(root: Node, action: String, entries: Array) -> Dictionary:
	var undo_redo = _Hub.get_undo_redo()
	if undo_redo != null:
		undo_redo.create_action("MCP: batch %s groups (%d entries)" % [action, entries.size()])

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
		match action:
			"add":
				if undo_redo != null:
					undo_redo.add_do_method(node, "add_to_group", group, true)
					undo_redo.add_undo_method(node, "remove_from_group", group)
				else:
					node.add_to_group(group, true)
				results.append({"node_path": np, "group": group, "status": "added"})
			"remove":
				if not node.is_in_group(group):
					results.append({"node_path": np, "group": group, "error": "not in group"})
					continue
				if undo_redo != null:
					undo_redo.add_do_method(node, "remove_from_group", group)
					undo_redo.add_undo_method(node, "add_to_group", group, true)
				else:
					node.remove_from_group(group)
				results.append({"node_path": np, "group": group, "status": "removed"})

	if undo_redo != null:
		undo_redo.commit_action()

	return {"success": true, "action": action, "results": results, "count": results.size()}


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
		return McpError.make("NO_SCENE", "no edited scene")

	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)
	var preset_name := str(parameters.get("preset", ""))
	var resize_mode_str := str(parameters.get("resize_mode", "keep_size"))
	var margins_raw = parameters.get("margins", null)

	if node_path.is_empty():
		return McpError.make("INVALID_PARAMS", "missing node_path")
	if preset_name.is_empty():
		return McpError.make("INVALID_PARAMS", "missing preset")

	var node := root.get_node_or_null(node_path)
	if node == null:
		return McpError.make("NOT_FOUND", "node not found: %s" % node_path, McpError.HINT_NODE_PATH)
	if not (node is Control):
		return McpError.make("INVALID_CLASS",
			"node at %s is %s — control.set_layout requires a Control node" % [
				node_path, node.get_class()])

	var ctrl: Control = node as Control

	if not _LAYOUT_PRESETS.has(preset_name):
		var available := ", ".join(PackedStringArray(_LAYOUT_PRESETS.keys()))
		return McpError.make("INVALID_PARAMS",
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
	var undo_redo = _Hub.get_undo_redo()
	if undo_redo != null:
		undo_redo.create_action("MCP: control.set_layout %s %s" % [node_path, preset_name])
		undo_redo.add_do_property(ctrl, "anchor_left", ctrl.anchor_left)
		undo_redo.add_do_property(ctrl, "anchor_top", ctrl.anchor_top)
		undo_redo.add_do_property(ctrl, "anchor_right", ctrl.anchor_right)
		undo_redo.add_do_property(ctrl, "anchor_bottom", ctrl.anchor_bottom)
		undo_redo.add_do_property(ctrl, "offset_left", ctrl.offset_left)
		undo_redo.add_do_property(ctrl, "offset_top", ctrl.offset_top)
		undo_redo.add_do_property(ctrl, "offset_right", ctrl.offset_right)
		undo_redo.add_do_property(ctrl, "offset_bottom", ctrl.offset_bottom)
		undo_redo.add_undo_property(ctrl, "anchor_left", old_anchor_left)
		undo_redo.add_undo_property(ctrl, "anchor_top", old_anchor_top)
		undo_redo.add_undo_property(ctrl, "anchor_right", old_anchor_right)
		undo_redo.add_undo_property(ctrl, "anchor_bottom", old_anchor_bottom)
		undo_redo.add_undo_property(ctrl, "offset_left", old_offset_left)
		undo_redo.add_undo_property(ctrl, "offset_top", old_offset_top)
		undo_redo.add_undo_property(ctrl, "offset_right", old_offset_right)
		undo_redo.add_undo_property(ctrl, "offset_bottom", old_offset_bottom)
		undo_redo.commit_action(false)  # Already applied — record only

	var response := {
		"success": true,
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

	return response


static func _cmd_collision_from_sprite(parameters: Dictionary) -> Dictionary:
	var err = McpError.check_required(parameters, ["sprite_path"])
	if err != null:
		return err

	var root := Helpers.get_edited_root()
	if root == null:
		return McpError.make("NO_SCENE", "no edited scene")

	var sprite_path := str(parameters.get("sprite_path", ""))
	sprite_path = Helpers.normalize_editor_path(sprite_path)
	var node = Helpers.resolve_scene_node(sprite_path)
	if node == null:
		return McpError.make("NOT_FOUND", "node not found: %s" % sprite_path, McpError.HINT_NODE_PATH)

	if not (node is Sprite2D or node is TextureRect):
		return McpError.make("INVALID_CLASS",
			"node at %s is %s — expected Sprite2D or TextureRect" % [sprite_path, node.get_class()])

	var tex = node.get("texture") as Texture2D
	if tex == null:
		return McpError.make("INVALID_PARAMS", "sprite has no texture")

	var img := tex.get_image()
	if img == null:
		return McpError.make("INVALID_PARAMS", "cannot read image data")

	var simplification := float(parameters.get("simplification", 2.0))

	var bitmap := BitMap.new()
	bitmap.create_from_image_alpha(img, 0.1)
	var polygons := bitmap.opaque_to_polygons(
		Rect2(Vector2.ZERO, Vector2(img.get_width(), img.get_height())),
		simplification)

	if polygons.is_empty():
		return McpError.make("INVALID_PARAMS", "no opaque regions found in texture")

	# Resolve target parent
	var target_parent: Node
	var target_parent_path := str(parameters.get("target_parent", ""))
	if target_parent_path.is_empty():
		target_parent = node.get_parent()
	else:
		target_parent_path = Helpers.normalize_editor_path(target_parent_path)
		target_parent = root.get_node_or_null(target_parent_path)
		if target_parent == null:
			return McpError.make("NOT_FOUND",
				"target parent not found: %s" % target_parent_path, McpError.HINT_NODE_PATH)

	var sprite_name := String(node.name)
	var base_name := str(parameters.get("target_name", "%s_collision" % sprite_name))
	var total_points := 0
	var first_path := ""

	var undo_redo = _Hub.get_undo_redo()
	if undo_redo != null:
		undo_redo.create_action("MCP: collision from sprite")

	for i in range(polygons.size()):
		var coll := CollisionPolygon2D.new()
		if polygons.size() == 1:
			coll.name = base_name
		else:
			coll.name = "%s_%d" % [base_name, i]
		coll.polygon = polygons[i]
		total_points += (polygons[i] as PackedVector2Array).size()

		if undo_redo != null:
			undo_redo.add_do_method(target_parent, "add_child", coll)
			undo_redo.add_do_method(coll, "set_owner", root)
			undo_redo.add_do_reference(coll)
			undo_redo.add_undo_method(target_parent, "remove_child", coll)
		else:
			target_parent.add_child(coll)
			coll.set_owner(root)

		if i == 0:
			first_path = str(root.get_path_to(coll))

	if undo_redo != null:
		undo_redo.commit_action()

	return {
		"success": true,
		"path": first_path,
		"polygon_count": polygons.size(),
		"total_points": total_points,
	}
