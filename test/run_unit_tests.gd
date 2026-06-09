extends SceneTree
## Headless unit test runner for MCP Toolkit pure-logic internals.
##
## Run: timeout 30 godot --headless --script test/run_unit_tests.gd
##
## Exit code: 0 = all passed, 1 = failures detected.
## The final banner is always printed for environments where exit codes
## are unreliable (Windows Godot).

const _SafeSceneOps := preload("res://addons/godot_mcp_toolkit/mcp_toolkit_safe_scene_ops.gd")
const EditorCommands := preload("res://addons/godot_mcp_toolkit/commands/editor_commands.gd")
const UnfocusedBackup := preload("res://addons/godot_mcp_toolkit/unfocused_backup.gd")

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
	_test_watchdog_timeout()
	_test_scene_lease()
	_test_safe_scene_ops()
	_test_tool_context()
	_test_compile_text_filter()
	_test_set_property_compound()
	_test_compound_set_helper()
	_test_undo_info()
	_test_undo_redo_action()
	_test_error_api()
	_test_export_strip()
	_test_editor_refresh_reload_filter()
	_test_unfocused_backup()
	await _test_response_validation()

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


# --- Mutation-watchdog deadline basis (Fix 6, 41l-tricies) -----------------
# get_watchdog_timeout_ms: trust a DECLARED timeout; for an undeclared command
# (the 30s default, not a deliberate duration) use _MAX_TIMEOUT_MS so an
# undeclared-but-slow method is never force-cleared early.

func _test_watchdog_timeout() -> void:
	_begin("Watchdog timeout basis")
	var reg := MCPToolkitCommandRegistry.new()

	# 1. declared timeout → trusted (the author's contract)
	reg.add("wd.declared", _noop, MCPToolkitCommandOptions.new().with_timeout_ms(5000))
	_eq(reg.get_watchdog_timeout_ms("wd.declared"), 5000,
			"declared timeout → trusted (5000)")

	# 2. undeclared (default) → _MAX_TIMEOUT_MS (300000), NOT the 30s default
	reg.add("wd.default", _noop, MCPToolkitCommandOptions.new())
	_eq(reg.get_watchdog_timeout_ms("wd.default"), 300000,
			"undeclared → _MAX_TIMEOUT_MS, not the 30s default")

	# 3. timeout 0 → treated as undeclared → _MAX_TIMEOUT_MS
	reg.add("wd.zero", _noop, MCPToolkitCommandOptions.new().with_timeout_ms(0))
	_eq(reg.get_watchdog_timeout_ms("wd.zero"), 300000,
			"timeout 0 → undeclared → _MAX_TIMEOUT_MS")

	# 4. explicitly declared 30000 is still 'declared' → trusted, NOT forced to _MAX
	reg.add("wd.d30k", _noop, MCPToolkitCommandOptions.new().with_timeout_ms(30000))
	_eq(reg.get_watchdog_timeout_ms("wd.d30k"), 30000,
			"explicitly declared 30000 → trusted (not _MAX)")

	# 5. unknown method → _MAX_TIMEOUT_MS (safe ceiling)
	_eq(reg.get_watchdog_timeout_ms("wd.unknown"), 300000,
			"unknown method → _MAX_TIMEOUT_MS")

	print("")


# --- Scene-lease bookkeeping (Fix 4, 41l-tricies) --------------------------
# After Fix 4, _try_acquire_lease is pure bookkeeping (the raw
# open_scene_from_path was removed), so it is headless-unit-testable. Instantiate
# mcp_server WITHOUT adding it to the tree, so _ready never fires (no TCP server).

func _test_scene_lease() -> void:
	_begin("Scene lease bookkeeping")
	var Server = preload("res://addons/godot_mcp_toolkit/mcp_server.gd")
	var srv = Server.new()
	var peer_a := WebSocketPeer.new()
	var peer_b := WebSocketPeer.new()

	# 1. free lease → A acquires (empty scene skips the file-exists check)
	_ok(srv._try_acquire_lease(peer_a, ""), "free lease → A acquires")
	_ok(srv._lease_holder == peer_a, "lease holder is A")

	# 2. same peer → renews
	_ok(srv._try_acquire_lease(peer_a, ""), "same peer → renews (true)")
	_ok(srv._lease_holder == peer_a, "A still holds after renew")

	# 3. different peer → contended (false); A keeps it
	_ok(not srv._try_acquire_lease(peer_b, ""), "other peer → contended (false)")
	_ok(srv._lease_holder == peer_a, "A still holds under contention")

	# 4. release → no holder
	srv._release_lease()
	_ok(srv._lease_holder == null, "release → no holder")

	# 5. after release → B acquires
	_ok(srv._try_acquire_lease(peer_b, ""), "after release → B acquires")
	_ok(srv._lease_holder == peer_b, "lease holder is B")

	srv.free()
	print("")


# --- MCPToolkitSafeSceneOps public API (Fix 1, 41l-tricies) ----------------
# is_dispatching() is the pure, headless-testable surface. wait_for_scan_idle /
# save_scene / queue_save touch EditorInterface (null in this --script runner),
# so they are covered by the smoke suite + the editor-required dispatch
# integration / A-B validation that exercise editor_save_scene end to end.

func _test_safe_scene_ops() -> void:
	_begin("MCPToolkitSafeSceneOps (public API)")
	_ok(not _SafeSceneOps.is_dispatching(), "is_dispatching → false by default")
	_SafeSceneOps._in_dispatch = true
	_ok(_SafeSceneOps.is_dispatching(), "is_dispatching → true when _in_dispatch set")
	_SafeSceneOps._in_dispatch = false
	_ok(not _SafeSceneOps.is_dispatching(), "is_dispatching → false after reset")

	# C# reaches the safe-save API through the registry facade (like
	# create_undo_action), so verify the registry bridge forwards to SafeSceneOps.
	# (queue_save fires the editor-coupled save → integration-tested; check_save
	# is pure dict logic → testable here.)
	var _reg := MCPToolkitCommandRegistry.new()
	_ok(_reg.check_save("nope").get("unknown", false),
			"registry.check_save bridge → forwards to SafeSceneOps")

	# check_save — pure dict logic; seed _save_results directly to bypass the
	# editor-coupled save in queue_save/_run_queued_save.
	_SafeSceneOps._save_results = {}
	_ok(_SafeSceneOps.check_save("nope").get("unknown", false),
			"check_save(unknown id) → unknown:true")
	_SafeSceneOps._save_results["s1"] = {"done": false}
	_ok(not _SafeSceneOps.check_save("s1").get("done", true),
			"pending save → done:false")
	_SafeSceneOps._save_results["s1"] = {"done": true, "success": true}
	_ok(_SafeSceneOps.check_save("s1").get("success", false),
			"completed save → success:true")
	_SafeSceneOps.check_save("s1", true)  # clear a done save
	_ok(_SafeSceneOps.check_save("s1").get("unknown", false),
			"check_save(clear) on done → record removed")
	_SafeSceneOps._save_results["s2"] = {"done": false}
	_SafeSceneOps.check_save("s2", true)  # clear a pending save → no-op
	_ok(_SafeSceneOps._save_results.has("s2"),
			"check_save(clear) on pending → kept")
	_SafeSceneOps._save_results = {}  # reset the shared static
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

const Helpers := preload("res://addons/godot_mcp_toolkit/commands/editor_helpers.gd")

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


# --- MCPToolkitUndoRedoAction (headless-safe subset) -----------------------

func _test_undo_redo_action() -> void:
	_begin("MCPToolkitUndoRedoAction")

	# 1. begin() returns non-null instance
	var action := MCPToolkitUndoRedoAction.begin("test action")
	_ok(action != null, "begin() returns non-null instance")

	# 2. is_active() returns false in headless (no plugin loaded)
	_ok(not action.is_active(), "is_active() false in headless")

	# 3. Fluent chaining — every method returns self
	var a2 := MCPToolkitUndoRedoAction.begin("chain test")
	var node := Node2D.new()
	var r1 = a2.do_property(node, &"position", Vector2(1, 2))
	_ok(r1 == a2, "do_property returns self")
	var r2 = a2.undo_property(node, &"position", Vector2.ZERO)
	_ok(r2 == a2, "undo_property returns self")
	var r3 = a2.do_method(node.set.bind(&"rotation", 1.0))
	_ok(r3 == a2, "do_method returns self")
	var r4 = a2.undo_method(node.set.bind(&"rotation", 0.0))
	_ok(r4 == a2, "undo_method returns self")
	var r5 = a2.do_reference(node)
	_ok(r5 == a2, "do_reference returns self")
	var r6 = a2.undo_reference(node)
	_ok(r6 == a2, "undo_reference returns self")
	node.free()

	# 4. All methods no-op without crash when inactive
	var inactive := MCPToolkitUndoRedoAction.begin("noop test")
	inactive.do_property(Node.new(), &"name", "test")  # won't crash
	inactive.undo_property(Node.new(), &"name", "old")
	inactive.do_method(Callable())
	inactive.undo_method(Callable())
	inactive.commit_recorded()
	_ok(true, "all methods no-op without crash when inactive")

	# 5. Double-commit guard — second call is no-op (warning logged)
	var a3 := MCPToolkitUndoRedoAction.begin("double commit")
	a3.commit_recorded()
	a3.commit_recorded()  # should push_warning, not crash
	_ok(true, "double commit_recorded() does not crash")

	# 6. commit() also guarded
	var a4 := MCPToolkitUndoRedoAction.begin("commit guard")
	a4.commit()
	a4.commit()  # should push_warning, not crash
	_ok(true, "double commit() does not crash")

	# 7. Cross-commit guard (commit after commit_recorded)
	var a5 := MCPToolkitUndoRedoAction.begin("cross commit")
	a5.commit_recorded()
	a5.commit()  # should push_warning, not crash
	_ok(true, "commit() after commit_recorded() does not crash")

	# 8. Registry factory returns valid instance
	var reg := MCPToolkitCommandRegistry.new()
	var factory_action := reg.create_undo_action("factory test")
	_ok(factory_action != null, "create_undo_action() returns non-null")
	_ok(not factory_action.is_active(), "factory action inactive in headless")

	print("")


# --- MCPToolkitError API (~5 assertions) ------------------------------------

func _test_error_api() -> void:
	_begin("MCPToolkitError API")

	# 1. fail() returns correct shape
	var e1 := MCPToolkitError.fail("NOT_FOUND", "Node missing")
	_ok(e1["success"] == false, "fail() → success false")
	_eq(e1["error"], "Node missing", "fail() → error message")
	_eq(e1["code"], "NOT_FOUND", "fail() → code")

	# 2. fail() with DEFAULT_HINTS code → auto-hint attached
	var e2 := MCPToolkitError.fail("TIMEOUT", "Editor busy")
	_ok(e2.has("hint"), "fail(TIMEOUT) → auto-hint attached")
	_eq(e2["hint"], MCPToolkitError.DEFAULT_HINTS["TIMEOUT"],
			"fail(TIMEOUT) → hint matches DEFAULT_HINTS")

	# 3. fail() with explicit hint → overrides auto-hint
	var e3 := MCPToolkitError.fail("TIMEOUT", "Custom", "My hint")
	_eq(e3["hint"], "My hint", "fail() explicit hint → overrides auto-hint")

	# 4. fail() with non-DEFAULT_HINTS code and no hint → no hint key
	var e4 := MCPToolkitError.fail("NOT_FOUND", "Missing")
	_ok(not e4.has("hint"), "fail(NOT_FOUND, no hint) → no hint key")

	# 5. require() with all params present → returns null
	var ok_params := {"node_path": "/root/Player", "file_path": "res://s.gd"}
	_eq(MCPToolkitError.require(ok_params, ["node_path", "file_path"]), null,
			"require() all present → null")

	# 6. require() with missing param → returns error with hint
	var bad_params := {"node_path": ""}
	var e5 = MCPToolkitError.require(bad_params, ["node_path"])
	_ok(e5 is Dictionary, "require() missing → returns Dictionary")
	_eq(e5["code"], "INVALID_PARAMS", "require() missing → INVALID_PARAMS")
	_eq(e5["hint"], MCPToolkitError.HINT_NODE_PATH,
			"require(node_path) → HINT_NODE_PATH")

	# 7. require() with missing file_path → HINT_FILE_PATH
	var bad_params2 := {"file_path": ""}
	var e6 = MCPToolkitError.require(bad_params2, ["file_path"])
	_eq(e6["hint"], MCPToolkitError.HINT_FILE_PATH,
			"require(file_path) → HINT_FILE_PATH")

	print("")


# --- Response validation (~6 assertions) ------------------------------------

func _bad_handler_non_dict(_p: Dictionary) -> String:
	return "not a dictionary"

func _bad_handler_no_success(_p: Dictionary) -> Dictionary:
	return {"data": "missing success"}

func _good_handler(_p: Dictionary) -> Dictionary:
	return {"success": true, "data": "ok"}

func _handler_with_hint(_p: Dictionary) -> Dictionary:
	return {"success": true, "hint": "handler hint"}

func _handler_fail(_p: Dictionary) -> Dictionary:
	return {"success": false, "error": "nope", "code": "TEST"}

func _test_response_validation() -> void:
	_begin("Response validation")
	var reg := MCPToolkitCommandRegistry.new()

	# 1. Handler returns non-Dictionary → INTERNAL error
	reg.add("rv.bad_type", _bad_handler_non_dict,
			MCPToolkitCommandOptions.new())
	var r1: Dictionary = await reg.call_command("rv.bad_type", {})
	_eq(r1["success"], false, "non-Dict handler → success false")
	_eq(r1["code"], "INTERNAL", "non-Dict handler → INTERNAL code")

	# 2. Handler returns Dict without success → INTERNAL error
	reg.add("rv.no_success", _bad_handler_no_success,
			MCPToolkitCommandOptions.new())
	var r2: Dictionary = await reg.call_command("rv.no_success", {})
	_eq(r2["success"], false, "no-success handler → success false")
	_eq(r2["code"], "INTERNAL", "no-success handler → INTERNAL code")

	# 3. Good handler → passes through
	reg.add("rv.good", _good_handler, MCPToolkitCommandOptions.new())
	var r3: Dictionary = await reg.call_command("rv.good", {})
	_eq(r3["success"], true, "good handler → success true")
	_eq(r3["data"], "ok", "good handler → data preserved")

	# 4. with_success_hint() auto-injection on success
	reg.add("rv.hinted", _good_handler,
			MCPToolkitCommandOptions.new().with_success_hint("Next step"))
	var r4: Dictionary = await reg.call_command("rv.hinted", {})
	_eq(r4["hint"], "Next step", "with_success_hint → auto-injected")

	# 5. Handler hint overrides registered hint
	reg.add("rv.override", _handler_with_hint,
			MCPToolkitCommandOptions.new().with_success_hint("Registered"))
	var r5: Dictionary = await reg.call_command("rv.override", {})
	_eq(r5["hint"], "handler hint", "handler hint → overrides registered")

	# 6. No injection on success: false
	reg.add("rv.fail", _handler_fail,
			MCPToolkitCommandOptions.new().with_success_hint("Should not appear"))
	var r6: Dictionary = await reg.call_command("rv.fail", {})
	_ok(not r6.has("hint") or r6.get("hint", "") != "Should not appear",
			"success:false → no success_hint injection")

	print("")


# --- Export strip + binary-token warning set (~7 strip + 22 warning) --------

const ExportStrip := preload("res://addons/godot_mcp_toolkit/export_strip.gd")

func _test_export_strip() -> void:
	_begin("Export strip set")

	# Strip is single-level: only DIRECT subclasses of MCPToolkitExtension
	# (base == "MCPToolkitExtension") are stripped, mirroring the loader's
	# definition of an extension. Path-extends to a direct subclass is flattened
	# by the engine to the same base, so it is covered too.
	var classes := [
		{"class": "MCPToolkitExtension", "base": "RefCounted", "path": "res://addons/godot_mcp_toolkit/mcp_toolkit_extension.gd"},
		{"class": "DirectExt", "base": "MCPToolkitExtension", "path": "res://a/direct.gd"},
		{"class": "PathDirectExt", "base": "MCPToolkitExtension", "path": "res://e/path_direct.gd"},
		{"class": "ChildExt", "base": "ParentExt", "path": "res://b/child.gd"},
		{"class": "GameThing", "base": "Node", "path": "res://g/game.gd"},
		{"class": "WeirdCs", "base": "MCPToolkitExtension", "path": "res://c/weird.cs"},
		{"class": "FakeChild", "base": "MCPToolkitFake", "path": "res://f/fakechild.gd"},
	]
	var strip: Dictionary = ExportStrip._compute_strip_paths(classes)

	# Direct subclasses (identifier form + path-extends flattened to the same base).
	_ok(strip.has("res://a/direct.gd"), "direct subclass → stripped")
	_ok(strip.has("res://e/path_direct.gd"), "path-flattened direct subclass → stripped")

	# Multi-level (base is an intermediate, not MCPToolkitExtension) → NOT stripped
	# (single-level by design; such files ship as harmless orphans).
	_ok(not strip.has("res://b/child.gd"), "multi-level child → NOT stripped (single-level)")

	# Unrelated game class → not stripped.
	_ok(not strip.has("res://g/game.gd"), "unrelated game class → not stripped")

	# .cs excluded by the .gd guard even if its base matched (C# can't be stripped).
	_ok(not strip.has("res://c/weird.cs"), ".cs excluded by .gd guard")

	# Base class itself (base RefCounted) → not matched; prefix-stripped at runtime.
	_ok(not strip.has("res://addons/godot_mcp_toolkit/mcp_toolkit_extension.gd"),
			"base class itself → not matched (prefix-stripped at runtime)")

	# Exact base match → no false positive from a coincidentally MCPToolkit*-named
	# class (FakeChild's base is "MCPToolkitFake", not "MCPToolkitExtension").
	_ok(not strip.has("res://f/fakechild.gd"),
			"subclass of coincidentally-named MCPToolkit* class → not stripped")

	# ── Binary-token leak warning (Q6) — pure _decide_warning decision ──────
	# args: (saw_addon_script, saw_addon_nonscript, extension_strip_paths, seen_ext)

	# No leak: text mode / 4.2 → addon scripts AND non-scripts reached us; no exts.
	var d_clean: Dictionary = ExportStrip._decide_warning(true, true, {}, {})
	_ok(not d_clean["warn"], "all addon files seen (text mode) → no warning")

	# Addon-only leak (binary mode, no extensions): non-scripts seen, scripts gone.
	var d_addon: Dictionary = ExportStrip._decide_warning(false, true, {}, {})
	_ok(d_addon["warn"], "addon non-script seen but no script → warn")
	_ok(d_addon["addon_leaked"], "addon-only leak → addon_leaked true")
	_ok(int(d_addon["leaked_ext_count"]) == 0, "addon-only leak → 0 extensions")
	_ok(str(d_addon["message"]).find("Godot MCP Toolkit addon") >= 0, "addon message names the addon")
	# Tail always says "extension path"; the subject clause "N extension script(s)" must be absent.
	_ok(str(d_addon["message"]).find("extension script") < 0, "addon-only message omits extension clause")

	# Both leak (binary mode, 1 extension): addon + one unseen extension path.
	var d_both: Dictionary = ExportStrip._decide_warning(false, true, {"res://x/ext.gd": true}, {})
	_ok(d_both["warn"], "addon + unseen extension → warn")
	_ok(int(d_both["leaked_ext_count"]) == 1, "1 unseen extension counted")
	_ok(str(d_both["message"]).find("addon and 1 extension script(s)") >= 0, "message joins addon + 1 extension")
	# REGRESSION: the recipe must list the addon glob AND the explicit extension path.
	_ok(str(d_both["message"]).find("res://addons/godot_mcp_toolkit/*") >= 0, "message includes the addon exclude glob")
	_ok(str(d_both["message"]).find("res://x/ext.gd") >= 0, "message lists the leaked extension path explicitly")

	# Two leaked extensions → BOTH paths listed (comma-join regression guard).
	var d_two: Dictionary = ExportStrip._decide_warning(false, true, {"res://x/a.gd": true, "res://y/b.gd": true}, {})
	_ok(int(d_two["leaked_ext_count"]) == 2, "2 unseen extensions counted")
	_ok(d_two["leaked_ext_paths"].size() == 2, "leaked_ext_paths populated")
	_ok(str(d_two["message"]).find("2 extension script(s)") >= 0, "subject reports 2 extensions")
	_ok(str(d_two["message"]).find("res://x/a.gd") >= 0 and str(d_two["message"]).find("res://y/b.gd") >= 0, "both extension paths listed")

	# Q6 guard: addon already excluded by the user → NO addon file reaches us.
	var d_excluded: Dictionary = ExportStrip._decide_warning(false, false, {}, {})
	_ok(not d_excluded["warn"], "addon excluded (no non-script seen) → no false-positive warning")

	# Extension-only leak: addon excluded but an extension still shipped as .gdc.
	var d_ext: Dictionary = ExportStrip._decide_warning(false, false, {"res://x/ext.gd": true}, {})
	_ok(d_ext["warn"], "unseen extension alone → warn")
	_ok(not d_ext["addon_leaked"], "extension-only leak → addon_leaked false")
	_ok(str(d_ext["message"]).find("1 extension script(s)") >= 0, "extension-only message names the extension")
	_ok(str(d_ext["message"]).find("res://x/ext.gd") >= 0, "extension-only message lists the path explicitly")
	# Addon not leaked → neither the addon subject phrase nor the addon glob appears.
	_ok(str(d_ext["message"]).find("Godot MCP Toolkit addon") < 0, "extension-only message omits addon clause")
	_ok(str(d_ext["message"]).find("res://addons/godot_mcp_toolkit/*") < 0, "extension-only message omits addon glob")

	# Extension seen (text mode for the extension) → not counted as leaked.
	var d_ext_seen: Dictionary = ExportStrip._decide_warning(true, true, {"res://x/ext.gd": true}, {"res://x/ext.gd": true})
	_ok(not d_ext_seen["warn"], "extension seen (stripped) → no warning")

	print("")


# --- editor.refresh reload filter (Fix, 41l-tricies) -----------------------
# should_reload_open_script: reload only scan-changed, non-toolkit open scripts.
# Pins the fix against a regression back to "reload all open scripts" (which
# cancels suspended coroutines → the C1/C3 crash class).

func _test_editor_refresh_reload_filter() -> void:
	_begin("editor.refresh reload filter")
	var changed := {
		"res://game/player.gd": true,
		"res://addons/godot_mcp_toolkit/commands/scene_commands.gd": true,
	}
	# 1. changed user script → reload
	_ok(EditorCommands.should_reload_open_script("res://game/player.gd", changed),
			"changed user script → reload")
	# 2. unchanged user script → skip
	_ok(not EditorCommands.should_reload_open_script("res://game/enemy.gd", changed),
			"unchanged user script → skip")
	# 3. toolkit's own script, even if scan-changed → skip (never self-reload)
	_ok(not EditorCommands.should_reload_open_script(
			"res://addons/godot_mcp_toolkit/commands/scene_commands.gd", changed),
			"toolkit-own changed script → skip (never self-reload)")
	# 4. unchanged toolkit script → skip
	_ok(not EditorCommands.should_reload_open_script(
			"res://addons/godot_mcp_toolkit/mcp_server.gd", changed),
			"unchanged toolkit script → skip")
	print("")


# --- Unfocused-sleep backup (41l-duotricies) -------------------------------
# Machine-wide crash-safe restore of the global unfocused frame-rate setting.
# The editor-coupled get/set EditorSettings calls live in mcp_server.gd (covered
# by interactive verification); the conflict-resolution + first-writer-wins +
# both-values-stored logic is pure and headless-testable here against a temp dir.

func _test_unfocused_backup() -> void:
	_begin("Unfocused-sleep backup")
	var dir := ProjectSettings.globalize_path("user://_mcp_unfocused_backup_test")
	DirAccess.make_dir_recursive_absolute(dir)
	var ver := "9.9"  # fixed test key + temp dir → isolated from any real backup
	UnfocusedBackup.delete_backup(dir, ver)  # clean slate

	# should_capture_boost — opt-out + idempotency gate (the "no-op when off" unit).
	_ok(UnfocusedBackup.should_capture_boost(true, false),
			"should_capture_boost(on, idle) → true")
	_ok(not UnfocusedBackup.should_capture_boost(false, false),
			"should_capture_boost(off, idle) → false (no-op when off)")
	_ok(not UnfocusedBackup.should_capture_boost(true, true),
			"should_capture_boost(on, already active) → false (idempotent)")

	# 1. capture_if_absent writes when no backup exists (first-writer-wins).
	_ok(UnfocusedBackup.capture_if_absent(dir, 100000, 16666, ver),
			"first capture → writes backup (true)")
	_ok(UnfocusedBackup.has_backup(dir, ver), "backup file exists after capture")

	# 2. backup stores BOTH original and boosted.
	var b: Dictionary = UnfocusedBackup.read_backup(dir, ver)
	_eq(b.get("original", -1), 100000, "backup stores original")
	_eq(b.get("boosted", -1), 16666, "backup stores boosted")

	# 3. second capture does NOT overwrite (first-writer-wins).
	_ok(not UnfocusedBackup.capture_if_absent(dir, 33333, 8333, ver),
			"second capture → does not overwrite (false)")
	var b2: Dictionary = UnfocusedBackup.read_backup(dir, ver)
	_eq(b2.get("original", -1), 100000, "original preserved after second capture")
	_eq(b2.get("boosted", -1), 16666, "boosted preserved after second capture")

	# 4. resolve_restore: current == boosted → restore the true original (self-heal A).
	var d1: Dictionary = UnfocusedBackup.resolve_restore(16666, b2)
	_ok(d1["restore"], "current == boosted → restore true")
	_eq(d1["value"], 100000, "current == boosted → value is the original")

	# 5. resolve_restore: current != boosted → keep current, conflict-aware (self-heal B).
	var d2: Dictionary = UnfocusedBackup.resolve_restore(50000, b2)
	_ok(not d2["restore"], "current != boosted → restore false (kept)")
	_eq(d2["value"], 50000, "current != boosted → value echoes current")

	# 6. resolve_restore: empty / malformed backup → no-op.
	_ok(not UnfocusedBackup.resolve_restore(16666, {})["restore"],
			"empty backup → restore false")
	_ok(not UnfocusedBackup.resolve_restore(16666, {"original": 100000})["restore"],
			"backup missing 'boosted' → restore false")

	# 7. delete_backup removes the file; read on missing → empty dict.
	UnfocusedBackup.delete_backup(dir, ver)
	_ok(not UnfocusedBackup.has_backup(dir, ver), "delete_backup → file gone")
	_eq(UnfocusedBackup.read_backup(dir, ver), {}, "read missing backup → empty dict")

	# 8. version_key derives "<major>.<minor>" (override form).
	_eq(UnfocusedBackup.version_key({"major": 4, "minor": 2}), "4.2",
			"version_key({4,2}) → '4.2'")

	DirAccess.remove_absolute(dir)  # cleanup
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
