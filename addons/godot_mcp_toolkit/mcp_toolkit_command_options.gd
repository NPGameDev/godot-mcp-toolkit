@tool
class_name MCPToolkitCommandOptions
extends RefCounted
## Builder for MCP command registration options.
##
## Usage (built-in tools):
##   var opts = MCPToolkitCommandOptions.new() \
##       .mark_read_only() \
##       .mark_idempotent() \
##       .with_timeout_ms(60000) \
##       .with_group("physics_tools", "Physics inspection", ["physics", "force"])
##
## Extension tools should use MCPToolkitExtensionOptions instead, which
## enforces a description at construction time.

var _description: String = ""
var _input_schema: Dictionary = {}
var _is_read_only: bool = false
var _is_destructive: bool = false
var _is_idempotent: bool = false
var _is_cancellable: bool = false
var _timeout_ms: int = 0  # 0 = use registry default (30000)
var _group_name: String = ""
var _group_description: String = ""
var _group_keywords: Array = []
var _is_scene_independent: bool = false  # inverted: true means NOT required
var _force_serialize: bool = false
var _min_godot_version: String = ""
var _max_godot_version: String = ""
var _success_hint: String = ""
var _path_guards: Dictionary = {}  # param_name -> "project" | "user"


func with_description(description: String) -> MCPToolkitCommandOptions:
	_description = description
	return self


func with_input_schema(schema: Dictionary) -> MCPToolkitCommandOptions:
	_input_schema = schema
	return self


func with_timeout_ms(timeout: int) -> MCPToolkitCommandOptions:
	_timeout_ms = timeout
	return self


func with_group(name: String, description: String = "",
		keywords: Array = []) -> MCPToolkitCommandOptions:
	_group_name = name
	_group_description = description
	_group_keywords = keywords
	return self


func mark_read_only() -> MCPToolkitCommandOptions:
	_is_read_only = true
	return self


func mark_destructive() -> MCPToolkitCommandOptions:
	_is_destructive = true
	return self


func mark_idempotent() -> MCPToolkitCommandOptions:
	_is_idempotent = true
	return self


func mark_cancellable() -> MCPToolkitCommandOptions:
	_is_cancellable = true
	return self


func mark_scene_independent() -> MCPToolkitCommandOptions:
	_is_scene_independent = true
	return self


func mark_exclusive_execution() -> MCPToolkitCommandOptions:
	_force_serialize = true
	return self


func with_min_godot_version(version: String) -> MCPToolkitCommandOptions:
	if not _is_valid_version(version):
		push_warning("[MCPToolkit] Invalid min_godot_version format: '%s' (expected 'major.minor', e.g. '4.5')" % version)
	_min_godot_version = version
	return self


func with_success_hint(hint: String) -> MCPToolkitCommandOptions:
	_success_hint = hint
	return self


## Declare that `param` carries a res:// project path the dispatch must validate
## (via FileGuard.resolve_safe) BEFORE the handler runs. Use this for any LLM-
## supplied path your command reads/writes, so a traversal/escape path is rejected
## with PATH_DENIED before your code touches it. Built-in tools self-guard; this is
## the declarative equivalent for extension commands. See docs/adr/0009.
func guard_project_path(param: String) -> MCPToolkitCommandOptions:
	_path_guards[param] = "project"
	return self


## Like guard_project_path, but for user:// paths (validated via
## FileGuard.resolve_safe_user — rejects traversal, non-user:// prefixes, and the
## plugin's own internal paths).
func guard_user_path(param: String) -> MCPToolkitCommandOptions:
	_path_guards[param] = "user"
	return self


func with_max_godot_version(version: String) -> MCPToolkitCommandOptions:
	if not _is_valid_version(version):
		push_warning("[MCPToolkit] Invalid max_godot_version format: '%s' (expected 'major.minor', e.g. '4.6')" % version)
	_max_godot_version = version
	return self


static func _is_valid_version(v: String) -> bool:
	var parts := v.split(".")
	if parts.size() < 2:
		return false
	return parts[0].is_valid_int() and parts[1].is_valid_int()


func to_dict() -> Dictionary:
	var d := {
		"description": _description,
		"is_read_only": _is_read_only,
		"is_destructive": _is_destructive,
		"is_idempotent": _is_idempotent,
		"is_cancellable": _is_cancellable,
		"is_active_scene_required": not _is_scene_independent,
	}
	if _force_serialize:
		d["_force_serialize"] = true
	if not _input_schema.is_empty():
		d["input_schema"] = _input_schema
	if _timeout_ms > 0:
		d["timeout_ms"] = _timeout_ms
	if _group_name != "":
		var group := {"name": _group_name}
		if _group_description != "":
			group["description"] = _group_description
		if not _group_keywords.is_empty():
			group["keywords"] = _group_keywords
		d["group"] = group
	if _min_godot_version != "":
		d["min_godot_version"] = _min_godot_version
	if _max_godot_version != "":
		d["max_godot_version"] = _max_godot_version
	if _success_hint != "":
		d["success_hint"] = _success_hint
	if not _path_guards.is_empty():
		d["path_guards"] = _path_guards
	return d
