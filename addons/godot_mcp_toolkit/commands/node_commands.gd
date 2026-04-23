@tool
extends RefCounted
## node.* command handlers — property get/set/list, method calls, script attachment.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPCoerce = _Hub.MCPCoerce
const MCPCommandRegistry = _Hub.MCPCommandRegistry
const MCPFileGuard = _Hub.MCPFileGuard
const MCPFeatureGate = _Hub.MCPFeatureGate


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


static func register(registry: MCPCommandRegistry, server: Node) -> void:
	registry.add("node.get_property", func(parameters: Dictionary) -> Dictionary:
		return _cmd_node_get_property(parameters))
	registry.add("node.set_property", func(parameters: Dictionary) -> Dictionary:
		return _cmd_node_set_property(parameters))
	registry.add("node.get_property_list", func(parameters: Dictionary) -> Dictionary:
		return _cmd_node_get_property_list(parameters))
	registry.add("node.call_method", func(parameters: Dictionary) -> Dictionary:
		return _cmd_node_call_method(parameters))
	registry.add("node.set_script", func(parameters: Dictionary) -> Dictionary:
		return _cmd_node_set_script(parameters))


# -- Helpers ------------------------------------------------------------------


static func _get_edited_root() -> Node:
	return EditorInterface.get_edited_scene_root()


static func _resolve_scene_node(node_path: String) -> Variant:
	var root := _get_edited_root()
	if root == null:
		return null
	if node_path.is_empty() or node_path == ".":
		return root
	return root.get_node_or_null(node_path)


# -- Commands -----------------------------------------------------------------


static func _cmd_node_get_property(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return MCPError.make("NO_SCENE", "no edited scene")

	var node_path := str(parameters.get("node_path", ""))
	var property_name := str(parameters.get("property", ""))

	if node_path.is_empty() or property_name.is_empty():
		return MCPError.make("INVALID_PARAMS", "missing node_path or property")

	var node := root.get_node_or_null(node_path)
	if node == null:
		return MCPError.make("NOT_FOUND", "node not found: %s" % node_path, MCPError.HINT_NODE_PATH)

	return {"value": MCPCoerce.serialize_value(node.get(property_name))}


static func _cmd_node_set_property(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return MCPError.make("NO_SCENE", "no edited scene")

	var node_path := str(parameters.get("node_path", ""))
	var property_name := str(parameters.get("property", ""))
	var raw_value = parameters.get("value", null)

	if node_path.is_empty() or property_name.is_empty():
		return MCPError.make("INVALID_PARAMS", "missing node_path or property")

	var node := root.get_node_or_null(node_path)
	if node == null:
		return MCPError.make("NOT_FOUND", "node not found: %s" % node_path, MCPError.HINT_NODE_PATH)

	var missing := MCPCoerce.check_resource_paths(raw_value)
	if missing != "":
		return MCPError.make("LOAD_FAILED",
			"failed to load resource at %s; verify the path or use resource.write to create it first" % missing)

	var coerced = MCPCoerce.coerce_value(raw_value)
	node.set(property_name, coerced)
	return {"ok": true}


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
		return MCPError.make("NO_SCENE", "no edited scene")
	var node_path := str(parameters.get("node_path", ""))
	var node = _resolve_scene_node(node_path)
	if node == null:
		return MCPError.make("NOT_FOUND", "node not found: %s" % node_path, MCPError.HINT_NODE_PATH)
	var mask := str(parameters.get("mask", "common"))
	if not (mask in ["common", "all", "groups"]):
		return MCPError.make("INVALID_PARAMS",
			"mask must be 'common', 'all', or 'groups' (got '%s')" % mask)
	var common_names: Array[String] = []
	if mask == "common":
		common_names = _resolve_common_property_names(node)
	var properties: Array = []
	for property in node.get_property_list():
		var usage: int = int(property.get("usage", 0))
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		var property_name := str(property.get("name", ""))
		if property_name.is_empty() or property_name.begins_with("_"):
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
	if not MCPFeatureGate.is_enabled("node_call_method"):
		return MCPFeatureGate.disabled_error("node_call_method")
	var root := _get_edited_root()
	if root == null:
		return MCPError.make("NO_SCENE", "no open scene; use scene.open or scene.create first")

	var node_path := str(parameters.get("node_path", ""))
	var method_name := str(parameters.get("method_name", ""))
	var args_raw = parameters.get("args", [])
	# Resource refs in args are validated via MCPCoerce.check_resource_paths,
	# which gates through FileGuard. node_path is a scene-tree path, not filesystem.

	if node_path.is_empty() or method_name.is_empty():
		return MCPError.make("INVALID_PARAMS", "missing node_path or method_name")
	if typeof(args_raw) != TYPE_ARRAY:
		return MCPError.make("INVALID_PARAMS",
			"args must be an Array (got %s)" % typeof(args_raw))

	var node := root.get_node_or_null(node_path)
	if node == null:
		return MCPError.make("NOT_FOUND", "no node at path %s" % node_path, MCPError.HINT_NODE_PATH)
	if not node.has_method(method_name):
		return MCPError.make("INVALID_METHOD",
			"node %s has no method '%s'; use scene.get_tree or inspect the script class via ClassDB" % [
				node_path, method_name])

	var missing := MCPCoerce.check_resource_paths(args_raw)
	if missing != "":
		return MCPError.make("LOAD_FAILED",
			"failed to load resource at %s; verify the path or use resource.write to create it first" % missing)

	var coerced_args = MCPCoerce.coerce_value(args_raw)
	if typeof(coerced_args) != TYPE_ARRAY:
		coerced_args = []
	push_warning("MCP: node.call_method invoked %s.%s(%d args)" % [
		node_path, method_name, (coerced_args as Array).size()])
	var result = node.callv(method_name, coerced_args)

	return {
		"success": true,
		"path": node_path,
		"method": method_name,
		"result": MCPCoerce.serialize_value(result),
	}


static func _cmd_node_set_script(parameters: Dictionary) -> Dictionary:
	var root := _get_edited_root()
	if root == null:
		return MCPError.make("NO_SCENE", "no edited scene")

	var node_path := str(parameters.get("node_path", ""))
	if node_path.is_empty():
		return MCPError.make("INVALID_PARAMS", "missing node_path")

	var node := root.get_node_or_null(node_path)
	if node == null:
		return MCPError.make("NOT_FOUND", "node not found: %s" % node_path, MCPError.HINT_NODE_PATH)

	var script_path := str(parameters.get("script_path", ""))

	if script_path.is_empty():
		node.set_script(null)
		return {"success": true, "path": node_path, "script": null, "properties": []}

	var guard := MCPFileGuard.resolve_safe(script_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))

	var loaded = ResourceLoader.load(script_path)
	if loaded == null:
		return MCPError.make("LOAD_FAILED",
			"cannot load script at %s; verify the path or use script.write to create it first" % script_path)
	if not (loaded is Script):
		return MCPError.make("INVALID_PARAMS",
			"resource at %s is not a Script (got %s)" % [script_path, loaded.get_class()])

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
