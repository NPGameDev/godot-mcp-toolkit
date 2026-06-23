@tool
extends RefCounted
## Safe-scene-ops public API + ToolContext cancellation unit tests. Exercises the
## scene/ subsystem's headless-safe surface (is_dispatching / check_save pure dict
## logic) and the cooperative-cancellation context.

const _SafeSceneOps := preload("res://addons/godot_mcp_toolkit/scene/mcp_toolkit_safe_scene_ops.gd")


static func run(h) -> void:
	_test_safe_scene_ops(h)
	_test_tool_context(h)


# --- MCPToolkitSafeSceneOps public API (Fix 1, 41l-tricies) ----------------
# is_dispatching() is the pure, headless-testable surface. wait_for_scan_idle /
# save_scene / queue_save touch EditorInterface (null in this --script runner),
# so they are covered by the smoke suite + the editor-required dispatch
# integration / A-B validation that exercise editor_save_scene end to end.

static func _test_safe_scene_ops(h) -> void:
	h.begin("MCPToolkitSafeSceneOps (public API)")
	h.ok(not _SafeSceneOps.is_dispatching(), "is_dispatching → false by default")
	_SafeSceneOps._in_dispatch = true
	h.ok(_SafeSceneOps.is_dispatching(), "is_dispatching → true when _in_dispatch set")
	_SafeSceneOps._in_dispatch = false
	h.ok(not _SafeSceneOps.is_dispatching(), "is_dispatching → false after reset")

	# C# reaches the safe-save API through the registry facade (like
	# create_undo_action), so verify the registry bridge forwards to SafeSceneOps.
	# (queue_save fires the editor-coupled save → integration-tested; check_save
	# is pure dict logic → testable here.)
	var _reg := MCPToolkitCommandRegistry.new()
	h.ok(_reg.check_save("nope").get("unknown", false),
			"registry.check_save bridge → forwards to SafeSceneOps")

	# check_save — pure dict logic; seed _save_results directly to bypass the
	# editor-coupled save in queue_save/_run_queued_save.
	_SafeSceneOps._save_results = {}
	h.ok(_SafeSceneOps.check_save("nope").get("unknown", false),
			"check_save(unknown id) → unknown:true")
	_SafeSceneOps._save_results["s1"] = {"done": false}
	h.ok(not _SafeSceneOps.check_save("s1").get("done", true),
			"pending save → done:false")
	_SafeSceneOps._save_results["s1"] = {"done": true, "success": true}
	h.ok(_SafeSceneOps.check_save("s1").get("success", false),
			"completed save → success:true")
	_SafeSceneOps.check_save("s1", true)  # clear a done save
	h.ok(_SafeSceneOps.check_save("s1").get("unknown", false),
			"check_save(clear) on done → record removed")
	_SafeSceneOps._save_results["s2"] = {"done": false}
	_SafeSceneOps.check_save("s2", true)  # clear a pending save → no-op
	h.ok(_SafeSceneOps._save_results.has("s2"),
			"check_save(clear) on pending → kept")
	_SafeSceneOps._save_results = {}  # reset the shared static
	print("")


# --- ToolContext cancellation (~3 assertions) ------------------------------

static func _test_tool_context(h) -> void:
	h.begin("ToolContext cancellation")

	# 1. fresh → is_cancelled false
	var ctx := MCPToolkitToolContext.new()
	h.ok(not ctx.is_cancelled(), "fresh context → is_cancelled false")

	# 2. cancel → is_cancelled true
	ctx.cancel()
	h.ok(ctx.is_cancelled(), "after cancel → is_cancelled true")

	# 3. cancelled signal fires synchronously
	var ctx2 := MCPToolkitToolContext.new()
	var fired := [false]
	ctx2.cancelled.connect(func(): fired[0] = true)
	ctx2.cancel()
	h.ok(fired[0], "cancel → cancelled signal fires")

	print("")
