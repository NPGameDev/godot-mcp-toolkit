@tool
extends EditorPlugin
## EditorPlugin entry point — thin orchestrator that delegates to PluginComposer.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const FileGuard = Modules.FileGuard
const SettingsRegistration := preload("res://addons/godot_mcp_toolkit/core/settings_registration.gd")
const OnboardingWizard := preload("res://addons/godot_mcp_toolkit/ui/onboarding_wizard.gd")
const PluginComposer := preload("res://addons/godot_mcp_toolkit/core/plugin_composer.gd")
const DockHost := preload("res://addons/godot_mcp_toolkit/core/dock_host.gd")
const ToolMenu := preload("res://addons/godot_mcp_toolkit/core/tool_menu.gd")
const DisableCleanupCoordinator := preload("res://addons/godot_mcp_toolkit/core/disable_cleanup_coordinator.gd")
const MCPJsonEnablePrompt := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_enable_prompt.gd")
const MCPJsonWriteFlow := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_write_flow.gd")
const AutoloadRegistration := preload("res://addons/godot_mcp_toolkit/core/autoload_registration.gd")
const SetupSteps = Modules.SetupSteps
const SetupStepTracker = Modules.SetupStepTracker

# The Handle that owns the composed collaborator graph and frees it in dispose().
# PluginComposer.compose() builds it; the orchestrator drives it and calls
# _handle.dispose() on exit.
var _handle = null

var _tool_menu: ToolMenu = null
var _wizard: OnboardingWizard = null
# Set by _enable_plugin(), which the editor calls only for a mid-session enable, and
# synchronously after _enter_tree, so the deferred _check_onboarding() sees it. A
# plugin loaded at editor start never gets the call.
var _enabled_mid_session: bool = false


func _enter_tree() -> void:
	# Brand line, not a log line: printed first so the version is stamped even if startup fails.
	print("Godot MCP Toolkit v%s — by NPGameDev · npgamedev.com" % get_plugin_version())

	# Lifecycle phase sequence. The "why this order" narrative lives here; the
	# composer owns the internal construction order of the graph it builds.
	Modules.EditorAccess.set_plugin(self)
	SettingsRegistration.register_all()

	# Re-assert "plugin enabled ⟹ runtime autoload registered" before the graph is
	# wired. _enable_plugin() only fires on the disabled→enabled toggle, so a project
	# opened already-enabled with the autoload missing (out-of-band project.godot edit,
	# VCS-propagated enabled flag, template) would silently run Mode A only. Placed
	# early — pre-compose() — so the heal's settings_changed emit fires with zero
	# listeners (the extension watcher and the other settings_changed consumers are
	# wired inside compose() below).
	AutoloadRegistration.ensure_registered()

	# Construct and wire the whole collaborator graph and register in the
	# system-wide registry. PluginComposer owns the graph's members and their
	# construction order.
	_handle = PluginComposer.compose(self, _on_user_path_changed, _on_setup_wizard_requested)

	# Tools > MCP Toolkit submenu + command palette (needs the server, dock, and
	# shared UI collaborators the composer just built).
	_tool_menu = ToolMenu.new(
			self, _handle.server(), _handle.dock(),
			_handle.write_flow(), _handle.dialog_presenter())
	_tool_menu.install()

	# -- Per-user EditorSettings --
	_register_editor_settings()

	# A local server build turns the connect-time version check off; follow the
	# setting live, so the next connection after a change already reflects it.
	_sync_skip_version_check()
	EditorInterface.get_editor_settings().settings_changed.connect(_sync_skip_version_check)

	# Warn about untested future Godot versions (but don't block).
	var _engine_ver := Modules.VersionUtils.get_engine_version_pair()
	if not Modules.VersionUtils.is_at_most(_engine_ver, Modules.VersionUtils.GODOT_TESTED_MAX_VERSION):
		push_warning(("[MCP] Godot %s detected - latest tested version is %s. "
			+ "The plugin will run normally but some features may behave unexpectedly. "
			+ "Please report issues at https://github.com/NPGameDev/godot-mcp-toolkit/issues")
			% [_engine_ver, Modules.VersionUtils.GODOT_TESTED_MAX_VERSION])

	_wizard = OnboardingWizard.new(
			self, _handle.server(), _handle.write_flow(), _handle.dialog_presenter())
	_wizard.step_seen.connect(_on_setup_step_seen)
	call_deferred("_check_onboarding")


# Show the setup steps due now, if any: every step for a new user, or the missed
# ones at an editor start.
func _check_onboarding() -> void:
	if _wizard == null:
		return
	var all_ids: Array[StringName] = SetupSteps.all_ids()
	var unseen: Array[StringName] = SetupStepTracker.get_unseen(all_ids)
	var show_optional := SetupSteps.shows_optional_steps(EditorInterface.get_editor_settings())
	_wizard.show_run(SetupSteps.plan_run(
			unseen, unseen.size() < all_ids.size(), show_optional, not _enabled_mid_session, false))


func _on_setup_step_seen(step_id: StringName) -> void:
	SetupStepTracker.mark_seen(step_id)


# The dock's Setup Wizard button: a run of every step, whatever has been seen. The
# wizard is built after the dock, so a press before then does nothing.
func _on_setup_wizard_requested() -> void:
	if _wizard == null:
		return
	_wizard.show_run(SetupSteps.plan_button_run())


# Reveal the toolkit dock (select its tab + expand the bottom panel). The
# onboarding wizard's final step calls this; delegating through DockHost keeps the
# editor↔version dock seam in one adapter instead of leaking make_visible here.
func reveal_dock() -> void:
	if _handle != null:
		DockHost.reveal(self, _handle.dock(), _handle.dock_host())


func _process(_delta: float) -> void:
	if _handle != null:
		_handle.poll_playtest()


# Mirror "a local server build is configured" onto the server, which keeps no
# EditorSettings reads of its own.
func _sync_skip_version_check() -> void:
	if _handle != null and _handle.server() != null:
		_handle.server().skip_version_check = MCPJsonWriteFlow.uses_local_server()


func _on_user_path_changed() -> void:
	# Static consumers that can't connect to signals themselves.
	# Instance consumers (feature_settings, server) connect directly
	# via bind_user_path_monitor().
	SetupStepTracker.migrate_flag_after_rename()
	Modules.LogBuffer.reset_tail_path()


func _exit_tree() -> void:
	# Teardown symmetry — reverse order of _enter_tree's phases.
	# Onboarding wizard (if still open) — teardown() frees the dialog immediately so
	# it can't outlive ObjectDB's exit-time leak check.
	if _wizard != null:
		_wizard.teardown()
		_wizard = null

	# The editor-settings watch (the EditorSettings singleton outlives this plugin).
	var editor_settings := EditorInterface.get_editor_settings()
	if editor_settings.settings_changed.is_connected(_sync_skip_version_check):
		editor_settings.settings_changed.disconnect(_sync_skip_version_check)

	# Menus + command palette.
	if _tool_menu != null:
		_tool_menu.uninstall()
		_tool_menu = null

	# Composed graph, disposed in reverse construction order (the order lives in
	# PluginComposer).
	if _handle != null:
		_handle.dispose()
		_handle = null

	# Plugin reference — clear last (teardown symmetry with _enter_tree).
	Modules.EditorAccess.clear_plugin()


func _enable_plugin() -> void:
	_enabled_mid_session = true

	# First-enable registration shares the on-load self-heal path so the two can never
	# diverge — an undo-free set_setting + save that persists to project.godot, which
	# is what the game reads at F5 (rationale lives in AutoloadRegistration).
	AutoloadRegistration.ensure_registered()

	# Offer to (re)create a missing .mcp.json — on the enable toggle only, never
	# on project open. The editor adds the plugin to the tree before calling
	# _enable_plugin, so the composed graph (and its write flow) already exists.
	if _handle != null:
		MCPJsonEnablePrompt.show_if_needed(_handle.write_flow())


func _disable_plugin() -> void:
	AutoloadRegistration.unregister(self)

	# Scrub the project-local mcp_toolkit/* ProjectSettings unconditionally —
	# they belong to project.godot and are meaningless once the plugin is gone.
	# (EditorSettings are machine-wide and need a confirm — see below.)
	SettingsRegistration.unregister_all()

	# Warn about an orphaned .mcp.json, then (chained off its resolution) about
	# the machine-wide EditorSettings keys. The editor frees THIS plugin the
	# instant this method returns (and _exit_tree runs) — before the user answers
	# the prompts — so the sequence must NOT be driven by plugin-bound callbacks
	# (they would fire into a freed object and silently no-op). Hand it to a
	# detached coordinator that outlives the plugin and owns the dialog flow.
	DisableCleanupCoordinator.new().start()


# -- EditorSettings registration (per-user, not committed to VCS) -------------


func _register_editor_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	# [type, default, hint_string]. These live in EDITOR Settings (per-user,
	# machine-wide), NOT Project Settings: the unfocused-responsive keys control a
	# machine-global editor effect and are a personal battery/CPU preference, the
	# local server path names a folder on this machine, and showing optional setup
	# steps is a personal preference across projects, so they must never be
	# committed to project.godot / VCS.
	var settings := {
		"mcp_toolkit/performance/keep_editor_responsive_unfocused": [TYPE_BOOL, true,
			"Keep the editor responsive (raise its unfocused frame rate) while an MCP client is connected, so commands stay snappy when the editor is unfocused. Off uses Godot's default low-power unfocused throttle. Raises background CPU. A toggle is also in the MCP Toolkit dock."],
		"mcp_toolkit/performance/unfocused_responsive_sleep_usec": [TYPE_INT, 16666,
			"Unfocused process sleep in µs applied while a client is connected (lower = higher fps = snappier but more CPU). 16666 ≈ 60 fps (default); 33333 ≈ 30 fps (power-saver). Not clamped."],
		MCPJsonWriteFlow.LOCAL_PATH_SETTING: [TYPE_STRING, "",
			"Absolute path to a local server build's dist/index.js (this machine only). Empty = the npm package. Falls back to the GODOT_MCP_DEV_SERVER_PATH environment variable. A local build turns the editor's version check off right away, and the server's after the next Write .mcp.json."],
		SetupSteps.SHOW_OPTIONAL_STEPS_SETTING: [TYPE_BOOL, true,
			"Show optional steps added by toolkit updates, in any project on this machine. Required steps still show. A toggle is also in the MCP Toolkit dock."],
	}
	for key in settings:
		if not es.has_setting(key):
			es.set_setting(key, settings[key][1])
		es.set_initial_value(key, settings[key][1], false)
		var info := {"name": key, "type": settings[key][0]}
		if settings[key][2] != "":
			info["hint"] = PROPERTY_HINT_NONE
			info["hint_string"] = settings[key][2]
		es.add_property_info(info)
