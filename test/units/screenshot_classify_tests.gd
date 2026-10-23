@tool
extends RefCounted
## Deterministic unit tests for the editor screenshot's pure capture decisions,
## testable without an editor viewport: classify_capture (usable, collapsed at the
## MIN_USABLE_DIMENSION boundary, or from a hidden screen) and choose_screen (which
## viewport each request reads for each combination of shown screens). Minimized is
## a call-site branch off DisplayServer.window_get_mode, covered by the sweep and
## smoke, not here.

const EditorScreenshot := preload("res://addons/godot_mcp_toolkit/commands/editor/editor_screenshot.gd")


static func run(testing) -> void:
	_test_usable(testing)
	_test_collapsed(testing)
	_test_boundary(testing)
	_test_hidden_screen(testing)
	_test_standard_screen_choice(testing)
	_test_node_screen_choice(testing)


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


# A hidden screen's viewport keeps its full size and its last frame, so a
# usable-size frame from it is not usable; the reason names the hidden screen
# even when the frame is also collapsed.
static func _test_hidden_screen(testing) -> void:
	testing.begin("classify_capture — frame from a hidden main screen")
	var viewport_shown := false
	var result := EditorScreenshot.classify_capture(1280, 720, viewport_shown)
	testing.ok(not bool(result["ok"]), "usable-size frame from a hidden viewport → not ok")
	testing.eq(str(result["reason"]), "hidden_main_screen", "hidden reason reported")
	testing.eq(int(result["width"]), 1280, "source width echoed")
	testing.eq(int(result["height"]), 720, "source height echoed")
	var collapsed := EditorScreenshot.classify_capture(2, 2, viewport_shown)
	testing.eq(str(collapsed["reason"]), "hidden_main_screen",
		"hidden and collapsed → the hidden reason")
	print("")


# A standard capture reads the shown view, 2D first, and falls back to 2D (the
# screen it then switches to) when neither is shown.
static func _test_standard_screen_choice(testing) -> void:
	testing.begin("choose_screen — standard capture")
	var standard := EditorScreenshot.CaptureRequest.STANDARD
	var shown := true
	var hidden := false
	testing.eq(EditorScreenshot.choose_screen(standard, shown, hidden), "2D",
		"2D shown, 3D hidden → 2D")
	testing.eq(EditorScreenshot.choose_screen(standard, hidden, shown), "3D",
		"2D hidden, 3D shown → 3D")
	testing.eq(EditorScreenshot.choose_screen(standard, hidden, hidden), "2D",
		"neither shown → 2D")
	testing.eq(EditorScreenshot.choose_screen(standard, shown, shown), "2D",
		"both shown → 2D")
	print("")


# A node capture reads its node's view whatever is shown; the capture switches to
# it only when it is hidden.
static func _test_node_screen_choice(testing) -> void:
	testing.begin("choose_screen — node capture")
	var node_2d := EditorScreenshot.CaptureRequest.NODE_2D
	var node_3d := EditorScreenshot.CaptureRequest.NODE_3D
	var shown := true
	var hidden := false
	testing.eq(EditorScreenshot.choose_screen(node_2d, hidden, shown), "2D",
		"2D node, only 3D shown → 2D")
	testing.eq(EditorScreenshot.choose_screen(node_2d, hidden, hidden), "2D",
		"2D node, neither shown → 2D")
	testing.eq(EditorScreenshot.choose_screen(node_2d, shown, hidden), "2D",
		"2D node, 2D shown → 2D")
	testing.eq(EditorScreenshot.choose_screen(node_3d, shown, hidden), "3D",
		"3D node, only 2D shown → 3D")
	testing.eq(EditorScreenshot.choose_screen(node_3d, hidden, hidden), "3D",
		"3D node, neither shown → 3D")
	testing.eq(EditorScreenshot.choose_screen(node_3d, hidden, shown), "3D",
		"3D node, 3D shown → 3D")
	print("")
