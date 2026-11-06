@tool
extends EditorPlugin
## Test-only editor plugin for scripts/test_framework/update_gui.sh, copied into its
## scratch projects. In an editor with a window it plays one step of a scenario: it
## presses the update badge's buttons and the dialogs' buttons the way a click does,
## and writes what it saw as "<scenario> <key>=<value>" lines to UPDATE_GUI_RESULTS,
## with screenshots in UPDATE_GUI_SHOTS. UPDATE_GUI_SCENARIO and UPDATE_GUI_STEP name
## the step; before an update can restart the editor it leaves a marker, so the editor
## the restart starts plays the step after it. Without UPDATE_GUI_SCENARIO it does nothing.

const _RESTART_MARKER := "user://update_gui_restarted"
const _TOOLKIT_CONFIG := "res://addons/godot_mcp_toolkit/plugin.cfg"
const _PROBE_SCRIPT := "res://probe_script.gd"
const _PROBE_EDIT := "# an unsaved edit"
const _START_WINDOW_TEXT := "is available. Install it now?"
const _MCP_JSON_CONFIRM_TEXT := "in .mcp.json?"
# The ready view's lines for the probe script's edit and for one scene never saved.
const _VIEW_SCRIPT_TEXT := "probe_script.gd has unsaved edits"
const _VIEW_SCENE_TEXT := "1 open scene has never been saved."
# The editor speaks English in these projects, so the plugin finds the engine's own
# buttons by their text.
const _SAVE_SCRIPT_ITEM := "Save"
const _NEW_2D_SCENE_TEXT := "2D Scene"
const _WAIT_SEC := 120.0
# How long a restart that should not come is given to show itself.
const _NO_RESTART_FRAMES := 300

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
		"restart/after_restart", "quit/b", "unsaved/after_restart", "server_hand/after_restart":
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
		"untitled/a":
			await _stage_with_untitled_scene()
		"quit/a":
			await _stage_then_wait_for_quit()
		"major/a":
			await _read_major_badge()
		_:
			_record("error", "unknown step")
	await _shot("%s_%s" % [_scenario, step])
	get_tree().quit()


# On Godot 4.4 and later, with nothing a restart would lose, the editor restarts on its
# own once staging ends; earlier ones open the ready view, whose Restart this presses.
func _install_then_restart() -> void:
	_record("available", await _wait_for(_shown.bind("UpdateButton")))
	_write_restart_marker()
	_press(_badge_button("UpdateButton"))
	# A restart frees this plugin during the wait; reaching its end means none came.
	var view_opened: bool = await _wait_for(_shown.bind("NotNowButton"))
	_record("ready_view", view_opened)
	if not view_opened:
		_record("restart_timeout", true)
		return
	_record("restart_text", _badge_text("RestartButton"))
	await _shot("%s_ready_view" % _scenario)
	_press(_badge_button("RestartButton"))
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


# The script is edited before the stage ends, so the ready view opens in place of a
# restart. Restart refuses while the edit is unsaved; Not now collapses the view;
# once the script is saved, Restart installs the update.
func _restart_with_unsaved_script() -> void:
	_record("available", await _wait_for(_shown.bind("UpdateButton")))
	_record("script_edited", await _edit_probe_script())
	_press(_badge_button("UpdateButton"))
	_record("ready_view", await _wait_for(_shown.bind("NotNowButton")))
	_record("view_names_script", _badge_text("Status").contains(_VIEW_SCRIPT_TEXT))
	_record("restart_text", _badge_text("RestartButton"))
	await _shot("unsaved_ready_view")
	_press(_badge_button("RestartButton"))
	await _frames(120)
	_record("after_refuse_toolkit_version", _toolkit_version())
	_record("after_refuse_view", _shown("NotNowButton"))
	_press(_badge_button("NotNowButton"))
	await _frames(30)
	_record("after_not_now_view", _shown("NotNowButton"))
	_record("after_not_now_restart_text", _badge_text("RestartButton"))
	_record("script_saved", await _save_probe_script())
	_write_restart_marker()
	_press(_badge_button("RestartButton"))
	await _wait_for(func() -> bool: return false, 60.0)
	_record("restart_timeout", true)


# A scene with a root and no file opens the ready view in place of a restart. The
# step's own quit then installs the update.
func _stage_with_untitled_scene() -> void:
	_record("available", await _wait_for(_shown.bind("UpdateButton")))
	_record("scene_created", await _create_untitled_scene())
	_press(_badge_button("UpdateButton"))
	_record("ready_view", await _wait_for(_shown.bind("NotNowButton")))
	_record("view_names_scene", _badge_text("Status").contains(_VIEW_SCENE_TEXT))
	await _shot("untitled_ready_view")
	# A restart would free this plugin during the wait.
	await _frames(_NO_RESTART_FRAMES)
	_record("still_running", true)
	_record("after_wait_toolkit_version", _toolkit_version())


# An unsaved script keeps the editor from restarting on its own once staging ends;
# saved, it leaves the quit nothing to ask about. The harness sends the editor's quit
# shortcut once the waiting line is printed.
func _stage_then_wait_for_quit() -> void:
	_record("available", await _wait_for(_shown.bind("UpdateButton")))
	_record("script_edited", await _edit_probe_script())
	_press(_badge_button("UpdateButton"))
	_record("ready_view", await _wait_for(_shown.bind("NotNowButton")))
	_record("script_saved", await _save_probe_script())
	await _shot("quit_ready_view")
	print("[UPDATE-GUI] waiting for the quit shortcut")
	await _wait_for(func() -> bool: return false, 120.0)
	_record("quit_timeout", true)


func _read_major_badge() -> void:
	_record("badge_visible", await _wait_for(_badge_visible))
	_record("title", _badge_text("Title"))
	_record("update_visible", _shown("UpdateButton"))
	_record("major_icon_visible", _shown("MajorIcon"))


# Opens the probe script and types a line into it. Returns whether the script editor
# took the edit.
func _edit_probe_script() -> bool:
	EditorInterface.edit_script(load(_PROBE_SCRIPT))
	await _frames(30)
	var code := _probe_code_edit()
	if code == null:
		return false
	code.set_caret_line(code.get_line_count() - 1)
	code.insert_text_at_caret("\n%s\n" % _PROBE_EDIT)
	await _frames(30)
	return true


# Picks Save in the script editor's File menu, as a click on it does. Returns whether
# the edit reached the file.
func _save_probe_script() -> bool:
	var saved := false
	for menu: MenuButton in EditorInterface.get_script_editor().find_children("*", "MenuButton", true, false):
		var popup := menu.get_popup()
		for index in popup.item_count:
			if popup.get_item_text(index) == _SAVE_SCRIPT_ITEM:
				popup.id_pressed.emit(popup.get_item_id(index))
				saved = true
				break
		if saved:
			break
	await _frames(60)
	return saved and FileAccess.get_file_as_string(_PROBE_SCRIPT).contains(_PROBE_EDIT)


func _probe_code_edit() -> CodeEdit:
	var script_editor := EditorInterface.get_script_editor().get_current_editor()
	return script_editor.get_base_editor() as CodeEdit if script_editor != null else null


# Presses the Scene dock's 2D Scene button, which gives the empty scene tab a root.
# Returns whether the edited scene now has a root and no file.
func _create_untitled_scene() -> bool:
	for button: Button in EditorInterface.get_base_control().find_children("*", "Button", true, false):
		if button.text == _NEW_2D_SCENE_TEXT:
			_press(button)
			break
	await _frames(60)
	var root := EditorInterface.get_edited_scene_root()
	return root != null and root.scene_file_path.is_empty()


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


# Deferred, as a click is: from Godot 4.3 a synchronous restart frees the editor's
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
