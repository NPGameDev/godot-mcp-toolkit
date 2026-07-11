@tool
extends RefCounted
## Deterministic unit tests for the runtime-screenshot suspended-window decision —
## the pure _should_signal_minimized(frame_arrived, window_suspended) branch
## extracted so the "return the fresh capture vs signal a suspended window"
## judgement is testable without a live game window. The capability read
## (DisplayServer.window_can_draw), the frame-arrival read (frame_post_draw within
## the bound), and the OS foreground lever are exercised by the sweep + interactive
## re-validation, not here.

const RuntimeServer := preload("res://addons/godot_mcp_toolkit/runtime/mcp_runtime_server.gd")


static func run(testing) -> void:
	_test_fresh_frame_captures(testing)
	_test_suspended_signals(testing)
	_test_idle_compositing_captures(testing)


# A frame that arrived within the bound is always returned, even on a window that
# reads suspended — a still-compositing embedded game is the current state.
static func _test_fresh_frame_captures(testing) -> void:
	testing.begin("runtime_screenshot — fresh frame captures")
	testing.ok(not RuntimeServer._should_signal_minimized(true, false),
		"frame arrived, window can draw → capture")
	testing.ok(not RuntimeServer._should_signal_minimized(true, true),
		"frame arrived while suspended → still capture (compositing)")
	print("")


# The wait lapsed AND the window cannot draw — the genuine render-suspended case
# (a top-level game minimized, or fully occluded on macOS). This is the only path
# that signals RUNTIME_WINDOW_MINIMIZED; it must keep firing there.
static func _test_suspended_signals(testing) -> void:
	testing.begin("runtime_screenshot — suspended window signals")
	testing.ok(RuntimeServer._should_signal_minimized(false, true),
		"no frame + cannot draw → signal RUNTIME_WINDOW_MINIMIZED")
	print("")


# The wait lapsed on a window that can still draw: an idle redraw-on-demand game
# whose last-drawn frame is current. Fall through to capture, never signal.
static func _test_idle_compositing_captures(testing) -> void:
	testing.begin("runtime_screenshot — idle compositing captures")
	testing.ok(not RuntimeServer._should_signal_minimized(false, false),
		"no frame + can draw → capture last-drawn frame")
	print("")
