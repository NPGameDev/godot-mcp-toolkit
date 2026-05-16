# Section 16 — 3D, Path2D, Navigation, Particles, Procedural

**Dependencies:** Section 2 (Sv2Path, Sv2NavRegion exist in main.tscn)
**Tools tested:** 3d_create_primitive, 3d_setup_environment, 3d_create_light, 3d_create_camera, path2d_edit_curve, navigation_edit_polygon, particles_create, procedural_edit_gradient, procedural_edit_curve, procedural_edit_noise
**Tests:** 28

---

## 3D Primitives (6 tests)

**16.1** `3d_create_primitive` — parent_path=`.`, primitive=`box`, size=`{"x":2,"y":2,"z":2}`, material=`{"type":"StandardMaterial3D","albedo_color":{"r":0.8,"g":0.2,"b":0.2}}`
- **Expect:** success, MeshInstance3D created

**16.2** `3d_create_primitive` — primitive=`sphere`, name=`Sv2Sphere`
- **Expect:** success

**16.3** `3d_setup_environment` — sky_type=`ProceduralSkyMaterial`, tonemap=`filmic`
- **Expect:** success, WorldEnvironment created

**16.4** `3d_create_light` — light_type=`directional`, shadow=`true`
- **Expect:** success

**16.5** `3d_create_camera` — projection=`perspective`, fov=75
- **Expect:** success

**16.6** `3d_create_primitive` guard — primitive=`invalid_shape`
- **Expect:** INVALID_PARAMS

## Path2D (5 tests)

**16.7** `path2d_edit_curve` — action=`set`, node_path=`Sv2Path`, points=[{position:{x:0,y:0}},{position:{x:100,y:50}},{position:{x:200,y:0}},{position:{x:300,y:50}}]
- **Expect:** success, point_count=4

**16.8** `path2d_edit_curve` — action=`add`, node_path=`Sv2Path`, index=2, points=[{position:{x:150,y:100}}]
- **Expect:** success, point_count=5

**16.9** `path2d_edit_curve` — action=`remove`, node_path=`Sv2Path`, index=0
- **Expect:** success, point_count=4

**16.10** `path2d_edit_curve` guard — node_path=`Sv2Sprite`
- **Expect:** INVALID_CLASS mentioning Path2D

**16.11** `path2d_edit_curve` — action=`clear`, node_path=`Sv2Path`
- **Expect:** success, point_count=0

## Navigation (5 tests)

**16.12** `navigation_edit_polygon` — action=`set`, node_path=`Sv2NavRegion`, outlines=`[[{x:0,y:0},{x:800,y:0},{x:800,y:600},{x:0,y:600}]]`
- **Expect:** success, outline_count=1

**16.13** `navigation_edit_polygon` — action=`add_outline`, node_path=`Sv2NavRegion`, outline=[{x:200,y:200},{x:400,y:200},{x:400,y:400},{x:200,y:400}]
- **Expect:** success, outline_count=2

**16.14** `navigation_edit_polygon` — action=`bake`, node_path=`Sv2NavRegion`
- **Expect:** success, polygon_count > 0

**16.15** `navigation_edit_polygon` — action=`remove_outline`, node_path=`Sv2NavRegion`, index=1
- **Expect:** success, outline_count=1

**16.16** `navigation_edit_polygon` guard — node_path=`.`
- **Expect:** INVALID_CLASS (scene root is Node2D, not NavigationRegion2D)

## Particles (7 tests)

**16.17** `particles_create` — parent_path=`.`, type=`"2d"`, preset=`"fire"`
- **Expect:** success, GPUParticles2D created

**16.18** `particles_create` — type=`"2d"`, preset=`"rain"`, amount=100
- **Expect:** success, overrides_applied includes "amount"

**16.19** `particles_create` — type=`"3d"`, preset=`"sparks"`, mesh=`"quad"`
- **Expect:** success, draw_pass_1 is QuadMesh

**16.20** All 8 presets quick check — create each with type="2d": fire, smoke, sparks, rain, snow, explosion, magic, dust
- **Expect:** 8 successes (lightweight — only verify success + emitting)

**16.21** `particles_create` guard — type=`"4d"`
- **Expect:** INVALID_PARAMS

**16.22** `particles_create` guard — preset=`"lava"`
- **Expect:** INVALID_PARAMS

**16.23** `particles_create` guard — parent_path=`"NonExistent"`
- **Expect:** NOT_FOUND

## Procedural Resources (5 tests)

**16.24** `procedural_edit_gradient` — file_path=`res://sv2_validation/gradient.tres`, action=`set`, points=[{offset:0, color:{r:1,g:0,b:0}}, {offset:0.5, color:{r:0,g:1,b:0}}, {offset:1, color:{r:0,g:0,b:1}}]
- **Expect:** success, point_count=3

**16.25** `procedural_edit_gradient` — file_path=`res://sv2_validation/gradient.tres`, action=`add_point`, offset=0.75, color={r:1,g:1,b:0}
- **Expect:** success, point_count=4

**16.26** `procedural_edit_curve` — file_path=`res://sv2_validation/curve.tres`, action=`set`, points=[{x:0,y:0},{x:0.5,y:1},{x:1,y:0}]
- **Expect:** success, point_count=3

**16.27** `procedural_edit_noise` — file_path=`res://sv2_validation/noise.tres`, noise_type=`simplex`, frequency=0.05
- **Expect:** success

**16.28** `procedural_edit_noise` guard — noise_type=`invalid_noise`
- **Expect:** INVALID_PARAMS

---

## Cleanup

- Delete all 3D nodes: any MeshInstance3D, WorldEnvironment, DirectionalLight3D, Camera3D created in 16.1-16.5
- Delete particle nodes: all GPUParticles2D/3D nodes created in 16.17-16.20
- Delete procedural resources: `resource_delete` gradient.tres, curve.tres, noise.tres
- If `scene_advanced` or `editor_advanced` groups were activated: call `discover_tools` with reset=["scene_advanced", "editor_advanced"] to deactivate them
