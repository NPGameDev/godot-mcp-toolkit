@tool
extends RefCounted
## Translates between an input event and the event object the input_map.* commands take
## and answer.
##
## One object shape serves both directions, so an event read from input_map.list can be
## passed back to a bind or an unbind. Every object carries [code]type[/code]; an answer
## also carries [code]class[/code], the engine class. A key answers the one code field
## the engine matches it on as [code]keycode[/code], with [code]key_kind[/code] naming that
## field, and a key built from an object sets only that field.

## The key fields a key event can be matched on, the value [code]key_kind[/code] takes.
const KEY_KINDS: Array[String] = ["physical_keycode", "keycode", "key_label"]

const _EVENT_TYPES := "'key' | 'mouse_button' | 'joypad_button' | 'joypad_motion'"
const _PRESSED_WARNING := "pressed has no effect on action matching; ignored"
const _LOCATION_WARNING := "location needs Godot 4.3+; ignored"


## Builds the input event that the event object [param fields] describes.
##
## Returns [code]{"event": InputEvent, "warnings": Array, "any_device": bool}[/code], or
## [code]{"code": "INVALID_PARAMS", "error": String}[/code] when [param fields] is not a
## valid event object. [code]any_device[/code] is true when the object names no device, so
## a match may take any device. [code]warnings[/code] lists each field that was accepted
## but not applied: a mouse [code]pressed[/code], which the engine ignores when it matches
## an action, and a key [code]location[/code] on an engine without one (before 4.3).
##
## A key or mouse event with no [code]device[/code] keeps the engine's own default; a
## joypad event with none gets -1, the engine's "any device".
static func build(fields: Variant) -> Dictionary:
	if typeof(fields) != TYPE_DICTIONARY:
		return _invalid("event must be an object")
	var event_fields: Dictionary = fields
	var device: Variant = event_fields.get("device", null)
	var has_device := typeof(device) != TYPE_NIL
	if has_device and not _is_number(device):
		return _invalid("event.device must be an integer (got %s)" % str(device))
	var warnings: Array = []
	var built: Variant
	var event_type := str(event_fields.get("type", ""))
	match event_type:
		"key":
			built = _build_key(event_fields, warnings)
		"mouse_button":
			built = _build_mouse_button(event_fields, warnings)
		"joypad_button":
			var joypad_button := InputEventJoypadButton.new()
			joypad_button.button_index = int(event_fields.get("button_index", 0))
			joypad_button.device = -1
			built = joypad_button
		"joypad_motion":
			var joypad_motion := InputEventJoypadMotion.new()
			joypad_motion.axis = int(event_fields.get("axis", 0))
			joypad_motion.axis_value = float(event_fields.get("axis_value", 0.0))
			joypad_motion.device = -1
			built = joypad_motion
		_:
			return _invalid("event.type must be one of %s (got %s)" % [_EVENT_TYPES, event_type])
	if typeof(built) == TYPE_DICTIONARY:
		return built
	var event: InputEvent = built
	if has_device:
		event.device = int(device)
	return {"event": event, "warnings": warnings, "any_device": not has_device}


## Returns the event object for [param event]. An event of a type the commands do not
## model answers [code]{"type": "unknown", "class": <engine class>}[/code].
##
## A key answers [code]location[/code] only on an engine that has it (4.3+). A mouse
## button never answers [code]pressed[/code]: an action match ignores it.
static func serialise(event: InputEvent) -> Dictionary:
	if event is InputEventKey:
		return _serialise_key(event as InputEventKey)
	if event is InputEventMouseButton:
		var mouse_button := event as InputEventMouseButton
		var mouse_fields := {
			"type": "mouse_button",
			"class": mouse_button.get_class(),
			"button_index": int(mouse_button.button_index),
			"double_click": mouse_button.double_click,
			"device": mouse_button.device,
		}
		mouse_fields.merge(_serialise_modifiers(mouse_button))
		return mouse_fields
	if event is InputEventJoypadButton:
		var joypad_button := event as InputEventJoypadButton
		return {
			"type": "joypad_button",
			"class": joypad_button.get_class(),
			"button_index": int(joypad_button.button_index),
			"device": joypad_button.device,
		}
	if event is InputEventJoypadMotion:
		var joypad_motion := event as InputEventJoypadMotion
		return {
			"type": "joypad_motion",
			"class": joypad_motion.get_class(),
			"axis": int(joypad_motion.axis),
			"axis_value": joypad_motion.axis_value,
			"device": joypad_motion.device,
		}
	return {"type": "unknown", "class": event.get_class()}


## Returns the event object of each input event in [param events], in order. A value that
## is not an input event is left out.
static func serialise_all(events: Array) -> Array:
	var serialised: Array = []
	for event in events:
		if event is InputEvent:
			serialised.append(serialise(event))
	return serialised


## Returns the field that [param key] is matched on, as the engine picks it: its
## [code]keycode[/code] when set, else its [code]physical_keycode[/code], else its
## [code]key_label[/code]. A key with none of the three answers
## [code]"physical_keycode"[/code].
static func key_kind(key: InputEventKey) -> String:
	if key.keycode != KEY_NONE:
		return "keycode"
	if key.physical_keycode != KEY_NONE:
		return "physical_keycode"
	if key.key_label != KEY_NONE:
		return "key_label"
	return "physical_keycode"


## Returns the value of the field [method key_kind] picks for [param key].
static func key_code(key: InputEventKey) -> int:
	match key_kind(key):
		"keycode":
			return int(key.keycode)
		"key_label":
			return int(key.key_label)
	return int(key.physical_keycode)


## Returns the key event [param fields] describes, or the error for an invalid code, kind
## or location. A [code]location[/code] the engine lacks is appended to [param warnings].
static func _build_key(fields: Dictionary, warnings: Array) -> Variant:
	var code: Variant = _resolve_keycode(fields.get("keycode", ""))
	if typeof(code) == TYPE_DICTIONARY:
		return code
	var kind := str(fields.get("key_kind", "physical_keycode"))
	if not KEY_KINDS.has(kind):
		return _invalid("event.key_kind must be one of 'physical_keycode' | 'keycode' | 'key_label' (got '%s')" % kind)
	var key := InputEventKey.new()
	match kind:
		"keycode":
			key.keycode = int(code)
		"key_label":
			key.key_label = int(code)
		_:
			key.physical_keycode = int(code)
	_apply_modifiers(key, fields)
	if not fields.has("location"):
		return key
	# InputEventKey.location exists from 4.3; a typed access would not parse on 4.2.
	if not ("location" in key):
		warnings.append(_LOCATION_WARNING)
		return key
	var location: Variant = fields["location"]
	if not _is_number(location) or int(location) < 0 or int(location) > 2:
		return _invalid("event.location must be 0 (unspecified), 1 (left) or 2 (right) (got %s)" % str(location))
	key.set("location", int(location))
	return key


## Returns the mouse button event [param fields] describes. A [code]pressed[/code] field is
## noted in [param warnings] and not stored.
static func _build_mouse_button(fields: Dictionary, warnings: Array) -> InputEventMouseButton:
	var mouse_button := InputEventMouseButton.new()
	mouse_button.button_index = int(fields.get("button_index", 1))
	mouse_button.double_click = bool(fields.get("double_click", false))
	_apply_modifiers(mouse_button, fields)
	if fields.has("pressed"):
		warnings.append(_PRESSED_WARNING)
	return mouse_button


## Sets [param event]'s modifiers from [param fields]. [code]command_or_control[/code] goes
## first and, when true, sets ctrl or meta itself for the running platform: the engine
## refuses a direct ctrl or meta while it is on, so [code]ctrl[/code] and
## [code]meta[/code] are then ignored.
static func _apply_modifiers(event: InputEventWithModifiers, fields: Dictionary) -> void:
	event.shift_pressed = bool(fields.get("shift", false))
	event.alt_pressed = bool(fields.get("alt", false))
	if bool(fields.get("command_or_control", false)):
		event.command_or_control_autoremap = true
		return
	event.ctrl_pressed = bool(fields.get("ctrl", false))
	event.meta_pressed = bool(fields.get("meta", false))


## Returns the key code [param raw] names: a symbolic name such as [code]"SPACE"[/code] or
## [code]"KEY_F1"[/code], or a raw integer. Returns the error Dictionary for an unknown name
## or a value of another type.
static func _resolve_keycode(raw: Variant) -> Variant:
	if _is_number(raw):
		return int(raw)
	if typeof(raw) != TYPE_STRING:
		return _invalid("event.keycode must be a string symbolic name or int")
	var name: String = raw
	var code := OS.find_keycode_from_string(name.trim_prefix("KEY_"))
	if code == KEY_NONE:
		return _invalid("unknown keycode '%s'; use symbolic names like 'SPACE' / 'A' / 'F1' or raw ints" % name)
	return int(code)


## Returns the modifier fields of [param event].
static func _serialise_modifiers(event: InputEventWithModifiers) -> Dictionary:
	return {
		"shift": event.shift_pressed,
		"ctrl": event.ctrl_pressed,
		"alt": event.alt_pressed,
		"meta": event.meta_pressed,
		"command_or_control": event.command_or_control_autoremap,
	}


## Returns the event object for [param key].
static func _serialise_key(key: InputEventKey) -> Dictionary:
	var code := key_code(key)
	var key_fields := {
		"type": "key",
		"class": key.get_class(),
		"keycode": code,
		"keycode_name": OS.get_keycode_string(code),
		"key_kind": key_kind(key),
		"device": key.device,
	}
	if "location" in key:
		key_fields["location"] = int(key.get("location"))
	key_fields.merge(_serialise_modifiers(key))
	return key_fields


## Returns whether [param value] is a JSON number: an int, or a float as JSON delivers one.
static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT


static func _invalid(message: String) -> Dictionary:
	return {"code": "INVALID_PARAMS", "error": message}
