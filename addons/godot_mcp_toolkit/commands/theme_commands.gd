@tool
extends RefCounted
## theme.* command handlers — create/modify Theme resources.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const FileGuard = Modules.FileGuard
const Helpers = Modules.CommandHelpers

const _VALID_PROPERTY_TYPES := ["color", "constant", "font", "font_size", "icon", "stylebox"]


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("theme.edit", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_theme_edit(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())


# -- Commands -----------------------------------------------------------------


static func _cmd_theme_edit(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path", "edits"])
	if err != null:
		return err

	var file_path := str(parameters.get("file_path", ""))
	file_path = Helpers.normalize_editor_path(file_path)
	var edits_raw = parameters.get("edits", null)

	if typeof(edits_raw) != TYPE_ARRAY:
		return MCPToolkitError.fail("INVALID_PARAMS", "edits must be an Array of edit descriptors")

	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if not file_path.get_extension().to_lower() in ["tres", "res"]:
		return MCPToolkitError.fail("INVALID_PATH",
			"theme.edit writes .tres/.res files (got %s)" % file_path)

	# Load existing or create new Theme.
	var theme: Theme
	if FileAccess.file_exists(file_path):
		var loaded = ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if loaded == null or not (loaded is Theme):
			return MCPToolkitError.fail("INVALID_CLASS",
				"Resource at %s is not a Theme" % file_path)
		theme = loaded as Theme
	else:
		theme = Theme.new()

	var edits: Array = edits_raw
	var edits_applied := 0

	for i in range(edits.size()):
		var edit = edits[i]
		if typeof(edit) != TYPE_DICTIONARY:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"edits[%d] must be a dictionary" % i)

		# Validate required keys per edit.
		for key in ["type_name", "property_type", "property", "value"]:
			if not edit.has(key):
				return MCPToolkitError.fail("INVALID_PARAMS",
					"edits[%d] missing required key '%s'" % [i, key])

		var type_name := str(edit["type_name"])
		var property_type := str(edit["property_type"])
		var property_name := str(edit["property"])
		var value = edit["value"]

		if property_type not in _VALID_PROPERTY_TYPES:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"edits[%d] invalid property_type '%s'; must be one of: %s" % [
					i, property_type, ", ".join(_VALID_PROPERTY_TYPES)])

		var apply_err := _apply_edit(theme, type_name, property_type, property_name, value, i)
		if not apply_err.is_empty():
			return MCPToolkitError.fail("INVALID_PARAMS", apply_err)
		edits_applied += 1

	# Save.
	var dir_result := Helpers.ensure_parent_dir(file_path, "theme.edit")
	if dir_result.has("error"):
		return dir_result
	var save_err := ResourceSaver.save(theme, file_path)
	if save_err != OK:
		return MCPToolkitError.fail("SAVE_FAILED",
			"ResourceSaver.save returned %d (path=%s)" % [save_err, file_path])
	ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	await Helpers.ensure_file_indexed(file_path)

	return MCPToolkitSuccess.ok({
		"path": file_path,
		"edits_applied": edits_applied,
	})


# -- Edit helpers -------------------------------------------------------------


## Project a {r,g,b,a} dict onto a Color with opaque-BLACK channel defaults
## (paint semantics: r/g/b default 0.0, a defaults 1.0). Distinct from
## Coerce.color_from_dict (opaque-WHITE / tint) — do not conflate. Non-dict -> opaque black.
static func _color_from_dict_opaque(d: Variant) -> Color:
	if typeof(d) != TYPE_DICTIONARY:
		return Color(0, 0, 0, 1)
	return Color(
		float(d.get("r", 0.0)), float(d.get("g", 0.0)),
		float(d.get("b", 0.0)), float(d.get("a", 1.0)))


static func _apply_edit(
	theme: Theme, type_name: String, property_type: String,
	property_name: String, value: Variant, index: int,
) -> String:
	match property_type:
		"color":
			if typeof(value) != TYPE_DICTIONARY:
				return "edits[%d] color value must be {r, g, b, a?}" % index
			theme.set_color(property_name, type_name, _color_from_dict_opaque(value))

		"constant":
			theme.set_constant(property_name, type_name, int(value))

		"font":
			var font_path := str(value)
			var font = load(font_path)
			if font == null or not (font is Font):
				return "edits[%d] font not found or not a Font: %s" % [index, font_path]
			theme.set_font(property_name, type_name, font as Font)

		"font_size":
			theme.set_font_size(property_name, type_name, int(value))

		"icon":
			var icon_path := str(value)
			var icon = load(icon_path)
			if icon == null or not (icon is Texture2D):
				return "edits[%d] icon not found or not a Texture2D: %s" % [index, icon_path]
			theme.set_icon(property_name, type_name, icon as Texture2D)

		"stylebox":
			if typeof(value) != TYPE_DICTIONARY:
				return "edits[%d] stylebox value must be a dictionary with 'type' key" % index
			var sb_type := str(value.get("type", ""))
			var sb = _create_stylebox(sb_type, value, index)
			if sb is String:
				return sb as String
			theme.set_stylebox(property_name, type_name, sb as StyleBox)

	return ""


static func _create_stylebox(sb_type: String, value: Dictionary, index: int) -> Variant:
	match sb_type:
		"StyleBoxFlat":
			var sb := StyleBoxFlat.new()
			if value.has("bg_color") and typeof(value["bg_color"]) == TYPE_DICTIONARY:
				sb.bg_color = _color_from_dict_opaque(value["bg_color"])
			if value.has("corner_radius"):
				var r := int(value["corner_radius"])
				sb.corner_radius_top_left = r
				sb.corner_radius_top_right = r
				sb.corner_radius_bottom_left = r
				sb.corner_radius_bottom_right = r
			if value.has("content_margin"):
				var m := float(value["content_margin"])
				sb.content_margin_left = m
				sb.content_margin_top = m
				sb.content_margin_right = m
				sb.content_margin_bottom = m
			if value.has("border_width"):
				var w := int(value["border_width"])
				sb.border_width_left = w
				sb.border_width_top = w
				sb.border_width_right = w
				sb.border_width_bottom = w
			if value.has("border_color") and typeof(value["border_color"]) == TYPE_DICTIONARY:
				sb.border_color = _color_from_dict_opaque(value["border_color"])
			return sb

		"StyleBoxTexture":
			var sb := StyleBoxTexture.new()
			if value.has("texture"):
				var tex = load(str(value["texture"]))
				if tex == null or not (tex is Texture2D):
					return "edits[%d] stylebox texture not found: %s" % [index, str(value["texture"])]
				sb.texture = tex as Texture2D
			if value.has("content_margin"):
				var m := float(value["content_margin"])
				sb.content_margin_left = m
				sb.content_margin_top = m
				sb.content_margin_right = m
				sb.content_margin_bottom = m
			return sb

		"StyleBoxLine":
			var sb := StyleBoxLine.new()
			if value.has("color") and typeof(value["color"]) == TYPE_DICTIONARY:
				sb.color = _color_from_dict_opaque(value["color"])
			if value.has("thickness"):
				sb.thickness = int(value["thickness"])
			if value.has("vertical"):
				sb.vertical = bool(value["vertical"])
			return sb

		_:
			return "edits[%d] unknown stylebox type '%s'; must be StyleBoxFlat, StyleBoxTexture, or StyleBoxLine" % [index, sb_type]
