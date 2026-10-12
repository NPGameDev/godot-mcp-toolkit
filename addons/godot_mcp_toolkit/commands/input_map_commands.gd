@tool
extends RefCounted
## input_map.* command handlers — action (add/remove) and event (bind/unbind).

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")

## The engine's [code]ProjectSettings::NO_BUILTIN_ORDER_BASE[/code] ([code]1 << 16[/code] on
## 4.2–4.7): the engine orders each setting it registers itself below this value and each
## setting a project adds above it. Its [code]is_builtin_setting()[/code] makes the same
## comparison, but scripts cannot call it.
const NO_BUILTIN_ORDER_BASE := 1 << 16


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("input_map.action", func(parameters: Dictionary) -> Dictionary:
		return _cmd_input_map_action(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("input_map.event", func(parameters: Dictionary) -> Dictionary:
		return _cmd_input_map_event(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())


# -- Input event helpers ------------------------------------------------------


static func _build_input_event(event: Variant) -> Variant:
	if typeof(event) != TYPE_DICTIONARY:
		return {"code": "INVALID_PARAMS", "error": "event must be an object"}
	var event_type := str(event.get("type", ""))
	match event_type:
		"key":
			var raw_keycode = event.get("keycode", "")
			var resolved_keycode := 0
			if typeof(raw_keycode) == TYPE_STRING:
				var keycode_str: String = raw_keycode
				if keycode_str.begins_with("KEY_"):
					keycode_str = keycode_str.substr(4)
				resolved_keycode = OS.find_keycode_from_string(keycode_str)
				if resolved_keycode == 0:
					return {"code": "INVALID_PARAMS",
						"error": "unknown keycode '%s'; use symbolic names like 'SPACE' / 'A' / 'F1' or raw ints" % raw_keycode}
			elif typeof(raw_keycode) == TYPE_INT or typeof(raw_keycode) == TYPE_FLOAT:
				resolved_keycode = int(raw_keycode)
			else:
				return {"code": "INVALID_PARAMS",
					"error": "event.keycode must be a string symbolic name or int"}
			var key_event := InputEventKey.new()
			key_event.physical_keycode = resolved_keycode
			key_event.shift_pressed = bool(event.get("shift", false))
			key_event.ctrl_pressed = bool(event.get("ctrl", false))
			key_event.alt_pressed = bool(event.get("alt", false))
			key_event.meta_pressed = bool(event.get("meta", false))
			return key_event
		"mouse_button":
			var mouse_event := InputEventMouseButton.new()
			mouse_event.button_index = int(event.get("button_index", 1))
			mouse_event.pressed = bool(event.get("pressed", true))
			return mouse_event
		"joypad_button":
			var joypad_button_event := InputEventJoypadButton.new()
			joypad_button_event.button_index = int(event.get("button_index", 0))
			joypad_button_event.device = int(event.get("device", -1))
			return joypad_button_event
		"joypad_motion":
			var joypad_motion_event := InputEventJoypadMotion.new()
			joypad_motion_event.axis = int(event.get("axis", 0))
			joypad_motion_event.axis_value = float(event.get("axis_value", 0.0))
			joypad_motion_event.device = int(event.get("device", -1))
			return joypad_motion_event
		_:
			return {"code": "INVALID_PARAMS",
				"error": "event.type must be one of 'key' | 'mouse_button' | 'joypad_button' | 'joypad_motion' (got %s)" % event_type}


static func _serialise_input_event(event: InputEvent) -> Dictionary:
	if event is InputEventKey:
		var kc: int = int((event as InputEventKey).physical_keycode)
		return {
			"type": "key",
			"keycode": kc,
			"keycode_name": OS.get_keycode_string(kc),
			"shift": (event as InputEventKey).shift_pressed,
			"ctrl": (event as InputEventKey).ctrl_pressed,
			"alt": (event as InputEventKey).alt_pressed,
			"meta": (event as InputEventKey).meta_pressed,
		}
	if event is InputEventMouseButton:
		return {
			"type": "mouse_button",
			"button_index": int((event as InputEventMouseButton).button_index),
			"pressed": (event as InputEventMouseButton).pressed,
		}
	if event is InputEventJoypadButton:
		return {
			"type": "joypad_button",
			"button_index": int((event as InputEventJoypadButton).button_index),
			"device": int((event as InputEventJoypadButton).device),
		}
	if event is InputEventJoypadMotion:
		return {
			"type": "joypad_motion",
			"axis": int((event as InputEventJoypadMotion).axis),
			"axis_value": float((event as InputEventJoypadMotion).axis_value),
			"device": int((event as InputEventJoypadMotion).device),
		}
	return {"type": "unknown", "class": event.get_class()}


static func _input_events_equivalent(
	event_a: InputEvent, event_b: InputEvent,
) -> bool:
	if event_a == null or event_b == null:
		return false
	if event_a.get_class() != event_b.get_class():
		return false
	if event_a is InputEventKey and event_b is InputEventKey:
		var key_a := event_a as InputEventKey
		var key_b := event_b as InputEventKey
		return key_a.physical_keycode == key_b.physical_keycode \
			and key_a.shift_pressed == key_b.shift_pressed \
			and key_a.ctrl_pressed == key_b.ctrl_pressed \
			and key_a.alt_pressed == key_b.alt_pressed \
			and key_a.meta_pressed == key_b.meta_pressed
	if event_a is InputEventMouseButton and event_b is InputEventMouseButton:
		var mouse_a := event_a as InputEventMouseButton
		var mouse_b := event_b as InputEventMouseButton
		return mouse_a.button_index == mouse_b.button_index \
			and mouse_a.pressed == mouse_b.pressed
	if event_a is InputEventJoypadButton and event_b is InputEventJoypadButton:
		var joypad_a := event_a as InputEventJoypadButton
		var joypad_b := event_b as InputEventJoypadButton
		return joypad_a.button_index == joypad_b.button_index \
			and joypad_a.device == joypad_b.device
	if event_a is InputEventJoypadMotion and event_b is InputEventJoypadMotion:
		var motion_a := event_a as InputEventJoypadMotion
		var motion_b := event_b as InputEventJoypadMotion
		return motion_a.axis == motion_b.axis \
			and motion_a.device == motion_b.device \
			and is_equal_approx(motion_a.axis_value, motion_b.axis_value)
	return false


static func _persist_input_action(action: String, deadzone: float) -> void:
	var events: Array = []
	for event in InputMap.action_get_events(action):
		events.append(event)
	ProjectSettings.set_setting("input/" + action, {
		"deadzone": deadzone,
		"events": events,
	})
	var error := ProjectSettings.save()
	if error != OK:
		push_warning(
			"[MCPServer] ProjectSettings.save after input_map mutation failed (err %d, action=%s); change is in-memory only" % [
				error, action])


## Returns whether [param action] is a built-in action: one the engine registers for every
## project, rather than a project action saved in project.godot. It asks the engine's
## registration order instead of matching a name list, so it stays exact on every engine
## version and never mistakes a project action named [code]ui_*[/code] for a built-in one.
static func _is_builtin_action(action: String) -> bool:
	var setting_name := "input/" + action
	# get_order() logs an error for a setting that does not exist.
	return ProjectSettings.has_setting(setting_name) \
		and ProjectSettings.get_order(setting_name) < NO_BUILTIN_ORDER_BASE


## Rebuilds the project action [param action] in the editor's InputMap from its
## [code]input/<name>[/code] setting, or drops it from InputMap when that setting is gone.
## The editor loads only the built-in actions into its InputMap (the engine calls
## [code]InputMap::load_default()[/code] when it runs the editor), so a project action exists
## there only as its setting. Project Settings edits, renames and deletes an action through
## that setting alone, so running this on every call keeps the next save from undoing a
## change made there since the previous call. A built-in action is left alone: the editor's
## own controls respond to it.
static func _load_project_action(action: String) -> void:
	if _is_builtin_action(action):
		return
	if InputMap.has_action(action):
		InputMap.erase_action(action)
	var setting: Variant = ProjectSettings.get_setting("input/" + action)
	if typeof(setting) != TYPE_DICTIONARY:
		return
	InputMap.add_action(action, float(setting.get("deadzone", 0.5)))
	var events: Variant = setting.get("events", [])
	if typeof(events) != TYPE_ARRAY:
		return
	for event in events:
		if event is InputEvent:
			InputMap.action_add_event(action, event)


# -- Commands -----------------------------------------------------------------


static func _cmd_input_map_action(parameters: Dictionary) -> Dictionary:
	var action := str(parameters.get("action", ""))
	if not (action in ["add", "remove"]):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"action must be 'add' or 'remove' (got '%s')" % action)
	var action_name := str(parameters.get("name", ""))
	if action_name.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "name must be a non-empty string")
	if action == "add":
		var deadzone_raw = parameters.get("deadzone", 0.5)
		var deadzone := float(deadzone_raw) \
			if (typeof(deadzone_raw) == TYPE_FLOAT or typeof(deadzone_raw) == TYPE_INT) else 0.5
		if deadzone < 0.0 or deadzone > 1.0:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"deadzone must be in [0.0, 1.0] (got %f)" % deadzone)
		_load_project_action(action_name)
		if InputMap.has_action(action_name):
			return MCPToolkitSuccess.ok({
				"status": "returned",
				"name": action_name,
				"deadzone": InputMap.action_get_deadzone(action_name),
			})
		InputMap.add_action(action_name, deadzone)
		_persist_input_action(action_name, deadzone)
		return MCPToolkitSuccess.ok({
			"status": "created",
			"name": action_name,
			"deadzone": deadzone,
		})
	else:
		_load_project_action(action_name)
		if not InputMap.has_action(action_name):
			return MCPToolkitError.fail("NOT_FOUND", "no action '%s'" % action_name)
		if _is_builtin_action(action_name):
			return MCPToolkitError.fail("INVALID_PARAMS",
				"refusing to remove built-in UI action '%s'; use input_map.event to unbind its events instead" % action_name)
		InputMap.erase_action(action_name)
		if ProjectSettings.has_setting("input/" + action_name):
			ProjectSettings.clear("input/" + action_name)
			var error := ProjectSettings.save()
			if error != OK:
				push_warning(
					"[MCPServer] ProjectSettings.save after input_map.action remove failed (err %d, action=%s)" % [
						error, action_name])
		return MCPToolkitSuccess.ok({"name": action_name})


static func _cmd_input_map_event(parameters: Dictionary) -> Dictionary:
	var action := str(parameters.get("action", ""))
	if not (action in ["bind", "unbind"]):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"action must be 'bind' or 'unbind' (got '%s')" % action)
	var action_name := str(parameters.get("name", ""))
	if action_name.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "name must be a non-empty string")
	var built: Variant = _build_input_event(parameters.get("event", null))
	if typeof(built) == TYPE_DICTIONARY and built.has("error"):
		return MCPToolkitError.fail(str(built["code"]), str(built["error"]))
	var event: InputEvent = built
	_load_project_action(action_name)
	if not InputMap.has_action(action_name):
		return MCPToolkitError.fail("NOT_FOUND",
			"no action '%s'; call input_map.action with action='add' first" % action_name)
	if action == "bind":
		for existing in InputMap.action_get_events(action_name):
			if _input_events_equivalent(existing, event):
				return MCPToolkitSuccess.ok({
					"status": "returned",
					"name": action_name,
					"event": _serialise_input_event(existing),
				})
		InputMap.action_add_event(action_name, event)
		_persist_input_action(action_name, InputMap.action_get_deadzone(action_name))
		return MCPToolkitSuccess.ok({
			"status": "created",
			"name": action_name,
			"event": _serialise_input_event(event),
		})
	else:
		var existing_events := InputMap.action_get_events(action_name)
		var matched: InputEvent = null
		for existing in existing_events:
			if _input_events_equivalent(existing, event):
				matched = existing
				break
		if matched == null:
			return MCPToolkitError.fail("NOT_FOUND",
				"no matching event on action '%s' (found %d events)" % [
					action_name, existing_events.size()])
		InputMap.action_erase_event(action_name, matched)
		_persist_input_action(action_name, InputMap.action_get_deadzone(action_name))
		return MCPToolkitSuccess.ok({
			"name": action_name,
			"event": _serialise_input_event(matched),
		})
