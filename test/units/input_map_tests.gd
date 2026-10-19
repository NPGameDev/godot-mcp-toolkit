@tool
extends RefCounted
## Input-map unit tests: the input_map.* handlers read and write the input/<name>
## settings only. Each case runs the real handlers on [UnsavedInputMapCommands], whose
## settings save does not write project.godot, so settings change in memory only. Each
## case seeds the settings it needs and restores every one it touched, the built-in
## actions' included.
##
## The editor's InputMap holds only a built-in action's keys (InputMap::load_default()),
## while this runner is not the editor and loads the full defaults into it. The cases
## that bind a built-in action with nothing saved narrow its InputMap events to the keys
## first, as the editor holds them, and put them back after.

const InputMapCommands := preload("res://addons/godot_mcp_toolkit/commands/input_map_commands.gd")
const InputActionSettings := preload("res://addons/godot_mcp_toolkit/commands/input_action_settings.gd")

const _ACTION := "mcp_test_project_action"
## A project action whose name looks like a built-in one.
const _UI_PREFIXED_ACTION := "ui_inventory"
const _BUILTIN_ACTION := "ui_accept"
## A built-in action whose default holds joypad events; ui_accept's holds keys only.
const _JOYPAD_BUILTIN_ACTION := "ui_left"
## The name a rename case moves [constant _ACTION] to.
const _RENAMED_ACTION := "mcp_test_renamed_action"
## A second project action, saved after [constant _ACTION].
const _OTHER_ACTION := "mcp_test_other_action"


static func run(testing) -> void:
	_test_seeded_setting_is_seen(testing)
	_test_setting_edit_between_calls_is_seen(testing)
	_test_deleted_setting_answers_not_found(testing)
	_test_unbind_project_action(testing)
	_test_bind_builtin_keeps_saved_events(testing)
	_test_bind_builtin_keeps_joypad_defaults(testing)
	_test_bind_builtin_keeps_each_default_event(testing)
	_test_key_equivalence(testing)
	_test_add_uses_default_deadzone(testing)
	_test_builtin_refusals_leave_setting(testing)
	_test_bind_keeps_builtin_order(testing)
	_test_builtin_rule_matches_engine(testing)
	_test_ui_prefixed_project_action(testing)
	_test_rename_moves_setting(testing)
	_test_rename_keeps_order(testing)
	_test_rename_refusals(testing)


# --- The settings are the source of truth -------------------------------------

static func _test_seeded_setting_is_seen(testing) -> void:
	testing.begin("input_map settings: the handlers see a project action's setting")
	_seed_action(_ACTION, 0.3, [_key_event(KEY_F7)])
	var add_again := _action_call("add", _ACTION)
	var bind_saved := _bind(_ACTION, "F7")
	var bind_new := _bind(_ACTION, "F8")
	var setting: Variant = ProjectSettings.get_setting("input/" + _ACTION)
	_clear_actions([_ACTION])

	testing.eq(str(add_again.get("status", "")), "returned", "add on the saved action → returned")
	testing.ok(absf(float(add_again.get("deadzone", -1.0)) - 0.3) < 0.001,
		"with its saved deadzone 0.3 (%s)" % str(add_again))
	testing.eq(str(bind_saved.get("status", "")), "returned", "bind F7, already saved → returned")
	testing.eq(str(bind_new.get("status", "")), "created", "bind F8 → created")
	testing.eq(_setting_keycodes(setting), [KEY_F7, KEY_F8], "the setting holds F7 then F8")
	testing.ok(absf(_setting_deadzone(setting) - 0.3) < 0.001,
		"and keeps the deadzone 0.3 (got %f)" % _setting_deadzone(setting))
	print("")


# Project Settings edits an action through its setting alone. The next call works
# on the edited setting, never on a copy kept from an earlier call.
static func _test_setting_edit_between_calls_is_seen(testing) -> void:
	testing.begin("input_map settings: a Project Settings edit between two calls is seen")
	_seed_action(_ACTION, 0.3, [_key_event(KEY_F7)])
	_bind(_ACTION, "F8")
	ProjectSettings.set_setting("input/" + _ACTION, {
		"deadzone": 0.7,
		"events": [_key_event(KEY_F9)],
	})
	var bind_after_edit := _bind(_ACTION, "F10")
	var setting: Variant = ProjectSettings.get_setting("input/" + _ACTION)
	_clear_actions([_ACTION])

	testing.eq(str(bind_after_edit.get("status", "")), "created", "bind F10 after the edit → created")
	testing.eq(_setting_keycodes(setting), [KEY_F9, KEY_F10], "the setting holds the edited event, then F10")
	testing.ok(absf(_setting_deadzone(setting) - 0.7) < 0.001,
		"and the edited deadzone 0.7 (got %f)" % _setting_deadzone(setting))
	print("")


# Project Settings deletes an action with ProjectSettings.clear() alone.
static func _test_deleted_setting_answers_not_found(testing) -> void:
	testing.begin("input_map settings: an action whose setting is gone answers NOT_FOUND")
	_seed_action(_ACTION, 0.3, [_key_event(KEY_F7)])
	_bind(_ACTION, "F8")
	ProjectSettings.clear("input/" + _ACTION)
	var bind_after := _bind(_ACTION, "F9")
	var unbind_after := _unbind(_ACTION, "F7")
	var remove_after := _action_call("remove", _ACTION)
	var recreated := ProjectSettings.has_setting("input/" + _ACTION)
	_clear_actions([_ACTION])

	testing.eq(str(bind_after.get("code", "")), "NOT_FOUND", "bind → NOT_FOUND")
	testing.eq(str(unbind_after.get("code", "")), "NOT_FOUND", "unbind → NOT_FOUND")
	testing.eq(str(remove_after.get("code", "")), "NOT_FOUND", "remove → NOT_FOUND")
	testing.ok(not recreated, "and no call brings the setting back")
	print("")


static func _test_unbind_project_action(testing) -> void:
	testing.begin("input_map settings: unbind removes the one matching saved event")
	_seed_action(_ACTION, 0.3, [_key_event(KEY_F7), _key_event(KEY_F8)])
	var unbind_saved := _unbind(_ACTION, "F7")
	var unbind_missing := _unbind(_ACTION, "F9")
	var setting: Variant = ProjectSettings.get_setting("input/" + _ACTION)
	_clear_actions([_ACTION])

	testing.ok(bool(unbind_saved.get("success", false)), "unbind F7 answers success (%s)" % str(unbind_saved))
	testing.eq(_setting_keycodes(setting), [KEY_F8], "the setting holds F8 alone")
	testing.ok(absf(_setting_deadzone(setting) - 0.3) < 0.001,
		"and keeps the deadzone 0.3 (got %f)" % _setting_deadzone(setting))
	testing.eq(str(unbind_missing.get("code", "")), "NOT_FOUND", "unbind F9, never saved → NOT_FOUND")
	testing.ok(str(unbind_missing.get("error", "")).contains("found 1 events"),
		"counting the saved events (%s)" % str(unbind_missing.get("error", "")))
	print("")


# --- Built-in actions --------------------------------------------------------

static func _test_bind_builtin_keeps_saved_events(testing) -> void:
	testing.begin("input_map built-in: bind keeps the events project.godot saves for it")
	var original: Dictionary = _snapshot_setting(_BUILTIN_ACTION)
	ProjectSettings.set_setting("input/" + _BUILTIN_ACTION, {
		"deadzone": 0.4,
		"events": [_key_event(KEY_F7)],
	})
	var response := _bind(_BUILTIN_ACTION, "F9")
	var setting: Variant = ProjectSettings.get_setting("input/" + _BUILTIN_ACTION)
	_restore_setting(_BUILTIN_ACTION, original)

	testing.eq(str(response.get("status", "")), "created", "bind F9 → created")
	testing.eq(_setting_keycodes(setting), [KEY_F7, KEY_F9], "the saved F7, then F9")
	testing.eq(_setting_events(setting).size(), 2, "and nothing else")
	testing.ok(absf(_setting_deadzone(setting) - 0.4) < 0.001,
		"the saved deadzone 0.4 stays (got %f)" % _setting_deadzone(setting))
	print("")


static func _test_bind_builtin_keeps_joypad_defaults(testing) -> void:
	testing.begin("input_map built-in: bind with nothing saved keeps the default's joypad events")
	var original: Dictionary = _snapshot_setting(_JOYPAD_BUILTIN_ACTION)
	# A copy: the default's own Array would change with an in-place edit of the default.
	var default_events := _setting_events(_builtin_default(_JOYPAD_BUILTIN_ACTION)).duplicate()
	ProjectSettings.set_setting("input/" + _JOYPAD_BUILTIN_ACTION, _builtin_default(_JOYPAD_BUILTIN_ACTION))
	var input_map_events := _narrow_to_editor_keys(_JOYPAD_BUILTIN_ACTION)
	var response := _bind(_JOYPAD_BUILTIN_ACTION, "F9")
	var saved_events := _setting_events(ProjectSettings.get_setting("input/" + _JOYPAD_BUILTIN_ACTION))
	_restore_input_map_events(_JOYPAD_BUILTIN_ACTION, input_map_events)
	_restore_setting(_JOYPAD_BUILTIN_ACTION, original)

	var default_buttons: Array = default_events.filter(func(event: Variant) -> bool:
		return event is InputEventJoypadButton)
	var default_motions: Array = default_events.filter(func(event: Variant) -> bool:
		return event is InputEventJoypadMotion)
	var kept_joypad: Array = (default_buttons + default_motions).filter(func(event: Variant) -> bool:
		return saved_events.has(event))
	testing.eq(str(response.get("status", "")), "created", "bind F9 → created")
	testing.ok(not default_buttons.is_empty() and not default_motions.is_empty(),
		"ui_left's default holds a joypad button and a joypad motion (%d, %d)" % [
			default_buttons.size(), default_motions.size()])
	testing.eq(kept_joypad.size(), default_buttons.size() + default_motions.size(),
		"every one of them is saved after the bind")
	print("")


static func _test_bind_builtin_keeps_each_default_event(testing) -> void:
	testing.begin("input_map built-in: bind F9 with nothing saved keeps each default event once")
	var original: Dictionary = _snapshot_setting(_BUILTIN_ACTION)
	# A copy, so the last check compares the default after the bind with the one before.
	var default_events := _setting_events(_builtin_default(_BUILTIN_ACTION)).duplicate()
	ProjectSettings.set_setting("input/" + _BUILTIN_ACTION, _builtin_default(_BUILTIN_ACTION))
	var input_map_events := _narrow_to_editor_keys(_BUILTIN_ACTION)
	_bind(_BUILTIN_ACTION, "F9")
	var saved_events := _setting_events(ProjectSettings.get_setting("input/" + _BUILTIN_ACTION))
	var default_after := _setting_events(_builtin_default(_BUILTIN_ACTION))
	_restore_input_map_events(_BUILTIN_ACTION, input_map_events)
	_restore_setting(_BUILTIN_ACTION, original)

	for keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
		testing.eq(_count_logical_keys(saved_events, keycode), 1,
			"the default's logical %s is saved once" % OS.get_keycode_string(keycode))
	testing.eq(_setting_keycodes({"events": saved_events}).count(KEY_F9), 1, "F9 is saved once")
	testing.eq(saved_events.size(), default_events.size() + 1,
		"the default's %d events and F9, none dropped or merged" % default_events.size())
	testing.ok(default_after == default_events, "and the engine's default itself is unchanged")
	print("")


# A built-in action's keys set the logical keycode and leave physical_keycode at 0;
# the handlers build the physical one. Comparing physical_keycode alone made every
# logical key equal to every other.
static func _test_key_equivalence(testing) -> void:
	testing.begin("input_map key equivalence: all three key codes compare exactly")
	var enter := _logical_key_event(KEY_ENTER)
	var space := _logical_key_event(KEY_SPACE)
	var physical_enter := _key_event(KEY_ENTER)
	var labelled_enter := InputEventKey.new()
	labelled_enter.key_label = KEY_ENTER
	var shift_enter := _logical_key_event(KEY_ENTER)
	shift_enter.shift_pressed = true

	testing.ok(not InputMapCommands._input_events_equivalent(enter, space),
		"logical ENTER and logical SPACE are different bindings")
	testing.ok(not InputMapCommands._input_events_equivalent(enter, physical_enter),
		"logical ENTER and physical ENTER are different bindings")
	testing.ok(not InputMapCommands._input_events_equivalent(enter, labelled_enter),
		"logical ENTER and an ENTER key label are different bindings")
	testing.ok(not InputMapCommands._input_events_equivalent(enter, shift_enter),
		"ENTER and Shift+ENTER are different bindings")
	testing.ok(InputMapCommands._input_events_equivalent(enter, _logical_key_event(KEY_ENTER)),
		"two logical ENTER events are the same binding")
	testing.ok(InputMapCommands._input_events_equivalent(physical_enter, _key_event(KEY_ENTER)),
		"two physical ENTER events are the same binding")
	print("")


static func _test_add_uses_default_deadzone(testing) -> void:
	testing.begin("input_map deadzone: add with none, or a setting without one, uses the engine's default")
	var version := Engine.get_version_info()
	var from_4_4 := int(version["major"]) > 4 or int(version["minor"]) >= 4
	var engine_default := 0.2 if from_4_4 else 0.5
	var default_deadzone := _settings().default_deadzone()
	_clear_actions([_ACTION, _OTHER_ACTION])
	var added := _action_call("add", _ACTION)
	var added_setting: Variant = ProjectSettings.get_setting("input/" + _ACTION, null)
	ProjectSettings.set_setting("input/" + _OTHER_ACTION, {"events": []})
	var add_existing := _action_call("add", _OTHER_ACTION)
	var read_deadzone := _settings().get_deadzone(_OTHER_ACTION)
	_bind(_OTHER_ACTION, "F7")
	var bound_setting: Variant = ProjectSettings.get_setting("input/" + _OTHER_ACTION, null)
	_clear_actions([_ACTION, _OTHER_ACTION])

	testing.ok(absf(default_deadzone - engine_default) < 0.001,
		"the default is the running engine's: %f on %d.%d (got %f)" % [
			engine_default, int(version["major"]), int(version["minor"]), default_deadzone])
	testing.eq(str(added.get("status", "")), "created", "add with no deadzone → created")
	testing.ok(absf(float(added.get("deadzone", -1.0)) - default_deadzone) < 0.001,
		"answers the default deadzone (%s)" % str(added))
	testing.ok(absf(_setting_deadzone(added_setting) - default_deadzone) < 0.001,
		"and saves it (got %f)" % _setting_deadzone(added_setting))
	testing.ok(absf(float(add_existing.get("deadzone", -1.0)) - default_deadzone) < 0.001,
		"an action saved without a deadzone answers add with the default (%s)" % str(add_existing))
	testing.ok(absf(read_deadzone - default_deadzone) < 0.001,
		"and reads as the default (got %f)" % read_deadzone)
	testing.ok(absf(_setting_deadzone(bound_setting) - default_deadzone) < 0.001,
		"and a bind on it saves the default (got %f)" % _setting_deadzone(bound_setting))
	print("")


# --- Guards: green-only; the code these pin is unchanged ------------------------

static func _test_builtin_refusals_leave_setting(testing) -> void:
	testing.begin("input_map built-in guard: remove and rename refuse it and leave its setting")
	var original: Dictionary = _snapshot_setting(_BUILTIN_ACTION)
	var remove := _action_call("remove", _BUILTIN_ACTION)
	var rename := _rename(_BUILTIN_ACTION, _RENAMED_ACTION)
	var value_after: Variant = ProjectSettings.get_setting("input/" + _BUILTIN_ACTION, null)
	var order_after := ProjectSettings.get_order("input/" + _BUILTIN_ACTION) \
		if ProjectSettings.has_setting("input/" + _BUILTIN_ACTION) else -1
	var renamed_exists := ProjectSettings.has_setting("input/" + _RENAMED_ACTION)
	_clear_actions([_RENAMED_ACTION])
	_restore_setting(_BUILTIN_ACTION, original)

	testing.eq(str(remove.get("code", "")), "INVALID_PARAMS", "remove → INVALID_PARAMS")
	testing.ok(str(remove.get("error", "")).contains("built-in UI action"),
		"refused as a built-in action (%s)" % str(remove.get("error", "")))
	testing.eq(str(rename.get("code", "")), "INVALID_PARAMS", "rename → INVALID_PARAMS")
	testing.ok(value_after == original["value"], "input/ui_accept keeps its value")
	testing.eq(order_after, int(original["order"]), "and its order")
	testing.ok(not renamed_exists, "and no setting appears under the new name")
	print("")


# ProjectSettings.clear() on a built-in action drops its order; a later set_setting
# then orders it as a project action.
static func _test_bind_keeps_builtin_order(testing) -> void:
	testing.begin("input_map built-in guard: bind and unbind keep its order and built-in status")
	var original: Dictionary = _snapshot_setting(_BUILTIN_ACTION)
	var default_value: Variant = _builtin_default(_BUILTIN_ACTION)
	ProjectSettings.set_setting("input/" + _BUILTIN_ACTION, default_value)
	_bind(_BUILTIN_ACTION, "F9")
	var order_after_bind := ProjectSettings.get_order("input/" + _BUILTIN_ACTION)
	var unbind := _unbind(_BUILTIN_ACTION, "F9")
	var order_after_unbind := ProjectSettings.get_order("input/" + _BUILTIN_ACTION)
	var builtin_after := _settings().is_builtin(_BUILTIN_ACTION)
	var value_after: Variant = ProjectSettings.get_setting("input/" + _BUILTIN_ACTION)
	_restore_setting(_BUILTIN_ACTION, original)

	testing.eq(order_after_bind, int(original["order"]), "bind keeps input/ui_accept's order")
	testing.ok(bool(unbind.get("success", false)), "unbind F9 answers success (%s)" % str(unbind))
	testing.eq(order_after_unbind, int(original["order"]), "unbind keeps it too")
	testing.ok(builtin_after, "ui_accept is still a built-in action")
	testing.ok(value_after == default_value, "and holds the default's content again")
	print("")


# --- The built-in rule -------------------------------------------------------
# The oracle: the engine keeps an initial value (the revert value) only for the
# settings it registers itself, so property_get_revert returns a Dictionary for a
# built-in action and null for a project action. The rule reads the registration
# order instead, so the two are independent.

static func _test_builtin_rule_matches_engine(testing) -> void:
	testing.begin("input_map built-in rule: agrees with the engine on every input/ setting")
	# Seeded so the scan meets project actions as well as the engine's own.
	_seed_action(_ACTION, 0.5, [])
	ProjectSettings.set_setting("input/" + _UI_PREFIXED_ACTION, {"deadzone": 0.5, "events": []})
	var settings := _settings()
	var builtin_count := 0
	var project_count := 0
	var disagreements: Array[String] = []
	for property in ProjectSettings.get_property_list():
		var setting_name := str(property["name"])
		if not setting_name.begins_with("input/"):
			continue
		var action := setting_name.trim_prefix("input/")
		var engine_builtin := typeof(ProjectSettings.property_get_revert(setting_name)) == TYPE_DICTIONARY
		if engine_builtin:
			builtin_count += 1
		else:
			project_count += 1
		if settings.is_builtin(action) != engine_builtin:
			disagreements.append(action)
	_clear_actions([_ACTION, _UI_PREFIXED_ACTION])

	testing.ok(builtin_count > 0, "the scan found built-in actions (%d)" % builtin_count)
	testing.ok(project_count >= 2, "the scan found the seeded project actions (%d)" % project_count)
	testing.ok(disagreements.is_empty(), "the rule and the engine agree (differ on: %s)" % str(disagreements))
	print("")


static func _test_ui_prefixed_project_action(testing) -> void:
	testing.begin("input_map built-in rule: a project action named ui_* is not built-in")
	var setting_name := "input/" + _UI_PREFIXED_ACTION
	ProjectSettings.set_setting(setting_name, {"deadzone": 0.5, "events": []})
	var rule_builtin := _settings().is_builtin(_UI_PREFIXED_ACTION)
	var engine_revert: Variant = ProjectSettings.property_get_revert(setting_name)
	ProjectSettings.clear(setting_name)

	testing.ok(not rule_builtin, "ui_inventory is a project action")
	testing.eq(typeof(engine_revert), TYPE_NIL, "the engine keeps no initial value for it")
	print("")


# --- Rename ------------------------------------------------------------------

static func _test_rename_moves_setting(testing) -> void:
	testing.begin("input_map rename: the saved action moves to the new name")
	var original: Dictionary = _snapshot_setting(_BUILTIN_ACTION)
	_seed_action(_ACTION, 0.3, [_key_event(KEY_F7)])
	var old_value: Variant = ProjectSettings.get_setting("input/" + _ACTION)
	var input_map_before := _input_map_snapshot()
	# Checked after each call: a bind that changed InputMap and the unbind after it
	# would cancel out in a single snapshot taken at the end.
	var changed_input_map: Array[String] = []
	_action_call("add", _OTHER_ACTION)
	_note_input_map_change(input_map_before, "add", changed_input_map)
	_bind(_OTHER_ACTION, "F8")
	_note_input_map_change(input_map_before, "bind on a project action", changed_input_map)
	_unbind(_OTHER_ACTION, "F8")
	_note_input_map_change(input_map_before, "unbind on a project action", changed_input_map)
	_bind(_BUILTIN_ACTION, "F9")
	_note_input_map_change(input_map_before, "bind on ui_accept", changed_input_map)
	_unbind(_BUILTIN_ACTION, "F9")
	_note_input_map_change(input_map_before, "unbind on ui_accept", changed_input_map)
	var response := _rename(_ACTION, _RENAMED_ACTION)
	_note_input_map_change(input_map_before, "rename", changed_input_map)
	var new_value: Variant = ProjectSettings.get_setting("input/" + _RENAMED_ACTION, null)
	var old_left := ProjectSettings.has_setting("input/" + _ACTION)
	_clear_actions([_ACTION, _OTHER_ACTION, _RENAMED_ACTION])
	_restore_setting(_BUILTIN_ACTION, original)

	testing.ok(bool(response.get("success", false)), "rename answers success (%s)" % str(response))
	testing.eq(str(response.get("name", "")), _RENAMED_ACTION, "answers the new name")
	testing.eq(str(response.get("old_name", "")), _ACTION, "answers the old name")
	testing.ok(new_value == old_value, "input/<new_name> holds the old setting")
	testing.eq(_setting_keycodes(new_value), [KEY_F7], "the moved event keeps its physical keycode F7")
	testing.ok(absf(_setting_deadzone(new_value) - 0.3) < 0.001,
		"the moved deadzone stays 0.3 (got %f)" % _setting_deadzone(new_value))
	testing.ok(not old_left, "input/<name> is gone")
	testing.ok(changed_input_map.is_empty(),
		"InputMap is untouched after each add, bind, unbind and rename (%d actions; changed by: %s)" % [
			input_map_before.size(), str(changed_input_map)])
	print("")


# A new setting is ordered after every other one; the editor's rename puts it back in
# the old one's place in [input].
static func _test_rename_keeps_order(testing) -> void:
	testing.begin("input_map rename: the action keeps its place in [input]")
	_seed_action(_ACTION, 0.5, [])
	_seed_action(_OTHER_ACTION, 0.5, [])
	var old_order := ProjectSettings.get_order("input/" + _ACTION)
	var other_order := ProjectSettings.get_order("input/" + _OTHER_ACTION)
	_rename(_ACTION, _RENAMED_ACTION)
	var new_key := "input/" + _RENAMED_ACTION
	# get_order() logs an error for a setting that does not exist.
	var new_order := ProjectSettings.get_order(new_key) if ProjectSettings.has_setting(new_key) else -1
	_clear_actions([_ACTION, _OTHER_ACTION, _RENAMED_ACTION])

	testing.eq(new_order, old_order, "input/<new_name> takes the old setting's order")
	testing.ok(new_order != -1 and new_order < other_order,
		"and still sits before the action saved after it (%d < %d)" % [new_order, other_order])
	print("")


static func _test_rename_refusals(testing) -> void:
	testing.begin("input_map rename: refusals")
	var original: Dictionary = _snapshot_setting(_BUILTIN_ACTION)
	_seed_action(_ACTION, 0.3, [_key_event(KEY_F7)])
	_seed_action(_OTHER_ACTION, 0.5, [])
	var builtin_source := _rename(_BUILTIN_ACTION, _RENAMED_ACTION)
	var onto_builtin := _rename(_ACTION, _BUILTIN_ACTION)
	var onto_project_action := _rename(_ACTION, _OTHER_ACTION)
	var same_name := _rename(_ACTION, _ACTION)
	var missing_new_name := _rename(_ACTION, null)
	var empty_new_name := _rename(_ACTION, "")
	var unknown_name := _rename("mcp_test_missing_action", _RENAMED_ACTION)
	var kept_after_refusals := ProjectSettings.has_setting("input/" + _ACTION)
	_clear_actions([_ACTION, _OTHER_ACTION, _RENAMED_ACTION])
	_restore_setting(_BUILTIN_ACTION, original)

	testing.eq(str(builtin_source.get("code", "")), "INVALID_PARAMS", "a built-in source → INVALID_PARAMS")
	testing.ok(str(builtin_source.get("error", "")).contains("built-in"),
		"refused as a built-in action (%s)" % str(builtin_source.get("error", "")))
	testing.eq(str(onto_builtin.get("code", "")), "ALREADY_EXISTS",
		"onto ui_accept, which project.godot does not override → ALREADY_EXISTS")
	testing.eq(str(onto_project_action.get("code", "")), "ALREADY_EXISTS",
		"onto another project action → ALREADY_EXISTS")
	testing.ok(kept_after_refusals, "a refused rename leaves input/<name> in place")
	testing.eq(str(same_name.get("code", "")), "INVALID_PARAMS", "new_name equal to name → INVALID_PARAMS")
	testing.ok(str(same_name.get("error", "")).contains("new_name equals name"),
		"refused as the same name (%s)" % str(same_name.get("error", "")))
	testing.eq(str(missing_new_name.get("code", "")), "INVALID_PARAMS", "no new_name → INVALID_PARAMS")
	testing.ok(str(missing_new_name.get("error", "")).contains("new_name must be a non-empty string"),
		"refused for the missing new_name (%s)" % str(missing_new_name.get("error", "")))
	testing.eq(str(empty_new_name.get("code", "")), "INVALID_PARAMS", "an empty new_name → INVALID_PARAMS")
	testing.ok(str(empty_new_name.get("error", "")).contains("new_name must be a non-empty string"),
		"refused for the empty new_name (%s)" % str(empty_new_name.get("error", "")))
	testing.eq(str(unknown_name.get("code", "")), "NOT_FOUND", "a name with no input/<name> setting → NOT_FOUND")
	print("")


# --- Helpers -----------------------------------------------------------------

## Sets the setting of the project action [param action] to [param deadzone] and
## [param events]; the handlers never put it in InputMap.
static func _seed_action(action: String, deadzone: float, events: Array) -> void:
	ProjectSettings.set_setting("input/" + action, {"deadzone": deadzone, "events": events})


## Deletes the settings of the project actions [param actions] that have one.
static func _clear_actions(actions: Array[String]) -> void:
	for action in actions:
		if ProjectSettings.has_setting("input/" + action):
			ProjectSettings.clear("input/" + action)


## Returns the built-in action [param action]'s setting value and order, for
## [method _restore_setting].
static func _snapshot_setting(action: String) -> Dictionary:
	var setting_name := "input/" + action
	return {
		"value": ProjectSettings.get_setting(setting_name),
		"order": ProjectSettings.get_order(setting_name),
	}


## Puts the built-in action [param action]'s setting back to [param snapshot], from
## [method _snapshot_setting]. It never clears the setting: that would drop its default.
static func _restore_setting(action: String, snapshot: Dictionary) -> void:
	var setting_name := "input/" + action
	ProjectSettings.set_setting(setting_name, snapshot["value"])
	ProjectSettings.set_order(setting_name, int(snapshot["order"]))


## Returns the built-in action [param action]'s default: the setting the engine
## registers for it, which project.godot changes only by saving another value.
static func _builtin_default(action: String) -> Variant:
	return ProjectSettings.property_get_revert("input/" + action)


## Leaves only the key events of [param action] in this process's InputMap, as the editor
## holds a built-in action, and returns the events it held before.
static func _narrow_to_editor_keys(action: String) -> Array:
	var events: Array = InputMap.action_get_events(action)
	InputMap.action_erase_events(action)
	for event in events:
		if event is InputEventKey:
			InputMap.action_add_event(action, event)
	return events


## Puts [param events] back as [param action]'s InputMap events.
static func _restore_input_map_events(action: String, events: Array) -> void:
	InputMap.action_erase_events(action)
	for event in events:
		InputMap.action_add_event(action, event)


## Returns every InputMap action with its deadzone and events, to compare before and
## after the handlers run.
static func _input_map_snapshot() -> Dictionary:
	var snapshot := {}
	for action in InputMap.get_actions():
		snapshot[action] = [InputMap.action_get_deadzone(action), InputMap.action_get_events(action)]
	return snapshot


## Appends [param call_name] to [param changed] when InputMap no longer matches
## [param before], from [method _input_map_snapshot].
static func _note_input_map_change(before: Dictionary, call_name: String, changed: Array[String]) -> void:
	if _input_map_snapshot() != before:
		changed.append(call_name)


## Returns a key event built as the handlers build one: from the physical keycode.
static func _key_event(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	return event


## Returns a key event built as the engine builds a built-in action's key: from the
## logical keycode.
static func _logical_key_event(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	return event


## Returns how many events in [param events] are the logical key [param keycode] with
## no physical keycode.
static func _count_logical_keys(events: Array, keycode: Key) -> int:
	var count := 0
	for event in events:
		if event is InputEventKey and (event as InputEventKey).keycode == keycode \
				and (event as InputEventKey).physical_keycode == KEY_NONE:
			count += 1
	return count


## Returns the events of an input/<name> setting [param setting]; empty when it is not an
## action's Dictionary.
static func _setting_events(setting: Variant) -> Array:
	if typeof(setting) != TYPE_DICTIONARY:
		return []
	var events: Variant = setting.get("events", [])
	if typeof(events) != TYPE_ARRAY:
		return []
	return events


## Returns the physical keycodes of the key events in an input/<name> setting
## [param setting], in order; empty when it is not an action's Dictionary.
static func _setting_keycodes(setting: Variant) -> Array:
	var keycodes: Array = []
	for event in _setting_events(setting):
		if event is InputEventKey:
			keycodes.append((event as InputEventKey).physical_keycode)
	return keycodes


## Returns the deadzone in an input/<name> setting [param setting], or -1.0 when it is
## not an action's Dictionary.
static func _setting_deadzone(setting: Variant) -> float:
	if typeof(setting) != TYPE_DICTIONARY:
		return -1.0
	return float(setting.get("deadzone", -1.0))


## Returns the settings helper with a save that does not write project.godot.
static func _settings() -> InputActionSettings:
	return UnsavedInputActionSettings.new()


## Runs the input_map.action handler's [param action] on [param name].
static func _action_call(action: String, name: String) -> Dictionary:
	return UnsavedInputMapCommands.new()._cmd_input_map_action({"action": action, "name": name})


## Runs the input_map.event handler's bind of the key [param keycode] on [param action].
static func _bind(action: String, keycode: String) -> Dictionary:
	return UnsavedInputMapCommands.new()._cmd_input_map_event({
		"action": "bind",
		"name": action,
		"event": {"type": "key", "keycode": keycode},
	})


## Runs the input_map.event handler's unbind of the key [param keycode] on [param action].
static func _unbind(action: String, keycode: String) -> Dictionary:
	return UnsavedInputMapCommands.new()._cmd_input_map_event({
		"action": "unbind",
		"name": action,
		"event": {"type": "key", "keycode": keycode},
	})


## Runs the input_map.action handler's rename on [UnsavedInputMapCommands]; a null
## [param new_name] leaves the parameter out.
static func _rename(action: String, new_name: Variant) -> Dictionary:
	var parameters := {"action": "rename", "name": action}
	if new_name != null:
		parameters["new_name"] = new_name
	return UnsavedInputMapCommands.new()._cmd_input_map_action(parameters)


## The input-action settings with a save that keeps project.godot untouched.
class UnsavedInputActionSettings extends InputActionSettings:
	func save() -> Error:
		return OK


## The input_map command handlers on [UnsavedInputActionSettings], so a test can run a
## handler that saves.
class UnsavedInputMapCommands extends InputMapCommands:
	func _create_settings() -> InputActionSettings:
		return UnsavedInputActionSettings.new()
