@tool
extends EditorPlugin

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const FileGuard = _Hub.FileGuard
const SettingsRegistration := preload("res://addons/godot_mcp_toolkit/settings_registration.gd")
const OnboardingWizard := preload("res://addons/godot_mcp_toolkit/ui/onboarding_wizard.gd")
const PluginComposer := preload("res://addons/godot_mcp_toolkit/plugin_composer.gd")
const ToolMenu := preload("res://addons/godot_mcp_toolkit/tool_menu.gd")

# Mode B — runtime autoload that hosts the game-side WS server on
# 127.0.0.1:6570. Registered/unregistered via add_autoload_singleton /
# remove_autoload_singleton so end-user installs pick it up when they
# tick the plugin. Idempotent: if project.godot already carries the entry
# (e.g., dogfood), Godot keeps the existing value rather than duplicating.
const RUNTIME_AUTOLOAD_NAME := "MCPRuntimeServer"
const RUNTIME_AUTOLOAD_PATH := "res://addons/godot_mcp_toolkit/runtime/mcp_runtime_server.gd"

# The composed collaborator graph (server, dock, export plugin, watchers, debug
# bridge, user-path monitor, playtest watcher). PluginComposer.compose() builds
# it; the orchestrator drives it and calls _handle.dispose() on exit.
var _handle = null

var _tool_menu: ToolMenu = null
var _wizard: OnboardingWizard = null


func _enter_tree() -> void:
	# Lifecycle phase sequence. The "why this order" narrative lives here; the
	# composer owns the internal construction order of the graph it builds.
	_Hub.EditorAccess.set_plugin(self)
	SettingsRegistration.register_all()

	# Construct + wire the whole collaborator graph (registry, server, debug
	# bridge, command registrar, extensions, export plugin, log buffer, user-path
	# monitor, registry registration, playtest watcher, dock) and register in the
	# system-wide registry.
	_handle = PluginComposer.compose(self, _on_user_path_changed)

	# Tools > MCP Toolkit submenu + command palette (needs the server + dock the
	# composer just built).
	_tool_menu = ToolMenu.new(self, _handle.server(), _handle.dock())
	_tool_menu.install()

	# -- Per-user EditorSettings --
	_register_editor_settings()

	# Warn about untested future Godot versions (but don't block).
	var _engine_ver := _Hub.VersionUtils.get_engine_version_pair()
	if not _Hub.VersionUtils.is_at_most(_engine_ver, _Hub.VersionUtils.GODOT_TESTED_MAX_VERSION):
		push_warning(("[MCP] Godot %s detected — latest tested version is %s. "
			+ "The plugin will run normally but some features may behave unexpectedly. "
			+ "Please report issues at https://github.com/NPGameDev/godot-mcp-toolkit/issues")
			% [_engine_ver, _Hub.VersionUtils.GODOT_TESTED_MAX_VERSION])

	_wizard = OnboardingWizard.new(self, _handle.dock())
	call_deferred("_check_onboarding")


func _check_onboarding() -> void:
	_wizard.check_and_show()


func _process(_delta: float) -> void:
	if _handle != null:
		_handle.poll_playtest()


func _on_user_path_changed() -> void:
	# Static consumers that can't connect to signals themselves.
	# Instance consumers (feature_settings, server) connect directly
	# via bind_user_path_monitor().
	OnboardingWizard.migrate_flag_after_rename()
	_Hub.LogBuffer.reset_tail_path()


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
