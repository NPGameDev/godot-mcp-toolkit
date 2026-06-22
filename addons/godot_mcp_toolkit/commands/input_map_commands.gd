@tool
extends RefCounted
## input_map.* command handlers — action (add/remove) and event (bind/unbind).

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")

const BUILTIN_UI_ACTIONS: Array[String] = [
	"ui_accept", "ui_cancel", "ui_focus_next", "ui_focus_prev",
	"ui_up", "ui_down", "ui_left", "ui_right",
	"ui_page_up", "ui_page_down", "ui_home", "ui_end",
	"ui_cut", "ui_copy", "ui_paste", "ui_undo", "ui_redo",
	"ui_text_completion_query", "ui_text_completion_accept",
	"ui_text_completion_replace",
	"ui_text_newline", "ui_text_newline_blank", "ui_text_newline_above",
	"ui_text_backspace", "ui_text_backspace_word",
	"ui_text_backspace_all_to_left",
	"ui_text_delete", "ui_text_delete_word",
	"ui_text_delete_all_to_right",
	"ui_text_caret_left", "ui_text_caret_word_left",
	"ui_text_caret_right", "ui_text_caret_word_right",
	"ui_text_caret_up", "ui_text_caret_down",
	"ui_text_caret_line_start", "ui_text_caret_line_end",
	"ui_text_caret_page_up", "ui_text_caret_page_down",
	"ui_text_caret_document_start", "ui_text_caret_document_end",
	"ui_text_caret_add_below", "ui_text_caret_add_above",
	"ui_text_scroll_up", "ui_text_scroll_down",
	"ui_text_select_all", "ui_text_select_word_under_caret",
	"ui_text_add_selection_for_next_occurrence",
	"ui_text_clear_carets_and_selection",
	"ui_text_toggle_insert_mode", "ui_menu", "ui_text_submit",
	"ui_graph_duplicate", "ui_graph_delete",
	"ui_filedialog_up_one_level", "ui_filedialog_refresh",
	"ui_filedialog_show_hidden",
	"ui_swap_input_direction",
]


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
		if not InputMap.has_action(action_name):
			return MCPToolkitError.fail("NOT_FOUND", "no action '%s'" % action_name)
		if action_name in BUILTIN_UI_ACTIONS:
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
	if not InputMap.has_action(action_name):
		return MCPToolkitError.fail("NOT_FOUND",
			"no action '%s'; call input_map.action with action='add' first" % action_name)
	var built: Variant = _build_input_event(parameters.get("event", null))
	if typeof(built) == TYPE_DICTIONARY and built.has("error"):
		return MCPToolkitError.fail(str(built["code"]), str(built["error"]))
	var event: InputEvent = built
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
