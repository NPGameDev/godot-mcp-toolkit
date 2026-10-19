@tool
extends RefCounted
## input_map.* command handlers — action (add/remove/rename) and event (bind/unbind).
##
## Every handler reads and writes the [code]input/<name>[/code] settings only, through
## [code]input_action_settings.gd[/code], and never the editor's InputMap: that InputMap holds
## only the built-in actions' keys, so a change written from it would replace a built-in
## action's saved events and drop its joypad defaults.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const InputActionSettings := preload("res://addons/godot_mcp_toolkit/commands/input_action_settings.gd")

var _settings: InputActionSettings


func _init() -> void:
	_settings = _create_settings()


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	var commands := new()
	registry.add("input_map.action", func(parameters: Dictionary) -> Dictionary:
		return commands._cmd_input_map_action(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("input_map.event", func(parameters: Dictionary) -> Dictionary:
		return commands._cmd_input_map_event(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())


## Returns the settings the handlers read and write. A test overrides it to hand in a
## subclass whose save does not write project.godot.
func _create_settings() -> InputActionSettings:
	return InputActionSettings.new()


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


## Returns whether [param event_a] and [param event_b] are the same binding. Key events
## compare their [code]keycode[/code], [code]physical_keycode[/code] and
## [code]key_label[/code] exactly, plus the four modifiers: a built-in action's keys are
## built from the logical [code]keycode[/code] with the other two left at 0, so comparing
## [code]physical_keycode[/code] or [code]key_label[/code] alone would make every such key
## equal to every other.
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
		return key_a.keycode == key_b.keycode \
			and key_a.physical_keycode == key_b.physical_keycode \
			and key_a.key_label == key_b.key_label \
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


## Returns the index in [param events] of the first event equivalent to [param event], or
## -1 when there is none.
static func _find_equivalent_event(events: Array, event: InputEvent) -> int:
	for index in events.size():
		var existing: Variant = events[index]
		if existing is InputEvent and _input_events_equivalent(existing, event):
			return index
	return -1


## Saves project.godot after the input_map.* change [param operation] to [param action]. A
## failed save leaves the change in memory, so it warns instead of failing the call.
func _save_settings(operation: String, action: String) -> void:
	var error := _settings.save()
	if error != OK:
		push_warning(
			"[MCPServer] ProjectSettings.save after input_map.%s failed (err %d, action=%s); the change is in memory only" % [
				operation, error, action])


# -- Rename -------------------------------------------------------------------


## Returns the error that refuses renaming [param action_name] to [param new_name], or an
## empty Dictionary when the rename may go ahead. The settings hold every built-in action,
## changed or not, so they answer both the built-in and the name-taken refusals.
func _check_rename(action_name: String, new_name: String) -> Dictionary:
	if new_name.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "new_name must be a non-empty string")
	if new_name == action_name:
		return MCPToolkitError.fail("INVALID_PARAMS", "new_name equals name ('%s')" % action_name)
	if _settings.is_builtin(action_name):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"refusing to rename built-in UI action '%s'" % action_name)
	if not _settings.exists(action_name):
		return MCPToolkitError.fail("NOT_FOUND", "no action '%s' in project settings" % action_name)
	if _settings.exists(new_name):
		return MCPToolkitError.fail("ALREADY_EXISTS", "action '%s' already exists" % new_name)
	return {}


# -- Commands -----------------------------------------------------------------


func _cmd_input_map_event(parameters: Dictionary) -> Dictionary:
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
	if not _settings.exists(action_name):
		return MCPToolkitError.fail("NOT_FOUND",
			"no action '%s'; call input_map.action with action='add' first" % action_name)
	var events := _settings.get_events(action_name)
	var matched_index := _find_equivalent_event(events, event)
	if action == "bind":
		if matched_index != -1:
			return MCPToolkitSuccess.ok({
				"status": "returned",
				"name": action_name,
				"event": _serialise_input_event(events[matched_index]),
			})
		events.append(event)
		_settings.write(action_name, _settings.get_deadzone(action_name), events)
		_save_settings("event bind", action_name)
		return MCPToolkitSuccess.ok({
			"status": "created",
			"name": action_name,
			"event": _serialise_input_event(event),
		})
	if matched_index == -1:
		return MCPToolkitError.fail("NOT_FOUND",
			"no matching event on action '%s' (found %d events)" % [
				action_name, events.size()])
	var matched: InputEvent = events[matched_index]
	events.remove_at(matched_index)
	_settings.write(action_name, _settings.get_deadzone(action_name), events)
	_save_settings("event unbind", action_name)
	return MCPToolkitSuccess.ok({
		"name": action_name,
		"event": _serialise_input_event(matched),
	})


func _cmd_input_map_action(parameters: Dictionary) -> Dictionary:
	var action := str(parameters.get("action", ""))
	if not (action in ["add", "remove", "rename"]):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"action must be 'add', 'remove' or 'rename' (got '%s')" % action)
	var action_name := str(parameters.get("name", ""))
	if action_name.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "name must be a non-empty string")
	if action == "rename":
		return _rename_input_action(action_name, str(parameters.get("new_name", "")))
	if action == "add":
		return _add_input_action(action_name, parameters.get("deadzone", null))
	if not _settings.exists(action_name):
		return MCPToolkitError.fail("NOT_FOUND", "no action '%s'" % action_name)
	if _settings.is_builtin(action_name):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"refusing to remove built-in UI action '%s'; use input_map.event to unbind its events instead" % action_name)
	_settings.erase(action_name)
	_save_settings("action remove", action_name)
	return MCPToolkitSuccess.ok({"name": action_name})


## Adds the project action [param action_name] with no events and saves project.godot. A
## [param deadzone] that is not a number gives the engine's own default, as the editor's
## Add action does: 0.5 before 4.4 and 0.2 from 4.4. An action that already exists, project
## action or built-in, is left as it is and answers [code]status: "returned"[/code] with its
## own deadzone.
func _add_input_action(action_name: String, deadzone: Variant) -> Dictionary:
	var is_number := typeof(deadzone) == TYPE_FLOAT or typeof(deadzone) == TYPE_INT
	var new_deadzone := float(deadzone) if is_number else _settings.default_deadzone()
	if new_deadzone < 0.0 or new_deadzone > 1.0:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"deadzone must be in [0.0, 1.0] (got %f)" % new_deadzone)
	if _settings.exists(action_name):
		return MCPToolkitSuccess.ok({
			"status": "returned",
			"name": action_name,
			"deadzone": _settings.get_deadzone(action_name),
		})
	_settings.write(action_name, new_deadzone, [])
	_save_settings("action add", action_name)
	return MCPToolkitSuccess.ok({
		"status": "created",
		"name": action_name,
		"deadzone": new_deadzone,
	})


## Renames the project action [param action_name] to [param new_name] and saves
## project.godot.
##
## A missing or empty [param new_name] is refused, and so is a [param new_name] equal to
## [param action_name]. A built-in action is refused as [code]remove[/code] refuses one.
## A [param action_name] with no setting answers [code]NOT_FOUND[/code], and a
## [param new_name] that already has a setting, project action or built-in, answers
## [code]ALREADY_EXISTS[/code]. The action keeps its events, its deadzone and its place
## in [code][input][/code]. Scripts and scenes that use the old name are not changed, as
## after the editor's own rename. Returns the new name with [code]old_name[/code].
func _rename_input_action(action_name: String, new_name: String) -> Dictionary:
	var refusal := _check_rename(action_name, new_name)
	if not refusal.is_empty():
		return refusal
	_settings.move(action_name, new_name)
	_save_settings("action rename", new_name)
	return MCPToolkitSuccess.ok({"name": new_name, "old_name": action_name})
