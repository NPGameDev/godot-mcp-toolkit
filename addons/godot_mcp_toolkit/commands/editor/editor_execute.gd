@tool
extends RefCounted
## execute.code: evaluate a single GDScript expression (not statements) via the
## engine Expression class, against an editor-side scope node (the edited scene
## root, an explicit scope_path under it, or the editor base control as a
## fallback). Guards statement keywords, and on an execution failure appends a
## recovery hint (inaccessible global, load(), or chained-property access) built
## by the shared ExecuteHints helper — the same one the runtime handler uses.
##
## Stateless — the handler takes (parameters) and returns the response Dictionary.
## Reaches the Expression evaluator / EditorInterface directly; scope-path
## normalization and result serialization are reached via the Modules aliases.
## An extracted submodule of the editor-command group, reached via a `preload` alias.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Helpers = Modules.CommandHelpers
const Coerce = Modules.Coerce
const ExecuteHints = Modules.ExecuteHints


# -- Commands -----------------------------------------------------------------


static func cmd_execute_code(parameters: Dictionary) -> Dictionary:
	var code := str(parameters.get("code", ""))
	if code.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing code")

	# Statement keyword guard (same as runtime handler).
	var trimmed := code.strip_edges()
	for kw in ["var", "return", "func", "if", "for", "while", "class", "const", "match"]:
		if trimmed == kw or trimmed.begins_with(kw + " ") or trimmed.begins_with(kw + "\t") or trimmed.begins_with(kw + "\n"):
			return MCPToolkitError.fail("PARSE_ERROR",
				"execute_code only supports expressions, not statements. '%s' is a statement keyword. " % kw +
				"Use method calls, property access, or arithmetic instead.")

	# Resolve scope node.
	var scope_node: Node = null
	var scope_path := str(parameters.get("scope_path", ""))
	if scope_path.is_empty():
		var edited := EditorInterface.get_edited_scene_root()
		if edited != null:
			scope_node = edited
		else:
			# Fallback to editor base control so expressions still have a Node scope
			scope_node = EditorInterface.get_base_control()
	else:
		var edited := EditorInterface.get_edited_scene_root()
		if edited == null:
			return MCPToolkitError.fail("NO_SCENE", "No scene open — cannot resolve scope_path")
		scope_path = Helpers.normalize_editor_path(scope_path)
		scope_node = edited.get_node_or_null(NodePath(scope_path))
		if scope_node == null:
			return MCPToolkitError.fail("NOT_FOUND", "scope node not found: " + scope_path)

	var expr := Expression.new()
	var parse_err := expr.parse(code, PackedStringArray())
	if parse_err != OK:
		# Frame the raw Expression parser message so the failure is actionable:
		# execute_code parses a single GDScript EXPRESSION (no statements,
		# assignments, or blocks), which is the usual cause of a parse failure.
		return MCPToolkitError.fail("PARSE_ERROR",
			"could not parse the expression: %s. execute_code evaluates a single GDScript expression — no assignments, statements, or multi-line blocks. Use a method call, property access, or arithmetic." % expr.get_error_text())
	var result = expr.execute([], scope_node, false)
	if expr.has_execute_failed():
		var err_text := expr.get_error_text()
		err_text += ExecuteHints.build_hint(err_text, code)
		return MCPToolkitError.fail("EXECUTE_FAILED", err_text)
	return MCPToolkitSuccess.ok({"result": Coerce.serialize_value(result)})
