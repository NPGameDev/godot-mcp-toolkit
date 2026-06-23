@tool
extends RefCounted
## SignalPairResolver unit tests: pure tree-resolution plus the missing-node /
## bad-signal / bad-method guards. Exercises the scene/ subsystem's signal-pair
## resolution logic headless via an injected root-resolver Callable.

const SignalPairResolver := preload("res://addons/godot_mcp_toolkit/scene/signal_pair_resolver.gd")


static func run(h) -> void:
	_test_signal_pair_resolver(h)


# --- SignalPairResolver (concern 007 C4) -----------------------------------
# The export-clean skeleton shared by the editor signal handlers and the runtime
# autoload. Pure logic over a tree whose root is supplied by an injected resolver
# Callable, so it is fully headless-testable: build a tiny Node tree, inject
# `func(): return root`, and assert the happy path plus each guard. Uses built-in
# Node signals/methods (`ready` / `queue_free`) so no custom class is needed.

static func _test_signal_pair_resolver(h) -> void:
	h.begin("SignalPairResolver (007 C4)")
	var root := Node.new()
	root.name = "Root"
	var src := Node.new()
	src.name = "Src"
	var tgt := Node.new()
	tgt.name = "Tgt"
	root.add_child(src)
	root.add_child(tgt)
	var resolver := func() -> Node: return root

	# resolve_node — empty / "." → root; named child → child; missing → null.
	h.ok(SignalPairResolver.resolve_node("", resolver) == root, "resolve_node '' → root")
	h.ok(SignalPairResolver.resolve_node(".", resolver) == root, "resolve_node '.' → root")
	h.ok(SignalPairResolver.resolve_node("Src", resolver) == src, "resolve_node 'Src' → child")
	h.ok(SignalPairResolver.resolve_node("Nope", resolver) == null, "resolve_node missing → null")
	# Null-root resolver → null (mirrors no edited scene / no live tree).
	var null_resolver := func() -> Node: return null
	h.ok(SignalPairResolver.resolve_node("Src", null_resolver) == null, "resolve_node null root → null")

	# list_signals_of — built-in Node has a `ready` signal in its signal list.
	var sig_list := SignalPairResolver.list_signals_of(src)
	var has_ready := false
	for entry in sig_list:
		if str(entry.get("name", "")) == "ready":
			has_ready = true
			break
	h.ok(has_ready, "list_signals_of → includes built-in 'ready' signal")

	# Happy path — Src.ready → Tgt.queue_free (both built-in to Node).
	var ok_params := {
		"source_path": "Src", "signal_name": "ready",
		"target_path": "Tgt", "method_name": "queue_free",
	}
	var r_ok := SignalPairResolver.resolve_pair(ok_params, resolver)
	h.ok(not r_ok.has("error"), "resolve_pair happy → no error")
	h.ok(r_ok.get("source") == src, "resolve_pair happy → source is Src")
	h.ok(r_ok.get("target") == tgt, "resolve_pair happy → target is Tgt")
	h.ok((r_ok.get("callable") as Callable) == Callable(tgt, "queue_free"),
			"resolve_pair happy → callable is Tgt.queue_free")

	# Guard: non-dict params.
	var r_nondict := SignalPairResolver.resolve_pair("nope", resolver)
	h.eq(str(r_nondict.get("code", "")), "INVALID_PARAMS", "resolve_pair non-dict → INVALID_PARAMS")

	# Guard: missing required field (method omitted).
	var r_missing := SignalPairResolver.resolve_pair({
		"source_path": "Src", "signal_name": "ready", "target_path": "Tgt",
	}, resolver)
	h.eq(str(r_missing.get("code", "")), "INVALID_PARAMS", "resolve_pair missing field → INVALID_PARAMS")

	# Guard: bad source path → NOT_FOUND (source).
	var r_bad_src := SignalPairResolver.resolve_pair({
		"source_path": "Ghost", "signal_name": "ready",
		"target_path": "Tgt", "method_name": "queue_free",
	}, resolver)
	h.eq(str(r_bad_src.get("code", "")), "NOT_FOUND", "resolve_pair bad source → NOT_FOUND")
	h.ok(str(r_bad_src.get("error", "")).contains("source node not found"),
			"resolve_pair bad source → 'source node not found' message")

	# Guard: bad signal → INVALID_PARAMS (signal not on source).
	var r_bad_sig := SignalPairResolver.resolve_pair({
		"source_path": "Src", "signal_name": "no_such_signal",
		"target_path": "Tgt", "method_name": "queue_free",
	}, resolver)
	h.eq(str(r_bad_sig.get("code", "")), "INVALID_PARAMS", "resolve_pair bad signal → INVALID_PARAMS")
	h.ok(str(r_bad_sig.get("error", "")).contains("not on"),
			"resolve_pair bad signal → 'not on' message")

	# Guard: bad target path → NOT_FOUND (target).
	var r_bad_tgt := SignalPairResolver.resolve_pair({
		"source_path": "Src", "signal_name": "ready",
		"target_path": "Ghost", "method_name": "queue_free",
	}, resolver)
	h.eq(str(r_bad_tgt.get("code", "")), "NOT_FOUND", "resolve_pair bad target → NOT_FOUND")
	h.ok(str(r_bad_tgt.get("error", "")).contains("target node not found"),
			"resolve_pair bad target → 'target node not found' message")

	# Guard: bad method → INVALID_PARAMS (method not on target).
	var r_bad_meth := SignalPairResolver.resolve_pair({
		"source_path": "Src", "signal_name": "ready",
		"target_path": "Tgt", "method_name": "no_such_method",
	}, resolver)
	h.eq(str(r_bad_meth.get("code", "")), "INVALID_PARAMS", "resolve_pair bad method → INVALID_PARAMS")
	h.ok(str(r_bad_meth.get("error", "")).contains("method"),
			"resolve_pair bad method → 'method' message")

	root.free()
	print("")
