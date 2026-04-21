@tool
extends RefCounted
## animation.* command handlers — keyframe (add/remove) and get_keys on AnimationPlayer tracks.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPCoerce = _Hub.MCPCoerce
const MCPCommandRegistry = _Hub.MCPCommandRegistry
const MCPUntrusted = _Hub.MCPUntrusted


static func register(registry: MCPCommandRegistry, server: Node) -> void:
	registry.add("animation.keyframe", func(parameters: Dictionary) -> Dictionary:
		return _cmd_animation_keyframe(server, parameters))
	registry.add("animation.get_keys", func(parameters: Dictionary) -> Dictionary:
		return _cmd_animation_get_keys(parameters))


# -- Helpers ------------------------------------------------------------------


static func _resolve_scene_node(node_path: String) -> Variant:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	if node_path.is_empty() or node_path == ".":
		return root
	return root.get_node_or_null(node_path)


static func _resolve_animation(
	player_path: String, animation_name: String,
) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"code": "NO_SCENE", "error": "no edited scene"}
	if player_path.is_empty():
		return {"code": "INVALID_PARAMS", "error": "missing player_path"}
	var node = _resolve_scene_node(player_path)
	if node == null:
		return {"code": "NOT_FOUND",
			"error": "no node at player_path %s" % player_path}
	if not (node is AnimationPlayer):
		return {"code": "INVALID_CLASS",
			"error": "node at %s is not an AnimationPlayer (got %s)" % [
				player_path, node.get_class()]}
	var player := node as AnimationPlayer
	if animation_name.is_empty():
		return {"code": "INVALID_PARAMS", "error": "missing animation_name"}
	if not player.has_animation(animation_name):
		var available: Array = []
		for name_entry in player.get_animation_list():
			available.append(str(name_entry))
			if available.size() >= 10:
				available.append("…")
				break
		return {"code": "NOT_FOUND",
			"error": "no animation '%s' on player %s; available: %s" % [
				animation_name, player_path, ", ".join(available)]}
	return {"player": player, "anim": player.get_animation(animation_name)}


static func _track_type_name(track_type: int) -> String:
	match track_type:
		Animation.TYPE_VALUE: return "value"
		Animation.TYPE_POSITION_3D: return "position_3d"
		Animation.TYPE_ROTATION_3D: return "rotation_3d"
		Animation.TYPE_SCALE_3D: return "scale_3d"
		Animation.TYPE_BLEND_SHAPE: return "blend_shape"
		Animation.TYPE_METHOD: return "method"
		Animation.TYPE_BEZIER: return "bezier"
		Animation.TYPE_AUDIO: return "audio"
		Animation.TYPE_ANIMATION: return "animation"
		_: return "unknown(%d)" % track_type


# -- Commands -----------------------------------------------------------------


static func _cmd_animation_keyframe(
	server: Node, parameters: Dictionary,
) -> Dictionary:
	var action := str(parameters.get("action", ""))
	if not (action in ["add", "remove"]):
		return MCPError.make("INVALID_PARAMS",
			"action must be 'add' or 'remove' (got '%s')" % action)
	var player_path := str(parameters.get("player_path", ""))
	var animation_name := str(parameters.get("animation_name", ""))
	var track_path := str(parameters.get("track_path", ""))
	var time_raw = parameters.get("time", -1.0)
	var time := float(time_raw) \
		if (typeof(time_raw) == TYPE_FLOAT or typeof(time_raw) == TYPE_INT) else -1.0
	if time < 0.0:
		return MCPError.make("INVALID_PARAMS",
			"time must be >= 0 (got %f)" % time)
	if track_path.is_empty():
		return MCPError.make("INVALID_PARAMS", "missing track_path")
	if action == "add":
		if not track_path.contains(":"):
			return MCPError.make("INVALID_PARAMS",
				"track_path must include a property (e.g. 'Sprite2D:position')")
		var track_type_param := str(parameters.get("track_type", ""))
		if not track_type_param.is_empty() and track_type_param != "value":
			return MCPError.make("INVALID_PARAMS",
				"track_type='%s' not supported (only 'value' / default)" % track_type_param)
		if not parameters.has("value"):
			return MCPError.make("INVALID_PARAMS",
				"missing value (required for action='add')")
		var raw_value = parameters.get("value", null)
		var resolved := _resolve_animation(player_path, animation_name)
		if resolved.has("error"):
			return MCPError.make(str(resolved["code"]), str(resolved["error"]))
		var animation: Animation = resolved["anim"]
		var missing := MCPCoerce.check_resource_paths(raw_value)
		if missing != "":
			return MCPError.make("LOAD_FAILED",
				"failed to load resource at %s" % missing)
		var coerced = MCPCoerce.coerce_value(raw_value)
		var track_index := -1
		var track_path_node_path := NodePath(track_path)
		for index in range(animation.get_track_count()):
			if animation.track_get_path(index) == track_path_node_path:
				track_index = index
				break
		if track_index == -1:
			track_index = animation.add_track(Animation.TYPE_VALUE)
			animation.track_set_path(track_index, track_path_node_path)
		var existing_index := animation.track_find_key(
			track_index, time, Animation.FIND_MODE_EXACT)
		if existing_index != -1:
			return {
				"success": true,
				"status": "returned",
				"player_path": player_path,
				"animation_name": animation_name,
				"track_path": track_path,
				"track_idx": track_index,
				"time": time,
				"key_idx": existing_index,
				"value": MCPCoerce.serialize_value(
					animation.track_get_key_value(track_index, existing_index)),
			}
		var undo_redo := EditorInterface.get_editor_undo_redo()
		undo_redo.create_action("MCP: animation.keyframe add %s @ %s" % [track_path, time])
		undo_redo.add_do_method(animation, "track_insert_key", track_index, time, coerced)
		undo_redo.add_undo_method(
			server, "_animation_remove_key_at", animation, track_index, time)
		undo_redo.add_undo_reference(animation)
		undo_redo.commit_action()
		var new_index := animation.track_find_key(
			track_index, time, Animation.FIND_MODE_EXACT)
		return {
			"success": true,
			"status": "created",
			"player_path": player_path,
			"animation_name": animation_name,
			"track_path": track_path,
			"track_idx": track_index,
			"time": time,
			"key_idx": new_index,
			"value": MCPCoerce.serialize_value(coerced),
		}
	else:
		var resolved := _resolve_animation(player_path, animation_name)
		if resolved.has("error"):
			return MCPError.make(str(resolved["code"]), str(resolved["error"]))
		var animation: Animation = resolved["anim"]
		var track_index := -1
		var track_path_node_path := NodePath(track_path)
		for index in range(animation.get_track_count()):
			if animation.track_get_path(index) == track_path_node_path:
				track_index = index
				break
		if track_index == -1:
			return MCPError.make("NOT_FOUND",
				"no track '%s' on animation '%s'" % [track_path, animation_name])
		var key_index := animation.track_find_key(
			track_index, time, Animation.FIND_MODE_EXACT)
		if key_index == -1:
			return MCPError.make("NOT_FOUND",
				"no key at time=%f on track '%s'" % [time, track_path])
		var captured_value = animation.track_get_key_value(track_index, key_index)
		var serialised_value = MCPCoerce.serialize_value(captured_value)
		var undo_redo := EditorInterface.get_editor_undo_redo()
		undo_redo.create_action("MCP: animation.keyframe remove %s @ %s" % [track_path, time])
		undo_redo.add_do_method(
			server, "_animation_remove_key_at", animation, track_index, time)
		undo_redo.add_undo_method(
			server, "_animation_insert_key_silent", animation, track_index, time, captured_value)
		undo_redo.add_undo_reference(animation)
		undo_redo.commit_action()
		return {
			"success": true,
			"player_path": player_path,
			"animation_name": animation_name,
			"track_path": track_path,
			"time": time,
			"removed_value": serialised_value,
		}


static func _cmd_animation_get_keys(parameters: Dictionary) -> Dictionary:
	var player_path := str(parameters.get("player_path", ""))
	var animation_name := str(parameters.get("animation_name", ""))
	var track_path := str(parameters.get("track_path", ""))
	if track_path.is_empty():
		return MCPError.make("INVALID_PARAMS", "missing track_path")
	var resolved := _resolve_animation(player_path, animation_name)
	if resolved.has("error"):
		return MCPError.make(str(resolved["code"]), str(resolved["error"]))
	var animation: Animation = resolved["anim"]
	var track_index := -1
	var track_path_node_path := NodePath(track_path)
	for index in range(animation.get_track_count()):
		if animation.track_get_path(index) == track_path_node_path:
			track_index = index
			break
	if track_index == -1:
		return MCPError.make("NOT_FOUND",
			"no track '%s' on animation '%s'" % [track_path, animation_name])
	var keys: Array = []
	for key_index in range(animation.track_get_key_count(track_index)):
		keys.append({
			"time": animation.track_get_key_time(track_index, key_index),
			"value": MCPCoerce.serialize_value(
				animation.track_get_key_value(track_index, key_index)),
			"transition": animation.track_get_key_transition(track_index, key_index),
		})
	return {
		"success": true,
		"player_path": player_path,
		"animation_name": animation_name,
		"track_path": track_path,
		"track_idx": track_index,
		"track_type": _track_type_name(animation.track_get_type(track_index)),
		"length": animation.length,
		"keys": MCPUntrusted.wrap(
			"animation", "%s/%s" % [player_path, animation_name],
			JSON.stringify(keys)),
	}
