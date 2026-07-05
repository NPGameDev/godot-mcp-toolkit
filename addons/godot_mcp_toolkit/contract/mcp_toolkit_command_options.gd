@tool
class_name MCPToolkitCommandOptions
extends RefCounted
## Fluent builder for the options a command declares when registered.
##
## Every chainable method returns [code]self[/code], so a registration reads as a
## single chain whose terminal [method to_dict] produces the metadata dictionary
## [method MCPToolkitCommandRegistry.add] consumes. Each setter records one facet
## of the command's contract: its hints ([method mark_read_only],
## [method mark_destructive], [method mark_idempotent]), its dispatch behaviour
## ([method mark_exclusive_execution], [method mark_scene_independent],
## [method with_timeout_ms]), its grouping ([method with_group]), its version range
## ([method with_min_godot_version] / [method with_max_godot_version]), and its
## path guards ([method guard_project_path] / [method guard_user_path]).[br]
## [br]
## For built-in tools, only [method mark_read_only] is load-bearing
## (routing/serialization); the client-visible readOnly/destructive/idempotent hints
## are server-authoritative (server [code]src/catalogue.ts[/code]).
## [method mark_destructive] / [method mark_idempotent] apply only to EXTENSION
## tools, whose annotations the bridge reads via
## [method MCPToolkitCommandRegistry.get_command_metadata]. Extension tools should
## use [MCPToolkitExtensionOptions], a subclass that requires a description at
## construction time (it errors on an empty one but still constructs).[br]
## [br]
## Example — register a read-only physics tool:
## [codeblock]
## registry.add("physics_list_bodies", _on_list_bodies,
##     MCPToolkitCommandOptions.new() \
##         .mark_read_only() \
##         .with_timeout_ms(60000) \
##         .with_group("physics_tools", "Physics inspection", ["physics", "force"]))
## [/codeblock]

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
var _exclusive_execution: bool = false
var _min_godot_version: String = ""
var _max_godot_version: String = ""
var _success_hint: String = ""
var _path_guards: Dictionary = {}  # param_name -> "project" | "user"


## Sets the human-readable [param description] the bridge advertises for an
## extension tool (built-in descriptions are server-authoritative).
## Returns [code]self[/code] for chaining. Prefer [MCPToolkitExtensionOptions],
## which takes the description in its constructor.
func with_description(description: String) -> MCPToolkitCommandOptions:
	_description = description
	return self


## Sets the JSON-Schema [param schema] describing the tool's parameters, used by
## the bridge to validate and advertise the tool's inputs.
## Returns [code]self[/code] for chaining.
func with_input_schema(schema: Dictionary) -> MCPToolkitCommandOptions:
	_input_schema = schema
	return self


## Sets the per-command watchdog deadline to [param timeout] milliseconds.
## A non-positive value (the default) means "use the registry default" (30 s);
## the registry floors a positive value at 1 s and caps it at 300 s.
## Returns [code]self[/code] for chaining.
func with_timeout_ms(timeout: int) -> MCPToolkitCommandOptions:
	_timeout_ms = timeout
	return self


## Assigns the command to the on-demand group [param name], so it loads only when
## that group is requested rather than at startup. [param description] and
## [param keywords] help the bridge present and surface the group. Pass an empty
## [param name] to leave the command ungrouped (eager).
## Returns [code]self[/code] for chaining.
func with_group(name: String, description: String = "",
		keywords: Array = []) -> MCPToolkitCommandOptions:
	_group_name = name
	_group_description = description
	_group_keywords = keywords
	return self


## Marks the command read-only: it does not mutate editor or project state.
## This is load-bearing for every command — the dispatcher uses it to decide
## whether the call must be serialized against mutations (read-only calls bypass
## the mutation queue) — and for extension tools it also becomes the client-visible
## [code]readOnlyHint[/code]. Mutually exclusive with [method mark_destructive].
## Returns [code]self[/code] for chaining.
func mark_read_only() -> MCPToolkitCommandOptions:
	_is_read_only = true
	return self


## Marks the command destructive (it may delete or overwrite data), surfacing the
## client-visible [code]destructiveHint[/code] for an extension tool. Applies to
## EXTENSION tools only — built-in hints are server-authoritative. The registry
## treats this as mutually exclusive with [method mark_read_only].
## Returns [code]self[/code] for chaining.
func mark_destructive() -> MCPToolkitCommandOptions:
	_is_destructive = true
	return self


## Marks the command idempotent (repeating it with the same arguments has the same
## effect as calling it once), surfacing the client-visible
## [code]idempotentHint[/code] for an extension tool. Applies to EXTENSION tools
## only — built-in hints are server-authoritative.
## Returns [code]self[/code] for chaining.
func mark_idempotent() -> MCPToolkitCommandOptions:
	_is_idempotent = true
	return self


## Marks the command cancellable, so the dispatcher passes a
## [MCPToolkitToolContext] the handler can poll to abort cooperatively.
## Returns [code]self[/code] for chaining.
func mark_cancellable() -> MCPToolkitCommandOptions:
	_is_cancellable = true
	return self


## Marks the command as not requiring an open edited scene, so the dispatcher
## does not reject it when no scene is active. By default a command IS treated as
## requiring the active scene; call this for scene-independent tools (e.g. ones
## that only read project files).
## Returns [code]self[/code] for chaining.
func mark_scene_independent() -> MCPToolkitCommandOptions:
	_is_scene_independent = true
	return self


## Marks the command for exclusive execution, so the dispatcher serializes it
## against all other mutations even when it is also read-only (use for commands
## whose work must not overlap any other dispatch).
## Returns [code]self[/code] for chaining.
func mark_exclusive_execution() -> MCPToolkitCommandOptions:
	_exclusive_execution = true
	return self


## Restricts the command to a minimum engine version: when the running engine is
## older than [param version], the registry skips registration entirely so the
## command never appears. [param version] is [code]"major.minor"[/code] or
## [code]"major.minor.patch"[/code] (e.g. [code]"4.5"[/code]); an invalid format
## warns and is otherwise ignored. See [method with_max_godot_version] for the
## upper bound. Returns [code]self[/code] for chaining.
func with_min_godot_version(version: String) -> MCPToolkitCommandOptions:
	if not _is_valid_version(version):
		push_warning("[MCPToolkit] Invalid min_godot_version format: '%s' (expected 'major.minor', e.g. '4.5')" % version)
	_min_godot_version = version
	return self


## Restricts the command to a maximum engine version: when the running engine is
## newer than [param version], the registry skips registration. [param version]
## uses the same format as [method with_min_godot_version]; an invalid format
## warns and is ignored. Returns [code]self[/code] for chaining.
func with_max_godot_version(version: String) -> MCPToolkitCommandOptions:
	if not _is_valid_version(version):
		push_warning("[MCPToolkit] Invalid max_godot_version format: '%s' (expected 'major.minor', e.g. '4.6')" % version)
	_max_godot_version = version
	return self


## Sets the [param hint] auto-attached to a successful response when the handler
## did not set one itself, giving the caller follow-up guidance.
## Returns [code]self[/code] for chaining.
func with_success_hint(hint: String) -> MCPToolkitCommandOptions:
	_success_hint = hint
	return self


## Declares that the parameter named [param param] carries a [code]res://[/code]
## project path the dispatcher must validate (rejecting traversal/escape with
## [code]PATH_DENIED[/code]) BEFORE the handler runs. Use this for any LLM-supplied
## path an extension command reads or writes; built-in tools self-guard, so this is
## the declarative equivalent for extension commands. An absent or empty value at
## call time is left for the handler (it is not a rejection). See
## [method guard_user_path] for the [code]user://[/code] variant.
## Returns [code]self[/code] for chaining.
func guard_project_path(param: String) -> MCPToolkitCommandOptions:
	_path_guards[param] = "project"
	return self


## Like [method guard_project_path], but declares that the parameter named
## [param param] carries a [code]user://[/code] path. The dispatcher rejects
## traversal, non-[code]user://[/code] prefixes, and the plugin's own internal
## paths with a path-denied error before the handler runs.
## Returns [code]self[/code] for chaining.
func guard_user_path(param: String) -> MCPToolkitCommandOptions:
	_path_guards[param] = "user"
	return self


static func _is_valid_version(v: String) -> bool:
	var parts := v.split(".")
	if parts.size() < 2:
		return false
	return parts[0].is_valid_int() and parts[1].is_valid_int()


## Builds the options dictionary the registry stores for the command, collapsing
## every facet set on this builder into one metadata map. Keys with no meaningful
## value are omitted; [code]is_active_scene_required[/code] is the inverse of
## [method mark_scene_independent]. [method MCPToolkitCommandRegistry.add] calls
## this — you rarely call it directly. Returns the metadata dictionary.
func to_dict() -> Dictionary:
	var d := {
		"description": _description,
		"is_read_only": _is_read_only,
		"is_destructive": _is_destructive,
		"is_idempotent": _is_idempotent,
		"is_cancellable": _is_cancellable,
		"is_active_scene_required": not _is_scene_independent,
	}
	if _exclusive_execution:
		d["exclusive_execution"] = true
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
