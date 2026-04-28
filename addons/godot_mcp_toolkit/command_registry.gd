@tool
extends RefCounted
## Central dispatch table for MCP commands.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPAudit = _Hub.MCPAudit

var _commands: Dictionary = {}
var _user_methods: Array[String] = []


func add(method: String, handler: Callable) -> void:
	_commands[method] = {"handler": handler}


func remove(method: String) -> void:
	_commands.erase(method)
	var idx := _user_methods.find(method)
	if idx >= 0:
		_user_methods.remove_at(idx)


func get_all_methods() -> Array:
	return _commands.keys()


func mark_user(method: String) -> void:
	if method not in _user_methods:
		_user_methods.append(method)


func get_user_methods() -> Array[String]:
	return _user_methods.duplicate()


func has_command(method: String) -> bool:
	return _commands.has(method)


func clear() -> void:
	_commands.clear()
	_user_methods.clear()


func call_command(method: String, parameters: Dictionary) -> Dictionary:
	if not _commands.has(method):
		return MCPError.make("NOT_FOUND", "unknown method: " + method)
	MCPAudit.log_call(method, parameters)
	return _commands[method]["handler"].call(parameters)
