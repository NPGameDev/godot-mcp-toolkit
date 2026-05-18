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
				+ "Three powerful features are gated by default:\n\n"
				+ "  \u2022 execute_code — arbitrary GDScript via Expression\n"
				+ "  \u2022 node_call_method — call methods on scene nodes\n"
				+ "  \u2022 read_user_scope — read/write whitelisted user:// paths\n\n"
				+ "You can enable all gates now, or toggle them individually\n"
				+ "later in the MCP dock.")
			dialog.ok_button_text = "Keep Defaults (Recommended)"
			_buttons.append(dialog.add_button("Enable All Gates", true, "enable_all"))

		1:
			# .mcp.json — two variants based on whether the file already exists.
			_mcp_exists = FileAccess.file_exists(
				ProjectSettings.globalize_path("res://") + ".mcp.json")
			if _mcp_exists:
				dialog.dialog_text = (
					"Your MCP client reads .mcp.json from the project root\n"
					+ "to locate and configure the server.\n\n"
					+ "The MCP server bridge requires Node.js 20+ to run.\n"
					+ "Download it from https://nodejs.org if not installed.\n\n"
					+ "An .mcp.json already exists in your project.")
				dialog.ok_button_text = "Continue (keep existing .mcp.json)"
				_buttons.append(
					dialog.add_button("Overwrite with clean .mcp.json", true, "overwrite_mcp"))
			else:
				dialog.dialog_text = (
					"Your MCP client reads .mcp.json from the project root\n"
					+ "to locate and configure the server.\n\n"
					+ "The MCP server bridge requires Node.js 20+ to run.\n"
					+ "Download it from https://nodejs.org if not installed.\n\n"
					+ "No .mcp.json was found — this file is required for your\n"
					+ "MCP client to connect to the toolkit.")
				dialog.ok_button_text = "Create .mcp.json"

		2:
			# MCP dock — show it in the bottom panel.
			dialog.dialog_text = (
				"The MCP Toolkit dock is in the bottom panel (next to Output and Debugger). "
				+ "It gives you:\n\n"
				+ "  \u2022 Server status — connection state, peer count, runtime port\n"
				+ "  \u2022 Feature gates — toggle gated capabilities on/off\n"
				+ "  \u2022 Audit log — review what the AI agent did\n"
				+ "  \u2022 Security settings — token rotation, response limits")
			dialog.ok_button_text = "Next"
			if _dock != null:
				_plugin.make_bottom_panel_item_visible(_dock)

		3:
			# Feature gates — open Project Settings.
			dialog.dialog_text = (
				"Feature gates are also available in Project Settings under "
				+ "MCP Toolkit > Feature Gates. Changes here sync to the dock "
				+ "and the MCP server automatically — no restart needed.\n\n"
				+ "  \u2022 allow_execute_code — GDScript evaluation via Expression\n"
				+ "  \u2022 allow_node_call_method — call methods on scene nodes\n"
				+ "  \u2022 allow_user_scope — read/write whitelisted user:// paths")
			dialog.ok_button_text = "Next"
			_buttons.append(dialog.add_button("Back", true, "back"))
			SettingsNavigator.open_mcp_settings()

		4:
			dialog.dialog_text = (
				"The 'Info / Help' button at the bottom of the MCP dock\n"
				+ "shows connection status, tool list, and documentation links.\n\n"
				+ "Companion Skills for Claude Code are bundled with the toolkit —\n"
				+ "click the 'Companion Skills' button in the dock to browse them.\n\n"
				+ "For supervised environments (classrooms, CI, demos), set\n"
				+ "GODOT_MCP_READ_ONLY=1 in .mcp.json to restrict to read-only tools.\n\n"
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
		"enable_all":
			# Enable all feature gates (with implicit RCE consent).
			if _dock != null:
				_dock.enable_all_gates()
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


## Re-create the onboarding completion flag at the new user:// path after a
## config/name change. Prevents the wizard from re-showing after a rename.
## Static so plugin.gd can call it without holding a wizard instance.
## Re-create the onboarding completion flag at the new user:// path after a
## config/name change. Prevents the wizard from re-showing after a rename.
## Called by plugin.gd's project_name_changed handler. Dirs are guaranteed
## to exist (UserPathMonitor calls ensure_dirs() before emitting the signal).
static func migrate_flag_after_rename() -> void:
	var f := FileAccess.open(_ONBOARDING_FLAG, FileAccess.WRITE)
	if f != null:
		f.store_string("1")
		f.close()


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
