@tool
extends RefCounted
## Deterministic unit tests for the editor-screenshot collapse classifier — the
## pure classify_capture(width, height) decision extracted so the usable-vs-
## collapsed judgement is testable without an editor viewport. Covers a usable
## frame, a collapsed 2x2-floor frame, and the boundary at MIN_USABLE_DIMENSION.
## (Minimized is a call-site branch off DisplayServer.window_get_mode, not the
## classifier — it is covered by the sweep + smoke, not here.)

const EditorScreenshot := preload("res://addons/godot_mcp_toolkit/commands/editor/editor_screenshot.gd")


static func run(testing) -> void:
	_test_usable(testing)
	_test_collapsed(testing)
	_test_boundary(testing)


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
