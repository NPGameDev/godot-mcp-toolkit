@tool
extends RefCounted
## input_map.* handler tests for actions saved in project.godot. The editor's
## InputMap holds only the built-in ui_* actions (main.cpp calls load_default()
## in the editor), so there a project action exists only as its input/<name>
## setting. Each case sets one up that way: the setting, and no InputMap action.
##
## The handlers call ProjectSettings.save(), which would also write whatever else
## this process holds in memory (the engine's own upgrades, settings other tests
## set). So the file's bytes are saved first and written back BEFORE any check
## runs (GDScript has no try/finally): a failure can never leave it dirty.

const InputMapCommands := preload("res://addons/godot_mcp_toolkit/commands/input_map_commands.gd")

const ACTION := "mcp_test_project_action"


static func run(testing) -> void:
	_test_project_action(testing)


static func _test_project_action(testing) -> void:
	testing.begin("input_map.* on an action saved in project.godot")
	var project_file := FileAccess.get_file_as_bytes("res://project.godot")

	_seed_project_action()
	var added := InputMapCommands._cmd_input_map_action({"action": "add", "name": ACTION})
	var events_after_add := _saved_event_count()

	_seed_project_action()
	var bound := InputMapCommands._cmd_input_map_event({
		"action": "bind", "name": ACTION, "event": {"type": "key", "keycode": "F8"}})
	var events_after_bind := _saved_event_count()

	_seed_project_action()
	var removed := InputMapCommands._cmd_input_map_action({"action": "remove", "name": ACTION})
	var setting_after_remove := ProjectSettings.has_setting("input/" + ACTION)

	_clear_project_action()
	var restore := FileAccess.open("res://project.godot", FileAccess.WRITE)
	restore.store_buffer(project_file)
	restore.close()

	testing.eq(added.get("status"), "returned", "add on a saved action → status returned")
	testing.eq(events_after_add, 1, "add keeps the saved event")
	testing.ok(bound.get("success", false), "bind on a saved action → success")
	testing.eq(events_after_bind, 2, "bind appends to the saved event")
	testing.ok(removed.get("success", false), "remove on a saved action → success")
	testing.ok(not setting_after_remove, "remove clears the saved setting")
	print("")


## The editor's view of a project action: its setting, with one F7 event, and
## no InputMap action.
static func _seed_project_action() -> void:
	if InputMap.has_action(ACTION):
		InputMap.erase_action(ACTION)
	var event := InputEventKey.new()
	event.physical_keycode = KEY_F7
	ProjectSettings.set_setting("input/" + ACTION, {"deadzone": 0.5, "events": [event]})


static func _saved_event_count() -> int:
	var setting = ProjectSettings.get_setting("input/" + ACTION)
	if typeof(setting) != TYPE_DICTIONARY:
		return -1
	return (setting.get("events", []) as Array).size()


static func _clear_project_action() -> void:
	if InputMap.has_action(ACTION):
		InputMap.erase_action(ACTION)
	if ProjectSettings.has_setting("input/" + ACTION):
		ProjectSettings.clear("input/" + ACTION)
