@tool
extends RefCounted
## Input-map unit tests: how the input_map.* handlers see project actions and
## built-in actions. The editor loads only the built-in actions into its InputMap,
## so there a project action exists only as its input/<name> setting; each
## project-action case sets up that state (the setting, and no InputMap action) and
## calls the loader the handlers share. Settings change in memory only and are
## restored; nothing calls ProjectSettings.save(). The handlers' add, bind and
## remove paths save project.godot, so the sweep covers them (Validations step
## 10.1b), and no case here calls remove on a built-in action.

const InputMapCommands := preload("res://addons/godot_mcp_toolkit/commands/input_map_commands.gd")

const _ACTION := "mcp_test_project_action"
## A project action whose name looks like a built-in one.
const _UI_PREFIXED_ACTION := "ui_inventory"
const _BUILTIN_ACTION := "ui_accept"


static func run(testing) -> void:
	_test_load_project_action(testing)
	_test_load_without_setting(testing)
	_test_load_leaves_builtin_alone(testing)
	_test_load_follows_setting_edit(testing)
	_test_load_drops_deleted_action(testing)
	_test_builtin_rule_matches_engine(testing)
	_test_ui_prefixed_project_action(testing)


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


# --- Helpers -----------------------------------------------------------------

## Sets up the editor's view of a project action: its setting holds [param deadzone]
## and [param events], and InputMap does not hold it.
static func _seed_project_action(deadzone: float, events: Array) -> void:
	if InputMap.has_action(_ACTION):
		InputMap.erase_action(_ACTION)
	ProjectSettings.set_setting("input/" + _ACTION, {"deadzone": deadzone, "events": events})


static func _clear_project_action() -> void:
	if InputMap.has_action(_ACTION):
		InputMap.erase_action(_ACTION)
	if ProjectSettings.has_setting("input/" + _ACTION):
		ProjectSettings.clear("input/" + _ACTION)


static func _key_event(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	return event


## Returns the physical keycodes of the test action's InputMap events, in order;
## empty when InputMap does not hold the action.
static func _loaded_keycodes() -> Array:
	var keycodes: Array = []
	if not InputMap.has_action(_ACTION):
		return keycodes
	for event in InputMap.action_get_events(_ACTION):
		if event is InputEventKey:
			keycodes.append((event as InputEventKey).physical_keycode)
	return keycodes
