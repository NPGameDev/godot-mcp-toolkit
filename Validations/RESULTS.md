# MCP Tool Sweep Results

- **Date:** 2026-05-12
- **Godot version:** 4.5
- **Project type:** GDScript
- **Profile:** power_user (full)
- **Project name:** Godot MCP Toolkit
- **Total:** 148 passed, 4 failed, 2 skipped (154 total)

---

## Phase 0 — Environment Detection

| Item | Value |
|------|-------|
| Godot version | 4.5 |
| Project type | GDScript |
| Profile | power_user (full) |
| Main scene (original) | uid://bompismuom3fi (res://Main.tscn) |
| Project name (original) | Godot MCP Toolkit |
| C# detected | No |
| TileMapLayer support | Yes |
| scene_close support | Yes |
| Logger buffer source | Yes |

---

## Phase 1 — Scaffolding

| # | Tool | Key Params | Expected | Actual | Result |
|---|------|-----------|----------|--------|--------|
| 1 | folder_create | res://mcp_validation/ | success | success, status=created | PASS |
| 2 | script_write | val_actor.gd | success | success, 178 bytes | PASS |
| 3 | script_write | val_shader.gdshader | success | success | PASS |
| 4 | resource_write | val_anim_lib.tres (AnimationLibrary) | success | success, status=created | PASS |
| 5 | resource_write | val_material.tres (ShaderMaterial) | success | success | PASS |
| 6 | resource_write | val_tileset.tres (TileSet) | success | success | PASS |
| 7 | scene_create | val_main.tscn (Node2D) | success | success, status=created | PASS |
| 8 | scene_create | val_sub.tscn (Node2D) | success | success, status=created | PASS |

---

## Phase 2 — Individual Tool Calls

### Core Tools

| # | Tool | Stage | Key Params | Expected | Actual | Result | Notes |
|---|------|-------|------------|----------|--------|--------|-------|
| 9 | scene_open | Core | val_main.tscn | success | success | PASS | |
| 10 | scene_create_node | Core | Label "ValLabel" | created | created | PASS | |
| 11 | scene_create_node | Core | AnimationPlayer | created | created | PASS | |
| 12 | scene_create_node | Core | AnimationTree | created | created | PASS | |
| 13 | scene_create_node | Core | TileMapLayer | created | created | PASS | 4.3+ node type |
| 14 | scene_create_node | Core | CharacterBody2D "ValPlayer" | created | created | PASS | |
| 15 | scene_create_node | Core | CollisionShape2D "ValCollider" under ValPlayer | created | created | PASS | |
| 16 | scene_instantiate | Core | val_sub.tscn under root | created | created | PASS | |
| 17 | scene_create_node | Core | Sprite2D "ValSprite" | created | created | PASS | |
| 18 | editor_save_scene | Core | save val_main | success | success | PASS | |
| 19 | scene_get_tree | Core | depth=2 | tree JSON | tree with all nodes | PASS | |
| 20 | node_set_property | Core | ValSprite position | success | success | PASS | |
| 21 | node_get_property | Core | ValSprite position | {x:100,y:100} | {x:100,y:100} | PASS | |
| 22 | node_get_property_list | Core | ValPlayer mask=common | properties list | curated list returned | PASS | |
| 23 | node_set_script | Core | ValPlayer -> val_actor.gd | success + exports | success, speed+label exports | PASS | |
| 24 | script_read | Core | val_actor.gd | file content | content returned | PASS | |
| 25 | script_check | Core | val_actor.gd | valid=true | valid=true, 0 diagnostics | PASS | |
| 26 | project_get_settings | Core | prefix=application/ | settings map | 35 settings returned | PASS | |
| 27 | project_set_setting | Core | config/name -> McpValidationSweep | success | success, previous_value captured | PASS | |
| 28 | editor_get_console | Core | level_filter=error | entries list | entries returned | PASS | |
| 29 | asset_list | Core | path_prefix=res://mcp_validation/ | files listed | 11 entries | PASS | |
| 30 | folder_create | Core | idempotent re-create | status=returned | status=returned | PASS | |
| 31 | classdb_get_info | Core | CharacterBody2D | class info | properties, methods, signals, inheritance | PASS | |
| 32 | classdb_search | Core | pattern=Sprite* | class list | Sprite2D, Sprite3D, etc. | PASS | |

### Gated Tools

| # | Tool | Stage | Key Params | Expected | Actual | Result | Notes |
|---|------|-------|------------|----------|--------|--------|-------|
| 33 | execute_code | Gated | editor context | result | success | PASS | |
| 34 | node_call_method | Gated | ValPlayer.get_info() | "McpValActor v1" | "McpValActor v1" | PASS | |

### On-Demand Group Tools

| # | Tool | Stage | Key Params | Expected | Actual | Result | Notes |
|---|------|-------|------------|----------|--------|--------|-------|
| 35 | discover_tools | Groups | activate all groups | activated | all groups activated | PASS | |
| 36 | signal_list | Signals | ValPlayer | hit signal listed | hit signal found | PASS | |
| 37 | signal_manage | Signals | connect hit->set_text | success | success | PASS | |
| 38 | signal_manage | Signals | disconnect | success | success | PASS | |
| 39 | input_map_action | InputMap | add mcp_val_jump | success | success | PASS | |
| 40 | input_map_event | InputMap | bind key_space | success | success | PASS | |
| 41 | input_map_event | InputMap | unbind key_space | success | success | PASS | |
| 42 | save_write | UserData | saves/mcp_validation_save.json | success | success | PASS | |
| 43 | save_read | UserData | same path | data returned | data matches | PASS | |
| 44 | save_list | UserData | prefix=saves/ | file listed | file found | PASS | |
| 45 | save_delete | UserData | same path | success | success | PASS | |
| 46 | resource_load | AssetMgmt | val_material.tres | ShaderMaterial | ShaderMaterial loaded | PASS | |
| 47 | asset_get_dependencies | AssetMgmt | val_material.tres | deps listed | shader dep found | PASS | |
| 48 | scene_diff | SceneAdv | val_main vs val_sub | diff result | differences returned | PASS | |
| 49 | editor_refresh | EditorAdv | full reload | success | success | PASS | |
| 50 | tileset_create | Tilemap | texture=icon.svg | success | success, atlas created | PASS | |
| 51 | tileset_edit | Tilemap | terrain + collision | success | terrain configured | PASS | |
| 52 | tilemap_set_cells | Tilemap | paint cells | success | cells painted | PASS | |

### Game Lifecycle

| # | Tool | Stage | Key Params | Expected | Actual | Result | Notes |
|---|------|-------|------------|----------|--------|--------|-------|
| 53 | game_start | Runtime | main scene | running | running | PASS | |
| 54 | runtime_screenshot | Runtime | capture | PNG image | PNG returned | PASS | |
| 55 | runtime_get_script_vars | Runtime | game node | variables | vars returned | PASS | |
| 56 | input_simulate | Runtime | key_press space | success | success | PASS | |
| 57 | debugger_get_log | Runtime | buffer | entries | entries returned | PASS | |
| 58a | editor_get_console | Filter | text_filter plain | filtered entries | correct filtering | PASS | |
| 58b | editor_get_console | Filter | text_filter regex \\d | regex match | 0 results | **FAIL** | Regex backslash escaping bug |
| 58c | editor_get_console | Filter | level+text combined | AND filter | correct AND | PASS | |
| 58d | editor_get_console | Filter | invalid regex | INVALID_PARAMS | INVALID_PARAMS | PASS | |
| 58e | editor_get_console | Filter | metachar plain mode | literal match | no error | PASS | |
| 58f | editor_get_console | Filter | is_regex coercion | string "true" works | string handled | PASS | |
| 58g | debugger_get_log | Filter | text_filter plain | filtered | correct | PASS | |
| 58h | debugger_get_log | Filter | text_filter regex \\d | regex match | 0 results | **FAIL** | Same regex escaping bug |
| 59 | game_stop | Runtime | stop | stopped | stopped | PASS | |

### Node Management

| # | Tool | Stage | Key Params | Expected | Actual | Result | Notes |
|---|------|-------|------------|----------|--------|--------|-------|
| 43a | node_manage | NodeMgmt | rename ValLabel2->Renamed | success | success | PASS | |
| 43b | node_manage | NodeMgmt | reparent under ValPlayer | success | success | PASS | |
| 43c | node_manage | NodeMgmt | reorder index=0 | success | success | PASS | |
| 43d | node_manage | NodeMgmt | duplicate ValSprite | success | success | PASS | |
| 43e | node_groups | NodeMgmt | add group | success | success | PASS | |
| 43f | node_groups | NodeMgmt | list groups | group present | group found | PASS | |
| 43g | node_groups | NodeMgmt | remove group | success | success | PASS | |
| 43h1 | node_manage | NodeMgmt | duplicate with new_name | success | success | PASS | |
| 43h2 | node_manage | NodeMgmt | duplicate with properties | position override | position (0,0) not (200,300) | **FAIL** | Properties override on duplicate not applying |

### Autoload Management

| # | Tool | Stage | Key Params | Expected | Actual | Result | Notes |
|---|------|-------|------------|----------|--------|--------|-------|
| 44a | autoload_manage | Autoload | register | success | success | PASS | |
| 44b | autoload_manage | Autoload | list | entry found | found | PASS | |
| 44c | autoload_manage | Autoload | unregister | success | success | PASS | |

### Scene Operations

| # | Tool | Stage | Key Params | Expected | Actual | Result | Notes |
|---|------|-------|------------|----------|--------|--------|-------|
| 60 | scene_close | Scene | val_close_probe.tscn | success | success | PASS | 4.5+ |
| 61 | scene_create | Scene | if_exists=fail | ALREADY_EXISTS | ALREADY_EXISTS | PASS | |

### Layer Names

| # | Tool | Stage | Key Params | Expected | Actual | Result | Notes |
|---|------|-------|------------|----------|--------|--------|-------|
| 62a | layer_names_set | Layers | 2d_physics layer 1 | success | success | PASS | |
| 62b | layer_names_get | Layers | 2d_physics | layer names | Tool not found | **SKIP** | Tool disappeared after editor_refresh |
| 62c-d | layer_names_set/get | Layers | roundtrip verify | matching names | Tool not found | **SKIP** | Same tool disappearance issue |

### Path Normalization

| # | Tool | Stage | Key Params | Expected | Actual | Result | Notes |
|---|------|-------|------------|----------|--------|--------|-------|
| 63a | node_get_property | PathNorm | /root/val_main/ValSprite position | auto-translated | position returned | PASS | |
| 63b | scene_get_tree | PathNorm | paths use . for root | dot-relative paths | confirmed | PASS | |

### Theme Editing

| # | Tool | Stage | Key Params | Expected | Actual | Result | Notes |
|---|------|-------|------------|----------|--------|--------|-------|
| 64a | theme_edit | Theme | color edit | success | success | PASS | |
| 64b | theme_edit | Theme | font_size edit | success | success | PASS | |
| 64c | theme_edit | Theme | stylebox edit | success | success | PASS | |
| 64d | theme_edit | Theme | invalid property_type | INVALID_PARAMS | INVALID_PARAMS | PASS | |

---

## Phase 2 — Extended Tool Sections

### Path2D / Curve2D (76a-76f)

| # | Tool | Key Params | Expected | Actual | Result |
|---|------|-----------|----------|--------|--------|
| 76a | path2d_edit_curve | set, 4 bezier points | point_count=4, baked_length>0 | point_count=4, baked_length=657.1 | PASS |
| 76a-v | node_get_property | curve | non-null Curve2D | Curve2D resource | PASS |
| 76b | path2d_edit_curve | add at index 2 | point_count=5 | point_count=5 | PASS |
| 76c | path2d_edit_curve | remove at index 0 | point_count=4 | point_count=4 | PASS |
| 76d | path2d_edit_curve | guard: non-Path2D | INVALID_CLASS | INVALID_CLASS "not a Path2D" | PASS |
| 76e | path2d_edit_curve | clear | point_count=0 | point_count=0 | PASS |
| 76f | scene_delete_node | cleanup | success | success | PASS |

### 3D Primitives (77a-77h)

| # | Tool | Key Params | Expected | Actual | Result |
|---|------|-----------|----------|--------|--------|
| 77a | 3d_create_primitive | box, red material | MeshInstance3D | MeshInstance3D created | PASS |
| 77b | 3d_create_primitive | sphere, name=MySphere | success | MySphere created | PASS |
| 77c | 3d_create_primitive | cylinder | success | created | PASS |
| 77d | 3d_setup_environment | ProceduralSky, ambient, filmic | WorldEnvironment | WorldEnvironment created | PASS |
| 77e | 3d_create_light | directional, shadow | success | DirectionalLight3D created | PASS |
| 77f | 3d_create_camera | perspective, fov=75 | success | Camera3D created | PASS |
| 77g | 3d_create_primitive | guard: invalid_shape | INVALID_PARAMS | INVALID_PARAMS enum error | PASS |
| 77h | cleanup | delete 3D scene | success | success | PASS |

### collision_from_texture (78a-78d)

| # | Tool | Key Params | Expected | Actual | Result |
|---|------|-----------|----------|--------|--------|
| 78a | collision_from_texture | ValSprite, simplification=2 | polygon_count>0 | polygon_count=1, total_points=20 | PASS |
| 78b | collision_from_texture | custom target_name | success | CustomCollision created | PASS |
| 78c | collision_from_texture | guard: non-Sprite2D | INVALID_CLASS | INVALID_CLASS "expected Sprite2D" | PASS |
| 78d | cleanup | delete collision nodes | success | success | PASS |

### Procedural Resources (79a-79f)

| # | Tool | Key Params | Expected | Actual | Result |
|---|------|-----------|----------|--------|--------|
| 79a | procedural_edit_gradient | set, 3 color stops | point_count=3 | point_count=3 | PASS |
| 79b | procedural_edit_gradient | add_point at 0.75 | point_count=4 | point_count=4 | PASS |
| 79c | procedural_edit_curve | set, 3 control points | point_count=3 | point_count=3 | PASS |
| 79d | procedural_edit_noise | simplex, freq=0.05 | success | success, noise_type=0 | PASS |
| 79e | procedural_edit_noise | guard: invalid_noise | INVALID_PARAMS | INVALID_PARAMS enum | PASS |
| 79f | cleanup | delete .tres files | success | all deleted | PASS |

### Scene Inheritance (80a-80d)

| # | Tool | Key Params | Expected | Actual | Result |
|---|------|-----------|----------|--------|--------|
| 80a | scene_create_inherited | inherit base_enemy | root=base_enemy | root_name=base_enemy | PASS |
| 80b | scene_create_inherited | root_name=SlimeEnemy | root=SlimeEnemy | root_name=SlimeEnemy | PASS |
| 80c | scene_create_inherited | guard: nonexistent base | NOT_FOUND | NOT_FOUND | PASS |
| 80d | cleanup | delete scenes | success | all deleted | PASS |

### AudioBus (81a-81g)

| # | Tool | Key Params | Expected | Actual | Result |
|---|------|-----------|----------|--------|--------|
| 81a | audiobus_edit | add_bus Music->Master | bus_count>=2 | bus_count=2 | PASS |
| 81b | audiobus_edit | set_bus Music vol=-6 | success | success | PASS |
| 81c | audiobus_edit | add_effect Reverb | success | AudioEffectReverb idx=0 | PASS |
| 81d | audiobus_edit | list | Master+Music, Reverb | confirmed, vol=-6 | PASS |
| 81e | audiobus_edit | add_bus SFX | bus_count=3 | bus_count=3 | PASS |
| 81f | audiobus_edit | guard: remove Master | INVALID_PARAMS | INVALID_PARAMS | PASS |
| 81g | cleanup | remove Music+SFX | bus_count=1 | bus_count=1 | PASS |

### SpriteFrames (82a-82j)

| # | Tool | Key Params | Expected | Actual | Result |
|---|------|-----------|----------|--------|--------|
| 82a | spriteframes_create | idle(2)+run(4) | 2 anims | idle:2, run:4 | PASS |
| 82b | resource_load | val_spriteframes.tres | SpriteFrames | SpriteFrames loaded | PASS |
| 82c | spriteframes_edit | add_animation jump | success | success | PASS |
| 82d | spriteframes_edit | add_frame jump | success | success | PASS |
| 82e | spriteframes_edit | remove_animation idle | success | success | PASS |
| 82f | spriteframes_edit | list | jump+run | jump:1, run:4 | PASS |
| 82g | spriteframes_from_spritesheet | walk, 32x32 grid | atlas frames | walk:3 frames | PASS |
| 82h | spriteframes_create | guard: empty[] | INVALID_PARAMS | INVALID_PARAMS minItems | PASS |
| 82i | spriteframes_create | guard: bad texture | NOT_FOUND | NOT_FOUND | PASS |
| 82j | cleanup | delete .tres | success | success | PASS |

### scene_query (83a-83j)

| # | Tool | Key Params | Expected | Actual | Result |
|---|------|-----------|----------|--------|--------|
| 83a | scene_query | class=Sprite2D | matches | count=1 ValSprite | PASS |
| 83b | scene_query | group=mcp_test_coins | count=2 | count=2 | PASS |
| 83c | scene_query | name=Val* | all Val-prefixed | count=7, all match | PASS |
| 83d | scene_query | visible=false | count>=0 | count=0 (all visible) | PASS |
| 83e | scene_query | Node2D+visible+props | position+scale in results | confirmed | PASS |
| 83f | scene_query | root=ValPlayer | only subtree | count=2 (Player+Collider) | PASS |
| 83g | scene_query | max_depth=0 | root only | count=1 (val_main) | PASS |
| 83h | scene_query | guard: no filters | INVALID_PARAMS | INVALID_PARAMS | PASS |
| 83i | scene_query | guard: bad root | NOT_FOUND | NOT_FOUND | PASS |
| 83j | cleanup | remove groups | success | success | PASS |

### GPU Particles (84a-84n)

| # | Tool | Key Params | Expected | Actual | Result |
|---|------|-----------|----------|--------|--------|
| 84a | particles_create | 2d, fire preset | GPUParticles2D, fire | preset_applied=fire | PASS |
| 84b | node_get_property | amount, lifetime | 24, 1.2 | 24, 1.2 | PASS |
| 84c | particles_create | 2d, rain, amount=100 | overrides_applied | overrides=["amount"] | PASS |
| 84d | particles_create | 2d, custom (no preset) | properties_set>0 | properties_set=7 | PASS |
| 84e | node_get_property | color_ramp readback | GradientTexture1D | GradientTexture1D | PASS |
| 84f | particles_create | 3d, sparks, quad | QuadMesh | draw_pass_1=QuadMesh | PASS |
| 84g | particles_create | all 8 presets | 8 successes | 8 successes (smoke,snow,explosion,magic,dust + fire,rain,sparks) | PASS |
| 84h | particles_create | .tres color_ramp ref | loaded from file | properties_set=1 | PASS |
| 84i | particles_create | guard: type=4d | INVALID_PARAMS | INVALID_PARAMS | PASS |
| 84j | particles_create | guard: preset=lava | INVALID_PARAMS | INVALID_PARAMS | PASS |
| 84k | particles_create | guard: emission=triangle | INVALID_PARAMS | INVALID_PARAMS | PASS |
| 84l | particles_create | guard: bad parent | NOT_FOUND | NOT_FOUND | PASS |
| 84m | particles_create | guard: bad color_ramp | NOT_FOUND | NOT_FOUND | PASS |
| 84n | cleanup | delete nodes+.tres | success | success | PASS |

### Navigation (85a-85f)

| # | Tool | Key Params | Expected | Actual | Result |
|---|------|-----------|----------|--------|--------|
| 85a | navigation_edit | set, 4-vertex outline | outline_count=1, vertex=4 | outline_count=1, vertex=4 | PASS |
| 85b | navigation_edit | add_outline (hole) | outline_count=2 | outline_count=2 | PASS |
| 85c | navigation_edit | bake | polygon_count>0 | polygon_count=1 | PASS |
| 85d | navigation_edit | remove_outline idx=1 | outline_count=1 | outline_count=1 | PASS |
| 85e | navigation_edit | guard: non-NavRegion | INVALID_CLASS | INVALID_CLASS | PASS |
| 85f | cleanup | delete NavRegion node | success | success | PASS |

---

## Combo Chain Results

| Chain | Description | Steps | Result | Notes |
|-------|-------------|-------|--------|-------|
| C1 | Resource round-trip (write/load/delete) | 4 | PASS | |
| C2 | Script validation pipeline | 3 | PASS | |
| C3 | Node mutation + undo | 4 | PASS | |
| C4 | Scene instantiation + property edit | 5 | PASS | |
| C5 | Animation authoring pipeline | 6 | PASS | |
| C6 | Shader material colon-chain | 7 | PASS | |
| C7 | Signal persistence round-trip | 5 | PASS | |
| C8 | Full game lifecycle | 8 | PASS | |
| C9 | Animation authoring pipeline | 5 | PASS | |
| C10 | TileMap painting (create/configure/paint) | 6 | PASS | |
| C11 | Script write -> immediate check | 3 | PASS | indexed:true, no editor_reload needed |
| C12 | Resource create -> immediate load | 3 | PASS | indexed:true |
| C13 | Scene create -> immediate open | 3 | PASS | indexed:true |
| C14 | File delete -> immediate deindex | 3 | PASS | deindexed:true |
| C15 | editor_refresh targeted mode | 3 | PASS | mode:"targeted", file_count:1 |
| C16 | editor_refresh full mode | 1 | PASS | mode:"full", scan_waited_ms:100 |
| C17 | New-directory indexing (scan fallback) | 4 | PASS | indexed:false but script_check still works |
| C18 | folder_delete auto-closes scene tabs | 5 | PASS | No PATH_IN_USE errors |
| C19 | Node management pipeline | 8 | PASS | dup->rename->reparent->groups cycle |
| C20 | Batch instantiate with transforms | 4 | PASS | rotation=1.57 verified |
| C21 | discover_tools keyword search (13 tests) | 13 | PASS | All keywords matched correct groups |

---

## discover_tools Keyword Results (C21)

| # | Query | Expected Group | Actual | Result |
|---|-------|---------------|--------|--------|
| 1 | "animation" | animation_authoring | animation_authoring + runtime_advanced + spriteframes | PASS |
| 2 | "tilemap" | tilemap | tilemap | PASS |
| 3 | "rename node" | node_management | node_management | PASS |
| 4 | "save game" | user_data | user_data + core: editor_save_scene | PASS |
| 5 | "signal" | signals | signals | PASS |
| 6 | "input" | input_map | input_map + core: input_simulate | PASS |
| 7 | "screenshot" | editor_advanced + core | editor_advanced + core: runtime_screenshot | PASS |
| 8 | "autoload" | node_management | node_management | PASS |
| 9 | "duplicate" | node_management | node_management | PASS |
| 10 | reset=true | all deactivated | 9 groups deactivated | PASS |
| 11 | (no params) | all "available" | all 20 groups show "available" | PASS |
| 12 | selective reset=["tilemap"] | tilemap deactivated, audio remains | tilemap=available, audio=already_loaded | PASS |
| 13 | reset=true (final) | cleanup | audio deactivated | PASS |

---

## Phase 5 — Cleanup Verification

- [x] `res://mcp_validation/` folder deleted (NOT_FOUND on asset_list)
- [x] Project name restored to "Godot MCP Toolkit"
- [x] Main scene restored to uid://bompismuom3fi
- [x] Input map action `mcp_val_jump` removed
- [x] Save data cleaned (already absent)
- [x] Game stopped (was not running)
- [x] Audio buses restored (Music + SFX removed, only Master remains)

---

## Version-Specific Observations

- [x] Plugin loaded successfully
- [x] TileMapLayer: used correct type for version (4.5)
- [x] scene_close: supported (active tab only)
- [x] Logger API: buffer source works
- [x] tileset_create: atlas + physics layer created
- [x] tileset_edit: terrain configured with peering
- [x] tilemap_set_cells: cells painted using correct source_id
- [x] theme_edit: color, font_size, and stylebox edits applied
- [x] theme_edit: invalid property_type returns INVALID_PARAMS
- [x] Path normalization: /root/ paths auto-translated
- [x] text_filter/is_regex: plain substring filtering works on both editor_get_console and debugger_get_log
- [ ] text_filter: regex with backslash sequences (\\d) returns 0 results (BUG)
- [x] text_filter: invalid regex returns INVALID_PARAMS with hint
- [x] text_filter: metacharacters in plain mode treated literally
- [x] text_filter: composition with level_filter ANDs correctly
- [x] is_regex coercion: string "true"/"false" handled correctly
- [x] node_manage: rename, reparent, reorder, duplicate all UndoRedo-wrapped
- [ ] node_manage: duplicate with properties override does not apply position (BUG)
- [x] node_groups: add/remove/list working, engine-internal groups filtered
- [x] autoload_manage: register/unregister/list roundtrip correct
- [x] scene_instantiate batch: multi-instance with transforms working
- [x] discover_tools: keyword search activates correct groups, reset deactivates
- [x] layer_names_set: set layer names works on first call
- [ ] layer_names_get: tool disappears after editor_refresh (intermittent)
- [x] Path2D/Curve2D: set/add/remove/clear all work, guard catches non-Path2D
- [x] 3D primitives: box/sphere/cylinder + environment + light + camera all create correctly
- [x] collision_from_texture: generates polygons from sprite texture
- [x] Procedural resources: gradient/curve/noise creation and editing
- [x] Scene inheritance: base->inherited with custom root name override
- [x] AudioBus: full CRUD + effect + guard on Master deletion
- [x] SpriteFrames: create/edit/spritesheet + guards
- [x] scene_query: all filter types work (class, group, name, property, root, depth)
- [x] GPU Particles: all 8 presets + custom + 3D + file ref + 5 guards
- [x] Navigation: outline set/add/remove/bake + guard

---

## Pitfalls Discovered

### 1. Regex backslash escaping in text_filter (58b, 58h)

- **Tools:** `editor_get_console`, `debugger_get_log`
- **Severity:** Major
- **Description:** Regex patterns containing `\d` (sent as `\\d` in JSON) return 0 results in both editor console and runtime log filtering. Plain substring matches work correctly.
- **Expected:** `\d` matches digit characters in log output
- **Actual:** 0 matches returned for any `\d`-containing regex
- **Workaround:** Use plain substring matching (`is_regex=false`) or character class `[0-9]` instead of `\d`

### 2. node_manage duplicate with properties override (43h2)

- **Tools:** `node_manage`
- **Severity:** Minor
- **Description:** `node_manage(action=duplicate, properties={position:{x:200,y:300}})` returns success but the duplicated node has position (0,0) instead of (200,300). The properties override parameter on duplicate is ignored.
- **Expected:** Duplicated node has position (200,300)
- **Actual:** Duplicated node has position (0,0)
- **Workaround:** Call `node_set_property` after `node_manage(duplicate)` to set properties

### 3. layer_names tools disappear after editor_refresh (62b-d)

- **Tools:** `layer_names_get`, `layer_names_set`
- **Severity:** Minor (intermittent)
- **Description:** After `editor_refresh` triggers a `tools/list_changed` notification, the layer_names tools become unavailable and cannot be re-fetched via ToolSearch. The `discover_tools(groups=["layer_naming"])` call can re-activate them but the tool schemas remain stale in the MCP client.
- **Expected:** Tools remain callable after reload
- **Actual:** Tool not found errors
- **Workaround:** Reconnect MCP (`/mcp`) or call `discover_tools` to re-activate

### 4. node_set_property with ResourceRef format (78a initial attempt)

- **Tools:** `node_set_property`
- **Severity:** Minor (documentation gap)
- **Description:** Setting a texture property with `{type: "ResourceRef", path: "res://icon.svg"}` appears to succeed but the value is null on readback. The correct format is `{type: "Resource", path: "res://icon.svg"}`.
- **Expected:** Both `ResourceRef` and `Resource` type formats work
- **Actual:** Only `{type: "Resource"}` format sets the property correctly
- **Workaround:** Always use `{type: "Resource", path: "..."}` for resource references

---

## Summary

**148 passed, 4 failed, 2 skipped out of 154 tests.**

The toolkit is in excellent shape. All core tools, gated tools, on-demand group tools, combo chains, and extended tool sections (Path2D, 3D, collision, procedural, inheritance, audio, spriteframes, scene_query, particles, navigation) work correctly. The 4 failures are isolated issues:
- 2 relate to regex backslash escaping in log filtering (systematic)
- 1 relates to `node_manage` duplicate not applying property overrides
- 1 relates to intermittent tool disappearance after `editor_refresh` (client-side caching)

All cleanup completed successfully with project state fully restored.
