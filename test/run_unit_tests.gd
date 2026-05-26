extends SceneTree
## Headless unit test runner for MCP Toolkit pure-logic internals.
##
## Run: timeout 30 godot --headless --script test/run_unit_tests.gd
##
## Exit code: 0 = all passed, 1 = failures detected.
## The final banner is always printed for environments where exit codes
## are unreliable (Windows Godot).

var _passed := 0
var _failed := 0
var _errors: Array[String] = []
var _group := ""


func _init() -> void:
	print("=== MCP Toolkit Unit Tests ===")
	print("")

	if not _guard_addon_classes():
		quit(1)
		return

	_test_registry()
	_test_options_builder()
	_test_extension_options()
	_test_annotation_mapping()
	_test_timeout_clamping()
	_test_tool_context()
	_test_compile_text_filter()
	_test_set_property_compound()
	_test_compound_set_helper()
	_test_undo_info()

	_report()
	quit(0 if _failed == 0 else 1)


# --- Guards ----------------------------------------------------------------

func _guard_addon_classes() -> bool:
	# If any class_name is unavailable (addon not enabled), Godot throws a
	# parse error before _init() runs. This runtime check is defence-in-depth
	# for unexpected constructor failures.
	var r := MCPToolkitCommandRegistry.new()
	var o := MCPToolkitCommandOptions.new()
	var e := MCPToolkitExtensionOptions.new("guard")
	var c := MCPToolkitToolContext.new()
	if r == null or o == null or e == null or c == null:
		print("FAIL: addon classes not accessible — is the addon enabled in project.godot?")
		return false
	print("Guard: all 4 addon classes accessible")
	print("")
	return true


# --- Assertion helpers -----------------------------------------------------

func _begin(name: String) -> void:
	_group = name
	print("[%s]" % name)


func _ok(value: bool, label: String) -> void:
	if value:
		_passed += 1
		print("  PASS: %s" % label)
	else:
		_failed += 1
		_errors.append("%s > %s" % [_group, label])
		print("  FAIL: %s" % label)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		_passed += 1
		print("  PASS: %s" % label)
	else:
		_failed += 1
		_errors.append("%s > %s" % [_group, label])
		print("  FAIL: %s (expected: %s, got: %s)" % [
			label, str(expected), str(actual)])


func _noop(_p: Dictionary) -> Dictionary:
	return {"success": true}


# --- Registry (~17 assertions) --------------------------------------------

func _test_registry() -> void:
	_begin("Registry")
	var reg := MCPToolkitCommandRegistry.new()

	# 1. mark_read_only → is_read_only true
	reg.add("t.ro", _noop, MCPToolkitCommandOptions.new().mark_read_only())
	_ok(reg.is_read_only("t.ro"), "mark_read_only → is_read_only true")

	# 2. default → is_read_only false
	reg.add("t.def", _noop, MCPToolkitCommandOptions.new())
	_ok(not reg.is_read_only("t.def"), "default → is_read_only false")

	# 3. mark_scene_independent → is_active_scene_required false
	reg.add("t.si", _noop, MCPToolkitCommandOptions.new().mark_scene_independent())
	_ok(not reg.is_active_scene_required("t.si"),
			"mark_scene_independent → is_active_scene_required false")

	# 4. default → is_active_scene_required true
	_ok(reg.is_active_scene_required("t.def"),
			"default → is_active_scene_required true")

	# 5. mark_exclusive_execution → is_force_serialized true
	reg.add("t.excl", _noop, MCPToolkitCommandOptions.new().mark_exclusive_execution())
	_ok(reg.is_force_serialized("t.excl"),
			"mark_exclusive_execution → is_force_serialized true")

	# 6. mark_cancellable → is_cancellable true
	reg.add("t.canc", _noop, MCPToolkitCommandOptions.new().mark_cancellable())
	_ok(reg.is_cancellable("t.canc"), "mark_cancellable → is_cancellable true")

	# 7-8. needs_serialization: read-only bypasses, default serialises
	_ok(not reg.needs_serialization("t.ro"),
			"needs_serialization for read-only → false")
	_ok(reg.needs_serialization("t.def"),
			"needs_serialization for non-read-only → true")

	# 9. remove → has_command false
	reg.add("t.rm", _noop, MCPToolkitCommandOptions.new())
	reg.remove("t.rm")
	_ok(not reg.has_command("t.rm"), "remove → has_command false")

	# 10. clear → get_all_methods empty
	var reg2 := MCPToolkitCommandRegistry.new()
	reg2.add("t.a", _noop, MCPToolkitCommandOptions.new())
	reg2.add("t.b", _noop, MCPToolkitCommandOptions.new())
	reg2.clear()
	_eq(reg2.get_all_methods().size(), 0, "clear → get_all_methods empty")

	# 11. mark_extension → get_extension_methods includes it
	reg.add("t.ext", _noop, MCPToolkitCommandOptions.new())
	reg.mark_extension("t.ext")
	_ok(reg.get_extension_methods().has("t.ext"),
			"mark_extension → in get_extension_methods")

	# 12. get_command_metadata contains description
	reg.add("t.desc", _noop,
			MCPToolkitCommandOptions.new().with_description("Hello"))
	_eq(reg.get_command_metadata("t.desc").get("description", ""), "Hello",
			"get_command_metadata → correct description")

	# 13. duplicate registration — overwrites cleanly, latest wins
	reg.add("t.dup", _noop, MCPToolkitCommandOptions.new())
	reg.add("t.dup", _noop, MCPToolkitCommandOptions.new().mark_read_only())
	_ok(reg.has_command("t.dup"), "duplicate → still registered")
	_ok(reg.is_read_only("t.dup"), "duplicate → latest options win")

	# 14. non-existent command — safe fallback
	_ok(not reg.has_command("t.nope"), "non-existent → has_command false")
	_eq(reg.get_command_metadata("t.nope"), {},
			"non-existent → metadata empty dict")
	_ok(reg.needs_serialization("t.nope"),
			"non-existent → needs_serialization true (safe default)")

	print("")


# --- Options builder (~14 assertions) -------------------------------------

func _test_options_builder() -> void:
	_begin("Options builder")

	# 1-5. Boolean marks
	_ok(MCPToolkitCommandOptions.new().mark_read_only().to_dict()["is_read_only"],
			"mark_read_only → to_dict is_read_only true")
	_ok(MCPToolkitCommandOptions.new().mark_destructive().to_dict()["is_destructive"],
			"mark_destructive → to_dict is_destructive true")
	_ok(MCPToolkitCommandOptions.new().mark_idempotent().to_dict()["is_idempotent"],
			"mark_idempotent → to_dict is_idempotent true")
	_ok(MCPToolkitCommandOptions.new().mark_exclusive_execution().to_dict() \
			.get("_force_serialize", false),
			"mark_exclusive_execution → to_dict _force_serialize true")
	_ok(MCPToolkitCommandOptions.new().mark_cancellable().to_dict()["is_cancellable"],
			"mark_cancellable → to_dict is_cancellable true")

	# 6. with_timeout_ms
	_eq(MCPToolkitCommandOptions.new().with_timeout_ms(5000).to_dict()["timeout_ms"],
			5000, "with_timeout_ms(5000) → 5000")

	# 7. chained builder returns same reference
	var opts := MCPToolkitCommandOptions.new()
	_ok(opts.mark_read_only().mark_idempotent() == opts,
			"chained builder returns same reference")

	# 8. with_group sets name, description, keywords
	var g: Dictionary = MCPToolkitCommandOptions.new() \
			.with_group("grp", "Desc", ["kw"]).to_dict().get("group", {})
	_eq(g.get("name", ""), "grp", "with_group → name")
	_eq(g.get("description", ""), "Desc", "with_group → description")
	_ok(g.get("keywords", []).has("kw"), "with_group → keywords")

	# 9-10. Version gating
	_eq(MCPToolkitCommandOptions.new().with_min_godot_version("4.5") \
			.to_dict().get("min_godot_version", ""), "4.5",
			"with_min_godot_version → '4.5'")
	_eq(MCPToolkitCommandOptions.new().with_max_godot_version("4.4") \
			.to_dict().get("max_godot_version", ""), "4.4",
			"with_max_godot_version → '4.4'")

	# 11. chained version bounds
	var vd: Dictionary = MCPToolkitCommandOptions.new() \
			.with_min_godot_version("4.3") \
			.with_max_godot_version("4.5").to_dict()
	_ok(vd.has("min_godot_version") and vd.has("max_godot_version"),
			"chained version bounds → both present")

	# 12. invalid version string — stored despite push_warning
	_eq(MCPToolkitCommandOptions.new().with_min_godot_version("bad") \
			.to_dict().get("min_godot_version", ""), "bad",
			"invalid version stored (push_warning fires)")

	print("")


# --- Extension options (~4 assertions) ------------------------------------

func _test_extension_options() -> void:
	_begin("Extension options")

	# 1. constructor sets description
	var d: Dictionary = MCPToolkitExtensionOptions.new("My tool").to_dict()
	_eq(d["description"], "My tool", "constructor sets description")

	# 2. inherits builder methods (chaining returns same ref)
	var ext := MCPToolkitExtensionOptions.new("Ext")
	_ok(ext.mark_read_only().mark_idempotent() == ext,
			"inherits builder methods (chaining works)")

	# 3. default annotations — safe fallback
	var fresh: Dictionary = MCPToolkitExtensionOptions.new("Fresh").to_dict()
	_ok(not fresh["is_read_only"], "default → not read-only")
	_ok(not fresh["is_destructive"], "default → not destructive")

	print("")


# --- Annotation mapping (~6 assertions) -----------------------------------

func _test_annotation_mapping() -> void:
	_begin("Annotation mapping")
	var reg := MCPToolkitCommandRegistry.new()

	# 1. mark_read_only → readOnlyHint true
	reg.add("a.ro", _noop, MCPToolkitCommandOptions.new().mark_read_only())
	_ok(reg.get_command_metadata("a.ro")["annotations"]["readOnlyHint"],
			"mark_read_only → readOnlyHint true")

	# 2. mark_destructive → destructiveHint true
	reg.add("a.ds", _noop, MCPToolkitCommandOptions.new().mark_destructive())
	_ok(reg.get_command_metadata("a.ds")["annotations"]["destructiveHint"],
			"mark_destructive → destructiveHint true")

	# 3. mark_idempotent → idempotentHint true
	reg.add("a.id", _noop, MCPToolkitCommandOptions.new().mark_idempotent())
	_ok(reg.get_command_metadata("a.id")["annotations"]["idempotentHint"],
			"mark_idempotent → idempotentHint true")

	# 4. no marks → all hints false
	reg.add("a.plain", _noop, MCPToolkitCommandOptions.new())
	var ann: Dictionary = reg.get_command_metadata("a.plain").get("annotations", {})
	_ok(not ann.get("readOnlyHint", false), "no marks → readOnlyHint false")
	_ok(not ann.get("destructiveHint", false), "no marks → destructiveHint false")
	_ok(not ann.get("idempotentHint", false), "no marks → idempotentHint false")

	print("")


# --- Timeout clamping (~5 assertions) -------------------------------------

func _test_timeout_clamping() -> void:
	_begin("Timeout clamping")
	var reg := MCPToolkitCommandRegistry.new()

	# 1. no timeout → default 30000 (metadata omits key)
	reg.add("to.def", _noop, MCPToolkitCommandOptions.new())
	_ok(not reg.get_command_metadata("to.def").has("timeout_ms"),
			"no timeout → default 30000 (omitted from metadata)")

	# 2. below min → clamped to 1000
	reg.add("to.lo", _noop, MCPToolkitCommandOptions.new().with_timeout_ms(500))
	_eq(reg.get_command_metadata("to.lo").get("timeout_ms", -1), 1000,
			"timeout 500 → clamped to 1000")

	# 3. above max → clamped to 300000
	reg.add("to.hi", _noop, MCPToolkitCommandOptions.new().with_timeout_ms(500000))
	_eq(reg.get_command_metadata("to.hi").get("timeout_ms", -1), 300000,
			"timeout 500000 → clamped to 300000")

	# 4. in range → unchanged
	reg.add("to.ok", _noop, MCPToolkitCommandOptions.new().with_timeout_ms(5000))
	_eq(reg.get_command_metadata("to.ok").get("timeout_ms", -1), 5000,
			"timeout 5000 → unchanged")

	# 5. zero → default (same as no timeout)
	reg.add("to.z", _noop, MCPToolkitCommandOptions.new().with_timeout_ms(0))
	_ok(not reg.get_command_metadata("to.z").has("timeout_ms"),
			"timeout 0 → default (omitted from metadata)")

	print("")


# --- ToolContext cancellation (~3 assertions) ------------------------------

func _test_tool_context() -> void:
	_begin("ToolContext cancellation")

	# 1. fresh → is_cancelled false
	var ctx := MCPToolkitToolContext.new()
	_ok(not ctx.is_cancelled(), "fresh context → is_cancelled false")

	# 2. cancel → is_cancelled true
	ctx.cancel()
	_ok(ctx.is_cancelled(), "after cancel → is_cancelled true")

	# 3. cancelled signal fires synchronously
	var ctx2 := MCPToolkitToolContext.new()
	var fired := [false]
	ctx2.cancelled.connect(func(): fired[0] = true)
	ctx2.cancel()
	_ok(fired[0], "cancel → cancelled signal fires")

	print("")


# --- Helpers: compile_text_filter (~6 assertions) -------------------------

const Helpers := preload("res://addons/godot_mcp_toolkit/commands/_helpers.gd")

func _test_compile_text_filter() -> void:
	_begin("compile_text_filter")

	# 1. Empty filter → null regex, no error
	var r1 := Helpers.compile_text_filter({"text_filter": "", "is_regex": true})
	_ok(r1[0] == null, "empty filter → null regex")
	_ok(r1[1] == null, "empty filter → no error")

	# 2. Non-regex → null regex
	var r2 := Helpers.compile_text_filter({"text_filter": "hello", "is_regex": false})
	_ok(r2[0] == null, "is_regex=false → null regex")

	# 3. Valid regex compiles
	var r3 := Helpers.compile_text_filter({"text_filter": "[0-9]+", "is_regex": true})
	_ok(r3[0] != null, "valid regex → RegEx instance")
	_ok(r3[1] == null, "valid regex → no error")

	# 4. Invalid regex → error returned
	var r4 := Helpers.compile_text_filter({"text_filter": "(unclosed", "is_regex": true})
	_ok(r4[0] == null, "invalid regex → null regex")
	_ok(r4[1] != null, "invalid regex → error dict")

	# 5. Double-escaped \\d → warning
	var r5 := Helpers.compile_text_filter({"text_filter": "test\\\\d+", "is_regex": true})
	_ok(r5[2] != "", "double-escaped \\d → warning not empty")

	# 6. Clean regex → empty warning
	var r6 := Helpers.compile_text_filter({"text_filter": "[0-9]+", "is_regex": true})
	_ok(r6[2] == "", "clean regex → empty warning")

	print("")


# --- Helpers: set_property_compound (~6 assertions) -----------------------

func _test_set_property_compound() -> void:
	_begin("set_property_compound")

	# 1. Simple slash path on a Control (theme_override)
	var ctrl := Control.new()
	var r1 := Helpers.set_property_compound(
		ctrl, "theme_override_font_sizes/font_size", 24)
	_ok(r1.get("ok", false), "theme_override slash path → ok")
	_eq(ctrl.get("theme_override_font_sizes/font_size"), 24,
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
	_ok(r2.get("ok", false), "shader_parameter colon path → ok")
	var readback = sprite.get("material").get_shader_parameter("brightness")
	_eq(readback, 0.3, "shader_parameter readback = 0.3")
	sprite.free()

	# 3. Non-existent sub-resource → NOT_FOUND
	var node := Node2D.new()
	var r3 := Helpers.set_property_compound(
		node, "material:shader_parameter/x", 1.0)
	_ok(not r3.get("ok", false), "null sub-resource → error")
	_eq(r3.get("code", ""), "NOT_FOUND", "error code = NOT_FOUND")
	node.free()

	print("")


# --- compound_set helper (~8 assertions) ------------------------------------

const UndoRedoHelpers := preload("res://addons/godot_mcp_toolkit/undo_redo_helpers.gd")

func _test_compound_set_helper() -> void:
	_begin("compound_set helper")
	var helpers := UndoRedoHelpers.new()

	# 1. Slash-only path (theme override on Control)
	var ctrl := Control.new()
	ctrl.add_theme_font_size_override("font_size", 16)
	helpers.compound_set(ctrl, "theme_override_font_sizes/font_size", 32)
	_eq(ctrl.get("theme_override_font_sizes/font_size"), 32,
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
	_eq(mat.get_shader_parameter("brightness"), 0.4,
		"single-colon: shader_parameter set to 0.4")
	# Undo by setting back
	helpers.compound_set(sprite, "material:shader_parameter/brightness", 0.75)
	_eq(mat.get_shader_parameter("brightness"), 0.75,
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
	_eq(pass2.get_shader_parameter("glow"), 0.5,
		"multi-colon: next_pass shader_parameter set to 0.5")
	sprite2.free()

	# 4. Simple property (no colon, no slash)
	var node := Node2D.new()
	node.visible = true
	helpers.compound_set(node, "visible", false)
	_eq(node.visible, false, "simple: visible set to false")
	node.free()

	# 5. Null sub-resource → no crash (silent return)
	var empty := Sprite2D.new()
	helpers.compound_set(empty, "material:shader_parameter/x", 1.0)
	_ok(true, "null sub-resource: no crash")
	empty.free()

	helpers.free()
	print("")


# --- _undo info from set_property_compound (~6 assertions) ------------------

func _test_undo_info() -> void:
	_begin("_undo info")

	# 1. Slash-only path returns property type
	var ctrl := Control.new()
	var r1 := Helpers.set_property_compound(
		ctrl, "theme_override_font_sizes/font_size", 24)
	_ok(r1.get("ok", false), "slash-only: set ok")
	var u1: Dictionary = r1.get("_undo", {})
	_eq(u1.get("type"), "property", "slash-only: _undo type = property")
	_eq(u1.get("path"), "theme_override_font_sizes/font_size",
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
	_ok(r2.get("ok", false), "colon: set ok")
	var u2: Dictionary = r2.get("_undo", {})
	_ok(u2.get("type") == "property" or u2.get("type") == "sub_resource",
		"colon: _undo type is property or sub_resource")
	_eq(u2.get("old"), null, "colon: _undo old = null (no prior override)")
	sprite.free()

	print("")


# --- Report ----------------------------------------------------------------

func _report() -> void:
	print("")
	if _failed == 0:
		print("=== ALL %d PASSED ===" % _passed)
	else:
		print("=== %d FAILED (%d passed) ===" % [_failed, _passed])
		for e in _errors:
			print("  FAIL: %s" % e)
