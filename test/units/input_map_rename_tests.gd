@tool
extends RefCounted
## input_map.action rename tests. In the editor a project action usually exists
## only as its input/<name> setting (main.cpp loads only the default ui_* actions
## into the editor's InputMap), so rename works from the setting; when InputMap
## does hold the action, its events move too. Both cases are set up here.
##
## The handler calls ProjectSettings.save(), which would also write whatever else
## this process holds in memory (the engine's own upgrades, settings other tests
## set). So the file's bytes are saved first and written back BEFORE any check
## runs (GDScript has no try/finally): a failure can never leave it dirty.

const InputMapCommands := preload("res://addons/godot_mcp_toolkit/commands/input_map_commands.gd")

const OLD_NAME := "mcp_test_rename_old"
const NEW_NAME := "mcp_test_rename_new"
const TAKEN_NAME := "mcp_test_rename_taken"


static func run(testing) -> void:
	_test_rename(testing)


static func _test_rename(testing) -> void:
	testing.begin("input_map.action rename")
	var project_file := FileAccess.get_file_as_bytes("res://project.godot")

	# Editor view: the setting only, no InputMap action.
	_seed(OLD_NAME, false)
	var renamed := _rename(OLD_NAME, NEW_NAME)
	var new_setting = ProjectSettings.get_setting("input/" + NEW_NAME)
	var old_setting_left := ProjectSettings.has_setting("input/" + OLD_NAME)
	var input_map_untouched := not InputMap.has_action(NEW_NAME)
	_clear([OLD_NAME, NEW_NAME])

	# InputMap holds the action too: its events move with it.
	_seed(OLD_NAME, true)
	var renamed_live := _rename(OLD_NAME, NEW_NAME)
	var live_events := InputMap.action_get_events(NEW_NAME).size() if InputMap.has_action(NEW_NAME) else -1
	var live_old_left := InputMap.has_action(OLD_NAME)
	_clear([OLD_NAME, NEW_NAME])

	# Guards.
	_seed(OLD_NAME, false)
	_seed(TAKEN_NAME, false)
	var onto_taken := _rename(OLD_NAME, TAKEN_NAME)
	var kept_after_refusal := ProjectSettings.has_setting("input/" + OLD_NAME)
	var missing := _rename("mcp_test_rename_missing", NEW_NAME)
	var empty_new_name := _rename(OLD_NAME, "")
	var builtin := _rename("ui_accept", NEW_NAME)
	_clear([OLD_NAME, NEW_NAME, TAKEN_NAME])

	var restore := FileAccess.open("res://project.godot", FileAccess.WRITE)
	restore.store_buffer(project_file)
	restore.close()

	testing.ok(renamed.get("success", false), "rename a saved action → success")
	testing.eq(renamed.get("name"), NEW_NAME, "answers the new name")
	testing.eq(renamed.get("old_name"), OLD_NAME, "answers the old name")
	testing.eq(_event_count(new_setting), 1, "new setting keeps the event")
	testing.eq(_deadzone(new_setting), 0.3, "new setting keeps the deadzone")
	testing.ok(not old_setting_left, "old setting cleared")
	testing.ok(input_map_untouched, "no InputMap action added when there was none")
	testing.ok(renamed_live.get("success", false), "rename an InputMap action → success")
	testing.eq(live_events, 1, "InputMap events moved to the new name")
	testing.ok(not live_old_left, "old InputMap action erased")
	testing.eq(onto_taken.get("code"), "ALREADY_EXISTS", "rename onto an existing action → ALREADY_EXISTS")
	testing.ok(kept_after_refusal, "refused rename leaves the old setting")
	testing.eq(missing.get("code"), "NOT_FOUND", "rename a missing action → NOT_FOUND")
	testing.eq(empty_new_name.get("code"), "INVALID_PARAMS", "empty new_name → INVALID_PARAMS")
	testing.eq(builtin.get("code"), "INVALID_PARAMS", "built-in ui_* action → INVALID_PARAMS")
	print("")


static func _rename(action_name: String, new_name: String) -> Dictionary:
	return InputMapCommands._cmd_input_map_action(
		{"action": "rename", "name": action_name, "new_name": new_name})


## A saved action with one F7 event and deadzone 0.3; [param in_input_map] also
## adds it to InputMap.
static func _seed(action_name: String, in_input_map: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_F7
	ProjectSettings.set_setting("input/" + action_name, {"deadzone": 0.3, "events": [event]})
	if in_input_map:
		InputMap.add_action(action_name, 0.3)
		InputMap.action_add_event(action_name, event)


static func _clear(action_names: Array) -> void:
	for action_name in action_names:
		if InputMap.has_action(action_name):
			InputMap.erase_action(action_name)
		if ProjectSettings.has_setting("input/" + action_name):
			ProjectSettings.clear("input/" + action_name)


static func _event_count(setting: Variant) -> int:
	if typeof(setting) != TYPE_DICTIONARY:
		return -1
	return (setting.get("events", []) as Array).size()


static func _deadzone(setting: Variant) -> float:
	if typeof(setting) != TYPE_DICTIONARY:
		return -1.0
	return snappedf(float(setting.get("deadzone", -1.0)), 0.001)
