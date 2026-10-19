@tool
extends RefCounted
## The setup wizard: one dialog that walks the user through a run of setup steps.
##
## A run is the list of step ids the run planner picked
## ([code]core/setup_steps.gd[/code]): every step for a new user, only the missed
## ones at a later editor start. The wizard shows the run and reports which steps
## the user has seen through [signal step_seen]; it never reads or writes the
## seen-steps file itself.[br]
## [br]
## A step counts as seen once the user leaves it: with Next or Done, or with a
## button that moves on ("Write .mcp.json", "Open Info"). Closing the dialog with ×
## also counts the open step and every optional step of the run not reached yet;
## required steps not reached stay unseen. "Remind me later", on the step a run
## opens on, closes the dialog and counts nothing.

## Emitted when the user leaves the step [param step_id] in a way that counts it as
## seen. Emitted again for a step left a second time after Back.
signal step_seen(step_id: StringName)

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const SetupSteps = Modules.SetupSteps
const SettingsNavigator := preload("res://addons/godot_mcp_toolkit/ui/settings_navigator.gd")
const MCPJsonWriteFlow := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_write_flow.gd")
const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")
const ToolkitDialogPresenter := preload("res://addons/godot_mcp_toolkit/ui/toolkit_dialog_presenter.gd")
const SetupStepSettings := preload("res://addons/godot_mcp_toolkit/ui/setup_step_settings.gd")

const _TITLE := "MCP Toolkit — Setup Wizard (%d of %d)"
const _NEXT_LABEL := "Next"
const _DONE_LABEL := "Done"
const _BACK_ACTION := "back"
const _REMIND_LATER_LABEL := "Remind me later"
const _REMIND_LATER_ACTION := "remind_later"
# The width a checkbox step's text wraps at.
const _WRAP_WIDTH := 560.0

var _plugin: EditorPlugin
var _server: Node  # Passed to the dialog presenter's Info / Help dialog.
var _write_flow: MCPJsonWriteFlow
var _dialog_presenter: ToolkitDialogPresenter
var _dialog: AcceptDialog = null
# The run being shown, the index of its open step, and the steps shown so far.
var _run: Array[StringName] = []
var _index: int = 0
var _visited: Array[StringName] = []
var _mcp_exists: bool = false  # Tracks .mcp.json state for the .mcp.json step's variants.
var _buttons: Array = []  # Tracked custom buttons for per-step cleanup.
# Per-step body content replacing the dialog text (the .mcp.json step's pin choice,
# a checkbox step's box), freed when the step changes like the buttons; null for a
# text-only step.
var _content: Control = null
var _pinned_box: CheckBox = null
var _latest_box: CheckBox = null
var _check_box: CheckBox = null
# Built on first use, so a wizard made without an editor never reaches for one.
var _settings: SetupStepSettings = null


func _init(
		plugin: EditorPlugin, server: Node,
		write_flow: MCPJsonWriteFlow, dialog_presenter: ToolkitDialogPresenter) -> void:
	_plugin = plugin
	_server = server
	_write_flow = write_flow
	_dialog_presenter = dialog_presenter


## Show the setup wizard over the editor for the run [param steps], a list of step
## ids in display order. Does nothing for an empty run or while a run is open.
func show_run(steps: Array[StringName]) -> void:
	if steps.is_empty() or (_dialog != null and is_instance_valid(_dialog)):
		return
	var dialog := _open_run(steps)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


## Use [param settings] for the checkbox steps instead of the project's and the
## editor's settings, for tests.
func set_settings(settings: SetupStepSettings) -> void:
	_settings = settings


# Mid-session dismissal — every in-wizard caller runs inside one of the dialog's OWN
# signal callbacks (confirmed / custom_action / canceled), where an immediate free()
# would delete the emitter mid-emission; queue_free() is the legal form there. Plugin
# teardown uses teardown() instead (immediate free — see below). The run is
# cleared first, so nothing the dialog emits on its way out counts a step as seen.
func free_if_open() -> void:
	_end_run()
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.queue_free()
	_dialog = null


# Plugin-teardown counterpart of free_if_open(): immediate free(), not queue_free().
# This runs on the plugin's _exit_tree path, outside any dialog signal emission, and a
# deferred delete would hold the dialog's button/confirm connections (and this wizard
# instance) past ObjectDB's exit-time leak check → spurious "resources still in use
# at exit". The dialog may be an open popup — free() closes and deletes it in one step.
# An editor closed mid-run therefore records nothing more.
func teardown() -> void:
	_end_run()
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.free()
	_dialog = null


# Build the dialog for the run `steps` and render its first step. The caller
# parents the dialog and pops it up.
func _open_run(steps: Array[StringName]) -> AcceptDialog:
	_run = steps.duplicate()
	_index = 0
	_visited.clear()
	_buttons.clear()
	var dialog := AcceptDialog.new()
	dialog.exclusive = false
	dialog.min_size = Vector2i(480, 260)
	# AcceptDialog auto-hides on confirmed — re-show after advancing.
	dialog.confirmed.connect(_on_confirmed.bind(dialog))
	dialog.custom_action.connect(_on_custom_action.bind(dialog))
	dialog.canceled.connect(_on_canceled)
	_dialog = dialog
	_show_step(dialog)
	return dialog


func _end_run() -> void:
	_run.clear()
	_index = 0
	_visited.clear()
	_buttons.clear()
	_clear_content_refs()


func _settings_store() -> SetupStepSettings:
	if _settings == null:
		_settings = SetupStepSettings.new(
				ProjectSettings, func() -> Object: return EditorInterface.get_editor_settings())
	return _settings


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
#   text:       String    — the dialog body
#   ok_label:   String    — the OK button caption
#   buttons:    Array     — [ { label: String, action: String }, ... ], in order
#   on_enter:   Callable  — optional side-effect run as the step is shown
#   pin_choice: bool      — optional; show the server pin choice under the text
#   check_box:  String    — optional; a checkbox with this label under the text,
#                           showing and applying the step's setting
#
# A spec describes its step alone; _spec_in_run() fits it to its place in a run.


# Build the spec for the step `step_id`. Pure with respect to the dialog: it
# returns data and may set _mcp_exists (which navigation reads), but never touches
# the dialog — so each step's text, ok-label, and buttons are unit-checkable without
# an editor.
func _spec_for_step(step_id: StringName) -> Dictionary:
	if step_id == SetupSteps.WELCOME:
		return _spec_welcome()
	if step_id == SetupSteps.MCP_JSON:
		# Probe the filesystem here (the impure part) and record it for
		# navigation; the spec body itself is built purely from the result.
		_mcp_exists = FileAccess.file_exists(
			ProjectSettings.globalize_path("res://") + ".mcp.json")
		return _spec_mcp_json(_mcp_exists)
	if step_id == SetupSteps.OPTIONAL_STEPS:
		return _spec_optional_steps()
	if step_id == SetupSteps.UPDATES:
		return _spec_updates()
	if step_id == SetupSteps.DOCK:
		return _spec_dock_overview()
	return {}


# Fit `spec` to its place in a run: the run's first step has no Back and
# carries "Remind me later", and on the run's last step an OK that reads "Next"
# reads "Done". Action labels and "Close" stay.
static func _spec_in_run(spec: Dictionary, is_first: bool, is_last: bool) -> Dictionary:
	var fitted := spec.duplicate()
	var buttons: Array = []
	for entry in spec.get("buttons", []):
		var button: Dictionary = entry
		if is_first and str(button.get("action", "")) == _BACK_ACTION:
			continue
		buttons.append(button)
	if is_first:
		buttons.append({"label": _REMIND_LATER_LABEL, "action": _REMIND_LATER_ACTION})
	fitted["buttons"] = buttons
	if is_last and str(spec.get("ok_label", "")) == _NEXT_LABEL:
		fitted["ok_label"] = _DONE_LABEL
	return fitted


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
		"ok_label": _NEXT_LABEL,
		"buttons": [{"label": "Open Security Doc", "action": "open_security"}],
	}


# Pure: the .mcp.json step has two variants keyed on whether the file already
# exists. The OK action also differs (keep-vs-create), which navigation drives off
# _mcp_exists — set by the caller, not here.
func _spec_mcp_json(mcp_exists: bool) -> Dictionary:
	var intro := (
		"Your MCP client reads .mcp.json from the project root "
		+ "to locate and configure the server.\n\n"
		+ "The MCP server bridge requires Node.js 22+ to run. "
		+ "Download it from https://nodejs.org if not installed.\n\n")
	if mcp_exists:
		return {
			# Continue keeps the file as it is, so the choice must say it takes
			# effect only through a write.
			"text": intro + (
				"An .mcp.json already exists in your project. The server choice "
				+ "below applies only if you press Write .mcp.json."),
			"ok_label": "Continue (keep existing .mcp.json)",
			"buttons": [{
				"label": "Write .mcp.json",
				"action": "overwrite_mcp",
			}],
			"pin_choice": true,
		}
	return {
		"text": intro + (
			"No .mcp.json was found — this file is required for your "
			+ "MCP client to connect to the toolkit."),
		"ok_label": "Create .mcp.json",
		"buttons": [],
		"pin_choice": true,
	}


func _spec_optional_steps() -> Dictionary:
	return {
		"text": (
			"Toolkit updates sometimes add steps to this wizard. When one does, the next "
			+ "time you start the editor you'll see only the new steps.\n\n"
			+ "Some steps are required because you lose something by skipping them: "
			+ "without .mcp.json your AI client won't find the toolkit on its own, and the "
			+ "update check only starts once you've seen the update-check step. Required "
			+ "steps come back at every editor start until you've seen them. \"Remind me "
			+ "later\" puts them off until the next start.\n\n"
			+ "The other steps are optional. Untick the box below and optional steps that "
			+ "future updates add won't show, in any project on this machine. Required "
			+ "steps still show."),
		"ok_label": _NEXT_LABEL,
		"buttons": [{"label": "Back", "action": _BACK_ACTION}],
		"check_box": "Show optional steps added by toolkit updates",
	}


func _spec_updates() -> Dictionary:
	return {
		"text": (
			"At most once a day, the toolkit asks GitHub whether a newer version is out. "
			+ "If one is, it also asks the Asset Store whether it lists that version yet. "
			+ "When there's a newer version, a closable badge at the top of the MCP Toolkit "
			+ "dock links to it. The toolkit never installs anything by itself.\n\n"
			+ "These requests carry no identifier and nothing about your project. Untick "
			+ "the box below and the toolkit sends no requests at all.\n\n"
			+ "You can change this later in Project Settings under Mcp Toolkit > Updates. "
			+ "It's saved in project.godot, so it applies to everyone who works on this "
			+ "project."),
		"ok_label": _NEXT_LABEL,
		"buttons": [{"label": "Back", "action": _BACK_ACTION}],
		"check_box": "Check for updates",
	}


func _spec_dock_overview() -> Dictionary:
	# Surfacing the dock is a side-effect, so it rides as on_enter rather than
	# being baked into the (otherwise pure) spec. Assigned as a separate statement
	# (not an inline dict value) to keep the multi-line lambda unambiguous to parse.
	var reveal_dock := func() -> void:
		if _plugin != null:
			_plugin.call("reveal_dock")  # dynamic dispatch: base EditorPlugin lacks reveal_dock
	var spec := {
		"text": (
				"The MCP Toolkit dock is in the bottom panel (next to Output and Debugger). "
				+ "From here you can:\n\n"
				+ "  • Monitor server status — connection state, peer count, runtime port\n"
				+ "  • Review the audit log — see what the AI agent did\n"
				+ "  • Adjust security settings — token rotation, response limits\n\n"
				+ "The 'Info / Help' button shows tool list and documentation links.\n"
				+ "Companion Skills for Claude Code are in the dock footer.\n\n"
				+ "For supervised environments, set GODOT_MCP_READ_ONLY=1 in\n"
				+ ".mcp.json to restrict the toolkit to read-only tools.\n\n"
				+ "The toolkit keeps the editor responsive while it's unfocused during\n"
				+ "MCP sessions (ON by default; raises background CPU). Toggle it in the\n"
				+ "dock's Server Status, or in Editor Settings → Mcp Toolkit → Performance.\n\n"
				+ "The dock's limits and audit controls are shortcuts into\n"
				+ "Project Settings → Mcp Toolkit, where all per-project options\n"
				+ "live (including advanced ones the dock doesn't surface).\n\n"
				+ "You're all set!"),
		"ok_label": "Close",
		"buttons": [
			{"label": "Back", "action": _BACK_ACTION},
			{"label": "Open Info", "action": "open_info"},
		],
	}
	spec["on_enter"] = reveal_dock
	return spec


# Render the open step's spec onto the dialog. Owns the boilerplate every step
# shares: title, previous-button cleanup, text + ok-label, and add+track of each
# custom button (tracking happens here, so a button can never leak from the
# per-step cleanup loop). on_enter, if present, fires before the caller pops up.
func _show_step(dialog: AcceptDialog) -> void:
	var step_id := _run[_index]
	if not _visited.has(step_id):
		_visited.append(step_id)
	dialog.title = _TITLE % [_index + 1, _run.size()]

	# Free all tracked custom buttons from the previous step.
	for btn in _buttons:
		if is_instance_valid(btn):
			btn.queue_free()
	_buttons.clear()
	# Removed before the free so the old and new content never share the dialog,
	# which lays every child over the same area.
	if _content != null and is_instance_valid(_content):
		dialog.remove_child(_content)
		_content.queue_free()
	_clear_content_refs()

	var spec := _spec_in_run(_spec_for_step(step_id), _index == 0, _index == _run.size() - 1)
	var text := str(spec.get("text", ""))
	# The dialog's own text label would sit under custom content, so the text
	# moves into the content.
	if bool(spec.get("pin_choice", false)):
		dialog.dialog_text = ""
		_content = _build_pin_choice(text)
		dialog.add_child(_content)
	elif spec.has("check_box"):
		dialog.dialog_text = ""
		_content = _build_check_box(text, str(spec.get("check_box", "")), step_id)
		dialog.add_child(_content)
	else:
		dialog.dialog_text = text
	dialog.ok_button_text = str(spec.get("ok_label", ""))
	var buttons: Array = spec.get("buttons", [])
	for entry in buttons:
		var button: Dictionary = entry
		_buttons.append(dialog.add_button(
			str(button.get("label", "")), true, str(button.get("action", ""))))
	if spec.has("on_enter"):
		var on_enter: Callable = spec.get("on_enter")
		on_enter.call()


# The .mcp.json step's body: its text, then Pinned or Latest as two exclusive
# check boxes, preselected from the project setting. A custom version checks
# neither and says so; the step leaves it alone unless the user picks one.
func _build_pin_choice(text: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	var intro := Label.new()
	intro.text = text
	box.add_child(intro)
	var group := ButtonGroup.new()
	_pinned_box = _add_choice(box, group, "Pinned (recommended)",
			"Uses the server version this toolkit was tested with. Updating the toolkit updates the server.")
	_latest_box = _add_choice(box, group, "Latest",
			"Downloads the newest server on every launch; may show a version warning until you update the toolkit.")
	var version_setting := MCPJsonSync.read_version_setting()
	var mode := MCPJsonSync.pin_mode(version_setting)
	_pinned_box.button_pressed = mode == MCPJsonSync.MODE_PINNED
	_latest_box.button_pressed = mode == MCPJsonSync.MODE_LATEST
	if mode == MCPJsonSync.MODE_CUSTOM:
		var note := Label.new()
		note.text = ("Project Settings names a custom server version (%s); "
				+ "pick one above to replace it.") % version_setting.strip_edges()
		box.add_child(note)
	return box


func _add_choice(box: VBoxContainer, group: ButtonGroup, label: String, description: String) -> CheckBox:
	var choice := CheckBox.new()
	choice.text = label
	choice.button_group = group
	box.add_child(choice)
	var detail := Label.new()
	detail.text = "      " + description
	detail.modulate = Color(1, 1, 1, 0.7)
	box.add_child(detail)
	return choice


# A checkbox step's body: its text, wrapped, then the box ticked from the step's
# setting as it is now.
func _build_check_box(text: String, label: String, step_id: StringName) -> VBoxContainer:
	var box := VBoxContainer.new()
	var intro := Label.new()
	intro.text = text
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.custom_minimum_size = Vector2(_WRAP_WIDTH, 0)
	box.add_child(intro)
	_check_box = CheckBox.new()
	_check_box.text = label
	_check_box.button_pressed = _settings_store().is_on(step_id)
	box.add_child(_check_box)
	return box


# Saves the pin choice to the project setting before the step writes .mcp.json.
# With neither box checked (a custom version) the setting is kept.
func _apply_pin_choice() -> void:
	var chosen := ""
	if _pinned_box != null and _pinned_box.button_pressed:
		chosen = MCPJsonSync.MODE_PINNED
	elif _latest_box != null and _latest_box.button_pressed:
		chosen = MCPJsonSync.MODE_LATEST
	else:
		return
	if MCPJsonSync.pin_mode(MCPJsonSync.read_version_setting()) == chosen:
		return
	MCPJsonSync.save_version_setting(
			MCPJsonSync.LATEST_SETTING_VALUE if chosen == MCPJsonSync.MODE_LATEST else "")


func _clear_content_refs() -> void:
	_content = null
	_pinned_box = null
	_latest_box = null
	_check_box = null


# -- Navigation ---------------------------------------------------------------


func _current_step() -> StringName:
	return _run[_index] if _index < _run.size() else &""


func _on_confirmed(dialog: AcceptDialog) -> void:
	var step_id := _current_step()
	if step_id == SetupSteps.MCP_JSON and not _mcp_exists:
		# The OK reads "Create .mcp.json" — write the file now. Fire-and-forget:
		# the wizard advances regardless, and a failed write keeps the dock's
		# "NO .mcp.json" warning visible as the durable signal.
		_apply_pin_choice()
		if _write_flow != null:
			_write_flow.write()
	if _check_box != null:
		_settings_store().apply(step_id, _check_box.button_pressed)
	_leave_step(dialog)


func _on_custom_action(action: StringName, dialog: AcceptDialog) -> void:
	match str(action):
		_BACK_ACTION:
			if _index > 0:
				_index -= 1
				_show_step(dialog)
		"overwrite_mcp":
			_apply_pin_choice()
			if _write_flow != null:
				_write_flow.write(false)
			_leave_step(dialog)
		"open_info":
			step_seen.emit(_current_step())
			free_if_open()
			if _dialog_presenter != null:
				_dialog_presenter.show_info(_server)
		"open_security":
			var doc_path := "res://addons/godot_mcp_toolkit/docs/security-recommendations.md"
			var global_path := ProjectSettings.globalize_path(doc_path)
			OS.shell_open(global_path)
		_REMIND_LATER_ACTION:
			free_if_open()


func _on_canceled() -> void:
	for step_id in SetupSteps.seen_on_close(_run, _index, _visited):
		step_seen.emit(step_id)
	free_if_open()


# Count the open step as seen, then show the next one, or close the wizard after
# the run's last step.
func _leave_step(dialog: AcceptDialog) -> void:
	step_seen.emit(_current_step())
	if _index >= _run.size() - 1:
		free_if_open()
		return
	_index += 1
	_show_step(dialog)
	# AcceptDialog auto-hides on confirmed, and stays up on a custom action.
	if not dialog.visible:
		dialog.popup_centered()
