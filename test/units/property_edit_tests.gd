@tool
extends RefCounted
## Property-edit helper unit tests: compile_text_filter, compound set_property,
## the compound_set undo helper, and the _undo info dict. Exercises the
## commands/editor_helpers + scene/undo_redo_helpers pure logic.

const Helpers := preload("res://addons/godot_mcp_toolkit/commands/editor_helpers.gd")
const UndoRedoHelpers := preload("res://addons/godot_mcp_toolkit/scene/undo_redo_helpers.gd")
const Coerce := preload("res://addons/godot_mcp_toolkit/contract/coerce.gd")
const PropertySetCheck := preload("res://addons/godot_mcp_toolkit/contract/property_set_check.gd")


static func run(testing) -> void:
	_test_compile_text_filter(testing)
	_test_set_property_compound(testing)
	_test_wrong_type_set_rejection(testing)
	_test_set_drop_logic(testing)
	_test_scene_create_node_inline_drop(testing)
	_test_runtime_set_property_pipeline(testing)
	_test_compound_set_helper(testing)
	_test_undo_info(testing)


# --- Helpers: compile_text_filter (~6 assertions) -------------------------

static func _test_compile_text_filter(testing) -> void:
	testing.begin("compile_text_filter")

	# 1. Empty filter → null regex, no error
	var empty_filter := Helpers.compile_text_filter({"text_filter": "", "is_regex": true})
	testing.ok(empty_filter[0] == null, "empty filter → null regex")
	testing.ok(empty_filter[1] == null, "empty filter → no error")

	# 2. Non-regex → null regex
	var non_regex_filter := Helpers.compile_text_filter({"text_filter": "hello", "is_regex": false})
	testing.ok(non_regex_filter[0] == null, "is_regex=false → null regex")

	# 3. Valid regex compiles
	var valid_regex := Helpers.compile_text_filter({"text_filter": "[0-9]+", "is_regex": true})
	testing.ok(valid_regex[0] != null, "valid regex → RegEx instance")
	testing.ok(valid_regex[1] == null, "valid regex → no error")

	# 4. Invalid regex → error returned
	var invalid_regex := Helpers.compile_text_filter({"text_filter": "(unclosed", "is_regex": true})
	testing.ok(invalid_regex[0] == null, "invalid regex → null regex")
	testing.ok(invalid_regex[1] != null, "invalid regex → error dict")

	# 5. Double-escaped \\d → warning
	var double_escaped_regex := Helpers.compile_text_filter({"text_filter": "test\\\\d+", "is_regex": true})
	testing.ok(double_escaped_regex[2] != "", "double-escaped \\d → warning not empty")

	# 6. Clean regex → empty warning
	var clean_regex := Helpers.compile_text_filter({"text_filter": "[0-9]+", "is_regex": true})
	testing.ok(clean_regex[2] == "", "clean regex → empty warning")

	print("")


# --- Helpers: set_property_compound (~6 assertions) -----------------------

static func _test_set_property_compound(testing) -> void:
	testing.begin("set_property_compound")

	# 1. Simple slash path on a Control (theme_override)
	var ctrl := Control.new()
	var theme_override_result := Helpers.set_property_compound(
		ctrl, "theme_override_font_sizes/font_size", 24)
	testing.ok(theme_override_result.get("ok", false), "theme_override slash path → ok")
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
	var shader_parameter_result := Helpers.set_property_compound(
		sprite, "material:shader_parameter/brightness", 0.3)
	testing.ok(shader_parameter_result.get("ok", false), "shader_parameter colon path → ok")
	var readback = sprite.get("material").get_shader_parameter("brightness")
	testing.eq(readback, 0.3, "shader_parameter readback = 0.3")
	sprite.free()

	# 3. Non-existent sub-resource → NOT_FOUND
	var node := Node2D.new()
	var missing_sub_resource_result := Helpers.set_property_compound(
		node, "material:shader_parameter/x", 1.0)
	testing.ok(not missing_sub_resource_result.get("ok", false), "null sub-resource → error")
	testing.eq(missing_sub_resource_result.get("code", ""), "NOT_FOUND", "error code = NOT_FOUND")
	node.free()

	print("")


# --- Wrong-type set rejection (silent-drop guard) ------------------------
# Godot's Object.set() silently discards a wrong-type Variant, which used to be
# reported as a false success against the unchanged property. These pin, end to
# end through set_property_compound's scalar (no-colon) path: a wrong-type write
# → clean SET_FAILED error + unchanged property; and every valid write (exact,
# int→float, set-to-same, transform-backed) → success.
static func _test_wrong_type_set_rejection(testing) -> void:
	testing.begin("wrong-type set rejection")

	var sprite := Sprite2D.new()
	# NON-ZERO prior so the destructive-zero path is exercised: Node2D.position is a
	# bound setter that Variant-converts a wrong type to ZERO and stores it, so the
	# readback moves off (50,50) — the exact case that regressed to a false "adjusted"
	# success. set_property_compound restores the prior on a drop (non-destructive).
	sprite.position = Vector2(50, 50)

	# 1. String → Vector2 (non-zero prior → zeroed): dropped → SET_FAILED, RESTORED.
	var s_to_vec: Dictionary = Helpers.set_property_compound(
		sprite, "position", "not a vector")
	testing.ok(not s_to_vec.get("ok", false), "String→Vector2 (non-zero prior): rejected (not ok)")
	testing.eq(s_to_vec.get("code", ""), "SET_FAILED", "String→Vector2: code SET_FAILED")
	testing.ok(not s_to_vec.has("warning"), "String→Vector2: NOT adjusted (carries no warning)")
	testing.ok(str(s_to_vec.get("error", "")).find("position") >= 0,
		"String→Vector2: error names the property")
	testing.eq(sprite.position, Vector2(50, 50), "String→Vector2: prior RESTORED, not zeroed")

	# 2. Color → Vector2 (non-zero prior → zeroed): dropped → SET_FAILED, RESTORED.
	var c_to_vec: Dictionary = Helpers.set_property_compound(
		sprite, "position", {"type": "Color", "r": 1, "g": 0, "b": 0, "a": 1})
	testing.ok(not c_to_vec.get("ok", false), "Color→Vector2 (non-zero prior): rejected (not ok)")
	testing.eq(c_to_vec.get("code", ""), "SET_FAILED", "Color→Vector2: code SET_FAILED")
	testing.ok(not c_to_vec.has("warning"), "Color→Vector2: NOT adjusted (carries no warning)")
	testing.eq(sprite.position, Vector2(50, 50), "Color→Vector2: prior RESTORED, not zeroed")

	# 3. Exact-type set still succeeds.
	var exact: Dictionary = Helpers.set_property_compound(
		sprite, "position", {"type": "Vector2", "x": 100, "y": 100})
	testing.ok(exact.get("ok", false), "exact Vector2: ok")
	testing.eq(sprite.position, Vector2(100, 100), "exact Vector2: value applied")

	# 4. int→float coercion still succeeds (JSON ints arrive as floats). z_index
	#    is a native int property; 5.0 must land as 5, not be flagged a drop.
	var int_prop: Dictionary = Helpers.set_property_compound(sprite, "z_index", 5.0)
	testing.ok(int_prop.get("ok", false), "float→int property: ok")
	testing.eq(sprite.z_index, 5, "float→int property: stored as 5")

	# 5. Set-to-same value succeeds (property already equals the request).
	var same: Dictionary = Helpers.set_property_compound(
		sprite, "position", {"type": "Vector2", "x": 100, "y": 100})
	testing.ok(same.get("ok", false), "set-to-same Vector2: ok")
	testing.eq(sprite.position, Vector2(100, 100), "set-to-same Vector2: value held")

	sprite.free()

	# 6. Transform-backed setter: the engine stores a different backing value
	#    (rotation, radians) than the input (rotation_degrees), yet the write is
	#    accepted — a same-type write is trusted. Guards against false-failing
	#    normalizing/transforming properties.
	var node := Node2D.new()
	var xform: Dictionary = Helpers.set_property_compound(node, "rotation_degrees", 90.0)
	testing.ok(xform.get("ok", false), "rotation_degrees set: ok (transform-backed)")
	testing.ok(absf(node.rotation - deg_to_rad(90.0)) < 0.001,
		"rotation_degrees: rotation stored in radians")
	node.free()

	# 7. Accepted-but-ADJUSTED: a fractional float on an int property truncates
	#    (hframes 2.9 → 2). The write IS accepted → ok, and set_property_compound
	#    propagates the tri-state "warning" naming the stored-vs-requested delta.
	var sprite2 := Sprite2D.new()
	var adj: Dictionary = Helpers.set_property_compound(sprite2, "hframes", 2.9)
	testing.ok(adj.get("ok", false), "float→int truncation: ok (accepted)")
	testing.ok(adj.has("warning"), "float→int truncation: carries the adjusted warning")
	testing.eq(sprite2.hframes, 2, "float→int truncation: stored 2")
	sprite2.free()

	print("")


# --- describe_set_drop tri-state logic (ok / adjusted / dropped) -----------
# Pins the detector's decision table directly with hand-built before/after/coerced
# triples — no engine set() involved. Locks the tri-state: clean OK, accepted-but-
# ADJUSTED (engine reshaped the value → success + warning), and silent DROPPED
# (cross-family wrong type → SET_FAILED), incl. the truncate/sanitize FPs and the
# restored wrong-subtype-Resource drop.
static func _test_set_drop_logic(testing) -> void:
	testing.begin("describe_set_drop tri-state")

	# --- OK (clean): stored ≈ requested ---
	# int→float where 5.0 == 5 → clean, NOT adjusted.
	testing.eq(_status(Helpers.describe_set_drop(0, 5, 5.0, "z_index")), "ok",
		"int→float 5.0==5 → ok (clean)")
	# Cross-type set-to-same (property already holds the request) → ok.
	testing.eq(_status(Helpers.describe_set_drop(5, 5, 5.0, "z_index")), "ok",
		"cross-type set-to-same → ok")
	# Same-type write that stored the request exactly → ok.
	testing.eq(_status(Helpers.describe_set_drop(Vector2.ZERO, Vector2(1, 0), Vector2(1, 0), "p")), "ok",
		"same-type exact store → ok")
	# Stringy cross-type stored the request (StringName &"b" ≈ "b") → ok.
	testing.eq(_status(Helpers.describe_set_drop(&"a", &"b", "b", "name")), "ok",
		"stringy cross-type stored request → ok")

	# --- ADJUSTED: accepted but engine reshaped the value (success + warning) ---
	# Fractional float truncates onto the CURRENT int value (7 + 7.9 → 7).
	var trunc_same: Dictionary = Helpers.describe_set_drop(7, 7, 7.9, "hframes")
	testing.eq(_status(trunc_same), "adjusted", "float 7.9 → int 7 (onto current) → adjusted")
	testing.ok(str(trunc_same.get("warning", "")).find("hframes") >= 0,
		"truncate-onto-current warning names the property")
	# Truncation that MOVED the value (before 5, requested 7.9, stored 7) → adjusted.
	testing.eq(_status(Helpers.describe_set_drop(5, 7, 7.9, "hframes")), "adjusted",
		"float 7.9 → int 7 (moved) → adjusted")
	# Stringy sanitize onto the current value ("Foo/" → "Foo", already "Foo") → adjusted.
	var sanitize: Dictionary = Helpers.describe_set_drop(&"Foo", &"Foo", "Foo/", "name")
	testing.eq(_status(sanitize), "adjusted", "stringy sanitize-to-current → adjusted")
	testing.ok(str(sanitize.get("warning", "")) != "", "sanitize adjusted carries a warning")
	# Same-type normalize-to-same-as-before ((2,0) → (1,0), already (1,0)) → adjusted.
	testing.eq(_status(Helpers.describe_set_drop(Vector2(1, 0), Vector2(1, 0), Vector2(2, 0), "dir")), "adjusted",
		"normalize-to-same (same type) → adjusted (not a false drop)")

	# --- DROPPED: cross-family write the engine did not store as a real value ---
	# Lock BOTH original-bug directions from a ZERO prior (kept-old, after == before).
	testing.eq(_status(Helpers.describe_set_drop(Vector2.ZERO, Vector2.ZERO, "nope", "position")), "dropped",
		"String → Vector2, zero prior (kept-old) → dropped")
	testing.eq(_status(Helpers.describe_set_drop(Vector2.ZERO, Vector2.ZERO, Color(1, 0, 0, 1), "position")), "dropped",
		"Color → Vector2, zero prior (kept-old) → dropped")
	# REGRESSION (destructive-zero): a bound setter (position/modulate) converts the
	# wrong type to a ZERO and STORES it, so after ≠ before. This is the case that hit
	# the old "adjusted" branch and returned a false success — it MUST be dropped.
	testing.eq(_status(Helpers.describe_set_drop(Vector2(50, 50), Vector2.ZERO, "not a vector", "position")), "dropped",
		"String → Vector2, NON-ZERO prior zeroed (after≠before) → dropped")
	testing.eq(_status(Helpers.describe_set_drop(Color(0, 1, 0, 1), Color(0, 0, 0, 1), "green", "modulate")), "dropped",
		"String → Color, modulate green→black (after≠before) → dropped")
	# Null readback with a non-null request (dedicated-API) → dropped.
	testing.eq(_status(Helpers.describe_set_drop("old", null, "new", "p")), "dropped",
		"null readback → dropped")
	# Restored: wrong-subtype Resource that kept its old object (both OBJECT) → dropped.
	var res_a := Resource.new()
	var res_b := Resource.new()
	testing.eq(_status(Helpers.describe_set_drop(res_a, res_a, res_b, "texture")), "dropped",
		"wrong-subtype Resource (kept old object) → dropped")
	# Valid Resource set-to-same object → ok (identity backstop, no false drop).
	testing.eq(_status(Helpers.describe_set_drop(res_a, res_a, res_a, "texture")), "ok",
		"Resource set-to-same object → ok")

	print("")


## The "status" field of a describe_set_drop tri-state result (test accessor).
static func _status(outcome: Dictionary) -> String:
	return str(outcome.get("status", ""))


# --- scene.create_node inline-property drop reporting --------------------------
# scene.create_node applies a `properties` dict at create time. Coercion only proves
# a value is well-formed; Object.set() is void and silently discards a wrong-type
# Variant (a value node.set_property rejects outright), so each write must be
# readback-verified or a discarded value would count as set. This pins the per-prop
# classification the handler runs — coerce → set → readback → the bare-res:// guard →
# describe_set_drop — on a real Sprite2D against the two known bad-form values
# (bare-string texture, bare-array scale) plus their valid tagged equivalents. The
# editor-bound handler wrapper (needs an edited scene) is exercised end to end by
# server smoke §02; this locks the pure classification headlessly.
static func _test_scene_create_node_inline_drop(testing) -> void:
	testing.begin("scene.create_node inline-property drop")

	# texture as a bare "res://…" string → coercion passes it through (well-formed
	# string), but set() can't assign a String to a Texture2D slot, so the readback
	# stays null. The bare-res:// guard fires and steers to the tagged form → DROPPED.
	var sprite := Sprite2D.new()
	var tex_coerce: Dictionary = Helpers.coerce_for_property(
		sprite, "texture", "res://icon.svg")
	testing.ok(tex_coerce.get("ok", false),
		"bare-string texture: coercion passes it through (well-formed string)")
	var tex_old = sprite.get("texture")
	var tex_value = tex_coerce["value"]
	sprite.set("texture", tex_value)
	var tex_after = sprite.get("texture")
	var tex_bare_res := typeof(tex_value) == TYPE_STRING \
		and str(tex_value).begins_with("res://") \
		and not (tex_value is Resource) and not (tex_after is String)
	testing.ok(tex_bare_res, "bare-string texture: bare-res:// guard fires (would report INVALID_VALUE)")

	# scale as a bare Array [4,4] → coercion recurses to a float Array, but set()
	# can't assign an Array to a Vector2 slot (cross-family), so describe_set_drop
	# classifies it DROPPED with the SET_FAILED-style message.
	var scale_coerce: Dictionary = Helpers.coerce_for_property(sprite, "scale", [4, 4])
	testing.ok(scale_coerce.get("ok", false),
		"bare-array scale: coercion passes it through (recurses to float Array)")
	var scale_old = sprite.get("scale")
	var scale_value = scale_coerce["value"]
	sprite.set("scale", scale_value)
	var scale_after = sprite.get("scale")
	var scale_outcome: Dictionary = Helpers.describe_set_drop(
		scale_old, scale_after, scale_value, "scale")
	testing.eq(_status(scale_outcome), "dropped", "bare-array scale → dropped")
	testing.ok(str(scale_outcome.get("error", "")).find("scale") >= 0,
		"bare-array scale: drop error names the property")
	# Handler restores the prior on a drop → scale is untouched by the failed write.
	sprite.set("scale", scale_old)
	testing.eq(sprite.scale, scale_old, "bare-array scale: prior restored (non-destructive)")

	# Valid tagged equivalents land cleanly (no drop). Contrast with the two above.
	# Point at a committed PlaceholderTexture2D .tres, NOT an imported asset (icon.svg):
	# the tagged-Resource branch calls ResourceLoader.load, and imported files
	# (.svg/.png) have no import artifact in the cold `--headless --script` unit runner
	# (.godot/imported/ is gitignored and only rebuilt by the CI warm-up editor scan,
	# which the runner races). A .tres is parsed directly with no import pipeline, so it
	# loads deterministically whether the cache is cold (CI) or warm (local editor open).
	var tex_ok: Dictionary = Helpers.coerce_for_property(
		sprite, "texture", {"type": "Resource", "path": "res://test/fixtures/placeholder_texture.tres"})
	testing.ok(tex_ok.get("ok", false), "tagged Resource texture: coercion ok")
	var tex_ok_old = sprite.get("texture")
	var tex_ok_value = tex_ok["value"]
	testing.ok(tex_ok_value is Resource, "tagged Resource texture: coerces to a real Resource")
	sprite.set("texture", tex_ok_value)
	testing.eq(_status(Helpers.describe_set_drop(
		tex_ok_old, sprite.get("texture"), tex_ok_value, "texture")), "ok",
		"tagged Resource texture → ok (stored)")

	var scale_ok: Dictionary = Helpers.coerce_for_property(
		sprite, "scale", {"type": "Vector2", "x": 4, "y": 4})
	testing.ok(scale_ok.get("ok", false), "tagged Vector2 scale: coercion ok")
	var scale_ok_old = sprite.get("scale")
	var scale_ok_value = scale_ok["value"]
	sprite.set("scale", scale_ok_value)
	testing.eq(_status(Helpers.describe_set_drop(
		scale_ok_old, sprite.get("scale"), scale_ok_value, "scale")), "ok",
		"tagged Vector2 scale → ok (stored)")
	testing.eq(sprite.scale, Vector2(4, 4), "tagged Vector2 scale: value applied")

	sprite.free()
	print("")


# --- runtime.set_property wrong-type pipeline (runtime autoload) ----
# The runtime autoload's _cmd_runtime_set_property applies the SAME shared leaf
# detector as the editor path: coerce → get(before) → set → get(after) →
# PropertySetCheck.describe_set_drop. Exercise that exact pure pipeline headlessly
# (no editor, no WebSocket) so the runtime path's wrong-type rejection is pinned.
static func _test_runtime_set_property_pipeline(testing) -> void:
	testing.begin("runtime.set_property wrong-type pipeline")

	var sprite := Sprite2D.new()
	# NON-ZERO prior so the bound-setter destructive-zero path is exercised (the
	# regression): position (50,50) → a String stores ZERO, so after ≠ before.
	sprite.position = Vector2(50, 50)

	# DROPPED: a String on the Vector2 bound setter zeroes the value (after ≠ before)
	# — still classified "dropped", NOT "adjusted". The full runtime handler returns
	# SET_FAILED and restores the prior; this pure pipeline pins the classification.
	var bad_coerced: Variant = Coerce.coerce_value("not a vector")
	var bad_before: Variant = sprite.get("position")
	sprite.set("position", bad_coerced)
	var bad_after: Variant = sprite.get("position")
	var bad_outcome: Dictionary = PropertySetCheck.describe_set_drop(
		bad_before, bad_after, bad_coerced, "position")
	testing.eq(_status(bad_outcome), "dropped", "runtime non-zero-prior destructive → dropped")
	testing.ok(not bad_outcome.has("warning"), "runtime destructive drop: NOT adjusted (no warning)")
	testing.ok(str(bad_outcome.get("error", "")).find("position") >= 0,
		"runtime wrong-type: error names the property")
	testing.eq(bad_after, Vector2.ZERO, "runtime raw set zeroed the value (handler restores it)")

	# OK: a tagged Vector2 lands exactly → clean (the runtime returns plain success).
	var ok_coerced: Variant = Coerce.coerce_value({"type": "Vector2", "x": 7, "y": 8})
	var ok_before: Variant = sprite.get("position")
	sprite.set("position", ok_coerced)
	var ok_after: Variant = sprite.get("position")
	testing.eq(
		_status(PropertySetCheck.describe_set_drop(ok_before, ok_after, ok_coerced, "position")),
		"ok", "runtime valid set → ok")
	testing.eq(sprite.position, Vector2(7, 8), "runtime valid set: value applied")

	# ADJUSTED: a fractional float onto an int property truncates (hframes 2.9 → 2) —
	# accepted, so the runtime returns success WITH a warning naming the delta.
	var adj_coerced: Variant = Coerce.coerce_value(2.9)
	var adj_before: Variant = sprite.get("hframes")
	sprite.set("hframes", adj_coerced)
	var adj_after: Variant = sprite.get("hframes")
	var adj_outcome: Dictionary = PropertySetCheck.describe_set_drop(
		adj_before, adj_after, adj_coerced, "hframes")
	testing.eq(_status(adj_outcome), "adjusted", "runtime float→int truncation → adjusted")
	testing.ok(str(adj_outcome.get("warning", "")) != "", "runtime adjusted carries a warning")
	testing.eq(sprite.hframes, 2, "runtime truncation: stored 2")

	sprite.free()
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
	var glow_shader := Shader.new()
	glow_shader.code = "shader_type canvas_item;\nuniform float glow : hint_range(0, 1) = 0.0;"
	var next_pass_material := ShaderMaterial.new()
	next_pass_material.shader = glow_shader
	var outer_material := ShaderMaterial.new()
	outer_material.shader = shader
	outer_material.next_pass = next_pass_material
	var nested_sprite := Sprite2D.new()
	nested_sprite.material = outer_material
	helpers.compound_set(nested_sprite, "material:next_pass:shader_parameter/glow", 0.5)
	testing.eq(next_pass_material.get_shader_parameter("glow"), 0.5,
		"multi-colon: next_pass shader_parameter set to 0.5")
	nested_sprite.free()

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
	var slash_only_result := Helpers.set_property_compound(
		ctrl, "theme_override_font_sizes/font_size", 24)
	testing.ok(slash_only_result.get("ok", false), "slash-only: set ok")
	var slash_only_undo: Dictionary = slash_only_result.get("_undo", {})
	testing.eq(slash_only_undo.get("type"), "property", "slash-only: _undo type = property")
	testing.eq(slash_only_undo.get("path"), "theme_override_font_sizes/font_size",
		"slash-only: _undo path preserved")
	ctrl.free()

	# 2. Single-colon path returns sub_resource type (readback null for in-memory)
	var shader := Shader.new()
	shader.code = "shader_type canvas_item;\nuniform float brightness : hint_range(0, 1) = 0.75;"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	var sprite := Sprite2D.new()
	sprite.material = mat
	var colon_result := Helpers.set_property_compound(
		sprite, "material:shader_parameter/brightness", 0.3)
	testing.ok(colon_result.get("ok", false), "colon: set ok")
	var colon_undo: Dictionary = colon_result.get("_undo", {})
	testing.ok(colon_undo.get("type") == "property" or colon_undo.get("type") == "sub_resource",
		"colon: _undo type is property or sub_resource")
	testing.eq(colon_undo.get("old"), null, "colon: _undo old = null (no prior override)")
	sprite.free()

	print("")
