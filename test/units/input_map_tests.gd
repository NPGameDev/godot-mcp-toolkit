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

const InputMapCommands := preload("res://addons/godot_mcp_toolkit/commands/input_map/input_map_commands.gd")
const InputActionSettings := preload("res://addons/godot_mcp_toolkit/commands/input_map/input_action_settings.gd")
const InputEventEquivalence := preload("res://addons/godot_mcp_toolkit/commands/input_map/input_event_equivalence.gd")

const _ACTION := "mcp_test_project_action"
## A project action whose name looks like a built-in one.
const _UI_PREFIXED_ACTION := "ui_inventory"
const _BUILTIN_ACTION := "ui_accept"
## A built-in action whose default holds joypad events; ui_accept's holds keys only.
const _JOYPAD_BUILTIN_ACTION := "ui_left"
## A project action whose name the engine reads as a feature override: everything after
## the first dot is feature tags, and neither tag is one a running engine has.
const _DOTTED_ACTION := "mcp_test_dotted.mcp_tag_one.mcp_tag_two"
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
	_test_list_registration(testing)
	_test_list_default_set(testing)
	_test_list_include_builtin(testing)
	_test_list_name(testing)
	_test_list_can_revert_follows_editor_rule(testing)
	_test_list_dotted_project_action(testing)
	_test_list_builtin_feature_entry(testing)
	_test_list_unknown_event_class(testing)
	_test_revert_reverts_changed_builtin(testing)
	_test_revert_returns_saved_default(testing)
	_test_revert_rebuilt_default_line(testing)
	_test_revert_refusals(testing)
	_test_bind_after_revert_keeps_default(testing)
	_test_remove_refusal_names_revert(testing)
	_test_read_event_unbinds_logical_key(testing)
	_test_command_or_control_round_trip(testing)
	_test_key_kind_build_and_serialise(testing)
	_test_key_equivalence_rules(testing)
	_test_key_location(testing)
	_test_mouse_pressed_ignored(testing)
	_test_mouse_equivalence(testing)
	_test_joypad_equivalence(testing)
	_test_device_wildcards(testing)
	_test_legacy_device_zero(testing)
	_test_event_shape_refusals(testing)


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

	testing.ok(not InputEventEquivalence.are_equivalent(enter, space),
		"logical ENTER and logical SPACE are different bindings")
	testing.ok(not InputEventEquivalence.are_equivalent(enter, physical_enter),
		"logical ENTER and physical ENTER are different bindings")
	testing.ok(not InputEventEquivalence.are_equivalent(enter, labelled_enter),
		"logical ENTER and an ENTER key label are different bindings")
	testing.ok(not InputEventEquivalence.are_equivalent(enter, shift_enter),
		"ENTER and Shift+ENTER are different bindings")
	testing.ok(InputEventEquivalence.are_equivalent(enter, _logical_key_event(KEY_ENTER)),
		"two logical ENTER events are the same binding")
	testing.ok(InputEventEquivalence.are_equivalent(physical_enter, _key_event(KEY_ENTER)),
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


# --- input_map.list ----------------------------------------------------------

static func _test_list_registration(testing) -> void:
	testing.begin("input_map list: registered read-only beside the two write commands")
	var registry := MCPToolkitCommandRegistry.new()
	InputMapCommands.register(registry, null)

	testing.ok(registry.has_command("input_map.list"), "input_map.list is registered")
	testing.ok(registry.is_read_only("input_map.list"), "and marked read-only")
	testing.ok(not registry.is_read_only("input_map.action"), "input_map.action is not read-only")
	testing.ok(not registry.is_read_only("input_map.event"), "input_map.event is not read-only")
	testing.ok(not registry.is_active_scene_required("input_map.list"), "input_map.list needs no open scene")
	print("")


static func _test_list_default_set(testing) -> void:
	testing.begin("input_map list: project actions and changed built-ins, in [input] order")
	var accept_original: Dictionary = _snapshot_setting(_BUILTIN_ACTION)
	var left_original: Dictionary = _snapshot_setting(_JOYPAD_BUILTIN_ACTION)
	ProjectSettings.set_setting("input/" + _JOYPAD_BUILTIN_ACTION, _builtin_default(_JOYPAD_BUILTIN_ACTION))
	ProjectSettings.set_setting("input/" + _BUILTIN_ACTION, {
		"deadzone": 0.5,
		"events": [_key_event(KEY_F9)],
	})
	_seed_action(_ACTION, 0.3, [_key_event(KEY_F7)])
	_seed_action(_OTHER_ACTION, 0.5, [])
	var response := _list({})
	_clear_actions([_ACTION, _OTHER_ACTION])
	_restore_setting(_JOYPAD_BUILTIN_ACTION, left_original)
	_restore_setting(_BUILTIN_ACTION, accept_original)

	var names := _entry_names(response)
	var entry := _entry(response, _ACTION)
	testing.ok(bool(response.get("success", false)), "list answers success (%s)" % str(response.get("error", "")))
	testing.eq(int(response.get("count", -1)), names.size(), "count is the number of actions listed")
	testing.ok(names.has(_ACTION) and names.has(_OTHER_ACTION), "the project actions are listed")
	testing.ok(names.has(_BUILTIN_ACTION), "ui_accept, changed, is listed")
	testing.ok(not names.has(_JOYPAD_BUILTIN_ACTION), "ui_left, at its default, is not")
	testing.ok(names.find(_BUILTIN_ACTION) < names.find(_ACTION) and names.find(_ACTION) < names.find(_OTHER_ACTION),
		"in [input] order: the built-in, then the project actions as saved (%s)" % str(names))
	testing.eq(str(entry.get("source", "")), "project", "a project action has source project")
	testing.ok(absf(float(entry.get("deadzone", -1.0)) - 0.3) < 0.001, "with its deadzone 0.3 (%s)" % str(entry))
	testing.eq(_entry_keycodes(entry), [KEY_F7], "and its event F7")
	testing.ok(not bool(entry.get("can_revert", true)), "a project action cannot be reverted")
	testing.ok(not entry.has("default") and not entry.has("feature"), "and carries no default and no feature")
	print("")


static func _test_list_include_builtin(testing) -> void:
	testing.begin("input_map list: include_builtin adds the built-ins at their default")
	var left_original: Dictionary = _snapshot_setting(_JOYPAD_BUILTIN_ACTION)
	ProjectSettings.set_setting("input/" + _JOYPAD_BUILTIN_ACTION, _builtin_default(_JOYPAD_BUILTIN_ACTION))
	var response := _list({"include_builtin": true})
	_restore_setting(_JOYPAD_BUILTIN_ACTION, left_original)

	var entry := _entry(response, _JOYPAD_BUILTIN_ACTION)
	var types: Array = _entry_events(entry).map(func(event: Dictionary) -> String:
		return str(event.get("type", "")))
	var joypad_button := _first_event_of_type(_entry_events(entry), "joypad_button")
	testing.eq(str(entry.get("source", "")), "builtin", "ui_left is listed with source builtin")
	testing.ok(not bool(entry.get("can_revert", true)), "can_revert false: it holds its default")
	testing.ok(not entry.has("default"), "and no default is given")
	testing.ok(types.has("key") and types.has("joypad_button") and types.has("joypad_motion"),
		"its events read as key, joypad_button and joypad_motion (%s)" % str(types))
	testing.eq(str(joypad_button.get("class", "")), "InputEventJoypadButton", "each event carries its class")
	# The default's joypad device is 0 before 4.6 and -1 from 4.6.
	testing.ok(typeof(joypad_button.get("device")) in [TYPE_INT, TYPE_FLOAT],
		"and its device (%s)" % str(joypad_button))
	testing.eq(int(response.get("count", -1)), _entry_names(response).size(), "count is the number listed")
	print("")


static func _test_list_name(testing) -> void:
	testing.begin("input_map list: name answers one action, built-in or not")
	var left_original: Dictionary = _snapshot_setting(_JOYPAD_BUILTIN_ACTION)
	ProjectSettings.set_setting("input/" + _JOYPAD_BUILTIN_ACTION, _builtin_default(_JOYPAD_BUILTIN_ACTION))
	_seed_action(_ACTION, 0.3, [])
	var builtin_hit := _list({"name": _JOYPAD_BUILTIN_ACTION})
	var project_hit := _list({"name": _ACTION})
	var miss := _list({"name": "mcp_test_missing_action"})
	_clear_actions([_ACTION])
	_restore_setting(_JOYPAD_BUILTIN_ACTION, left_original)

	testing.eq(_entry_names(builtin_hit), [_JOYPAD_BUILTIN_ACTION], "a built-in at its default, by name")
	testing.eq(int(builtin_hit.get("count", -1)), 1, "count 1")
	testing.eq(_entry_names(project_hit), [_ACTION], "a project action, by name")
	testing.eq(str(miss.get("code", "")), "NOT_FOUND", "an unknown name → NOT_FOUND")
	testing.ok(str(miss.get("error", "")).contains("call input_map_list without name"),
		"pointing at the list call (%s)" % str(miss.get("error", "")))
	print("")


# The editor's revert arrow: the deadzone, the event count, then each pair at the same
# index through InputEvent.is_match(other, true). Order counts; the event objects do not.
static func _test_list_can_revert_follows_editor_rule(testing) -> void:
	testing.begin("input_map list: can_revert follows the editor's revert arrow")
	var original: Dictionary = _snapshot_setting(_BUILTIN_ACTION)
	var default_events := _setting_events(_builtin_default(_BUILTIN_ACTION)).duplicate()
	var default_deadzone := _setting_deadzone(_builtin_default(_BUILTIN_ACTION))
	var reordered := _rebuilt_events(default_events)
	reordered.reverse()
	var states := {
		"at its default": _builtin_default(_BUILTIN_ACTION),
		"rebuilt with the same content": {"deadzone": default_deadzone, "events": _rebuilt_events(default_events)},
		"with another deadzone": {"deadzone": 0.95, "events": _rebuilt_events(default_events)},
		"with its events reordered": {"deadzone": default_deadzone, "events": reordered},
		"with F9 added": {"deadzone": default_deadzone, "events": default_events + [_key_event(KEY_F9)]},
		"with each event on device 7": {"deadzone": default_deadzone, "events": _events_on_device(default_events, 7)},
	}
	var entries := {}
	for state in states:
		ProjectSettings.set_setting("input/" + _BUILTIN_ACTION, states[state])
		entries[state] = _entry(_list({"name": _BUILTIN_ACTION}), _BUILTIN_ACTION)
	_restore_setting(_BUILTIN_ACTION, original)

	for state in ["at its default", "rebuilt with the same content", "with each event on device 7"]:
		var entry: Dictionary = entries[state]
		testing.ok(entry.has("can_revert") and not bool(entry["can_revert"]), "ui_accept %s → can_revert false" % state)
		testing.ok(not entry.has("default"), "  and no default")
	for state in ["with another deadzone", "with its events reordered", "with F9 added"]:
		var entry: Dictionary = entries[state]
		testing.ok(bool(entry.get("can_revert", false)), "ui_accept %s → can_revert true" % state)
	var changed: Dictionary = entries["with another deadzone"]
	var default_value: Variant = changed.get("default", {})
	var default_entry: Dictionary = default_value if typeof(default_value) == TYPE_DICTIONARY else {}
	testing.ok(absf(float(default_entry.get("deadzone", -1.0)) - default_deadzone) < 0.001,
		"default.deadzone is the engine's (%s)" % str(default_entry))
	testing.eq(_entry_keycodes(default_entry), [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE],
		"default.events are ENTER, KP_ENTER and SPACE, in order")
	var changed_keycodes := _entry_keycodes(entries["with F9 added"])
	testing.ok(not changed_keycodes.is_empty() and changed_keycodes.back() == KEY_F9,
		"the changed events end with F9 (%s)" % str(changed_keycodes))
	print("")


static func _test_list_dotted_project_action(testing) -> void:
	testing.begin("input_map list: a dotted project action carries a feature and keeps its write operations")
	_seed_action(_DOTTED_ACTION, 0.5, [])
	var bind := _bind(_DOTTED_ACTION, "F7")
	var listed := _list({"name": _DOTTED_ACTION})
	var unbind := _unbind(_DOTTED_ACTION, "F7")
	var remove := _action_call("remove", _DOTTED_ACTION)
	var left_behind := ProjectSettings.has_setting("input/" + _DOTTED_ACTION)
	_clear_actions([_DOTTED_ACTION])

	var entry := _entry(listed, _DOTTED_ACTION)
	testing.eq(str(bind.get("status", "")), "created", "bind F7 → created")
	testing.eq(str(entry.get("source", "")), "project", "listed as a project action")
	testing.eq(str(entry.get("feature", "")), "mcp_tag_one.mcp_tag_two",
		"feature is everything after the first dot (%s)" % str(entry))
	testing.eq(str(entry.get("name", "")), _DOTTED_ACTION, "name stays the full setting name")
	testing.eq(_entry_keycodes(entry), [KEY_F7], "with its event F7")
	testing.ok(bool(unbind.get("success", false)), "unbind F7 → success (%s)" % str(unbind))
	testing.ok(bool(remove.get("success", false)) and not left_behind, "remove deletes it (%s)" % str(remove))
	print("")


static func _test_list_builtin_feature_entry(testing) -> void:
	testing.begin("input_map list: a built-in feature entry is listed, and bind, unbind, revert and remove refuse it")
	var action := _builtin_feature_action()
	if action.is_empty():
		testing.ok(false, "the engine registers a built-in input/<name>.macos setting")
		print("")
		return
	var original: Dictionary = _snapshot_setting(action)
	var listed := _list({"name": action})
	var bind := _bind(action, "F9")
	var unbind := _unbind(action, "F9")
	var revert := _action_call("revert", action)
	var value_after: Variant = ProjectSettings.get_setting("input/" + action)
	var remove := _action_call("remove", action)
	var kept_after_remove := ProjectSettings.has_setting("input/" + action)
	_restore_setting(action, original)

	var entry := _entry(listed, action)
	testing.eq(str(entry.get("source", "")), "builtin", "%s is listed as a built-in" % action)
	testing.eq(str(entry.get("feature", "")), "macos", "with feature macos")
	for response_name in ["bind", "unbind", "revert"]:
		var response: Dictionary = {"bind": bind, "unbind": unbind, "revert": revert}[response_name]
		testing.eq(str(response.get("code", "")), "INVALID_PARAMS", "%s → INVALID_PARAMS" % response_name)
		testing.ok(str(response.get("error", "")).contains("feature-override entries are read-only"),
			"  refused as read-only (%s)" % str(response.get("error", "")))
	testing.ok(value_after == original["value"], "and its setting is unchanged")
	testing.eq(str(remove.get("code", "")), "INVALID_PARAMS", "remove → INVALID_PARAMS")
	testing.ok(str(remove.get("error", "")).contains("feature-override entries are read-only")
			and not str(remove.get("error", "")).contains("revert"),
		"  refused as read-only, with no pointer to revert (%s)" % str(remove.get("error", "")))
	testing.ok(kept_after_remove, "  and the setting stays")
	print("")


static func _test_list_unknown_event_class(testing) -> void:
	testing.begin("input_map list: an event with no modelled type reads as unknown with its class")
	_seed_action(_ACTION, 0.5, [InputEventMIDI.new(), _key_event(KEY_F7)])
	var events := _entry_events(_entry(_list({"name": _ACTION}), _ACTION))
	_clear_actions([_ACTION])

	testing.eq(events.size(), 2, "both events are listed")
	if events.size() == 2:
		testing.eq(events[0], {"type": "unknown", "class": "InputEventMIDI"}, "a MIDI event → unknown + class")
		testing.eq(str(events[1].get("class", "")), "InputEventKey", "a key carries its class too")
	print("")


# --- revert ------------------------------------------------------------------

static func _test_revert_reverts_changed_builtin(testing) -> void:
	testing.begin("input_map revert: a changed built-in goes back to its default")
	var original: Dictionary = _snapshot_setting(_BUILTIN_ACTION)
	var setting_name := "input/" + _BUILTIN_ACTION
	ProjectSettings.set_setting(setting_name, {"deadzone": 0.95, "events": [_key_event(KEY_F9)]})
	var response := _action_call("revert", _BUILTIN_ACTION)
	var saved_as_default: bool = ProjectSettings.get_setting(setting_name) == ProjectSettings.property_get_revert(setting_name)
	var order_after := ProjectSettings.get_order(setting_name)
	_restore_setting(_BUILTIN_ACTION, original)

	testing.eq(str(response.get("status", "")), "reverted", "revert → reverted (%s)" % str(response))
	testing.eq(str(response.get("name", "")), _BUILTIN_ACTION, "answers the list entry: its name")
	testing.eq(str(response.get("source", "")), "builtin", "  its source")
	testing.eq(_entry_keycodes(response), [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE], "  its default's events")
	testing.ok(response.has("can_revert") and not bool(response["can_revert"]), "  and can_revert false")
	testing.ok(saved_as_default, "the setting is its revert value, so save() drops the line")
	testing.eq(order_after, int(original["order"]), "and it keeps its order")
	print("")


static func _test_revert_returns_saved_default(testing) -> void:
	testing.begin("input_map revert: a built-in already at its default answers returned")
	var original: Dictionary = _snapshot_setting(_BUILTIN_ACTION)
	var setting_name := "input/" + _BUILTIN_ACTION
	ProjectSettings.set_setting(setting_name, _builtin_default(_BUILTIN_ACTION))
	var value_before: Variant = ProjectSettings.get_setting(setting_name)
	var response := _action_call("revert", _BUILTIN_ACTION)
	var value_after: Variant = ProjectSettings.get_setting(setting_name)
	_restore_setting(_BUILTIN_ACTION, original)

	testing.eq(str(response.get("status", "")), "returned", "revert → returned (%s)" % str(response))
	testing.eq(_entry_keycodes(response), [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE], "with its default's events")
	testing.ok(is_same(value_after, value_before), "and the setting is left as it was")
	print("")


# save() keeps a line unless its value equals the initial one, events compared by
# identity, so a line rebuilt with equal content is still saved and revert must clear it.
static func _test_revert_rebuilt_default_line(testing) -> void:
	testing.begin("input_map revert: a line equal to the default but rebuilt is reverted, not returned")
	var original: Dictionary = _snapshot_setting(_BUILTIN_ACTION)
	var setting_name := "input/" + _BUILTIN_ACTION
	ProjectSettings.set_setting(setting_name, {
		"deadzone": _setting_deadzone(_builtin_default(_BUILTIN_ACTION)),
		"events": _rebuilt_events(_setting_events(_builtin_default(_BUILTIN_ACTION))),
	})
	var listed := _entry(_list({"name": _BUILTIN_ACTION}), _BUILTIN_ACTION)
	var response := _action_call("revert", _BUILTIN_ACTION)
	var saved_as_default: bool = ProjectSettings.get_setting(setting_name) == ProjectSettings.property_get_revert(setting_name)
	_restore_setting(_BUILTIN_ACTION, original)

	testing.ok(listed.has("can_revert") and not bool(listed["can_revert"]),
		"the list answers can_revert false: the content is the default's")
	testing.eq(str(response.get("status", "")), "reverted", "revert still clears it → reverted (%s)" % str(response))
	testing.ok(saved_as_default, "and the setting is then its revert value")
	print("")


static func _test_revert_refusals(testing) -> void:
	testing.begin("input_map revert: refusals")
	_seed_action(_ACTION, 0.5, [_key_event(KEY_F7)])
	var unknown := _action_call("revert", "mcp_test_missing_action")
	var project := _action_call("revert", _ACTION)
	var empty := _action_call("revert", "")
	var project_after: Variant = ProjectSettings.get_setting("input/" + _ACTION)
	_clear_actions([_ACTION])

	testing.eq(str(unknown.get("code", "")), "NOT_FOUND", "an unknown action → NOT_FOUND")
	testing.eq(str(project.get("code", "")), "INVALID_PARAMS", "a project action → INVALID_PARAMS")
	testing.ok(str(project.get("error", "")).contains("no default"),
		"refused as having no default (%s)" % str(project.get("error", "")))
	testing.eq(_setting_keycodes(project_after), [KEY_F7], "and the project action keeps its events")
	testing.eq(str(empty.get("code", "")), "INVALID_PARAMS", "an empty name → INVALID_PARAMS")
	print("")


# After revert the setting holds the default's own events Array; a bind that appended
# to it in place would change the default too, and save() would then drop the bind.
static func _test_bind_after_revert_keeps_default(testing) -> void:
	testing.begin("input_map revert: a bind after revert is saved and the default keeps its three keys")
	var original: Dictionary = _snapshot_setting(_BUILTIN_ACTION)
	var setting_name := "input/" + _BUILTIN_ACTION
	ProjectSettings.set_setting(setting_name, {"deadzone": 0.5, "events": [_key_event(KEY_F9)]})
	_action_call("revert", _BUILTIN_ACTION)
	var bind := _bind(_BUILTIN_ACTION, "F9")
	var saved_events := _setting_events(ProjectSettings.get_setting(setting_name))
	var default_events := _setting_events(_builtin_default(_BUILTIN_ACTION))
	var kept_by_save: bool = ProjectSettings.get_setting(setting_name) != ProjectSettings.property_get_revert(setting_name)
	_restore_setting(_BUILTIN_ACTION, original)

	testing.eq(str(bind.get("status", "")), "created", "bind F9 after revert → created")
	testing.eq(_setting_keycodes({"events": saved_events}).count(KEY_F9), 1, "the setting holds F9")
	testing.eq(saved_events.size(), 4, "with the default's three keys")
	testing.eq(default_events.size(), 3, "the default still holds its three keys")
	testing.ok(kept_by_save, "so save() keeps the line with F9")
	print("")


static func _test_remove_refusal_names_revert(testing) -> void:
	testing.begin("input_map revert: remove's built-in refusal names revert")
	var original: Dictionary = _snapshot_setting(_BUILTIN_ACTION)
	var remove := _action_call("remove", _BUILTIN_ACTION)
	_restore_setting(_BUILTIN_ACTION, original)

	testing.ok(str(remove.get("error", "")).contains("use action='revert' to restore its default events"),
		"remove ui_accept points at revert (%s)" % str(remove.get("error", "")))
	print("")


# --- The event shape round trip ----------------------------------------------

static func _test_read_event_unbinds_logical_key(testing) -> void:
	testing.begin("input_map round trip: an event read from the list unbinds ui_accept's logical ENTER")
	var original: Dictionary = _snapshot_setting(_BUILTIN_ACTION)
	ProjectSettings.set_setting("input/" + _BUILTIN_ACTION, _builtin_default(_BUILTIN_ACTION))
	var enter := _find_listed_key(_entry_events(_entry(_list({"name": _BUILTIN_ACTION}), _BUILTIN_ACTION)), KEY_ENTER)
	var unbind := _event_call("unbind", _BUILTIN_ACTION, enter)
	var saved_events := _setting_events(ProjectSettings.get_setting("input/" + _BUILTIN_ACTION))
	_restore_setting(_BUILTIN_ACTION, original)

	testing.eq(str(enter.get("key_kind", "")), "keycode", "the list reads ENTER as a logical keycode (%s)" % str(enter))
	testing.ok(bool(unbind.get("success", false)), "unbind with the read event → success (%s)" % str(unbind))
	testing.eq(_count_logical_keys(saved_events, KEY_ENTER), 0, "ENTER is no longer saved")
	testing.eq(_count_logical_keys(saved_events, KEY_KP_ENTER) + _count_logical_keys(saved_events, KEY_SPACE), 2,
		"KP_ENTER and SPACE stay")
	print("")


static func _test_command_or_control_round_trip(testing) -> void:
	testing.begin("input_map round trip: ui_copy's Command-or-Control C reads back, unbinds and binds")
	var action := "ui_copy"
	var setting_name := "input/" + action
	var original: Dictionary = _snapshot_setting(action)
	ProjectSettings.set_setting(setting_name, _builtin_default(action))
	var copy_key := _find_listed_key(_entry_events(_entry(_list({"name": action}), action)), KEY_C)
	var unbind := _event_call("unbind", action, copy_key)
	var after_unbind := _setting_events(ProjectSettings.get_setting(setting_name))
	var bind := _event_call("bind", action, copy_key)
	var after_bind := _setting_events(ProjectSettings.get_setting(setting_name))
	_restore_setting(action, original)

	var bound: Variant = after_bind.back() if not after_bind.is_empty() else null
	testing.ok(bool(copy_key.get("command_or_control", false)), "the list reads command_or_control true (%s)" % str(copy_key))
	testing.ok(bool(copy_key.get("ctrl", false)) or bool(copy_key.get("meta", false)),
		"with the ctrl or meta the engine sets for it")
	testing.ok(bool(unbind.get("success", false)), "unbind with the read event → success (%s)" % str(unbind))
	testing.eq(_count_logical_keys(after_unbind, KEY_C), 0, "C is no longer saved")
	testing.eq(str(bind.get("status", "")), "created", "bind with the read event → created (%s)" % str(bind))
	testing.ok(bound is InputEventKey and (bound as InputEventKey).keycode == KEY_C
			and (bound as InputEventKey).command_or_control_autoremap,
		"and saves a logical C with command_or_control on")
	print("")


static func _test_key_kind_build_and_serialise(testing) -> void:
	testing.begin("input_map key_kind: each kind builds and reads back its own code field")
	_seed_action(_ACTION, 0.5, [])
	var kinds := ["physical_keycode", "keycode", "key_label"]
	var responses: Array[Dictionary] = []
	for kind in kinds:
		responses.append(_event_call("bind", _ACTION, {"type": "key", "keycode": "F7", "key_kind": kind}))
	var default_kind := _event_call("bind", _ACTION, {"type": "key", "keycode": "F8"})
	var saved_events := _setting_events(ProjectSettings.get_setting("input/" + _ACTION))
	var listed := _entry_events(_entry(_list({"name": _ACTION}), _ACTION))
	_clear_actions([_ACTION])

	var expected_fields := [[0, KEY_F7, 0], [KEY_F7, 0, 0], [0, 0, KEY_F7]]
	for index in kinds.size():
		var response_event: Dictionary = responses[index].get("event", {})
		testing.eq(str(responses[index].get("status", "")), "created", "bind F7 as %s → created" % kinds[index])
		testing.eq(str(response_event.get("key_kind", "")), kinds[index],
			"  the response reads it back as %s" % kinds[index])
		testing.eq(_saved_key_fields(saved_events, index), expected_fields[index],
			"  and the saved event sets only that field ([keycode, physical, label])")
	var default_event: Dictionary = default_kind.get("event", {})
	testing.eq(str(default_event.get("key_kind", "")), "physical_keycode", "no key_kind builds a physical_keycode")
	testing.eq(listed.map(func(event: Dictionary) -> String: return str(event.get("key_kind", ""))),
		["physical_keycode", "keycode", "key_label", "physical_keycode"], "the list reads the four kinds back")
	testing.eq(_entry_keycodes({"events": listed}), [KEY_F7, KEY_F7, KEY_F7, KEY_F8], "each under keycode")
	print("")


# --- Equivalence -------------------------------------------------------------

static func _test_key_equivalence_rules(testing) -> void:
	testing.begin("input_map key equivalence: code, modifiers, command_or_control and device")
	_seed_action(_ACTION, 0.5, [])
	var plain := _event_call("bind", _ACTION, {"type": "key", "keycode": "C"})
	var on_device := _event_call("bind", _ACTION, {"type": "key", "keycode": "C", "device": 3})
	var with_ctrl := _event_call("bind", _ACTION, {"type": "key", "keycode": "C", "ctrl": true})
	var command := _event_call("bind", _ACTION, {"type": "key", "keycode": "C", "command_or_control": true})
	var command_with_ctrl := _event_call("bind", _ACTION,
		{"type": "key", "keycode": "C", "command_or_control": true, "ctrl": true, "meta": true})
	var with_shift := _event_call("bind", _ACTION, {"type": "key", "keycode": "C", "shift": true})
	var saved_count := _setting_events(ProjectSettings.get_setting("input/" + _ACTION)).size()
	_clear_actions([_ACTION])

	testing.eq(str(plain.get("status", "")), "created", "bind C → created")
	testing.eq(str(on_device.get("status", "")), "created", "bind C on device 3 → created: another device")
	testing.eq(str(with_ctrl.get("status", "")), "created", "bind Ctrl+C → created")
	testing.eq(str(command.get("status", "")), "created",
		"bind C with command_or_control → created: not the same as a plain Ctrl+C")
	testing.eq(str(command_with_ctrl.get("status", "")), "returned",
		"the same with ctrl and meta too → returned: command_or_control sets them itself")
	testing.eq(str(with_shift.get("status", "")), "created", "bind Shift+C → created")
	testing.eq(saved_count, 5, "five distinct bindings are saved")
	print("")


static func _test_key_location(testing) -> void:
	testing.begin("input_map key location: matched on 4.3+, ignored with a warning on 4.2")
	var has_location := "location" in InputEventKey.new()
	_seed_action(_ACTION, 0.5, [])
	var left := _event_call("bind", _ACTION, {"type": "key", "keycode": "SHIFT", "location": 1})
	var right := _event_call("bind", _ACTION, {"type": "key", "keycode": "SHIFT", "location": 2})
	var unbind_left := _event_call("unbind", _ACTION, {"type": "key", "keycode": "SHIFT", "location": 1})
	var saved_events := _setting_events(ProjectSettings.get_setting("input/" + _ACTION))
	_clear_actions([_ACTION])

	var left_event: Dictionary = left.get("event", {})
	if has_location:
		testing.eq(str(left.get("status", "")), "created", "bind left Shift → created")
		testing.eq(int(left_event.get("location", -1)), 1, "  read back with location 1")
		testing.ok(not left.has("warnings"), "  and no warnings")
		testing.eq(str(right.get("status", "")), "created", "bind right Shift → created: another location")
		testing.ok(bool(unbind_left.get("success", false)), "unbind left Shift → success")
		testing.eq(saved_events.size(), 1, "one event stays")
		testing.eq(int(saved_events[0].get("location")) if not saved_events.is_empty() else -1, 2,
			"  the right Shift")
	else:
		testing.eq(left.get("warnings", []), ["location needs Godot 4.3+; ignored"], "bind with location → a warning")
		testing.ok(not left_event.has("location"), "  and the event read back has no location")
		testing.eq(str(right.get("status", "")), "returned", "the other location is the same binding on 4.2")
	print("")


static func _test_mouse_pressed_ignored(testing) -> void:
	testing.begin("input_map mouse: pressed is accepted, never stored, and never splits a binding")
	_seed_action(_ACTION, 0.5, [])
	var pressed := _event_call("bind", _ACTION, {"type": "mouse_button", "button_index": 1, "pressed": true})
	var events_after_bind := _setting_events(ProjectSettings.get_setting("input/" + _ACTION))
	var stored: Variant = events_after_bind.back() if not events_after_bind.is_empty() else null
	var released := _event_call("bind", _ACTION, {"type": "mouse_button", "button_index": 1, "pressed": false})
	var unbind := _event_call("unbind", _ACTION, {"type": "mouse_button", "button_index": 1})
	var saved_events := _setting_events(ProjectSettings.get_setting("input/" + _ACTION))
	_clear_actions([_ACTION])

	var pressed_event: Dictionary = pressed.get("event", {})
	testing.eq(str(pressed.get("status", "")), "created", "bind button 1 with pressed → created")
	testing.eq(pressed.get("warnings", []), ["pressed has no effect on action matching; ignored"], "  with a warning")
	testing.ok(not pressed_event.has("pressed"), "  and the event read back has no pressed (%s)" % str(pressed_event))
	testing.ok(stored is InputEventMouseButton and not (stored as InputEventMouseButton).pressed,
		"  and the saved event is not pressed")
	testing.eq(str(released.get("status", "")), "returned", "bind button 1 with pressed false → returned")
	testing.ok(bool(unbind.get("success", false)), "unbind button 1 → success")
	testing.eq(saved_events.size(), 0, "and no mouse event stays")
	print("")


static func _test_mouse_equivalence(testing) -> void:
	testing.begin("input_map mouse equivalence: button, modifiers and device")
	_seed_action(_ACTION, 0.5, [])
	var plain := _event_call("bind", _ACTION, {"type": "mouse_button", "button_index": 2})
	var double_click := _event_call("bind", _ACTION, {"type": "mouse_button", "button_index": 2, "double_click": true})
	var with_shift := _event_call("bind", _ACTION, {"type": "mouse_button", "button_index": 2, "shift": true})
	var command := _event_call("bind", _ACTION, {"type": "mouse_button", "button_index": 2, "command_or_control": true})
	var on_device := _event_call("bind", _ACTION, {"type": "mouse_button", "button_index": 2, "device": 7})
	var saved_count := _setting_events(ProjectSettings.get_setting("input/" + _ACTION)).size()
	_clear_actions([_ACTION])

	var plain_event: Dictionary = plain.get("event", {})
	testing.eq(str(plain.get("status", "")), "created", "bind button 2 → created")
	testing.eq(str(plain_event.get("class", "")), "InputEventMouseButton", "  read back with its class")
	testing.ok(plain_event.has("double_click") and plain_event.has("device") and plain_event.has("command_or_control"),
		"  its double_click, device and command_or_control (%s)" % str(plain_event))
	testing.eq(str(double_click.get("status", "")), "returned", "double_click is not part of the match → returned")
	testing.eq(str(with_shift.get("status", "")), "created", "Shift+button 2 → created")
	testing.eq(str(command.get("status", "")), "created", "Command-or-Control+button 2 → created")
	testing.eq(str(on_device.get("status", "")), "created", "button 2 on device 7 → created")
	testing.eq(saved_count, 4, "four distinct bindings are saved")
	print("")


static func _test_joypad_equivalence(testing) -> void:
	testing.begin("input_map joypad equivalence: motion by axis and direction, button by index and device")
	_seed_action(_ACTION, 0.5, [])
	var half := _event_call("bind", _ACTION, {"type": "joypad_motion", "axis": 0, "axis_value": 0.5})
	var full := _event_call("bind", _ACTION, {"type": "joypad_motion", "axis": 0, "axis_value": 1.0})
	var negative := _event_call("bind", _ACTION, {"type": "joypad_motion", "axis": 0, "axis_value": -1.0})
	var button_zero := _event_call("bind", _ACTION, {"type": "joypad_button", "button_index": 0, "device": 0})
	var button_one := _event_call("bind", _ACTION, {"type": "joypad_button", "button_index": 0, "device": 1})
	var saved_count := _setting_events(ProjectSettings.get_setting("input/" + _ACTION)).size()
	_clear_actions([_ACTION])

	testing.eq(str(half.get("status", "")), "created", "bind axis 0 at 0.5 → created")
	testing.eq(str(full.get("status", "")), "returned", "axis 0 at 1.0, the same direction → returned")
	testing.eq(str(negative.get("status", "")), "created", "axis 0 at -1.0, the other direction → created")
	testing.eq(str(button_zero.get("status", "")), "created", "button 0 on device 0 → created")
	testing.eq(str(button_one.get("status", "")), "created", "button 0 on device 1 → created")
	testing.eq(saved_count, 4, "four distinct bindings are saved")
	print("")


static func _test_device_wildcards(testing) -> void:
	testing.begin("input_map device: an omitted device or -1 matches any device")
	var on_device_two := InputEventJoypadButton.new()
	on_device_two.button_index = JOY_BUTTON_A
	on_device_two.device = 2
	var any_device := InputEventJoypadButton.new()
	any_device.button_index = JOY_BUTTON_B
	any_device.device = -1
	var key_on_five := _key_event(KEY_F7)
	key_on_five.device = 5
	_seed_action(_ACTION, 0.5, [on_device_two, any_device, key_on_five])
	var omitted := _event_call("unbind", _ACTION, {"type": "joypad_button", "button_index": JOY_BUTTON_A})
	var saved_minus_one := _event_call("unbind", _ACTION,
		{"type": "joypad_button", "button_index": JOY_BUTTON_B, "device": 3})
	var other_device := _event_call("unbind", _ACTION, {"type": "key", "keycode": "F7", "device": 6})
	var input_minus_one := _event_call("unbind", _ACTION, {"type": "key", "keycode": "F7", "device": -1})
	var saved_count := _setting_events(ProjectSettings.get_setting("input/" + _ACTION)).size()
	_clear_actions([_ACTION])

	testing.ok(bool(omitted.get("success", false)), "unbind button A with no device matches device 2 (%s)" % str(omitted))
	testing.ok(bool(saved_minus_one.get("success", false)),
		"unbind button B on device 3 matches a saved -1 (%s)" % str(saved_minus_one))
	testing.eq(str(other_device.get("code", "")), "NOT_FOUND", "unbind F7 on device 6 misses F7 on device 5")
	testing.ok(bool(input_minus_one.get("success", false)),
		"unbind F7 on device -1 matches it (%s)" % str(input_minus_one))
	testing.eq(saved_count, 0, "nothing stays")
	print("")


# 4.7 gives keys and mice their own device ids and reads a saved device 0 as them.
static func _test_legacy_device_zero(testing) -> void:
	var has_device_ids := ClassDB.class_has_integer_constant("InputEvent", "DEVICE_ID_KEYBOARD")
	testing.begin("input_map device: a key or mouse device 0 %s the keyboard and mouse devices" % (
		"matches" if has_device_ids else "differs from"))
	var legacy_key := _key_event(KEY_F7)
	legacy_key.device = 0
	var keyboard_key := _key_event(KEY_F8)
	keyboard_key.device = 16
	var legacy_mouse := InputEventMouseButton.new()
	legacy_mouse.button_index = MOUSE_BUTTON_LEFT
	legacy_mouse.device = 0
	_seed_action(_ACTION, 0.5, [legacy_key, keyboard_key, legacy_mouse])
	var unbinds := {
		"a saved device-0 key by device 16": _event_call("unbind", _ACTION, {"type": "key", "keycode": "F7", "device": 16}),
		"a saved device-16 key by device 0": _event_call("unbind", _ACTION, {"type": "key", "keycode": "F8", "device": 0}),
		"a saved device-0 mouse button by device 32": _event_call("unbind", _ACTION,
			{"type": "mouse_button", "button_index": MOUSE_BUTTON_LEFT, "device": 32}),
	}
	_clear_actions([_ACTION])

	for label in unbinds:
		var response: Dictionary = unbinds[label]
		if has_device_ids:
			testing.ok(bool(response.get("success", false)), "unbind %s → success (%s)" % [label, str(response)])
		else:
			testing.eq(str(response.get("code", "")), "NOT_FOUND", "unbind %s → NOT_FOUND before 4.7" % label)
	print("")


static func _test_event_shape_refusals(testing) -> void:
	testing.begin("input_map event shape: an invalid key_kind, location or device is refused")
	var has_location := "location" in InputEventKey.new()
	_seed_action(_ACTION, 0.5, [])
	var bad_kind := _event_call("bind", _ACTION, {"type": "key", "keycode": "F7", "key_kind": "scancode"})
	var bad_location := _event_call("bind", _ACTION, {"type": "key", "keycode": "F7", "location": 3})
	var bad_device := _event_call("bind", _ACTION, {"type": "key", "keycode": "F7", "device": "keyboard"})
	var saved_count := _setting_events(ProjectSettings.get_setting("input/" + _ACTION)).size()
	_clear_actions([_ACTION])

	testing.eq(str(bad_kind.get("code", "")), "INVALID_PARAMS", "key_kind 'scancode' → INVALID_PARAMS")
	testing.ok(str(bad_kind.get("error", "")).contains("key_kind"), "  naming key_kind (%s)" % str(bad_kind.get("error", "")))
	if has_location:
		testing.eq(str(bad_location.get("code", "")), "INVALID_PARAMS", "location 3 → INVALID_PARAMS")
		testing.ok(str(bad_location.get("error", "")).contains("location"),
			"  naming location (%s)" % str(bad_location.get("error", "")))
	testing.eq(str(bad_device.get("code", "")), "INVALID_PARAMS", "a device that is not a number → INVALID_PARAMS")
	# On 4.2 location is ignored, so that bind saves F7.
	testing.eq(saved_count, 0 if has_location else 1, "nothing refused is saved")
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


## Runs the input_map.event handler's [param action] on [param name] with the event object
## [param event].
static func _event_call(action: String, name: String, event: Dictionary) -> Dictionary:
	return UnsavedInputMapCommands.new()._cmd_input_map_event({
		"action": action,
		"name": name,
		"event": event,
	})


## Runs the input_map.list handler with [param parameters]. The handler is looked up by
## name, as the registry looks a command up, so a toolkit without it answers the
## registry's unknown-method error instead of failing to parse this file.
static func _list(parameters: Dictionary) -> Dictionary:
	var commands: Object = UnsavedInputMapCommands.new()
	if not commands.has_method("_cmd_input_map_list"):
		return {"success": false, "code": "NOT_FOUND", "error": "unknown method: input_map.list"}
	var response: Dictionary = commands.call("_cmd_input_map_list", parameters)
	return response


## Returns the entries of an input_map.list [param response]; empty when it has none.
static func _entries(response: Dictionary) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var actions: Variant = response.get("actions", [])
	if typeof(actions) != TYPE_ARRAY:
		return entries
	for entry in actions:
		if typeof(entry) == TYPE_DICTIONARY:
			entries.append(entry)
	return entries


## Returns the names of an input_map.list [param response]'s entries, in order.
static func _entry_names(response: Dictionary) -> Array:
	var names: Array = []
	for entry in _entries(response):
		names.append(str(entry.get("name", "")))
	return names


## Returns the entry named [param name] in an input_map.list [param response], or an
## empty Dictionary when there is none.
static func _entry(response: Dictionary, name: String) -> Dictionary:
	for entry in _entries(response):
		if str(entry.get("name", "")) == name:
			return entry
	return {}


## Returns the event objects of a list entry, or of an entry's default, [param entry].
static func _entry_events(entry: Dictionary) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	var raw_events: Variant = entry.get("events", [])
	if typeof(raw_events) != TYPE_ARRAY:
		return events
	for event in raw_events:
		if typeof(event) == TYPE_DICTIONARY:
			events.append(event)
	return events


## Returns the keycode of each key event object in [param entry], in order.
static func _entry_keycodes(entry: Dictionary) -> Array:
	var keycodes: Array = []
	for event in _entry_events(entry):
		if str(event.get("type", "")) == "key":
			keycodes.append(int(event.get("keycode", -1)))
	return keycodes


## Returns the first event object of [param type] in [param events], or an empty
## Dictionary.
static func _first_event_of_type(events: Array[Dictionary], type: String) -> Dictionary:
	for event in events:
		if str(event.get("type", "")) == type:
			return event
	return {}


## Returns the first key event object in [param events] whose keycode is
## [param keycode], or an empty Dictionary.
static func _find_listed_key(events: Array[Dictionary], keycode: Key) -> Dictionary:
	for event in events:
		if str(event.get("type", "")) == "key" and int(event.get("keycode", -1)) == keycode:
			return event
	return {}


## Returns a new event object for each event in [param events]: equal content, other
## objects, as an editor restart loads a saved line.
static func _rebuilt_events(events: Array) -> Array:
	var rebuilt: Array = []
	for event in events:
		if event is InputEvent:
			rebuilt.append((event as InputEvent).duplicate())
	return rebuilt


## Returns a copy of each input event in [param events] with its device set to
## [param device].
static func _events_on_device(events: Array, device: int) -> Array:
	var moved := _rebuilt_events(events)
	for event in moved:
		(event as InputEvent).device = device
	return moved


## Returns the name of a built-in action the engine registers with a [code].macos[/code]
## feature tag, or an empty String when it registers none.
static func _builtin_feature_action() -> String:
	var settings := _settings()
	for property in ProjectSettings.get_property_list():
		var setting_name := str(property["name"])
		if not setting_name.begins_with("input/") or not setting_name.ends_with(".macos"):
			continue
		var action := setting_name.trim_prefix("input/")
		if settings.is_builtin(action):
			return action
	return ""


## Returns [keycode, physical_keycode, key_label] of the key event at [param index] in
## [param events], or an empty Array when it is not a key event.
static func _saved_key_fields(events: Array, index: int) -> Array:
	if index >= events.size() or not (events[index] is InputEventKey):
		return []
	var key := events[index] as InputEventKey
	return [int(key.keycode), int(key.physical_keycode), int(key.key_label)]


## The input-action settings with a save that keeps project.godot untouched.
class UnsavedInputActionSettings extends InputActionSettings:
	func save() -> Error:
		return OK


## The input_map command handlers on [UnsavedInputActionSettings], so a test can run a
## handler that saves.
class UnsavedInputMapCommands extends InputMapCommands:
	func _create_settings() -> InputActionSettings:
		return UnsavedInputActionSettings.new()
