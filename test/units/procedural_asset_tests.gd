@tool
extends RefCounted
## Procedural/asset command unit tests: scene.spatial_map geometry, texture.generate
## pixels+colour, particles _apply_props / _merge_overrides, sound.generate synthesis,
## tileset.edit_* key enforcement, tileset_io full-tile polygon, and the
## resolve_create_collision decision. Exercises the procedural/asset commands' pure logic.

const SpatialCommands := preload("res://addons/godot_mcp_toolkit/commands/spatial_commands.gd")
const TextureCommands := preload("res://addons/godot_mcp_toolkit/commands/texture_commands.gd")
const ParticleCommands := preload("res://addons/godot_mcp_toolkit/commands/particle_commands.gd")
const SoundCommands := preload("res://addons/godot_mcp_toolkit/commands/sound_commands.gd")
const TilesetTileData := preload("res://addons/godot_mcp_toolkit/commands/tileset/tileset_tile_data.gd")
const TilesetIo := preload("res://addons/godot_mcp_toolkit/commands/tileset/tileset_io.gd")
const Helpers := preload("res://addons/godot_mcp_toolkit/commands/editor_helpers.gd")


static func run(testing) -> void:
	_test_spatial_map(testing)
	_test_texture_generate(testing)
	_test_particle_prop_apply(testing)
	_test_particle_merge_overrides(testing)
	_test_sound_generate(testing)
	_test_tileset_edit_key_enforcement(testing)
	_test_tileset_io_polygon(testing)
	_test_create_collision_resolver(testing)


# --- scene.spatial_map geometry --------------------------------------------
static func _test_spatial_map(testing) -> void:
	testing.begin("scene.spatial_map (geometry)")

	# _world_bounds dispatch by node type. Nodes stay parentless so global ==
	# local transform (headless has no initialised World3D for a tree-parented
	# Node3D; real tree behaviour is covered by interactive smoke/sweep).
	var n3 := Node3D.new()
	n3.position = Vector3(1, 2, 3)
	var b3 = SpatialCommands._world_bounds(n3)
	testing.ok(typeof(b3) == TYPE_AABB, "Node3D → AABB")
	testing.ok(b3.size == Vector3.ZERO, "Node3D → point AABB (zero size; world pos via interactive)")
	n3.free()

	var n2 := Node2D.new()
	n2.position = Vector2(5, 6)
	var b2 = SpatialCommands._world_bounds(n2)
	testing.ok(typeof(b2) == TYPE_RECT2, "Node2D → Rect2")
	testing.ok(b2.position == Vector2(5, 6), "Node2D Rect2 at global_position")
	n2.free()

	var ctrl := Control.new()
	ctrl.position = Vector2(10, 10)
	ctrl.size = Vector2(20, 30)
	var bc = SpatialCommands._world_bounds(ctrl)
	testing.ok(typeof(bc) == TYPE_RECT2, "Control → Rect2")
	testing.ok(bc.size == Vector2(20, 30), "Control Rect2 size from get_global_rect")
	ctrl.free()

	var plain := Node.new()
	testing.ok(SpatialCommands._world_bounds(plain) == null, "plain Node → null (non-spatial)")
	plain.free()

	# _xform_rect2 / _xform_aabb world-space transform.
	testing.ok(SpatialCommands._xform_rect2(Transform2D.IDENTITY, Rect2(0, 0, 10, 10)) == Rect2(0, 0, 10, 10),
		"_xform_rect2 identity → same")
	var rt = SpatialCommands._xform_rect2(Transform2D(0.0, Vector2(5, 5)), Rect2(0, 0, 10, 10))
	testing.ok(rt.position == Vector2(5, 5) and rt.size == Vector2(10, 10), "_xform_rect2 translate")
	testing.ok(SpatialCommands._xform_aabb(Transform3D.IDENTITY, AABB(Vector3.ZERO, Vector3(2, 2, 2)))
		== AABB(Vector3.ZERO, Vector3(2, 2, 2)), "_xform_aabb identity → same")

	# _compute_relations: overlap + containment + nearest (full).
	var entries := [
		{"path": "a", "bounds": Rect2(0, 0, 10, 10)},
		{"path": "b", "bounds": Rect2(5, 5, 10, 10)},
		{"path": "c", "bounds": Rect2(100, 100, 5, 5)},
		{"path": "d", "bounds": Rect2(2, 2, 3, 3)},
	]
	SpatialCommands._compute_relations(entries, "full")
	testing.ok(entries[0]["overlaps"].has("b"), "overlap a-b detected")
	testing.ok(not entries[0]["overlaps"].has("c"), "no overlap a-c (disjoint)")
	testing.ok(entries[0]["contains"].has("d"), "containment a contains d")
	testing.ok(entries[3]["contained_by"].has("a"), "containment d contained_by a")
	testing.ok(entries[0].has("nearest"), "nearest neighbour computed (full)")

	# 2D and 3D never relate.
	var mixed := [
		{"path": "p2", "bounds": Rect2(0, 0, 10, 10)},
		{"path": "p3", "bounds": AABB(Vector3.ZERO, Vector3(10, 10, 10))},
	]
	SpatialCommands._compute_relations(mixed, "normal")
	testing.ok(mixed[0]["overlaps"].is_empty(), "2D node never overlaps 3D node")

	# Region parsing + filtering.
	testing.ok(typeof(SpatialCommands._parse_region([0, 0, 10, 10])) == TYPE_RECT2, "_parse_region 4 nums → Rect2")
	testing.ok(typeof(SpatialCommands._parse_region([0, 0, 0, 1, 1, 1])) == TYPE_AABB, "_parse_region 6 nums → AABB")
	testing.ok(SpatialCommands._parse_region([1, 2, 3]).has("error"), "_parse_region bad size → error")
	testing.ok(SpatialCommands._parse_region(null) == null, "_parse_region null → null")
	testing.ok(SpatialCommands._passes_filters(Rect2(0, 0, 5, 5), Rect2(0, 0, 10, 10), null),
		"region: 2D node inside → pass")
	testing.ok(not SpatialCommands._passes_filters(Rect2(0, 0, 5, 5), AABB(Vector3.ZERO, Vector3.ONE), null),
		"region: 3D region excludes 2D node")

	# Serialization.
	testing.eq(SpatialCommands._vec_to_array(Vector2(1, 2)), [1.0, 2.0], "_vec_to_array Vector2")
	testing.eq(SpatialCommands._vec_to_array(Vector3(1, 2, 3)), [1.0, 2.0, 3.0], "_vec_to_array Vector3")


# --- texture.generate pixels + colour --------------------------------------
static func _test_texture_generate(testing) -> void:
	testing.begin("texture.generate (pixels + colour)")

	# _parse_color (hex / named, 0-1 vs 0-255 arrays, alpha-absent).
	testing.ok(TextureCommands._parse_color(null, Color(0.5, 0.5, 0.5, 1)) == Color(0.5, 0.5, 0.5, 1),
		"_parse_color null → default")
	var c_hex = TextureCommands._parse_color("#ff0000", Color.BLACK)
	testing.ok(c_hex.r > 0.99 and c_hex.g < 0.01 and c_hex.b < 0.01, "_parse_color #ff0000 → red")
	testing.ok(TextureCommands._parse_color([0, 255, 0], Color.BLACK).g > 0.99, "_parse_color [0,255,0] → green (0-255)")
	testing.ok(TextureCommands._parse_color([0, 0, 1], Color.BLACK).b > 0.99, "_parse_color [0,0,1] → blue (0-1)")
	testing.ok(TextureCommands._parse_color([0, 0, 0, 0], Color.WHITE).a == 0.0,
		"_parse_color [0,0,0,0] → transparent (alpha-absent)")

	# _in_shape inside/outside.
	testing.ok(TextureCommands._in_shape("solid", 8, 8, 16, 16, "up", 0), "solid: center inside")
	testing.ok(TextureCommands._in_shape("circle", 8, 8, 16, 16, "up", 0), "circle: center inside")
	testing.ok(not TextureCommands._in_shape("circle", 0, 0, 16, 16, "up", 0), "circle: corner outside")
	testing.ok(TextureCommands._in_shape("diamond", 8, 8, 16, 16, "up", 0), "diamond: center inside")
	testing.ok(not TextureCommands._in_shape("diamond", 0, 0, 16, 16, "up", 0), "diamond: corner outside")
	testing.ok(TextureCommands._in_shape("triangle", 8, 14, 16, 16, "up", 0), "triangle(up): bottom-center inside")
	testing.ok(not TextureCommands._in_shape("triangle", 1, 1, 16, 16, "up", 0), "triangle(up): top-corner outside")

	var red := Color(1, 0, 0, 1)
	var blue := Color(0, 0, 1, 1)
	var clear := Color(0, 0, 0, 0)

	# Solid fill covers everything.
	var solid := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	solid.fill(clear)
	TextureCommands._draw_shape(solid, "solid", red, clear, 0, clear, 4, "right")
	testing.ok(solid.get_pixel(8, 8) == red, "solid fill: center red")
	testing.ok(solid.get_pixel(0, 0) == red, "solid fill: corner red (covers all)")

	# Circle fill on transparent background.
	var circ := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	circ.fill(clear)
	TextureCommands._draw_shape(circ, "circle", red, clear, 0, clear, 4, "right")
	testing.ok(circ.get_pixel(8, 8) == red, "circle fill: center red")
	testing.ok(circ.get_pixel(0, 0).a == 0.0, "circle: corner transparent (background)")

	# Hollow shape: transparent fill + opaque outline → interior clear, band is outline.
	var hollow := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	hollow.fill(clear)
	TextureCommands._draw_shape(hollow, "solid", clear, blue, 2, clear, 4, "right")
	testing.ok(hollow.get_pixel(0, 0) == blue, "hollow solid: border blue (outline band)")
	testing.ok(hollow.get_pixel(8, 8).a == 0.0, "hollow solid: interior transparent (no fill)")

	# Checkerboard alternates fill / background.
	var checker := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	checker.fill(clear)
	TextureCommands._draw_shape(checker, "checkerboard", red, clear, 0, clear, 8, "right")
	testing.ok(checker.get_pixel(0, 0) == red, "checkerboard: cell (0,0) fill")
	testing.ok(checker.get_pixel(8, 0).a == 0.0, "checkerboard: cell (1,0) background")


# --- particles.create _PROP_SPEC / _apply_props ----------------------------
# Pins the data-driven property applier. The load-bearing contract is the
# RETURNED count (== properties_set delta) plus the exact value + cast landing on
# the node / material. ParticleProcessMaterial and GPUParticles2D are not
# editor-only, so this runs headless.
static func _test_particle_prop_apply(testing) -> void:
	testing.begin("particles _apply_props (_PROP_SPEC)")

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
	testing.eq(n_all, 15, "all 15 props present → count 15")

	# Node group values + casts.
	testing.eq(node_all.amount, 24, "amount float 24.0 → int 24")
	testing.ok(typeof(node_all.amount) == TYPE_INT, "amount cast to int")
	testing.ok(is_equal_approx(node_all.lifetime, 1.5), "lifetime → 1.5")
	testing.ok(is_equal_approx(node_all.explosiveness, 0.5), "explosiveness → 0.5")
	testing.ok(is_equal_approx(node_all.speed_scale, 2.0), "speed_scale → 2.0")
	testing.eq(node_all.one_shot, true, "one_shot int 1 → bool true")
	testing.eq(node_all.local_coords, true, "local_coords → true")

	# Material group values + casts.
	testing.eq(mat_all.direction, dir, "direction → Vector3 (raw assign)")
	testing.ok(is_equal_approx(mat_all.spread, 30.0), "spread int 30 → float 30.0")
	testing.eq(mat_all.gravity, grav, "gravity → Vector3 (raw assign)")
	testing.eq(mat_all.color, col, "color → Color (raw assign)")
	testing.eq(mat_all.particle_flag_align_y, true, "particle_flag_align_y → true")
	testing.ok(is_equal_approx(mat_all.emission_sphere_radius, 12.0), "emission_sphere_radius → 12.0")
	testing.eq(mat_all.emission_box_extents, box, "emission_box_extents → Vector3 (raw assign)")
	testing.eq(mat_all.turbulence_enabled, true, "turbulence_enabled → true")
	testing.ok(is_equal_approx(mat_all.turbulence_noise_strength, 0.75), "turbulence_noise_strength → 0.75")
	node_all.free()

	# --- No props present → count 0, nothing written (props keep defaults).
	var node_none := GPUParticles2D.new()
	var mat_none := ParticleProcessMaterial.new()
	var amount_default := node_none.amount
	var spread_default := mat_none.spread
	testing.eq(ParticleCommands._apply_props(node_none, mat_none, {}), 0, "empty eff → count 0")
	testing.eq(node_none.amount, amount_default, "empty eff → amount untouched")
	testing.eq(mat_none.spread, spread_default, "empty eff → spread untouched")
	node_none.free()

	# --- Subset (1 node + 2 material) → count 3, only those land.
	var node_sub := GPUParticles2D.new()
	var mat_sub := ParticleProcessMaterial.new()
	var n_sub := ParticleCommands._apply_props(node_sub, mat_sub, {
		"lifetime": 3.0,
		"spread": 45.0,
		"turbulence_enabled": true,
	})
	testing.eq(n_sub, 3, "subset of 3 → count 3")
	testing.ok(is_equal_approx(node_sub.lifetime, 3.0), "subset: lifetime landed")
	testing.ok(is_equal_approx(mat_sub.spread, 45.0), "subset: spread landed")
	testing.eq(mat_sub.turbulence_enabled, true, "subset: turbulence_enabled landed")
	# A prop absent from the subset eff must NOT have been counted/written.
	testing.eq(node_sub.amount, node_none.amount, "subset: absent amount stays default")
	node_sub.free()


# --- particles.create _OVERRIDE_SPEC / _merge_overrides --------------------
# Pins the data-driven override merge. The load-bearing contracts are (a) the
# merged eff values + casts and (b) the RETURNED overrides_applied array — its
# CONTENTS and ORDER are part of the particles.create response. Pure dict→dict
# logic, so this runs headless (no node, no editor).
static func _test_particle_merge_overrides(testing) -> void:
	testing.begin("particles _merge_overrides (_OVERRIDE_SPEC)")

	# --- Preset-only (no params) → eff unchanged, overrides empty.
	var fire: Dictionary = ParticleCommands._PRESETS["fire"].duplicate(true)
	var eff_pre: Dictionary = fire.duplicate(true)
	var ov_none := ParticleCommands._merge_overrides(eff_pre, {})
	testing.eq(ov_none.size(), 0, "no params → overrides_applied empty")
	testing.eq(eff_pre, fire, "no params → eff identical to preset")

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
	testing.eq(ov_sub, ["amount", "spread", "initial_velocity"], "shadowing overrides in contract order")
	testing.eq(eff_sub["amount"], 99, "amount float 99.0 → int 99")
	testing.ok(typeof(eff_sub["amount"]) == TYPE_INT, "amount cast to int")
	testing.ok(is_equal_approx(eff_sub["spread"], 5.0), "spread int 5 → float 5.0")
	testing.ok(is_equal_approx(eff_sub["initial_velocity_min"], 1.0), "range min landed")
	testing.ok(is_equal_approx(eff_sub["initial_velocity_max"], 2.0), "range max landed")

	# --- Vector/colour coercion (the merge VEC3/COLOR modes, distinct from apply RAW).
	var eff_vec := {}
	var ov_vec := ParticleCommands._merge_overrides(eff_vec, {
		"direction": {"x": 0.0, "y": -1.0, "z": 0.0},
		"color": {"r": 0.2, "g": 0.4, "b": 0.6, "a": 0.8},
		"gravity": {"x": 0.0, "y": 49.0, "z": 0.0},
	})
	testing.eq(ov_vec.size(), 0, "no preset → vec/colour applied but nothing shadowed")
	testing.eq(eff_vec["direction"], Vector3(0, -1, 0), "direction dict → Vector3")
	testing.eq(eff_vec["color"], Color(0.2, 0.4, 0.6, 0.8), "color dict → Color")
	testing.eq(eff_vec["gravity"], Vector3(0, 49, 0), "gravity dict → Vector3")

	# --- No preset → values written to eff but NONE appended (no shadow); range as
	# a bare scalar fans into _min/_max; an absent key never appears.
	var eff_np := {}
	var ov_np := ParticleCommands._merge_overrides(eff_np, {
		"amount": 7,
		"scale_range": 2.0,  # bare scalar → min == max
	})
	testing.eq(ov_np.size(), 0, "empty eff → nothing shadowed → overrides empty")
	testing.eq(eff_np["amount"], 7, "no-preset: amount still written to eff")
	testing.ok(is_equal_approx(eff_np["scale_min"], 2.0), "scalar range → scale_min")
	testing.ok(is_equal_approx(eff_np["scale_max"], 2.0), "scalar range → scale_max == min")
	testing.ok(not eff_np.has("lifetime"), "absent param never written")

	# --- Cross-sub-pass ORDER pin: simple + range + emission against an eff that
	# holds all three preset keys → array order is [simple, range, emission].
	var eff_ord := {"color": Color.WHITE, "scale_min": 0.5, "emission_shape": "point"}
	var ov_ord := ParticleCommands._merge_overrides(eff_ord, {
		"emission_shape": "box",
		"scale_range": {"min": 1.0, "max": 3.0},
		"color": {"r": 1.0, "g": 0.0, "b": 0.0, "a": 1.0},
	})
	testing.eq(ov_ord, ["color", "scale_range", "emission_shape"], "order: simple → range → emission")
	testing.eq(eff_ord["emission_shape"], "box", "emission_shape override landed (name kept)")


# --- sound.generate synthesis ----------------------------------------------
static func _test_sound_generate(testing) -> void:
	testing.begin("sound.generate (synth)")

	# _oscillator waveforms.
	testing.ok(abs(SoundCommands._oscillator("sine", 0.0)) < 0.001, "sine(0) approx 0")
	testing.ok(SoundCommands._oscillator("sine", PI / 2.0) > 0.99, "sine(pi/2) approx 1")
	testing.ok(SoundCommands._oscillator("square", 0.5) == 1.0, "square(+) = 1")
	testing.ok(SoundCommands._oscillator("square", PI + 0.5) == -1.0, "square(-) = -1")
	testing.ok(SoundCommands._oscillator("sawtooth", 0.0) < -0.99, "sawtooth(0) approx -1")
	testing.ok(SoundCommands._oscillator("triangle", PI / 2.0) > 0.99, "triangle(pi/2) approx 1")

	# _build_pcm length + content (mono 16-bit @ 44100).
	var pcm := SoundCommands._build_pcm("sine", 440.0, 440.0, false, 0.1, 0.8, 0.003, 0.003, 0.0)
	var expected_samples := int(0.1 * 44100)
	testing.eq(pcm.size(), expected_samples * 2, "_build_pcm byte length = samples*2 (16-bit mono)")
	var mid := expected_samples / 2
	var found_nonzero := false
	for i in range(mid, mini(mid + 120, expected_samples)):
		if pcm.decode_s16(i * 2) != 0:
			found_nonzero = true
			break
	testing.ok(found_nonzero, "_build_pcm sine non-silent in sustain")

	# volume 0 → silence.
	var silent := SoundCommands._build_pcm("sine", 440.0, 440.0, false, 0.05, 0.0, 0.0, 0.0, 0.0)
	var all_zero := true
	for i in range(silent.size() / 2):
		if silent.decode_s16(i * 2) != 0:
			all_zero = false
			break
	testing.ok(all_zero, "_build_pcm volume 0 → silence")

	# noise varies sample-to-sample.
	var noise := SoundCommands._build_pcm("noise", 440.0, 440.0, false, 0.05, 0.8, 0.0, 0.0, 0.0)
	var distinct := {}
	for i in range(mini(50, noise.size() / 2)):
		distinct[noise.decode_s16(i * 2)] = true
	testing.ok(distinct.size() > 5, "_build_pcm noise varies sample-to-sample")


# --- tileset.edit_* per-verb foreign-key rejection ------------------------
# The five tileset.edit_* tools share one handler but each owns exactly one
# tile-data concern. _foreign_key_error is the pure gate: it accepts only the
# verb's own keys (plus the universal atlas_x/atlas_y selectors) and rejects the
# first foreign key with a message that names the tool owning it. Pure → testable
# without an editor or a TileSet resource.
static func _test_tileset_edit_key_enforcement(testing) -> void:
	testing.begin("tileset.edit_* per-verb foreign-key rejection")

	# Happy path: each verb with only its own keys (+ coords) → accepted ("").
	testing.eq(TilesetTileData._foreign_key_error("physics",
		{"atlas_x": 0, "atlas_y": 0, "physics_polygon": "full", "physics_layer": 0,
			"one_way_collision": true}), "", "physics accepts its own keys")
	testing.eq(TilesetTileData._foreign_key_error("terrain",
		{"atlas_x": 1, "atlas_y": 0, "terrain_set": 0, "terrain": 0,
			"terrain_peering": {"center": 0}}), "", "terrain accepts its own keys")
	testing.eq(TilesetTileData._foreign_key_error("navigation",
		{"atlas_x": 0, "atlas_y": 0, "navigation_polygon": "full", "navigation_layer": 0}),
		"", "navigation accepts its own keys")
	testing.eq(TilesetTileData._foreign_key_error("visuals",
		{"atlas_x": 0, "atlas_y": 0, "occlusion_polygon": "full", "occlusion_layer": 0,
			"animation": {"frame_count": 2}, "probability": 0.5}), "",
		"visuals accepts occlusion+animation+probability bundle")
	testing.eq(TilesetTileData._foreign_key_error("custom_data",
		{"atlas_x": 0, "atlas_y": 0, "custom_data": {"damage": 10}}), "",
		"custom_data accepts its own key")

	# Coordinate-only tile is always valid (selectors are universal).
	testing.eq(TilesetTileData._foreign_key_error("physics", {"atlas_x": 0, "atlas_y": 0}),
		"", "coords-only tile accepted")

	# Foreign key → rejected, and the message names the OWNING tool.
	var r1 := TilesetTileData._foreign_key_error("physics",
		{"atlas_x": 0, "atlas_y": 0, "terrain_set": 0})
	testing.ok(not r1.is_empty(), "terrain_set on physics → rejected")
	testing.ok(r1.contains("tileset.edit_terrain"), "physics rejection names tileset.edit_terrain")

	var r2 := TilesetTileData._foreign_key_error("terrain",
		{"atlas_x": 0, "atlas_y": 0, "physics_polygon": "full"})
	testing.ok(r2.contains("tileset.edit_physics"), "physics_polygon on terrain → names edit_physics")

	var r3 := TilesetTileData._foreign_key_error("navigation",
		{"atlas_x": 0, "atlas_y": 0, "probability": 0.5})
	testing.ok(r3.contains("tileset.edit_visuals"), "probability on navigation → names edit_visuals")

	var r4 := TilesetTileData._foreign_key_error("custom_data",
		{"atlas_x": 0, "atlas_y": 0, "navigation_polygon": "full"})
	testing.ok(r4.contains("tileset.edit_navigation"), "navigation_polygon on custom_data → names edit_navigation")

	var r5 := TilesetTileData._foreign_key_error("visuals",
		{"atlas_x": 0, "atlas_y": 0, "custom_data": {"x": 1}})
	testing.ok(r5.contains("tileset.edit_custom_data"), "custom_data on visuals → names edit_custom_data")

	# A key owned by no verb → rejected via the "unknown key" branch (no owner).
	var r6 := TilesetTileData._foreign_key_error("physics",
		{"atlas_x": 0, "atlas_y": 0, "bogus_key": 1})
	testing.ok(not r6.is_empty(), "unknown key on physics → rejected")
	testing.ok(r6.contains("unknown key"), "unknown-key rejection uses unknown-key wording")

	# Unknown verb has an empty allow-list → first non-coord key is foreign.
	testing.ok(not TilesetTileData._foreign_key_error("bogus_verb",
		{"atlas_x": 0, "atlas_y": 0, "physics_polygon": "full"}).is_empty(),
		"unknown verb rejects any non-coord key")


# --- tileset_io full-tile polygon (shared unit rectangle) -----------------
# build_full_tile_polygon is the consolidated unit rectangle that create's
# collision seed and edit_physics' "full"/"one_way" shape all share. Pure
# geometry — pin the exact vertex output so the shared helper can never drift.
static func _test_tileset_io_polygon(testing) -> void:
	testing.begin("tileset_io.build_full_tile_polygon (geometry)")

	# 16×16 tile → ±8 corners, wound TL → TR → BR → BL (the order create and
	# edit_physics both rely on for set_collision_polygon_points).
	var p16 := TilesetIo.build_full_tile_polygon(Vector2i(16, 16))
	testing.eq(p16, PackedVector2Array([
		Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)]),
		"16x16 → exact ±8 rectangle in winding order")

	# Non-square tile uses x and y half-extents independently.
	var p_rect := TilesetIo.build_full_tile_polygon(Vector2i(32, 16))
	testing.eq(p_rect, PackedVector2Array([
		Vector2(-16, -8), Vector2(16, -8), Vector2(16, 8), Vector2(-16, 8)]),
		"32x16 → independent half-extents")

	# Odd size keeps the float half (/ 2.0) — no integer truncation.
	var p_odd := TilesetIo.build_full_tile_polygon(Vector2i(15, 15))
	testing.eq(p_odd[0], Vector2(-7.5, -7.5), "odd size keeps .5 half (float division)")


# --- resolve_create_collision (shared if_exists decision) -----------------
# Pure decision query shared by the file creators (scene.create, asset.import,
# texture/sound.generate). Validates if_exists, stats the destination, returns
# the {valid, existed, action} DECISION — no payload, no write. Editor-free:
# FileAccess.file_exists sees user:// paths, so existence cases use a temp file.
static func _test_create_collision_resolver(testing) -> void:
	testing.begin("resolve_create_collision (if_exists decision)")

	# A guaranteed-absent res:// path (randomised to dodge any stray fixture).
	var absent := "res://__nope_%d.png" % (randi() % 1_000_000)

	# Not-exists: every legal if_exists short-circuits to action "create".
	var c_create := Helpers.resolve_create_collision(absent, "return")
	testing.eq(c_create.get("valid"), true, "absent + return → valid")
	testing.eq(c_create.get("existed"), false, "absent + return → existed false")
	testing.eq(c_create.get("action"), "create", "absent + return → action create")
	testing.eq(Helpers.resolve_create_collision(absent, "fail").get("action"), "create",
		"absent + fail → action create (value irrelevant when absent)")
	testing.eq(Helpers.resolve_create_collision(absent, "replace").get("action"), "create",
		"absent + replace → action create")

	# Invalid if_exists → {valid:false} (no existence read needed).
	testing.eq(Helpers.resolve_create_collision(absent, "clobber").get("valid"), false,
		"invalid value 'clobber' → valid false")
	testing.eq(Helpers.resolve_create_collision(absent, "").get("valid"), false,
		"empty value → valid false")
	testing.eq(Helpers.resolve_create_collision(absent, "Return").get("valid"), false,
		"wrong-case 'Return' → valid false (exact-case match)")

	# Exists: write a temp file under user://, assert the action == if_exists, clean up.
	var present := "user://__collision_test_%d.tmp" % (randi() % 1_000_000)
	var f := FileAccess.open(present, FileAccess.WRITE)
	if f == null:
		testing.ok(false, "could not open temp file for existence cases — SKIPPED exists path")
	else:
		f.store_string("x")
		f.close()

		var c_return := Helpers.resolve_create_collision(present, "return")
		testing.eq(c_return.get("valid"), true, "exists + return → valid")
		testing.eq(c_return.get("existed"), true, "exists + return → existed true")
		testing.eq(c_return.get("action"), "return", "exists + return → action return")
		testing.eq(Helpers.resolve_create_collision(present, "fail").get("action"), "fail",
			"exists + fail → action fail")
		testing.eq(Helpers.resolve_create_collision(present, "replace").get("action"), "replace",
			"exists + replace → action replace")

		# Validation precedes existence: invalid value while the file exists is
		# still {valid:false} — locks that the value check runs before the stat.
		testing.eq(Helpers.resolve_create_collision(present, "nope").get("valid"), false,
			"exists + invalid value → valid false (validation precedes existence)")

		DirAccess.remove_absolute(ProjectSettings.globalize_path(present))
