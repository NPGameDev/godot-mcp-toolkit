@tool
extends RefCounted
## animation.* command handlers — keyframe (add/remove) and get_keys on AnimationPlayer tracks.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Coerce = Modules.Coerce
const Untrusted = Modules.Untrusted
const Helpers = Modules.CommandHelpers


static func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:
	registry.add("animation.keyframe", func(parameters: Dictionary) -> Dictionary:
		return _cmd_animation_keyframe(server, parameters)
	, MCPToolkitCommandOptions.new())
	registry.add("animation.get_keys", func(parameters: Dictionary) -> Dictionary:
		return _cmd_animation_get_keys(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only())
	registry.add("animationtree.edit", func(parameters: Dictionary) -> Dictionary:
		return _cmd_animationtree_edit(server, parameters)
	, MCPToolkitCommandOptions.new())
	registry.add("animationtree.list", func(parameters: Dictionary) -> Dictionary:
		return _cmd_animationtree_list(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only())


# -- Helpers ------------------------------------------------------------------


static func _resolve_scene_node(node_path: String) -> Variant:
	return Helpers.resolve_scene_node(node_path)


static func _resolve_animation(
	player_path: String, animation_name: String,
) -> Dictionary:
	var root := Helpers.get_edited_root()
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
		# Auto-create: if "library/anim" format and the library exists, create the Animation.
		var slash_pos := animation_name.find("/")
		if slash_pos != -1:
			var lib_name := animation_name.substr(0, slash_pos)
			var anim_key := animation_name.substr(slash_pos + 1)
			if player.has_animation_library(lib_name):
				var lib := player.get_animation_library(lib_name)
				var new_anim := Animation.new()
				lib.add_animation(anim_key, new_anim)
				return {"player": player, "anim": new_anim, "auto_created": true}
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
		return MCPToolkitError.fail("INVALID_PARAMS",
			"action must be 'add' or 'remove' (got '%s')" % action)
	var player_path := str(parameters.get("player_path", ""))
	player_path = Helpers.normalize_editor_path(player_path)
	var animation_name := str(parameters.get("animation_name", ""))
	var track_path := str(parameters.get("track_path", ""))
	var time_raw = parameters.get("time", -1.0)
	var time := float(time_raw) \
		if (typeof(time_raw) == TYPE_FLOAT or typeof(time_raw) == TYPE_INT) else -1.0
	if time < 0.0:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"time must be >= 0 (got %f)" % time)
	if track_path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing track_path")
	if action == "add":
		if not track_path.contains(":"):
			return MCPToolkitError.fail("INVALID_PARAMS",
				"track_path must include a property (e.g. 'Sprite2D:position')")
		var track_type_param := str(parameters.get("track_type", ""))
		if not track_type_param.is_empty() and track_type_param != "value":
			return MCPToolkitError.fail("INVALID_PARAMS",
				"track_type='%s' not supported (only 'value' / default)" % track_type_param)
		if not parameters.has("value"):
			return MCPToolkitError.fail("INVALID_PARAMS",
				"missing value (required for action='add')")
		var raw_value = parameters.get("value", null)
		var resolved := _resolve_animation(player_path, animation_name)
		if resolved.has("error"):
			return MCPToolkitError.fail(str(resolved["code"]), str(resolved["error"]))
		var animation: Animation = resolved["anim"]
		var player: AnimationPlayer = resolved["player"]
		var missing := Coerce.check_resource_paths(raw_value)
		if missing != "":
			return MCPToolkitError.fail("LOAD_FAILED",
				"failed to load resource at %s" % missing)
		var coerced = Coerce.coerce_value(raw_value)
		if typeof(coerced) == TYPE_DICTIONARY and (coerced as Dictionary).has("_coerce_error"):
			return MCPToolkitError.fail("INVALID_PARAMS", str(coerced["_coerce_error"]))
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
			return MCPToolkitSuccess.ok({
				"status": "returned",
				"player_path": player_path,
				"animation_name": animation_name,
				"track_path": track_path,
				"track_idx": track_index,
				"time": time,
				"key_idx": existing_index,
				"value": Coerce.serialize_value(
					animation.track_get_key_value(track_index, existing_index)),
			})
		animation.track_insert_key(track_index, time, coerced)
		MCPToolkitUndoRedoAction.begin("animation.keyframe add %s @ %s" % [track_path, time], player) \
			.do_method(animation.track_insert_key.bind(track_index, time, coerced)) \
			.undo_method(server.undo_helpers._animation_remove_key_at.bind(animation, track_index, time)) \
			.undo_reference(animation) \
			.commit_recorded()
		var new_index := animation.track_find_key(
			track_index, time, Animation.FIND_MODE_EXACT)
		# Persist external library to disk so runtime can find the animation.
		var _slash := animation_name.find("/")
		if _slash != -1:
			var _lib_name := animation_name.substr(0, _slash)
			var _lib := player.get_animation_library(_lib_name)
			if _lib != null and not _lib.resource_path.is_empty():
				ResourceSaver.save(_lib)
		return MCPToolkitSuccess.ok({
			"status": "created",
			"player_path": player_path,
			"animation_name": animation_name,
			"track_path": track_path,
			"track_idx": track_index,
			"time": time,
			"key_idx": new_index,
			"value": Coerce.serialize_value(coerced),
		})
	else:
		var resolved := _resolve_animation(player_path, animation_name)
		if resolved.has("error"):
			return MCPToolkitError.fail(str(resolved["code"]), str(resolved["error"]))
		var animation: Animation = resolved["anim"]
		var track_index := -1
		var track_path_node_path := NodePath(track_path)
		for index in range(animation.get_track_count()):
			if animation.track_get_path(index) == track_path_node_path:
				track_index = index
				break
		if track_index == -1:
			return MCPToolkitError.fail("NOT_FOUND",
				"no track '%s' on animation '%s'" % [track_path, animation_name])
		var key_index := animation.track_find_key(
			track_index, time, Animation.FIND_MODE_EXACT)
		if key_index == -1:
			return MCPToolkitError.fail("NOT_FOUND",
				"no key at time=%f on track '%s'" % [time, track_path])
		var captured_value = animation.track_get_key_value(track_index, key_index)
		var serialised_value = Coerce.serialize_value(captured_value)
		server.undo_helpers._animation_remove_key_at(animation, track_index, time)
		MCPToolkitUndoRedoAction.begin("animation.keyframe remove %s @ %s" % [track_path, time], resolved["player"]) \
			.do_method(server.undo_helpers._animation_remove_key_at.bind(animation, track_index, time)) \
			.undo_method(server.undo_helpers._animation_insert_key_silent.bind(animation, track_index, time, captured_value)) \
			.undo_reference(animation) \
			.commit_recorded()
		return MCPToolkitSuccess.ok({
			"player_path": player_path,
			"animation_name": animation_name,
			"track_path": track_path,
			"time": time,
			"removed_value": serialised_value,
		})


static func _cmd_animation_get_keys(parameters: Dictionary) -> Dictionary:
	var player_path := str(parameters.get("player_path", ""))
	player_path = Helpers.normalize_editor_path(player_path)
	var animation_name := str(parameters.get("animation_name", ""))
	var track_path := str(parameters.get("track_path", ""))
	if track_path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing track_path")
	var resolved := _resolve_animation(player_path, animation_name)
	if resolved.has("error"):
		return MCPToolkitError.fail(str(resolved["code"]), str(resolved["error"]))
	var animation: Animation = resolved["anim"]
	var track_index := -1
	var track_path_node_path := NodePath(track_path)
	for index in range(animation.get_track_count()):
		if animation.track_get_path(index) == track_path_node_path:
			track_index = index
			break
	if track_index == -1:
		return MCPToolkitError.fail("NOT_FOUND",
			"no track '%s' on animation '%s'" % [track_path, animation_name])
	var keys: Array = []
	for key_index in range(animation.track_get_key_count(track_index)):
		keys.append({
			"time": animation.track_get_key_time(track_index, key_index),
			"value": Coerce.serialize_value(
				animation.track_get_key_value(track_index, key_index)),
			"transition": animation.track_get_key_transition(track_index, key_index),
		})
	return MCPToolkitSuccess.ok({
		"player_path": player_path,
		"animation_name": animation_name,
		"track_path": track_path,
		"track_idx": track_index,
		"track_type": _track_type_name(animation.track_get_type(track_index)),
		"length": animation.length,
		"keys": Untrusted.wrap(
			"animation", "%s/%s" % [player_path, animation_name],
			JSON.stringify(keys)),
	})


# -- AnimationTree editing ----------------------------------------------------


static func _resolve_tree(node_path: String) -> Variant:
	var root := Helpers.get_edited_root()
	if root == null:
		return MCPToolkitError.fail("NO_SCENE", "no edited scene")
	if node_path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing node_path")
	var node = _resolve_scene_node(node_path)
	if node == null:
		return MCPToolkitError.fail("NOT_FOUND", "no node at %s" % node_path)
	if not (node is AnimationTree):
		return MCPToolkitError.fail("INVALID_CLASS",
			"node at %s is not an AnimationTree (got %s)" % [node_path, node.get_class()])
	return node


static func _resolve_state_machine(tree: AnimationTree) -> Variant:
	var tree_root = tree.tree_root
	if tree_root == null:
		return MCPToolkitError.fail("INVALID_STATE", "AnimationTree has no tree_root set")
	if not (tree_root is AnimationNodeStateMachine):
		return MCPToolkitError.fail("INVALID_STATE",
			"tree_root is %s, not AnimationNodeStateMachine" % tree_root.get_class())
	return tree_root


static func _switch_mode_from_string(mode_str: String) -> int:
	match mode_str:
		"immediate": return 0
		"sync": return 1
		"at_end": return 2
		_: return 0


static func _switch_mode_to_string(mode_int: int) -> String:
	match mode_int:
		0: return "immediate"
		1: return "sync"
		2: return "at_end"
		_: return "immediate"


static func _advance_mode_from_string(mode_str: String) -> int:
	match mode_str:
		"disabled": return 0
		"enabled": return 1
		"auto": return 2
		_: return 1


static func _advance_mode_to_string(mode_int: int) -> String:
	match mode_int:
		0: return "disabled"
		1: return "enabled"
		2: return "auto"
		_: return "enabled"


static func _sm_summary(sm: AnimationNodeStateMachine) -> Dictionary:
	# get_node_list() is a 4.5+ script API (engine: bound to get_node_list_as_typed_array
	# in 4.5; absent on 4.2-4.4 → calling it errors and corrupts the return). Transitions
	# are countable on every version (get_transition_count is 4.2+).
	var summary := {"transitions_count": sm.get_transition_count()}
	if sm.has_method(&"get_node_list"):
		summary["nodes_count"] = sm.get_node_list().size()
	else:
		# On 4.2-4.4 node enumeration is unavailable, so omit nodes_count rather
		# than report a fabricated 0 that would read as a failed add.
		summary["note"] = "node enumeration unavailable on Godot 4.2-4.4 (get_node_list is 4.5+); nodes_count is omitted — verify the node via animationtree_list or the AnimationTree panel"
	return summary


static func _cmd_animationtree_list(parameters: Dictionary) -> Dictionary:
	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)
	var resolved = _resolve_tree(node_path)
	if resolved is Dictionary:
		return resolved
	var tree: AnimationTree = resolved
	return _at_list(tree)


static func _cmd_animationtree_edit(
	server: Node, parameters: Dictionary,
) -> Dictionary:
	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)
	var action := str(parameters.get("action", ""))
	if action.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing action")

	var resolved = _resolve_tree(node_path)
	if resolved is Dictionary:
		return resolved
	var tree: AnimationTree = resolved

	match action:
		"set_root":
			return _at_set_root(server, tree, node_path, parameters)
		"add_node":
			return _at_add_node(server, tree, node_path, parameters)
		"remove_node":
			return _at_remove_node(server, tree, node_path, parameters)
		"add_transition":
			return _at_add_transition(server, tree, node_path, parameters)
		"remove_transition":
			return _at_remove_transition(server, tree, node_path, parameters)
		"set_property":
			return _at_set_property(server, tree, node_path, parameters)
		_:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"unknown action '%s'; expected set_root|add_node|remove_node|add_transition|remove_transition|set_property" % action)


static func _at_set_root(
	server: Node, tree: AnimationTree, node_path: String,
	params: Dictionary,
) -> Dictionary:
	var root_type := str(params.get("root_type", "AnimationNodeStateMachine"))
	var new_root: AnimationNode = null
	match root_type:
		"AnimationNodeStateMachine":
			new_root = AnimationNodeStateMachine.new()
		"AnimationNodeBlendTree":
			new_root = AnimationNodeBlendTree.new()
		_:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"root_type must be 'AnimationNodeStateMachine' or 'AnimationNodeBlendTree' (got '%s')" % root_type)

	var old_root = tree.tree_root
	tree.tree_root = new_root
	var action := MCPToolkitUndoRedoAction.begin("animationtree.edit set_root %s" % node_path, tree) \
		.do_property(tree, &"tree_root", new_root) \
		.undo_property(tree, &"tree_root", old_root) \
		.do_reference(new_root)
	if old_root != null:
		action.undo_reference(old_root)
	action.commit_recorded()

	return MCPToolkitSuccess.ok({"root_type": root_type})


static func _at_add_node(
	server: Node, tree: AnimationTree, node_path: String,
	params: Dictionary,
) -> Dictionary:
	var sm_result = _resolve_state_machine(tree)
	if sm_result is Dictionary:
		return sm_result
	var sm: AnimationNodeStateMachine = sm_result

	var node_name := str(params.get("node_name", ""))
	if node_name.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing node_name")
	var node_type := str(params.get("node_type", "AnimationNodeAnimation"))

	# Idempotent: if the node already exists, return it.
	if sm.has_node(StringName(node_name)):
		var existing = sm.get_node(StringName(node_name))
		var summary := _sm_summary(sm)
		summary["status"] = "returned"
		summary["node_name"] = node_name
		summary["node_type"] = existing.get_class()
		return MCPToolkitSuccess.ok(summary)

	# Instantiate the AnimationNode by class name.
	if not ClassDB.class_exists(node_type):
		return MCPToolkitError.fail("INVALID_CLASS",
			"class '%s' does not exist" % node_type)
	if not ClassDB.is_parent_class(node_type, "AnimationNode"):
		return MCPToolkitError.fail("INVALID_CLASS",
			"'%s' is not an AnimationNode subclass" % node_type)
	var new_node: AnimationNode = ClassDB.instantiate(node_type) as AnimationNode
	if new_node == null:
		return MCPToolkitError.fail("INVALID_CLASS",
			"could not instantiate '%s'" % node_type)

	# For AnimationNodeAnimation, set the animation property.
	var anim_name := str(params.get("animation_name", ""))
	if not anim_name.is_empty() and new_node is AnimationNodeAnimation:
		(new_node as AnimationNodeAnimation).animation = StringName(anim_name)

	var pos := Vector2.ZERO
	var pos_dict = params.get("position", {})
	if typeof(pos_dict) == TYPE_DICTIONARY:
		pos = Vector2(float(pos_dict.get("x", 0)), float(pos_dict.get("y", 0)))

	sm.add_node(StringName(node_name), new_node, pos)
	MCPToolkitUndoRedoAction.begin("animationtree.edit add_node %s/%s" % [node_path, node_name], tree) \
		.do_method(sm.add_node.bind(StringName(node_name), new_node, pos)) \
		.undo_method(sm.remove_node.bind(StringName(node_name))) \
		.do_reference(new_node) \
		.commit_recorded()

	var summary := _sm_summary(sm)
	summary["status"] = "created"
	summary["node_name"] = node_name
	summary["node_type"] = node_type
	return MCPToolkitSuccess.ok(summary)


static func _at_remove_node(
	server: Node, tree: AnimationTree, node_path: String,
	params: Dictionary,
) -> Dictionary:
	var sm_result = _resolve_state_machine(tree)
	if sm_result is Dictionary:
		return sm_result
	var sm: AnimationNodeStateMachine = sm_result

	var node_name := str(params.get("node_name", ""))
	if node_name.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing node_name")
	if not sm.has_node(StringName(node_name)):
		return MCPToolkitError.fail("NOT_FOUND",
			"no node '%s' in state machine" % node_name)

	var old_node: AnimationNode = sm.get_node(StringName(node_name))
	var old_pos: Vector2 = sm.get_node_position(StringName(node_name))
	sm.remove_node(StringName(node_name))
	MCPToolkitUndoRedoAction.begin("animationtree.edit remove_node %s/%s" % [node_path, node_name], tree) \
		.do_method(sm.remove_node.bind(StringName(node_name))) \
		.undo_method(sm.add_node.bind(StringName(node_name), old_node, old_pos)) \
		.undo_reference(old_node) \
		.commit_recorded()

	var summary := _sm_summary(sm)
	summary["node_name"] = node_name
	return MCPToolkitSuccess.ok(summary)


static func _at_add_transition(
	server: Node, tree: AnimationTree, node_path: String,
	params: Dictionary,
) -> Dictionary:
	var sm_result = _resolve_state_machine(tree)
	if sm_result is Dictionary:
		return sm_result
	var sm: AnimationNodeStateMachine = sm_result

	var from := str(params.get("from", ""))
	var to := str(params.get("to", ""))
	if from.is_empty() or to.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing from or to")
	if not sm.has_node(StringName(from)):
		return MCPToolkitError.fail("NOT_FOUND", "no node '%s' in state machine" % from)
	if not sm.has_node(StringName(to)):
		return MCPToolkitError.fail("NOT_FOUND", "no node '%s' in state machine" % to)

	# Check for existing identical transition (idempotent).
	for i in range(sm.get_transition_count()):
		if str(sm.get_transition_from(i)) == from and str(sm.get_transition_to(i)) == to:
			var summary := _sm_summary(sm)
			summary["status"] = "returned"
			summary["from"] = from
			summary["to"] = to
			return MCPToolkitSuccess.ok(summary)

	var transition := AnimationNodeStateMachineTransition.new()

	var switch_mode_str := str(params.get("switch_mode", ""))
	if not switch_mode_str.is_empty():
		transition.switch_mode = _switch_mode_from_string(switch_mode_str)

	var advance_condition_str := str(params.get("advance_condition", ""))
	if not advance_condition_str.is_empty():
		transition.advance_condition = StringName(advance_condition_str)

	var advance_mode_str := str(params.get("advance_mode", ""))
	if not advance_mode_str.is_empty():
		transition.advance_mode = _advance_mode_from_string(advance_mode_str)

	sm.add_transition(StringName(from), StringName(to), transition)
	MCPToolkitUndoRedoAction.begin("animationtree.edit add_transition %s %s->%s" % [node_path, from, to], tree) \
		.do_method(sm.add_transition.bind(StringName(from), StringName(to), transition)) \
		.undo_method(server.undo_helpers._sm_remove_transition_by_endpoints.bind(sm, from, to)) \
		.do_reference(transition) \
		.commit_recorded()

	var summary := _sm_summary(sm)
	summary["status"] = "created"
	summary["from"] = from
	summary["to"] = to
	return MCPToolkitSuccess.ok(summary)


static func _at_remove_transition(
	server: Node, tree: AnimationTree, node_path: String,
	params: Dictionary,
) -> Dictionary:
	var sm_result = _resolve_state_machine(tree)
	if sm_result is Dictionary:
		return sm_result
	var sm: AnimationNodeStateMachine = sm_result

	var from := str(params.get("from", ""))
	var to := str(params.get("to", ""))
	if from.is_empty() or to.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing from or to")

	var found_idx := -1
	for i in range(sm.get_transition_count()):
		if str(sm.get_transition_from(i)) == from and str(sm.get_transition_to(i)) == to:
			found_idx = i
			break
	if found_idx == -1:
		return MCPToolkitError.fail("NOT_FOUND",
			"no transition from '%s' to '%s'" % [from, to])

	var old_transition: AnimationNodeStateMachineTransition = sm.get_transition(found_idx)
	sm.remove_transition_by_index(found_idx)
	MCPToolkitUndoRedoAction.begin("animationtree.edit remove_transition %s %s->%s" % [node_path, from, to], tree) \
		.do_method(sm.remove_transition_by_index.bind(found_idx)) \
		.undo_method(sm.add_transition.bind(StringName(from), StringName(to), old_transition)) \
		.undo_reference(old_transition) \
		.commit_recorded()

	var summary := _sm_summary(sm)
	summary["from"] = from
	summary["to"] = to
	return MCPToolkitSuccess.ok(summary)


static func _at_set_property(
	server: Node, tree: AnimationTree, node_path: String,
	params: Dictionary,
) -> Dictionary:
	var sm_result = _resolve_state_machine(tree)
	if sm_result is Dictionary:
		return sm_result
	var sm: AnimationNodeStateMachine = sm_result

	var target_node := str(params.get("target_node", ""))
	if target_node.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing target_node")
	var property := str(params.get("property", ""))
	if property.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing property")
	if not params.has("value"):
		return MCPToolkitError.fail("INVALID_PARAMS", "missing value")
	var value = params.get("value")

	if not sm.has_node(StringName(target_node)):
		return MCPToolkitError.fail("NOT_FOUND",
			"no node '%s' in state machine" % target_node)
	var anim_node: AnimationNode = sm.get_node(StringName(target_node))

	var old_value = anim_node.get(property)
	var coerced = Coerce.coerce_value(value)
	if typeof(coerced) == TYPE_DICTIONARY and (coerced as Dictionary).has("_coerce_error"):
		return MCPToolkitError.fail("INVALID_PARAMS", str(coerced["_coerce_error"]))

	anim_node.set(property, coerced)
	MCPToolkitUndoRedoAction.begin("animationtree.edit set_property %s/%s.%s" % [node_path, target_node, property], tree) \
		.do_property(anim_node, StringName(property), coerced) \
		.undo_property(anim_node, StringName(property), old_value) \
		.commit_recorded()

	var summary := _sm_summary(sm)
	summary["target_node"] = target_node
	summary["property"] = property
	return MCPToolkitSuccess.ok(summary)


static func _at_list(tree: AnimationTree) -> Dictionary:
	var tree_root = tree.tree_root
	if tree_root == null:
		return MCPToolkitSuccess.ok({"root_type": "none", "nodes": [], "transitions": []})

	var root_type := tree_root.get_class()
	if not (tree_root is AnimationNodeStateMachine):
		return MCPToolkitSuccess.ok({"root_type": root_type, "nodes": [], "transitions": []})

	var sm: AnimationNodeStateMachine = tree_root as AnimationNodeStateMachine
	var nodes: Array = []
	# get_node_list() is a 4.5+ script API (absent on 4.2-4.4 → errors); guard it so list
	# stays well-formed on older versions. Node enumeration is unavailable there (nodes:[]),
	# but transitions below still enumerate (get_transition_* are 4.2+).
	if sm.has_method(&"get_node_list"):
		for sn_name in sm.get_node_list():
			var anim_node: AnimationNode = sm.get_node(sn_name)
			# Robustness: skip an unreadable node rather than dereferencing null.
			if anim_node == null:
				continue
			var pos: Vector2 = sm.get_node_position(sn_name)
			var entry := {
				"name": str(sn_name),
				"type": anim_node.get_class(),
				"position": {"x": pos.x, "y": pos.y},
			}
			if anim_node is AnimationNodeAnimation:
				entry["animation"] = str((anim_node as AnimationNodeAnimation).animation)
			nodes.append(entry)

	var transitions: Array = []
	for i in range(sm.get_transition_count()):
		var tr: AnimationNodeStateMachineTransition = sm.get_transition(i)
		var t_entry := {
			"from": str(sm.get_transition_from(i)),
			"to": str(sm.get_transition_to(i)),
		}
		# Robustness: on some engine versions get_transition(i) can return null even
		# for an in-range index (Godot 4.2 runtime divergence). Emit the
		# endpoints we have and skip the transition-object fields rather than
		# dereferencing null (which would yield a malformed return → INTERNAL).
		if tr != null:
			t_entry["switch_mode"] = _switch_mode_to_string(tr.switch_mode)
			t_entry["advance_condition"] = str(tr.advance_condition)
			t_entry["advance_mode"] = _advance_mode_to_string(tr.advance_mode)
		transitions.append(t_entry)

	return MCPToolkitSuccess.ok({
		"root_type": root_type,
		"nodes": Untrusted.wrap(
			"animationtree", "nodes",
			JSON.stringify(nodes)),
		"transitions": Untrusted.wrap(
			"animationtree", "transitions",
			JSON.stringify(transitions)),
	})
