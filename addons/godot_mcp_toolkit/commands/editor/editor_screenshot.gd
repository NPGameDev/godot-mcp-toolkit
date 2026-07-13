@tool
extends RefCounted
## editor.screenshot: capture the editor viewport to a PNG envelope — either the
## full main viewport, or focused on one node (select + edit + restore the prior
## selection). Caps the inline image to the requested image_detail level, handles
## headless (no viewport), and self-diagnoses a collapsed viewport: a minimized
## window returns EDITOR_VIEWPORT_UNAVAILABLE, and a wrong (non-2D/3D) main screen
## is auto-healed by switching to a 2D/3D screen and re-capturing. The
## image_response_mode / image_detail / save_path handling — inline vs disk vs both,
## the inline-resolution cap, and the res:// or user://screenshots/ save-path guard —
## is shaped by the shared ScreenshotResponse builder.
##
## Stateless — the handler takes (parameters) and returns the response Dictionary.
## Reaches the viewport / RenderingServer / EditorInterface / DisplayServer
## directly; the headless check, path normalization/edited-root lookup, and
## response shaping are reached via the Modules aliases. An extracted submodule of
## the editor-command group, reached via a `preload` alias.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Helpers = Modules.CommandHelpers

## Below this pixel size a viewport frame is treated as collapsed rather than
## usable: Godot clamps every viewport to a hard 2x2 floor, so a zero-size
## central editor area bottoms out well under this threshold.
const MIN_USABLE_DIMENSION := 16

## Re-capture attempts after switching the main screen: a freshly laid-out 2D/3D
## canvas needs a compositing frame or two before its viewport reports real
## dimensions. Worst case is a few frames at the connected editor's boosted frame
## rate — cheap next to returning a blank capture.
const MAX_HEAL_FRAMES := 4

## Recovery hint when the editor window is minimized: no viewport is composited,
## so no frame can be captured. This is never headless — headless short-circuits
## with HEADLESS_UNSUPPORTED before any capture, so a caller must not chase that
## non-cause.
const _HINT_MINIMIZED := "The editor window is minimized, so no viewport is composited — this is not headless. Retry with force_foreground_editor:true to raise the editor automatically, or restore the window yourself; for non-visual checks use script_check."

## Recovery hint when a main-screen switch laid out a 2D/3D canvas but it still
## composited nothing usable — an occlusion or timing edge past the bounded heal.
const _HINT_POST_HEAL := "Switched to a 2D/3D main screen but no viewport composited. Retry with force_foreground_editor:true, or use script_check for non-visual verification."


# -- Classification -----------------------------------------------------------


## Classify a capture by its source (pre-resize) viewport dimensions.
##
## Returns [code]{"ok": true}[/code] when the frame is usable, else
## [code]{"ok": false, "reason": "no_viewport_screen", "width": w, "height": h}[/code].
## Minimized is decided at the call site from [method DisplayServer.window_get_mode]
## (short-circuited before any capture/await), so this pure classifier only
## distinguishes a usable frame from a collapsed 2D/3D canvas. Editor-free and
## deterministic — the reason the capture decision lives here rather than inline.
## [param source_width] and [param source_height] are the viewport's pre-resize
## pixel dimensions.
static func classify_capture(source_width: int, source_height: int) -> Dictionary:
	if source_width < MIN_USABLE_DIMENSION or source_height < MIN_USABLE_DIMENSION:
		return {
			"ok": false,
			"reason": "no_viewport_screen",
			"width": source_width,
			"height": source_height,
		}
	return {"ok": true}


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
	# front — before any await frame_post_draw, which would never fire on a
	# suspended-render editor and hang the handler until the server times out.
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
# the prior selection. A wrong main screen is healed against the node's own
# viewport kind (3D for a Node3D, else 2D).
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

	var wants_3d := node is Node3D

	var selection := EditorInterface.get_selection()
	var prior_selection: Array = []
	if selection != null:
		for selected_node in selection.get_selected_nodes():
			prior_selection.append(selected_node)
		selection.clear()
		selection.add_node(node)
	EditorInterface.edit_node(node)
	await RenderingServer.frame_post_draw

	var image := await _grab_usable_image(wants_3d, remediation)
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


# Standard viewport screenshot. Defaults the heal target to the 2D viewport.
static func _capture_standard(parameters: Dictionary, remediation: Array[String]) -> Dictionary:
	# Freshness await before the first read: a throttled unfocused editor can
	# otherwise hand back a slightly stale frame. Safe now that minimized is
	# short-circuited up front — this only runs while the editor is compositing.
	await RenderingServer.frame_post_draw

	var image := await _grab_usable_image(false, remediation)
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


# -- Viewport heal + foreground ----------------------------------------------


# Fetch a usable viewport image, auto-healing a wrong main screen. Reads the
# requested viewport, and if it is collapsed (2x2 floor, not minimized — that is
# handled up front) switches to the 2D/3D main screen and re-checks across a
# bounded frame loop, breaking the instant a usable frame arrives. Appends
# "switched_main_screen" to [param remediation] when a switch was performed.
# Returns the usable Image, or null when nothing composited within the cap.
static func _grab_usable_image(wants_3d: bool, remediation: Array[String]) -> Image:
	var image := _read_viewport_image(wants_3d)
	if image != null and classify_capture(image.get_width(), image.get_height())["ok"]:
		return image

	# Collapsed and not minimized ⇒ the 2D/3D canvas is not the active main screen.
	# Lay it out and re-capture; there is no getter for the prior screen, so the
	# switch is one-way and disclosed via remediation rather than restored.
	EditorInterface.set_main_screen_editor("3D" if wants_3d else "2D")
	var switched := false
	for _attempt in range(MAX_HEAL_FRAMES):
		await RenderingServer.frame_post_draw
		image = _read_viewport_image(wants_3d)
		if image != null and classify_capture(image.get_width(), image.get_height())["ok"]:
			switched = true
			break

	if switched:
		remediation.append("switched_main_screen")
		return image
	return null


# Read the current texture of the requested editor viewport (3D falls back to 2D
# when no 3D viewport exists). Returns null when no viewport or texture is
# available.
static func _read_viewport_image(wants_3d: bool) -> Image:
	var viewport: SubViewport = null
	if wants_3d:
		viewport = EditorInterface.get_editor_viewport_3d(0)
	if viewport == null:
		viewport = EditorInterface.get_editor_viewport_2d()
	if viewport == null:
		return null
	return viewport.get_texture().get_image()


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
	await RenderingServer.frame_post_draw


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
