@tool
extends RefCounted
## SignalPairResolver unit tests: pure tree-resolution plus the missing-node /
## bad-signal / bad-method guards, and the 4.2 static-Callable regression guard.
## Exercises the scene/ subsystem's signal-pair resolution logic headless against a
## synthetic root Node passed directly.

const SignalPairResolver := preload("res://addons/godot_mcp_toolkit/scene/signal_pair_resolver.gd")


static func run(testing) -> void:
	_test_signal_pair_resolver(testing)
	_test_no_static_callable_indirection_regression(testing)


# --- SignalPairResolver (tree resolution + guards) -------------------------
# The export-clean skeleton shared by the editor signal handlers and the runtime
# autoload. Pure logic over a tree whose root the caller resolves and passes in as a
# Node, so it is fully headless-testable: build a tiny Node tree, pass `root`, and
# assert the happy path plus each guard. Uses built-in Node signals/methods
# (`ready` / `queue_free`) so no custom class is needed.

static func _test_signal_pair_resolver(testing) -> void:
	testing.begin("SignalPairResolver (tree resolution + guards)")
	var root := Node.new()
	root.name = "Root"
	var src := Node.new()
	src.name = "Src"
	var tgt := Node.new()
	tgt.name = "Tgt"
	root.add_child(src)
	root.add_child(tgt)

	# resolve_node — empty / "." → root; named child → child; missing → null. The
	# root is passed as a Node directly (no resolver Callable — see resolve_node).
	testing.ok(SignalPairResolver.resolve_node("", root) == root, "resolve_node '' → root")
	testing.ok(SignalPairResolver.resolve_node(".", root) == root, "resolve_node '.' → root")
	testing.ok(SignalPairResolver.resolve_node("Src", root) == src, "resolve_node 'Src' → child")
	testing.ok(SignalPairResolver.resolve_node("Nope", root) == null, "resolve_node missing → null")
	# Null root → null (mirrors no edited scene / no live tree).
	var null_root: Node = null
	testing.ok(SignalPairResolver.resolve_node("Src", null_root) == null, "resolve_node null root → null")

	# list_signals_of — built-in Node has a `ready` signal in its signal list.
	var sig_list := SignalPairResolver.list_signals_of(src)
	var has_ready := false
	for entry in sig_list:
		if str(entry.get("name", "")) == "ready":
			has_ready = true
			break
	testing.ok(has_ready, "list_signals_of → includes built-in 'ready' signal")

	# Happy path — Src.ready → Tgt.queue_free (both built-in to Node).
	var ok_params := {
		"source_path": "Src", "signal_name": "ready",
		"target_path": "Tgt", "method_name": "queue_free",
	}
	var r_ok := SignalPairResolver.resolve_pair(ok_params, root)
	testing.ok(not r_ok.has("error"), "resolve_pair happy → no error")
	testing.ok(r_ok.get("source") == src, "resolve_pair happy → source is Src")
	testing.ok(r_ok.get("target") == tgt, "resolve_pair happy → target is Tgt")
	testing.ok((r_ok.get("callable") as Callable) == Callable(tgt, "queue_free"),
			"resolve_pair happy → callable is Tgt.queue_free")

	# Guard: non-dict params.
	var r_nondict := SignalPairResolver.resolve_pair("nope", root)
	testing.eq(str(r_nondict.get("code", "")), "INVALID_PARAMS", "resolve_pair non-dict → INVALID_PARAMS")

	# Guard: missing required field (method omitted).
	var r_missing := SignalPairResolver.resolve_pair({
		"source_path": "Src", "signal_name": "ready", "target_path": "Tgt",
	}, root)
	testing.eq(str(r_missing.get("code", "")), "INVALID_PARAMS", "resolve_pair missing field → INVALID_PARAMS")

	# Guard: bad source path → NOT_FOUND (source).
	var r_bad_src := SignalPairResolver.resolve_pair({
		"source_path": "Ghost", "signal_name": "ready",
		"target_path": "Tgt", "method_name": "queue_free",
	}, root)
	testing.eq(str(r_bad_src.get("code", "")), "NOT_FOUND", "resolve_pair bad source → NOT_FOUND")
	testing.ok(str(r_bad_src.get("error", "")).contains("source node not found"),
			"resolve_pair bad source → 'source node not found' message")

	# Guard: bad signal → INVALID_PARAMS (signal not on source).
	var r_bad_sig := SignalPairResolver.resolve_pair({
		"source_path": "Src", "signal_name": "no_such_signal",
		"target_path": "Tgt", "method_name": "queue_free",
	}, root)
	testing.eq(str(r_bad_sig.get("code", "")), "INVALID_PARAMS", "resolve_pair bad signal → INVALID_PARAMS")
	testing.ok(str(r_bad_sig.get("error", "")).contains("not on"),
			"resolve_pair bad signal → 'not on' message")

	# Guard: bad target path → NOT_FOUND (target).
	var r_bad_tgt := SignalPairResolver.resolve_pair({
		"source_path": "Src", "signal_name": "ready",
		"target_path": "Ghost", "method_name": "queue_free",
	}, root)
	testing.eq(str(r_bad_tgt.get("code", "")), "NOT_FOUND", "resolve_pair bad target → NOT_FOUND")
	testing.ok(str(r_bad_tgt.get("error", "")).contains("target node not found"),
			"resolve_pair bad target → 'target node not found' message")

	# Guard: bad method → INVALID_PARAMS (method not on target).
	var r_bad_meth := SignalPairResolver.resolve_pair({
		"source_path": "Src", "signal_name": "ready",
		"target_path": "Tgt", "method_name": "no_such_method",
	}, root)
	testing.eq(str(r_bad_meth.get("code", "")), "INVALID_PARAMS", "resolve_pair bad method → INVALID_PARAMS")
	testing.ok(str(r_bad_meth.get("error", "")).contains("method"),
			"resolve_pair bad method → 'method' message")

	root.free()
	print("")


# --- Regression guard: 4.2 static-Callable indirection ---
# resolve_pair / resolve_node take the scene-tree root as a Node passed directly, NOT
# a root-resolver Callable. The earlier Callable form regressed signal.manage on Godot
# 4.2 ONLY: signal_commands.gd resolved the pair from a `static` function and passed a
# bare static-method reference as the Callable; on 4.2 a bare member-function reference
# binds to a NIL self, so resolve_node's `root_resolver.call()` aborted and the handler
# silently returned the typed-default {} (no `success` key) — surfacing to the bridge as
# INTERNAL. Fixed upstream between 4.2 and 4.5; we side-stepped it by passing the resolved
# Node. This guard locks that contract: with a Node root the production path resolves a
# full pair and never yields the empty typed-default. No Callable is formed here, so it
# passes identically on 4.2–4.7 (CI now runs the 4.2 unit suite, which catches this class), and
# reintroducing a Callable parameter breaks the Node argument below.
static func _test_no_static_callable_indirection_regression(testing) -> void:
	testing.begin("SignalPairResolver — no static-Callable indirection (4.2 regression guard)")
	var root := Node.new()
	root.name = "Root"
	var src := Node.new()
	src.name = "Src"
	var tgt := Node.new()
	tgt.name = "Tgt"
	root.add_child(src)
	root.add_child(tgt)

	# resolve_node with a Node root resolves the child — the aborted Callable path
	# would have yielded null instead.
	testing.ok(SignalPairResolver.resolve_node("Src", root) == src,
			"resolve_node(Node root) → child, not an aborted null")

	# resolve_pair with a Node root returns the fully-resolved pair — crucially NOT the
	# empty {} the 4.2 abort produced. An empty dict has neither 'error' NOR 'source', so
	# assert both non-emptiness and the resolved members.
	var resolved := SignalPairResolver.resolve_pair({
		"source_path": "Src", "signal_name": "ready",
		"target_path": "Tgt", "method_name": "queue_free",
	}, root)
	testing.ok(not resolved.is_empty(),
			"resolve_pair(Node root) → populated dict, not the typed-default {}")
	testing.ok(not resolved.has("error"), "resolve_pair(Node root) → no error")
	testing.ok(resolved.has("source") and resolved.get("source") == src,
			"resolve_pair(Node root) → source resolved to Src")
	testing.ok((resolved.get("callable") as Callable) == Callable(tgt, "queue_free"),
			"resolve_pair(Node root) → callable is Tgt.queue_free")

	root.free()
	print("")
