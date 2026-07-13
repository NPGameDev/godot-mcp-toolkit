@tool
extends RefCounted
## Recovery hints appended to an execute_code failure message.
##
## execute_code evaluates a single GDScript expression through the engine
## Expression class. Expression resolves every bare identifier as a property
## lookup on the scope object (`self`) — it has no notion of global names — so a
## reference to an engine singleton, a project autoload, or a global class_name
## fails with "Invalid named index '<Name>' for base type Object", and load()
## cannot be called at all. These helpers turn those opaque engine strings into an
## actionable next step. Pure string logic; safe in both the editor and runtime
## handlers, which share it so the guidance stays identical.

## Engine singletons that are reachable in normal GDScript but not through
## Expression. Named explicitly so the hint can call one out by name; any other
## unresolved global (an autoload, a global class) is caught by the generic
## bare-identifier branch instead.
const _ENGINE_SINGLETONS: Array[String] = [
	"EditorInterface",
	"Engine",
	"OS",
	"Input",
	"DisplayServer",
	"ProjectSettings",
	"ResourceLoader",
	"ResourceSaver",
	"RenderingServer",
	"PhysicsServer2D",
	"PhysicsServer3D",
]


## Returns the hint to append to [param err_text] (an [code]EXECUTE_FAILED[/code]
## message from a failed [code]Expression.execute()[/code]), given the original
## [param code] the caller ran. Empty when no known failure shape is recognised.
##
## Recognises three shapes, in priority order: an inaccessible bare global
## (engine singleton, autoload, or global class named at the start of an access
## chain), a [code]load()[/code] call (which Expression cannot make), and property
## access chained on a returned object. The leading-global check runs before the
## generic chained-access check because both surface as the same
## "Invalid named index … base type Object" string, and the global reading is the
## more accurate one when the failed name begins the expression.
static func build_hint(err_text: String, code: String) -> String:
	var global_hint := _bare_global_hint(err_text, code)
	if not global_hint.is_empty():
		return global_hint
	var lower_err := err_text.to_lower()
	if "'load'" in lower_err and ("call to" in lower_err or "function" in lower_err):
		return _load_hint(code)
	if "invalid named index" in lower_err and "base type object" in lower_err:
		return (
			"\n\nHint: Expression.execute() cannot chain property access on returned objects. "
			+ "Use runtime_get_node_state or node_call_method for multi-step property access."
		)
	return ""


## Hint for a bare global that Expression can't resolve, or [code]""[/code] when the
## failure is not that shape. [param err_text] is the failed message; [param code]
## is the expression, used to confirm the failed name is a leading global reference
## (not a property reached through a chain, which is a different, correctly-framed
## failure). Names the identifier and, when it is a known engine singleton, says so.
static func _bare_global_hint(err_text: String, code: String) -> String:
	var re := RegEx.new()
	re.compile("Invalid named index '([^']+)' for base type Object")
	var m := re.search(err_text)
	if m == null:
		return ""
	var identifier := m.get_string(1)
	if not _is_leading_reference(code, identifier):
		return ""
	var kind := "a global singleton" if identifier in _ENGINE_SINGLETONS else "a global (autoload or global class)"
	return (
		"\n\nHint: '%s' is %s, which is not accessible in execute_code. " % [identifier, kind]
		+ "Expression.execute() resolves a bare identifier as a property of the scope node, "
		+ "not as a global name, so no singleton, autoload, or class_name is reachable this way. "
		+ "Use the dedicated MCP tools instead — e.g. runtime_get_node_state or node_call_method "
		+ "to read a node's live state, project_get_settings for ProjectSettings, or (for a running "
		+ "game) drive the node whose script already references the global."
	)


## Whether [param name] appears in [param code] as a leading global reference — the
## first token, at the head of the expression or a sub-expression, not preceded by a
## [code].[/code] (which would make it a property reached through a chain). Anchors
## the match so [code]OS[/code] does not match [code]node.get_class_OS[/code].
static func _is_leading_reference(code: String, name: String) -> bool:
	var re := RegEx.new()
	re.compile("(?:^|[^\\w.])%s\\b" % _escape_regex(name))
	return re.search(code) != null


## Escapes the RegEx metacharacters that a Godot identifier can never contain but a
## defensive caller should still not inject unescaped. Identifiers are
## [code][A-Za-z0-9_][/code] only, so this is belt-and-suspenders.
static func _escape_regex(text: String) -> String:
	var out := ""
	for chr in text:
		if chr in "\\^$.|?*+()[]{}":
			out += "\\"
		out += chr
	return out


## Hint for a [code]load()[/code] call, which Expression cannot make in any context.
## Both recovery paths are always offered — assigning a resource and running script
## logic — because either could be the caller's intent; the detected target only
## orders which leads. [param code] is the expression, scanned for the load() target.
static func _load_hint(code: String) -> String:
	var re := RegEx.new()
	re.compile("load\\s*\\(\\s*[\"']([^\"']+)[\"']\\s*\\)")
	var m := re.search(code)
	var script_first := m != null and m.get_string(1).ends_with(".gd")
	var assign_remedy := (
		"To assign the resource, use node_set_property with "
		+ "{\"type\": \"Resource\", \"path\": \"res://...\"}."
	)
	var script_remedy := (
		"To run GDScript logic in the editor: "
		+ "(1) write a @tool script with script_write, "
		+ "(2) create a temporary node with scene_create_node, "
		+ "(3) attach the script with node_set_script, "
		+ "(4) call the method with node_call_method, "
		+ "(5) delete the temp node with node_manage(action:'delete')."
	)
	var lead := script_remedy if script_first else assign_remedy
	var follow := assign_remedy if script_first else script_remedy
	return (
		"\n\nHint: Expression.execute() cannot call load() in any context (editor or runtime). "
		+ lead + " " + follow
	)
