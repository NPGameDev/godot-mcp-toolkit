@tool
extends RefCounted
## particles.* command handlers — GPU particle system creation with presets.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Coerce = Modules.Coerce
const Helpers = Modules.CommandHelpers

const _VALID_PRESETS := ["fire", "smoke", "sparks", "rain", "snow", "explosion", "magic", "dust"]


static func _class_has_prop(cls: String, prop: String) -> bool:
	for p in ClassDB.class_get_property_list(cls):
		if p.get("name", "") == prop:
			return true
	return false

const _EMISSION_SHAPES := {
	"point": ParticleProcessMaterial.EMISSION_SHAPE_POINT,
	"sphere": ParticleProcessMaterial.EMISSION_SHAPE_SPHERE,
	"sphere_surface": ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE,
	"box": ParticleProcessMaterial.EMISSION_SHAPE_BOX,
	"ring": ParticleProcessMaterial.EMISSION_SHAPE_RING,
}

# User param name → material property prefix for {prefix}_min / {prefix}_max pairs.
const _RANGE_PARAMS := {
	"initial_velocity": "initial_velocity",
	"damping": "damping",
	"orbit_velocity": "orbit_velocity",
	"scale_range": "scale",
	"angle": "angle",
	"angular_velocity": "angular_velocity",
	"hue_variation": "hue_variation",
}

# Coercion modes shared by the two data-driven passes (_apply_props pass 7 and
# _merge_overrides pass 6). Each value mirrors the EXACT cast the old hand-written
# ladder used so both the emitted property value AND the merged eff value stay
# byte-identical:
#   INT/FLOAT/BOOL — wrap the source in int()/float()/bool() before storing.
#   VEC3/COLOR     — coerce a raw user param via _vec3()/_color() (the merge ladder
#                    converted the {x,y,z}/{r,g,b,a} request dict into a Vector3/Color).
#   RAW            — assign the source directly (the apply ladder stored the value
#                    untouched; by then the preset/merge had already produced the
#                    right Vector3/Color, so it was assigned as-is).
# _apply_props uses INT/FLOAT/BOOL/RAW (its inputs are already typed); _merge_overrides
# uses INT/FLOAT/BOOL/VEC3/COLOR (its inputs are raw user params). The VEC3/COLOR rows
# are exactly the keys the apply pass treats as RAW — the coercion happens at merge.
enum { _COERCE_INT, _COERCE_FLOAT, _COERCE_BOOL, _COERCE_RAW, _COERCE_VEC3, _COERCE_COLOR }

# Targets for the applier: the node vs the ParticleProcessMaterial.
enum { _TARGET_NODE, _TARGET_MATERIAL }

# Data-driven map of the uniform "if eff.has(k): target.set(prop, cast(eff[k]));
# properties_set += 1" apply rows.
# Each row is [eff_key, target, coerce] and contributes weight 1. The eff_key ==
# the target property name in every case, so a single `key` field doubles as both.
# Rows stay in apply ORDER (node group, then material group); the genuine
# specials — range pairs (weight 2), the emission-shape name→enum lookup,
# sub-resources, version-gated props, the 2D/3D forks — are NOT in this table and
# remain explicit. Property writes here are mutually independent, so the integer
# count and the final object state are invariant under their relative order.
const _PROP_SPEC := [
	# Node group.
	["amount", _TARGET_NODE, _COERCE_INT],
	["lifetime", _TARGET_NODE, _COERCE_FLOAT],
	["explosiveness", _TARGET_NODE, _COERCE_FLOAT],
	["speed_scale", _TARGET_NODE, _COERCE_FLOAT],
	["one_shot", _TARGET_NODE, _COERCE_BOOL],
	["local_coords", _TARGET_NODE, _COERCE_BOOL],
	# Material group (the range pairs + emission-shape arm stay explicit below).
	["direction", _TARGET_MATERIAL, _COERCE_RAW],
	["spread", _TARGET_MATERIAL, _COERCE_FLOAT],
	["gravity", _TARGET_MATERIAL, _COERCE_RAW],
	["color", _TARGET_MATERIAL, _COERCE_RAW],
	["particle_flag_align_y", _TARGET_MATERIAL, _COERCE_BOOL],
	["emission_sphere_radius", _TARGET_MATERIAL, _COERCE_FLOAT],
	["emission_box_extents", _TARGET_MATERIAL, _COERCE_RAW],
	["turbulence_enabled", _TARGET_MATERIAL, _COERCE_BOOL],
	["turbulence_noise_strength", _TARGET_MATERIAL, _COERCE_FLOAT],
]

# Data-driven map of the uniform simple-override rows of the merge that layers
# user params onto the preset-seeded eff dict.
# Each row is [param_key, coerce] and writes eff[param_key] = coerce(parameters[key]).
# Row order is load-bearing: every shadow append into overrides_applied happens in
# this order and the array's element order is part of the particles.create response
# contract — so keep the rows in exactly this sequence (unlike _PROP_SPEC, whose
# writes are independent and order-invariant). The coercion column uses the merge
# modes (VEC3/COLOR convert the request dict), NOT the apply modes. The genuine
# specials — range pairs and the emission-shape override — are NOT in this table;
# they keep their dedicated blocks in _merge_overrides (different shape: a _min/_max
# pair, and a name-validated string) and append AFTER this table.
const _OVERRIDE_SPEC := [
	["amount", _COERCE_INT],
	["lifetime", _COERCE_FLOAT],
	["one_shot", _COERCE_BOOL],
	["explosiveness", _COERCE_FLOAT],
	["speed_scale", _COERCE_FLOAT],
	["local_coords", _COERCE_BOOL],
	["direction", _COERCE_VEC3],
	["spread", _COERCE_FLOAT],
	["gravity", _COERCE_VEC3],
	["color", _COERCE_COLOR],
	["particle_flag_align_y", _COERCE_BOOL],
	["emission_sphere_radius", _COERCE_FLOAT],
	["emission_box_extents", _COERCE_VEC3],
	["turbulence_enabled", _COERCE_BOOL],
	["turbulence_noise_strength", _COERCE_FLOAT],
]

# Presets defined in 2D units. When type=="3d", _adjust_for_3d() is applied.
const _PRESETS := {
	"fire": {
		"direction": Vector3(0, -1, 0),
		"spread": 15.0,
		"initial_velocity_min": 30.0,
		"initial_velocity_max": 60.0,
		"gravity": Vector3(0, 0, 0),
		"lifetime": 1.2,
		"amount": 24,
		"scale_min": 0.8,
		"scale_max": 1.5,
		"color_ramp": [
			{"offset": 0.0, "color": Color(1, 1, 0, 1)},
			{"offset": 0.35, "color": Color(1, 0.5, 0, 1)},
			{"offset": 0.7, "color": Color(0.6, 0.1, 0, 0.6)},
			{"offset": 1.0, "color": Color(0.2, 0, 0, 0)},
		],
		"alpha_curve": [
			{"x": 0.0, "y": 0.0},
			{"x": 0.1, "y": 1.0},
			{"x": 0.8, "y": 0.6},
			{"x": 1.0, "y": 0.0},
		],
		"scale_curve": [
			{"x": 0.0, "y": 0.5},
			{"x": 0.3, "y": 1.0},
			{"x": 1.0, "y": 0.0},
		],
	},
	"smoke": {
		"direction": Vector3(0, -1, 0),
		"spread": 25.0,
		"initial_velocity_min": 10.0,
		"initial_velocity_max": 25.0,
		"gravity": Vector3(0, 0, 0),
		"damping_min": 1.0,
		"damping_max": 2.0,
		"lifetime": 3.0,
		"amount": 16,
		"scale_min": 1.5,
		"scale_max": 3.0,
		"color_ramp": [
			{"offset": 0.0, "color": Color(0.6, 0.6, 0.6, 0.6)},
			{"offset": 0.5, "color": Color(0.4, 0.4, 0.4, 0.3)},
			{"offset": 1.0, "color": Color(0.2, 0.2, 0.2, 0.0)},
		],
		"alpha_curve": [
			{"x": 0.0, "y": 0.0},
			{"x": 0.15, "y": 0.8},
			{"x": 0.7, "y": 0.4},
			{"x": 1.0, "y": 0.0},
		],
		"scale_curve": [
			{"x": 0.0, "y": 0.3},
			{"x": 0.5, "y": 0.7},
			{"x": 1.0, "y": 1.0},
		],
	},
	"sparks": {
		"direction": Vector3(0, -1, 0),
		"spread": 180.0,
		"initial_velocity_min": 200.0,
		"initial_velocity_max": 400.0,
		"gravity": Vector3(0, 98, 0),
		"damping_min": 1.0,
		"damping_max": 3.0,
		"lifetime": 0.5,
		"amount": 48,
		"one_shot": true,
		"explosiveness": 1.0,
		"scale_min": 0.1,
		"scale_max": 0.3,
		"particle_flag_align_y": true,
		"color_ramp": [
			{"offset": 0.0, "color": Color(1, 1, 0.8, 1)},
			{"offset": 0.3, "color": Color(1, 0.7, 0.2, 1)},
			{"offset": 0.7, "color": Color(1, 0.3, 0, 0.8)},
			{"offset": 1.0, "color": Color(0.5, 0.1, 0, 0)},
		],
		"alpha_curve": [
			{"x": 0.0, "y": 1.0},
			{"x": 0.7, "y": 0.8},
			{"x": 1.0, "y": 0.0},
		],
		"scale_curve": [
			{"x": 0.0, "y": 1.0},
			{"x": 1.0, "y": 0.3},
		],
	},
	"rain": {
		"direction": Vector3(0, 1, 0),
		"spread": 5.0,
		"initial_velocity_min": 300.0,
		"initial_velocity_max": 400.0,
		"gravity": Vector3(0, 98, 0),
		"lifetime": 0.8,
		"amount": 64,
		"emission_shape": "box",
		"emission_box_extents": Vector3(300, 0, 0),
		"particle_flag_align_y": true,
		"color": Color(0.6, 0.7, 1.0, 0.7),
		"scale_min": 0.1,
		"scale_max": 0.2,
	},
	"snow": {
		"direction": Vector3(0, 1, 0),
		"spread": 20.0,
		"initial_velocity_min": 20.0,
		"initial_velocity_max": 40.0,
		"gravity": Vector3(0, 20, 0),
		"angular_velocity_min": -45.0,
		"angular_velocity_max": 45.0,
		"lifetime": 4.0,
		"amount": 48,
		"emission_shape": "box",
		"emission_box_extents": Vector3(300, 0, 0),
		"color": Color(1, 1, 1, 0.9),
		"scale_min": 0.3,
		"scale_max": 0.8,
	},
	"explosion": {
		"direction": Vector3(0, -1, 0),
		"spread": 180.0,
		"initial_velocity_min": 100.0,
		"initial_velocity_max": 200.0,
		"gravity": Vector3(0, 49, 0),
		"damping_min": 2.0,
		"damping_max": 4.0,
		"lifetime": 0.6,
		"amount": 32,
		"one_shot": true,
		"explosiveness": 1.0,
		"scale_min": 0.5,
		"scale_max": 1.5,
		"color_ramp": [
			{"offset": 0.0, "color": Color(1, 1, 0.8, 1)},
			{"offset": 0.2, "color": Color(1, 0.6, 0, 1)},
			{"offset": 0.5, "color": Color(0.8, 0.2, 0, 0.7)},
			{"offset": 0.8, "color": Color(0.4, 0.1, 0, 0.3)},
			{"offset": 1.0, "color": Color(0.2, 0.05, 0, 0)},
		],
		"alpha_curve": [
			{"x": 0.0, "y": 1.0},
			{"x": 0.3, "y": 0.9},
			{"x": 0.7, "y": 0.4},
			{"x": 1.0, "y": 0.0},
		],
		"scale_curve": [
			{"x": 0.0, "y": 0.2},
			{"x": 0.15, "y": 1.0},
			{"x": 0.5, "y": 0.7},
			{"x": 1.0, "y": 0.3},
		],
	},
	"magic": {
		"direction": Vector3(0, -1, 0),
		"spread": 180.0,
		"initial_velocity_min": 20.0,
		"initial_velocity_max": 50.0,
		"gravity": Vector3(0, 0, 0),
		"orbit_velocity_min": 0.5,
		"orbit_velocity_max": 1.5,
		"damping_min": 1.0,
		"damping_max": 2.0,
		"lifetime": 2.0,
		"amount": 24,
		"scale_min": 0.3,
		"scale_max": 0.8,
		"hue_variation_min": -0.15,
		"hue_variation_max": 0.15,
		"color_ramp": [
			{"offset": 0.0, "color": Color(0.5, 0.2, 1, 1)},
			{"offset": 0.4, "color": Color(0.2, 0.6, 1, 0.8)},
			{"offset": 0.7, "color": Color(0.8, 0.3, 1, 0.5)},
			{"offset": 1.0, "color": Color(0.4, 0.1, 0.8, 0)},
		],
		"alpha_curve": [
			{"x": 0.0, "y": 0.0},
			{"x": 0.1, "y": 1.0},
			{"x": 0.6, "y": 0.7},
			{"x": 1.0, "y": 0.0},
		],
		"scale_curve": [
			{"x": 0.0, "y": 0.5},
			{"x": 0.3, "y": 1.0},
			{"x": 0.7, "y": 0.8},
			{"x": 1.0, "y": 0.2},
		],
	},
	"dust": {
		"direction": Vector3(0, -1, 0),
		"spread": 180.0,
		"initial_velocity_min": 3.0,
		"initial_velocity_max": 8.0,
		"gravity": Vector3(0, 0, 0),
		"damping_min": 0.5,
		"damping_max": 1.0,
		"lifetime": 5.0,
		"amount": 12,
		"emission_shape": "box",
		"emission_box_extents": Vector3(100, 100, 0),
		"color": Color(0.8, 0.75, 0.65, 0.4),
		"scale_min": 0.2,
		"scale_max": 0.5,
		"color_ramp": [
			{"offset": 0.0, "color": Color(0.8, 0.75, 0.65, 0.0)},
			{"offset": 0.2, "color": Color(0.8, 0.75, 0.65, 0.4)},
			{"offset": 0.8, "color": Color(0.7, 0.65, 0.55, 0.3)},
			{"offset": 1.0, "color": Color(0.6, 0.55, 0.45, 0.0)},
		],
		"alpha_curve": [
			{"x": 0.0, "y": 0.0},
			{"x": 0.2, "y": 0.6},
			{"x": 0.6, "y": 0.5},
			{"x": 1.0, "y": 0.0},
		],
		"scale_curve": [
			{"x": 0.0, "y": 0.5},
			{"x": 0.5, "y": 1.0},
			{"x": 1.0, "y": 0.8},
		],
	},
}


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("particles.create", func(p: Dictionary) -> Dictionary:
		return _cmd_particles_create(p)
	, MCPToolkitCommandOptions.new())


# -- Helpers ------------------------------------------------------------------


static func _vec3(d: Variant) -> Vector3:
	if typeof(d) != TYPE_DICTIONARY:
		return Vector3.ZERO
	return Vector3(float(d.get("x", 0.0)), float(d.get("y", 0.0)), float(d.get("z", 0.0)))


static func _color(d: Variant) -> Color:
	return Coerce.color_from_dict(d)


static func _expand_range(v: Variant) -> Array:
	## Returns [min_val, max_val] as floats.
	if typeof(v) == TYPE_DICTIONARY:
		return [float(v.get("min", 0.0)), float(v.get("max", 0.0))]
	var f := float(v)
	return [f, f]


static func _adjust_for_3d(data: Dictionary) -> void:
	## Mutate preset data in-place: 2D → 3D coordinate scaling.
	if data.has("direction"):
		var d: Vector3 = data["direction"]
		data["direction"] = Vector3(d.x, -d.y, d.z)
	if data.has("gravity"):
		data["gravity"] = Vector3(data["gravity"]) / 10.0
	for key in ["initial_velocity_min", "initial_velocity_max"]:
		if data.has(key):
			data[key] = float(data[key]) / 20.0
	if data.has("emission_box_extents"):
		data["emission_box_extents"] = Vector3(data["emission_box_extents"]) / 20.0


static func _build_gradient_texture(points: Array, interp_mode: int) -> Array:
	## Create GradientTexture1D from [{offset, color}].
	## Returns [GradientTexture1D, Gradient].
	var gradient := Gradient.new()
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for point in points:
		offsets.append(float(point["offset"]))
		if point["color"] is Color:
			colors.append(point["color"])
		else:
			colors.append(_color(point["color"]))
	gradient.offsets = offsets
	gradient.colors = colors
	gradient.interpolation_mode = interp_mode
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	return [texture, gradient]


static func _build_curve_texture(points: Array) -> Array:
	## Create CurveTexture from [{x, y}].
	## Returns [CurveTexture, Curve].
	var curve := Curve.new()
	for point in points:
		curve.add_point(Vector2(float(point["x"]), float(point["y"])))
	var texture := CurveTexture.new()
	texture.curve = curve
	return [texture, curve]


static func _apply_props(node: Node, material: ParticleProcessMaterial, eff: Dictionary) -> int:
	## Apply every uniform _PROP_SPEC entry present in eff onto its target,
	## returning the properties_set delta (the data-driven replacement for the
	## simple-property half of pass 7). The range-pair loop and the emission-shape
	## name→enum lookup are NOT covered here and stay explicit in the handler.
	var count := 0
	for spec in _PROP_SPEC:
		var key: String = spec[0]
		if not eff.has(key):
			continue
		var target: Object = node if spec[1] == _TARGET_NODE else material
		var raw: Variant = eff[key]
		match spec[2]:
			_COERCE_INT:
				target.set(key, int(raw))
			_COERCE_FLOAT:
				target.set(key, float(raw))
			_COERCE_BOOL:
				target.set(key, bool(raw))
			_:  # _COERCE_RAW — assign untouched (already the right Vector3/Color).
				target.set(key, raw)
		count += 1
	return count


static func _merge_overrides(eff: Dictionary, parameters: Dictionary) -> Array:
	## Layer the request's user params onto the preset-seeded eff dict (pass 6),
	## returning the overrides_applied array — the names of params that SHADOWED a
	## preset value, in contract order. eff is mutated in place. Three sub-passes,
	## appended strictly in the original order so the returned array is byte-identical:
	##   1. the uniform simple props (_OVERRIDE_SPEC, in order);
	##   2. the range params (_RANGE_PARAMS → {prefix}_min/_max);
	##   3. the emission-shape name override.
	## A param shadows the preset only when eff already holds the key (range: the
	## _min half) — matching the old `if eff.has(...): overrides.append(...)` guards.
	var overrides: Array = []

	# 1. Simple user overrides (table-driven; was the :464-483 match-ladder).
	for spec in _OVERRIDE_SPEC:
		var key: String = spec[0]
		if not parameters.has(key):
			continue
		if eff.has(key):
			overrides.append(key)
		var raw: Variant = parameters[key]
		match spec[1]:
			_COERCE_INT:
				eff[key] = int(raw)
			_COERCE_BOOL:
				eff[key] = bool(raw)
			_COERCE_VEC3:
				eff[key] = _vec3(raw)
			_COERCE_COLOR:
				eff[key] = _color(raw)
			_:  # _COERCE_FLOAT — the old ladder's default arm.
				eff[key] = float(raw)

	# 2. Range params: user float or {min,max} → internal _min/_max (was :485-494).
	for user_key in _RANGE_PARAMS:
		if not parameters.has(user_key):
			continue
		var prefix: String = _RANGE_PARAMS[user_key]
		var r := _expand_range(parameters[user_key])
		if eff.has(prefix + "_min"):
			overrides.append(user_key)
		eff[prefix + "_min"] = r[0]
		eff[prefix + "_max"] = r[1]

	# 3. Emission shape override (was :496-500). The name was already validated
	# against _EMISSION_SHAPES in the handler before this merge runs.
	var emission_shape_str = parameters.get("emission_shape")
	if emission_shape_str != null:
		if eff.has("emission_shape"):
			overrides.append("emission_shape")
		eff["emission_shape"] = str(emission_shape_str)

	return overrides


# -- Command ------------------------------------------------------------------


static func _cmd_particles_create(parameters: Dictionary) -> Dictionary:
	# --- Validate required ---
	var err = MCPToolkitError.require(parameters, ["parent_path", "type"])
	if err != null:
		return err

	var type_str := str(parameters.get("type", ""))
	if type_str != "2d" and type_str != "3d":
		return MCPToolkitError.fail("INVALID_PARAMS",
			"type must be '2d' or '3d', got '%s'" % type_str)
	var is_3d := type_str == "3d"

	# --- Preset ---
	var preset_name = parameters.get("preset")
	var preset := {}
	if preset_name != null:
		var pn := str(preset_name)
		if pn not in _VALID_PRESETS:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"invalid preset '%s'; valid presets: %s" % [pn, ", ".join(_VALID_PRESETS)])
		preset = _PRESETS[pn].duplicate(true)
		if is_3d:
			_adjust_for_3d(preset)

	# --- Validate emission_shape ---
	var emission_shape_str = parameters.get("emission_shape")
	if emission_shape_str != null and str(emission_shape_str) not in _EMISSION_SHAPES:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"invalid emission_shape '%s'; valid shapes: %s" % [
				str(emission_shape_str), ", ".join(_EMISSION_SHAPES.keys())])

	# --- Resolve parent ---
	var root := Helpers.get_edited_root()
	if root == null:
		return MCPToolkitError.fail("NO_SCENE", "no edited scene")
	var parent_path := str(parameters.get("parent_path", "."))
	parent_path = Helpers.normalize_editor_path(parent_path)
	var parent := Helpers.resolve_scene_node(parent_path)
	if parent == null:
		return MCPToolkitError.fail("NOT_FOUND",
			"parent not found: %s" % parent_path, MCPToolkitError.HINT_NODE_PATH)

	# --- Create node + material ---
	var node: Node
	var default_name := "GPUParticles3D" if is_3d else "GPUParticles2D"
	if is_3d:
		node = GPUParticles3D.new()
	else:
		node = GPUParticles2D.new()
	node.name = str(parameters.get("name", default_name))

	var material := ParticleProcessMaterial.new()
	var sub_resources: Array = [material]
	var properties_set := 0
	var version_notes: Array = []

	# Build effective config: preset base, user overrides on top.
	var eff := preset.duplicate(true)

	# --- Merge user overrides (data-driven; see _OVERRIDE_SPEC) ---
	# overrides holds the names of params that shadowed a preset value, in the order
	# the response contract expects (simple props, then range params, then emission
	# shape). The sub-resource pass appends to it below; the result reads it last.
	var overrides: Array = _merge_overrides(eff, parameters)

	# --- Apply node + material properties (data-driven; see _PROP_SPEC) ---
	# The uniform single-property rows of pass 7 are applied by _apply_props.
	# The range-pair loop and the emission-shape name→enum lookup are NOT uniform
	# (weight 2 / value is an enum lookup) and stay explicit below. These writes
	# are mutually independent, so the count and final state are order-invariant.
	properties_set += _apply_props(node, material, eff)

	# Range params on material (weight 2 each — kept explicit).
	for prefix in ["initial_velocity", "damping", "orbit_velocity", "scale",
			"angle", "angular_velocity", "hue_variation"]:
		if eff.has(prefix + "_min"):
			material.set(prefix + "_min", float(eff[prefix + "_min"]))
			material.set(prefix + "_max", float(eff[prefix + "_max"]))
			properties_set += 2

	# Emission shape (name → enum lookup — kept explicit).
	if eff.has("emission_shape"):
		var shape_name := str(eff["emission_shape"])
		if shape_name in _EMISSION_SHAPES:
			material.emission_shape = _EMISSION_SHAPES[shape_name]
			properties_set += 1

	# --- Sub-resources: color_ramp, alpha_curve, scale_curve ---
	var sr_err = _apply_sub_resource(parameters, eff, preset, material,
		"color_ramp", sub_resources, overrides, node)
	if sr_err != null:
		return sr_err
	if material.color_ramp != null:
		properties_set += 1

	sr_err = _apply_sub_resource(parameters, eff, preset, material,
		"alpha_curve", sub_resources, overrides, node)
	if sr_err != null:
		return sr_err
	if material.alpha_curve != null:
		properties_set += 1

	sr_err = _apply_sub_resource(parameters, eff, preset, material,
		"scale_curve", sub_resources, overrides, node)
	if sr_err != null:
		return sr_err
	if material.scale_curve != null:
		properties_set += 1

	# --- Assign material ---
	node.process_material = material
	properties_set += 1

	# --- 3D mesh ---
	if is_3d and parameters.has("mesh"):
		var mesh_type := str(parameters["mesh"])
		var mesh: Mesh
		match mesh_type:
			"quad": mesh = QuadMesh.new()
			"box": mesh = BoxMesh.new()
			"sphere": mesh = SphereMesh.new()
			_: mesh = QuadMesh.new()
		(node as GPUParticles3D).draw_pass_1 = mesh
		sub_resources.append(mesh)
		properties_set += 1

	# --- 2D texture ---
	if not is_3d and parameters.has("texture_path"):
		var tex_path := str(parameters["texture_path"])
		if ResourceLoader.exists(tex_path):
			(node as GPUParticles2D).texture = ResourceLoader.load(tex_path)
			properties_set += 1

	# --- Position ---
	if parameters.has("position"):
		var pos = parameters["position"]
		if is_3d:
			(node as Node3D).position = _vec3(pos)
		else:
			var p = pos if typeof(pos) == TYPE_DICTIONARY else {}
			(node as Node2D).position = Vector2(
				float(p.get("x", 0.0)), float(p.get("y", 0.0)))
		properties_set += 1

	# --- Version-gated properties ---
	var node_class := "GPUParticles3D" if is_3d else "GPUParticles2D"
	if parameters.has("use_fixed_seed"):
		if _class_has_prop(node_class, "use_fixed_seed"):
			node.set("use_fixed_seed", bool(parameters["use_fixed_seed"]))
			properties_set += 1
		else:
			version_notes.append("use_fixed_seed unavailable in this Godot version")
	if parameters.has("seed"):
		if _class_has_prop(node_class, "seed"):
			node.set("seed", int(parameters["seed"]))
			properties_set += 1
		else:
			version_notes.append("seed unavailable in this Godot version")
	if parameters.has("emission_ring_cone_angle"):
		if _class_has_prop("ParticleProcessMaterial", "emission_ring_cone_angle"):
			material.set("emission_ring_cone_angle", float(parameters["emission_ring_cone_angle"]))
			properties_set += 1
		else:
			version_notes.append("emission_ring_cone_angle unavailable in this Godot version")

	# --- Add to scene via UndoRedo ---
	parent.add_child(node)
	node.set_owner(root)
	var _undo := MCPToolkitUndoRedoAction.begin("create %s" % node.name, parent) \
		.do_method(parent.add_child.bind(node)) \
		.do_method(node.set_owner.bind(root)) \
		.do_reference(node)
	for res in sub_resources:
		_undo.undo_reference(res)
	_undo.undo_method(parent.remove_child.bind(node)) \
		.commit_recorded()

	# --- Result ---
	var result := {
		"node_path": str(root.get_path_to(node)),
		"type": "GPUParticles3D" if is_3d else "GPUParticles2D",
		"properties_set": properties_set,
		"version_notes": version_notes,
	}
	if preset_name != null:
		result["preset_applied"] = str(preset_name)
	if not overrides.is_empty():
		result["overrides_applied"] = overrides
	return MCPToolkitSuccess.ok(result)


static func _apply_sub_resource(
		parameters: Dictionary, eff: Dictionary, preset: Dictionary,
		material: ParticleProcessMaterial, prop_name: String,
		sub_resources: Array, overrides_out: Array, node: Node) -> Variant:
	## Handle color_ramp / alpha_curve / scale_curve. Returns error dict or null.
	var source = null
	var is_override := false
	if parameters.has(prop_name):
		source = parameters[prop_name]
		is_override = preset.has(prop_name)
	elif eff.has(prop_name):
		source = eff[prop_name]
	if source == null:
		return null

	if source is String:
		var path := str(source)
		if not ResourceLoader.exists(path):
			node.free()
			return MCPToolkitError.fail("NOT_FOUND",
				"%s resource not found: %s" % [prop_name, path])
		material.set(prop_name, ResourceLoader.load(path))
	elif source is Array:
		# Preset format: array of point dicts.
		if prop_name == "color_ramp":
			var result := _build_gradient_texture(source, Gradient.GRADIENT_INTERPOLATE_LINEAR)
			material.color_ramp = result[0]
			sub_resources.append(result[0])
			sub_resources.append(result[1])
		else:
			var result := _build_curve_texture(source)
			material.set(prop_name, result[0])
			sub_resources.append(result[0])
			sub_resources.append(result[1])
	elif source is Dictionary and source.has("points"):
		# User format: {points: [...], interpolation?}.
		if prop_name == "color_ramp":
			var interp := Gradient.GRADIENT_INTERPOLATE_LINEAR
			var interp_str = source.get("interpolation", "linear")
			match str(interp_str):
				"cubic": interp = Gradient.GRADIENT_INTERPOLATE_CUBIC
				"constant": interp = Gradient.GRADIENT_INTERPOLATE_CONSTANT
			var result := _build_gradient_texture(source["points"], interp)
			material.color_ramp = result[0]
			sub_resources.append(result[0])
			sub_resources.append(result[1])
		else:
			var result := _build_curve_texture(source["points"])
			material.set(prop_name, result[0])
			sub_resources.append(result[0])
			sub_resources.append(result[1])

	if is_override:
		overrides_out.append(prop_name)
	return null
