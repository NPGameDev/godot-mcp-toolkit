@tool
extends RefCounted
## input_map.* command handlers: list (read), action (add/remove/rename/revert) and event
## (bind/unbind), with the rule that decides when two events are the same binding.
##
## Every handler reads and writes the [code]input/<name>[/code] settings only, through
## [code]input_action_settings.gd[/code], and never the editor's InputMap: that InputMap holds
## only the built-in actions' keys, so a change written from it would replace a built-in
## action's saved events and drop its joypad defaults. Events cross the wire as the objects
## [code]input_event_codec.gd[/code] builds and answers.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const InputActionSettings := preload("res://addons/godot_mcp_toolkit/commands/input_action_settings.gd")
const InputEventCodec := preload("res://addons/godot_mcp_toolkit/commands/input_event_codec.gd")

var _settings: InputActionSettings


func _init() -> void:
	_settings = _create_settings()


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	var commands := new()
	registry.add("input_map.list", func(parameters: Dictionary) -> Dictionary:
		return commands._cmd_input_map_list(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
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


# -- Binding equivalence -------------------------------------------------------


## Returns whether [param event_a] and [param event_b] are the same binding, the rule a
## bind uses to find a duplicate and an unbind to find its event. It follows the engine's
## own exact match, [method InputEvent.is_match], and is stricter in two places so that an
## unbind removes exactly the event named: a key compares the field it is matched on
## ([code]key_kind[/code]) as well as its code, and [code]command_or_control[/code] is told
## apart from a plain ctrl or meta.
##
## A key compares its kind, code, location and modifiers; a mouse button its index and
## modifiers, never [code]pressed[/code] or [code]double_click[/code]; a joypad button its
## index; a joypad motion its axis and the sign of its value. Every type compares its
## device too, unless [param any_device] is true, either device is -1, the engine's "any
## device", or, on 4.7+, a key or mouse event's device 0 reads as the keyboard or mouse
## device, as the engine reads a saved device 0 when it loads a project.
static func _input_events_equivalent(
	event_a: InputEvent, event_b: InputEvent, any_device: bool = false,
) -> bool:
	if event_a == null or event_b == null:
		return false
	if event_a.get_class() != event_b.get_class():
		return false
	if not any_device and not _devices_match(event_a, event_b):
		return false
	if event_a is InputEventKey and event_b is InputEventKey:
		var key_a := event_a as InputEventKey
		var key_b := event_b as InputEventKey
		return InputEventCodec.key_kind(key_a) == InputEventCodec.key_kind(key_b) \
			and InputEventCodec.key_code(key_a) == InputEventCodec.key_code(key_b) \
			and key_a.get("location") == key_b.get("location") \
			and _modifiers_match(key_a, key_b)
	if event_a is InputEventMouseButton and event_b is InputEventMouseButton:
		var mouse_a := event_a as InputEventMouseButton
		var mouse_b := event_b as InputEventMouseButton
		return mouse_a.button_index == mouse_b.button_index and _modifiers_match(mouse_a, mouse_b)
	if event_a is InputEventJoypadButton and event_b is InputEventJoypadButton:
		return (event_a as InputEventJoypadButton).button_index \
			== (event_b as InputEventJoypadButton).button_index
	if event_a is InputEventJoypadMotion and event_b is InputEventJoypadMotion:
		var motion_a := event_a as InputEventJoypadMotion
		var motion_b := event_b as InputEventJoypadMotion
		return motion_a.axis == motion_b.axis \
			and (motion_a.axis_value < 0.0) == (motion_b.axis_value < 0.0)
	return false


## Returns the index in [param events] of the first event equivalent to [param event], or
## -1 when there is none. [param any_device] is passed to [method _input_events_equivalent].
static func _find_equivalent_event(events: Array, event: InputEvent, any_device: bool = false) -> int:
	for index in events.size():
		var existing: Variant = events[index]
		if existing is InputEvent and _input_events_equivalent(existing, event, any_device):
			return index
	return -1


static func _modifiers_match(event_a: InputEventWithModifiers, event_b: InputEventWithModifiers) -> bool:
	return event_a.shift_pressed == event_b.shift_pressed \
		and event_a.ctrl_pressed == event_b.ctrl_pressed \
		and event_a.alt_pressed == event_b.alt_pressed \
		and event_a.meta_pressed == event_b.meta_pressed \
		and event_a.command_or_control_autoremap == event_b.command_or_control_autoremap


static func _devices_match(event_a: InputEvent, event_b: InputEvent) -> bool:
	var device_a := _matched_device(event_a)
	var device_b := _matched_device(event_b)
	return device_a == -1 or device_b == -1 or device_a == device_b


## Returns the device [param event] is matched on. From 4.7 keys and mice have their own
## device ids (the engine's [code]InputEvent.DEVICE_ID_KEYBOARD[/code] and
## [code]DEVICE_ID_MOUSE[/code]), and the engine reads a key or mouse event saved with
## device 0 as one of them; earlier engines have no such ids, and 0 stays 0.
static func _matched_device(event: InputEvent) -> int:
	if event.device != 0 or not ClassDB.class_has_integer_constant("InputEvent", "DEVICE_ID_KEYBOARD"):
		return event.device
	if event is InputEventKey:
		return ClassDB.class_get_integer_constant("InputEvent", "DEVICE_ID_KEYBOARD")
	if event is InputEventMouse:
		return ClassDB.class_get_integer_constant("InputEvent", "DEVICE_ID_MOUSE")
	return event.device


# -- Shared helpers -----------------------------------------------------------


## Returns [param action]'s input_map.list entry: its name, [code]source[/code],
## deadzone, events and [code]can_revert[/code]; with [code]default[/code] when it can be
## reverted, and [code]feature[/code] when its name carries feature tags.
func _action_entry(action: String) -> Dictionary:
	var builtin := _settings.is_builtin(action)
	var can_revert := builtin and _settings.differs_from_default(action)
	var entry := {
		"name": action,
		"source": "builtin" if builtin else "project",
		"deadzone": _settings.get_deadzone(action),
		"events": InputEventCodec.serialise_all(_settings.get_events(action)),
		"can_revert": can_revert,
	}
	if can_revert:
		var default_setting := _settings.get_default(action)
		entry["default"] = {
			"deadzone": default_setting["deadzone"],
			"events": InputEventCodec.serialise_all(default_setting["events"]),
		}
	var feature := _settings.get_feature(action)
	if not feature.is_empty():
		entry["feature"] = feature
	return entry


## Returns the error that refuses a change to [param action] when it is a built-in
## action's feature-override entry, or an empty Dictionary otherwise. A project action
## whose name carries feature tags may still be changed.
func _check_not_builtin_feature(action: String) -> Dictionary:
	if _settings.is_builtin(action) and not _settings.get_feature(action).is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS",
			"'%s' is a built-in action's feature-override entry; feature-override entries are read-only" % action)
	return {}


## Saves project.godot after the input_map.* change [param operation] to [param action]. A
## failed save leaves the change in memory, so it warns instead of failing the call.
func _save_settings(operation: String, action: String) -> void:
	var error := _settings.save()
	if error != OK:
		push_warning(
			"[MCPServer] ProjectSettings.save after input_map.%s failed (err %d, action=%s); the change is in memory only" % [
				operation, error, action])


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


## Lists actions with their events. With no [code]name[/code], it answers every project
## action and every built-in action that differs from its default, plus the unchanged
## built-in actions when [code]include_builtin[/code] is true. A [code]name[/code] answers
## that one action, built-in or not, or [code]NOT_FOUND[/code]. Returns
## [code]{actions, count}[/code], the actions in project.godot's [code][input][/code] order.
func _cmd_input_map_list(parameters: Dictionary) -> Dictionary:
	var action_name := str(parameters.get("name", ""))
	if not action_name.is_empty():
		if not _settings.exists(action_name):
			return MCPToolkitError.fail("NOT_FOUND",
				"no action '%s'; call input_map_list without name to see the actions" % action_name)
		return MCPToolkitSuccess.ok({"actions": [_action_entry(action_name)], "count": 1})
	var include_builtin := bool(parameters.get("include_builtin", false))
	var actions: Array = []
	for action in _settings.get_actions():
		if include_builtin or not _settings.is_builtin(action) or _settings.differs_from_default(action):
			actions.append(_action_entry(action))
	return MCPToolkitSuccess.ok({"actions": actions, "count": actions.size()})


func _cmd_input_map_event(parameters: Dictionary) -> Dictionary:
	var action := str(parameters.get("action", ""))
	if not (action in ["bind", "unbind"]):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"action must be 'bind' or 'unbind' (got '%s')" % action)
	var action_name := str(parameters.get("name", ""))
	if action_name.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "name must be a non-empty string")
	var built := InputEventCodec.build(parameters.get("event", null))
	if built.has("error"):
		return MCPToolkitError.fail(str(built["code"]), str(built["error"]))
	var event: InputEvent = built["event"]
	var any_device: bool = built["any_device"]
	var warnings: Array = built["warnings"]
	if not _settings.exists(action_name):
		return MCPToolkitError.fail("NOT_FOUND",
			"no action '%s'; call input_map.action with action='add' first" % action_name)
	var refusal := _check_not_builtin_feature(action_name)
	if not refusal.is_empty():
		return refusal
	var events := _settings.get_events(action_name)
	var matched_index := _find_equivalent_event(events, event, any_device)
	var response: Dictionary
	if action == "bind":
		response = _bind_event(action_name, events, event, matched_index)
	elif matched_index == -1:
		return MCPToolkitError.fail("NOT_FOUND",
			"no matching event on action '%s' (found %d events)" % [
				action_name, events.size()])
	else:
		response = _unbind_event(action_name, events, matched_index)
	if not warnings.is_empty():
		response["warnings"] = warnings
	return response


## Appends [param event] to [param action_name]'s [param events] and saves, or answers
## [code]status: "returned"[/code] with the saved event at [param matched_index] when it is
## not -1.
func _bind_event(action_name: String, events: Array, event: InputEvent, matched_index: int) -> Dictionary:
	if matched_index != -1:
		return MCPToolkitSuccess.ok({
			"status": "returned",
			"name": action_name,
			"event": InputEventCodec.serialise(events[matched_index]),
		})
	events.append(event)
	_settings.write(action_name, _settings.get_deadzone(action_name), events)
	_save_settings("event bind", action_name)
	return MCPToolkitSuccess.ok({
		"status": "created",
		"name": action_name,
		"event": InputEventCodec.serialise(event),
	})


## Removes the event at [param matched_index] from [param action_name]'s [param events] and
## saves. Returns the removed event.
func _unbind_event(action_name: String, events: Array, matched_index: int) -> Dictionary:
	var matched: InputEvent = events[matched_index]
	events.remove_at(matched_index)
	_settings.write(action_name, _settings.get_deadzone(action_name), events)
	_save_settings("event unbind", action_name)
	return MCPToolkitSuccess.ok({
		"name": action_name,
		"event": InputEventCodec.serialise(matched),
	})


func _cmd_input_map_action(parameters: Dictionary) -> Dictionary:
	var action := str(parameters.get("action", ""))
	if not (action in ["add", "remove", "rename", "revert"]):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"action must be 'add', 'remove', 'rename' or 'revert' (got '%s')" % action)
	var action_name := str(parameters.get("name", ""))
	if action_name.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "name must be a non-empty string")
	match action:
		"rename":
			return _rename_input_action(action_name, str(parameters.get("new_name", "")))
		"add":
			return _add_input_action(action_name, parameters.get("deadzone", null))
		"revert":
			return _revert_input_action(action_name)
	if not _settings.exists(action_name):
		return MCPToolkitError.fail("NOT_FOUND", "no action '%s'" % action_name)
	if _settings.is_builtin(action_name):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"refusing to remove built-in UI action '%s'; use action='revert' to restore its default events" % action_name)
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


## Puts the built-in action [param action_name] back to its default and saves
## project.godot, which then leaves the action's line out.
##
## An action with no setting answers [code]NOT_FOUND[/code]; a project action, which has no
## default, and a built-in action's feature-override entry answer
## [code]INVALID_PARAMS[/code]. A setting that already holds its default value answers
## [code]status: "returned"[/code]; any other, even one whose content equals the default,
## is reverted and answers [code]status: "reverted"[/code], since project.godot keeps a
## line whose events are not the default's own. Returns the action's input_map.list entry
## with [code]status[/code].
func _revert_input_action(action_name: String) -> Dictionary:
	if not _settings.exists(action_name):
		return MCPToolkitError.fail("NOT_FOUND", "no action '%s'" % action_name)
	if not _settings.is_builtin(action_name):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"'%s' is a project action and has no default to revert to; use action='remove' to delete it" % action_name)
	var refusal := _check_not_builtin_feature(action_name)
	if not refusal.is_empty():
		return refusal
	var status := "returned"
	if not _settings.holds_default(action_name):
		_settings.revert(action_name)
		_save_settings("action revert", action_name)
		status = "reverted"
	var entry := _action_entry(action_name)
	entry["status"] = status
	return MCPToolkitSuccess.ok(entry)
