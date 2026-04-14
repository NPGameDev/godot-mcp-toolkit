@tool
extends EditorPlugin

const MCPServer := preload("res://addons/godot_mcp_toolkit/mcp_server.gd")

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
