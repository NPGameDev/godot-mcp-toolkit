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
	_show_step(dialog)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


func free_if_open() -> void:
	_buttons.clear()
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.queue_free()
	_dialog = null


# -- Step rendering -----------------------------------------------------------
#
# Each step contributes a "spec" — a plain data description of its content — while
# a single renderer (_show_step) owns the boilerplate every step shares: the
# title, the previous step's button cleanup, applying text/ok-label, and
# add+track of each custom button (tracking is automatic, so a button can't leak
# from the per-step cleanup loop). Adding a step means adding a spec, not another
# rendering arm that has to re-implement the cleanup/track/popup contract.
#
# Spec shape (all values plain data except on_enter):
#   text:      String    — the dialog body
#   ok_label:  String    — the OK button caption
#   buttons:   Array     — [ { label: String, action: String }, ... ], in order
#   on_enter:  Callable  — optional side-effect run as the step is shown


# Build the spec for the current step. Pure with respect to the dialog: it returns
# data and may set _mcp_exists (which navigation reads), but never touches the
# dialog — so each step's text, ok-label, and buttons are unit-checkable without
# an editor.
func _spec_for_step() -> Dictionary:
	match _step:
		0:
			return _spec_welcome()
		1:
			# Probe the filesystem here (the impure part) and record it for
			# navigation; the spec body itself is built purely from the result.
			_mcp_exists = FileAccess.file_exists(
				ProjectSettings.globalize_path("res://") + ".mcp.json")
			return _spec_mcp_json(_mcp_exists)
		2:
			return _spec_dock_overview()
	return {}


func _spec_welcome() -> Dictionary:
	return {
		"text": (
			"Welcome to the Godot MCP Toolkit!\n\n"
			+ "This plugin exposes your Godot editor to AI agents via MCP.\n"
			+ "Some tools can modify your project or execute arbitrary code.\n\n"
			+ "Risk is communicated per-tool via MCP annotations.\n"
			+ "For details and copy-pasteable agent blocking configs, see:\n"
			+ "  addons/godot_mcp_toolkit/docs/security-recommendations.md\n\n"
			+ "All tools are available by default. Use your agent's\n"
			+ "allowlist/blocklist to restrict specific tools if needed."),
		"ok_label": "Next",
		"buttons": [{"label": "Open Security Doc", "action": "open_security"}],
	}


# Pure: the .mcp.json step has two variants keyed on whether the file already
# exists. The OK action also differs (keep-vs-create), which navigation drives off
# _mcp_exists — set by the caller, not here.
func _spec_mcp_json(mcp_exists: bool) -> Dictionary:
	var intro := (
		"Your MCP client reads .mcp.json from the project root "
		+ "to locate and configure the server.\n\n"
		+ "The MCP server bridge requires Node.js 20+ to run. "
		+ "Download it from https://nodejs.org if not installed.\n\n")
	if mcp_exists:
		return {
			"text": intro + "An .mcp.json already exists in your project.",
			"ok_label": "Continue (keep existing .mcp.json)",
			"buttons": [{
				"label": "Overwrite with clean .mcp.json",
				"action": "overwrite_mcp",
			}],
		}
	return {
		"text": intro + (
			"No .mcp.json was found — this file is required for your "
			+ "MCP client to connect to the toolkit."),
		"ok_label": "Create .mcp.json",
		"buttons": [],
	}


func _spec_dock_overview() -> Dictionary:
	# Surfacing the dock is a side-effect, so it rides as on_enter rather than
	# being baked into the (otherwise pure) spec. Assigned as a separate statement
	# (not an inline dict value) to keep the multi-line lambda unambiguous to parse.
	var reveal_dock := func() -> void:
		if _dock != null:
			_plugin.make_bottom_panel_item_visible(_dock)
	var spec := {
		"text": (
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
				+ "You're all set!"),
		"ok_label": "Close",
		"buttons": [
			{"label": "Back", "action": "back"},
			{"label": "Open Info", "action": "open_info"},
		],
	}
	spec["on_enter"] = reveal_dock
	return spec


# Render the current step's spec onto the dialog. Owns the boilerplate every step
# shares: title, previous-button cleanup, text + ok-label, and add+track of each
# custom button (tracking happens here, so a button can never leak from the
# per-step cleanup loop). on_enter, if present, fires before the caller pops up.
func _show_step(dialog: AcceptDialog) -> void:
	dialog.title = "MCP Toolkit — Setup Wizard (%d of %d)" % [
		_step + 1, _STEP_COUNT]

	# Free all tracked custom buttons from the previous step.
	for btn in _buttons:
		if is_instance_valid(btn):
			btn.queue_free()
	_buttons.clear()

	var spec := _spec_for_step()
	dialog.dialog_text = str(spec.get("text", ""))
	dialog.ok_button_text = str(spec.get("ok_label", ""))
	var buttons: Array = spec.get("buttons", [])
	for entry in buttons:
		var button: Dictionary = entry
		_buttons.append(dialog.add_button(
			str(button.get("label", "")), true, str(button.get("action", ""))))
	if spec.has("on_enter"):
		var on_enter: Callable = spec.get("on_enter")
		on_enter.call()


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
	_show_step(dialog)
	# AcceptDialog auto-hides on confirmed — re-show for the next step.
	dialog.popup_centered()


func _on_custom_action(action: StringName, dialog: AcceptDialog) -> void:
	match str(action):
		"back":
			if _step > 0:
				_step -= 1
				_show_step(dialog)
		"overwrite_mcp":
			if _dock != null:
				_dock.write_mcp_json(true)
			_step += 1
			_save_progress()
			_show_step(dialog)
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
## user:// path shift (config/name, use_custom_user_dir, or custom_user_dir_name
## change). Prevents the wizard from re-showing once the path moves. Called by
## plugin.gd's user_path_changed handler. Dirs are guaranteed to exist
## (UserPathMonitor calls ensure_dirs() before emitting the signal).
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
