@tool
extends RefCounted
## texture.generate — procedural 2D placeholder textures (PNG → Texture2D).
##
## Closes half of the can't-produce-assets blindspot: the LLM can't draw, so
## prototypes are hand-built coloured rects. This synthesises distinguishable
## placeholder sprites — shapes/patterns with a 3-layer colour model
## (fill / outline / background, alpha-absent = layer omitted) plus an optional
## text label overlay — and writes a PNG that imports as a Texture2D.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Helpers = Modules.CommandHelpers

const ALLOWED_EXTS := ["png"]
const MAX_DIM := 1024
const DEFAULT_DIM := 64
const SHAPES := ["solid", "circle", "triangle", "diamond", "arrow", "checkerboard", "grid"]
const DIRECTIONS := ["up", "down", "left", "right"]


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("texture.generate", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_generate(parameters)
	, MCPToolkitCommandOptions.new()
		.mark_scene_independent()
		.guard_project_path("file_path")
		.with_timeout_ms(40000)
		.with_success_hint(
			"Assign the texture: node_set_property on Sprite2D.texture / "
			+ "TextureRect.texture / Button.icon, or feed spriteframes_create."))


static func _cmd_generate(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("file_path", ""))
	if file_path == "":
		return MCPToolkitError.fail("INVALID_PARAMS",
			"file_path is required (res:// destination ending in .png)", MCPToolkitError.HINT_FILE_PATH)

	var shape := str(parameters.get("shape", "solid")).to_lower()
	if shape not in SHAPES:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"shape must be one of: %s (got '%s')" % [", ".join(SHAPES), shape])

	var width: int = clampi(int(parameters.get("width", DEFAULT_DIM)), 1, MAX_DIM)
	var height: int = clampi(int(parameters.get("height", DEFAULT_DIM)), 1, MAX_DIM)

	var fill_color := _parse_color(parameters.get("fill_color", null), Color(0.8, 0.8, 0.8, 1.0))
	var outline_color := _parse_color(parameters.get("outline_color", null), Color(0, 0, 0, 0))
	var background_color := _parse_color(parameters.get("background_color", null), Color(0, 0, 0, 0))
	var outline_width: int = maxi(0, int(parameters.get("outline_width", 1)))

	# Blank-result guard: at least one layer must be visible.
	if fill_color.a <= 0.0 and outline_color.a <= 0.0 and background_color.a <= 0.0:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"result would be fully transparent — set fill_color, outline_color, or background_color (alpha > 0)")

	var direction := str(parameters.get("direction", "right")).to_lower()
	if direction not in DIRECTIONS:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"direction must be one of: %s (got '%s')" % [", ".join(DIRECTIONS), direction])
	var cell_size: int = maxi(1, int(parameters.get("cell_size", maxi(8, mini(width, height) / 8))))

	# --- Build the image ---
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(background_color)
	_draw_shape(image, shape, fill_color, outline_color, outline_width, background_color, cell_size, direction)

	# --- Optional label overlay ---
	var label := str(parameters.get("label", ""))
	var warnings: Array[String] = []
	if label != "":
		if Modules.VersionUtils.is_headless():
			warnings.append("label overlay skipped: text rasterization needs a display (unavailable in --headless)")
		else:
			var label_color := _parse_color(parameters.get("label_color", null), Color(0, 0, 0, 1))
			var label_img = await _render_label(label, width, height, label_color)
			if label_img != null:
				image.blend_rect(label_img, Rect2i(0, 0, width, height), Vector2i(0, 0))
			else:
				warnings.append("label overlay could not be rendered")

	# --- Write + settle (shared bracket) ---
	var write_fn := func(write_path: String) -> Dictionary:
		var err := image.save_png(write_path)
		if err != OK:
			return MCPToolkitError.fail("WRITE_FAILED",
				"Image.save_png failed for %s (err %d)" % [write_path, err])
		return {}

	var if_exists := str(parameters.get("if_exists", "return"))
	# Default 0 = no import-settle poll: a generated PNG is a Texture2D by
	# construction, so the class is reported directly (no FS round-trip). Pass an
	# explicit wait_for_scan_ms > 0 to force a settle.
	var wait_for_scan_ms := int(parameters.get("wait_for_scan_ms", 0))
	var result := await Helpers.write_asset_with_settle(
		file_path, PackedStringArray(ALLOWED_EXTS), if_exists, wait_for_scan_ms, "texture.generate", write_fn, "Texture2D")
	if not result.get("success", false):
		return result

	if result.get("status") != "returned":
		result["shape"] = shape
		result["width"] = width
		result["height"] = height
		if not warnings.is_empty():
			var existing: Array = result.get("warnings", [])
			existing.append_array(warnings)
			result["warnings"] = existing
	return result


# -- Drawing ------------------------------------------------------------------


static func _draw_shape(
	image: Image, shape: String, fill: Color, outline: Color,
	outline_width: int, background: Color, cell_size: int, direction: String,
) -> void:
	var w := image.get_width()
	var h := image.get_height()
	match shape:
		"solid":
			# Fast path: rectangle fills, no per-pixel loop (large images stay quick).
			var ow := outline_width if outline.a > 0.0 else 0
			if ow > 0 and w > 2 * ow and h > 2 * ow:
				image.fill(outline)
				image.fill_rect(Rect2i(ow, ow, w - 2 * ow, h - 2 * ow), fill if fill.a > 0.0 else background)
			else:
				image.fill(fill if fill.a > 0.0 else (outline if outline.a > 0.0 else background))
			return
		"checkerboard":
			# Per-cell fills (fill_color squares over the already-filled background).
			var cells_x := int(ceil(float(w) / cell_size))
			var cells_y := int(ceil(float(h) / cell_size))
			for cy in range(cells_y):
				for cx in range(cells_x):
					if (cx + cy) % 2 == 0:
						var rx := cx * cell_size
						var ry := cy * cell_size
						image.fill_rect(Rect2i(rx, ry, mini(cell_size, w - rx), mini(cell_size, h - ry)), fill)
			return
		"grid":
			# Lines (outline_color, falling back to fill) over the background.
			var line_color := outline if outline.a > 0.0 else fill
			var lw := maxi(1, outline_width)
			var gx := 0
			while gx < w:
				image.fill_rect(Rect2i(gx, 0, mini(lw, w - gx), h), line_color)
				gx += cell_size
			var gy := 0
			while gy < h:
				image.fill_rect(Rect2i(0, gy, w, mini(lw, h - gy)), line_color)
				gy += cell_size
			return
		_:
			# Convex shapes via inside-tests at two margins (fill inset by the
			# outline width); pixels in the band become the outline.
			var ow := outline_width if outline.a > 0.0 else 0
			for y in range(h):
				for x in range(w):
					var inside_outer := _in_shape(shape, x, y, w, h, direction, 0)
					if not inside_outer:
						continue
					var inside_inner := _in_shape(shape, x, y, w, h, direction, ow)
					if inside_inner:
						# Interior: fill, or leave background when fill is absent (hollow).
						if fill.a > 0.0:
							image.set_pixel(x, y, fill)
					elif outline.a > 0.0:
						# Outline band (inside outer shape, outside the inset inner shape).
						image.set_pixel(x, y, outline)


## True when pixel (x,y) is inside the shape, shrunk inward by `margin` pixels.
static func _in_shape(shape: String, x: int, y: int, w: int, h: int, direction: String, margin: float) -> bool:
	var px := x + 0.5
	var py := y + 0.5
	match shape:
		"solid":
			return px >= margin and px <= w - margin and py >= margin and py <= h - margin
		"circle":
			var cx := w / 2.0
			var cy := h / 2.0
			var r := minf(w, h) / 2.0 - margin
			return r > 0.0 and Vector2(px - cx, py - cy).length() <= r
		"diamond":
			var hw := w / 2.0 - margin
			var hh := h / 2.0 - margin
			if hw <= 0.0 or hh <= 0.0:
				return false
			return abs(px - w / 2.0) / hw + abs(py - h / 2.0) / hh <= 1.0
		"triangle":
			return _in_directional_triangle(px, py, w, h, "up", margin)
		"arrow":
			return _in_directional_triangle(px, py, w, h, direction, margin)
	return false


## Triangle inscribed in the box with its apex toward `direction`, inset by margin.
static func _in_directional_triangle(px: float, py: float, w: float, h: float, direction: String, margin: float) -> bool:
	# Map to a canonical "apex up" coordinate (a, b) in the same box.
	var a := px
	var b := py
	var ww := w
	var hh := h
	match direction:
		"up":
			a = px; b = py; ww = w; hh = h
		"down":
			a = px; b = h - py; ww = w; hh = h
		"left":
			a = py; b = px; ww = h; hh = w
		"right":
			a = py; b = w - px; ww = h; hh = w
	# Canonical apex-up: apex at (ww/2, 0), base at b = hh.
	var top := margin
	var bottom := hh - margin
	if b < top or b > bottom:
		return false
	var t := (b - top) / maxf(bottom - top, 0.0001)  # 0 at apex, 1 at base
	var half := (ww / 2.0 - margin) * t
	return half > 0.0 and abs(a - ww / 2.0) <= half


# -- Label rasterization (editor only) ----------------------------------------


## Render `text` centred into a transparent SubViewport and return its Image,
## or null on failure. Requires a display server (guarded by the caller).
static func _render_label(text: String, width: int, height: int, color: Color) -> Variant:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var viewport := SubViewport.new()
	viewport.size = Vector2i(width, height)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.disable_3d = true
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Fill the fixed-size SubViewport via anchors. No explicit .size — setting it
	# alongside FULL_RECT anchors emits a control.cpp:1440 "size overridden after
	# _ready" warning, and the anchors already produce the same width×height rect.
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(label)
	tree.root.add_child(viewport)
	# Let the viewport render once.
	await tree.process_frame
	await RenderingServer.frame_post_draw
	var texture := viewport.get_texture()
	var img: Variant = null
	if texture != null:
		img = texture.get_image()
	tree.root.remove_child(viewport)
	viewport.queue_free()
	return img


# -- Colour parsing -----------------------------------------------------------


## Parse a colour from a hex/named string, an [r,g,b(,a)] array (0-1 or 0-255),
## or null (returns default_color). Alpha 0 = "layer absent".
static func _parse_color(raw: Variant, default_color: Color) -> Color:
	match typeof(raw):
		TYPE_NIL:
			return default_color
		TYPE_COLOR:
			return raw
		TYPE_STRING:
			return Color.from_string(str(raw), default_color)
		TYPE_ARRAY:
			var a := raw as Array
			if a.size() >= 3:
				var r := float(a[0])
				var g := float(a[1])
				var b := float(a[2])
				var alpha := float(a[3]) if a.size() >= 4 else 1.0
				if r > 1.0 or g > 1.0 or b > 1.0 or alpha > 1.0:
					r /= 255.0
					g /= 255.0
					b /= 255.0
					if alpha > 1.0:
						alpha /= 255.0
				return Color(r, g, b, alpha)
	return default_color
