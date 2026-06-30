@tool
extends RefCounted
## Validates a {source, signal, target, method} quartet against a scene tree whose
## root the caller resolves and passes in, returning the connect-ready pair
## (source/target/callable/echoed paths+names) or a {code, error} dict. This is the
## structural skeleton shared by the editor signal handlers (Mode A) and the runtime
## autoload (Mode B): both resolve a node path against a root, then guard
## has_signal / has_method identically — the ONLY thing that differs is where the
## root comes from (the editor's edited-scene root vs the live SceneTree root), which
## the caller resolves itself and passes in as a Node.
##
## Deliberately bare: it returns the leanest validated pair (the runtime's historic
## shape). The editor wraps it and layers its friendly hint enrichment (instanced-
## scene hint, script-source method-walk) on top of a has_signal/has_method failure
## — that enrichment is editor-only and stays in the editor file (see the 007 §D
## rule-of-three caveat); forcing it into this shared shape would either taint this
## clean child or bloat the runtime path with dead editor logic.
##
## Export-clean by contract: the Mode-B runtime autoload preloads this file, and
## GDScript resolves identifiers at parse time (before any is_editor_hint() guard),
## so naming ANY editor-only class — or preloading a script that does — would
## parse-fail the autoload in an export template (godotengine/godot#91713, unfixed
## 4.2–4.6). The entire identifier set here is core (Node/Object/Callable/Dictionary)
## and it preloads nothing. Keep it that way: a grep for "Editor" must return zero
## non-comment hits.


## Resolves a single node path against the supplied scene-tree [param root].
##
## The skeleton both servers shared: a null root yields null (no scene / no live
## tree); an empty or "." path resolves to the root itself (so a caller wanting a
## top-level signal need not type the full path); anything else goes through
## get_node_or_null. [param root] is the editor's edited-scene root or the runtime's
## live SceneTree root — each caller resolves its own root and passes the Node, never
## a root-resolver Callable: a bare static-method reference used as a Callable
## mis-binds to a NIL self on Godot 4.2 and silently aborts, so this shared static
## helper takes the resolved value, not a Callable to call. The return is Variant
## because a missing node is a valid null result the caller branches on.
static func resolve_node(path: String, root: Node) -> Variant:
	if root == null:
		return null
	if path.is_empty() or path == ".":
		return root
	return root.get_node_or_null(path)


## Returns the [{name, args:[{name, type}]}] signal list of a node — the bare
## runtime shape (no connection walk; the editor's list adds connections itself).
static func list_signals_of(node: Object) -> Array:
	var out: Array = []
	for sig in node.get_signal_list():
		var args: Array = []
		for arg in sig.get("args", []):
			args.append({
				"name": str(arg.get("name", "")),
				"type": int(arg.get("type", 0)),
			})
		out.append({
			"name": str(sig.get("name", "")),
			"args": args,
		})
	return out


## Validates the {source, signal, target, method} quartet and returns either a
## {code, error} dict (INVALID_PARAMS / NOT_FOUND) or the connect-ready pair:
##   {source, target, source_path, target_path, signal_name, method_name, callable}.
##
## params accepts node_path OR source_path for the source. The caller is expected to
## have already normalized the paths it cares about (the editor normalizes /root/…
## paths before calling); this resolver treats the paths as given. [param root] is the
## scene-tree root both paths resolve against (see [method resolve_node]). The
## has_signal / has_method guards return the leanest message — the editor layers its
## richer hints on top of an INVALID_PARAMS failure by re-resolving the offending node
## itself.
static func resolve_pair(params: Variant, root: Node) -> Dictionary:
	if typeof(params) != TYPE_DICTIONARY:
		return {"code": "INVALID_PARAMS", "error": "params must be an object"}
	var source_path := str(params.get("node_path", params.get("source_path", "")))
	var signal_name := str(params.get("signal_name", ""))
	var target_path := str(params.get("target_path", ""))
	var method_name := str(params.get("method_name", ""))
	if source_path.is_empty() or signal_name.is_empty() \
			or target_path.is_empty() or method_name.is_empty():
		return {"code": "INVALID_PARAMS",
			"error": "node_path, signal_name, target_path, method_name are all required"}
	var source = resolve_node(source_path, root)
	if source == null:
		return {"code": "NOT_FOUND", "error": "source node not found: %s" % source_path}
	var target = resolve_node(target_path, root)
	if target == null:
		return {"code": "NOT_FOUND", "error": "target node not found: %s" % target_path}
	# Explicit bool — `source`/`target` are Variant (resolve_node return), so the
	# has_signal/has_method results need a typed receiver, not := inference.
	var has_sig: bool = source.has_signal(signal_name)
	if not has_sig:
		return {"code": "INVALID_PARAMS",
			"error": "signal %s not on %s" % [signal_name, source_path]}
	var has_meth: bool = target.has_method(method_name)
	if not has_meth:
		return {"code": "INVALID_PARAMS",
			"error": "method %s not on %s" % [method_name, target_path]}
	return {
		"source": source,
		"target": target,
		"source_path": source_path,
		"target_path": target_path,
		"signal_name": signal_name,
		"method_name": method_name,
		"callable": Callable(target, method_name),
	}
