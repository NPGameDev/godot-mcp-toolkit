@tool
extends RefCounted
## Guided onboarding wizard shown on first plugin activation.
## Self-contained state machine managing a multi-step AcceptDialog.

const SettingsNavigator := preload("res://addons/godot_mcp_toolkit/ui/settings_navigator.gd")

const _ONBOARDING_FLAG := "user://addons/godot_mcp_toolkit/mcp_onboarding_v35b_shown"
const _ONBOARDING_PROGRESS := "user://addons/godot_mcp_toolkit/mcp_onboarding_progress"
# Projects that already saw the v35 single-dialog onboarding skip the wizard.
const _ONBOARDING_FLAG_V35 := "user://addons/godot_mcp_toolkit/mcp_onboarding_v35_shown"
const _STEP_COUNT := 5

var _plugin: EditorPlugin
var _dock: Control
var _notifier: RefCounted = null  # GateNotifier
var _dialog: AcceptDialog = null
var _step: int = 0
var _mcp_exists: bool = false  # Tracks .mcp.json state for step-1 variants.
var _buttons: Array = []  # Tracked custom buttons for per-step cleanup.


func _init(plugin: EditorPlugin, dock: Control, notifier: RefCounted = null) -> void:
	_plugin = plugin
	_dock = dock
	_notifier = notifier


func check_and_show() -> void:
	if FileAccess.file_exists(_ONBOARDING_FLAG):
		return
	if FileAccess.file_exists(_ONBOARDING_FLAG_V35):
		_write_flag()
		return

	# Resume from saved progress (e.g. after Power User restart).
	_step = 0
	if FileAccess.file_exists(_ONBOARDING_PROGRESS):
		var f := FileAccess.open(_ONBOARDING_PROGRESS, FileAccess.READ)
		if f != null:
			_step = clampi(f.get_line().to_int(), 0, _STEP_COUNT - 1)
			f.close()
	if _notifier != null:
		_notifier._wizard_active = true
	_buttons.clear()
	var dialog := AcceptDialog.new()
	dialog.exclusive = false
	dialog.min_size = Vector2i(480, 260)

	# AcceptDialog auto-hides on confirmed — re-show after advancing.
	dialog.confirmed.connect(_on_confirmed.bind(dialog))
	dialog.custom_action.connect(_on_custom_action.bind(dialog))
	dialog.canceled.connect(func():
		_write_flag()
		free_if_open()
	)

	_dialog = dialog
	_apply_step(dialog)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


func free_if_open() -> void:
	if _notifier != null:
		_notifier._wizard_active = false
	_buttons.clear()
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.queue_free()
	_dialog = null


# -- Step rendering -----------------------------------------------------------


func _apply_step(dialog: AcceptDialog) -> void:
	dialog.title = "MCP Toolkit — Setup Wizard (%d of %d)" % [
		_step + 1, _STEP_COUNT]

	# Free all tracked custom buttons from the previous step.
	for btn in _buttons:
		if is_instance_valid(btn):
			btn.queue_free()
	_buttons.clear()

	match _step:
		0:
			dialog.dialog_text = (
				"Welcome to the Godot MCP Toolkit!\n\n"
				+ "Your AI coding assistant sees tools based on the active profile.\n"
				+ "Choose your starting configuration:\n\n"
				+ "  Standard (default) — core tools, unsafe ops disabled\n"
				+ "  Power User — all tools, including code execution & OS commands\n\n"
				+ "You can change this anytime in the MCP dock.")
			dialog.ok_button_text = "Standard (Recommended)"
			_buttons.append(dialog.add_button("Power User Mode", true, "power_user"))

		1:
			# .mcp.json — two variants based on whether the file already exists.
			_mcp_exists = FileAccess.file_exists(
				ProjectSettings.globalize_path("res://") + ".mcp.json")
			if _mcp_exists:
				dialog.dialog_text = (
					"Your MCP client reads .mcp.json from the project root\n"
					+ "to locate and configure the server.\n\n"
					+ "An .mcp.json already exists in your project.")
				dialog.ok_button_text = "Continue (keep existing .mcp.json)"
				_buttons.append(
					dialog.add_button("Overwrite with clean .mcp.json", true, "overwrite_mcp"))
			else:
				dialog.dialog_text = (
					"Your MCP client reads .mcp.json from the project root\n"
					+ "to locate and configure the server.\n\n"
					+ "No .mcp.json was found — this file is required for your\n"
					+ "MCP client to connect to the toolkit.")
				dialog.ok_button_text = "Create .mcp.json"

		2:
			# MCP control center — show the dock.
			dialog.dialog_text = (
				"This is your MCP control center — server status,\n"
				+ "feature gates, and audit log.\n\n"
				+ "The dock is now visible in the bottom panel.")
			dialog.ok_button_text = "Next"
			if _dock != null:
				_plugin.make_bottom_panel_item_visible(_dock)

		3:
			# Feature gates — open Project Settings.
			dialog.dialog_text = (
				"Toggle individual capabilities here. Changes sync to\n"
				+ "your MCP configuration automatically.\n\n"
				+ "Navigate to: MCP Toolkit > Feature Gates")
			dialog.ok_button_text = "Next"
			_buttons.append(dialog.add_button("Back", true, "back"))
			SettingsNavigator.open_mcp_settings()

		4:
			dialog.dialog_text = (
				"The 'Info / Help' button at the bottom of the MCP dock\n"
				+ "shows connection status, tool list, and documentation links.\n\n"
				+ "You're all set!")
			dialog.ok_button_text = "Close"
			_buttons.append(dialog.add_button("Back", true, "back"))
			_buttons.append(dialog.add_button("Open Info", true, "open_info"))

	# "Skip Tour" on steps 2–3 (not 0: profile required;
	# not 1: .mcp.json required; not 4: nothing to skip).
	if _step >= 2 and _step <= 3:
		_buttons.append(dialog.add_button("Skip Tour", true, "skip"))


# -- Navigation ---------------------------------------------------------------


func _on_confirmed(dialog: AcceptDialog) -> void:
	if _step == 0:
		# Step 0 OK = "Standard (Recommended)" — no action needed, default profile.
		pass
	elif _step == 1 and not _mcp_exists:
		# Step 1 OK = "Create .mcp.json" — write the file now.
		if _dock != null:
			_dock.write_mcp_json()
	if _step >= _STEP_COUNT - 1:
		# Final step — finish.
		_write_flag()
		free_if_open()
		return
	_step += 1
	_save_progress()
	_apply_step(dialog)
	# AcceptDialog auto-hides on confirmed — re-show for the next step.
	dialog.popup_centered()


func _on_custom_action(action: StringName, dialog: AcceptDialog) -> void:
	match str(action):
		"skip":
			_write_flag()
			free_if_open()
		"back":
			if _step > 0:
				_step -= 1
				_apply_step(dialog)
		"power_user":
			# Trigger Power User flow — the dock shows its own confirmation dialog.
			if _dock != null:
				_dock.toggle_power_user_mode()
			# Advance to step 1 after choosing. Save progress in case the
			# user restarts the editor (Power User toggle suggests a restart).
			_step = 1
			_save_progress()
			_apply_step(dialog)
		"standard":
			# Explicit standard choice — advance.
			_step = 1
			_save_progress()
			_apply_step(dialog)
		"overwrite_mcp":
			if _dock != null:
				_dock.write_mcp_json(true)
			_step += 1
			_save_progress()
			_apply_step(dialog)
		"open_info":
			_write_flag()
			free_if_open()
			if _dock != null:
				_dock._show_info_dialog()


# -- Persistence --------------------------------------------------------------


func _write_flag() -> void:
	var f := FileAccess.open(_ONBOARDING_FLAG, FileAccess.WRITE)
	if f != null:
		f.store_string("1")
		f.close()
	# Clean up progress file — wizard is done.
	if FileAccess.file_exists(_ONBOARDING_PROGRESS):
		DirAccess.remove_absolute(_ONBOARDING_PROGRESS)


func _save_progress() -> void:
	var f := FileAccess.open(_ONBOARDING_PROGRESS, FileAccess.WRITE)
	if f != null:
		f.store_string(str(_step))
		f.close()
