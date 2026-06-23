@tool
extends RefCounted
## Property-edit helper unit tests: compile_text_filter, compound set_property,
## the compound_set undo helper, and the _undo info dict. Exercises the
## commands/editor_helpers + scene/undo_redo_helpers pure logic.

const Helpers := preload("res://addons/godot_mcp_toolkit/commands/editor_helpers.gd")
const UndoRedoHelpers := preload("res://addons/godot_mcp_toolkit/scene/undo_redo_helpers.gd")


static func run(testing) -> void:
	_test_compile_text_filter(testing)
	_test_set_property_compound(testing)
	_test_compound_set_helper(testing)
	_test_undo_info(testing)


# --- Helpers: compile_text_filter (~6 assertions) -------------------------

static func _test_compile_text_filter(testing) -> void:
	testing.begin("compile_text_filter")

	# 1. Empty filter → null regex, no error
	var r1 := Helpers.compile_text_filter({"text_filter": "", "is_regex": true})
	testing.ok(r1[0] == null, "empty filter → null regex")
	testing.ok(r1[1] == null, "empty filter → no error")

	# 2. Non-regex → null regex
	var r2 := Helpers.compile_text_filter({"text_filter": "hello", "is_regex": false})
	testing.ok(r2[0] == null, "is_regex=false → null regex")

	# 3. Valid regex compiles
	var r3 := Helpers.compile_text_filter({"text_filter": "[0-9]+", "is_regex": true})
	testing.ok(r3[0] != null, "valid regex → RegEx instance")
	testing.ok(r3[1] == null, "valid regex → no error")

	# 4. Invalid regex → error returned
	var r4 := Helpers.compile_text_filter({"text_filter": "(unclosed", "is_regex": true})
	testing.ok(r4[0] == null, "invalid regex → null regex")
	testing.ok(r4[1] != null, "invalid regex → error dict")

	# 5. Double-escaped \\d → warning
	var r5 := Helpers.compile_text_filter({"text_filter": "test\\\\d+", "is_regex": true})
	testing.ok(r5[2] != "", "double-escaped \\d → warning not empty")

	# 6. Clean regex → empty warning
	var r6 := Helpers.compile_text_filter({"text_filter": "[0-9]+", "is_regex": true})
	testing.ok(r6[2] == "", "clean regex → empty warning")

	print("")


# --- Helpers: set_property_compound (~6 assertions) -----------------------

static func _test_set_property_compound(testing) -> void:
	testing.begin("set_property_compound")

	# 1. Simple slash path on a Control (theme_override)
	var ctrl := Control.new()
	var r1 := Helpers.set_property_compound(
		ctrl, "theme_override_font_sizes/font_size", 24)
	testing.ok(r1.get("ok", false), "theme_override slash path → ok")
	testing.eq(ctrl.get("theme_override_font_sizes/font_size"), 24,
		"theme_override readback = 24")
	ctrl.free()

	# 2. Colon path to sub-resource (ShaderMaterial shader_parameter)
	var shader := Shader.new()
	shader.code = "shader_type canvas_item;\nuniform float brightness : hint_range(0, 1) = 0.75;"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	# The node needs the material as a property for colon-chain navigation.
	# Use a Sprite2D which has a "material" property.
	var sprite := Sprite2D.new()
	sprite.material = mat
	var r2 := Helpers.set_property_compound(
		sprite, "material:shader_parameter/brightness", 0.3)
	testing.ok(r2.get("ok", false), "shader_parameter colon path → ok")
	var readback = sprite.get("material").get_shader_parameter("brightness")
	testing.eq(readback, 0.3, "shader_parameter readback = 0.3")
	sprite.free()

	# 3. Non-existent sub-resource → NOT_FOUND
	var node := Node2D.new()
	var r3 := Helpers.set_property_compound(
		node, "material:shader_parameter/x", 1.0)
	testing.ok(not r3.get("ok", false), "null sub-resource → error")
	testing.eq(r3.get("code", ""), "NOT_FOUND", "error code = NOT_FOUND")
	node.free()

	print("")


# --- compound_set helper (~8 assertions) ------------------------------------

static func _test_compound_set_helper(testing) -> void:
	testing.begin("compound_set helper")
	var helpers := UndoRedoHelpers.new()

	# 1. Slash-only path (theme override on Control)
	var ctrl := Control.new()
	ctrl.add_theme_font_size_override("font_size", 16)
	helpers.compound_set(ctrl, "theme_override_font_sizes/font_size", 32)
	testing.eq(ctrl.get("theme_override_font_sizes/font_size"), 32,
		"slash-only: theme_override set to 32")
	ctrl.free()

	# 2. Single-colon sub-resource (shader_parameter on ShaderMaterial)
	var shader := Shader.new()
	shader.code = "shader_type canvas_item;\nuniform float brightness : hint_range(0, 1) = 0.75;"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	var sprite := Sprite2D.new()
	sprite.material = mat
	helpers.compound_set(sprite, "material:shader_parameter/brightness", 0.4)
	testing.eq(mat.get_shader_parameter("brightness"), 0.4,
		"single-colon: shader_parameter set to 0.4")
	# Undo by setting back
	helpers.compound_set(sprite, "material:shader_parameter/brightness", 0.75)
	testing.eq(mat.get_shader_parameter("brightness"), 0.75,
		"single-colon: shader_parameter restored to 0.75")
	sprite.free()

	# 3. Multi-colon sub-resource navigation
	var shader2 := Shader.new()
	shader2.code = "shader_type canvas_item;\nuniform float glow : hint_range(0, 1) = 0.0;"
	var pass2 := ShaderMaterial.new()
	pass2.shader = shader2
	var mat2 := ShaderMaterial.new()
	mat2.shader = shader
	mat2.next_pass = pass2
	var sprite2 := Sprite2D.new()
	sprite2.material = mat2
	helpers.compound_set(sprite2, "material:next_pass:shader_parameter/glow", 0.5)
	testing.eq(pass2.get_shader_parameter("glow"), 0.5,
		"multi-colon: next_pass shader_parameter set to 0.5")
	sprite2.free()

	# 4. Simple property (no colon, no slash)
	var node := Node2D.new()
	node.visible = true
	helpers.compound_set(node, "visible", false)
	testing.eq(node.visible, false, "simple: visible set to false")
	node.free()

	# 5. Null sub-resource → no crash (silent return)
	var empty := Sprite2D.new()
	helpers.compound_set(empty, "material:shader_parameter/x", 1.0)
	testing.ok(true, "null sub-resource: no crash")
	empty.free()

	helpers.free()
	print("")


# --- _undo info from set_property_compound (~6 assertions) ------------------

static func _test_undo_info(testing) -> void:
	testing.begin("_undo info")

	# 1. Slash-only path returns property type
	var ctrl := Control.new()
	var r1 := Helpers.set_property_compound(
		ctrl, "theme_override_font_sizes/font_size", 24)
	testing.ok(r1.get("ok", false), "slash-only: set ok")
	var u1: Dictionary = r1.get("_undo", {})
	testing.eq(u1.get("type"), "property", "slash-only: _undo type = property")
	testing.eq(u1.get("path"), "theme_override_font_sizes/font_size",
		"slash-only: _undo path preserved")
	ctrl.free()

	# 2. Single-colon path returns sub_resource type (readback null for in-memory)
	var shader := Shader.new()
	shader.code = "shader_type canvas_item;\nuniform float brightness : hint_range(0, 1) = 0.75;"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	var sprite := Sprite2D.new()
	sprite.material = mat
	var r2 := Helpers.set_property_compound(
		sprite, "material:shader_parameter/brightness", 0.3)
	testing.ok(r2.get("ok", false), "colon: set ok")
	var u2: Dictionary = r2.get("_undo", {})
	testing.ok(u2.get("type") == "property" or u2.get("type") == "sub_resource",
		"colon: _undo type is property or sub_resource")
	testing.eq(u2.get("old"), null, "colon: _undo old = null (no prior override)")
	sprite.free()

	print("")
