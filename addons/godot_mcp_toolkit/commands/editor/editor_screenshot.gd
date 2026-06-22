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
## via the Modules aliases. Consumed by editor_commands.gd via a `preload` alias.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const FileGuard = Modules.FileGuard
const Helpers = Modules.CommandHelpers
const MIN_SCREENSHOT_SIZE := 64
const MAX_SCREENSHOT_SIZE := 4096


# -- Commands -----------------------------------------------------------------


static func cmd_screenshot(parameters: Dictionary) -> Dictionary:
	if Modules.VersionUtils.is_headless():
		return MCPToolkitError.fail("HEADLESS_UNSUPPORTED",
			"editor.screenshot requires a display server (no viewport in headless mode)")

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
		return MCPToolkitSuccess.ok({
			"image_base64": Marshalls.raw_to_base64(png_bytes),
			"mime_type": "image/png",
			"width": image.get_width(),
			"height": image.get_height(),
			"bytes": png_bytes.size(),
			"path": node_path,
		})

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
	if image.get_width() < 16 or image.get_height() < 16:
		response["warning"] = "Screenshot captured only %dx%d — editor may be minimized or running headless. Use script_check and editor_get_console for non-visual verification." % [image.get_width(), image.get_height()]
	if not persisted_path.is_empty():
		response["path"] = persisted_path
	return MCPToolkitSuccess.ok(response)
