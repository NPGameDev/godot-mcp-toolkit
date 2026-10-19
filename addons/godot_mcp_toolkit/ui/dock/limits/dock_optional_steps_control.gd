@tool
extends HBoxContainer
## Dock "Show optional steps added by toolkit updates" checkbox, in Server Status.
##
## A dock sub-panel. Constructed and owned by dock.gd; added into the dock's tree
## (so the editor frees it with the dock). Reads and writes the machine-wide
## EditorSettings key that the setup wizard's optional-steps step also edits.
## Subscribes itself to EditorSettings.settings_changed while in the tree, so a
## change made in the wizard or the Editor Settings dialog repaints the box at once.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const SetupSteps = Modules.SetupSteps

var _check: CheckBox = null


func _init() -> void:
	_check = CheckBox.new()
	_check.text = "Show optional steps added by toolkit updates"
	_check.set_pressed_no_signal(_read_setting())
	_check.toggled.connect(_on_toggled)
	add_child(_check)


func _enter_tree() -> void:
	# The signal is keyless, and refresh() is cheap and idempotent, so repainting on
	# every settings change is fine. No feedback loop: _on_toggled writes the
	# setting, and the refresh that follows reads back the value the box shows.
	var es := EditorInterface.get_editor_settings()
	if es != null and not es.settings_changed.is_connected(refresh):
		es.settings_changed.connect(refresh)
	refresh()


func _exit_tree() -> void:
	# The EditorSettings singleton outlives this control — an undisconnected
	# callback would go zombie after the dock is freed.
	var es := EditorInterface.get_editor_settings()
	if es != null and es.settings_changed.is_connected(refresh):
		es.settings_changed.disconnect(refresh)


## Repaint the box from the setting without firing its toggled signal.
func refresh() -> void:
	if _check == null:
		return
	var shown := _read_setting()
	if _check.button_pressed != shown:
		_check.set_pressed_no_signal(shown)


func _on_toggled(enabled: bool) -> void:
	var es := EditorInterface.get_editor_settings()
	if es != null:
		es.set_setting(SetupSteps.SHOW_OPTIONAL_STEPS_SETTING, enabled)


func _read_setting() -> bool:
	return SetupSteps.shows_optional_steps(EditorInterface.get_editor_settings())
