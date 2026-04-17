@tool
extends EditorPlugin

const MCPServer := preload("res://addons/godot_mcp_toolkit/mcp_server.gd")

# Mode B (iter 10) — runtime autoload that hosts the game-side WS server on
# 127.0.0.1:9090. Registered/unregistered via add_autoload_singleton /
# remove_autoload_singleton per I12 so end-user installs pick it up when they
# tick the plugin. Idempotent: if project.godot already carries the entry
# (e.g., dogfood), Godot keeps the existing value rather than duplicating.
const RUNTIME_AUTOLOAD_NAME := "MCPRuntimeServer"
const RUNTIME_AUTOLOAD_PATH := "res://addons/godot_mcp_toolkit/runtime/mcp_runtime_server.gd"

var _server: Node = null


func _enter_tree() -> void:
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


func _exit_tree() -> void:
	if _server != null:
		_server.stop()
		_server.queue_free()
		_server = null


func _enable_plugin() -> void:
	add_autoload_singleton(RUNTIME_AUTOLOAD_NAME, RUNTIME_AUTOLOAD_PATH)


func _disable_plugin() -> void:
	remove_autoload_singleton(RUNTIME_AUTOLOAD_NAME)
