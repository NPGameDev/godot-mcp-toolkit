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

# Mode B (iter 10) — runtime autoload that hosts the game-side WS server on
# 127.0.0.1:9090. Registered/unregistered via add_autoload_singleton /
# remove_autoload_singleton per I12 so end-user installs pick it up when they
# tick the plugin. Idempotent: if project.godot already carries the entry
# (e.g., dogfood), Godot keeps the existing value rather than duplicating.
const RUNTIME_AUTOLOAD_NAME := "MCPRuntimeServer"
const RUNTIME_AUTOLOAD_PATH := "res://addons/godot_mcp_toolkit/runtime/mcp_runtime_server.gd"

var _server: Node = null


func _enter_tree() -> void:
	_register_feature_gate_settings()

	var registry := MCPCommandRegistry.new()
	_server = MCPServer.new()
	_server.name = "MCPServer"
	_server.set_registry(registry)

	# Register all domain command modules.
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

	add_child(_server)
	_server.start()

	call_deferred("_check_onboarding")


# -- FeatureGate ProjectSettings registration (iter 19) -----------------------


func _register_feature_gate_settings() -> void:
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


# -- Onboarding dialog (iter 19) ----------------------------------------------


const _ONBOARDING_FLAG := "user://mcp_onboarding_v19_shown"


func _check_onboarding() -> void:
	if FileAccess.file_exists(_ONBOARDING_FLAG):
		return
	var dialog := AcceptDialog.new()
	dialog.title = "Godot MCP Toolkit — Feature Gates"
	dialog.dialog_text = """Some MCP capabilities are now disabled by default for safety:

  game_eval — Arbitrary GDScript execution (dual-gate)
  node_call_method — Method invocation on nodes (single-gate)
  project_set_setting — Write ProjectSettings keys (dual-gate)
  input_map_write — Modify InputMap actions (single-gate)

To enable them, visit:
  Project Settings → Advanced → mcp/unsafe/

Dual-gate features also require their environment variable
(e.g. GODOT_MCP_ALLOW_GAME_EVAL=1 in .mcp.json env).

This dialog will not appear again."""
	dialog.confirmed.connect(func():
		_write_onboarding_flag()
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


func _exit_tree() -> void:
	if _server != null:
		_server.stop()
		_server.queue_free()
		_server = null


func _enable_plugin() -> void:
	add_autoload_singleton(RUNTIME_AUTOLOAD_NAME, RUNTIME_AUTOLOAD_PATH)


func _disable_plugin() -> void:
	remove_autoload_singleton(RUNTIME_AUTOLOAD_NAME)
