@tool
extends EditorPlugin
## Test-only editor plugin for scripts/test_framework/update_gui.sh, copied into its
## scratch projects. In an editor with a window it plays one step of a scenario: it
## presses the update badge's buttons and the dialogs' buttons the way a click does,
## and writes what it saw as "<scenario> <key>=<value>" lines to UPDATE_GUI_RESULTS,
## with screenshots in UPDATE_GUI_SHOTS. UPDATE_GUI_SCENARIO and UPDATE_GUI_STEP name
## the step; a Restart now leaves a marker so the editor it starts plays the step
## after it. Without UPDATE_GUI_SCENARIO it does nothing.

const _RESTART_MARKER := "user://update_gui_restarted"
const _TOOLKIT_CONFIG := "res://addons/godot_mcp_toolkit/plugin.cfg"
const _START_WINDOW_TEXT := "is available. Install it now?"
# Godot 4.5 and later ask before quitting with an unsaved script; earlier ones don't.
const _UNSAVED_SCRIPT_TEXT := "Save changes to the following script(s)"
const _MCP_JSON_CONFIRM_TEXT := "in .mcp.json?"
const _WAIT_SEC := 120.0

var _scenario: String = ""
var _results_path: String = ""
var _shots_folder: String = ""


func _enter_tree() -> void:
	_scenario = OS.get_environment("UPDATE_GUI_SCENARIO")
	_results_path = OS.get_environment("UPDATE_GUI_RESULTS")
	_shots_folder = OS.get_environment("UPDATE_GUI_SHOTS")
	if not _scenario.is_empty():
		_play.call_deferred()


func _play() -> void:
	# Lets the editor finish its first layout and the toolkit build its dock.
	await _frames(120)
	var step := OS.get_environment("UPDATE_GUI_STEP")
	if FileAccess.file_exists(_RESTART_MARKER):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_RESTART_MARKER))
		step = "after_restart"
	_record("step", step)
	_record("toolkit_version", _toolkit_version())
	match "%s/%s" % [_scenario, step]:
		"restart/a", "server/a", "server_hand/a":
			await _install_then_restart()
		"restart/after_restart", "automatic/b", "unsaved/after_restart", "server_hand/after_restart":
			await _read_updated_notice()
		"server/after_restart":
			await _read_updated_notice()
			await _update_mcp_json()
		"later/a":
			_record("available", await _wait_for(_shown.bind("UpdateButton")))
		"later/b":
			await _answer_start_window("Later")
		"later/c":
			await _answer_start_window("Skip this version")
		"later/d":
			# The window would have opened by now; it must not.
			await _frames(600)
			_record("window_shown", _dialog_with(_START_WINDOW_TEXT) != null)
			_record("badge_visible", _badge_visible())
		"unsaved/a":
			await _restart_with_unsaved_script()
		"automatic/a":
			await _wait_for_quit_shortcut()
		"major/a":
			await _read_major_badge()
		_:
			_record("error", "unknown step")
	await _shot("%s_%s" % [_scenario, step])
	get_tree().quit()


func _install_then_restart() -> void:
	_record("available", await _wait_for(_shown.bind("UpdateButton")))
	_press(_badge_button("UpdateButton"))
	_record("ready", await _wait_for(_shown.bind("RestartButton")))
	_record("ready_status", _badge_text("Status"))
	await _shot("%s_ready" % _scenario)
	_write_restart_marker()
	_press(_badge_button("RestartButton"))
	# The restart frees this plugin; reaching the end of the wait means it never came.
	await _wait_for(func() -> bool: return false, 60.0)
	_record("restart_timeout", true)


func _read_updated_notice() -> void:
	_record("notice_shown", await _wait_for(_notice_says_updated))
	_record("title", _badge_text("Title"))
	_record("whats_new_visible", _shown("GitHubButton"))
	_record("status", _badge_text("Status") if _shown("Status") else "")
	_record("update_mcp_json_visible", _shown("UpdateMcpJsonButton"))


func _update_mcp_json() -> void:
	_press(_badge_button("UpdateMcpJsonButton"))
	await _wait_for(_dialog_open.bind(_MCP_JSON_CONFIRM_TEXT), 30.0)
	var confirm := _dialog_with(_MCP_JSON_CONFIRM_TEXT)
	_record("confirm_shown", confirm != null)
	if confirm == null:
		return
	await _shot("server_confirm")
	_press(confirm.get_ok_button())
	await _frames(60)
	_record("update_mcp_json_visible_after", _shown("UpdateMcpJsonButton"))
	_record("mcp_json", FileAccess.get_file_as_string("res://.mcp.json").replace("\n", " ").replace("\t", ""))


func _answer_start_window(button_text: String) -> void:
	await _wait_for(_dialog_open.bind(_START_WINDOW_TEXT))
	var window := _dialog_with(_START_WINDOW_TEXT)
	_record("window_shown", window != null)
	if window == null:
		return
	await _shot("%s_window" % _scenario)
	var pressed := false
	for button: Button in window.find_children("*", "Button", true, false):
		if button.visible and button.text == button_text:
			_press(button)
			pressed = true
			break
	_record("pressed", pressed)
	await _frames(60)
	_record("window_after", _dialog_with(_START_WINDOW_TEXT) != null)
	_record("badge_visible", _badge_visible())
	_record("update_visible", _shown("UpdateButton"))


func _restart_with_unsaved_script() -> void:
	_record("available", await _wait_for(_shown.bind("UpdateButton")))
	_press(_badge_button("UpdateButton"))
	_record("ready", await _wait_for(_shown.bind("RestartButton")))
	EditorInterface.edit_script(load("res://probe_script.gd"))
	await _frames(30)
	var script_editor := EditorInterface.get_script_editor().get_current_editor()
	var code := script_editor.get_base_editor() as CodeEdit if script_editor != null else null
	if code != null:
		code.set_caret_line(code.get_line_count() - 1)
		code.insert_text_at_caret("\n# an unsaved edit\n")
	await _frames(30)
	_record("script_edited", code != null)
	_press(_badge_button("RestartButton"))
	await _wait_for(_dialog_open.bind(_UNSAVED_SCRIPT_TEXT), 30.0)
	var ask := _dialog_with(_UNSAVED_SCRIPT_TEXT)
	_record("save_dialog_shown", ask != null)
	if ask == null:
		return
	await _shot("unsaved_save_dialog")
	_press(ask.get_cancel_button())
	await _frames(120)
	_record("after_cancel_toolkit_version", _toolkit_version())
	_record("after_cancel_restart_visible", _shown("RestartButton"))
	_write_restart_marker()
	_press(_badge_button("RestartButton"))
	await _wait_for(_dialog_open.bind(_UNSAVED_SCRIPT_TEXT), 30.0)
	ask = _dialog_with(_UNSAVED_SCRIPT_TEXT)
	_record("save_dialog_again", ask != null)
	if ask != null:
		_press(ask.get_ok_button())
	await _wait_for(func() -> bool: return false, 60.0)
	_record("restart_timeout", true)


# The harness sends the editor's quit shortcut once this line is printed.
func _wait_for_quit_shortcut() -> void:
	_record("ready", await _wait_for(_shown.bind("RestartButton"), 180.0))
	_record("status", _badge_text("Status"))
	await _shot("automatic_ready")
	print("[UPDATE-GUI] waiting for the quit shortcut")
	await _wait_for(func() -> bool: return false, 120.0)
	_record("quit_timeout", true)


func _read_major_badge() -> void:
	_record("badge_visible", await _wait_for(_badge_visible))
	_record("title", _badge_text("Title"))
	_record("update_visible", _shown("UpdateButton"))
	_record("major_icon_visible", _shown("MajorIcon"))


func _badge() -> Control:
	return EditorInterface.get_base_control().find_child("UpdateBadge", true, false) as Control


func _badge_visible() -> bool:
	var badge := _badge()
	return badge != null and badge.visible


func _badge_button(child_name: String) -> Button:
	var badge := _badge()
	return badge.find_child(child_name, true, false) as Button if badge != null else null


# Checks the node's own flag: the bottom panel that holds the dock on Godot 4.5 and
# earlier stays collapsed on a virtual display.
func _shown(child_name: String) -> bool:
	var badge := _badge()
	var child := badge.find_child(child_name, true, false) as CanvasItem if badge != null else null
	return child != null and child.visible


func _badge_text(child_name: String) -> String:
	var badge := _badge()
	var child := badge.find_child(child_name, true, false) if badge != null else null
	if child is Label:
		return (child as Label).text
	if child is Button:
		return (child as Button).text
	return ""


func _notice_says_updated() -> bool:
	return _badge_text("Title").contains("was updated to")


func _dialog_open(text_fragment: String) -> bool:
	return _dialog_with(text_fragment) != null


func _dialog_with(text_fragment: String) -> AcceptDialog:
	for node: Node in get_tree().root.find_children("*", "AcceptDialog", true, false):
		var dialog := node as AcceptDialog
		if dialog.visible and dialog.dialog_text.contains(text_fragment):
			return dialog
	return null


# Deferred, as a click is: from Godot 4.3 a synchronous Restart now frees the editor's
# plugins while this function is still on the stack.
func _press(button: Button) -> void:
	if button != null:
		button.call_deferred("emit_signal", "pressed")


func _write_restart_marker() -> void:
	var file := FileAccess.open(_RESTART_MARKER, FileAccess.WRITE)
	file.store_string("1")
	file.close()


func _toolkit_version() -> String:
	var config := ConfigFile.new()
	config.load(_TOOLKIT_CONFIG)
	return str(config.get_value("plugin", "version", ""))


func _reveal_dock() -> void:
	var badge := _badge()
	if badge == null:
		return
	var dock := badge.get_parent() as Control
	if ClassDB.class_exists("EditorDock"):
		var host := dock.get_parent()
		if host != null and host.has_method("make_visible"):
			host.call("make_visible")
	else:
		make_bottom_panel_item_visible(dock)


func _shot(shot_name: String) -> void:
	if _shots_folder.is_empty():
		return
	_reveal_dock()
	await _frames(20)
	get_tree().root.get_texture().get_image().save_png(_shots_folder.path_join(shot_name + ".png"))


func _wait_for(condition: Callable, seconds: float = _WAIT_SEC) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await get_tree().process_frame
	return false


func _frames(count: int) -> void:
	for index in count:
		await get_tree().process_frame


func _record(key: String, value: Variant) -> void:
	var line := "%s %s=%s" % [_scenario, key, str(value)]
	print("[UPDATE-GUI] " + line)
	if _results_path.is_empty():
		return
	var file := FileAccess.open(_results_path, FileAccess.READ_WRITE if FileAccess.file_exists(_results_path) else FileAccess.WRITE)
	file.seek_end()
	file.store_line(line)
	file.close()
