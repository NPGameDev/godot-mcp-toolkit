@tool
extends RefCounted
## Decides when two input events are the same binding: the rule a bind uses to find a
## duplicate and an unbind to find its event.
##
## The rule follows the engine's own exact match, [method InputEvent.is_match], and is
## stricter in three places so that an unbind removes exactly the event named: a key
## compares the field it is matched on ([code]key_kind[/code]) as well as its code,
## [code]command_or_control[/code] is told apart from a plain ctrl or meta, and a key's
## [code]location[/code] always counts. The engine's match (4.3+, where keys have a location)
## reads a saved event's unspecified location as any location, and ignores location on a
## logical key.

const InputEventCodec := preload("res://addons/godot_mcp_toolkit/commands/input_map/input_event_codec.gd")


## Returns whether [param event_a] and [param event_b] are the same binding.
##
## A key compares its kind, code, location and modifiers; a mouse button its index and
## modifiers, never [code]pressed[/code] or [code]double_click[/code]; a joypad button its
## index; a joypad motion its axis and the sign of its value. Every type compares its
## device too, unless [param any_device] is true, either device is -1, the engine's "any
## device", or, on 4.7+, a key or mouse event's device 0 reads as the keyboard or mouse
## device, as the engine reads a saved device 0 when it loads a project.
static func are_equivalent(
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
## -1 when there is none. [param any_device] is passed to [method are_equivalent].
static func find_equivalent(events: Array, event: InputEvent, any_device: bool = false) -> int:
	for index in events.size():
		var existing: Variant = events[index]
		if existing is InputEvent and are_equivalent(existing, event, any_device):
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
