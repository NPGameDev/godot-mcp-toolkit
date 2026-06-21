@tool
extends EditorPlugin

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const FileGuard = _Hub.FileGuard
const RegistryClient = _Hub.RegistryClient
const MCPServer := preload("res://addons/godot_mcp_toolkit/mcp_server.gd")
const MCPAuth := preload("res://addons/godot_mcp_toolkit/auth.gd")
const SettingsRegistration := preload("res://addons/godot_mcp_toolkit/settings_registration.gd")
const SettingsNavigator := preload("res://addons/godot_mcp_toolkit/ui/settings_navigator.gd")
const OnboardingWizard := preload("res://addons/godot_mcp_toolkit/ui/onboarding_wizard.gd")
const ExtensionLoader := preload("res://addons/godot_mcp_toolkit/extension_loader.gd")
const CommandRegistrar := preload("res://addons/godot_mcp_toolkit/command_registrar.gd")
const PlaytestWatcher := preload("res://addons/godot_mcp_toolkit/playtest_watcher.gd")
const DebugBridge := preload("res://addons/godot_mcp_toolkit/debug_bridge.gd")
# Retained (not moved to the registrar): _exit_tree calls PlaytestCommands.clear_debug_bridge()
# as the I12 teardown counterpart of its register(..., _debug_bridge) — a teardown op, not a
# registration, so it stays with the debug-bridge teardown here. The registrar keeps its own
# preload for the register call (preload is resource-idempotent).
const PlaytestCommands := preload("res://addons/godot_mcp_toolkit/commands/playtest_commands.gd")

# Mode B — runtime autoload that hosts the game-side WS server on
# 127.0.0.1:6570. Registered/unregistered via add_autoload_singleton /
# remove_autoload_singleton so end-user installs pick it up when they
# tick the plugin. Idempotent: if project.godot already carries the entry
# (e.g., dogfood), Godot keeps the existing value rather than duplicating.
const RUNTIME_AUTOLOAD_NAME := "MCPRuntimeServer"
const RUNTIME_AUTOLOAD_PATH := "res://addons/godot_mcp_toolkit/runtime/mcp_runtime_server.gd"

# Data-driven menu / command-palette registration.
# "label" is the command-palette name (prefixed for discoverability);
# "menu_label" is the short name shown inside the Tools > MCP Toolkit submenu.
const _ACTIONS := [
	{"label": "MCP Toolkit: Regenerate Token", "menu_label": "Regenerate Token", "key": "mcp/regenerate_token", "method": "_on_regen_token"},
	{"label": "MCP Toolkit: Show Audit Log", "menu_label": "Show Audit Log", "key": "mcp/show_audit_log", "method": "_on_show_audit"},
	{"label": "MCP Toolkit: Open Project Settings", "menu_label": "Open Project Settings", "key": "mcp/open_settings", "method": "_on_open_settings"},
	{"label": "MCP Toolkit: Write .mcp.json", "menu_label": "Write .mcp.json", "key": "mcp/write_mcp_json", "method": "_on_write_mcp_json"},
	{"label": "MCP Toolkit: Extension Catalog", "menu_label": "Extension Catalog...", "key": "mcp/extension_catalog", "method": "_on_extension_catalog"},
]

var _tool_submenu: PopupMenu = null

var _server: Node = null
var _export_plugin: EditorExportPlugin = null
var _dock: Control = null
var _wizard: OnboardingWizard = null
var _extension_watcher: RefCounted = null  # Live hot-reload watcher (ExtensionLoader)
var _debug_bridge: RefCounted = null  # EditorDebuggerPlugin for debug.* commands
var _user_path_monitor = null  # UserPathMonitor — detects config/name changes
var _playtest_watcher: PlaytestWatcher = null  # Edge-detects the play→stop transition


func _enter_tree() -> void:
	_Hub.EditorAccess.set_plugin(self)
	SettingsRegistration.register_all()

	var registry := MCPToolkitCommandRegistry.new()
	_server = MCPServer.new()
	_server.name = "MCPServer"
	_server.set_registry(registry)
	_server.editor_plugin = self

	# Debugger bridge — create early so command registrars can reference it.
	_debug_bridge = DebugBridge.new()
	add_debugger_plugin(_debug_bridge)

	CommandRegistrar.register_all(registry, _server, _debug_bridge)

	# Third-party extensions — profile-exempt, always loaded.
	ExtensionLoader.load_all(registry, _server)
	# Live hot-reload: watch EditorFileSystem for extension additions/removals.
	_extension_watcher = ExtensionLoader.start_watcher(registry, _server)

	_export_plugin = preload("res://addons/godot_mcp_toolkit/export_strip.gd").new()
	add_export_plugin(_export_plugin)

	_Hub.LogBuffer.setup()

	# Monitor the ProjectSettings that shift user:// paths (config/name,
	# use_custom_user_dir, custom_user_dir_name). Each consumer connects
	# directly and handles its own recovery.
	_user_path_monitor = _Hub.UserPathMonitor.new()
	_user_path_monitor.start()
	_user_path_monitor.user_path_changed.connect(_on_user_path_changed)

	# Edge-detects the play→stop transition; polled each _process.
	_playtest_watcher = PlaytestWatcher.new(_server)

	add_child(_server)
	_server.bind_user_path_monitor(_user_path_monitor)
	# After a user-path change the server re-writes its token and announces the new
	# path; we re-publish the registry entry runtime-preservingly (ensure_registered,
	# not register) so a game running across the rename keeps Mode-B discovery.
	_server.token_rewritten.connect(_on_token_rewritten)
	_server.start()

	# Register in the system-wide project registry so the TS bridge can
	# discover us by project path. Must come after start() — port unknown
	# until _scan_and_listen() runs.
	var bound_port: int = _server.get_bound_port()
	if bound_port > 0:
		var lsp := MCPServer.resolve_lsp_endpoint()
		RegistryClient.register(bound_port, MCPAuth.get_token_path(), lsp["host"], lsp["port"])
		# Deferred re-verify: concurrent editors may clobber our entry after
		# our initial verify passes. Jittered delay ensures all editors have
		# finished their initial registration before we re-check. Re-resolve the
		# LSP endpoint at fire time so a mid-window Q4 change isn't reverted.
		var _jitter := randf_range(5.0, 10.0)
		get_tree().create_timer(_jitter).timeout.connect(
			func():
				var lsp_re := MCPServer.resolve_lsp_endpoint()
				RegistryClient.ensure_registered(bound_port, MCPAuth.get_token_path(), lsp_re["host"], lsp_re["port"]))

	# -- Bottom-panel dock --
	_dock = preload("res://addons/godot_mcp_toolkit/ui/dock.tscn").instantiate()
	_dock.bind(_server, _Hub.Audit.get_log_path())
	add_control_to_bottom_panel(_dock, "MCP Toolkit")

	_register_menus()

	# -- Per-user EditorSettings --
	_register_editor_settings()

	# Warn about untested future Godot versions (but don't block).
	var _engine_ver := _Hub.VersionUtils.get_engine_version_pair()
	if not _Hub.VersionUtils.is_at_most(_engine_ver, _Hub.VersionUtils.GODOT_TESTED_MAX_VERSION):
		push_warning(("[MCP] Godot %s detected — latest tested version is %s. "
			+ "The plugin will run normally but some features may behave unexpectedly. "
			+ "Please report issues at https://github.com/NPGameDev/godot-mcp-toolkit/issues")
			% [_engine_ver, _Hub.VersionUtils.GODOT_TESTED_MAX_VERSION])

	_wizard = OnboardingWizard.new(self, _dock)
	call_deferred("_check_onboarding")


func _check_onboarding() -> void:
	_wizard.check_and_show()


func _process(_delta: float) -> void:
	_playtest_watcher.poll()


func _on_user_path_changed() -> void:
	# Static consumers that can't connect to signals themselves.
	# Instance consumers (feature_settings, server) connect directly
	# via bind_user_path_monitor().
	OnboardingWizard.migrate_flag_after_rename()
	_Hub.LogBuffer.reset_tail_path()


# Re-publish this editor's registry entry after the server re-writes its token to
# a new user:// path. ensure_registered (not register) so an active playtest's
# runtime_port/runtime_pid are preserved — otherwise Mode-B (running-game)
# discovery dies for the rest of the session. Re-resolve the LSP endpoint at fire
# time, mirroring the startup registration, so a concurrent endpoint change isn't
# reverted to a stale value.
func _on_token_rewritten(token_path: String) -> void:
	if _server == null:
		return
	var bound_port: int = _server.get_bound_port()
	if bound_port <= 0:
		return
	var lsp := MCPServer.resolve_lsp_endpoint()
	RegistryClient.ensure_registered(bound_port, token_path, lsp["host"], lsp["port"])


func _exit_tree() -> void:
	# Teardown symmetry — reverse order of _enter_tree registrations.
	# Onboarding wizard (if still open).
	if _wizard != null:
		_wizard.free_if_open()
		_wizard = null

	# Menus + command palette.
	_unregister_menus()

	# Dock — remove from panel, then free() immediately (not queue_free())
	# so its script preload chain is released before ObjectDB's exit-time
	# leak check runs.
	if _dock != null:
		remove_control_from_bottom_panel(_dock)
		_dock.free()
		_dock = null

	# RefCounted subsystems — drop our references so they can be collected
	# once the dock (which also holds them) is freed above.
	if _user_path_monitor != null:
		_user_path_monitor.stop()
		_user_path_monitor = null

	# Playtest watcher (RefCounted — just null) — drop before server teardown
	# since it holds a server reference.
	_playtest_watcher = null

	# Extension watcher — disconnect global signals, then drop before server
	# teardown (holds registry ref). Without explicit disconnect, the
	# filesystem_changed / settings_changed handlers become zombie callbacks.
	if _extension_watcher != null:
		var efs := EditorInterface.get_resource_filesystem()
		if efs.filesystem_changed.is_connected(_extension_watcher.on_filesystem_changed):
			efs.filesystem_changed.disconnect(_extension_watcher.on_filesystem_changed)
		if ProjectSettings.settings_changed.is_connected(_extension_watcher.on_settings_changed):
			ProjectSettings.settings_changed.disconnect(_extension_watcher.on_settings_changed)
	_extension_watcher = null

	# Debugger bridge — unregister before server teardown (I12 symmetry).
	PlaytestCommands.clear_debug_bridge()
	if _debug_bridge != null:
		_debug_bridge.cleanup()
		remove_debugger_plugin(_debug_bridge)
		_debug_bridge = null

	# Export plugin (RefCounted — do NOT queue_free, just null).
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null

	# Server + registry — clear command registry first to break the
	# Callable → GDScript reference chains, then free() immediately.
	# queue_free() alone causes "resources still in use at exit" because
	# deferred deletion runs after ObjectDB's leak check.
	if _server != null:
		_server.stop()
		_server.clear_registry()
		RegistryClient.deregister()
		_server.free()
		_server = null

	# Plugin reference — clear last (teardown symmetry with _enter_tree).
	_Hub.EditorAccess.clear_plugin()


func _enable_plugin() -> void:
	add_autoload_singleton(RUNTIME_AUTOLOAD_NAME, RUNTIME_AUTOLOAD_PATH)


func _disable_plugin() -> void:
	remove_autoload_singleton(RUNTIME_AUTOLOAD_NAME)

	# Warn about orphaned .mcp.json.
	var mcp_json_path := ProjectSettings.globalize_path("res://") + ".mcp.json"
	if FileAccess.file_exists(mcp_json_path):
		var dialog := ConfirmationDialog.new()
		dialog.exclusive = false
		dialog.title = "MCP Plugin Disabled"
		dialog.dialog_text = (
			"The .mcp.json configuration file is still at your project root:\n"
			+ mcp_json_path + "\n\n"
			+ "If you're uninstalling the plugin, you may want to remove it.\n"
			+ "If you're just disabling temporarily, keep it.")
		dialog.ok_button_text = "Delete .mcp.json"
		dialog.cancel_button_text = "Keep"
		dialog.confirmed.connect(func():
			DirAccess.remove_absolute(mcp_json_path)
			print("[MCP] Deleted .mcp.json at %s" % mcp_json_path)
			dialog.queue_free()
		)
		dialog.canceled.connect(func():
			print("[MCP] .mcp.json kept at %s" % mcp_json_path)
			dialog.queue_free()
		)
		EditorInterface.get_base_control().add_child(dialog)
		dialog.popup_centered()


# -- Menu registration ---------------------------------------------------------


func _register_menus() -> void:
	# Tools > MCP Toolkit submenu.
	_tool_submenu = PopupMenu.new()
	_tool_submenu.name = "MCPToolkitMenu"
	for i in _ACTIONS.size():
		_tool_submenu.add_item(_ACTIONS[i]["menu_label"], i)
	_tool_submenu.id_pressed.connect(_on_submenu_id_pressed)
	add_tool_submenu_item("MCP Toolkit", _tool_submenu)
	# -- Command Palette (4.0+; guard anyway for safety) --
	if EditorInterface.has_method("get_command_palette"):
		var palette = EditorInterface.call("get_command_palette")
		if palette != null:
			for action in _ACTIONS:
				palette.add_command(
					action["label"], action["key"],
					Callable(self, action["method"]))


func _unregister_menus() -> void:
	# Command Palette.
	if EditorInterface.has_method("get_command_palette"):
		var palette = EditorInterface.call("get_command_palette")
		if palette != null:
			for action in _ACTIONS:
				palette.remove_command(action["key"])
	# Submenu.
	remove_tool_menu_item("MCP Toolkit")
	if _tool_submenu != null:
		_tool_submenu.queue_free()
		_tool_submenu = null


# -- Submenu router ------------------------------------------------------------


func _on_submenu_id_pressed(id: int) -> void:
	if id >= 0 and id < _ACTIONS.size():
		Callable(self, _ACTIONS[id]["method"]).call()


# -- Menu handlers -------------------------------------------------------------


func _on_regen_token() -> void:
	if _server != null:
		_server.regenerate_token()
		print("[MCP] Token rotated")
		var toaster = _Hub.EditorAccess.get_toaster()
		if toaster != null:
			toaster.push_toast("MCP token rotated", 0)


func _on_show_audit() -> void:
	if _dock != null:
		_dock.show_audit_dialog()
	else:
		var global_path := ProjectSettings.globalize_path(_Hub.Audit.get_log_path())
		OS.shell_open(global_path)


func _on_open_settings() -> void:
	SettingsNavigator.open_mcp_settings()


func _on_write_mcp_json() -> void:
	if _dock != null:
		_dock.write_mcp_json()


func _on_extension_catalog() -> void:
	if _dock != null:
		_dock.show_extension_catalog()


# -- EditorSettings registration (per-user, not committed to VCS) -------------


func _register_editor_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	# [type, default, hint_string]. These live in EDITOR Settings (per-user,
	# machine-wide), NOT Project Settings: the unfocused-responsive keys control a
	# machine-global editor effect and are a personal battery/CPU preference, so
	# they must never be committed to project.godot / VCS. See ADR 0007.
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
