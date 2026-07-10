@tool
extends RefCounted
## editor.screenshot: capture the editor viewport to a PNG envelope — either the
## full main viewport, or focused on one node (select + edit + restore the prior
## selection). Validates the requested size, handles headless (no viewport),
## empty-content, and minimized-window cases, and optionally persists to a
## save_path under res:// or user://screenshots/.
##
## Stateless — the handler takes (parameters) and returns the response Dictionary.
## Reaches the viewport / RenderingServer / EditorInterface directly; the headless
## check, path normalization/edited-root lookup, and save-path guard are reached
## via the Modules aliases. An extracted submodule of the editor-command group,
## reached via a `preload` alias.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const FileGuard = Modules.FileGuard
const Helpers = Modules.CommandHelpers
const MIN_SCREENSHOT_SIZE := 64
const MAX_SCREENSHOT_SIZE := 4096
const MIN_USABLE_DIMENSION := 16
# A collapsed editor viewport reports Godot's hard 2x2 viewport floor — the window
# is minimized / not compositing a frame, or no 2D/3D viewport is the active main
# screen. The capture still succeeds but is unusable, so warn with a remediation
# path. This branch is never headless (headless short-circuits with
# HEADLESS_UNSUPPORTED before any capture), so the message must not name headless
# as a possibility — doing so only sends the caller chasing a non-cause.
const COLLAPSED_VIEWPORT_WARNING := "Screenshot captured from a collapsed editor viewport (%dx%d) — the editor window is likely minimized or not compositing a frame, or no 2D/3D viewport is the active main screen. Restore and foreground the editor on a 2D or 3D main screen, then retry; otherwise use script_check for non-visual verification. This is not headless — a headless editor returns HEADLESS_UNSUPPORTED instead of an image."


# -- Commands -----------------------------------------------------------------


static func cmd_screenshot(parameters: Dictionary) -> Dictionary:
	if Modules.VersionUtils.is_headless():
		# Redirect must be headless-accurate: script_check is the reliable alternative;
		# editor_get_console gives RUNTIME output only (its editor parse-error capture is
		# itself headless-degraded), so it is not a substitute for visual verification.
		return MCPToolkitError.fail("HEADLESS_UNSUPPORTED",
			"editor.screenshot requires a display server (no viewport in headless mode)",
			"Use script_check to verify a script's parse status; editor_get_console captures runtime output only (headless editors don't revalidate scripts, so editor parse errors aren't captured there).")

	var node_path := str(parameters.get("node_path", ""))
	node_path = Helpers.normalize_editor_path(node_path)

	# Node-focused screenshot: select + capture a specific node, then restore.
	if not node_path.is_empty():
		var size_dict: Dictionary = parameters.get("size", {}) if typeof(parameters.get("size", {})) == TYPE_DICTIONARY else {}
		var width := int(size_dict.get("width", 1280))
		var height := int(size_dict.get("height", 720))
		if width < MIN_SCREENSHOT_SIZE or width > MAX_SCREENSHOT_SIZE \
				or height < MIN_SCREENSHOT_SIZE or height > MAX_SCREENSHOT_SIZE:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"size.width and size.height must be in [64, 4096] (got %dx%d)" % [width, height])
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

		var selection := EditorInterface.get_selection()
		var prior_selection: Array = []
		if selection != null:
			for selected_node in selection.get_selected_nodes():
				prior_selection.append(selected_node)
			selection.clear()
			selection.add_node(node)
		EditorInterface.edit_node(node)
		await RenderingServer.frame_post_draw

		var viewport: SubViewport = null
		if node is Node3D:
			viewport = EditorInterface.get_editor_viewport_3d(0)
		if viewport == null:
			viewport = EditorInterface.get_editor_viewport_2d()
		if viewport == null:
			return MCPToolkitError.fail("INTERNAL", "no editor viewport available")
		var image := viewport.get_texture().get_image()
		if image == null:
			return MCPToolkitError.fail("INTERNAL",
				"viewport texture unavailable (nothing rendered yet?)")
		# Snapshot the pre-resize dimensions: a collapsed viewport reports the 2x2
		# floor, and the resize below would upscale that blank frame to the
		# requested size with no signal left to the caller. Keep the source dims so
		# the response can warn instead of silently returning an empty capture.
		var source_width := image.get_width()
		var source_height := image.get_height()
		if image.get_width() != width or image.get_height() != height:
			image.resize(width, height, Image.INTERPOLATE_LANCZOS)

		if selection != null:
			selection.clear()
			for selected_node in prior_selection:
				if is_instance_valid(selected_node):
					selection.add_node(selected_node)
		var png_bytes := image.save_png_to_buffer()
		if png_bytes.is_empty():
			return MCPToolkitError.fail("EMPTY_CONTENT",
				"node '%s' produced no visible image. Node may lack visual content (no texture, no mesh). Use editor_screenshot without node_path for a full viewport capture instead." % node_path)
		var response := {
			"image_base64": Marshalls.raw_to_base64(png_bytes),
			"mime_type": "image/png",
			"width": image.get_width(),
			"height": image.get_height(),
			"bytes": png_bytes.size(),
			"path": node_path,
		}
		if source_width < MIN_USABLE_DIMENSION or source_height < MIN_USABLE_DIMENSION:
			response["warning"] = COLLAPSED_VIEWPORT_WARNING % [source_width, source_height]
		return MCPToolkitSuccess.ok(response)

	# Standard viewport screenshot.
	var save_path := str(parameters.get("save_path", ""))
	var viewport: SubViewport = EditorInterface.get_editor_viewport_2d()
	if viewport == null:
		viewport = EditorInterface.get_editor_viewport_3d(0)
	if viewport == null:
		return MCPToolkitError.fail("INTERNAL", "no editor viewport available")
	var image := viewport.get_texture().get_image()
	if image == null:
		return MCPToolkitError.fail("INTERNAL",
			"viewport texture unavailable (nothing rendered yet?)")

	var png_bytes := image.save_png_to_buffer()
	if png_bytes.is_empty():
		return MCPToolkitError.fail("INTERNAL", "save_png_to_buffer returned empty")

	var persisted_path := ""
	if not save_path.is_empty():
		var guard := FileGuard.resolve_safe(
			save_path, ["res://", "user://screenshots/"])
		if guard["error"] != null:
			return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
		if not save_path.ends_with(".png"):
			return MCPToolkitError.fail("INVALID_PARAMS",
				"save_path must end with .png: %s" % save_path)
		var directory_path := save_path.get_base_dir()
		if not directory_path.is_empty():
			var mkdir_error := DirAccess.make_dir_recursive_absolute(directory_path)
			if mkdir_error != OK and mkdir_error != ERR_ALREADY_EXISTS:
				return MCPToolkitError.fail("INTERNAL",
					"could not create %s (err %d)" % [directory_path, mkdir_error])
		var save_error := image.save_png(save_path)
		if save_error != OK:
			return MCPToolkitError.fail("INTERNAL",
				"save_png failed (err %d) for %s" % [save_error, save_path])
		persisted_path = save_path

	var response := {
		"image_base64": Marshalls.raw_to_base64(png_bytes),
		"mime_type": "image/png",
		"width": image.get_width(),
		"height": image.get_height(),
		"bytes": png_bytes.size(),
	}
	if image.get_width() < MIN_USABLE_DIMENSION or image.get_height() < MIN_USABLE_DIMENSION:
		response["warning"] = COLLAPSED_VIEWPORT_WARNING % [image.get_width(), image.get_height()]
	if not persisted_path.is_empty():
		response["path"] = persisted_path
	return MCPToolkitSuccess.ok(response)
