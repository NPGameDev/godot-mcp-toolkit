@tool
extends RefCounted
## Input-map unit tests: how the input_map.* handlers see project actions and
## built-in actions. The editor loads only the built-in actions into its InputMap,
## so there a project action exists only as its input/<name> setting; each
## project-action case sets up that state (the setting, and no InputMap action) and
## calls the loader the handlers share. Settings change in memory only and are
## restored; nothing calls ProjectSettings.save(). The handlers' add, bind and
## remove paths save project.godot, so the sweep covers them (Validations step
## 10.1b), and no case here calls remove on a built-in action. The rename cases run
## the real input_map.action handler on [UnsavedInputMapCommands], whose save does
## not write the file.

const InputMapCommands := preload("res://addons/godot_mcp_toolkit/commands/input_map_commands.gd")

const _ACTION := "mcp_test_project_action"
## A project action whose name looks like a built-in one.
const _UI_PREFIXED_ACTION := "ui_inventory"
const _BUILTIN_ACTION := "ui_accept"
## The name a rename case moves [constant _ACTION] to.
const _RENAMED_ACTION := "mcp_test_renamed_action"
## A second project action, saved after [constant _ACTION].
const _OTHER_ACTION := "mcp_test_other_action"


static func run(testing) -> void:
	_test_load_project_action(testing)
	_test_load_without_setting(testing)
	_test_load_leaves_builtin_alone(testing)
	_test_load_follows_setting_edit(testing)
	_test_load_drops_deleted_action(testing)
	_test_builtin_rule_matches_engine(testing)
	_test_ui_prefixed_project_action(testing)
	_test_rename_moves_setting(testing)
	_test_rename_keeps_order(testing)
	_test_rename_moves_loaded_action(testing)
	_test_rename_refusals(testing)


# --- The loader --------------------------------------------------------------

static func _test_load_project_action(testing) -> void:
	testing.begin("input_map loader: a project action loads from its setting")
	_seed_project_action(0.3, [_key_event(KEY_F7)])
	InputMapCommands._load_project_action(_ACTION)
	var loaded := InputMap.has_action(_ACTION)
	var keycodes := _loaded_keycodes()
	var deadzone := InputMap.action_get_deadzone(_ACTION) if loaded else -1.0
	_clear_project_action()

	testing.ok(loaded, "the action is in InputMap")
	testing.eq(keycodes, [KEY_F7], "with its one saved event")
	testing.ok(absf(deadzone - 0.3) < 0.001, "and its saved deadzone 0.3 (got %f)" % deadzone)
	print("")


static func _test_load_without_setting(testing) -> void:
	testing.begin("input_map loader: no setting, no action")
	_clear_project_action()
	InputMapCommands._load_project_action(_ACTION)
	var created := InputMap.has_action(_ACTION)
	_clear_project_action()

	testing.ok(not created, "an action with no input/<name> setting stays out of InputMap")
	print("")


# A rebuild from input/ui_accept would reset this deadzone to the setting's 0.5. The
# marker lives in this process's InputMap only and is restored before the checks.
static func _test_load_leaves_builtin_alone(testing) -> void:
	testing.begin("input_map loader: a built-in action is left alone")
	var original_deadzone := InputMap.action_get_deadzone(_BUILTIN_ACTION)
	InputMap.action_set_deadzone(_BUILTIN_ACTION, 0.123)
	InputMapCommands._load_project_action(_BUILTIN_ACTION)
	var deadzone_after := InputMap.action_get_deadzone(_BUILTIN_ACTION)
	InputMap.action_set_deadzone(_BUILTIN_ACTION, original_deadzone)

	testing.ok(absf(deadzone_after - 0.123) < 0.001,
		"ui_accept keeps its InputMap state (deadzone %f)" % deadzone_after)
	print("")


# An edit in Project Settings changes only the setting. If the loader kept the
# InputMap action it loaded earlier, the next bind would save that stale copy over
# the edit.
static func _test_load_follows_setting_edit(testing) -> void:
	testing.begin("input_map loader: a later edit to the setting reaches InputMap")
	_seed_project_action(0.3, [_key_event(KEY_F7)])
	InputMapCommands._load_project_action(_ACTION)
	ProjectSettings.set_setting("input/" + _ACTION, {
		"deadzone": 0.7,
		"events": [_key_event(KEY_F8), _key_event(KEY_F9)],
	})
	InputMapCommands._load_project_action(_ACTION)
	var keycodes := _loaded_keycodes()
	var deadzone := InputMap.action_get_deadzone(_ACTION) if InputMap.has_action(_ACTION) else -1.0
	_clear_project_action()

	testing.eq(keycodes, [KEY_F8, KEY_F9], "the action holds the edited events")
	testing.ok(absf(deadzone - 0.7) < 0.001, "and the edited deadzone 0.7 (got %f)" % deadzone)
	print("")


# Project Settings deletes an action with ProjectSettings.clear() and renames one
# with clear() plus a new setting, neither of which touches InputMap. If the loader
# kept the InputMap action it loaded earlier, the next bind would save the deleted
# action back.
static func _test_load_drops_deleted_action(testing) -> void:
	testing.begin("input_map loader: an action whose setting is gone leaves InputMap")
	_seed_project_action(0.3, [_key_event(KEY_F7)])
	InputMapCommands._load_project_action(_ACTION)
	ProjectSettings.clear("input/" + _ACTION)
	InputMapCommands._load_project_action(_ACTION)
	var still_loaded := InputMap.has_action(_ACTION)
	_clear_project_action()

	testing.ok(not still_loaded, "the deleted action is no longer in InputMap")
	print("")


# --- The built-in rule -------------------------------------------------------
# The oracle: the engine keeps an initial value (the revert value) only for the
# settings it registers itself, so property_get_revert returns a Dictionary for a
# built-in action and null for a project action. The rule reads the registration
# order instead, so the two are independent.

static func _test_builtin_rule_matches_engine(testing) -> void:
	testing.begin("input_map built-in rule: agrees with the engine on every input/ setting")
	# Seeded so the scan meets project actions as well as the engine's own.
	_seed_project_action(0.5, [])
	ProjectSettings.set_setting("input/" + _UI_PREFIXED_ACTION, {"deadzone": 0.5, "events": []})
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
		if InputMapCommands._is_builtin_action(action) != engine_builtin:
			disagreements.append(action)
	_clear_project_action()
	ProjectSettings.clear("input/" + _UI_PREFIXED_ACTION)

	testing.ok(builtin_count > 0, "the scan found built-in actions (%d)" % builtin_count)
	testing.ok(project_count >= 2, "the scan found the seeded project actions (%d)" % project_count)
	testing.ok(disagreements.is_empty(), "the rule and the engine agree (differ on: %s)" % str(disagreements))
	print("")


static func _test_ui_prefixed_project_action(testing) -> void:
	testing.begin("input_map built-in rule: a project action named ui_* is not built-in")
	var setting_name := "input/" + _UI_PREFIXED_ACTION
	ProjectSettings.set_setting(setting_name, {"deadzone": 0.5, "events": []})
	var rule_builtin := InputMapCommands._is_builtin_action(_UI_PREFIXED_ACTION)
	var engine_revert: Variant = ProjectSettings.property_get_revert(setting_name)
	ProjectSettings.clear(setting_name)

	testing.ok(not rule_builtin, "ui_inventory is a project action")
	testing.eq(typeof(engine_revert), TYPE_NIL, "the engine keeps no initial value for it")
	print("")


# --- Rename ------------------------------------------------------------------
# The editor's own rename moves the input/<name> setting and leaves InputMap alone,
# so each case starts from that state: the setting, and no InputMap action.

static func _test_rename_moves_setting(testing) -> void:
	testing.begin("input_map rename: the saved action moves to the new name")
	_seed_action(_ACTION, 0.3, [_key_event(KEY_F7)])
	var old_value: Variant = ProjectSettings.get_setting("input/" + _ACTION)
	var response := _rename(_ACTION, _RENAMED_ACTION)
	var new_value: Variant = ProjectSettings.get_setting("input/" + _RENAMED_ACTION, null)
	var old_left := ProjectSettings.has_setting("input/" + _ACTION)
	var loaded_new := InputMap.has_action(_RENAMED_ACTION)
	_clear_actions([_ACTION, _RENAMED_ACTION])

	testing.ok(bool(response.get("success", false)), "rename answers success (%s)" % str(response))
	testing.eq(str(response.get("name", "")), _RENAMED_ACTION, "answers the new name")
	testing.eq(str(response.get("old_name", "")), _ACTION, "answers the old name")
	testing.ok(new_value == old_value, "input/<new_name> holds the old setting")
	testing.eq(_setting_keycodes(new_value), [KEY_F7], "the moved event keeps its physical keycode F7")
	testing.ok(absf(_setting_deadzone(new_value) - 0.3) < 0.001,
		"the moved deadzone stays 0.3 (got %f)" % _setting_deadzone(new_value))
	testing.ok(not old_left, "input/<name> is gone")
	testing.ok(not loaded_new, "InputMap gets no action when it held none")
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


static func _test_rename_moves_loaded_action(testing) -> void:
	testing.begin("input_map rename: an action InputMap holds moves there too")
	_seed_action(_ACTION, 0.3, [_key_event(KEY_F7)])
	InputMapCommands._load_project_action(_ACTION)
	var response := _rename(_ACTION, _RENAMED_ACTION)
	var keycodes := _loaded_keycodes(_RENAMED_ACTION)
	var deadzone := InputMap.action_get_deadzone(_RENAMED_ACTION) if InputMap.has_action(_RENAMED_ACTION) else -1.0
	var old_loaded := InputMap.has_action(_ACTION)
	_clear_actions([_ACTION, _RENAMED_ACTION])

	testing.ok(bool(response.get("success", false)), "rename answers success (%s)" % str(response))
	testing.eq(keycodes, [KEY_F7], "InputMap holds the event under the new name")
	testing.ok(absf(deadzone - 0.3) < 0.001, "and the deadzone 0.3 (got %f)" % deadzone)
	testing.ok(not old_loaded, "and no longer holds the old name")
	print("")


static func _test_rename_refusals(testing) -> void:
	testing.begin("input_map rename: refusals")
	var builtin_value: Variant = ProjectSettings.get_setting("input/" + _BUILTIN_ACTION)
	var builtin_order := ProjectSettings.get_order("input/" + _BUILTIN_ACTION)
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
	_restore_builtin_action(builtin_value, builtin_order)

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

## Sets up the editor's view of a project action: its setting holds [param deadzone]
## and [param events], and InputMap does not hold it.
static func _seed_project_action(deadzone: float, events: Array) -> void:
	_seed_action(_ACTION, deadzone, events)


static func _clear_project_action() -> void:
	_clear_actions([_ACTION])


## Sets up the editor's view of the project action [param action]: its setting holds
## [param deadzone] and [param events], and InputMap does not hold it.
static func _seed_action(action: String, deadzone: float, events: Array) -> void:
	if InputMap.has_action(action):
		InputMap.erase_action(action)
	ProjectSettings.set_setting("input/" + action, {"deadzone": deadzone, "events": events})


static func _clear_actions(actions: Array[String]) -> void:
	for action in actions:
		if InputMap.has_action(action):
			InputMap.erase_action(action)
		if ProjectSettings.has_setting("input/" + action):
			ProjectSettings.clear("input/" + action)


static func _key_event(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	return event


## Returns the physical keycodes of [param action]'s InputMap events, in order;
## empty when InputMap does not hold the action.
static func _loaded_keycodes(action: String = _ACTION) -> Array:
	var keycodes: Array = []
	if not InputMap.has_action(action):
		return keycodes
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			keycodes.append((event as InputEventKey).physical_keycode)
	return keycodes


## Returns the physical keycodes of the key events in an input/<name> setting
## [param setting], in order; empty when it is not an action's Dictionary.
static func _setting_keycodes(setting: Variant) -> Array:
	var keycodes: Array = []
	if typeof(setting) != TYPE_DICTIONARY:
		return keycodes
	var events: Variant = setting.get("events", [])
	if typeof(events) != TYPE_ARRAY:
		return keycodes
	for event in events:
		if event is InputEventKey:
			keycodes.append((event as InputEventKey).physical_keycode)
	return keycodes


## Returns the deadzone in an input/<name> setting [param setting], or -1.0 when it is
## not an action's Dictionary.
static func _setting_deadzone(setting: Variant) -> float:
	if typeof(setting) != TYPE_DICTIONARY:
		return -1.0
	return float(setting.get("deadzone", -1.0))


## Puts [constant _BUILTIN_ACTION] back as it was before a rename case: its setting holds
## [param value] at [param order], and InputMap holds the action. A rename that let the
## built-in through would have moved or cleared both.
static func _restore_builtin_action(value: Variant, order: int) -> void:
	var setting_name := "input/" + _BUILTIN_ACTION
	ProjectSettings.set_setting(setting_name, value)
	ProjectSettings.set_order(setting_name, order)
	if InputMap.has_action(_BUILTIN_ACTION) or typeof(value) != TYPE_DICTIONARY:
		return
	InputMap.add_action(_BUILTIN_ACTION, float(value.get("deadzone", 0.5)))
	var events: Variant = value.get("events", [])
	if typeof(events) != TYPE_ARRAY:
		return
	for event in events:
		if event is InputEvent:
			InputMap.action_add_event(_BUILTIN_ACTION, event)


## Runs the input_map.action handler's rename on [UnsavedInputMapCommands]; a null
## [param new_name] leaves the parameter out.
static func _rename(action: String, new_name: Variant) -> Dictionary:
	var parameters := {"action": "rename", "name": action}
	if new_name != null:
		parameters["new_name"] = new_name
	return UnsavedInputMapCommands.new()._cmd_input_map_action(parameters)


## The input_map command handlers with a save that keeps project.godot untouched, so a
## test can run a handler that saves.
class UnsavedInputMapCommands extends InputMapCommands:
	func _save_project_settings() -> Error:
		return OK
