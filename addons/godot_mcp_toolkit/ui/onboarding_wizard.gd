@tool
extends RefCounted
## Guided onboarding wizard shown on first plugin activation.
## Self-contained state machine managing a multi-step AcceptDialog.

const NodejsCheck := preload("res://addons/godot_mcp_toolkit/versioning/nodejs_check.gd")
const SettingsNavigator := preload("res://addons/godot_mcp_toolkit/ui/settings_navigator.gd")
const MCPJsonWriteFlow := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_write_flow.gd")
const ToolkitDialogPresenter := preload("res://addons/godot_mcp_toolkit/ui/toolkit_dialog_presenter.gd")

const _ONBOARDING_FLAG := "user://addons/godot_mcp_toolkit/mcp_onboarding_shown_v001"
const _ONBOARDING_PROGRESS := "user://addons/godot_mcp_toolkit/mcp_onboarding_progress"
const _STEP_COUNT := 4

var _plugin: EditorPlugin
var _server: Node  # Passed to the dialog presenter's Info / Help dialog.
var _write_flow: MCPJsonWriteFlow
var _dialog_presenter: ToolkitDialogPresenter
var _dialog: AcceptDialog = null
var _step: int = 0
var _mcp_exists: bool = false  # Tracks .mcp.json state for step-1 variants.
# Tracks whether the final macOS-setup step is relevant for this host (macOS with
# an unresolved login-shell Node). Set when step 2's spec is built and read by
# navigation to skip the step when it doesn't apply.
var _macos_help_needed: bool = false
var _buttons: Array = []  # Tracked custom buttons for per-step cleanup.


func _init(
		plugin: EditorPlugin, server: Node,
		write_flow: MCPJsonWriteFlow, dialog_presenter: ToolkitDialogPresenter) -> void:
	_plugin = plugin
	_server = server
	_write_flow = write_flow
	_dialog_presenter = dialog_presenter


func check_and_show() -> void:
	if is_onboarding_complete():
		return

	# Decide up front whether the final macOS-setup step applies, so every render
	# (from step 0 and on a resumed session) can show the EFFECTIVE step total and
	# the resume clamp targets the effective last index.
	_probe_macos_help_needed()

	# Resume from saved progress (e.g. after restart during wizard).
	_step = 0
	if FileAccess.file_exists(_ONBOARDING_PROGRESS):
		var f := FileAccess.open(_ONBOARDING_PROGRESS, FileAccess.READ)
		if f != null:
			_step = clampi(f.get_line().to_int(), 0, _effective_step_count() - 1)
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


# Mid-session dismissal — every in-wizard caller runs inside one of the dialog's OWN
# signal callbacks (confirmed / custom_action / canceled), where an immediate free()
# would delete the emitter mid-emission; queue_free() is the legal form there. Plugin
# teardown uses teardown() instead (immediate free — see below).
func free_if_open() -> void:
	_buttons.clear()
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.queue_free()
	_dialog = null


# Plugin-teardown counterpart of free_if_open(): immediate free(), not queue_free().
# This runs on the plugin's _exit_tree path, outside any dialog signal emission, and a
# deferred delete would hold the dialog's button/confirm connections (and this wizard
# instance) past ObjectDB's exit-time leak check → spurious "resources still in use
# at exit". The dialog may be an open popup — free() closes and deletes it in one step.
func teardown() -> void:
	_buttons.clear()
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.free()
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
			# The overview spec is unchanged; only its OK caption flips to "Next" when
			# a further macOS page follows (_macos_help_needed is set at wizard start).
			var overview_spec := _spec_dock_overview()
			if _macos_help_needed:
				overview_spec["ok_label"] = "Next"
			return overview_spec
		3:
			return _spec_macos_setup()
	return {}


# Pure: the final macOS-setup step is relevant only when the host is macOS AND Node
# couldn't be resolved from a login shell ([param resolved_node] empty) — i.e. a
# GUI-launched client won't find Node (launchd's minimal PATH). Every other case
# skips the step so the wizard finishes without an irrelevant page.
static func _macos_setup_needs_help(os_name: String, resolved_node: String) -> bool:
	return os_name == "macOS" and resolved_node.is_empty()


# Resolve whether the final macOS-setup step applies for this host and cache it in
# _macos_help_needed. Run once at wizard start (the login-shell probe is a subprocess
# on macOS and a no-op elsewhere), so every render and the resume clamp can rely on it.
func _probe_macos_help_needed() -> void:
	var resolved := NodejsCheck.resolve_launch_paths()
	_macos_help_needed = _macos_setup_needs_help(OS.get_name(), str(resolved.get("node", "")))


# The number of steps the wizard will actually show: the full count only when the
# macOS-setup step applies, else one fewer (that step is skipped). Drives both the
# "Step X of N" title and the resume clamp so a good-setup host never sees "of 4".
func _effective_step_count() -> int:
	return _STEP_COUNT if _macos_help_needed else _STEP_COUNT - 1


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
		if _plugin != null:
			_plugin.call("reveal_dock")  # dynamic dispatch: base EditorPlugin lacks reveal_dock
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
				+ "dock's Server Status, or in Editor Settings → Mcp Toolkit → Performance.\n\n"
				+ "The dock's limits and audit controls are shortcuts into\n"
				+ "Project Settings → Mcp Toolkit, where all per-project options\n"
				+ "live (including advanced ones the dock doesn't surface).\n\n"
				+ "You're all set!"),
		"ok_label": "Close",
		"buttons": [
			{"label": "Back", "action": "back"},
			{"label": "Open Info", "action": "open_info"},
		],
	}
	spec["on_enter"] = reveal_dock
	return spec


# The opt-in macOS-setup page (final step) — shown only when _macos_setup_needs_help
# holds. Calm and non-forcing: it names the launchd minimal-PATH cause and the fix
# options, with an "Open setup guide" button; nothing is done automatically.
func _spec_macos_setup() -> Dictionary:
	return {
		"text": (
				"Almost done — one macOS setup note.\n\n"
				+ "The toolkit couldn't resolve your Node.js from a login shell. On macOS, "
				+ "an app launched from Finder, the Dock, or Spotlight runs with a minimal "
				+ "PATH and doesn't source your shell startup files, so a version-manager "
				+ "Node (nvm/fnm/volta) stays invisible — your MCP client won't be able to "
				+ "start the server.\n\n"
				+ "To fix it, pick whichever fits your setup:\n\n"
				+ "  • Move your version-manager init into ~/.zprofile — a login shell "
				+ "sources it, so the toolkit can resolve Node.\n"
				+ "  • Or install Node from the official nodejs.org installer — it lands "
				+ "on the default PATH, so no shell setup is needed.\n"
				+ "  • Or launch the editor and client from a terminal, which inherits "
				+ "your PATH.\n\n"
				+ "Open the setup guide for step-by-step details."),
		"ok_label": "Finish",
		"buttons": [
			{"label": "Back", "action": "back"},
			{"label": "Open setup guide", "action": "open_macos_guide"},
		],
	}


# Render the current step's spec onto the dialog. Owns the boilerplate every step
# shares: title, previous-button cleanup, text + ok-label, and add+track of each
# custom button (tracking happens here, so a button can never leak from the
# per-step cleanup loop). on_enter, if present, fires before the caller pops up.
func _show_step(dialog: AcceptDialog) -> void:
	dialog.title = "MCP Toolkit — Setup Wizard (%d of %d)" % [
		_step + 1, _effective_step_count()]

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
		# Step 1 OK = "Create .mcp.json" — write the file now. Fire-and-forget:
		# the wizard advances regardless, and a failed write keeps the dock's
		# "NO .mcp.json" warning visible as the durable signal.
		if _write_flow != null:
			_write_flow.write()
	if _is_last_relevant_step():
		# Final relevant step — finish (the macOS-setup page is skipped when it
		# doesn't apply, so the dock-overview step is the last one for most hosts).
		_write_flag()
		free_if_open()
		return
	_step += 1
	_save_progress()
	_show_step(dialog)
	# AcceptDialog auto-hides on confirmed — re-show for the next step.
	dialog.popup_centered()


# True when the current step is the last one the wizard will show. The macOS-setup
# page (the final _STEP_COUNT step) is conditional: on a host where it doesn't apply
# (_macos_help_needed false — set when the dock-overview step's spec was built), the
# dock-overview step before it is the effective last page, so confirming it finishes.
func _is_last_relevant_step() -> bool:
	if _step >= _STEP_COUNT - 1:
		return true
	if _step == _STEP_COUNT - 2:
		return not _macos_help_needed
	return false


func _on_custom_action(action: StringName, dialog: AcceptDialog) -> void:
	match str(action):
		"back":
			if _step > 0:
				_step -= 1
				_save_progress()
				_show_step(dialog)
		"overwrite_mcp":
			if _write_flow != null:
				_write_flow.write(true)
			_step += 1
			_save_progress()
			_show_step(dialog)
		"open_info":
			_write_flag()
			free_if_open()
			if _dialog_presenter != null:
				_dialog_presenter.show_info(_server)
		"open_security":
			var doc_path := "res://addons/godot_mcp_toolkit/docs/security-recommendations.md"
			var global_path := ProjectSettings.globalize_path(doc_path)
			OS.shell_open(global_path)
		# Opt-in: open the macOS setup guide (advanced_configuration.md carries the
		# launchd/PATH section) and leave the wizard open so the user can still
		# Finish. Mirrors "open_security" — nothing forced.
		"open_macos_guide":
			var guide_path := "res://addons/godot_mcp_toolkit/docs/advanced_configuration.md"
			OS.shell_open(ProjectSettings.globalize_path(guide_path))


# -- Persistence --------------------------------------------------------------


## True once onboarding has finished (the wizard was completed or dismissed).
## The one shared query on the completion flag: check_and_show() gates on it,
## and the enable-time .mcp.json prompt suppresses itself while onboarding is
## still pending (the wizard's own .mcp.json step owns the file then).
static func is_onboarding_complete() -> bool:
	return FileAccess.file_exists(_ONBOARDING_FLAG)


## Re-create the onboarding completion flag at the new user:// path after a
## user:// path shift (config/name, use_custom_user_dir, or custom_user_dir_name
## change). Prevents the wizard from re-showing once the path moves.
## Dirs are guaranteed to exist (UserPathMonitor calls ensure_dirs() before
## emitting the signal).
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
