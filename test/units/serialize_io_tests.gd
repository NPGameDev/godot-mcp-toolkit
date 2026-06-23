@tool
extends RefCounted
## Serialization + I/O + content-boundary unit tests: Coerce/serialize round-trip,
## color_from_dict (white + black defaults), node-sourced Packed property serialize,
## save.read / script.read paging, export-strip warning set, log-level continuation,
## and the SettingsRegistration mcp_toolkit/* collector. Exercises the
## serialize/IO/content subsystems' pure logic headless.

const Coerce := preload("res://addons/godot_mcp_toolkit/contract/coerce.gd")
const ThemeCommands := preload("res://addons/godot_mcp_toolkit/commands/theme_commands.gd")
const SaveCommands := preload("res://addons/godot_mcp_toolkit/commands/save_commands.gd")
const ScriptCommands := preload("res://addons/godot_mcp_toolkit/commands/script_commands.gd")
const ExportStrip := preload("res://addons/godot_mcp_toolkit/core/export_strip.gd")
const LogHelpers := preload("res://addons/godot_mcp_toolkit/logging/log_helpers.gd")
const SettingsRegistration := preload("res://addons/godot_mcp_toolkit/core/settings_registration.gd")


static func run(h) -> void:
	_test_coerce_roundtrip(h)
	_test_color_from_dict(h)
	_test_color_from_dict_opaque(h)
	_test_node_packed_property_serialize(h)
	_test_save_read_paging(h)
	_test_script_read_paging(h)
	_test_export_strip(h)
	_test_log_level_continuation(h)
	_test_settings_collect_names(h)


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

static func _test_coerce_roundtrip(h) -> void:
	h.begin("Coerce/serialize round-trip (concern 018)")

	# Tagged-dict value types: coerce_value(serialize_value(V)) == V (both legs).
	var vec2: Vector2 = Vector2(3.5, -2.0)
	h.ok(Coerce.coerce_value(Coerce.serialize_value(vec2)) == vec2, "Vector2 round-trips")
	var vec3: Vector3 = Vector3(1.0, 2.0, -3.5)
	h.ok(Coerce.coerce_value(Coerce.serialize_value(vec3)) == vec3, "Vector3 round-trips")
	var vec4: Vector4 = Vector4(1.0, 2.0, 3.0, 4.0)
	h.ok(Coerce.coerce_value(Coerce.serialize_value(vec4)) == vec4, "Vector4 round-trips")
	var vec2i: Vector2i = Vector2i(7, -8)
	h.ok(Coerce.coerce_value(Coerce.serialize_value(vec2i)) == vec2i, "Vector2i round-trips")
	var vec3i: Vector3i = Vector3i(-1, 2, 9)
	h.ok(Coerce.coerce_value(Coerce.serialize_value(vec3i)) == vec3i, "Vector3i round-trips")
	var col: Color = Color(0.25, 0.5, 0.75, 1.0)
	h.ok(Coerce.coerce_value(Coerce.serialize_value(col)) == col, "Color round-trips")
	var rect2: Rect2 = Rect2(1.0, 2.0, 3.0, 4.0)
	h.ok(Coerce.coerce_value(Coerce.serialize_value(rect2)) == rect2, "Rect2 round-trips")
	var rect2i: Rect2i = Rect2i(5, 6, 7, 8)
	h.ok(Coerce.coerce_value(Coerce.serialize_value(rect2i)) == rect2i, "Rect2i round-trips")
	var xform2d: Transform2D = Transform2D(Vector2(0.0, 1.0), Vector2(-1.0, 0.0), Vector2(5.0, 6.0))
	h.ok(Coerce.coerce_value(Coerce.serialize_value(xform2d)) == xform2d, "Transform2D round-trips")
	var basis: Basis = Basis(Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.0, 0.0))
	var xform3d: Transform3D = Transform3D(basis, Vector3(7.0, 8.0, 9.0))
	h.ok(Coerce.coerce_value(Coerce.serialize_value(xform3d)) == xform3d, "Transform3D round-trips")
	var npath: NodePath = NodePath("Player/Sprite2D:position")
	h.ok(Coerce.coerce_value(Coerce.serialize_value(npath)) == npath, "NodePath round-trips")

	# Coerce leg: assert coerce_value parses the EXACT documented tagged wire form
	# (JSON→Godot). For Packed* this complements the symmetric round-trip below — it
	# pins the wire shape itself, not just coerce∘serialize self-consistency.
	# LayerMask is coerce-only by design (see header).
	var pv2: Variant = Coerce.coerce_value({
		"type": "PackedVector2Array",
		"values": [{"type": "Vector2", "x": 1.0, "y": 2.0}, {"type": "Vector2", "x": 3.0, "y": 4.0}],
	})
	h.ok(pv2 == PackedVector2Array([Vector2(1.0, 2.0), Vector2(3.0, 4.0)]),
			"PackedVector2Array coerces from the documented tagged form")
	var pv3: Variant = Coerce.coerce_value({
		"type": "PackedVector3Array",
		"values": [{"type": "Vector3", "x": 1.0, "y": 2.0, "z": 3.0}],
	})
	h.ok(pv3 == PackedVector3Array([Vector3(1.0, 2.0, 3.0)]),
			"PackedVector3Array coerces from the documented tagged form")
	var pcol: Variant = Coerce.coerce_value({
		"type": "PackedColorArray",
		"values": [{"type": "Color", "r": 1.0, "g": 0.0, "b": 0.0, "a": 1.0}],
	})
	h.ok(pcol == PackedColorArray([Color(1.0, 0.0, 0.0, 1.0)]),
			"PackedColorArray coerces from the documented tagged form")
	# LayerMask: numeric layers 1 and 3 → bits 0 and 2 → 0b101 = 5 (no ProjectSettings).
	var mask: Variant = Coerce.coerce_value({"type": "LayerMask", "layers": [1, 3]})
	h.eq(mask, 5, "LayerMask coerces layers [1,3] → bitmask 5 (coerce-only tag)")

	# Concern 053: serialize_value now emits the tagged Packed* form (was a
	# var_to_str string), so the Packed* tags are bidirectionally symmetric.
	# Assert the full native round-trip coerce_value(serialize_value(V)) == V.
	var pv2_native: PackedVector2Array = PackedVector2Array([Vector2(1.0, 2.0), Vector2(-3.5, 4.0)])
	h.ok(Coerce.coerce_value(Coerce.serialize_value(pv2_native)) == pv2_native,
			"PackedVector2Array round-trips (now symmetric)")
	var pv3_native: PackedVector3Array = PackedVector3Array([Vector3(1.0, 2.0, 3.0), Vector3(-4.0, 5.5, 6.0)])
	h.ok(Coerce.coerce_value(Coerce.serialize_value(pv3_native)) == pv3_native,
			"PackedVector3Array round-trips (now symmetric)")
	var pcol_native: PackedColorArray = PackedColorArray([Color(1.0, 0.0, 0.0, 1.0), Color(0.25, 0.5, 0.75, 0.5)])
	h.ok(Coerce.coerce_value(Coerce.serialize_value(pcol_native)) == pcol_native,
			"PackedColorArray round-trips (now symmetric)")

	print("")


# --- color_from_dict white-default projection -----------------------------
# Pins both default behaviours of Coerce.color_from_dict so neither the
# white-default (modulate/tint) family nor the override path drifts after the
# 3d/particle/procedural/tileset sites were routed through this one helper.
static func _test_color_from_dict(h) -> void:
	h.begin("Coerce.color_from_dict white-default projection")

	# Full {r,g,b,a} dict → exact Color, no defaulting.
	h.eq(Coerce.color_from_dict({"r": 0.25, "g": 0.5, "b": 0.75, "a": 0.5}),
			Color(0.25, 0.5, 0.75, 0.5), "full {r,g,b,a} → exact Color")
	# Missing channels fall to opaque-white (1.0) — alpha included.
	h.eq(Coerce.color_from_dict({"r": 1.0, "g": 0.0, "b": 0.0}),
			Color(1.0, 0.0, 0.0, 1.0), "missing alpha → opaque (a defaults 1.0)")
	# Empty dict → all channels default 1.0 → opaque white.
	h.eq(Coerce.color_from_dict({}), Color(1.0, 1.0, 1.0, 1.0),
			"empty dict → opaque white via channel defaults")
	# Non-dict, no override → the white default.
	h.eq(Coerce.color_from_dict(null), Color(1.0, 1.0, 1.0, 1.0),
			"non-dict → white default")
	h.eq(Coerce.color_from_dict("not a dict"), Color(1.0, 1.0, 1.0, 1.0),
			"non-dict string → white default")
	# default override governs the non-dict case only.
	h.eq(Coerce.color_from_dict(null, Color.BLACK), Color(0.0, 0.0, 0.0, 1.0),
			"non-dict + BLACK override → black default")
	# A dict still channel-defaults to white even when an override is passed
	# (override is the non-dict fallback, not a per-channel source).
	h.eq(Coerce.color_from_dict({"r": 0.5}, Color.BLACK), Color(0.5, 1.0, 1.0, 1.0),
			"dict ignores override; channels stay opaque white")

	print("")


# --- _color_from_dict_opaque black-default projection ---------------------
# Pins the paint/opaque-BLACK channel defaults of theme_commands'
# _color_from_dict_opaque (r/g/b default 0.0, a defaults 1.0) — the sibling of
# Coerce.color_from_dict's opaque-WHITE defaults. The partial-dict case is the
# decisive contrast: a missing g/b must stay 0.0 here, NOT 1.0 (that is the tint
# helper), so the two paint/tint facts never drift together.
static func _test_color_from_dict_opaque(h) -> void:
	h.begin("theme _color_from_dict_opaque black-default projection")

	# Partial dict: missing g/b default 0.0 (the contrast vs the white helper).
	h.eq(ThemeCommands._color_from_dict_opaque({"r": 0.5}), Color(0.5, 0, 0, 1),
			"partial {r} → missing g/b default 0.0 (paint, not tint)")
	# Full {r,g,b,a} dict → exact Color, no defaulting.
	h.eq(ThemeCommands._color_from_dict_opaque({"r": 0.25, "g": 0.5, "b": 0.75, "a": 0.5}),
			Color(0.25, 0.5, 0.75, 0.5), "full {r,g,b,a} → exact Color")
	# Non-dict → opaque black.
	h.eq(ThemeCommands._color_from_dict_opaque(null), Color(0, 0, 0, 1),
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
static func _test_node_packed_property_serialize(h) -> void:
	h.begin("node-sourced Packed property serialises tagged (concern 053)")

	var line := Line2D.new()
	var written: PackedVector2Array = PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(100.0, 50.0), Vector2(200.0, 0.0)])
	line.points = written

	# Read the property the way the handler does (node.get(...) → Variant), then
	# serialise it the way node.get_property does (Coerce.serialize_value).
	var read_value: Variant = line.get("points")
	h.eq(typeof(read_value), TYPE_PACKED_VECTOR2_ARRAY,
			"Line2D.points reads back as a PackedVector2Array")

	var serialised: Variant = Coerce.serialize_value(read_value)
	# The contract: a tagged Dictionary, NOT a var_to_str String (the 053 fix).
	h.eq(typeof(serialised), TYPE_DICTIONARY,
			"serialised node Packed value is a Dictionary, not a String (concern 053)")
	var serialised_dict: Dictionary = serialised
	h.eq(str(serialised_dict.get("type", "")), "PackedVector2Array",
			"serialised form carries type tag 'PackedVector2Array' (not a var_to_str string)")
	var values_field: Variant = serialised_dict.get("values", null)
	h.eq(typeof(values_field), TYPE_ARRAY, "serialised form has a 'values' array")

	# Read-form must round-trip back to the written value (read==write for the LLM).
	var restored: Variant = Coerce.coerce_value(serialised)
	h.ok(restored == written,
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

static func _test_save_read_paging(h) -> void:
	h.begin("save.read cap + offset paging (concern 025)")

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
	h.ok(wf != null, "fixture file opened for write")
	if wf != null:
		wf.store_string(body)
		wf.close()

	# Default cap (256 KB) for the paging assertions.
	ProjectSettings.set_setting("mcp_toolkit/limits/save_read_cap_kb", 256)
	ProjectSettings.set_setting("mcp_toolkit/limits/ws_buffer_kb", 1024)

	# 1. First window: offset 0, max_bytes 400 → 400 bytes, next_offset 400,
	#    truncated true (600 remain), total_bytes 1000.
	var p1: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": 400})
	h.ok(p1.get("success", false), "window 1 → success")
	h.eq(p1.get("bytes_returned", -1), 400, "window 1 → 400 bytes returned")
	h.eq(p1.get("offset", -1), 0, "window 1 → offset 0 echoed")
	h.eq(p1.get("next_offset", -1), 400, "window 1 → next_offset 400")
	h.eq(p1.get("total_bytes", -1), 1000, "window 1 → total_bytes 1000")
	h.eq(p1.get("truncated", null), true, "window 1 → truncated true (more remains)")
	# Uniform pagination contract (concern 054): truncated window carries a prose
	# hint naming next_offset; not-truncated windows omit it (asserted below).
	h.ok(p1.has("hint"), "window 1 → hint present (truncated)")
	h.ok(str(p1.get("hint", "")).contains("next_offset"), "window 1 → hint names next_offset")

	# 2. Middle window: seek correctness — offset 400, max_bytes 400 → next_offset
	#    800, still truncated.
	var p2: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "offset": 400, "max_bytes": 400})
	h.eq(p2.get("bytes_returned", -1), 400, "window 2 → 400 bytes returned")
	h.eq(p2.get("offset", -1), 400, "window 2 → offset 400 echoed")
	h.eq(p2.get("next_offset", -1), 800, "window 2 → next_offset 800")
	h.eq(p2.get("truncated", null), true, "window 2 → still truncated")

	# 3. Final window: offset 800 → only 200 bytes left; next_offset reaches EOF,
	#    truncated false. Pins next_offset arithmetic = offset + bytes_returned.
	var p3: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "offset": 800, "max_bytes": 400})
	h.eq(p3.get("bytes_returned", -1), 200, "window 3 → 200 bytes (clamped to remaining)")
	h.eq(p3.get("next_offset", -1), 1000, "window 3 → next_offset 1000 (== total)")
	h.eq(p3.get("truncated", null), false, "window 3 → truncated false (reached EOF)")
	h.ok(not p3.has("hint"), "window 3 → no hint (not truncated)")

	# 4. Offset exactly AT EOF → 0 bytes, not an error; next_offset == total,
	#    truncated false (graceful completion sentinel for a paging caller).
	var p_eof: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "offset": 1000})
	h.ok(p_eof.get("success", false), "offset == EOF → success (not an error)")
	h.eq(p_eof.get("bytes_returned", -1), 0, "offset == EOF → 0 bytes")
	h.eq(p_eof.get("next_offset", -1), 1000, "offset == EOF → next_offset == total")
	h.eq(p_eof.get("truncated", null), false, "offset == EOF → truncated false")

	# 5. Offset PAST EOF → still graceful: 0 bytes, no error.
	var p_past: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "offset": 99999})
	h.ok(p_past.get("success", false), "offset past EOF → success (not an error)")
	h.eq(p_past.get("bytes_returned", -1), 0, "offset past EOF → 0 bytes")
	h.eq(p_past.get("truncated", null), false, "offset past EOF → truncated false")

	# 6. Negative offset → INVALID_PARAMS.
	var p_neg: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "offset": -1})
	h.eq(p_neg.get("success", null), false, "negative offset → rejected")
	h.eq(str(p_neg.get("code", "")), "INVALID_PARAMS", "negative offset → INVALID_PARAMS")

	# 7. Cap clamp — at the default 256 KB cap, max_bytes one past the cap is
	#    rejected; exactly at the cap is accepted (the 256 KB default == the former
	#    hardcoded ceiling, so default behaviour is unchanged).
	var at_cap := 262144
	var over_cap: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": at_cap + 1})
	h.eq(over_cap.get("success", null), false, "max_bytes cap+1 → rejected")
	h.eq(str(over_cap.get("code", "")), "INVALID_PARAMS", "max_bytes cap+1 → INVALID_PARAMS")
	var at_cap_ok: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": at_cap})
	h.ok(at_cap_ok.get("success", false), "max_bytes == cap → accepted")

	# 8. Cap is configurable upward: raise to 512 KB → a max_bytes of 300 KB
	#    (rejected at the default) is now accepted.
	ProjectSettings.set_setting("mcp_toolkit/limits/save_read_cap_kb", 512)
	var raised: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": 300 * 1024})
	h.ok(raised.get("success", false), "raised cap 512 KB → 300 KB max_bytes accepted")

	# 9. Cap floor — a sub-minimum cap setting (32) is floored to 64 KB, so a
	#    max_bytes above 64 KB but below the raw setting is rejected at the floor.
	ProjectSettings.set_setting("mcp_toolkit/limits/save_read_cap_kb", 32)
	var floored: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": 100 * 1024})
	h.eq(floored.get("success", null), false, "cap 32 floored to 64 KB → 100 KB max_bytes rejected")
	var floored_ok: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": 64 * 1024})
	h.ok(floored_ok.get("success", false), "cap 32 floored to 64 KB → 64 KB max_bytes accepted")

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
	h.eq(too_large.get("success", null), false, "oversized window → rejected")
	h.eq(str(too_large.get("code", "")), "FILE_TOO_LARGE", "oversized window → FILE_TOO_LARGE")
	h.ok(too_large.has("total_bytes"), "FILE_TOO_LARGE → carries total_bytes")
	h.ok(str(too_large.get("hint", "")).contains("offset"),
			"FILE_TOO_LARGE → hint mentions offset paging")
	# A small window of the SAME big file fits and succeeds (guard is per-window,
	# not per-file).
	var small_window: Dictionary = SaveCommands._cmd_save_read({"path": big_rel, "max_bytes": 100 * 1024})
	h.ok(small_window.get("success", false), "small window of the big file → fits, succeeds")

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

static func _test_script_read_paging(h) -> void:
	h.begin("script.read pagination contract (concern 054)")

	# A deterministic 5-line fixture (no trailing newline → split("\n") size 5).
	var fixture := "res://sv2_script_read_054.gd"
	var sf := FileAccess.open(fixture, FileAccess.WRITE)
	h.ok(sf != null, "fixture script opened for write")
	if sf != null:
		sf.store_string("line1\nline2\nline3\nline4\nline5")
		sf.close()

	# 1. Windowed read that ENDS BEFORE EOF (lines 1..2 of 5) → truncated true,
	#    next_start_line 3, hint naming next_start_line. total_lines preserved.
	var w: Dictionary = ScriptCommands._cmd_script_read({"file_path": fixture, "start_line": 1, "end_line": 2})
	h.ok(w.get("success", false), "window 1..2 → success")
	h.eq(w.get("start_line", -1), 1, "window → start_line 1 preserved")
	h.eq(w.get("end_line", -1), 2, "window → end_line 2 preserved")
	h.eq(w.get("total_lines", -1), 5, "window → total_lines 5 preserved")
	h.eq(w.get("truncated", null), true, "window 1..2 → truncated true (2 < 5)")
	h.eq(w.get("next_start_line", -1), 3, "window → next_start_line = end_line + 1 = 3 (1-based)")
	h.ok(str(w.get("hint", "")).contains("next_start_line"), "window → hint names next_start_line")

	# 2. Windowed read that REACHES EOF (lines 3..5; end clamps to 5) → truncated
	#    false, no next_start_line, no hint.
	var eofw: Dictionary = ScriptCommands._cmd_script_read({"file_path": fixture, "start_line": 3, "end_line": 999})
	h.eq(eofw.get("end_line", -1), 5, "window 3..999 → end_line clamped to 5")
	h.eq(eofw.get("truncated", null), false, "window reaching EOF → truncated false")
	h.ok(not eofw.has("next_start_line"), "window at EOF → no next_start_line")
	h.ok(not eofw.has("hint"), "window at EOF → no hint")

	# 3. FULL read (no start_line) → truncated false + total_lines, contract-complete.
	#    Existing 'content' field is still present (additive change).
	var full: Dictionary = ScriptCommands._cmd_script_read({"file_path": fixture})
	h.ok(full.get("success", false), "full read → success")
	h.ok(full.has("content"), "full read → content preserved")
	h.eq(full.get("total_lines", -1), 5, "full read → total_lines 5 (added for uniformity)")
	h.eq(full.get("truncated", null), false, "full read → truncated false")
	h.ok(not full.has("next_start_line"), "full read → no next_start_line")
	h.ok(not full.has("hint"), "full read → no hint")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(fixture))
	print("")


# --- Export strip + binary-token warning set (~7 strip + 22 warning) --------

static func _test_export_strip(h) -> void:
	h.begin("Export strip set")

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
	h.ok(strip.has("res://a/direct.gd"), "direct subclass → stripped")
	h.ok(strip.has("res://e/path_direct.gd"), "path-flattened direct subclass → stripped")

	# Multi-level (base is an intermediate, not MCPToolkitExtension) → NOT stripped
	# (single-level by design; such files ship as harmless orphans).
	h.ok(not strip.has("res://b/child.gd"), "multi-level child → NOT stripped (single-level)")

	# Unrelated game class → not stripped.
	h.ok(not strip.has("res://g/game.gd"), "unrelated game class → not stripped")

	# .cs excluded by the .gd guard even if its base matched (C# can't be stripped).
	h.ok(not strip.has("res://c/weird.cs"), ".cs excluded by .gd guard")

	# Base class itself (base RefCounted) → not matched; prefix-stripped at runtime.
	h.ok(not strip.has("res://addons/godot_mcp_toolkit/extensions/mcp_toolkit_extension.gd"),
			"base class itself → not matched (prefix-stripped at runtime)")

	# Exact base match → no false positive from a coincidentally MCPToolkit*-named
	# class (FakeChild's base is "MCPToolkitFake", not "MCPToolkitExtension").
	h.ok(not strip.has("res://f/fakechild.gd"),
			"subclass of coincidentally-named MCPToolkit* class → not stripped")

	# ── Binary-token leak warning (Q6) — pure _decide_warning decision ──────
	# args: (saw_addon_script, saw_addon_nonscript, extension_strip_paths, seen_ext)

	# No leak: text mode / 4.2 → addon scripts AND non-scripts reached us; no exts.
	var d_clean: Dictionary = ExportStrip._decide_warning(true, true, {}, {})
	h.ok(not d_clean["warn"], "all addon files seen (text mode) → no warning")

	# Addon-only leak (binary mode, no extensions): non-scripts seen, scripts gone.
	var d_addon: Dictionary = ExportStrip._decide_warning(false, true, {}, {})
	h.ok(d_addon["warn"], "addon non-script seen but no script → warn")
	h.ok(d_addon["addon_leaked"], "addon-only leak → addon_leaked true")
	h.ok(int(d_addon["leaked_ext_count"]) == 0, "addon-only leak → 0 extensions")
	h.ok(str(d_addon["message"]).find("Godot MCP Toolkit addon") >= 0, "addon message names the addon")
	# Tail always says "extension path"; the subject clause "N extension script(s)" must be absent.
	h.ok(str(d_addon["message"]).find("extension script") < 0, "addon-only message omits extension clause")

	# Both leak (binary mode, 1 extension): addon + one unseen extension path.
	var d_both: Dictionary = ExportStrip._decide_warning(false, true, {"res://x/ext.gd": true}, {})
	h.ok(d_both["warn"], "addon + unseen extension → warn")
	h.ok(int(d_both["leaked_ext_count"]) == 1, "1 unseen extension counted")
	h.ok(str(d_both["message"]).find("addon and 1 extension script(s)") >= 0, "message joins addon + 1 extension")
	# REGRESSION: the recipe must list the addon glob AND the explicit extension path.
	h.ok(str(d_both["message"]).find("res://addons/godot_mcp_toolkit/*") >= 0, "message includes the addon exclude glob")
	h.ok(str(d_both["message"]).find("res://x/ext.gd") >= 0, "message lists the leaked extension path explicitly")

	# Two leaked extensions → BOTH paths listed (comma-join regression guard).
	var d_two: Dictionary = ExportStrip._decide_warning(false, true, {"res://x/a.gd": true, "res://y/b.gd": true}, {})
	h.ok(int(d_two["leaked_ext_count"]) == 2, "2 unseen extensions counted")
	h.ok(d_two["leaked_ext_paths"].size() == 2, "leaked_ext_paths populated")
	h.ok(str(d_two["message"]).find("2 extension script(s)") >= 0, "subject reports 2 extensions")
	h.ok(str(d_two["message"]).find("res://x/a.gd") >= 0 and str(d_two["message"]).find("res://y/b.gd") >= 0, "both extension paths listed")

	# Q6 guard: addon already excluded by the user → NO addon file reaches us.
	var d_excluded: Dictionary = ExportStrip._decide_warning(false, false, {}, {})
	h.ok(not d_excluded["warn"], "addon excluded (no non-script seen) → no false-positive warning")

	# Extension-only leak: addon excluded but an extension still shipped as .gdc.
	var d_ext: Dictionary = ExportStrip._decide_warning(false, false, {"res://x/ext.gd": true}, {})
	h.ok(d_ext["warn"], "unseen extension alone → warn")
	h.ok(not d_ext["addon_leaked"], "extension-only leak → addon_leaked false")
	h.ok(str(d_ext["message"]).find("1 extension script(s)") >= 0, "extension-only message names the extension")
	h.ok(str(d_ext["message"]).find("res://x/ext.gd") >= 0, "extension-only message lists the path explicitly")
	# Addon not leaked → neither the addon subject phrase nor the addon glob appears.
	h.ok(str(d_ext["message"]).find("Godot MCP Toolkit addon") < 0, "extension-only message omits addon clause")
	h.ok(str(d_ext["message"]).find("res://addons/godot_mcp_toolkit/*") < 0, "extension-only message omits addon glob")

	# Extension seen (text mode for the extension) → not counted as leaked.
	var d_ext_seen: Dictionary = ExportStrip._decide_warning(true, true, {"res://x/ext.gd": true}, {"res://x/ext.gd": true})
	h.ok(not d_ext_seen["warn"], "extension seen (stripped) → no warning")

	print("")


# --- Log level + continuation leveling (~14 assertions) -------------------
# A2/A3 (41m-ter): editor parse errors on Godot 4.2-4.4 log as TWO lines —
# "SCRIPT ERROR: …" then "   at: <script>.gd:LINE" — and the script path is on the
# continuation line. LogHelpers.is_continuation_line lets the file-tail buffer
# (log_buffer.gd) and the source=file reader (editor_commands.gd) keep such a line at
# the preceding error/warning level instead of "info", so a filename+level=error query
# finds it. _level_sequence mirrors that loop using the shared primitives under test.

static func _level_sequence(lines: Array) -> Array:
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


static func _test_log_level_continuation(h) -> void:
	h.begin("Log level + continuation leveling")

	# detect_log_level prefixes (SHADER ERROR: is the new one)
	h.eq(LogHelpers.detect_log_level("ERROR: boom"), "error", "ERROR: → error")
	h.eq(LogHelpers.detect_log_level("SCRIPT ERROR: Parse Error: x"), "error", "SCRIPT ERROR: → error")
	h.eq(LogHelpers.detect_log_level("SHADER ERROR: bad shader"), "error", "SHADER ERROR: → error (added)")
	h.eq(LogHelpers.detect_log_level("WARNING: meh"), "warning", "WARNING: → warning")
	h.eq(LogHelpers.detect_log_level("just a message"), "info", "plain → info")
	h.eq(LogHelpers.detect_log_level("at: GDScript::reload (res://x.gd:1)"), "info",
		"stripped at: line alone → info (no prefix)")

	# is_continuation_line — pass RAW (un-edge-stripped) lines so indentation is visible
	h.ok(LogHelpers.is_continuation_line("   at: GDScript::reload (res://x.gd:1)"),
		"indented 'at:' → continuation")
	h.ok(LogHelpers.is_continuation_line("at: foo (bar:2)"), "bare 'at:' → continuation")
	h.ok(LogHelpers.is_continuation_line("\ttab indented"), "tab-indented → continuation")
	h.ok(not LogHelpers.is_continuation_line("SCRIPT ERROR: x"), "error line → not continuation")
	h.ok(not LogHelpers.is_continuation_line("plain message"), "plain line → not continuation")

	# Sequence: the exact Godot 4.2 parse-error shape → both lines error-leveled.
	var parse_err := [
		'SCRIPT ERROR: Parse Error: Could not find base class "BogusHitClass".',
		'   at: GDScript::reload (res://smoke_txtflt_hit.gd:1)',
	]
	h.eq(_level_sequence(parse_err), ["error", "error"],
		"4.2 parse error: SCRIPT ERROR: + at: both → error")
	h.eq(_level_sequence(["WARNING: w", "   at: foo (x:1)"]), ["warning", "warning"],
		"warning + at: both → warning")
	h.eq(_level_sequence(["a plain info line", "   at: stray (x:1)"]), ["info", "info"],
		"info + at: → info (no spurious error inherit)")


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
static func _test_settings_collect_names(h) -> void:
	h.begin("SettingsRegistration mcp_toolkit/* collector (concern 002)")
	# Establish production's precondition: register_all() runs in the plugin's
	# _enter_tree before unregister_all() is ever reached in _disable_plugin. The
	# headless --script runner doesn't run _enter_tree, so register the keys here
	# so the collector sees the full set. register_all() does NOT call
	# ProjectSettings.save() — purely in-memory, so project.godot is untouched.
	SettingsRegistration.register_all()
	var names := SettingsRegistration._collect_mcp_setting_names()
	# Regression-pin: the exact key the concern's stale hardcoded list missed.
	h.ok(names.has("mcp_toolkit/limits/save_read_cap_kb"),
			"collector includes save_read_cap_kb (the key the stale list missed)")
	h.ok(names.has("mcp_toolkit/limits/script_read_cap_kb"),
			"collector includes script_read_cap_kb")
	h.ok(names.has("mcp_toolkit/status"), "collector includes status")
	h.ok(names.has("mcp_toolkit/internal/bootstrap_complete"),
			"collector includes internal/bootstrap_complete")
	# An unrelated engine key is NOT swept by the mcp_toolkit/ prefix.
	h.ok(not names.has("application/config/name"),
			"collector excludes unrelated engine key (application/config/name)")
	print("")
