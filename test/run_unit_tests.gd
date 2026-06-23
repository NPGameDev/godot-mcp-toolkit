extends SceneTree
## Headless unit test runner for MCP Toolkit pure-logic internals.
##
## Run: timeout 30 godot --headless --script test/run_unit_tests.gd
##
## Exit code: 0 = all passed, 1 = failures detected.
## The final banner is always printed for environments where exit codes
## are unreliable (Windows Godot).

const RegistryClient := preload("res://addons/godot_mcp_toolkit/registry/registry_client.gd")
const SettingsRegistration := preload("res://addons/godot_mcp_toolkit/core/settings_registration.gd")
const LogHelpers := preload("res://addons/godot_mcp_toolkit/logging/log_helpers.gd")
const ScriptCommands := preload("res://addons/godot_mcp_toolkit/commands/script_commands.gd")
const FileGuard := preload("res://addons/godot_mcp_toolkit/security/file_guard.gd")
const Untrusted := preload("res://addons/godot_mcp_toolkit/security/untrusted.gd")
const ExtensionCatalog := preload("res://addons/godot_mcp_toolkit/ui/dock/ext/extension_catalog.gd")
const OnboardingWizard := preload("res://addons/godot_mcp_toolkit/ui/onboarding_wizard.gd")
const ExtensionSupport := preload("res://addons/godot_mcp_toolkit/extensions/services/extension_support.gd")
const ExtensionMetaCommands := preload("res://addons/godot_mcp_toolkit/extensions/services/extension_meta_commands.gd")
const ExtensionWatcher := preload("res://addons/godot_mcp_toolkit/extensions/services/extension_watcher.gd")
const SpatialCommands := preload("res://addons/godot_mcp_toolkit/commands/spatial_commands.gd")
const TextureCommands := preload("res://addons/godot_mcp_toolkit/commands/texture_commands.gd")
const ParticleCommands := preload("res://addons/godot_mcp_toolkit/commands/particle_commands.gd")
const SoundCommands := preload("res://addons/godot_mcp_toolkit/commands/sound_commands.gd")
const TilesetTileData := preload("res://addons/godot_mcp_toolkit/commands/tileset/tileset_tile_data.gd")
const TilesetIo := preload("res://addons/godot_mcp_toolkit/commands/tileset/tileset_io.gd")
const ThemeCommands := preload("res://addons/godot_mcp_toolkit/commands/theme_commands.gd")
const Coerce := preload("res://addons/godot_mcp_toolkit/contract/coerce.gd")
const ProjectKey := preload("res://addons/godot_mcp_toolkit/paths/project_key.gd")
const ProjectPaths := preload("res://addons/godot_mcp_toolkit/paths/project_paths.gd")
const RegistryPaths := preload("res://addons/godot_mcp_toolkit/registry/store/registry_paths.gd")
const RegistryEntryFile := preload("res://addons/godot_mcp_toolkit/registry/store/registry_entry_file.gd")
const RegistryProjection := preload("res://addons/godot_mcp_toolkit/registry/store/registry_projection.gd")
const Harness := preload("res://test/units/_harness.gd")
const SecurityTests := preload("res://test/units/security_tests.gd")
const RegistryCommandTests := preload("res://test/units/registry_command_tests.gd")
const RegistryStoreTests := preload("res://test/units/registry_store_tests.gd")
const ExtensionMetaTests := preload("res://test/units/extension_meta_tests.gd")
const OptionsTests := preload("res://test/units/options_tests.gd")
const DispatchLaneTests := preload("res://test/units/dispatch_lane_tests.gd")
const SignalResolverTests := preload("res://test/units/signal_resolver_tests.gd")
const SceneOpsTests := preload("res://test/units/scene_ops_tests.gd")
const PropertyEditTests := preload("res://test/units/property_edit_tests.gd")
const UndoRedoTests := preload("res://test/units/undo_redo_tests.gd")
const ErrorContractTests := preload("res://test/units/error_contract_tests.gd")
const PathsVersioningTests := preload("res://test/units/paths_versioning_tests.gd")

var _h := Harness.new()


func _init() -> void:
	print("=== MCP Toolkit Unit Tests ===")
	print("")

	if not _guard_addon_classes():
		quit(1)
		return

	SecurityTests.run(_h)
	RegistryCommandTests.run(_h)
	RegistryStoreTests.run(_h)
	await ExtensionMetaTests.run(_h)
	OptionsTests.run(_h)
	DispatchLaneTests.run(_h)
	SignalResolverTests.run(_h)
	SceneOpsTests.run(_h)
	PropertyEditTests.run(_h)
	_test_log_level_continuation()
	UndoRedoTests.run(_h)
	await ErrorContractTests.run(_h)
	PathsVersioningTests.run(_h)
	_test_export_strip()
	_test_spatial_map()
	_test_texture_generate()
	_test_particle_prop_apply()
	_test_particle_merge_overrides()
	_test_sound_generate()
	_test_create_collision_resolver()
	_test_tileset_edit_key_enforcement()
	_test_tileset_io_polygon()
	_test_coerce_roundtrip()
	_test_color_from_dict()
	_test_color_from_dict_opaque()
	_test_node_packed_property_serialize()
	_test_save_read_paging()
	_test_script_read_paging()
	_test_settings_collect_names()

	var failed := _h.report()
	quit(0 if failed == 0 else 1)


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


# --- Log level + continuation leveling (~14 assertions) -------------------
# A2/A3 (41m-ter): editor parse errors on Godot 4.2-4.4 log as TWO lines —
# "SCRIPT ERROR: …" then "   at: <script>.gd:LINE" — and the script path is on the
# continuation line. LogHelpers.is_continuation_line lets the file-tail buffer
# (log_buffer.gd) and the source=file reader (editor_commands.gd) keep such a line at
# the preceding error/warning level instead of "info", so a filename+level=error query
# finds it. _level_sequence mirrors that loop using the shared primitives under test.

func _level_sequence(lines: Array) -> Array:
	var out: Array = []
	var prev := "info"
	for line in lines:
		var stripped: String = str(line).strip_edges()
		if stripped.is_empty():
			continue
		var lvl: String
		if LogHelpers.is_continuation_line(line) and (prev == "error" or prev == "warning"):
			lvl = prev
		else:
			lvl = LogHelpers.detect_log_level(stripped)
		out.append(lvl)
		prev = lvl
	return out


func _test_log_level_continuation() -> void:
	_h.begin("Log level + continuation leveling")

	# detect_log_level prefixes (SHADER ERROR: is the new one)
	_h.eq(LogHelpers.detect_log_level("ERROR: boom"), "error", "ERROR: → error")
	_h.eq(LogHelpers.detect_log_level("SCRIPT ERROR: Parse Error: x"), "error", "SCRIPT ERROR: → error")
	_h.eq(LogHelpers.detect_log_level("SHADER ERROR: bad shader"), "error", "SHADER ERROR: → error (added)")
	_h.eq(LogHelpers.detect_log_level("WARNING: meh"), "warning", "WARNING: → warning")
	_h.eq(LogHelpers.detect_log_level("just a message"), "info", "plain → info")
	_h.eq(LogHelpers.detect_log_level("at: GDScript::reload (res://x.gd:1)"), "info",
		"stripped at: line alone → info (no prefix)")

	# is_continuation_line — pass RAW (un-edge-stripped) lines so indentation is visible
	_h.ok(LogHelpers.is_continuation_line("   at: GDScript::reload (res://x.gd:1)"),
		"indented 'at:' → continuation")
	_h.ok(LogHelpers.is_continuation_line("at: foo (bar:2)"), "bare 'at:' → continuation")
	_h.ok(LogHelpers.is_continuation_line("\ttab indented"), "tab-indented → continuation")
	_h.ok(not LogHelpers.is_continuation_line("SCRIPT ERROR: x"), "error line → not continuation")
	_h.ok(not LogHelpers.is_continuation_line("plain message"), "plain line → not continuation")

	# Sequence: the exact Godot 4.2 parse-error shape → both lines error-leveled.
	var parse_err := [
		'SCRIPT ERROR: Parse Error: Could not find base class "BogusHitClass".',
		'   at: GDScript::reload (res://smoke_txtflt_hit.gd:1)',
	]
	_h.eq(_level_sequence(parse_err), ["error", "error"],
		"4.2 parse error: SCRIPT ERROR: + at: both → error")
	_h.eq(_level_sequence(["WARNING: w", "   at: foo (x:1)"]), ["warning", "warning"],
		"warning + at: both → warning")
	_h.eq(_level_sequence(["a plain info line", "   at: stray (x:1)"]), ["info", "info"],
		"info + at: → info (no spurious error inherit)")


const Helpers := preload("res://addons/godot_mcp_toolkit/commands/editor_helpers.gd")


# --- Export strip + binary-token warning set (~7 strip + 22 warning) --------

const ExportStrip := preload("res://addons/godot_mcp_toolkit/core/export_strip.gd")

func _test_export_strip() -> void:
	_h.begin("Export strip set")

	# Strip is single-level: only DIRECT subclasses of MCPToolkitExtension
	# (base == "MCPToolkitExtension") are stripped, mirroring the loader's
	# definition of an extension. Path-extends to a direct subclass is flattened
	# by the engine to the same base, so it is covered too.
	var classes := [
		{"class": "MCPToolkitExtension", "base": "RefCounted", "path": "res://addons/godot_mcp_toolkit/extensions/mcp_toolkit_extension.gd"},
		{"class": "DirectExt", "base": "MCPToolkitExtension", "path": "res://a/direct.gd"},
		{"class": "PathDirectExt", "base": "MCPToolkitExtension", "path": "res://e/path_direct.gd"},
		{"class": "ChildExt", "base": "ParentExt", "path": "res://b/child.gd"},
		{"class": "GameThing", "base": "Node", "path": "res://g/game.gd"},
		{"class": "WeirdCs", "base": "MCPToolkitExtension", "path": "res://c/weird.cs"},
		{"class": "FakeChild", "base": "MCPToolkitFake", "path": "res://f/fakechild.gd"},
	]
	var strip: Dictionary = ExportStrip._compute_strip_paths(classes)

	# Direct subclasses (identifier form + path-extends flattened to the same base).
	_h.ok(strip.has("res://a/direct.gd"), "direct subclass → stripped")
	_h.ok(strip.has("res://e/path_direct.gd"), "path-flattened direct subclass → stripped")

	# Multi-level (base is an intermediate, not MCPToolkitExtension) → NOT stripped
	# (single-level by design; such files ship as harmless orphans).
	_h.ok(not strip.has("res://b/child.gd"), "multi-level child → NOT stripped (single-level)")

	# Unrelated game class → not stripped.
	_h.ok(not strip.has("res://g/game.gd"), "unrelated game class → not stripped")

	# .cs excluded by the .gd guard even if its base matched (C# can't be stripped).
	_h.ok(not strip.has("res://c/weird.cs"), ".cs excluded by .gd guard")

	# Base class itself (base RefCounted) → not matched; prefix-stripped at runtime.
	_h.ok(not strip.has("res://addons/godot_mcp_toolkit/extensions/mcp_toolkit_extension.gd"),
			"base class itself → not matched (prefix-stripped at runtime)")

	# Exact base match → no false positive from a coincidentally MCPToolkit*-named
	# class (FakeChild's base is "MCPToolkitFake", not "MCPToolkitExtension").
	_h.ok(not strip.has("res://f/fakechild.gd"),
			"subclass of coincidentally-named MCPToolkit* class → not stripped")

	# ── Binary-token leak warning (Q6) — pure _decide_warning decision ──────
	# args: (saw_addon_script, saw_addon_nonscript, extension_strip_paths, seen_ext)

	# No leak: text mode / 4.2 → addon scripts AND non-scripts reached us; no exts.
	var d_clean: Dictionary = ExportStrip._decide_warning(true, true, {}, {})
	_h.ok(not d_clean["warn"], "all addon files seen (text mode) → no warning")

	# Addon-only leak (binary mode, no extensions): non-scripts seen, scripts gone.
	var d_addon: Dictionary = ExportStrip._decide_warning(false, true, {}, {})
	_h.ok(d_addon["warn"], "addon non-script seen but no script → warn")
	_h.ok(d_addon["addon_leaked"], "addon-only leak → addon_leaked true")
	_h.ok(int(d_addon["leaked_ext_count"]) == 0, "addon-only leak → 0 extensions")
	_h.ok(str(d_addon["message"]).find("Godot MCP Toolkit addon") >= 0, "addon message names the addon")
	# Tail always says "extension path"; the subject clause "N extension script(s)" must be absent.
	_h.ok(str(d_addon["message"]).find("extension script") < 0, "addon-only message omits extension clause")

	# Both leak (binary mode, 1 extension): addon + one unseen extension path.
	var d_both: Dictionary = ExportStrip._decide_warning(false, true, {"res://x/ext.gd": true}, {})
	_h.ok(d_both["warn"], "addon + unseen extension → warn")
	_h.ok(int(d_both["leaked_ext_count"]) == 1, "1 unseen extension counted")
	_h.ok(str(d_both["message"]).find("addon and 1 extension script(s)") >= 0, "message joins addon + 1 extension")
	# REGRESSION: the recipe must list the addon glob AND the explicit extension path.
	_h.ok(str(d_both["message"]).find("res://addons/godot_mcp_toolkit/*") >= 0, "message includes the addon exclude glob")
	_h.ok(str(d_both["message"]).find("res://x/ext.gd") >= 0, "message lists the leaked extension path explicitly")

	# Two leaked extensions → BOTH paths listed (comma-join regression guard).
	var d_two: Dictionary = ExportStrip._decide_warning(false, true, {"res://x/a.gd": true, "res://y/b.gd": true}, {})
	_h.ok(int(d_two["leaked_ext_count"]) == 2, "2 unseen extensions counted")
	_h.ok(d_two["leaked_ext_paths"].size() == 2, "leaked_ext_paths populated")
	_h.ok(str(d_two["message"]).find("2 extension script(s)") >= 0, "subject reports 2 extensions")
	_h.ok(str(d_two["message"]).find("res://x/a.gd") >= 0 and str(d_two["message"]).find("res://y/b.gd") >= 0, "both extension paths listed")

	# Q6 guard: addon already excluded by the user → NO addon file reaches us.
	var d_excluded: Dictionary = ExportStrip._decide_warning(false, false, {}, {})
	_h.ok(not d_excluded["warn"], "addon excluded (no non-script seen) → no false-positive warning")

	# Extension-only leak: addon excluded but an extension still shipped as .gdc.
	var d_ext: Dictionary = ExportStrip._decide_warning(false, false, {"res://x/ext.gd": true}, {})
	_h.ok(d_ext["warn"], "unseen extension alone → warn")
	_h.ok(not d_ext["addon_leaked"], "extension-only leak → addon_leaked false")
	_h.ok(str(d_ext["message"]).find("1 extension script(s)") >= 0, "extension-only message names the extension")
	_h.ok(str(d_ext["message"]).find("res://x/ext.gd") >= 0, "extension-only message lists the path explicitly")
	# Addon not leaked → neither the addon subject phrase nor the addon glob appears.
	_h.ok(str(d_ext["message"]).find("Godot MCP Toolkit addon") < 0, "extension-only message omits addon clause")
	_h.ok(str(d_ext["message"]).find("res://addons/godot_mcp_toolkit/*") < 0, "extension-only message omits addon glob")

	# Extension seen (text mode for the extension) → not counted as leaked.
	var d_ext_seen: Dictionary = ExportStrip._decide_warning(true, true, {"res://x/ext.gd": true}, {"res://x/ext.gd": true})
	_h.ok(not d_ext_seen["warn"], "extension seen (stripped) → no warning")

	print("")


# --- Report ----------------------------------------------------------------

# --- 41m-quinquies: scene.spatial_map geometry ----------------------------
func _test_spatial_map() -> void:
	_h.begin("scene.spatial_map (geometry)")

	# _world_bounds dispatch by node type. Nodes stay parentless so global ==
	# local transform (headless has no initialised World3D for a tree-parented
	# Node3D; real tree behaviour is covered by interactive smoke/sweep).
	var n3 := Node3D.new()
	n3.position = Vector3(1, 2, 3)
	var b3 = SpatialCommands._world_bounds(n3)
	_h.ok(typeof(b3) == TYPE_AABB, "Node3D → AABB")
	_h.ok(b3.size == Vector3.ZERO, "Node3D → point AABB (zero size; world pos via interactive)")
	n3.free()

	var n2 := Node2D.new()
	n2.position = Vector2(5, 6)
	var b2 = SpatialCommands._world_bounds(n2)
	_h.ok(typeof(b2) == TYPE_RECT2, "Node2D → Rect2")
	_h.ok(b2.position == Vector2(5, 6), "Node2D Rect2 at global_position")
	n2.free()

	var ctrl := Control.new()
	ctrl.position = Vector2(10, 10)
	ctrl.size = Vector2(20, 30)
	var bc = SpatialCommands._world_bounds(ctrl)
	_h.ok(typeof(bc) == TYPE_RECT2, "Control → Rect2")
	_h.ok(bc.size == Vector2(20, 30), "Control Rect2 size from get_global_rect")
	ctrl.free()

	var plain := Node.new()
	_h.ok(SpatialCommands._world_bounds(plain) == null, "plain Node → null (non-spatial)")
	plain.free()

	# _xform_rect2 / _xform_aabb world-space transform.
	_h.ok(SpatialCommands._xform_rect2(Transform2D.IDENTITY, Rect2(0, 0, 10, 10)) == Rect2(0, 0, 10, 10),
		"_xform_rect2 identity → same")
	var rt = SpatialCommands._xform_rect2(Transform2D(0.0, Vector2(5, 5)), Rect2(0, 0, 10, 10))
	_h.ok(rt.position == Vector2(5, 5) and rt.size == Vector2(10, 10), "_xform_rect2 translate")
	_h.ok(SpatialCommands._xform_aabb(Transform3D.IDENTITY, AABB(Vector3.ZERO, Vector3(2, 2, 2)))
		== AABB(Vector3.ZERO, Vector3(2, 2, 2)), "_xform_aabb identity → same")

	# _compute_relations: overlap + containment + nearest (full).
	var entries := [
		{"path": "a", "bounds": Rect2(0, 0, 10, 10)},
		{"path": "b", "bounds": Rect2(5, 5, 10, 10)},
		{"path": "c", "bounds": Rect2(100, 100, 5, 5)},
		{"path": "d", "bounds": Rect2(2, 2, 3, 3)},
	]
	SpatialCommands._compute_relations(entries, "full")
	_h.ok(entries[0]["overlaps"].has("b"), "overlap a-b detected")
	_h.ok(not entries[0]["overlaps"].has("c"), "no overlap a-c (disjoint)")
	_h.ok(entries[0]["contains"].has("d"), "containment a contains d")
	_h.ok(entries[3]["contained_by"].has("a"), "containment d contained_by a")
	_h.ok(entries[0].has("nearest"), "nearest neighbour computed (full)")

	# 2D and 3D never relate.
	var mixed := [
		{"path": "p2", "bounds": Rect2(0, 0, 10, 10)},
		{"path": "p3", "bounds": AABB(Vector3.ZERO, Vector3(10, 10, 10))},
	]
	SpatialCommands._compute_relations(mixed, "normal")
	_h.ok(mixed[0]["overlaps"].is_empty(), "2D node never overlaps 3D node")

	# Region parsing + filtering.
	_h.ok(typeof(SpatialCommands._parse_region([0, 0, 10, 10])) == TYPE_RECT2, "_parse_region 4 nums → Rect2")
	_h.ok(typeof(SpatialCommands._parse_region([0, 0, 0, 1, 1, 1])) == TYPE_AABB, "_parse_region 6 nums → AABB")
	_h.ok(SpatialCommands._parse_region([1, 2, 3]).has("error"), "_parse_region bad size → error")
	_h.ok(SpatialCommands._parse_region(null) == null, "_parse_region null → null")
	_h.ok(SpatialCommands._passes_filters(Rect2(0, 0, 5, 5), Rect2(0, 0, 10, 10), null),
		"region: 2D node inside → pass")
	_h.ok(not SpatialCommands._passes_filters(Rect2(0, 0, 5, 5), AABB(Vector3.ZERO, Vector3.ONE), null),
		"region: 3D region excludes 2D node")

	# Serialization.
	_h.eq(SpatialCommands._vec_to_array(Vector2(1, 2)), [1.0, 2.0], "_vec_to_array Vector2")
	_h.eq(SpatialCommands._vec_to_array(Vector3(1, 2, 3)), [1.0, 2.0, 3.0], "_vec_to_array Vector3")


# --- 41m-quinquies: texture.generate pixels + colour ----------------------
func _test_texture_generate() -> void:
	_h.begin("texture.generate (pixels + colour)")

	# _parse_color (hex / named, 0-1 vs 0-255 arrays, alpha-absent).
	_h.ok(TextureCommands._parse_color(null, Color(0.5, 0.5, 0.5, 1)) == Color(0.5, 0.5, 0.5, 1),
		"_parse_color null → default")
	var c_hex = TextureCommands._parse_color("#ff0000", Color.BLACK)
	_h.ok(c_hex.r > 0.99 and c_hex.g < 0.01 and c_hex.b < 0.01, "_parse_color #ff0000 → red")
	_h.ok(TextureCommands._parse_color([0, 255, 0], Color.BLACK).g > 0.99, "_parse_color [0,255,0] → green (0-255)")
	_h.ok(TextureCommands._parse_color([0, 0, 1], Color.BLACK).b > 0.99, "_parse_color [0,0,1] → blue (0-1)")
	_h.ok(TextureCommands._parse_color([0, 0, 0, 0], Color.WHITE).a == 0.0,
		"_parse_color [0,0,0,0] → transparent (alpha-absent)")

	# _in_shape inside/outside.
	_h.ok(TextureCommands._in_shape("solid", 8, 8, 16, 16, "up", 0), "solid: center inside")
	_h.ok(TextureCommands._in_shape("circle", 8, 8, 16, 16, "up", 0), "circle: center inside")
	_h.ok(not TextureCommands._in_shape("circle", 0, 0, 16, 16, "up", 0), "circle: corner outside")
	_h.ok(TextureCommands._in_shape("diamond", 8, 8, 16, 16, "up", 0), "diamond: center inside")
	_h.ok(not TextureCommands._in_shape("diamond", 0, 0, 16, 16, "up", 0), "diamond: corner outside")
	_h.ok(TextureCommands._in_shape("triangle", 8, 14, 16, 16, "up", 0), "triangle(up): bottom-center inside")
	_h.ok(not TextureCommands._in_shape("triangle", 1, 1, 16, 16, "up", 0), "triangle(up): top-corner outside")

	var red := Color(1, 0, 0, 1)
	var blue := Color(0, 0, 1, 1)
	var clear := Color(0, 0, 0, 0)

	# Solid fill covers everything.
	var solid := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	solid.fill(clear)
	TextureCommands._draw_shape(solid, "solid", red, clear, 0, clear, 4, "right")
	_h.ok(solid.get_pixel(8, 8) == red, "solid fill: center red")
	_h.ok(solid.get_pixel(0, 0) == red, "solid fill: corner red (covers all)")

	# Circle fill on transparent background.
	var circ := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	circ.fill(clear)
	TextureCommands._draw_shape(circ, "circle", red, clear, 0, clear, 4, "right")
	_h.ok(circ.get_pixel(8, 8) == red, "circle fill: center red")
	_h.ok(circ.get_pixel(0, 0).a == 0.0, "circle: corner transparent (background)")

	# Hollow shape: transparent fill + opaque outline → interior clear, band is outline.
	var hollow := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	hollow.fill(clear)
	TextureCommands._draw_shape(hollow, "solid", clear, blue, 2, clear, 4, "right")
	_h.ok(hollow.get_pixel(0, 0) == blue, "hollow solid: border blue (outline band)")
	_h.ok(hollow.get_pixel(8, 8).a == 0.0, "hollow solid: interior transparent (no fill)")

	# Checkerboard alternates fill / background.
	var checker := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	checker.fill(clear)
	TextureCommands._draw_shape(checker, "checkerboard", red, clear, 0, clear, 8, "right")
	_h.ok(checker.get_pixel(0, 0) == red, "checkerboard: cell (0,0) fill")
	_h.ok(checker.get_pixel(8, 0).a == 0.0, "checkerboard: cell (1,0) background")


# --- 41n/034 C1: particles.create _PROP_SPEC / _apply_props ----------------
# Pins the data-driven property applier that replaced pass 7's if-ladder. The
# load-bearing contract is the RETURNED count (== properties_set delta) plus the
# exact value + cast landing on the node / material. ParticleProcessMaterial and
# GPUParticles2D are not editor-only, so this runs headless.
func _test_particle_prop_apply() -> void:
	_h.begin("particles _apply_props (_PROP_SPEC)")

	# --- All 15 uniform props present → count 15, every value lands + cast.
	# Scalars deliberately arrive in the "wrong" numeric type to pin the cast:
	# amount as a float (→ int), spread as an int (→ float), one_shot as int 1
	# (→ bool true). Vectors/colour are pre-built (RAW direct-assign, no recast).
	var node_all := GPUParticles2D.new()
	var mat_all := ParticleProcessMaterial.new()
	var dir := Vector3(0, -1, 0)
	var grav := Vector3(0, 49, 0)
	var box := Vector3(100, 50, 0)
	var col := Color(0.2, 0.4, 0.6, 0.8)
	var eff_all := {
		"amount": 24.0,  # float in → int out
		"lifetime": 1.5,
		"explosiveness": 0.5,
		"speed_scale": 2.0,
		"one_shot": 1,  # int in → bool out
		"local_coords": true,
		"direction": dir,
		"spread": 30,  # int in → float out
		"gravity": grav,
		"color": col,
		"particle_flag_align_y": true,
		"emission_sphere_radius": 12.0,
		"emission_box_extents": box,
		"turbulence_enabled": true,
		"turbulence_noise_strength": 0.75,
	}
	var n_all := ParticleCommands._apply_props(node_all, mat_all, eff_all)
	_h.eq(n_all, 15, "all 15 props present → count 15")

	# Node group values + casts.
	_h.eq(node_all.amount, 24, "amount float 24.0 → int 24")
	_h.ok(typeof(node_all.amount) == TYPE_INT, "amount cast to int")
	_h.ok(is_equal_approx(node_all.lifetime, 1.5), "lifetime → 1.5")
	_h.ok(is_equal_approx(node_all.explosiveness, 0.5), "explosiveness → 0.5")
	_h.ok(is_equal_approx(node_all.speed_scale, 2.0), "speed_scale → 2.0")
	_h.eq(node_all.one_shot, true, "one_shot int 1 → bool true")
	_h.eq(node_all.local_coords, true, "local_coords → true")

	# Material group values + casts.
	_h.eq(mat_all.direction, dir, "direction → Vector3 (raw assign)")
	_h.ok(is_equal_approx(mat_all.spread, 30.0), "spread int 30 → float 30.0")
	_h.eq(mat_all.gravity, grav, "gravity → Vector3 (raw assign)")
	_h.eq(mat_all.color, col, "color → Color (raw assign)")
	_h.eq(mat_all.particle_flag_align_y, true, "particle_flag_align_y → true")
	_h.ok(is_equal_approx(mat_all.emission_sphere_radius, 12.0), "emission_sphere_radius → 12.0")
	_h.eq(mat_all.emission_box_extents, box, "emission_box_extents → Vector3 (raw assign)")
	_h.eq(mat_all.turbulence_enabled, true, "turbulence_enabled → true")
	_h.ok(is_equal_approx(mat_all.turbulence_noise_strength, 0.75), "turbulence_noise_strength → 0.75")
	node_all.free()

	# --- No props present → count 0, nothing written (props keep defaults).
	var node_none := GPUParticles2D.new()
	var mat_none := ParticleProcessMaterial.new()
	var amount_default := node_none.amount
	var spread_default := mat_none.spread
	_h.eq(ParticleCommands._apply_props(node_none, mat_none, {}), 0, "empty eff → count 0")
	_h.eq(node_none.amount, amount_default, "empty eff → amount untouched")
	_h.eq(mat_none.spread, spread_default, "empty eff → spread untouched")
	node_none.free()

	# --- Subset (1 node + 2 material) → count 3, only those land.
	var node_sub := GPUParticles2D.new()
	var mat_sub := ParticleProcessMaterial.new()
	var n_sub := ParticleCommands._apply_props(node_sub, mat_sub, {
		"lifetime": 3.0,
		"spread": 45.0,
		"turbulence_enabled": true,
	})
	_h.eq(n_sub, 3, "subset of 3 → count 3")
	_h.ok(is_equal_approx(node_sub.lifetime, 3.0), "subset: lifetime landed")
	_h.ok(is_equal_approx(mat_sub.spread, 45.0), "subset: spread landed")
	_h.eq(mat_sub.turbulence_enabled, true, "subset: turbulence_enabled landed")
	# A prop absent from the subset eff must NOT have been counted/written.
	_h.eq(node_sub.amount, node_none.amount, "subset: absent amount stays default")
	node_sub.free()


# --- 41n/034 C2: particles.create _OVERRIDE_SPEC / _merge_overrides --------
# Pins the data-driven override merge that replaced pass 6's match-ladder. The
# load-bearing contracts are (a) the merged eff values + casts and (b) the RETURNED
# overrides_applied array — its CONTENTS and ORDER are part of the particles.create
# response. Pure dict→dict logic, so this runs headless (no node, no editor).
func _test_particle_merge_overrides() -> void:
	_h.begin("particles _merge_overrides (_OVERRIDE_SPEC)")

	# --- Preset-only (no params) → eff unchanged, overrides empty.
	var fire: Dictionary = ParticleCommands._PRESETS["fire"].duplicate(true)
	var eff_pre: Dictionary = fire.duplicate(true)
	var ov_none := ParticleCommands._merge_overrides(eff_pre, {})
	_h.eq(ov_none.size(), 0, "no params → overrides_applied empty")
	_h.eq(eff_pre, fire, "no params → eff identical to preset")

	# --- Subset shadowing the preset → values + casts land, overrides in order.
	# fire has amount, spread, initial_velocity_min → all three shadow. params arrive
	# in the "wrong" numeric type to pin the cast (amount float→int, spread int→float).
	var eff_sub: Dictionary = fire.duplicate(true)
	var ov_sub := ParticleCommands._merge_overrides(eff_sub, {
		"amount": 99.0,  # float in → int out
		"spread": 5,  # int in → float out
		"initial_velocity": {"min": 1.0, "max": 2.0},
	})
	# _OVERRIDE_SPEC order puts amount before spread; range params append after.
	_h.eq(ov_sub, ["amount", "spread", "initial_velocity"], "shadowing overrides in contract order")
	_h.eq(eff_sub["amount"], 99, "amount float 99.0 → int 99")
	_h.ok(typeof(eff_sub["amount"]) == TYPE_INT, "amount cast to int")
	_h.ok(is_equal_approx(eff_sub["spread"], 5.0), "spread int 5 → float 5.0")
	_h.ok(is_equal_approx(eff_sub["initial_velocity_min"], 1.0), "range min landed")
	_h.ok(is_equal_approx(eff_sub["initial_velocity_max"], 2.0), "range max landed")

	# --- Vector/colour coercion (the merge VEC3/COLOR modes, distinct from apply RAW).
	var eff_vec := {}
	var ov_vec := ParticleCommands._merge_overrides(eff_vec, {
		"direction": {"x": 0.0, "y": -1.0, "z": 0.0},
		"color": {"r": 0.2, "g": 0.4, "b": 0.6, "a": 0.8},
		"gravity": {"x": 0.0, "y": 49.0, "z": 0.0},
	})
	_h.eq(ov_vec.size(), 0, "no preset → vec/colour applied but nothing shadowed")
	_h.eq(eff_vec["direction"], Vector3(0, -1, 0), "direction dict → Vector3")
	_h.eq(eff_vec["color"], Color(0.2, 0.4, 0.6, 0.8), "color dict → Color")
	_h.eq(eff_vec["gravity"], Vector3(0, 49, 0), "gravity dict → Vector3")

	# --- No preset → values written to eff but NONE appended (no shadow); range as
	# a bare scalar fans into _min/_max; an absent key never appears.
	var eff_np := {}
	var ov_np := ParticleCommands._merge_overrides(eff_np, {
		"amount": 7,
		"scale_range": 2.0,  # bare scalar → min == max
	})
	_h.eq(ov_np.size(), 0, "empty eff → nothing shadowed → overrides empty")
	_h.eq(eff_np["amount"], 7, "no-preset: amount still written to eff")
	_h.ok(is_equal_approx(eff_np["scale_min"], 2.0), "scalar range → scale_min")
	_h.ok(is_equal_approx(eff_np["scale_max"], 2.0), "scalar range → scale_max == min")
	_h.ok(not eff_np.has("lifetime"), "absent param never written")

	# --- Cross-sub-pass ORDER pin: simple + range + emission against an eff that
	# holds all three preset keys → array order is [simple, range, emission].
	var eff_ord := {"color": Color.WHITE, "scale_min": 0.5, "emission_shape": "point"}
	var ov_ord := ParticleCommands._merge_overrides(eff_ord, {
		"emission_shape": "box",
		"scale_range": {"min": 1.0, "max": 3.0},
		"color": {"r": 1.0, "g": 0.0, "b": 0.0, "a": 1.0},
	})
	_h.eq(ov_ord, ["color", "scale_range", "emission_shape"], "order: simple → range → emission")
	_h.eq(eff_ord["emission_shape"], "box", "emission_shape override landed (name kept)")


# --- 41m-quinquies: sound.generate synthesis ------------------------------
func _test_sound_generate() -> void:
	_h.begin("sound.generate (synth)")

	# _oscillator waveforms.
	_h.ok(abs(SoundCommands._oscillator("sine", 0.0)) < 0.001, "sine(0) approx 0")
	_h.ok(SoundCommands._oscillator("sine", PI / 2.0) > 0.99, "sine(pi/2) approx 1")
	_h.ok(SoundCommands._oscillator("square", 0.5) == 1.0, "square(+) = 1")
	_h.ok(SoundCommands._oscillator("square", PI + 0.5) == -1.0, "square(-) = -1")
	_h.ok(SoundCommands._oscillator("sawtooth", 0.0) < -0.99, "sawtooth(0) approx -1")
	_h.ok(SoundCommands._oscillator("triangle", PI / 2.0) > 0.99, "triangle(pi/2) approx 1")

	# _build_pcm length + content (mono 16-bit @ 44100).
	var pcm := SoundCommands._build_pcm("sine", 440.0, 440.0, false, 0.1, 0.8, 0.003, 0.003, 0.0)
	var expected_samples := int(0.1 * 44100)
	_h.eq(pcm.size(), expected_samples * 2, "_build_pcm byte length = samples*2 (16-bit mono)")
	var mid := expected_samples / 2
	var found_nonzero := false
	for i in range(mid, mini(mid + 120, expected_samples)):
		if pcm.decode_s16(i * 2) != 0:
			found_nonzero = true
			break
	_h.ok(found_nonzero, "_build_pcm sine non-silent in sustain")

	# volume 0 → silence.
	var silent := SoundCommands._build_pcm("sine", 440.0, 440.0, false, 0.05, 0.0, 0.0, 0.0, 0.0)
	var all_zero := true
	for i in range(silent.size() / 2):
		if silent.decode_s16(i * 2) != 0:
			all_zero = false
			break
	_h.ok(all_zero, "_build_pcm volume 0 → silence")

	# noise varies sample-to-sample.
	var noise := SoundCommands._build_pcm("noise", 440.0, 440.0, false, 0.05, 0.8, 0.0, 0.0, 0.0)
	var distinct := {}
	for i in range(mini(50, noise.size() / 2)):
		distinct[noise.decode_s16(i * 2)] = true
	_h.ok(distinct.size() > 5, "_build_pcm noise varies sample-to-sample")


# --- resolve_create_collision (concern 017) -------------------------------
# Pure decision query shared by the file creators (scene.create, asset.import,
# texture/sound.generate). Validates if_exists, stats the destination, returns
# the {valid, existed, action} DECISION — no payload, no write. Editor-free:
# FileAccess.file_exists sees user:// paths, so existence cases use a temp file.
func _test_create_collision_resolver() -> void:
	_h.begin("resolve_create_collision (concern 017)")

	# A guaranteed-absent res:// path (randomised to dodge any stray fixture).
	var absent := "res://__nope_%d.png" % (randi() % 1_000_000)

	# Not-exists: every legal if_exists short-circuits to action "create".
	var c_create := Helpers.resolve_create_collision(absent, "return")
	_h.eq(c_create.get("valid"), true, "absent + return → valid")
	_h.eq(c_create.get("existed"), false, "absent + return → existed false")
	_h.eq(c_create.get("action"), "create", "absent + return → action create")
	_h.eq(Helpers.resolve_create_collision(absent, "fail").get("action"), "create",
		"absent + fail → action create (value irrelevant when absent)")
	_h.eq(Helpers.resolve_create_collision(absent, "replace").get("action"), "create",
		"absent + replace → action create")

	# Invalid if_exists → {valid:false} (no existence read needed).
	_h.eq(Helpers.resolve_create_collision(absent, "clobber").get("valid"), false,
		"invalid value 'clobber' → valid false")
	_h.eq(Helpers.resolve_create_collision(absent, "").get("valid"), false,
		"empty value → valid false")
	_h.eq(Helpers.resolve_create_collision(absent, "Return").get("valid"), false,
		"wrong-case 'Return' → valid false (exact-case match)")

	# Exists: write a temp file under user://, assert the action == if_exists, clean up.
	var present := "user://__collision_test_%d.tmp" % (randi() % 1_000_000)
	var f := FileAccess.open(present, FileAccess.WRITE)
	if f == null:
		_h.ok(false, "could not open temp file for existence cases — SKIPPED exists path")
	else:
		f.store_string("x")
		f.close()

		var c_return := Helpers.resolve_create_collision(present, "return")
		_h.eq(c_return.get("valid"), true, "exists + return → valid")
		_h.eq(c_return.get("existed"), true, "exists + return → existed true")
		_h.eq(c_return.get("action"), "return", "exists + return → action return")
		_h.eq(Helpers.resolve_create_collision(present, "fail").get("action"), "fail",
			"exists + fail → action fail")
		_h.eq(Helpers.resolve_create_collision(present, "replace").get("action"), "replace",
			"exists + replace → action replace")

		# Validation precedes existence: invalid value while the file exists is
		# still {valid:false} — locks that the value check runs before the stat.
		_h.eq(Helpers.resolve_create_collision(present, "nope").get("valid"), false,
			"exists + invalid value → valid false (validation precedes existence)")

		DirAccess.remove_absolute(ProjectSettings.globalize_path(present))


# --- tileset.edit_* per-verb key enforcement (concern 031) ----------------
# The five tileset.edit_* tools share one handler but each owns exactly one
# tile-data concern. _foreign_key_error is the pure gate: it accepts only the
# verb's own keys (plus the universal atlas_x/atlas_y selectors) and rejects the
# first foreign key with a message that names the tool owning it. Pure → testable
# without an editor or a TileSet resource.
func _test_tileset_edit_key_enforcement() -> void:
	_h.begin("tileset.edit_* key enforcement (concern 031)")

	# Happy path: each verb with only its own keys (+ coords) → accepted ("").
	_h.eq(TilesetTileData._foreign_key_error("physics",
		{"atlas_x": 0, "atlas_y": 0, "physics_polygon": "full", "physics_layer": 0,
			"one_way_collision": true}), "", "physics accepts its own keys")
	_h.eq(TilesetTileData._foreign_key_error("terrain",
		{"atlas_x": 1, "atlas_y": 0, "terrain_set": 0, "terrain": 0,
			"terrain_peering": {"center": 0}}), "", "terrain accepts its own keys")
	_h.eq(TilesetTileData._foreign_key_error("navigation",
		{"atlas_x": 0, "atlas_y": 0, "navigation_polygon": "full", "navigation_layer": 0}),
		"", "navigation accepts its own keys")
	_h.eq(TilesetTileData._foreign_key_error("visuals",
		{"atlas_x": 0, "atlas_y": 0, "occlusion_polygon": "full", "occlusion_layer": 0,
			"animation": {"frame_count": 2}, "probability": 0.5}), "",
		"visuals accepts occlusion+animation+probability bundle")
	_h.eq(TilesetTileData._foreign_key_error("custom_data",
		{"atlas_x": 0, "atlas_y": 0, "custom_data": {"damage": 10}}), "",
		"custom_data accepts its own key")

	# Coordinate-only tile is always valid (selectors are universal).
	_h.eq(TilesetTileData._foreign_key_error("physics", {"atlas_x": 0, "atlas_y": 0}),
		"", "coords-only tile accepted")

	# Foreign key → rejected, and the message names the OWNING tool.
	var r1 := TilesetTileData._foreign_key_error("physics",
		{"atlas_x": 0, "atlas_y": 0, "terrain_set": 0})
	_h.ok(not r1.is_empty(), "terrain_set on physics → rejected")
	_h.ok(r1.contains("tileset.edit_terrain"), "physics rejection names tileset.edit_terrain")

	var r2 := TilesetTileData._foreign_key_error("terrain",
		{"atlas_x": 0, "atlas_y": 0, "physics_polygon": "full"})
	_h.ok(r2.contains("tileset.edit_physics"), "physics_polygon on terrain → names edit_physics")

	var r3 := TilesetTileData._foreign_key_error("navigation",
		{"atlas_x": 0, "atlas_y": 0, "probability": 0.5})
	_h.ok(r3.contains("tileset.edit_visuals"), "probability on navigation → names edit_visuals")

	var r4 := TilesetTileData._foreign_key_error("custom_data",
		{"atlas_x": 0, "atlas_y": 0, "navigation_polygon": "full"})
	_h.ok(r4.contains("tileset.edit_navigation"), "navigation_polygon on custom_data → names edit_navigation")

	var r5 := TilesetTileData._foreign_key_error("visuals",
		{"atlas_x": 0, "atlas_y": 0, "custom_data": {"x": 1}})
	_h.ok(r5.contains("tileset.edit_custom_data"), "custom_data on visuals → names edit_custom_data")

	# A key owned by no verb → rejected via the "unknown key" branch (no owner).
	var r6 := TilesetTileData._foreign_key_error("physics",
		{"atlas_x": 0, "atlas_y": 0, "bogus_key": 1})
	_h.ok(not r6.is_empty(), "unknown key on physics → rejected")
	_h.ok(r6.contains("unknown key"), "unknown-key rejection uses unknown-key wording")

	# Unknown verb has an empty allow-list → first non-coord key is foreign.
	_h.ok(not TilesetTileData._foreign_key_error("bogus_verb",
		{"atlas_x": 0, "atlas_y": 0, "physics_polygon": "full"}).is_empty(),
		"unknown verb rejects any non-coord key")


# --- tileset_io full-tile polygon (decompose 034 C1, DRY ×3 → 1) ----------
# build_full_tile_polygon is the consolidated unit rectangle that create's
# collision seed and edit_physics' "full"/"one_way" shape all share. Pure
# geometry — pin the exact vertex output so the DRY can never drift.
func _test_tileset_io_polygon() -> void:
	_h.begin("tileset_io.build_full_tile_polygon (geometry)")

	# 16×16 tile → ±8 corners, wound TL → TR → BR → BL (the order create and
	# edit_physics both rely on for set_collision_polygon_points).
	var p16 := TilesetIo.build_full_tile_polygon(Vector2i(16, 16))
	_h.eq(p16, PackedVector2Array([
		Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)]),
		"16x16 → exact ±8 rectangle in winding order")

	# Non-square tile uses x and y half-extents independently.
	var p_rect := TilesetIo.build_full_tile_polygon(Vector2i(32, 16))
	_h.eq(p_rect, PackedVector2Array([
		Vector2(-16, -8), Vector2(16, -8), Vector2(16, 8), Vector2(-16, 8)]),
		"32x16 → independent half-extents")

	# Odd size keeps the float half (/ 2.0) — no integer truncation.
	var p_odd := TilesetIo.build_full_tile_polygon(Vector2i(15, 15))
	_h.eq(p_odd[0], Vector2(-7.5, -7.5), "odd size keeps .5 half (float division)")


# --- Coerce/serialize round-trip symmetry (concern 018) -------------------
# coerce_value (JSON dict → Godot) and serialize_value (Godot → JSON dict)
# share one tagged-type vocabulary. For value types that serialize_value emits
# as a tagged dict, the Godot-value round-trip coerce_value(serialize_value(V))
# must reproduce V exactly (native compare — no float-string fragility).
#
# Packed* tags (PackedVector2/3Array, PackedColorArray) are bidirectionally
# symmetric as of concern 053 — serialize_value emits the tagged form, so the full
# native round-trip coerce_value(serialize_value(V)) == V holds (asserted below).
# LayerMask stays coerce-only BY DESIGN: a mask is a bare int with no per-value
# marker, so serialize_value cannot tag it without tagging every int — it reads
# back as a plain int, itself writable as-is (no value round-trip break).
# Resource/NewResource are skipped: path-based (ResourceLoader), not value-symmetric.

func _test_coerce_roundtrip() -> void:
	_h.begin("Coerce/serialize round-trip (concern 018)")

	# Tagged-dict value types: coerce_value(serialize_value(V)) == V (both legs).
	var vec2: Vector2 = Vector2(3.5, -2.0)
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(vec2)) == vec2, "Vector2 round-trips")
	var vec3: Vector3 = Vector3(1.0, 2.0, -3.5)
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(vec3)) == vec3, "Vector3 round-trips")
	var vec4: Vector4 = Vector4(1.0, 2.0, 3.0, 4.0)
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(vec4)) == vec4, "Vector4 round-trips")
	var vec2i: Vector2i = Vector2i(7, -8)
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(vec2i)) == vec2i, "Vector2i round-trips")
	var vec3i: Vector3i = Vector3i(-1, 2, 9)
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(vec3i)) == vec3i, "Vector3i round-trips")
	var col: Color = Color(0.25, 0.5, 0.75, 1.0)
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(col)) == col, "Color round-trips")
	var rect2: Rect2 = Rect2(1.0, 2.0, 3.0, 4.0)
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(rect2)) == rect2, "Rect2 round-trips")
	var rect2i: Rect2i = Rect2i(5, 6, 7, 8)
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(rect2i)) == rect2i, "Rect2i round-trips")
	var xform2d: Transform2D = Transform2D(Vector2(0.0, 1.0), Vector2(-1.0, 0.0), Vector2(5.0, 6.0))
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(xform2d)) == xform2d, "Transform2D round-trips")
	var basis: Basis = Basis(Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.0, 0.0))
	var xform3d: Transform3D = Transform3D(basis, Vector3(7.0, 8.0, 9.0))
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(xform3d)) == xform3d, "Transform3D round-trips")
	var npath: NodePath = NodePath("Player/Sprite2D:position")
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(npath)) == npath, "NodePath round-trips")

	# Coerce leg: assert coerce_value parses the EXACT documented tagged wire form
	# (JSON→Godot). For Packed* this complements the symmetric round-trip below — it
	# pins the wire shape itself, not just coerce∘serialize self-consistency.
	# LayerMask is coerce-only by design (see header).
	var pv2: Variant = Coerce.coerce_value({
		"type": "PackedVector2Array",
		"values": [{"type": "Vector2", "x": 1.0, "y": 2.0}, {"type": "Vector2", "x": 3.0, "y": 4.0}],
	})
	_h.ok(pv2 == PackedVector2Array([Vector2(1.0, 2.0), Vector2(3.0, 4.0)]),
			"PackedVector2Array coerces from the documented tagged form")
	var pv3: Variant = Coerce.coerce_value({
		"type": "PackedVector3Array",
		"values": [{"type": "Vector3", "x": 1.0, "y": 2.0, "z": 3.0}],
	})
	_h.ok(pv3 == PackedVector3Array([Vector3(1.0, 2.0, 3.0)]),
			"PackedVector3Array coerces from the documented tagged form")
	var pcol: Variant = Coerce.coerce_value({
		"type": "PackedColorArray",
		"values": [{"type": "Color", "r": 1.0, "g": 0.0, "b": 0.0, "a": 1.0}],
	})
	_h.ok(pcol == PackedColorArray([Color(1.0, 0.0, 0.0, 1.0)]),
			"PackedColorArray coerces from the documented tagged form")
	# LayerMask: numeric layers 1 and 3 → bits 0 and 2 → 0b101 = 5 (no ProjectSettings).
	var mask: Variant = Coerce.coerce_value({"type": "LayerMask", "layers": [1, 3]})
	_h.eq(mask, 5, "LayerMask coerces layers [1,3] → bitmask 5 (coerce-only tag)")

	# Concern 053: serialize_value now emits the tagged Packed* form (was a
	# var_to_str string), so the Packed* tags are bidirectionally symmetric.
	# Assert the full native round-trip coerce_value(serialize_value(V)) == V.
	var pv2_native: PackedVector2Array = PackedVector2Array([Vector2(1.0, 2.0), Vector2(-3.5, 4.0)])
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(pv2_native)) == pv2_native,
			"PackedVector2Array round-trips (now symmetric)")
	var pv3_native: PackedVector3Array = PackedVector3Array([Vector3(1.0, 2.0, 3.0), Vector3(-4.0, 5.5, 6.0)])
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(pv3_native)) == pv3_native,
			"PackedVector3Array round-trips (now symmetric)")
	var pcol_native: PackedColorArray = PackedColorArray([Color(1.0, 0.0, 0.0, 1.0), Color(0.25, 0.5, 0.75, 0.5)])
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(pcol_native)) == pcol_native,
			"PackedColorArray round-trips (now symmetric)")

	print("")


# --- color_from_dict white-default projection -----------------------------
# Pins both default behaviours of Coerce.color_from_dict so neither the
# white-default (modulate/tint) family nor the override path drifts after the
# 3d/particle/procedural/tileset sites were routed through this one helper.
func _test_color_from_dict() -> void:
	_h.begin("Coerce.color_from_dict white-default projection")

	# Full {r,g,b,a} dict → exact Color, no defaulting.
	_h.eq(Coerce.color_from_dict({"r": 0.25, "g": 0.5, "b": 0.75, "a": 0.5}),
			Color(0.25, 0.5, 0.75, 0.5), "full {r,g,b,a} → exact Color")
	# Missing channels fall to opaque-white (1.0) — alpha included.
	_h.eq(Coerce.color_from_dict({"r": 1.0, "g": 0.0, "b": 0.0}),
			Color(1.0, 0.0, 0.0, 1.0), "missing alpha → opaque (a defaults 1.0)")
	# Empty dict → all channels default 1.0 → opaque white.
	_h.eq(Coerce.color_from_dict({}), Color(1.0, 1.0, 1.0, 1.0),
			"empty dict → opaque white via channel defaults")
	# Non-dict, no override → the white default.
	_h.eq(Coerce.color_from_dict(null), Color(1.0, 1.0, 1.0, 1.0),
			"non-dict → white default")
	_h.eq(Coerce.color_from_dict("not a dict"), Color(1.0, 1.0, 1.0, 1.0),
			"non-dict string → white default")
	# default override governs the non-dict case only.
	_h.eq(Coerce.color_from_dict(null, Color.BLACK), Color(0.0, 0.0, 0.0, 1.0),
			"non-dict + BLACK override → black default")
	# A dict still channel-defaults to white even when an override is passed
	# (override is the non-dict fallback, not a per-channel source).
	_h.eq(Coerce.color_from_dict({"r": 0.5}, Color.BLACK), Color(0.5, 1.0, 1.0, 1.0),
			"dict ignores override; channels stay opaque white")

	print("")


# --- _color_from_dict_opaque black-default projection ---------------------
# Pins the paint/opaque-BLACK channel defaults of theme_commands'
# _color_from_dict_opaque (r/g/b default 0.0, a defaults 1.0) — the sibling of
# Coerce.color_from_dict's opaque-WHITE defaults. The partial-dict case is the
# decisive contrast: a missing g/b must stay 0.0 here, NOT 1.0 (that is the tint
# helper), so the two paint/tint facts never drift together.
func _test_color_from_dict_opaque() -> void:
	_h.begin("theme _color_from_dict_opaque black-default projection")

	# Partial dict: missing g/b default 0.0 (the contrast vs the white helper).
	_h.eq(ThemeCommands._color_from_dict_opaque({"r": 0.5}), Color(0.5, 0, 0, 1),
			"partial {r} → missing g/b default 0.0 (paint, not tint)")
	# Full {r,g,b,a} dict → exact Color, no defaulting.
	_h.eq(ThemeCommands._color_from_dict_opaque({"r": 0.25, "g": 0.5, "b": 0.75, "a": 0.5}),
			Color(0.25, 0.5, 0.75, 0.5), "full {r,g,b,a} → exact Color")
	# Non-dict → opaque black.
	_h.eq(ThemeCommands._color_from_dict_opaque(null), Color(0, 0, 0, 1),
			"non-dict → opaque black")

	print("")


# --- node-sourced Packed property serialises tagged (concern 053) ----------
# The unit suite above pins coerce∘serialize on hand-built Packed* values; this
# pins the read PATH'S contract: node.get_property serialises the property VALUE
# through Coerce.serialize_value (node_commands.gd:158 — the single-property read).
# Here we obtain a PackedVector2Array from an ACTUAL node property (Line2D.points)
# and assert serialize_value emits the TAGGED dict {type:"PackedVector2Array", …}
# — NOT a var_to_str String — and that it round-trips back to the exact value.
# This is the headless proxy for sweep 3.20b (node_set_property → node_get_property).
# No editor/dispatch context needed: serialize_value is the same call the handler
# makes on node.get(property), so exercising it on a node-sourced value covers the
# read path's serialisation without a live scene. Node built with .new()/free().
func _test_node_packed_property_serialize() -> void:
	_h.begin("node-sourced Packed property serialises tagged (concern 053)")

	var line := Line2D.new()
	var written: PackedVector2Array = PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(100.0, 50.0), Vector2(200.0, 0.0)])
	line.points = written

	# Read the property the way the handler does (node.get(...) → Variant), then
	# serialise it the way node.get_property does (Coerce.serialize_value).
	var read_value: Variant = line.get("points")
	_h.eq(typeof(read_value), TYPE_PACKED_VECTOR2_ARRAY,
			"Line2D.points reads back as a PackedVector2Array")

	var serialised: Variant = Coerce.serialize_value(read_value)
	# The contract: a tagged Dictionary, NOT a var_to_str String (the 053 fix).
	_h.eq(typeof(serialised), TYPE_DICTIONARY,
			"serialised node Packed value is a Dictionary, not a String (concern 053)")
	var serialised_dict: Dictionary = serialised
	_h.eq(str(serialised_dict.get("type", "")), "PackedVector2Array",
			"serialised form carries type tag 'PackedVector2Array' (not a var_to_str string)")
	var values_field: Variant = serialised_dict.get("values", null)
	_h.eq(typeof(values_field), TYPE_ARRAY, "serialised form has a 'values' array")

	# Read-form must round-trip back to the written value (read==write for the LLM).
	var restored: Variant = Coerce.coerce_value(serialised)
	_h.ok(restored == written,
			"node-sourced PackedVector2Array round-trips (coerce(serialize(points)) == written)")

	line.free()
	print("")


# --- save.read configurable cap + byte-offset paging (concern 025) ---------
# _cmd_save_read gained a configurable cap (save_read_cap_kb, min 64) replacing
# the hardcoded 256 KB, an `offset` param for windowed paging, a `next_offset`
# return, and a FILE_TOO_LARGE frame guard (base64 1.33× projection vs
# ws_buffer_kb) so an oversized window is rejected before it silently vanishes on
# the transport. Drives the real handler against a user:// temp file; restores
# the mutated limit settings afterward.

const SaveCommands := preload("res://addons/godot_mcp_toolkit/commands/save_commands.gd")

func _test_save_read_paging() -> void:
	_h.begin("save.read cap + offset paging (concern 025)")

	# Preserve the limit settings this test mutates (str/int coercion — Variant
	# source, warnings-as-error in test/).
	var orig_cap: int = int(ProjectSettings.get_setting("mcp_toolkit/limits/save_read_cap_kb", 256))
	var orig_ws: int = int(ProjectSettings.get_setting("mcp_toolkit/limits/ws_buffer_kb", 1024))

	# A deterministic ASCII fixture so byte offsets == character offsets and the
	# UTF-8 decode path (not base64) is exercised. 1000 bytes total.
	var body := "A".repeat(1000)
	var rel_path := "user://saves/sv2_paging_025.txt"
	var abs_path := ProjectSettings.globalize_path(rel_path)
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	var wf := FileAccess.open(abs_path, FileAccess.WRITE)
	_h.ok(wf != null, "fixture file opened for write")
	if wf != null:
		wf.store_string(body)
		wf.close()

	# Default cap (256 KB) for the paging assertions.
	ProjectSettings.set_setting("mcp_toolkit/limits/save_read_cap_kb", 256)
	ProjectSettings.set_setting("mcp_toolkit/limits/ws_buffer_kb", 1024)

	# 1. First window: offset 0, max_bytes 400 → 400 bytes, next_offset 400,
	#    truncated true (600 remain), total_bytes 1000.
	var p1: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": 400})
	_h.ok(p1.get("success", false), "window 1 → success")
	_h.eq(p1.get("bytes_returned", -1), 400, "window 1 → 400 bytes returned")
	_h.eq(p1.get("offset", -1), 0, "window 1 → offset 0 echoed")
	_h.eq(p1.get("next_offset", -1), 400, "window 1 → next_offset 400")
	_h.eq(p1.get("total_bytes", -1), 1000, "window 1 → total_bytes 1000")
	_h.eq(p1.get("truncated", null), true, "window 1 → truncated true (more remains)")
	# Uniform pagination contract (concern 054): truncated window carries a prose
	# hint naming next_offset; not-truncated windows omit it (asserted below).
	_h.ok(p1.has("hint"), "window 1 → hint present (truncated)")
	_h.ok(str(p1.get("hint", "")).contains("next_offset"), "window 1 → hint names next_offset")

	# 2. Middle window: seek correctness — offset 400, max_bytes 400 → next_offset
	#    800, still truncated.
	var p2: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "offset": 400, "max_bytes": 400})
	_h.eq(p2.get("bytes_returned", -1), 400, "window 2 → 400 bytes returned")
	_h.eq(p2.get("offset", -1), 400, "window 2 → offset 400 echoed")
	_h.eq(p2.get("next_offset", -1), 800, "window 2 → next_offset 800")
	_h.eq(p2.get("truncated", null), true, "window 2 → still truncated")

	# 3. Final window: offset 800 → only 200 bytes left; next_offset reaches EOF,
	#    truncated false. Pins next_offset arithmetic = offset + bytes_returned.
	var p3: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "offset": 800, "max_bytes": 400})
	_h.eq(p3.get("bytes_returned", -1), 200, "window 3 → 200 bytes (clamped to remaining)")
	_h.eq(p3.get("next_offset", -1), 1000, "window 3 → next_offset 1000 (== total)")
	_h.eq(p3.get("truncated", null), false, "window 3 → truncated false (reached EOF)")
	_h.ok(not p3.has("hint"), "window 3 → no hint (not truncated)")

	# 4. Offset exactly AT EOF → 0 bytes, not an error; next_offset == total,
	#    truncated false (graceful completion sentinel for a paging caller).
	var p_eof: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "offset": 1000})
	_h.ok(p_eof.get("success", false), "offset == EOF → success (not an error)")
	_h.eq(p_eof.get("bytes_returned", -1), 0, "offset == EOF → 0 bytes")
	_h.eq(p_eof.get("next_offset", -1), 1000, "offset == EOF → next_offset == total")
	_h.eq(p_eof.get("truncated", null), false, "offset == EOF → truncated false")

	# 5. Offset PAST EOF → still graceful: 0 bytes, no error.
	var p_past: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "offset": 99999})
	_h.ok(p_past.get("success", false), "offset past EOF → success (not an error)")
	_h.eq(p_past.get("bytes_returned", -1), 0, "offset past EOF → 0 bytes")
	_h.eq(p_past.get("truncated", null), false, "offset past EOF → truncated false")

	# 6. Negative offset → INVALID_PARAMS.
	var p_neg: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "offset": -1})
	_h.eq(p_neg.get("success", null), false, "negative offset → rejected")
	_h.eq(str(p_neg.get("code", "")), "INVALID_PARAMS", "negative offset → INVALID_PARAMS")

	# 7. Cap clamp — at the default 256 KB cap, max_bytes one past the cap is
	#    rejected; exactly at the cap is accepted (the 256 KB default == the former
	#    hardcoded ceiling, so default behaviour is unchanged).
	var at_cap := 262144
	var over_cap: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": at_cap + 1})
	_h.eq(over_cap.get("success", null), false, "max_bytes cap+1 → rejected")
	_h.eq(str(over_cap.get("code", "")), "INVALID_PARAMS", "max_bytes cap+1 → INVALID_PARAMS")
	var at_cap_ok: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": at_cap})
	_h.ok(at_cap_ok.get("success", false), "max_bytes == cap → accepted")

	# 8. Cap is configurable upward: raise to 512 KB → a max_bytes of 300 KB
	#    (rejected at the default) is now accepted.
	ProjectSettings.set_setting("mcp_toolkit/limits/save_read_cap_kb", 512)
	var raised: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": 300 * 1024})
	_h.ok(raised.get("success", false), "raised cap 512 KB → 300 KB max_bytes accepted")

	# 9. Cap floor — a sub-minimum cap setting (32) is floored to 64 KB, so a
	#    max_bytes above 64 KB but below the raw setting is rejected at the floor.
	ProjectSettings.set_setting("mcp_toolkit/limits/save_read_cap_kb", 32)
	var floored: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": 100 * 1024})
	_h.eq(floored.get("success", null), false, "cap 32 floored to 64 KB → 100 KB max_bytes rejected")
	var floored_ok: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": 64 * 1024})
	_h.ok(floored_ok.get("success", false), "cap 32 floored to 64 KB → 64 KB max_bytes accepted")

	# 10. FILE_TOO_LARGE frame guard — raise the cap high and drop ws_buffer_kb to
	#     256 (its floor). A 250 KB window projects to ~333 KB base64, over the
	#     256 KB buffer → FILE_TOO_LARGE BEFORE any read, with total_bytes + a hint.
	#     (Use a larger fixture so 250 KB is actually available to request.)
	var big_body := "B".repeat(300 * 1024)
	var big_rel := "user://saves/sv2_paging_025_big.txt"
	var big_abs := ProjectSettings.globalize_path(big_rel)
	var bwf := FileAccess.open(big_abs, FileAccess.WRITE)
	if bwf != null:
		bwf.store_string(big_body)
		bwf.close()
	ProjectSettings.set_setting("mcp_toolkit/limits/save_read_cap_kb", 1024)
	ProjectSettings.set_setting("mcp_toolkit/limits/ws_buffer_kb", 256)
	var too_large: Dictionary = SaveCommands._cmd_save_read({"path": big_rel, "max_bytes": 250 * 1024})
	_h.eq(too_large.get("success", null), false, "oversized window → rejected")
	_h.eq(str(too_large.get("code", "")), "FILE_TOO_LARGE", "oversized window → FILE_TOO_LARGE")
	_h.ok(too_large.has("total_bytes"), "FILE_TOO_LARGE → carries total_bytes")
	_h.ok(str(too_large.get("hint", "")).contains("offset"),
			"FILE_TOO_LARGE → hint mentions offset paging")
	# A small window of the SAME big file fits and succeeds (guard is per-window,
	# not per-file).
	var small_window: Dictionary = SaveCommands._cmd_save_read({"path": big_rel, "max_bytes": 100 * 1024})
	_h.ok(small_window.get("success", false), "small window of the big file → fits, succeeds")

	# Cleanup: remove fixtures, restore the mutated limit settings.
	DirAccess.remove_absolute(abs_path)
	DirAccess.remove_absolute(big_abs)
	ProjectSettings.set_setting("mcp_toolkit/limits/save_read_cap_kb", orig_cap)
	ProjectSettings.set_setting("mcp_toolkit/limits/ws_buffer_kb", orig_ws)
	print("")


# --- script.read uniform pagination contract (concern 054) -----------------
# script.read now mirrors save.read's SHAPE in LINE units: every success carries
# truncated + total_lines; a windowed read whose end precedes EOF also carries
# next_start_line (1-based resume = clamped end_line + 1) + a prose hint; a full
# read (and a window reaching EOF) returns truncated:false with no hint. ADD-ONLY
# (concern 054) — existing start_line/end_line/total_lines/content are unchanged.
# Drives the real handler against a res:// temp fixture; removes it afterward.

func _test_script_read_paging() -> void:
	_h.begin("script.read pagination contract (concern 054)")

	# A deterministic 5-line fixture (no trailing newline → split("\n") size 5).
	var fixture := "res://sv2_script_read_054.gd"
	var sf := FileAccess.open(fixture, FileAccess.WRITE)
	_h.ok(sf != null, "fixture script opened for write")
	if sf != null:
		sf.store_string("line1\nline2\nline3\nline4\nline5")
		sf.close()

	# 1. Windowed read that ENDS BEFORE EOF (lines 1..2 of 5) → truncated true,
	#    next_start_line 3, hint naming next_start_line. total_lines preserved.
	var w: Dictionary = ScriptCommands._cmd_script_read({"file_path": fixture, "start_line": 1, "end_line": 2})
	_h.ok(w.get("success", false), "window 1..2 → success")
	_h.eq(w.get("start_line", -1), 1, "window → start_line 1 preserved")
	_h.eq(w.get("end_line", -1), 2, "window → end_line 2 preserved")
	_h.eq(w.get("total_lines", -1), 5, "window → total_lines 5 preserved")
	_h.eq(w.get("truncated", null), true, "window 1..2 → truncated true (2 < 5)")
	_h.eq(w.get("next_start_line", -1), 3, "window → next_start_line = end_line + 1 = 3 (1-based)")
	_h.ok(str(w.get("hint", "")).contains("next_start_line"), "window → hint names next_start_line")

	# 2. Windowed read that REACHES EOF (lines 3..5; end clamps to 5) → truncated
	#    false, no next_start_line, no hint.
	var eofw: Dictionary = ScriptCommands._cmd_script_read({"file_path": fixture, "start_line": 3, "end_line": 999})
	_h.eq(eofw.get("end_line", -1), 5, "window 3..999 → end_line clamped to 5")
	_h.eq(eofw.get("truncated", null), false, "window reaching EOF → truncated false")
	_h.ok(not eofw.has("next_start_line"), "window at EOF → no next_start_line")
	_h.ok(not eofw.has("hint"), "window at EOF → no hint")

	# 3. FULL read (no start_line) → truncated false + total_lines, contract-complete.
	#    Existing 'content' field is still present (additive change).
	var full: Dictionary = ScriptCommands._cmd_script_read({"file_path": fixture})
	_h.ok(full.get("success", false), "full read → success")
	_h.ok(full.has("content"), "full read → content preserved")
	_h.eq(full.get("total_lines", -1), 5, "full read → total_lines 5 (added for uniformity)")
	_h.eq(full.get("truncated", null), false, "full read → truncated false")
	_h.ok(not full.has("next_start_line"), "full read → no next_start_line")
	_h.ok(not full.has("hint"), "full read → no hint")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(fixture))
	print("")


# --- SettingsRegistration mcp_toolkit/* collector (concern 002) -------------
# unregister_all() scrubs every mcp_toolkit/* ProjectSettings key on uninstall
# via a PREFIX SCAN, not a hardcoded list — that staleness is the concern (its
# own list missed save_read_cap_kb). _collect_mcp_setting_names is the read-only
# core that scan drives; pinning it proves the prefix matches the keys that
# matter (incl. the one the stale list dropped) and excludes engine keys.
# READ-ONLY by design: asserts the collector only — it must NOT call
# unregister_all / set_setting-persist / save (the runner loads the real dogfood
# project, so a save would scrub project.godot). It calls register_all() first
# (mirroring the plugin's _enter_tree) so the collector sees the full registered
# set — register_all is in-memory only (no save), so project.godot stays clean.
func _test_settings_collect_names() -> void:
	_h.begin("SettingsRegistration mcp_toolkit/* collector (concern 002)")
	# Establish production's precondition: register_all() runs in the plugin's
	# _enter_tree before unregister_all() is ever reached in _disable_plugin. The
	# headless --script runner doesn't run _enter_tree, so register the keys here
	# so the collector sees the full set. register_all() does NOT call
	# ProjectSettings.save() — purely in-memory, so project.godot is untouched.
	SettingsRegistration.register_all()
	var names := SettingsRegistration._collect_mcp_setting_names()
	# Regression-pin: the exact key the concern's stale hardcoded list missed.
	_h.ok(names.has("mcp_toolkit/limits/save_read_cap_kb"),
			"collector includes save_read_cap_kb (the key the stale list missed)")
	_h.ok(names.has("mcp_toolkit/limits/script_read_cap_kb"),
			"collector includes script_read_cap_kb")
	_h.ok(names.has("mcp_toolkit/status"), "collector includes status")
	_h.ok(names.has("mcp_toolkit/internal/bootstrap_complete"),
			"collector includes internal/bootstrap_complete")
	# An unrelated engine key is NOT swept by the mcp_toolkit/ prefix.
	_h.ok(not names.has("application/config/name"),
			"collector excludes unrelated engine key (application/config/name)")
	print("")
