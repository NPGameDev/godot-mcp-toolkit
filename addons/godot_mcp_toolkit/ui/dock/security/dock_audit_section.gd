@tool
extends VBoxContainer
## Dock "Audit Log" collapsible-section content — settings + log view/clear.
##
## A dock sub-panel. Constructed and owned by dock.gd; added into the dock's
## tree (so the editor frees this panel with the dock). Builds its controls once
## and owns the whole audit concern: the enabled/max-size settings (each writes
## its ProjectSetting on change), the View/Clear buttons (clear uses the shared
## self-freeing confirm factory), and the lazy AuditLogDialog. Toasts go through
## an injected Callable so the panel never touches the dock's private toaster.
## While in the tree the two settings controls follow
## ProjectSettings.settings_changed, so an edit made in the Project Settings
## inspector shows here at once, and an adjustment made here starts from the
## current value instead of a stale one.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const AuditLogDialog := preload("res://addons/godot_mcp_toolkit/ui/dock/security/audit_log_dialog.gd")
const DockConfirm := preload("res://addons/godot_mcp_toolkit/ui/dock/dock_confirm.gd")

# Audit path source for the dialog + clear; passed by the dock from its bind().
var _audit_path: String = ""
# Dock-supplied toast sink (msg, severity, tooltip) — injected so the panel stays
# decoupled from the editor toaster the dock owns.
var _toast: Callable = Callable()

# The two settings controls, held so refresh() can repaint them.
var _enabled_checkbox: CheckBox = null
var _max_size_spinbox: SpinBox = null

# Lazy log viewer. Parented to the editor base control (NOT this panel) so its
# popup_centered() centers on the editor, not the dock — so it is NOT freed with
# this panel's subtree and must be freed explicitly in _exit_tree (see there).
var _audit_dialog: AcceptDialog = null


func _init(audit_path: String, toast: Callable) -> void:
	_audit_path = audit_path
	_toast = toast

	var audit_settings_row := HBoxContainer.new()
	add_child(audit_settings_row)

	_enabled_checkbox = CheckBox.new()
	_enabled_checkbox.text = "Enabled"
	_enabled_checkbox.toggled.connect(_on_audit_enabled_toggled)
	audit_settings_row.add_child(_enabled_checkbox)

	var audit_size_label := Label.new()
	audit_size_label.text = "  Max KB:"
	audit_size_label.add_theme_font_size_override("font_size", 11)
	audit_settings_row.add_child(audit_size_label)

	_max_size_spinbox = SpinBox.new()
	_max_size_spinbox.min_value = 0
	_max_size_spinbox.max_value = 10240
	_max_size_spinbox.step = 128
	_max_size_spinbox.tooltip_text = "0 = unlimited"
	_max_size_spinbox.value_changed.connect(_on_audit_max_size_changed)
	audit_settings_row.add_child(_max_size_spinbox)

	var audit_btns := HBoxContainer.new()
	add_child(audit_btns)

	var view_log_btn := Button.new()
	view_log_btn.text = "View Audit Log"
	view_log_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view_log_btn.pressed.connect(show_dialog)
	audit_btns.add_child(view_log_btn)

	var clear_log_btn := Button.new()
	clear_log_btn.text = "Clear Audit Log"
	clear_log_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_log_btn.pressed.connect(_on_clear_audit_log)
	audit_btns.add_child(clear_log_btn)

	refresh()


func _enter_tree() -> void:
	# An edit made in the Project Settings inspector never passes through these
	# controls, so follow ProjectSettings while in the tree. The signal names no
	# key, so each emission re-reads both settings. No feedback loop: refresh()
	# writes no setting and fires no write handler, so the signal a dock save
	# queues changes nothing.
	if not ProjectSettings.settings_changed.is_connected(refresh):
		ProjectSettings.settings_changed.connect(refresh)
	# Catch anything that changed between _init and entering the tree.
	refresh()


func _exit_tree() -> void:
	# The log viewer is a base-control child, not in this panel's subtree, so the
	# editor does NOT free it with the panel. Free it immediately (not queue_free)
	# so its reference chain is released before ObjectDB's exit-time leak check
	# runs (same reason the dock/server free() at teardown).
	if _audit_dialog != null and is_instance_valid(_audit_dialog):
		_audit_dialog.free()
	_audit_dialog = null
	# ProjectSettings outlives this panel; a callback left connected would keep
	# repainting a panel that has left the dock.
	if ProjectSettings.settings_changed.is_connected(refresh):
		ProjectSettings.settings_changed.disconnect(refresh)


# ---------------------------------------------------------------------------
# Audit log popup
# ---------------------------------------------------------------------------

## Opens the audit-log viewer, lazy-creating it on first use. Public because the
## dock's show_audit_dialog() delegator (called from the Tools menu) forwards here.
func show_dialog() -> void:
	if _audit_dialog == null or not is_instance_valid(_audit_dialog):
		_audit_dialog = AuditLogDialog.new()
		EditorInterface.get_base_control().add_child(_audit_dialog)
	_audit_dialog.show_log(_audit_path)


func _on_clear_audit_log() -> void:
	DockConfirm.confirm(
		"Clear Audit Log?",
		"This will permanently delete all audit log entries.",
		"Clear",
		func() -> void:
			var path := _audit_path
			if path.is_empty():
				path = Modules.Audit.get_log_path()
			var file := FileAccess.open(path, FileAccess.WRITE)
			if file != null:
				file.store_string("")
				file.close()
			if _toast.is_valid():
				_toast.call("Audit log cleared")
	)


# ---------------------------------------------------------------------------
# Settings handlers
# ---------------------------------------------------------------------------

## Repaints the Enabled checkbox and the Max KB spin box from their
## ProjectSettings.
##
## Assigns only where a stored value differs from its control, and through the
## no-signal setters, so a refresh never fires a write handler (each one saves
## project.godot), and a refresh with nothing new leaves a value the user is still
## typing alone. A stored size outside the spin box's range or step shows clamped
## or snapped.
func refresh() -> void:
	var enabled := bool(ProjectSettings.get_setting("mcp_toolkit/audit/enabled", true))
	if _enabled_checkbox.button_pressed != enabled:
		_enabled_checkbox.set_pressed_no_signal(enabled)
	var max_size_kb := float(ProjectSettings.get_setting("mcp_toolkit/audit/max_size_kb", 1024))
	if _max_size_spinbox.value != max_size_kb:
		_max_size_spinbox.set_value_no_signal(max_size_kb)


func _on_audit_enabled_toggled(enabled: bool) -> void:
	ProjectSettings.set_setting("mcp_toolkit/audit/enabled", enabled)
	ProjectSettings.save()


func _on_audit_max_size_changed(value: float) -> void:
	ProjectSettings.set_setting("mcp_toolkit/audit/max_size_kb", int(value))
	ProjectSettings.save()
