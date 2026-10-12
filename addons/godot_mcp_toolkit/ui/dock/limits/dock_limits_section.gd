@tool
extends VBoxContainer
## Dock "Security & Response Limits" sub-panel — token regen + response limits.
##
## A dock sub-panel. Constructed and owned by dock.gd; added into the dock's
## tree (so the editor frees it with the dock). Builds its own controls once and
## owns the limit spin boxes: each shows and edits a response limit's project
## value and writes it to its ProjectSetting on change. Token regeneration touches
## the server/token (which the dock owns), so it is surfaced as a signal the dock
## handles rather than wired here.
## An env override pushed by the MCP server never reaches a spin box, so a save
## from here cannot carry it into project.godot. Instead, under the fields, each
## limit with an active env override gets an override line naming the value in
## use and where it comes from.
## While in the tree it follows ProjectSettings.settings_changed and the
## env-override change signal, so a project value changed in the Project Settings
## inspector, or an env override the server pushes, shows here at once, and an
## adjustment made here starts from the current value instead of a stale one.

# Emitted when the user presses "Regenerate Token". The dock owns the server +
# toast, so it performs the actual token rotation; this panel only requests it.
signal regenerate_token_requested

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const ResponseLimits = Modules.ResponseLimits

var _script_cap_spinbox: SpinBox = null
var _save_cap_spinbox: SpinBox = null
var _ws_buffer_spinbox: SpinBox = null
# Per response-limit key: its spin box, its override line, and the field name both
# of those use.
var _spinboxes: Dictionary = {}
var _override_lines: Dictionary = {}
var _field_names: Dictionary = {}


func _init() -> void:
	var regen_btn := Button.new()
	regen_btn.text = "Regenerate Token"
	regen_btn.pressed.connect(_on_regen_pressed)
	add_child(regen_btn)

	var limits_row := HBoxContainer.new()
	add_child(limits_row)
	_script_cap_spinbox = _add_limit_field(limits_row, ResponseLimits.SCRIPT_READ_CAP_KB,
			"Script cap", _on_script_cap_changed)
	_save_cap_spinbox = _add_limit_field(limits_row, ResponseLimits.SAVE_READ_CAP_KB,
			"Save cap", _on_save_cap_changed)
	_ws_buffer_spinbox = _add_limit_field(limits_row, ResponseLimits.WS_BUFFER_KB,
			"WS buffer", _on_ws_buffer_changed)

	# One override line per limit, hidden while no env override is active.
	for key in ResponseLimits.KEYS:
		var override_line := Label.new()
		override_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		override_line.visible = false
		add_child(override_line)
		_override_lines[key] = override_line

	var limits_note := Label.new()
	limits_note.text = "These may be overridden by env vars in .mcp.json on connect."
	limits_note.add_theme_font_size_override("font_size", 11)
	limits_note.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	limits_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(limits_note)

	refresh()


func _enter_tree() -> void:
	# A project value changed in the Project Settings inspector, or an env override
	# pushed by the MCP server through meta.set_limits, never passes through these
	# spin boxes, so follow both sources while in the tree. Neither signal names a
	# key, so each emission repaints all three limits. No feedback loop: refresh()
	# writes no setting and fires no write handler, so the signal a dock save
	# queues changes nothing.
	if not ProjectSettings.settings_changed.is_connected(refresh):
		ProjectSettings.settings_changed.connect(refresh)
	var env_overrides_changed: Signal = ResponseLimits.env_overrides_changed()
	if not env_overrides_changed.is_connected(refresh):
		env_overrides_changed.connect(refresh)
	# Catch anything that changed between _init and entering the tree.
	refresh()


func _exit_tree() -> void:
	# ProjectSettings and the env-override layer outlive this panel; a callback left
	# connected would keep repainting a panel that has left the dock.
	if ProjectSettings.settings_changed.is_connected(refresh):
		ProjectSettings.settings_changed.disconnect(refresh)
	var env_overrides_changed: Signal = ResponseLimits.env_overrides_changed()
	if env_overrides_changed.is_connected(refresh):
		env_overrides_changed.disconnect(refresh)


## Repaints each limit's spin box from its project value and its override line from
## its env override.
##
## Assigns a spin box only where the project value differs from it, and through the
## no-signal setter, so a refresh never fires a write handler (each one saves
## project.godot), and a refresh with nothing new leaves a value the user is still
## typing alone. A project value outside a spin box's range or step shows clamped
## or snapped; the override line shows the exact value in use.
func refresh() -> void:
	for key in ResponseLimits.KEYS:
		_repaint_spinbox(_spinboxes[key], key)
		_repaint_override_line(_override_lines[key], key)


# Adds a limit's label and spin box to the field row, with the spin box's range
# taken from the response-limits table, and returns the spin box.
func _add_limit_field(
		row: HBoxContainer, key: String, field_name: String, on_changed: Callable) -> SpinBox:
	var label := Label.new()
	label.text = field_name + ":"
	row.add_child(label)
	var bounds: Array[int] = ResponseLimits.range_bounds(key)
	var spinbox := SpinBox.new()
	spinbox.min_value = bounds[0]
	spinbox.max_value = bounds[1]
	spinbox.step = bounds[2]
	spinbox.suffix = "KB"
	spinbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spinbox.value_changed.connect(on_changed)
	row.add_child(spinbox)
	_spinboxes[key] = spinbox
	_field_names[key] = field_name
	return spinbox


func _repaint_spinbox(spinbox: SpinBox, key: String) -> void:
	var project_kb := float(ResponseLimits.project_value(key))
	if spinbox.value != project_kb:
		spinbox.set_value_no_signal(project_kb)


func _repaint_override_line(override_line: Label, key: String) -> void:
	if not ResponseLimits.has_env_override(key):
		override_line.visible = false
		return
	override_line.text = _override_line_text(key)
	override_line.visible = true


# The save cap has no environment variable, so only a direct push from the server
# can set it; its line says so instead of naming a variable.
func _override_line_text(key: String) -> String:
	var field_name := str(_field_names[key])
	var in_use_kb: int = ResponseLimits.effective_value(key)
	var variable: String = ResponseLimits.env_variable(key)
	if variable.is_empty():
		return "%s in use: %d KB, set by the MCP server. This field applies once the server stops setting it." % [
				field_name, in_use_kb]
	return "%s in use: %d KB from %s (MCP client env). This field applies once you remove the variable and restart your MCP client." % [
			field_name, in_use_kb, variable]


func _on_regen_pressed() -> void:
	regenerate_token_requested.emit()


func _on_script_cap_changed(value: float) -> void:
	_save_project_value(ResponseLimits.SCRIPT_READ_CAP_KB, value)


func _on_save_cap_changed(value: float) -> void:
	_save_project_value(ResponseLimits.SAVE_READ_CAP_KB, value)


func _on_ws_buffer_changed(value: float) -> void:
	_save_project_value(ResponseLimits.WS_BUFFER_KB, value)


func _save_project_value(key: String, value: float) -> void:
	var clamped: int = maxi(ResponseLimits.floor_kb(key), int(value))
	ProjectSettings.set_setting(ResponseLimits.setting_path(key), clamped)
	ProjectSettings.save()
