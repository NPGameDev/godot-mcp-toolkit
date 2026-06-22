@tool
extends RefCounted
## procedural.* command handlers — create/edit Gradient, Curve, and
## FastNoiseLite resources as standalone .tres files.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Coerce = Modules.Coerce
const FileGuard = Modules.FileGuard
const Helpers = Modules.CommandHelpers


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("procedural.edit_gradient", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_edit_gradient(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("procedural.edit_curve", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_edit_curve(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("procedural.edit_noise", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_edit_noise(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())


# -- Commands -----------------------------------------------------------------


static func _cmd_edit_gradient(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path"])
	if err != null:
		return err

	var file_path := str(parameters.get("file_path", ""))
	file_path = Helpers.normalize_editor_path(file_path)
	var action := str(parameters.get("action", "set"))
	var points_raw = parameters.get("points", null)
	var index_raw = parameters.get("index", null)
	var interp_raw = parameters.get("interpolation_mode", null)

	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if file_path.get_extension().to_lower() != "tres":
		return MCPToolkitError.fail("INVALID_PATH",
			"procedural.edit_gradient writes .tres files (got %s)" % file_path)

	if action not in ["set", "add_point", "remove_point"]:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"action must be one of: set, add_point, remove_point (got '%s')" % action)

	# Load or create Gradient.
	var gradient: Gradient
	if FileAccess.file_exists(file_path):
		var loaded = ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if loaded == null or not (loaded is Gradient):
			return MCPToolkitError.fail("INVALID_CLASS",
				"Resource at %s is not a Gradient" % file_path)
		gradient = loaded as Gradient
	else:
		gradient = Gradient.new()

	match action:
		"set":
			if points_raw == null or typeof(points_raw) != TYPE_ARRAY:
				return MCPToolkitError.fail("INVALID_PARAMS",
					"action 'set' requires a 'points' array")
			var points := points_raw as Array
			# Clear existing points (Gradient always keeps at least 1).
			while gradient.get_point_count() > 1:
				gradient.remove_point(gradient.get_point_count() - 1)
			# Set the first point, then add the rest.
			if points.size() > 0:
				gradient.set_offset(0, float(points[0].get("offset", 0.0)))
				gradient.set_color(0, _color(points[0].get("color", {})))
				for i in range(1, points.size()):
					gradient.add_point(
						float(points[i].get("offset", 0.0)),
						_color(points[i].get("color", {})))
		"add_point":
			if points_raw == null or typeof(points_raw) != TYPE_ARRAY:
				return MCPToolkitError.fail("INVALID_PARAMS",
					"action 'add_point' requires a 'points' array with at least one entry")
			var points := points_raw as Array
			if points.size() < 1:
				return MCPToolkitError.fail("INVALID_PARAMS",
					"action 'add_point' requires at least one point")
			gradient.add_point(
				float(points[0].get("offset", 0.0)),
				_color(points[0].get("color", {})))
		"remove_point":
			if index_raw == null:
				return MCPToolkitError.fail("INVALID_PARAMS",
					"action 'remove_point' requires an 'index'")
			var index := int(index_raw)
			if index < 0 or index >= gradient.get_point_count():
				return MCPToolkitError.fail("INVALID_PARAMS",
					"index %d out of range (point_count=%d)" % [index, gradient.get_point_count()])
			gradient.remove_point(index)

	# Interpolation mode.
	if interp_raw != null:
		var interp_str := str(interp_raw)
		var interp_map := {"linear": 0, "constant": 1, "cubic": 2}
		if not interp_map.has(interp_str):
			return MCPToolkitError.fail("INVALID_PARAMS",
				"interpolation_mode must be one of: linear, constant, cubic (got '%s')" % interp_str)
		gradient.interpolation_mode = interp_map[interp_str]

	return await _save_resource(gradient, file_path, "procedural.edit_gradient",
		{"point_count": gradient.get_point_count()})


## Authors a 1D **Curve** resource as a standalone .tres file (tool
## `procedural.edit_curve`). NOT `path2d.edit_curve`, which edits a **Curve2D**
## on a Path2D scene node — different engine type, different aggregate.
static func _cmd_edit_curve(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path"])
	if err != null:
		return err

	var file_path := str(parameters.get("file_path", ""))
	file_path = Helpers.normalize_editor_path(file_path)
	var action := str(parameters.get("action", "set"))
	var points_raw = parameters.get("points", null)
	var index_raw = parameters.get("index", null)
	var min_val = parameters.get("min_value", null)
	var max_val = parameters.get("max_value", null)

	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if file_path.get_extension().to_lower() != "tres":
		return MCPToolkitError.fail("INVALID_PATH",
			"procedural.edit_curve writes .tres files (got %s)" % file_path)

	if action not in ["set", "add_point", "remove_point", "clear"]:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"action must be one of: set, add_point, remove_point, clear (got '%s')" % action)

	# Load or create Curve.
	var curve: Curve
	if FileAccess.file_exists(file_path):
		var loaded = ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if loaded == null or not (loaded is Curve):
			return MCPToolkitError.fail("INVALID_CLASS",
				"Resource at %s is not a Curve" % file_path)
		curve = loaded as Curve
	else:
		curve = Curve.new()

	# Set min/max before adding points.
	if min_val != null:
		curve.min_value = float(min_val)
	if max_val != null:
		curve.max_value = float(max_val)

	match action:
		"set":
			if points_raw == null or typeof(points_raw) != TYPE_ARRAY:
				return MCPToolkitError.fail("INVALID_PARAMS",
					"action 'set' requires a 'points' array")
			curve.clear_points()
			for i in range((points_raw as Array).size()):
				var pt = (points_raw as Array)[i]
				if typeof(pt) != TYPE_DICTIONARY or not pt.has("position"):
					return MCPToolkitError.fail("INVALID_PARAMS",
						"points[%d] must have a 'position' key with {x, y}" % i)
				var pos_d = pt["position"]
				var pos := Vector2(float(pos_d.get("x", 0.0)), float(pos_d.get("y", 0.0)))
				var lt := float(pt.get("left_tangent", 0.0))
				var rt := float(pt.get("right_tangent", 0.0))
				var lm := _tangent_mode(pt.get("left_mode", null))
				var rm := _tangent_mode(pt.get("right_mode", null))
				curve.add_point(pos, lt, rt, lm, rm)
		"add_point":
			if points_raw == null or typeof(points_raw) != TYPE_ARRAY:
				return MCPToolkitError.fail("INVALID_PARAMS",
					"action 'add_point' requires a 'points' array with at least one entry")
			var points := points_raw as Array
			if points.size() < 1:
				return MCPToolkitError.fail("INVALID_PARAMS",
					"action 'add_point' requires at least one point")
			var pt = points[0]
			if typeof(pt) != TYPE_DICTIONARY or not pt.has("position"):
				return MCPToolkitError.fail("INVALID_PARAMS",
					"points[0] must have a 'position' key with {x, y}")
			var pos_d = pt["position"]
			var pos := Vector2(float(pos_d.get("x", 0.0)), float(pos_d.get("y", 0.0)))
			var lt := float(pt.get("left_tangent", 0.0))
			var rt := float(pt.get("right_tangent", 0.0))
			var lm := _tangent_mode(pt.get("left_mode", null))
			var rm := _tangent_mode(pt.get("right_mode", null))
			curve.add_point(pos, lt, rt, lm, rm)
		"remove_point":
			if index_raw == null:
				return MCPToolkitError.fail("INVALID_PARAMS",
					"action 'remove_point' requires an 'index'")
			var index := int(index_raw)
			if index < 0 or index >= curve.point_count:
				return MCPToolkitError.fail("INVALID_PARAMS",
					"index %d out of range (point_count=%d)" % [index, curve.point_count])
			curve.remove_point(index)
		"clear":
			curve.clear_points()

	return await _save_resource(curve, file_path, "procedural.edit_curve",
		{"point_count": curve.point_count})


static func _cmd_edit_noise(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path"])
	if err != null:
		return err

	var file_path := str(parameters.get("file_path", ""))
	file_path = Helpers.normalize_editor_path(file_path)

	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if file_path.get_extension().to_lower() != "tres":
		return MCPToolkitError.fail("INVALID_PATH",
			"procedural.edit_noise writes .tres files (got %s)" % file_path)

	# Load or create FastNoiseLite.
	var noise: FastNoiseLite
	if FileAccess.file_exists(file_path):
		var loaded = ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if loaded == null or not (loaded is FastNoiseLite):
			return MCPToolkitError.fail("INVALID_CLASS",
				"Resource at %s is not a FastNoiseLite" % file_path)
		noise = loaded as FastNoiseLite
	else:
		noise = FastNoiseLite.new()

	# Noise type.
	var noise_type_raw = parameters.get("noise_type", null)
	if noise_type_raw != null:
		var nt_str := str(noise_type_raw)
		var nt_map := {
			"simplex": FastNoiseLite.TYPE_SIMPLEX,
			"simplex_smooth": FastNoiseLite.TYPE_SIMPLEX_SMOOTH,
			"cellular": FastNoiseLite.TYPE_CELLULAR,
			"perlin": FastNoiseLite.TYPE_PERLIN,
			"value": FastNoiseLite.TYPE_VALUE,
			"value_cubic": FastNoiseLite.TYPE_VALUE_CUBIC,
		}
		if not nt_map.has(nt_str):
			return MCPToolkitError.fail("INVALID_PARAMS",
				"noise_type must be one of: %s (got '%s')" % [
					", ".join(nt_map.keys()), nt_str])
		noise.noise_type = nt_map[nt_str]

	# Simple numeric properties.
	if parameters.has("seed"):
		noise.seed = int(parameters["seed"])
	if parameters.has("frequency"):
		noise.frequency = float(parameters["frequency"])
	if parameters.has("octaves"):
		noise.fractal_octaves = int(parameters["octaves"])
	if parameters.has("lacunarity"):
		noise.fractal_lacunarity = float(parameters["lacunarity"])
	if parameters.has("gain"):
		noise.fractal_gain = float(parameters["gain"])

	# Fractal type.
	var fractal_raw = parameters.get("fractal_type", null)
	if fractal_raw != null:
		var ft_str := str(fractal_raw)
		var ft_map := {
			"none": FastNoiseLite.FRACTAL_NONE,
			"fbm": FastNoiseLite.FRACTAL_FBM,
			"ridged": FastNoiseLite.FRACTAL_RIDGED,
			"ping_pong": FastNoiseLite.FRACTAL_PING_PONG,
		}
		if not ft_map.has(ft_str):
			return MCPToolkitError.fail("INVALID_PARAMS",
				"fractal_type must be one of: %s (got '%s')" % [
					", ".join(ft_map.keys()), ft_str])
		noise.fractal_type = ft_map[ft_str]

	# Cellular distance function.
	var cdf_raw = parameters.get("cellular_distance_function", null)
	if cdf_raw != null:
		var cdf_str := str(cdf_raw)
		var cdf_map := {
			"euclidean": FastNoiseLite.DISTANCE_EUCLIDEAN,
			"euclidean_squared": FastNoiseLite.DISTANCE_EUCLIDEAN_SQUARED,
			"manhattan": FastNoiseLite.DISTANCE_MANHATTAN,
			"hybrid": FastNoiseLite.DISTANCE_HYBRID,
		}
		if not cdf_map.has(cdf_str):
			return MCPToolkitError.fail("INVALID_PARAMS",
				"cellular_distance_function must be one of: %s (got '%s')" % [
					", ".join(cdf_map.keys()), cdf_str])
		noise.cellular_distance_function = cdf_map[cdf_str]

	# Cellular return type.
	var crt_raw = parameters.get("cellular_return_type", null)
	if crt_raw != null:
		var crt_str := str(crt_raw)
		var crt_map := {
			"cell_value": FastNoiseLite.RETURN_CELL_VALUE,
			"distance": FastNoiseLite.RETURN_DISTANCE,
			"distance2": FastNoiseLite.RETURN_DISTANCE2,
			"distance2_add": FastNoiseLite.RETURN_DISTANCE2_ADD,
			"distance2_sub": FastNoiseLite.RETURN_DISTANCE2_SUB,
			"distance2_mul": FastNoiseLite.RETURN_DISTANCE2_MUL,
			"distance2_div": FastNoiseLite.RETURN_DISTANCE2_DIV,
		}
		if not crt_map.has(crt_str):
			return MCPToolkitError.fail("INVALID_PARAMS",
				"cellular_return_type must be one of: %s (got '%s')" % [
					", ".join(crt_map.keys()), crt_str])
		noise.cellular_return_type = crt_map[crt_str]

	# Domain warp.
	if parameters.has("domain_warp_enabled"):
		noise.domain_warp_enabled = bool(parameters["domain_warp_enabled"])
	if parameters.has("domain_warp_amplitude"):
		noise.domain_warp_amplitude = float(parameters["domain_warp_amplitude"])

	return await _save_resource(noise, file_path, "procedural.edit_noise",
		{"noise_type": noise.noise_type})


# -- Helpers ------------------------------------------------------------------


static func _color(d: Variant) -> Color:
	return Coerce.color_from_dict(d)


static func _tangent_mode(val) -> int:
	if val == null:
		return Curve.TANGENT_FREE
	var s := str(val)
	if s == "linear":
		return Curve.TANGENT_LINEAR
	return Curve.TANGENT_FREE


static func _save_resource(resource: Resource, file_path: String,
		cmd_name: String, extra: Dictionary) -> Dictionary:
	var dir_result := Helpers.ensure_parent_dir(file_path, cmd_name)
	if dir_result.has("error"):
		return dir_result
	var save_err := ResourceSaver.save(resource, file_path)
	if save_err != OK:
		return MCPToolkitError.fail("SAVE_FAILED",
			"ResourceSaver.save returned %d (path=%s)" % [save_err, file_path])
	ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	await Helpers.ensure_file_indexed(file_path)
	var result := {"file_path": file_path}
	result.merge(extra)
	return MCPToolkitSuccess.ok(result)
