@tool
extends EditorPlugin

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPCommandRegistry = _Hub.MCPCommandRegistry
const MCPFeatureRegistry = _Hub.MCPFeatureRegistry
const MCPServer := preload("res://addons/godot_mcp_toolkit/mcp_server.gd")
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
const MCPFileGuard = _Hub.MCPFileGuard
const MCPRegistryClient = _Hub.MCPRegistryClient
const MCPAuth := preload("res://addons/godot_mcp_toolkit/auth.gd")
const UserCommandsLoader := preload("res://addons/godot_mcp_toolkit/user_commands_loader.gd")

# Mode B — runtime autoload that hosts the game-side WS server on
# 127.0.0.1:6525. Registered/unregistered via add_autoload_singleton /
# remove_autoload_singleton so end-user installs pick it up when they
# tick the plugin. Idempotent: if project.godot already carries the entry
# (e.g., dogfood), Godot keeps the existing value rather than duplicating.
const RUNTIME_AUTOLOAD_NAME := "MCPRuntimeServer"
const RUNTIME_AUTOLOAD_PATH := "res://addons/godot_mcp_toolkit/runtime/mcp_runtime_server.gd"

var _server: Node = null
var _export_plugin: EditorExportPlugin = null
var _dock: Control = null
# Playtest-end detection for runtime port cleanup.
var _was_playing: bool = false

# Menu item keys for teardown symmetry.
const _MENU_ITEMS: Array[String] = [
	"MCP: Regenerate Token",
	"MCP: Show Audit Log",
	"MCP: Open Project Settings",
	"MCP: Write .mcp.json",
	"MCP: Power User Mode",
]

# Command Palette key names for teardown symmetry.
const _PALETTE_KEYS: Array[String] = [
	"mcp/regenerate_token",
	"mcp/show_audit_log",
	"mcp/open_settings",
	"mcp/write_mcp_json",
	"mcp/power_user_mode",
]


func _enter_tree() -> void:
	_register_feature_gate_settings()

	var registry := MCPCommandRegistry.new()
	_server = MCPServer.new()
	_server.name = "MCPServer"
	_server.set_registry(registry)

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

	# User command extensions — profile-exempt, always loaded.
	UserCommandsLoader.load_all(registry, _server)

	_validate_user_whitelist()

	_export_plugin = preload("res://addons/godot_mcp_toolkit/export_strip.gd").new()
	add_export_plugin(_export_plugin)

	add_child(_server)
	_server.start()

	# Register in the system-wide project registry so the TS bridge can
	# discover us by project path. Must come after start() — port unknown
	# until _scan_and_listen() runs.
	var bound_port: int = _server.get_bound_port()
	if bound_port > 0:
		MCPRegistryClient.register(bound_port, MCPAuth.get_token_path())

	# -- Bottom-panel dock --
	_dock = preload("res://addons/godot_mcp_toolkit/ui/dock.tscn").instantiate()
	_dock.bind(_server, "user://mcp_audit.log")
	add_control_to_bottom_panel(_dock, "MCP")

	# -- Menu items --
	add_tool_menu_item("MCP: Regenerate Token", _on_regen_token)
	add_tool_menu_item("MCP: Show Audit Log", _on_show_audit)
	add_tool_menu_item("MCP: Open Project Settings", _on_open_settings)
	add_tool_menu_item("MCP: Write .mcp.json", _on_write_mcp_json)
	add_tool_menu_item("MCP: Power User Mode", _on_power_user_mode)

	# -- Command Palette --
	var palette := EditorInterface.get_command_palette()
	palette.add_command("MCP: Regenerate Token", "mcp/regenerate_token", _on_regen_token)
	palette.add_command("MCP: Show Audit Log", "mcp/show_audit_log", _on_show_audit)
	palette.add_command("MCP: Open Project Settings", "mcp/open_settings", _on_open_settings)
	palette.add_command("MCP: Write .mcp.json", "mcp/write_mcp_json", _on_write_mcp_json)
	palette.add_command("MCP: Power User Mode", "mcp/power_user_mode", _on_power_user_mode)

	# -- Per-user EditorSettings --
	_register_editor_settings()

	call_deferred("_check_onboarding")


# -- user:// whitelist validation ----------------------------------------------


func _validate_user_whitelist() -> void:
	MCPFileGuard.reload_user_whitelist()
	var wl_path := "res://addons/godot_mcp_toolkit/user_scope_whitelist.json"
	if not FileAccess.file_exists(wl_path):
		push_warning("MCP: user_scope_whitelist.json not found at %s; save.* tools will return USER_SCOPE_DISABLED until the file is created" % wl_path)
		return
	var f := FileAccess.open(wl_path, FileAccess.READ)
	if f == null:
		push_warning("MCP: cannot open user_scope_whitelist.json (error %d); save.* tools will return USER_SCOPE_DISABLED" % FileAccess.get_open_error())
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("MCP: user_scope_whitelist.json is malformed (expected JSON object); save.* tools will return USER_SCOPE_DISABLED")
		return


# -- FeatureGate ProjectSettings registration ---------------------------------


func _register_feature_gate_settings() -> void:
	# allow_all — Power User Mode master switch.
	if not ProjectSettings.has_setting("mcp/unsafe/allow_all"):
		ProjectSettings.set_setting("mcp/unsafe/allow_all", false)
	ProjectSettings.set_initial_value("mcp/unsafe/allow_all", false)
	ProjectSettings.add_property_info({
		"name": "mcp/unsafe/allow_all",
		"type": TYPE_BOOL,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "DANGER: Enables PS side of ALL feature gates. "
			+ "Dual-gated features still require their env var. "
			+ "Explicit deny_<feature> overrides this.",
	})

	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		var ps_key: String = entry["ps_key"]
		if not ProjectSettings.has_setting(ps_key):
			ProjectSettings.set_setting(ps_key, false)
		ProjectSettings.set_initial_value(ps_key, false)
		var gate_label := "dual-gate: env AND PS" if entry["dual_gate"] else "single-gate: env OR PS"
		ProjectSettings.add_property_info({
			"name": ps_key,
			"type": TYPE_BOOL,
			"hint": PROPERTY_HINT_NONE,
			"hint_string": "DANGER: %s (%s). Default off." % [entry["risk"], gate_label],
		})


# -- Onboarding dialog --------------------------------------------------------


const _ONBOARDING_FLAG := "user://mcp_onboarding_v21_shown"


func _check_onboarding() -> void:
	if FileAccess.file_exists(_ONBOARDING_FLAG):
		return
	var dialog := AcceptDialog.new()
	dialog.title = "MCP Plugin — First Run Setup"
	dialog.dialog_text = (
		"Welcome to the Godot MCP Toolkit.\n\n"
		+ "Some capabilities (code execution, OS commands, etc.)\n"
		+ "are disabled by default for safety. Choose your mode:\n\n"
		+ "Safe Mode (Recommended):\n"
		+ "  All advanced features off. Enable individually later\n"
		+ "  via the MCP dock or Project Settings.\n\n"
		+ "Configure Individually:\n"
		+ "  Opens Project Settings -> mcp/unsafe/ to pick features.\n\n"
		+ "Power User Mode:\n"
		+ "  Enable ALL features. You know the risks.")
	dialog.ok_button_text = "Safe Mode (Recommended)"
	dialog.add_button("Configure Individually", true, "configure")
	dialog.add_button("Power User Mode", true, "power_user")
	dialog.confirmed.connect(func():
		_write_onboarding_flag()
		dialog.queue_free()
	)
	dialog.custom_action.connect(func(action: StringName):
		_write_onboarding_flag()
		match str(action):
			"configure":
				_on_open_settings()
			"power_user":
				_on_power_user_mode()
		dialog.queue_free()
	)
	dialog.canceled.connect(func():
		_write_onboarding_flag()
		dialog.queue_free()
	)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


func _write_onboarding_flag() -> void:
	var f := FileAccess.open(_ONBOARDING_FLAG, FileAccess.WRITE)
	if f != null:
		f.store_string("1")
		f.close()


# Detect playtest end so we can clear runtime_port/runtime_pid from
# the registry (belt-and-suspenders with runtime's own _exit_tree cleanup).
func _process(_delta: float) -> void:
	var playing := EditorInterface.is_playing_scene()
	if _was_playing and not playing:
		MCPRegistryClient.clear_runtime()
	_was_playing = playing


func _exit_tree() -> void:
	# Teardown symmetry — reverse order of _enter_tree registrations.
	# Command Palette.
	var palette := EditorInterface.get_command_palette()
	for key in _PALETTE_KEYS:
		palette.remove_command(key)

	# Menu items.
	for item in _MENU_ITEMS:
		remove_tool_menu_item(item)

	# Dock (remove + free).
	if _dock != null:
		remove_control_from_bottom_panel(_dock)
		_dock.queue_free()
		_dock = null

	# Export plugin (RefCounted — do NOT queue_free, just null).
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null

	# Server + registry.
	if _server != null:
		_server.stop()
		MCPRegistryClient.deregister()
		_server.queue_free()
		_server = null


func _enable_plugin() -> void:
	add_autoload_singleton(RUNTIME_AUTOLOAD_NAME, RUNTIME_AUTOLOAD_PATH)


func _disable_plugin() -> void:
	remove_autoload_singleton(RUNTIME_AUTOLOAD_NAME)

	# Warn about orphaned .mcp.json.
	var mcp_json_path := ProjectSettings.globalize_path("res://") + ".mcp.json"
	if FileAccess.file_exists(mcp_json_path):
		var dialog := ConfirmationDialog.new()
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


# -- EditorSettings registration (per-user, not committed to VCS) --------


func _register_editor_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	var settings := {
		"mcp/personal/dock_default_visible": [TYPE_BOOL, true],
		"mcp/personal/audit_log_tail_lines": [TYPE_INT, 50],
	}
	for key in settings:
		if not es.has_setting(key):
			es.set_setting(key, settings[key][1])
		es.add_property_info({"name": key, "type": settings[key][0]})


# -- Menu / Command Palette handlers --------------------------------------


func _on_regen_token() -> void:
	if _server != null:
		_server.regenerate_token()
		print("[MCP] Token rotated")
		var toaster = EditorInterface.get_editor_toaster()
		if toaster != null:
			toaster.push_toast("MCP token rotated", 0)


func _on_show_audit() -> void:
	var global_path := ProjectSettings.globalize_path("user://mcp_audit.log")
	OS.shell_open(global_path)


func _on_open_settings() -> void:
	# No public API to open Project Settings to a specific section.
	print("[MCP] Navigate to: Project -> Project Settings -> Advanced -> mcp/unsafe/")
	var toaster = EditorInterface.get_editor_toaster()
	if toaster != null:
		toaster.push_toast(
			"Project -> Project Settings -> Advanced -> mcp/unsafe/", 0,
			"Enable 'Advanced Settings' to see the MCP feature gates")


func _on_write_mcp_json() -> void:
	if _dock != null:
		_dock.write_mcp_json()


func _on_power_user_mode() -> void:
	if _dock != null:
		_dock.toggle_power_user_mode()
