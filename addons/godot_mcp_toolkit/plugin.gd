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
const AutoloadRegistration := preload("res://addons/godot_mcp_toolkit/core/autoload_registration.gd")

# The composed collaborator graph (server, dock, export plugin, watchers, debug
# bridge, user-path monitor, playtest watcher). PluginComposer.compose() builds
# it; the orchestrator drives it and calls _handle.dispose() on exit.
var _handle = null

var _tool_menu: ToolMenu = null
var _wizard: OnboardingWizard = null


func _enter_tree() -> void:
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

	# Construct + wire the whole collaborator graph (registry, server, debug
	# bridge, command registrar, extensions, export plugin, log buffer, user-path
	# monitor, registry registration, playtest watcher, write flow + dialog
	# presenter, dock) and register in the system-wide registry.
	_handle = PluginComposer.compose(self, _on_user_path_changed)

	# Tools > MCP Toolkit submenu + command palette (needs the server, dock, and
	# shared UI collaborators the composer just built).
	_tool_menu = ToolMenu.new(
			self, _handle.server(), _handle.dock(),
			_handle.write_flow(), _handle.dialog_presenter())
	_tool_menu.install()

	# -- Per-user EditorSettings --
	_register_editor_settings()

	# Warn about untested future Godot versions (but don't block).
	var _engine_ver := Modules.VersionUtils.get_engine_version_pair()
	if not Modules.VersionUtils.is_at_most(_engine_ver, Modules.VersionUtils.GODOT_TESTED_MAX_VERSION):
		push_warning(("[MCP] Godot %s detected - latest tested version is %s. "
			+ "The plugin will run normally but some features may behave unexpectedly. "
			+ "Please report issues at https://github.com/NPGameDev/godot-mcp-toolkit/issues")
			% [_engine_ver, Modules.VersionUtils.GODOT_TESTED_MAX_VERSION])

	_wizard = OnboardingWizard.new(
			self, _handle.server(), _handle.write_flow(), _handle.dialog_presenter())
	call_deferred("_check_onboarding")


func _check_onboarding() -> void:
	_wizard.check_and_show()


# Reveal the toolkit dock (select its tab + expand the bottom panel). The
# onboarding wizard's final step calls this; delegating through DockHost keeps the
# editor↔version dock seam in one adapter instead of leaking make_visible here.
func reveal_dock() -> void:
	if _handle != null:
		DockHost.reveal(self, _handle.dock(), _handle.dock_host())


func _process(_delta: float) -> void:
	if _handle != null:
		_handle.poll_playtest()


func _on_user_path_changed() -> void:
	# Static consumers that can't connect to signals themselves.
	# Instance consumers (feature_settings, server) connect directly
	# via bind_user_path_monitor().
	OnboardingWizard.migrate_flag_after_rename()
	Modules.LogBuffer.reset_tail_path()


func _exit_tree() -> void:
	# Teardown symmetry — reverse order of _enter_tree's phases.
	# Onboarding wizard (if still open).
	if _wizard != null:
		_wizard.free_if_open()
		_wizard = null

	# Menus + command palette.
	if _tool_menu != null:
		_tool_menu.uninstall()
		_tool_menu = null

	# Composed graph (dock, monitor, watchers, debug bridge, export plugin,
	# server + registry) — disposed in reverse construction order.
	if _handle != null:
		_handle.dispose()
		_handle = null

	# Plugin reference — clear last (teardown symmetry with _enter_tree).
	Modules.EditorAccess.clear_plugin()


func _enable_plugin() -> void:
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
	# machine-global editor effect and are a personal battery/CPU preference, so
	# they must never be committed to project.godot / VCS.
	var settings := {
		"mcp_toolkit/personal/dock_default_visible": [TYPE_BOOL, true, ""],
		"mcp_toolkit/performance/keep_editor_responsive_unfocused": [TYPE_BOOL, true,
			"Keep the editor responsive (raise its unfocused frame rate) while an MCP client is connected, so commands stay snappy when the editor is unfocused. Off uses Godot's default low-power unfocused throttle. Raises background CPU. A toggle is also in the MCP Toolkit dock."],
		"mcp_toolkit/performance/unfocused_responsive_sleep_usec": [TYPE_INT, 16666,
			"Unfocused process sleep in µs applied while a client is connected (lower = higher fps = snappier but more CPU). 16666 ≈ 60 fps (default); 33333 ≈ 30 fps (power-saver). Not clamped."],
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
