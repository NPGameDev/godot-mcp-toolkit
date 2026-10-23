@tool
extends RefCounted
## editor.screenshot: capture the editor viewport to a PNG envelope — either the
## shown 2D or 3D view, or focused on one node (select + edit + restore the prior
## selection). Caps the inline image to the requested image_detail level, handles
## headless (no viewport), and never returns a frame from a view the editor is not
## showing: a minimized window returns EDITOR_VIEWPORT_UNAVAILABLE, and a hidden or
## collapsed 2D/3D view makes the capture switch the main screen and wait, within a
## bound, for a fresh frame.
## A hidden view is detected by its container's visibility, not its size: Godot
## stops rendering a hidden SubViewportContainer's viewport but keeps its size and
## last texture, so a size check alone would pass an old frame as usable. The
## image_response_mode / image_detail / save_path handling — inline vs disk vs both,
## the inline-resolution cap, and the res:// or user://screenshots/ save-path guard —
## is shaped by the shared ScreenshotResponse builder.
##
## Stateless — the handler takes (parameters) and returns the response Dictionary.
## Reaches the viewport / RenderingServer / EditorInterface / DisplayServer
## directly; the headless check, path normalization/edited-root lookup, and
## response shaping are reached via the Modules aliases. An extracted submodule of
## the editor-command group, reached via a `preload` alias.

## What a capture is aimed at: whichever editor view is shown, or one node's view.
enum CaptureRequest { STANDARD, NODE_2D, NODE_3D }

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Helpers = Modules.CommandHelpers

## Main-screen names as [method EditorInterface.set_main_screen_editor] takes them.
const SCREEN_2D := "2D"
const SCREEN_3D := "3D"

## Below this pixel size a viewport frame is treated as collapsed rather than
## usable: Godot clamps every viewport to a hard 2x2 floor, so a zero-size
## central editor area bottoms out well under this threshold.
const MIN_USABLE_DIMENSION := 16

## Re-capture attempts after switching the main screen: a freshly shown 2D/3D
## canvas needs a compositing frame or two before its viewport reports real
## dimensions and holds a newly drawn frame. Each attempt is one bounded
## fresh-frame wait, so the worst case is [constant MAX_HEAL_FRAMES] bounds — cheap
## next to returning a blank capture.
const MAX_HEAL_FRAMES := 4

## Bound on each fresh-frame wait, matching the runtime screenshot's bound. A
## redraw-requested wait normally ends within an editor iteration or two; the
## bound only stops a frame that never draws from holding the call until the
## server's call timeout.
const FRESH_FRAME_WAIT_SECONDS := 1.0

## Recovery hint when the editor window is minimized: no viewport is composited,
## so no frame can be captured. This is never headless — headless short-circuits
## with HEADLESS_UNSUPPORTED before any capture, so a caller must not chase that
## non-cause.
const _HINT_MINIMIZED := "The editor window is minimized, so no viewport is composited — this is not headless. Retry with force_foreground_editor:true to raise the editor automatically, or restore the window yourself; for non-visual checks use script_check."

## Recovery hint when a main-screen switch laid out a 2D/3D canvas but it still
## composited nothing usable — an occlusion or timing edge past the bounded wait.
const _HINT_POST_HEAL := "Switched to a 2D/3D main screen but no viewport composited. Retry with force_foreground_editor:true, or use script_check for non-visual verification."


# -- Classification -----------------------------------------------------------


## Classify a capture by its source viewport: shown or hidden, and its pre-resize
## dimensions.
##
## Returns [code]{"ok": true}[/code] when the frame is usable, else
## [code]{"ok": false, "reason": r, "width": w, "height": h}[/code], where
## [code]r[/code] is [code]"hidden_main_screen"[/code] for a viewport whose screen is
## not shown (it keeps its full size and its last frame, so only this flag can tell)
## or [code]"no_viewport_screen"[/code] for a collapsed one. Minimized is decided at
## the call site from [method DisplayServer.window_get_mode] (short-circuited before
## any capture/await), so this pure classifier only tells a usable frame from one
## the capture must switch the main screen for. Editor-free and deterministic — the
## reason the capture decision lives here rather than inline.
## [param source_width] and [param source_height] are the viewport's pre-resize
## pixel dimensions; [param viewport_shown] is whether its screen is shown.
static func classify_capture(
		source_width: int,
		source_height: int,
		viewport_shown: bool = true) -> Dictionary:
	if not viewport_shown:
		return {
			"ok": false,
			"reason": "hidden_main_screen",
			"width": source_width,
			"height": source_height,
		}
	if source_width < MIN_USABLE_DIMENSION or source_height < MIN_USABLE_DIMENSION:
		return {
			"ok": false,
			"reason": "no_viewport_screen",
			"width": source_width,
			"height": source_height,
		}
	return {"ok": true}


## Choose the main screen whose viewport a capture reads.
##
## A node capture reads its node's view: [constant SCREEN_3D] for
## [constant CaptureRequest.NODE_3D], else [constant SCREEN_2D]. A standard capture
## reads the view the user is looking at: 2D when it is shown, else 3D when that is
## shown, else 2D. The capture switches to the answered screen only when its viewport
## is hidden or collapsed, so a standard capture never switches away from a shown 2D
## or 3D screen. A node capture runs after [method EditorInterface.edit_node], which
## already moves a shown 2D or 3D screen to a [CanvasItem]'s 2D or a [Node3D]'s 3D
## screen, so it switches only from another screen, or from 3D to 2D for a node that
## is neither.
## [param request] is a [enum CaptureRequest]; [param shown_2d] and
## [param shown_3d] say whether each editor viewport's screen is shown.
## Returns [constant SCREEN_2D] or [constant SCREEN_3D].
static func choose_screen(request: CaptureRequest, shown_2d: bool, shown_3d: bool) -> String:
	if request == CaptureRequest.NODE_3D:
		return SCREEN_3D
	if request == CaptureRequest.NODE_2D:
		return SCREEN_2D
	if shown_3d and not shown_2d:
		return SCREEN_3D
	return SCREEN_2D


# -- Fresh frame --------------------------------------------------------------


## Wait for the editor to draw a fresh frame, asking it to draw one, for at most
## a bound.
##
## The one place this handler waits for a frame, so a change of mechanism edits
## only this function. The editor runs in low-processor mode and draws only when
## something on screen changed, so the wait first queues a redraw of
## [param redraw_target], which makes the next iteration draw; a null target
## skips the request. It then polls each process frame, which keeps ticking on an
## idle editor, until [param frame_drawn] fires or [param bound_seconds] pass, and
## leaves no connection on [param frame_drawn] either way. Call sites pass no
## arguments; the parameters exist so a headless unit can stand in its own signal,
## bound and target.
## Returns true when a frame drew within the bound, false when the bound lapsed.
## The caller reads the viewport in both cases: on a visible window the
## last-drawn frame is what is on screen.
static func await_fresh_frame(
		redraw_target: CanvasItem = EditorInterface.get_base_control(),
		bound_seconds: float = FRESH_FRAME_WAIT_SECONDS,
		frame_drawn: Signal = RenderingServer.frame_post_draw) -> bool:
	var drew := [false]
	var on_frame_drawn := func() -> void:
		drew[0] = true
	frame_drawn.connect(on_frame_drawn, CONNECT_ONE_SHOT)
	if redraw_target != null:
		redraw_target.queue_redraw()
	var tree: SceneTree = Engine.get_main_loop()
	var deadline := Time.get_ticks_msec() + int(bound_seconds * 1000.0)
	while not drew[0] and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	if frame_drawn.is_connected(on_frame_drawn):
		frame_drawn.disconnect(on_frame_drawn)
	return drew[0]


# -- Commands -----------------------------------------------------------------


static func cmd_screenshot(parameters: Dictionary) -> Dictionary:
	if Modules.VersionUtils.is_headless():
		# Redirect must be headless-accurate: script_check is the reliable alternative;
		# editor_get_console gives RUNTIME output only (its editor parse-error capture is
		# itself headless-degraded), so it is not a substitute for visual verification.
		return MCPToolkitError.fail("HEADLESS_UNSUPPORTED",
			"editor.screenshot requires a display server (no viewport in headless mode)",
			"Use script_check to verify a script's parse status; editor_get_console captures runtime output only (headless editors don't revalidate scripts, so editor parse errors aren't captured there).")

	# Reject a bad image_detail before any capture so a typo can't slip through as
	# full-res (the pure dims calculator treats an unknown value as native — the guard
	# lives here, once, so both capture paths reject uniformly).
	if Modules.ScreenshotResponse.detail_of(parameters).is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS",
			"image_detail must be one of [full, mid, low] (got %s)"
			% str(parameters.get("image_detail", "")))

	var force_foreground := bool(parameters.get("force_foreground_editor", false))
	var remediation: Array[String] = []

	# Minimized suspends compositing, so no frame can be captured. Detect it up
	# front, before any fresh-frame wait: a wait on a suspended window always runs
	# to its bound, and the frame it would fall back on is not what is on screen.
	if _window_is_minimized():
		if not force_foreground:
			return MCPToolkitError.fail("EDITOR_VIEWPORT_UNAVAILABLE",
				"editor viewport unavailable: the editor window is minimized", _HINT_MINIMIZED)
		await _foreground_editor()
		remediation.append("foregrounded_editor")

	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)

	if not node_path.is_empty():
		return await _capture_node(parameters, node_path, remediation)
	return await _capture_standard(parameters, remediation)


# -- Capture paths ------------------------------------------------------------


# Node-focused screenshot: select + edit + capture a specific node, then restore
# the prior selection. Reads the node's own viewport (3D for a Node3D, else 2D),
# switching the main screen to it when it is hidden: edit_node leaves the Script
# screen up under the editor's default "stay in script editor" setting.
static func _capture_node(parameters: Dictionary, node_path: String, remediation: Array[String]) -> Dictionary:
	var root := Helpers.get_edited_root()
	if root == null:
		return MCPToolkitError.fail("NO_SCENE", "no edited scene")
	var node: Variant = null
	if node_path == ".":
		node = root
	else:
		node = root.get_node_or_null(node_path)
	if node == null:
		return MCPToolkitError.fail("NOT_FOUND", "no node at %s" % node_path, MCPToolkitError.HINT_NODE_PATH)

	var request := CaptureRequest.NODE_2D
	if node is Node3D:
		request = CaptureRequest.NODE_3D

	var selection := EditorInterface.get_selection()
	var prior_selection: Array = []
	if selection != null:
		for selected_node in selection.get_selected_nodes():
			prior_selection.append(selected_node)
		selection.clear()
		selection.add_node(node)
	EditorInterface.edit_node(node)
	await await_fresh_frame()

	var image := await _grab_usable_image(request, remediation)
	if image == null:
		_restore_selection(selection, prior_selection)
		return MCPToolkitError.fail("EDITOR_VIEWPORT_UNAVAILABLE",
			"editor viewport unavailable: no 2D/3D viewport composited a usable frame", _HINT_POST_HEAL)

	_restore_selection(selection, prior_selection)

	var png_bytes := image.save_png_to_buffer()
	if png_bytes.is_empty():
		return MCPToolkitError.fail("EMPTY_CONTENT",
			"node '%s' produced no visible image. Node may lack visual content (no texture, no mesh). Use editor_screenshot without node_path for a full viewport capture instead." % node_path)
	var inline := _downscale_inline_png(image, parameters)
	var response := Modules.ScreenshotResponse.build(
		parameters, png_bytes, image.get_width(), image.get_height(),
		["res://", "user://screenshots/"],
		inline["png_bytes"], int(inline["width"]), int(inline["height"]))
	if response.get("success") == false:
		return response
	# Inline mode echoes the requested node path; a disk/both response already carries
	# the FILE path in "path" (which supersedes the echo — the caller knows its input).
	if not response.has("path"):
		response["path"] = node_path
	if not remediation.is_empty():
		response["remediation"] = remediation
	return MCPToolkitSuccess.ok(response)


# Standard viewport screenshot of whichever 2D or 3D view is shown (see choose_screen).
static func _capture_standard(parameters: Dictionary, remediation: Array[String]) -> Dictionary:
	# Fresh frame before the first read: a throttled unfocused editor can otherwise
	# hand back a slightly stale one. An idle editor draws only on change, so the
	# wait asks for a redraw and is bounded; on a lapse the last-drawn frame is
	# current, because minimized is short-circuited up front.
	await await_fresh_frame()

	var image := await _grab_usable_image(CaptureRequest.STANDARD, remediation)
	if image == null:
		return MCPToolkitError.fail("EDITOR_VIEWPORT_UNAVAILABLE",
			"editor viewport unavailable: no 2D/3D viewport composited a usable frame", _HINT_POST_HEAL)

	var png_bytes := image.save_png_to_buffer()
	if png_bytes.is_empty():
		return MCPToolkitError.fail("INTERNAL", "save_png_to_buffer returned empty")

	var inline := _downscale_inline_png(image, parameters)
	var response := Modules.ScreenshotResponse.build(
		parameters, png_bytes, image.get_width(), image.get_height(),
		["res://", "user://screenshots/"],
		inline["png_bytes"], int(inline["width"]), int(inline["height"]))
	if response.get("success") == false:
		return response
	if not remediation.is_empty():
		response["remediation"] = remediation
	return MCPToolkitSuccess.ok(response)


# Encode the downscaled inline PNG for the requested image_detail cap, but only when
# an inline image is actually returned (inline/both mode) and the level shrinks the
# frame — disk-only returns the full-res file, so it needs no inline buffer. Returns
# {png_bytes, width, height}; png_bytes is empty (and dims -1) when no downscale
# applies, which ScreenshotResponse.build reads as "use the full-res buffer inline".
static func _downscale_inline_png(image: Image, parameters: Dictionary) -> Dictionary:
	var empty := {"png_bytes": PackedByteArray(), "width": -1, "height": -1}
	if Modules.ScreenshotResponse.mode_of(parameters) == "disk":
		return empty
	var detail := Modules.ScreenshotResponse.detail_of(parameters)
	var target := Modules.ScreenshotResponse.image_detail_dims(
		image.get_width(), image.get_height(), detail)
	if target.x == image.get_width() and target.y == image.get_height():
		return empty
	# duplicate() is typed Ref<Resource>; the explicit Image local coerces (loud on a
	# mismatch, unlike `as`). Resize the copy so the full-res buffer stays intact for disk.
	var inline_image: Image = image.duplicate()
	inline_image.resize(target.x, target.y, Image.INTERPOLATE_LANCZOS)
	return {
		"png_bytes": inline_image.save_png_to_buffer(),
		"width": inline_image.get_width(),
		"height": inline_image.get_height(),
	}


# -- Main-screen switch + foreground -----------------------------------------


# Fetch a usable frame for `request`. Reads the viewport choose_screen picks;
# when that viewport is hidden or collapsed (not minimized — that is handled up
# front), switches the main screen to it and re-reads across a bounded frame loop,
# stopping at the first usable frame. Each re-read follows a bounded fresh-frame
# wait, so the frame returned is normally one drawn after the screen was shown; a
# wait that lapses still re-reads, and may return the frame drawn before the screen
# was hidden. Appends "switched_main_screen" to `remediation` when a switch
# produced the frame. Returns the usable Image, or null when nothing composited
# within the cap.
static func _grab_usable_image(request: CaptureRequest, remediation: Array[String]) -> Image:
	var shown_2d := _viewport_shown(EditorInterface.get_editor_viewport_2d())
	var shown_3d := _viewport_shown(EditorInterface.get_editor_viewport_3d(0))
	var screen := choose_screen(request, shown_2d, shown_3d)
	var image := _read_usable_frame(screen)
	if image != null:
		return image

	# There is no getter for the current main screen, so the switch is one-way and
	# disclosed via remediation rather than restored.
	EditorInterface.set_main_screen_editor(screen)
	for _attempt in range(MAX_HEAL_FRAMES):
		await await_fresh_frame()
		image = _read_usable_frame(screen)
		if image != null:
			remediation.append("switched_main_screen")
			return image
	return null


# Read `screen`'s editor viewport (3D falls back to 2D when no 3D viewport
# exists). Returns its current frame when classify_capture finds it usable, else
# null, including when no viewport or texture is available.
static func _read_usable_frame(screen: String) -> Image:
	var viewport: SubViewport = null
	if screen == SCREEN_3D:
		viewport = EditorInterface.get_editor_viewport_3d(0)
	if viewport == null:
		viewport = EditorInterface.get_editor_viewport_2d()
	if viewport == null:
		return null
	var image := viewport.get_texture().get_image()
	if image == null:
		return null
	var verdict := classify_capture(image.get_width(), image.get_height(), _viewport_shown(viewport))
	if not bool(verdict["ok"]):
		return null
	return image


# Whether `viewport`'s screen is shown. Each editor viewport sits in a
# SubViewportContainer that the editor hides with its main screen, and a hidden
# container stops its viewport rendering without resizing it, so the container's
# visibility is the one signal that its last frame is current. A viewport outside
# a CanvasItem parent counts as shown, leaving the size check to judge it; a
# missing viewport counts as hidden.
static func _viewport_shown(viewport: SubViewport) -> bool:
	if viewport == null:
		return false
	var parent := viewport.get_parent()
	if not (parent is CanvasItem):
		return true
	var container: CanvasItem = parent
	return container.is_visible_in_tree()


# Un-minimize + raise + focus the editor window, then await a composite frame so
# the subsequent capture sees a laid-out viewport. window_set_mode(WINDOWED) is
# applied only when minimized so a maximized editor is not un-maximized; the
# 4.6+-deprecated Window.move_to_foreground() is deliberately avoided in favour of
# DisplayServer.window_move_to_foreground() + Window.grab_focus().
static func _foreground_editor() -> void:
	if _window_is_minimized():
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED, 0)
	DisplayServer.window_move_to_foreground(0)
	var base := EditorInterface.get_base_control()
	if base != null:
		var win := base.get_window()
		if win != null:
			win.grab_focus()
	await await_fresh_frame()


# -- Helpers ------------------------------------------------------------------


static func _window_is_minimized() -> bool:
	return DisplayServer.window_get_mode(0) == DisplayServer.WINDOW_MODE_MINIMIZED


static func _restore_selection(selection: EditorSelection, prior_selection: Array) -> void:
	if selection == null:
		return
	selection.clear()
	for selected_node in prior_selection:
		if is_instance_valid(selected_node):
			selection.add_node(selected_node)
