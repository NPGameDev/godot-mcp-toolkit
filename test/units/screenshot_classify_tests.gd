@tool
extends RefCounted
## Deterministic unit tests for the editor-screenshot collapse classifier — the
## pure classify_capture(width, height) decision extracted so the usable-vs-
## collapsed judgement is testable without an editor viewport. Covers a usable
## frame, a collapsed 2x2-floor frame, and the boundary at MIN_USABLE_DIMENSION.
## (Minimized is a call-site branch off DisplayServer.window_get_mode, not the
## classifier — it is covered by the sweep + smoke, not here.) Also guards, from the
## handler's source text, that every frame wait goes through its one bounded helper.

const EditorScreenshot := preload("res://addons/godot_mcp_toolkit/commands/editor/editor_screenshot.gd")

const _EDITOR_SCREENSHOT_PATH := "res://addons/godot_mcp_toolkit/commands/editor/editor_screenshot.gd"
const _WAIT_HELPER_HEADER := "static func await_fresh_frame("
const _FRAME_SIGNAL := "frame_post_draw"


static func run(testing) -> void:
	_test_usable(testing)
	_test_collapsed(testing)
	_test_boundary(testing)
	_test_single_wait_seam(testing)


# A real viewport-sized frame classifies usable, with no collapse metadata.
static func _test_usable(testing) -> void:
	testing.begin("classify_capture — usable frame")
	var result := EditorScreenshot.classify_capture(1280, 720)
	testing.ok(bool(result["ok"]), "large dims → ok")
	testing.ok(not result.has("reason"), "usable frame carries no reason")
	print("")


# A collapsed capture (Godot's hard 2x2 viewport floor) classifies not-ok, and
# reports the reason plus the source dimensions for the caller's disclosure.
static func _test_collapsed(testing) -> void:
	testing.begin("classify_capture — collapsed 2x2 floor")
	var result := EditorScreenshot.classify_capture(2, 2)
	testing.ok(not bool(result["ok"]), "2x2 → not ok")
	testing.eq(str(result["reason"]), "no_viewport_screen", "collapse reason reported")
	testing.eq(int(result["width"]), 2, "source width echoed")
	testing.eq(int(result["height"]), 2, "source height echoed")
	print("")


# The threshold is inclusive-exclusive at MIN_USABLE_DIMENSION: one below is
# collapsed, exactly at it is usable, and a mixed frame (one axis below) collapses.
static func _test_boundary(testing) -> void:
	testing.begin("classify_capture — MIN_USABLE_DIMENSION boundary")
	var threshold := EditorScreenshot.MIN_USABLE_DIMENSION
	testing.ok(bool(EditorScreenshot.classify_capture(threshold, threshold)["ok"]),
		"exactly at threshold → usable")
	testing.ok(not bool(EditorScreenshot.classify_capture(threshold - 1, threshold)["ok"]),
		"one below on width → collapsed")
	testing.ok(not bool(EditorScreenshot.classify_capture(threshold, threshold - 1)["ok"]),
		"one below on height → collapsed")
	print("")


# The handler waits for a frame only through await_fresh_frame(), which asks for a
# redraw and bounds the wait. A bare frame_post_draw await anywhere else hangs on an
# idle windowed editor, which CI cannot see: its editors run headless and the handler
# returns before any wait. So the file's text is checked instead: the signal's name
# may appear only between the helper's header and the next top-level line.
static func _test_single_wait_seam(testing) -> void:
	testing.begin("editor screenshot — every frame wait goes through await_fresh_frame()")
	var source := FileAccess.get_file_as_string(_EDITOR_SCREENSHOT_PATH)
	testing.ok(not source.is_empty(), "the handler's source is readable")
	var lines := source.split("\n")
	var helper_start := -1
	var helper_end := lines.size()
	for index in range(lines.size()):
		if helper_start < 0 and lines[index].begins_with(_WAIT_HELPER_HEADER):
			helper_start = index
		elif helper_start >= 0 and index > helper_start and _is_top_level(lines[index]):
			helper_end = index
			break
	testing.ok(helper_start >= 0, "the handler defines await_fresh_frame()")
	var outside: Array[int] = []
	for index in range(lines.size()):
		var in_helper := helper_start >= 0 and index >= helper_start and index < helper_end
		if not in_helper and lines[index].contains(_FRAME_SIGNAL):
			outside.append(index + 1)
	testing.ok(outside.is_empty(),
		"frame_post_draw appears only inside await_fresh_frame() (outside it on lines %s)" % str(outside))
	print("")


# True for a line that starts a new top-level member: not blank and not indented.
static func _is_top_level(line: String) -> bool:
	var trimmed := line.strip_edges()
	return not trimmed.is_empty() and not line.begins_with("\t") and not line.begins_with(" ")
