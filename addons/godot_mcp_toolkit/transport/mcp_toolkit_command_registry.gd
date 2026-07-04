@tool
class_name MCPToolkitCommandRegistry
extends RefCounted
## Central dispatch table for MCP commands.
##
## Holds every registered command — built-in and extension — keyed by method name,
## and routes incoming calls to their handlers via [method call_command]. Built-in
## modules and extensions populate it with [method add], passing a
## [MCPToolkitCommandOptions] (or [MCPToolkitExtensionOptions]) that declares the
## command's contract; the per-command metadata it derives drives version gating,
## annotations, timeout clamping, path guards, and the read-only/serialization
## routing the dispatcher reads back through the various accessor methods here. It
## also exposes thin facades ([method create_options], [method fail],
## [method require], [method create_undo_action], [method queue_save], …) so a
## handler — including a C# one that cannot reach the GDScript statics directly — can
## build options, errors, and undo actions through this one object.[br]
## [br]
## An extension registers its commands by overriding
## [method MCPToolkitExtension.register], which receives the live registry:
## [codeblock]
## func register(registry, server):
##     registry.add("physics_list_bodies", _on_list_bodies,
##         MCPToolkitExtensionOptions.new("List all physics bodies").mark_read_only())
## [/codeblock]

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Audit = Modules.Audit
const FileGuard = Modules.FileGuard

const _DEFAULT_TIMEOUT_MS := 30000
const _MIN_TIMEOUT_MS := 1000
const _MAX_TIMEOUT_MS := 300000

var _commands: Dictionary = {}
var _extension_methods: Array[String] = []
var _version_blocked: Dictionary = {}  # method -> {min, max, engine}

# Extension-load collision guard. While an extension's register() runs (bracketed
# by the loader with begin/end_extension_load), any add() of a name that is ALREADY
# registered is REFUSED — recorded here, never written to _commands. This closes the
# accidental-reuse footgun at load time: a well-meaning author who reuses a built-in
# name (or the name of an already-loaded extension) inside register() gets an
# editor-facing error rather than a silent overwrite; first-loaded wins, atomically.
# The colliding add is a no-op at the moment it is attempted: no transient overwrite,
# no chance for the foreign handler's Callable to become GC-broken.
# Scope: guard is window-scoped — only active during register(). An extension that
# stashes the registry reference and calls add() after register() returns (via a
# signal, timer, or deferred call) still lands as last-writer-wins. That path is out
# of scope by design (ADR 0009 — installed extensions are full-trust in-process code;
# the guard protects against accidental collision, not deliberate post-load adds).
# The loader drains _ext_load_refused after register() and surfaces the error to the
# editor only — never into the MCP response stream. See extension_loader.gd and
# docs/extending.md (collision policy: first-loaded wins within the load window).
var _ext_load_guard_active := false
var _ext_load_refused: Array[Dictionary] = []  # [{method, description}]


## Open the extension-load collision window. While open, add() refuses any name
## already present (records it to the refused list instead of overwriting).
## The loader calls this immediately before invoking an extension's register().
func begin_extension_load() -> void:
	_ext_load_guard_active = true
	_ext_load_refused.clear()


## Close the extension-load collision window and return the names refused during
## it (each {method, description}), so the loader can raise an editor-facing
## error attributing the collision to the offending extension. Returns [] when
## nothing collided.
func end_extension_load() -> Array[Dictionary]:
	_ext_load_guard_active = false
	var refused: Array[Dictionary] = _ext_load_refused.duplicate()
	_ext_load_refused.clear()
	return refused


## Registers the command named [param method], dispatched to [param handler], with
## the contract declared by [param options]. The handler is a [Callable] taking the
## parameters [Dictionary] (and, for a cancellable command, a
## [MCPToolkitToolContext]) and returning a response [Dictionary]. This is the
## single registration entry point for both built-in modules and extensions.[br]
## [br]
## From [param options] it derives and stores the command's metadata, applying
## several rules: a command outside the running engine's
## [method MCPToolkitCommandOptions.with_min_godot_version] /
## [method MCPToolkitCommandOptions.with_max_godot_version] range is recorded as
## version-blocked and NOT registered; read-only and destructive together are
## contradictory, so destructive is forced off with a warning; and the timeout is
## clamped (a non-positive value becomes the 30 s default, a positive one is floored
## at 1 s and capped at 300 s). During a bracketed extension load (see
## [method begin_extension_load]) an [param method] that already exists is refused
## rather than overwritten.[br]
## [br]
## [codeblock]
## registry.add("physics_list_bodies", _on_list_bodies,
##     MCPToolkitExtensionOptions.new("List all physics bodies").mark_read_only())
## [/codeblock]
func add(method: String, handler: Callable,
		options: MCPToolkitCommandOptions) -> void:
	# Collision guard (active only during a bracketed extension load): refuse to
	# overwrite an existing command. Recorded for the loader to report; the write
	# below never happens, so the incumbent handler is left fully intact.
	if _ext_load_guard_active and _commands.has(method):
		_ext_load_refused.append({
			"method": method,
			"description": options.to_dict().get("description", ""),
		})
		return

	var opts: Dictionary = options.to_dict()

	# Version gate: block commands incompatible with the running engine.
	var min_ver: String = opts.get("min_godot_version", "")
	var max_ver: String = opts.get("max_godot_version", "")
	if min_ver != "" or max_ver != "":
		var engine_ver := Modules.VersionUtils.get_engine_version_pair()
		if not Modules.VersionUtils.is_version_in_range(engine_ver, min_ver, max_ver):
			_version_blocked[method] = {"min": min_ver, "max": max_ver, "engine": engine_ver}
			return

	var is_read_only: bool = opts.get("is_read_only", false)
	var is_destructive: bool = opts.get("is_destructive", false)
	var is_idempotent: bool = opts.get("is_idempotent", false)

	# Exclusivity validation: read-only + destructive is a contradiction.
	if is_read_only and is_destructive:
		push_warning("[MCPExtensions] '%s': is_read_only and is_destructive are mutually exclusive - forcing is_destructive to false" % method)
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
			push_warning("[MCPExtensions] '%s': timeout_ms %d exceeds maximum %d - clamped. Consider restructuring the tool to use a start-work-and-poll pattern." % [method, raw_timeout, _MAX_TIMEOUT_MS])
		timeout_ms = clampi(raw_timeout, _MIN_TIMEOUT_MS, _MAX_TIMEOUT_MS)

	var cmd_entry := {
		"handler": handler,
		"description": opts.get("description", ""),
		"input_schema": opts.get("input_schema", {}),
		"annotations": annotations,
		"group": opts.get("group", {}),
		"timeout_ms": timeout_ms,
		"timeout_declared": raw_timeout > 0,  # author set a positive timeout_ms (vs defaulted)
		"is_cancellable": bool(opts.get("is_cancellable", false)),
		"read_only": is_read_only,
		"active_scene_required": bool(opts.get("is_active_scene_required", true)),
		"exclusive_execution": bool(opts.get("exclusive_execution", false)),
		"success_hint": opts.get("success_hint", ""),
		"path_guards": opts.get("path_guards", {}),
	}
	if min_ver != "":
		cmd_entry["min_godot_version"] = min_ver
	if max_ver != "":
		cmd_entry["max_godot_version"] = max_ver
	_commands[method] = cmd_entry


## Unregisters the command named [param method], removing both its handler and its
## extension marking (if any). A no-op when the command is not registered.
func remove(method: String) -> void:
	_commands.erase(method)
	var idx := _extension_methods.find(method)
	if idx >= 0:
		_extension_methods.remove_at(idx)


## Returns the names of all currently registered commands.
func get_all_methods() -> Array:
	return _commands.keys()


## Marks the command named [param method] as extension-provided (as opposed to
## built-in). Idempotent. The extension loader calls this after [method add] so the
## bridge can tell extension commands apart; see [method get_extension_methods].
func mark_extension(method: String) -> void:
	if method not in _extension_methods:
		_extension_methods.append(method)


## Returns a copy of the names marked as extension commands via
## [method mark_extension].
func get_extension_methods() -> Array[String]:
	return _extension_methods.duplicate()


## Returns the stored metadata for `method`, including its annotations dict.
## NOTE: this dict is consumed ONLY via the extension path — extension_loader
## and extension services iterate it to describe extension commands to the bridge.
## Built-in client-visible annotations (readOnlyHint/destructiveHint/idempotentHint)
## are SERVER-authoritative (server src/catalogue.ts → MCP tools/list); the server
## never calls this function. mark_read_only() on built-ins is load-bearing for
## routing/serialization (needs_serialization), not the client hint.
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


## Returns [code]true[/code] if a command named [param method] is registered.
func has_command(method: String) -> bool:
	return _commands.has(method)


## Watchdog deadline basis for `method`. If the author DECLARED a timeout we
## trust it (their stated contract — built-ins + careful extensions get a tight,
## appropriate deadline); if not (the command falls back to the 30 s default,
## which isn't a deliberate statement about its duration) we use _MAX_TIMEOUT_MS
## so an undeclared-but-slow method is never force-cleared early.
func get_watchdog_timeout_ms(method: String) -> int:
	if not _commands.has(method):
		return _MAX_TIMEOUT_MS
	var entry: Dictionary = _commands[method]
	if bool(entry.get("timeout_declared", false)):
		return int(entry.get("timeout_ms", _MAX_TIMEOUT_MS))
	return _MAX_TIMEOUT_MS


## Returns [code]true[/code] if the command named [param method] was registered as
## cancellable (see [method MCPToolkitCommandOptions.mark_cancellable]), meaning the
## dispatcher passes it a [MCPToolkitToolContext]. [code]false[/code] for an unknown
## command.
func is_cancellable(method: String) -> bool:
	if not _commands.has(method):
		return false
	return _commands[method].get("is_cancellable", false)


## Returns [code]true[/code] if the command named [param method] was marked
## read-only (see [method MCPToolkitCommandOptions.mark_read_only]).
## [code]false[/code] for an unknown command.
func is_read_only(method: String) -> bool:
	var cmd = _commands.get(method)
	return cmd != null and cmd.get("read_only", false)


## Declarative path guards for `method` ({param -> "project"|"user"}), or {} if
## none. Populated from MCPToolkitCommandOptions.guard_project_path/guard_user_path.
func path_guards(method: String) -> Dictionary:
	var cmd = _commands.get(method)
	if cmd == null:
		return {}
	return cmd.get("path_guards", {})


## Returns [code]true[/code] if the command named [param method] requires an open
## edited scene, i.e. it was NOT marked scene-independent (see
## [method MCPToolkitCommandOptions.mark_scene_independent]); a registered command
## defaults to [code]true[/code]. [code]false[/code] for an unknown command.
func is_active_scene_required(method: String) -> bool:
	var cmd = _commands.get(method)
	return cmd != null and cmd.get("active_scene_required", true)


## Returns [code]true[/code] if the command named [param method] was marked for
## exclusive execution (see
## [method MCPToolkitCommandOptions.mark_exclusive_execution]). [code]false[/code]
## for an unknown command.
func is_exclusive_execution(method: String) -> bool:
	var cmd = _commands.get(method)
	return cmd != null and cmd.get("exclusive_execution", false)


## Returns [code]true[/code] if calls to the command named [param method] must be
## serialized against mutations — i.e. it is exclusive, or it is not read-only.
## Read-only, non-exclusive commands return [code]false[/code] (they may run
## concurrently). An unknown command returns [code]true[/code] (the safe default).
func needs_serialization(method: String) -> bool:
	if not _commands.has(method):
		return true  # Safe default for unknown commands.
	if is_exclusive_execution(method):
		return true
	return not is_read_only(method)


## Returns a fresh [MCPToolkitCommandOptions] builder. A convenience facade so a
## handler (notably a C# one that cannot reach the GDScript [code]new()[/code]
## directly) can build options through the registry. Returns the new builder.
func create_options() -> MCPToolkitCommandOptions:
	return MCPToolkitCommandOptions.new()


## Returns a fresh [MCPToolkitExtensionOptions] builder seeded with
## [param description]. A facade equivalent to
## [code]MCPToolkitExtensionOptions.new(description)[/code], reachable through the
## registry by a C# handler. Returns the new builder.
func create_extension_options(description: String) -> MCPToolkitExtensionOptions:
	return MCPToolkitExtensionOptions.new(description)


## Begins an undo action named [param description] (optionally scoped to
## [param context_object]) and returns its [MCPToolkitUndoRedoAction] builder. A
## facade over [method MCPToolkitUndoRedoAction.begin] so a C# handler — which
## cannot call that GDScript static — can build undo actions through the registry.
func create_undo_action(description: String, context_object: Object = null) -> MCPToolkitUndoRedoAction:
	return MCPToolkitUndoRedoAction.begin(description, context_object)


## Editor-safe scene save for extension handlers — wraps MCPToolkitSafeSceneOps
## (just as create_undo_action wraps MCPToolkitUndoRedoAction), so C# handlers
## (which can't await or call GDScript statics) reach it through this single
## registry facade. Usage: `id = registry.Call("queue_save", path)`, then poll
## `registry.Call("check_save", id [, clear])` until `done` is true. The save
## runs after the handler returns (C2 scan-idle + C1 re-entrancy guards apply).
func queue_save(path := "") -> String:
	return MCPToolkitSafeSceneOps.queue_save(path)


## Polls a queued save by [param save_id], optionally clearing the record when
## [param clear] is true and the save is done. A facade over
## [method MCPToolkitSafeSceneOps.check_save] (paired with [method queue_save]) for
## a synchronous/C# handler. Returns the same status dictionary that method does.
func check_save(save_id: String, clear := false) -> Dictionary:
	return MCPToolkitSafeSceneOps.check_save(save_id, clear)


## Removes every registered command and clears the extension-marking and
## version-blocked state. Used at plugin teardown to break handler [Callable]
## references before the editor's exit-time leak check.
func clear() -> void:
	_commands.clear()
	_extension_methods.clear()
	_version_blocked.clear()


## Builds a failure response with [param code], [param message], and an optional
## [param hint]. A facade over [method MCPToolkitError.fail] so a handler can
## return errors through the registry. Returns the failure dictionary.
func fail(code: String, message: String, hint: String = "") -> Dictionary:
	return MCPToolkitError.fail(code, message, hint)


## Validates that every key in [param required] is present and non-empty in
## [param parameters]. A facade over [method MCPToolkitError.require]: returns
## [code]null[/code] when satisfied, or an [code]INVALID_PARAMS[/code] error dict
## for the first missing key.
func require(parameters: Dictionary, required: Array) -> Variant:
	return MCPToolkitError.require(parameters, required)


## Dispatches a registered command (this is a coroutine — call it with
## [code]await[/code]). Looks up [param method], runs its declared path guards
## against [param parameters], invokes the handler (passing [param ctx] when the
## command is cancellable), and enforces the response contract before returning.[br]
## [br]
## Returns the handler's response [Dictionary], or an error dict when: the command
## is unknown ([code]NOT_FOUND[/code], or [code]UNSUPPORTED[/code] when it was
## version-blocked for the running engine); a guarded path is rejected
## ([code]PATH_DENIED[/code]); or the handler violates the contract by returning a
## non-dictionary or omitting the [code]success[/code] key ([code]INTERNAL[/code]).
## On a successful response with no hint, the command's registered success hint (if
## any) is attached. [param ctx] is the per-invocation [MCPToolkitToolContext] for a
## cancellable command, or [code]null[/code].
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
			return MCPToolkitError.fail("UNSUPPORTED",
				"%s %s (connected: %s)" % [method, detail, info["engine"]])
		return MCPToolkitError.fail("NOT_FOUND", "unknown method: " + method)
	Audit.log_call(method, parameters)

	# Declarative path guards (extension commands) — validate a declared path param
	# BEFORE the handler runs. Built-ins declare none (they self-guard via FileGuard
	# inside the handler), so this loop is a no-op for them. Absent/empty values
	# defer to the handler (an unprovided optional path is not a rejection).
	# Toolkit-side only; the server does not see these. See docs/adr/0009.
	var guards: Dictionary = _commands[method].get("path_guards", {})
	for param in guards:
		var raw = parameters.get(param, "")
		if not (raw is String) or (raw as String).strip_edges().is_empty():
			continue
		if str(guards[param]) == "user":
			var ug: Dictionary = FileGuard.resolve_safe_user(raw)
			if not ug.get("ok", false):
				return MCPToolkitError.fail(
					str(ug.get("error_code", "PATH_DENIED")), str(ug.get("error_message", "path denied")))
		else:
			var pg: Dictionary = FileGuard.resolve_safe(raw)
			if pg.get("error") != null:
				return MCPToolkitError.fail("PATH_DENIED", str(pg.get("reason", "path denied")))

	var result
	if ctx != null:
		result = await _commands[method]["handler"].call(parameters, ctx)
	else:
		result = await _commands[method]["handler"].call(parameters)

	# ── Response contract enforcement ──
	if not result is Dictionary:
		push_error("[MCPToolkit] Handler for '%s' returned non-Dictionary (%s)" % [method, type_string(typeof(result))])
		return MCPToolkitError.fail("INTERNAL", "Handler for %s returned non-Dictionary" % method)

	if not result.has("success"):
		push_error("[MCPToolkit] Handler for '%s' returned Dictionary without 'success' key" % method)
		return MCPToolkitError.fail("INTERNAL", "Handler for %s returned Dictionary without 'success' key" % method)

	# ── Auto-inject registered success hint if handler didn't set one ──
	# NOTE: Hint injection lives here (toolkit-side) for extension tools.
	# Built-in tools get hints injected server-side in callAndWrap().
	# Both use result["hint"] as the contract surface — no double injection.
	var sh: String = _commands[method].get("success_hint", "")
	if sh != "" and result.get("success", false) and not result.has("hint"):
		result["hint"] = sh

	return result
