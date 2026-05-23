@tool
class_name MCPToolkitCommandRegistry
extends RefCounted
## Central dispatch table for MCP commands.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const McpError = _Hub.McpError
const Audit = _Hub.Audit

const _DEFAULT_TIMEOUT_MS := 30000
const _MIN_TIMEOUT_MS := 1000
const _MAX_TIMEOUT_MS := 300000

var _commands: Dictionary = {}
var _extension_methods: Array[String] = []
var _version_blocked: Dictionary = {}  # method -> {min, max, engine}


func add(method: String, handler: Callable,
		options: MCPToolkitCommandOptions) -> void:
	var opts: Dictionary = options.to_dict()

	# Version gate: block commands incompatible with the running engine.
	var min_ver: String = opts.get("min_godot_version", "")
	var max_ver: String = opts.get("max_godot_version", "")
	if min_ver != "" or max_ver != "":
		var engine_ver := _Hub.VersionUtils.get_engine_version_pair()
		if not _Hub.VersionUtils.is_version_in_range(engine_ver, min_ver, max_ver):
			_version_blocked[method] = {"min": min_ver, "max": max_ver, "engine": engine_ver}
			return

	var is_read_only: bool = opts.get("is_read_only", false)
	var is_destructive: bool = opts.get("is_destructive", false)
	var is_idempotent: bool = opts.get("is_idempotent", false)

	# Exclusivity validation: read-only + destructive is a contradiction.
	if is_read_only and is_destructive:
		push_warning("[MCPExtensions] '%s': is_read_only and is_destructive are mutually exclusive — forcing is_destructive to false" % method)
		is_destructive = false

	# Map friendly names to MCP annotations.
	var annotations := {
		"readOnlyHint": is_read_only,
		"destructiveHint": is_destructive,
		"idempotentHint": is_idempotent,
	}

	# Clamp timeout: 0/negative → default, then floor/cap.
	var raw_timeout: int = opts.get("timeout_ms", 0)
	var timeout_ms: int = _DEFAULT_TIMEOUT_MS
	if raw_timeout > 0:
		if raw_timeout > _MAX_TIMEOUT_MS:
			push_warning("[MCPExtensions] '%s': timeout_ms %d exceeds maximum %d — clamped. Consider restructuring the tool to use a start-work-and-poll pattern." % [method, raw_timeout, _MAX_TIMEOUT_MS])
		timeout_ms = clampi(raw_timeout, _MIN_TIMEOUT_MS, _MAX_TIMEOUT_MS)

	var cmd_entry := {
		"handler": handler,
		"description": opts.get("description", ""),
		"input_schema": opts.get("input_schema", {}),
		"annotations": annotations,
		"group": opts.get("group", {}),
		"timeout_ms": timeout_ms,
		"is_cancellable": bool(opts.get("is_cancellable", false)),
		"read_only": is_read_only,
		"active_scene_required": bool(opts.get("is_active_scene_required", true)),
		"_force_serialize": bool(opts.get("_force_serialize", false)),
	}
	if min_ver != "":
		cmd_entry["min_godot_version"] = min_ver
	if max_ver != "":
		cmd_entry["max_godot_version"] = max_ver
	_commands[method] = cmd_entry


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
	var meta := {
		"description": entry.get("description", ""),
		"input_schema": entry.get("input_schema", {}),
		"annotations": entry.get("annotations", {}),
		"group": entry.get("group", {}),
	}
	var timeout_ms: int = entry.get("timeout_ms", _DEFAULT_TIMEOUT_MS)
	if timeout_ms != _DEFAULT_TIMEOUT_MS:
		meta["timeout_ms"] = timeout_ms
	if entry.has("min_godot_version"):
		meta["min_godot_version"] = entry["min_godot_version"]
	if entry.has("max_godot_version"):
		meta["max_godot_version"] = entry["max_godot_version"]
	return meta


func has_command(method: String) -> bool:
	return _commands.has(method)


func is_cancellable(method: String) -> bool:
	if not _commands.has(method):
		return false
	return _commands[method].get("is_cancellable", false)


func is_read_only(method: String) -> bool:
	var cmd = _commands.get(method)
	return cmd != null and cmd.get("read_only", false)


func is_active_scene_required(method: String) -> bool:
	var cmd = _commands.get(method)
	return cmd != null and cmd.get("active_scene_required", true)


func is_force_serialized(method: String) -> bool:
	var cmd = _commands.get(method)
	return cmd != null and cmd.get("_force_serialize", false)


func needs_serialization(method: String) -> bool:
	if not _commands.has(method):
		return true  # Safe default for unknown commands.
	if is_force_serialized(method):
		return true
	return not is_read_only(method)


func create_options() -> MCPToolkitCommandOptions:
	return MCPToolkitCommandOptions.new()


func create_extension_options(description: String) -> MCPToolkitExtensionOptions:
	return MCPToolkitExtensionOptions.new(description)


func clear() -> void:
	_commands.clear()
	_extension_methods.clear()
	_version_blocked.clear()


func call_command(method: String, parameters: Dictionary,
		ctx: MCPToolkitToolContext = null) -> Dictionary:
	if not _commands.has(method):
		if _version_blocked.has(method):
			var info: Dictionary = _version_blocked[method]
			var detail := "requires"
			if info["min"] != "":
				detail += " >= %s" % info["min"]
			if info["max"] != "":
				detail += " <= %s" % info["max"]
			return McpError.make("UNSUPPORTED",
				"%s %s (running: %s)" % [method, detail, info["engine"]])
		return McpError.make("NOT_FOUND", "unknown method: " + method)
	Audit.log_call(method, parameters)
	if ctx != null:
		return await _commands[method]["handler"].call(parameters, ctx)
	else:
		return await _commands[method]["handler"].call(parameters)
