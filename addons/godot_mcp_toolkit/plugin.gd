@tool
extends EditorPlugin

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPFileGuard = _Hub.MCPFileGuard
const MCPRegistryClient = _Hub.MCPRegistryClient
const MCPServer := preload("res://addons/godot_mcp_toolkit/mcp_server.gd")
const MCPAuth := preload("res://addons/godot_mcp_toolkit/auth.gd")
const SettingsMigration := preload("res://addons/godot_mcp_toolkit/settings_migration.gd")
const FeatureGateSettings := preload("res://addons/godot_mcp_toolkit/feature_gate_settings.gd")
const GateEvents := preload("res://addons/godot_mcp_toolkit/gate_events.gd")
const SettingsNavigator := preload("res://addons/godot_mcp_toolkit/ui/settings_navigator.gd")
const OnboardingWizard := preload("res://addons/godot_mcp_toolkit/ui/onboarding_wizard.gd")
const GateNotifier := preload("res://addons/godot_mcp_toolkit/gate_notifier.gd")
const ExtensionLoader := preload("res://addons/godot_mcp_toolkit/extension_loader.gd")
const SceneCommands := preload("res://addons/godot_mcp_toolkit/commands/scene_commands.gd")
const NodeCommands := preload("res://addons/godot_mcp_toolkit/commands/node_commands.gd")
const ScriptCommands := preload("res://addons/godot_mcp_toolkit/commands/script_commands.gd")
const EditorCommands := preload("res://addons/godot_mcp_toolkit/commands/editor_commands.gd")
const ResourceCommands := preload("res://addons/godot_mcp_toolkit/commands/resource_commands.gd")
const FolderCommands := preload("res://addons/godot_mcp_toolkit/commands/folder_commands.gd")
const FileCommands := preload("res://addons/godot_mcp_toolkit/commands/file_commands.gd")
const SignalCommands := preload("res://addons/godot_mcp_toolkit/commands/signal_commands.gd")
const PlaytestCommands := preload("res://addons/godot_mcp_toolkit/commands/playtest_commands.gd")
const ProjectCommands := preload("res://addons/godot_mcp_toolkit/commands/project_commands.gd")
const InputMapCommands := preload("res://addons/godot_mcp_toolkit/commands/input_map_commands.gd")
const AnimationCommands := preload("res://addons/godot_mcp_toolkit/commands/animation_commands.gd")
const TilemapCommands := preload("res://addons/godot_mcp_toolkit/commands/tilemap_commands.gd")
const AssetCommands := preload("res://addons/godot_mcp_toolkit/commands/asset_commands.gd")
const SaveCommands := preload("res://addons/godot_mcp_toolkit/commands/save_commands.gd")
const ClassdbCommands := preload("res://addons/godot_mcp_toolkit/commands/classdb_commands.gd")
const ThemeCommands := preload("res://addons/godot_mcp_toolkit/commands/theme_commands.gd")
const PathCommands := preload("res://addons/godot_mcp_toolkit/commands/path_commands.gd")
const ThreeDCommands := preload("res://addons/godot_mcp_toolkit/commands/3d_commands.gd")
const AudioCommands := preload("res://addons/godot_mcp_toolkit/commands/audio_commands.gd")
const ProceduralCommands := preload("res://addons/godot_mcp_toolkit/commands/procedural_commands.gd")
const SpriteframesCommands := preload("res://addons/godot_mcp_toolkit/commands/spriteframes_commands.gd")
const ParticleCommands := preload("res://addons/godot_mcp_toolkit/commands/particle_commands.gd")
const NavigationCommands := preload("res://addons/godot_mcp_toolkit/commands/navigation_commands.gd")
const MetaCommands := preload("res://addons/godot_mcp_toolkit/commands/meta_commands.gd")

# Mode B — runtime autoload that hosts the game-side WS server on
# 127.0.0.1:6525. Registered/unregistered via add_autoload_singleton /
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
	{"label": "MCP Toolkit: Power User Mode", "menu_label": "Power User Mode", "key": "mcp/power_user_mode", "method": "_on_power_user_mode"},
]

var _tool_submenu: PopupMenu = null

var _server: Node = null
var _export_plugin: EditorExportPlugin = null
var _dock: Control = null
var _wizard: OnboardingWizard = null
var _feature_settings: FeatureGateSettings = null
var _notifier: GateNotifier = null
var _events: GateEvents = null
var _extension_watcher: RefCounted = null  # Live hot-reload watcher (ExtensionLoader)
var _user_path_monitor = null  # UserPathMonitor — detects config/name changes
# Playtest-end detection for runtime port cleanup.
var _was_playing: bool = false


func _enter_tree() -> void:
	SettingsMigration.migrate_user_data_paths()
	SettingsMigration.migrate_stale_settings()

	_events = GateEvents.new()
	_feature_settings = FeatureGateSettings.new()
	_feature_settings.bind_events(_events)
	_feature_settings.register_all()

	var registry := MCPToolkitCommandRegistry.new()
	_server = MCPServer.new()
	_server.name = "MCPServer"
	_server.set_registry(registry)
	_server.editor_plugin = self

	SceneCommands.register(registry, _server)
	NodeCommands.register(registry, _server)
	ScriptCommands.register(registry, _server)
	EditorCommands.register(registry, _server)
	ResourceCommands.register(registry, _server)
	FolderCommands.register(registry, _server)
	FileCommands.register(registry, _server)
	SignalCommands.register(registry, _server)
	PlaytestCommands.register(registry, _server)
	ProjectCommands.register(registry, _server)
	InputMapCommands.register(registry, _server)
	AnimationCommands.register(registry, _server)
	TilemapCommands.register(registry, _server)
	AssetCommands.register(registry, _server)
	SaveCommands.register(registry, _server)
	ClassdbCommands.register(registry, _server)
	ThemeCommands.register(registry, _server)
	PathCommands.register(registry, _server)
	ThreeDCommands.register(registry, _server)
	AudioCommands.register(registry, _server)
	ProceduralCommands.register(registry, _server)
	SpriteframesCommands.register(registry, _server)
	ParticleCommands.register(registry, _server)
	NavigationCommands.register(registry, _server)
	MetaCommands.register(registry)

	# Third-party extensions — profile-exempt, always loaded.
	ExtensionLoader.load_all(registry, _server)
	# Live hot-reload: watch EditorFileSystem for extension additions/removals.
	_extension_watcher = ExtensionLoader.start_watcher(registry, _server)

	_validate_user_whitelist()

	_export_plugin = preload("res://addons/godot_mcp_toolkit/export_strip.gd").new()
	add_export_plugin(_export_plugin)

	_Hub.LogBuffer.setup()

	# P-055: monitor config/name changes that shift user:// paths.
	# Each consumer connects directly and handles its own recovery.
	_user_path_monitor = _Hub.UserPathMonitor.new()
	_user_path_monitor.start()
	_user_path_monitor.project_name_changed.connect(_on_project_name_changed)
	_feature_settings.bind_user_path_monitor(_user_path_monitor)

	add_child(_server)
	_server.bind_user_path_monitor(_user_path_monitor)
	_server.start()

	# Register in the system-wide project registry so the TS bridge can
	# discover us by project path. Must come after start() — port unknown
	# until _scan_and_listen() runs.
	var bound_port: int = _server.get_bound_port()
	if bound_port > 0:
		MCPRegistryClient.register(bound_port, MCPAuth.get_token_path())
		# Deferred re-verify: concurrent editors may clobber our entry after
		# our initial verify passes. Jittered delay ensures all editors have
		# finished their initial registration before we re-check.
		var _jitter := randf_range(5.0, 10.0)
		get_tree().create_timer(_jitter).timeout.connect(
			func(): MCPRegistryClient.ensure_registered(bound_port, MCPAuth.get_token_path()))

	# -- Bottom-panel dock --
	_dock = preload("res://addons/godot_mcp_toolkit/ui/dock.tscn").instantiate()
	_notifier = GateNotifier.new()
	_notifier.bind(_server, _events)

	_dock.bind(_server, _Hub.MCPAudit.get_log_path())
	_dock.bind_events(_events)
	_dock.bind_notifier(_notifier)
	add_control_to_bottom_panel(_dock, "MCP Toolkit")

	_register_menus()

	# -- Per-user EditorSettings --
	_register_editor_settings()

	# Warn about untested future Godot versions (but don't block).
	var _minor := _Hub.godot_minor()
	if _minor > _Hub.GODOT_TESTED_MAX_MINOR:
		push_warning("[MCP] Godot 4.%d detected — latest tested version is 4.%d. "
			+ "The plugin will run normally but some features may behave unexpectedly. "
			+ "Please report issues at https://github.com/NPGameDev/godot-mcp-toolkit/issues" % [_minor, _Hub.GODOT_TESTED_MAX_MINOR])

	_wizard = OnboardingWizard.new(self, _dock, _notifier)
	call_deferred("_check_onboarding")


func _check_onboarding() -> void:
	_wizard.check_and_show()


func _process(_delta: float) -> void:
	_detect_playtest_end()
	_feature_settings.poll()


func _detect_playtest_end() -> void:
	var playing := EditorInterface.is_playing_scene()
	if _was_playing and not playing:
		MCPRegistryClient.clear_runtime()
		# Proactive notification: tell the MCP server bridge the game stopped
		# so it can tear down the runtime channel immediately — no need to wait
		# for the next callRuntime() to discover the dead connection.
		_server.broadcast_notification("game_stopped")
	_was_playing = playing


func _on_project_name_changed(_old_name: String, _new_name: String) -> void:
	# Static consumers that can't connect to signals themselves.
	# Instance consumers (feature_settings, server) connect directly
	# via bind_user_path_monitor().
	OnboardingWizard.migrate_flag_after_rename()
	_Hub.LogBuffer.reset_tail_path()


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
	_notifier = null
	_feature_settings = null
	_events = null
	if _user_path_monitor != null:
		_user_path_monitor.stop()
		_user_path_monitor = null

	# Extension watcher — drop before server teardown (holds registry ref).
	_extension_watcher = null

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
		MCPRegistryClient.deregister()
		_server.free()
		_server = null


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
		var toaster = _Hub.get_toaster()
		if toaster != null:
			toaster.push_toast("MCP token rotated", 0)


func _on_show_audit() -> void:
	if _dock != null:
		_dock.show_audit_dialog()
	else:
		var global_path := ProjectSettings.globalize_path(_Hub.MCPAudit.get_log_path())
		OS.shell_open(global_path)


func _on_open_settings() -> void:
	SettingsNavigator.open_mcp_settings()


func _on_write_mcp_json() -> void:
	if _dock != null:
		_dock.write_mcp_json()


func _on_power_user_mode() -> void:
	if _dock != null:
		_dock.toggle_power_user_mode()


# -- Whitelist validation ------------------------------------------------------


func _validate_user_whitelist() -> void:
	MCPFileGuard.reload_user_whitelist()
	var wl_path := "res://addons/godot_mcp_toolkit/user_scope_whitelist.json"
	if not FileAccess.file_exists(wl_path):
		push_warning("[MCPTools] user_scope_whitelist.json not found at %s; save.* tools will return USER_SCOPE_DISABLED until the file is created" % wl_path)
		return
	var f := FileAccess.open(wl_path, FileAccess.READ)
	if f == null:
		push_warning("[MCPTools] cannot open user_scope_whitelist.json (error %d); save.* tools will return USER_SCOPE_DISABLED" % FileAccess.get_open_error())
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[MCPTools] user_scope_whitelist.json is malformed (expected JSON object); save.* tools will return USER_SCOPE_DISABLED")
		return


# -- EditorSettings registration (per-user, not committed to VCS) -------------


func _register_editor_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	var settings := {
		"mcp_toolkit/personal/dock_default_visible": [TYPE_BOOL, true],
	}
	for key in settings:
		if not es.has_setting(key):
			es.set_setting(key, settings[key][1])
		es.add_property_info({"name": key, "type": settings[key][0]})
