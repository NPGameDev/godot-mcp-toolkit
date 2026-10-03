@tool
extends VBoxContainer
## Dock "Security & Response Limits" sub-panel — token regen + response caps.
##
## A dock sub-panel. Constructed and owned by dock.gd; added into the dock's
## tree (so the editor frees it with the dock). Builds its own controls once and
## owns the cap-SpinBox interactions: each cap writes its ProjectSetting on
## change. Token regeneration touches the server/token (which the dock owns), so
## it is surfaced as a signal the dock handles rather than wired here.
## While in the tree it follows ProjectSettings.settings_changed, so a cap
## changed elsewhere (the Project Settings inspector, or the MCP server's
## meta.set_limits) shows here at once, and an adjustment made here starts from
## the current value instead of a stale one.

# Emitted when the user presses "Regenerate Token". The dock owns the server +
# toast, so it performs the actual token rotation; this panel only requests it.
signal regenerate_token_requested

var _script_cap_spinbox: SpinBox = null
var _save_cap_spinbox: SpinBox = null
var _ws_buffer_spinbox: SpinBox = null


func _init() -> void:
	var regen_btn := Button.new()
	regen_btn.text = "Regenerate Token"
	regen_btn.pressed.connect(_on_regen_pressed)
	add_child(regen_btn)

	var limits_row := HBoxContainer.new()
	add_child(limits_row)

	var cap_label := Label.new()
	cap_label.text = "Script cap:"
	limits_row.add_child(cap_label)
	_script_cap_spinbox = SpinBox.new()
	_script_cap_spinbox.min_value = 64
	_script_cap_spinbox.max_value = 4096
	_script_cap_spinbox.step = 64
	_script_cap_spinbox.suffix = "KB"
	_script_cap_spinbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_script_cap_spinbox.value_changed.connect(_on_script_cap_changed)
	limits_row.add_child(_script_cap_spinbox)

	var save_cap_label := Label.new()
	save_cap_label.text = "Save cap:"
	limits_row.add_child(save_cap_label)
	_save_cap_spinbox = SpinBox.new()
	_save_cap_spinbox.min_value = 64
	_save_cap_spinbox.max_value = 4096
	_save_cap_spinbox.step = 64
	_save_cap_spinbox.suffix = "KB"
	_save_cap_spinbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_cap_spinbox.value_changed.connect(_on_save_cap_changed)
	limits_row.add_child(_save_cap_spinbox)

	var ws_label := Label.new()
	ws_label.text = "WS buffer:"
	limits_row.add_child(ws_label)
	_ws_buffer_spinbox = SpinBox.new()
	_ws_buffer_spinbox.min_value = 256
	_ws_buffer_spinbox.max_value = 8192
	_ws_buffer_spinbox.step = 256
	_ws_buffer_spinbox.suffix = "KB"
	_ws_buffer_spinbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ws_buffer_spinbox.value_changed.connect(_on_ws_buffer_changed)
	limits_row.add_child(_ws_buffer_spinbox)

	var limits_note := Label.new()
	limits_note.text = "These may be overridden by env vars in .mcp.json on connect."
	limits_note.add_theme_font_size_override("font_size", 11)
	limits_note.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	limits_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(limits_note)

	refresh()


func _enter_tree() -> void:
	# A cap changed in the Project Settings inspector, or pushed by the MCP server
	# through meta.set_limits, never passes through these spin boxes, so follow
	# ProjectSettings while in the tree. The signal names no key, so each emission
	# re-reads all three caps. No feedback loop: refresh() writes no setting and
	# fires no write handler, so the signal a dock save queues changes nothing.
	if not ProjectSettings.settings_changed.is_connected(refresh):
		ProjectSettings.settings_changed.connect(refresh)
	# Catch anything that changed between _init and entering the tree.
	refresh()


func _exit_tree() -> void:
	# ProjectSettings outlives this panel; a callback left connected would keep
	# repainting a panel that has left the dock.
	if ProjectSettings.settings_changed.is_connected(refresh):
		ProjectSettings.settings_changed.disconnect(refresh)


## Repaints the three cap spin boxes from their ProjectSettings.
##
## Assigns only where a stored value differs from its spin box, and through the
## no-signal setter, so a refresh never fires a write handler (each one saves
## project.godot), and a refresh with nothing new leaves a value the user is still
## typing alone. A stored value outside a spin box's range or step shows clamped
## or snapped.
func refresh() -> void:
	_repaint_spinbox(_script_cap_spinbox, "mcp_toolkit/limits/script_read_cap_kb", 256)
	_repaint_spinbox(_save_cap_spinbox, "mcp_toolkit/limits/save_read_cap_kb", 256)
	_repaint_spinbox(_ws_buffer_spinbox, "mcp_toolkit/limits/ws_buffer_kb", 1024)


func _repaint_spinbox(spinbox: SpinBox, key: String, default_kb: int) -> void:
	var stored_kb := float(ProjectSettings.get_setting(key, default_kb))
	if spinbox.value != stored_kb:
		spinbox.set_value_no_signal(stored_kb)


func _on_regen_pressed() -> void:
	regenerate_token_requested.emit()


func _on_script_cap_changed(value: float) -> void:
	var clamped := maxi(64, int(value))
	ProjectSettings.set_setting("mcp_toolkit/limits/script_read_cap_kb", clamped)
	ProjectSettings.save()


func _on_save_cap_changed(value: float) -> void:
	var clamped := maxi(64, int(value))
	ProjectSettings.set_setting("mcp_toolkit/limits/save_read_cap_kb", clamped)
	ProjectSettings.save()


func _on_ws_buffer_changed(value: float) -> void:
	var clamped := maxi(256, int(value))
	ProjectSettings.set_setting("mcp_toolkit/limits/ws_buffer_kb", clamped)
	ProjectSettings.save()
