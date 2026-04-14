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
	_server = MCPServer.new()
	_server.name = "MCPServer"
	add_child(_server)
	_server.start()


func _exit_tree() -> void:
	if _server != null:
		_server.stop()
		_server.queue_free()
		_server = null


func _enable_plugin() -> void:
	# Fires when the plugin is FIRST enabled (or re-enabled after disable).
	# Autoload edits persist in project.godot so this is the right boundary
	# per I12 (not _enter_tree which fires on every editor open).
	add_autoload_singleton(RUNTIME_AUTOLOAD_NAME, RUNTIME_AUTOLOAD_PATH)


func _disable_plugin() -> void:
	remove_autoload_singleton(RUNTIME_AUTOLOAD_NAME)
