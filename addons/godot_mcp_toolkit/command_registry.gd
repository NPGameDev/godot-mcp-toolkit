@tool
extends RefCounted
## Central dispatch table for MCP commands with tier membership (I14).

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
##
## Every tool registers via add() with a required tier argument.
## The registry is the single source of truth for which tools are lite vs full.

const VALID_TIERS: Array[String] = ["lite", "full"]

var _commands: Dictionary = {}  # method -> { handler: Callable, tier: String }


func add(method: String, handler: Callable, tier: String) -> void:
	assert(tier in VALID_TIERS, "tier must be 'lite' or 'full', got: " + tier)
	_commands[method] = {"handler": handler, "tier": tier}


func has_command(method: String) -> bool:
	return _commands.has(method)


func get_tier(method: String) -> String:
	return _commands[method]["tier"] if _commands.has(method) else ""


func get_methods_for_tier(tier: String) -> Array[String]:
	var result: Array[String] = []
	for method: String in _commands:
		if tier == "full" or _commands[method]["tier"] == tier:
			result.append(method)
	return result


func call_command(method: String, parameters: Dictionary) -> Dictionary:
	if not _commands.has(method):
		return MCPError.make("NOT_FOUND", "unknown method: " + method)
	return _commands[method]["handler"].call(parameters)
