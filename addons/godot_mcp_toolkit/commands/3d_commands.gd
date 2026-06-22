@tool
extends RefCounted
## 3d.* command handlers — create 3D primitives, lights, cameras,
## and environment setups in the edited scene.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Coerce = Modules.Coerce
const Helpers = Modules.CommandHelpers

const _VALID_PRIMITIVES := ["box", "sphere", "cylinder", "capsule", "plane", "prism"]
const _VALID_LIGHT_TYPES := ["directional", "omni", "spot"]
const _VALID_PROJECTIONS := ["perspective", "orthogonal"]
const _VALID_TONEMAPS := ["linear", "reinhardt", "filmic", "aces"]


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("3d.create_primitive", func(parameters: Dictionary) -> Dictionary:
		return _cmd_create_primitive(parameters)
	, MCPToolkitCommandOptions.new())
	registry.add("3d.setup_environment", func(parameters: Dictionary) -> Dictionary:
		return _cmd_setup_environment(parameters)
	, MCPToolkitCommandOptions.new())
	registry.add("3d.create_light", func(parameters: Dictionary) -> Dictionary:
		return _cmd_create_light(parameters)
	, MCPToolkitCommandOptions.new())
	registry.add("3d.create_camera", func(parameters: Dictionary) -> Dictionary:
		return _cmd_create_camera(parameters)
	, MCPToolkitCommandOptions.new())


# -- Helpers ------------------------------------------------------------------


static func _vec3(d: Variant) -> Vector3:
	if typeof(d) != TYPE_DICTIONARY:
		return Vector3.ZERO
	return Vector3(float(d.get("x", 0.0)), float(d.get("y", 0.0)), float(d.get("z", 0.0)))


static func _color(d: Variant) -> Color:
	return Coerce.color_from_dict(d)


static func _path_in_scene(root: Node, node: Node) -> String:
	return str(root.get_path_to(node))


static func _resolve_parent(parameters: Dictionary) -> Variant:
	var root := Helpers.get_edited_root()
	if root == null:
		return MCPToolkitError.fail("NO_SCENE", "no edited scene")
	var parent_path := str(parameters.get("parent_path", "."))
	parent_path = Helpers.normalize_editor_path(parent_path)
	var parent := Helpers.resolve_scene_node(parent_path)
	if parent == null:
		return MCPToolkitError.fail("NOT_FOUND",
			"parent not found: %s" % parent_path, MCPToolkitError.HINT_NODE_PATH)
	return parent


static func _add_node_undoable(parent: Node, node: Node, root: Node) -> void:
	parent.add_child(node)
	node.set_owner(root)
	MCPToolkitUndoRedoAction.begin("create %s" % node.name, parent) \
		.do_method(parent.add_child.bind(node)) \
		.do_method(node.set_owner.bind(root)) \
		.do_reference(node) \
		.undo_method(parent.remove_child.bind(node)) \
		.commit_recorded()


# -- Commands -----------------------------------------------------------------


static func _cmd_create_primitive(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["parent_path", "primitive"])
	if err != null:
		return err

	var primitive := str(parameters.get("primitive", ""))
	if primitive not in _VALID_PRIMITIVES:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"invalid primitive '%s'; must be one of: %s" % [primitive, ", ".join(_VALID_PRIMITIVES)])

	var parent_result = _resolve_parent(parameters)
	if parent_result is Dictionary:
		return parent_result
	var parent: Node = parent_result
	var root := Helpers.get_edited_root()

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = str(parameters.get("name", "MeshInstance3D"))

	# Create appropriate mesh type.
	var mesh: Mesh
	match primitive:
		"box":
			var box := BoxMesh.new()
			if parameters.has("size"):
				box.size = _vec3(parameters["size"])
			mesh = box
		"sphere":
			var sphere := SphereMesh.new()
			if parameters.has("size"):
				var s = parameters["size"]
				if typeof(s) == TYPE_DICTIONARY:
					if s.has("x"):
						sphere.radius = float(s["x"]) / 2.0
					if s.has("y"):
						sphere.height = float(s["y"])
			mesh = sphere
		"cylinder":
			var cyl := CylinderMesh.new()
			if parameters.has("size"):
				var s = parameters["size"]
				if typeof(s) == TYPE_DICTIONARY:
					if s.has("x"):
						cyl.top_radius = float(s["x"]) / 2.0
						cyl.bottom_radius = float(s["x"]) / 2.0
					if s.has("y"):
						cyl.height = float(s["y"])
			mesh = cyl
		"capsule":
			var cap := CapsuleMesh.new()
			if parameters.has("size"):
				var s = parameters["size"]
				if typeof(s) == TYPE_DICTIONARY:
					if s.has("x"):
						cap.radius = float(s["x"]) / 2.0
					if s.has("y"):
						cap.height = float(s["y"])
			mesh = cap
		"plane":
			var plane := PlaneMesh.new()
			if parameters.has("size"):
				var s = parameters["size"]
				if typeof(s) == TYPE_DICTIONARY:
					plane.size = Vector2(
						float(s.get("x", 1.0)),
						float(s.get("z", 1.0)))
			mesh = plane
		"prism":
			var prism := PrismMesh.new()
			if parameters.has("size"):
				prism.size = _vec3(parameters["size"])
			mesh = prism

	mesh_instance.mesh = mesh

	# Material.
	if parameters.has("material"):
		var mat_data = parameters["material"]
		if typeof(mat_data) == TYPE_DICTIONARY:
			var mat := StandardMaterial3D.new()
			if mat_data.has("albedo_color"):
				mat.albedo_color = _color(mat_data["albedo_color"])
			if mat_data.has("metallic"):
				mat.metallic = float(mat_data["metallic"])
			if mat_data.has("roughness"):
				mat.roughness = float(mat_data["roughness"])
			mesh_instance.material_override = mat

	# Position.
	if parameters.has("position"):
		mesh_instance.position = _vec3(parameters["position"])

	_add_node_undoable(parent, mesh_instance, root)
	return MCPToolkitSuccess.ok({"status": "created", "path": _path_in_scene(root, mesh_instance)})


static func _cmd_setup_environment(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["parent_path"])
	if err != null:
		return err

	var parent_result = _resolve_parent(parameters)
	if parent_result is Dictionary:
		return parent_result
	var parent: Node = parent_result
	var root := Helpers.get_edited_root()

	var env := Environment.new()

	# Sky.
	var sky_data = parameters.get("sky", null)
	var sky_material: ProceduralSkyMaterial
	if sky_data != null and typeof(sky_data) == TYPE_DICTIONARY:
		sky_material = ProceduralSkyMaterial.new()
		if sky_data.has("sky_top_color"):
			sky_material.sky_top_color = _color(sky_data["sky_top_color"])
		if sky_data.has("sky_horizon_color"):
			sky_material.sky_horizon_color = _color(sky_data["sky_horizon_color"])
		if sky_data.has("ground_bottom_color"):
			sky_material.ground_bottom_color = _color(sky_data["ground_bottom_color"])
	else:
		sky_material = ProceduralSkyMaterial.new()

	var sky := Sky.new()
	sky.sky_material = sky_material
	env.sky = sky
	env.background_mode = Environment.BG_SKY

	# Ambient light.
	var ambient_data = parameters.get("ambient_light", null)
	if ambient_data != null and typeof(ambient_data) == TYPE_DICTIONARY:
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		if ambient_data.has("color"):
			env.ambient_light_color = _color(ambient_data["color"])
		if ambient_data.has("energy"):
			env.ambient_light_energy = float(ambient_data["energy"])

	# Tonemap.
	var tonemap_str := str(parameters.get("tonemap", ""))
	if not tonemap_str.is_empty():
		match tonemap_str:
			"linear":
				env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
			"reinhardt":
				env.tonemap_mode = Environment.TONE_MAPPER_REINHARDT
			"filmic":
				env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
			"aces":
				env.tonemap_mode = Environment.TONE_MAPPER_ACES

	# Fog.
	var fog_data = parameters.get("fog", null)
	if fog_data != null and typeof(fog_data) == TYPE_DICTIONARY:
		env.fog_enabled = bool(fog_data.get("enabled", true))
		if fog_data.has("color"):
			env.fog_light_color = _color(fog_data["color"])
		if fog_data.has("density"):
			env.fog_density = float(fog_data["density"])

	var world_env := WorldEnvironment.new()
	world_env.name = str(parameters.get("name", "WorldEnvironment"))
	world_env.environment = env

	_add_node_undoable(parent, world_env, root)
	return MCPToolkitSuccess.ok({"status": "created", "path": _path_in_scene(root, world_env)})


static func _cmd_create_light(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["parent_path", "light_type"])
	if err != null:
		return err

	var light_type := str(parameters.get("light_type", ""))
	if light_type not in _VALID_LIGHT_TYPES:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"invalid light_type '%s'; must be one of: %s" % [light_type, ", ".join(_VALID_LIGHT_TYPES)])

	var parent_result = _resolve_parent(parameters)
	if parent_result is Dictionary:
		return parent_result
	var parent: Node = parent_result
	var root := Helpers.get_edited_root()

	var light: Light3D
	match light_type:
		"directional":
			light = DirectionalLight3D.new()
			light.name = str(parameters.get("name", "DirectionalLight3D"))
		"omni":
			light = OmniLight3D.new()
			light.name = str(parameters.get("name", "OmniLight3D"))
		"spot":
			light = SpotLight3D.new()
			light.name = str(parameters.get("name", "SpotLight3D"))

	if parameters.has("color"):
		light.light_color = _color(parameters["color"])
	if parameters.has("energy"):
		light.light_energy = float(parameters["energy"])
	if parameters.has("shadow"):
		light.shadow_enabled = bool(parameters["shadow"])
	if parameters.has("position"):
		light.position = _vec3(parameters["position"])
	if parameters.has("rotation"):
		var rot = parameters["rotation"]
		if typeof(rot) == TYPE_DICTIONARY:
			light.rotation_degrees = _vec3(rot)

	_add_node_undoable(parent, light, root)
	return MCPToolkitSuccess.ok({"status": "created", "path": _path_in_scene(root, light)})


static func _cmd_create_camera(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["parent_path"])
	if err != null:
		return err

	var parent_result = _resolve_parent(parameters)
	if parent_result is Dictionary:
		return parent_result
	var parent: Node = parent_result
	var root := Helpers.get_edited_root()

	var camera := Camera3D.new()
	camera.name = str(parameters.get("name", "Camera3D"))

	var projection_str := str(parameters.get("projection", ""))
	if not projection_str.is_empty():
		match projection_str:
			"perspective":
				camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			"orthogonal":
				camera.projection = Camera3D.PROJECTION_ORTHOGONAL

	if parameters.has("fov"):
		camera.fov = float(parameters["fov"])
	if parameters.has("size"):
		camera.size = float(parameters["size"])
	if parameters.has("position"):
		camera.position = _vec3(parameters["position"])
	if parameters.has("rotation"):
		var rot = parameters["rotation"]
		if typeof(rot) == TYPE_DICTIONARY:
			camera.rotation_degrees = _vec3(rot)
	if parameters.has("current"):
		camera.current = bool(parameters["current"])

	_add_node_undoable(parent, camera, root)
	return MCPToolkitSuccess.ok({"status": "created", "path": _path_in_scene(root, camera)})
