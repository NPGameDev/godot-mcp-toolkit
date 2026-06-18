@tool
extends RefCounted
## Guided onboarding wizard shown on first plugin activation.
## Self-contained state machine managing a multi-step AcceptDialog.

const SettingsNavigator := preload("res://addons/godot_mcp_toolkit/ui/settings_navigator.gd")

const _ONBOARDING_FLAG := "user://addons/godot_mcp_toolkit/mcp_onboarding_v41l_shown"
const _ONBOARDING_PROGRESS := "user://addons/godot_mcp_toolkit/mcp_onboarding_progress"
const _STEP_COUNT := 3

var _plugin: EditorPlugin
var _dock: Control
var _dialog: AcceptDialog = null
var _step: int = 0
var _mcp_exists: bool = false  # Tracks .mcp.json state for step-1 variants.
var _buttons: Array = []  # Tracked custom buttons for per-step cleanup.


func _init(plugin: EditorPlugin, dock: Control) -> void:
	_plugin = plugin
	_dock = dock


func check_and_show() -> void:
	if FileAccess.file_exists(_ONBOARDING_FLAG):
		return

	# Resume from saved progress (e.g. after restart during wizard).
	_step = 0
	if FileAccess.file_exists(_ONBOARDING_PROGRESS):
		var f := FileAccess.open(_ONBOARDING_PROGRESS, FileAccess.READ)
		if f != null:
			_step = clampi(f.get_line().to_int(), 0, _STEP_COUNT - 1)
			f.close()
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
				+ "This plugin exposes your Godot editor to AI agents via MCP.\n"
				+ "Some tools can modify your project or execute arbitrary code.\n\n"
				+ "Risk is communicated per-tool via MCP annotations.\n"
				+ "For details and copy-pasteable agent blocking configs, see:\n"
				+ "  addons/godot_mcp_toolkit/docs/security-recommendations.md\n\n"
				+ "All tools are available by default. Use your agent's\n"
				+ "allowlist/blocklist to restrict specific tools if needed.")
			dialog.ok_button_text = "Next"
			_buttons.append(dialog.add_button("Open Security Doc", true, "open_security"))

		1:
			# .mcp.json — two variants based on whether the file already exists.
			_mcp_exists = FileAccess.file_exists(
				ProjectSettings.globalize_path("res://") + ".mcp.json")
			if _mcp_exists:
				dialog.dialog_text = (
					"Your MCP client reads .mcp.json from the project root "
					+ "to locate and configure the server.\n\n"
					+ "The MCP server bridge requires Node.js 20+ to run. "
					+ "Download it from https://nodejs.org if not installed.\n\n"
					+ "An .mcp.json already exists in your project.")
				dialog.ok_button_text = "Continue (keep existing .mcp.json)"
				_buttons.append(
					dialog.add_button("Overwrite with clean .mcp.json", true, "overwrite_mcp"))
			else:
				dialog.dialog_text = (
					"Your MCP client reads .mcp.json from the project root "
					+ "to locate and configure the server.\n\n"
					+ "The MCP server bridge requires Node.js 20+ to run. "
					+ "Download it from https://nodejs.org if not installed.\n\n"
					+ "No .mcp.json was found — this file is required for your "
					+ "MCP client to connect to the toolkit.")
				dialog.ok_button_text = "Create .mcp.json"

		2:
			# Dock + help + read-only info.
			if _dock != null:
				_plugin.make_bottom_panel_item_visible(_dock)
			dialog.dialog_text = (
				"The MCP Toolkit dock is in the bottom panel (next to Output and Debugger). "
				+ "From here you can:\n\n"
				+ "  \u2022 Monitor server status — connection state, peer count, runtime port\n"
				+ "  \u2022 Review the audit log — see what the AI agent did\n"
				+ "  \u2022 Adjust security settings — token rotation, response limits\n\n"
				+ "The 'Info / Help' button shows tool list and documentation links.\n"
				+ "Companion Skills for Claude Code are in the dock footer.\n\n"
				+ "For supervised environments, set GODOT_MCP_READ_ONLY=1 in\n"
				+ ".mcp.json to restrict the toolkit to read-only tools.\n\n"
				+ "The toolkit keeps the editor responsive while it's unfocused during\n"
				+ "MCP sessions (ON by default; raises background CPU). Toggle it in the\n"
				+ "dock's Server Status, or in Editor Settings → Mcp Toolkit →\n"
				+ "Performance — note this setting lives in Editor Settings, unlike\n"
				+ "the other mcp_toolkit/* keys in Project Settings.\n\n"
				+ "You're all set!")
			dialog.ok_button_text = "Close"
			_buttons.append(dialog.add_button("Back", true, "back"))
			_buttons.append(dialog.add_button("Open Info", true, "open_info"))


# -- Navigation ---------------------------------------------------------------


func _on_confirmed(dialog: AcceptDialog) -> void:
	if _step == 1 and not _mcp_exists:
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
		"back":
			if _step > 0:
				_step -= 1
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
		"open_security":
			var doc_path := "res://addons/godot_mcp_toolkit/docs/security-recommendations.md"
			var global_path := ProjectSettings.globalize_path(doc_path)
			OS.shell_open(global_path)


# -- Persistence --------------------------------------------------------------


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
