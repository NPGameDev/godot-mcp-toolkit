@tool
extends RefCounted
## Unit tests for the editor screenshot's fresh-frame wait, await_fresh_frame().
##
## No unit can reach the handler's four wait sites: in this headless runner the
## handler answers HEADLESS_UNSUPPORTED before any of them. A headless run never
## draws, though, so the real RenderingServer.frame_post_draw never fires here,
## which is the idle editor the wait must survive. Each group passes a short bound,
## never the handler's default. The groups test the helper directly and need it to
## exist; the single-seam guard in screenshot_classify_tests.gd checks that the
## handler waits only through it. The lapse and redraw groups cover, without a
## window, the paths the windowed idle probe exercises against a live editor.

const EditorScreenshot := preload("res://addons/godot_mcp_toolkit/commands/editor/editor_screenshot.gd")

# Short enough to keep the suite fast, long enough to tell from the default bound.
const _SHORT_BOUND_SECONDS := 0.2
const _SHORT_BOUND_MSEC := 200
# Slack past the bound for the few process frames the poll may take to notice it;
# well under the default bound, so a wait that ignored the short one still fails.
const _LAPSE_SLACK_MSEC := 500
# Process frames before the stand-in signal fires in the late-frame group.
const _LATE_FRAME_DELAY := 3
const _STAND_IN_SIGNAL := "frame_drawn"


## run() is a coroutine: every group awaits the helper, so the runner must
## [code]await[/code] it. [param tree] is the runner itself: Engine.get_main_loop() is
## still null while the runner's _init runs, and its root joins the tree only after
## a frame.
static func run(testing, tree: SceneTree) -> void:
	await tree.process_frame
	await _test_idle_lapse(testing)
	await _test_late_frame(testing, tree)
	await _test_redraw_requested(testing, tree)
	await _test_null_target(testing)


# The idle analogue: the real signal, which a headless run never fires, and no
# redraw target. The wait gives up at its bound, not before and not much after, and
# leaves no connection on the signal. If a frame did draw during the group, the
# premise is gone and the group skips rather than passing.
static func _test_idle_lapse(testing) -> void:
	testing.begin("await_fresh_frame — lapses at its bound on a run that never draws")
	var connections_before := RenderingServer.frame_post_draw.get_connections().size()
	var frames_before := Engine.get_frames_drawn()
	var started := Time.get_ticks_msec()
	var drew: bool = await EditorScreenshot.await_fresh_frame(null, _SHORT_BOUND_SECONDS)
	var elapsed := Time.get_ticks_msec() - started
	if Engine.get_frames_drawn() != frames_before:
		print("  SKIP: a frame drew during the wait, so this run is not the idle case")
		print("")
		return
	testing.ok(not drew, "returns false when no frame draws")
	testing.ok(elapsed >= _SHORT_BOUND_MSEC, "waits the whole bound (%d ms)" % elapsed)
	testing.ok(elapsed < _SHORT_BOUND_MSEC + _LAPSE_SLACK_MSEC,
		"gives up within a few frames of the bound (%d ms)" % elapsed)
	testing.eq(RenderingServer.frame_post_draw.get_connections().size(), connections_before,
		"leaves no connection on frame_post_draw")
	print("")


# A stand-in signal fired a few process frames into the wait: the helper returns
# true before its bound, and its one-shot connection is gone.
static func _test_late_frame(testing, tree: SceneTree) -> void:
	testing.begin("await_fresh_frame — returns true when a frame draws before the bound")
	var emitter := Object.new()
	emitter.add_user_signal(_STAND_IN_SIGNAL)
	var frame_drawn := Signal(emitter, _STAND_IN_SIGNAL)
	_emit_after_frames(tree, frame_drawn, _LATE_FRAME_DELAY)
	var started := Time.get_ticks_msec()
	var drew: bool = await EditorScreenshot.await_fresh_frame(null, _SHORT_BOUND_SECONDS, frame_drawn)
	var elapsed := Time.get_ticks_msec() - started
	testing.ok(drew, "returns true when the signal fires")
	testing.ok(elapsed < _SHORT_BOUND_MSEC, "returns before the bound (%d ms)" % elapsed)
	testing.ok(frame_drawn.get_connections().is_empty(), "leaves no connection on the signal")
	emitter.free()
	print("")


# A visible Control in the tree as the redraw target: its draw signal fires during
# the wait, which is the request that makes an idle editor draw. Its absence means
# the helper asked for nothing, whatever the wait returned. The draw that entering
# the tree queues is let through first, and a quiet frame checked, so the counted
# draw can only come from the helper.
static func _test_redraw_requested(testing, tree: SceneTree) -> void:
	testing.begin("await_fresh_frame — queues a redraw of its target")
	var target := Control.new()
	tree.root.add_child(target)
	testing.ok(target.is_visible_in_tree(), "the target is visible in the tree")
	var draws := [0]
	var on_draw := func() -> void:
		draws[0] += 1
	target.draw.connect(on_draw)
	await tree.process_frame
	await tree.process_frame
	draws[0] = 0
	await tree.process_frame
	await tree.process_frame
	testing.eq(int(draws[0]), 0, "the target draws nothing on its own")
	# The lapse result is the idle group's subject; this group checks only the request.
	var _drew: bool = await EditorScreenshot.await_fresh_frame(target, _SHORT_BOUND_SECONDS)
	testing.ok(int(draws[0]) > 0, "the target drew during the wait")
	target.draw.disconnect(on_draw)
	tree.root.remove_child(target)
	target.free()
	print("")


# An explicit null target with a stand-in signal that never fires: no error, the
# same lapse result as the idle group, and no connection left behind.
static func _test_null_target(testing) -> void:
	testing.begin("await_fresh_frame — an explicit null target skips the redraw")
	var emitter := Object.new()
	emitter.add_user_signal(_STAND_IN_SIGNAL)
	var frame_drawn := Signal(emitter, _STAND_IN_SIGNAL)
	var started := Time.get_ticks_msec()
	var drew: bool = await EditorScreenshot.await_fresh_frame(null, _SHORT_BOUND_SECONDS, frame_drawn)
	var elapsed := Time.get_ticks_msec() - started
	testing.ok(not drew, "returns false when the signal never fires")
	testing.ok(elapsed >= _SHORT_BOUND_MSEC, "waits the whole bound (%d ms)" % elapsed)
	testing.ok(frame_drawn.get_connections().is_empty(), "leaves no connection on the signal")
	emitter.free()
	print("")


# Fires `frame_drawn` after `delay` process frames. Called without
# await, so it runs alongside the wait it feeds.
static func _emit_after_frames(tree: SceneTree, frame_drawn: Signal, delay: int) -> void:
	for _frame in range(delay):
		await tree.process_frame
	frame_drawn.emit()
