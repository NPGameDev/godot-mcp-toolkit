@tool
class_name MCPToolkitCommandRegistry
extends RefCounted
## Central dispatch table for MCP commands.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPAudit = _Hub.MCPAudit

var _commands: Dictionary = {}
var _extension_methods: Array[String] = []


func add(method: String, handler: Callable, options: Dictionary = {}) -> void:
	_commands[method] = {
		"handler": handler,
		"description": options.get("description", ""),
		"input_schema": options.get("input_schema", {}),
		"annotations": options.get("annotations", {}),
		"group": options.get("group", {}),
	}


func remove(method: String) -> void:
	_commands.erase(method)
	var idx := _extension_methods.find(method)
	if idx >= 0:
		_extension_methods.remove_at(idx)


func get_all_methods() -> Array:
	return _commands.keys()


func mark_extension(method: String) -> void:
	if method not in _extension_methods:
		_extension_methods.append(method)


func get_extension_methods() -> Array[String]:
	return _extension_methods.duplicate()


func get_command_metadata(method: String) -> Dictionary:
	if not _commands.has(method):
		return {}
	var entry: Dictionary = _commands[method]
	return {
		"description": entry.get("description", ""),
		"input_schema": entry.get("input_schema", {}),
		"annotations": entry.get("annotations", {}),
		"group": entry.get("group", {}),
	}


func has_command(method: String) -> bool:
	return _commands.has(method)


func clear() -> void:
	_commands.clear()
	_extension_methods.clear()


func call_command(method: String, parameters: Dictionary) -> Dictionary:
	if not _commands.has(method):
		return MCPError.make("NOT_FOUND", "unknown method: " + method)
	MCPAudit.log_call(method, parameters)
	return await _commands[method]["handler"].call(parameters)
