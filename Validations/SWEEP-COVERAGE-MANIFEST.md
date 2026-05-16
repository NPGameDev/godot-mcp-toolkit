# Sweep Coverage Manifest

**Last updated:** 2026-05-16
**Toolkit commit:** T:dec5b24
**Total tools:** 105 (93 editor-side + 12 runtime)
**Sweep test count:** ~185 numbered test cases + 23 combo chains + C# phase + extension phase

---

## Tool → Sweep Test Matrix

### Scene Management (11 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| scene.create | 7, 8 | — | C3, C5, C8, C13, C18, C19 | — | — | |
| scene.open | 18, 64a, 64d, 64f | — | C3, C7, C8 | — | — | |
| scene.close | 64b, 64f | ✓ (inactive tab) | C3, C7 | ✓ (active-tab hint) | — | 4.5+ only |
| scene.delete | 64c, 64e | ✓ (active tab) | C3, C18 | — | — | |
| scene.create_node | 20–26, 64h | ✓ (C22: CLASS_MISMATCH) | C5, C8, C10, C19 | ✓ (preload, unique_name) | FIX-G (P6), cb4e162 | **GAP:** unique_name param untested |
| scene.delete_node | 43j, 43s, 64i | — | C19 | — | — | |
| scene.instantiate | 41, 43q–43s | — | C20 | — | FIX-B, FIX-9, FIX-K | **GAP:** properties param, auto-rename |
| scene.diff | 63 | — | — | — | — | |
| scene.create_inherited | 80a–80d | ✓ (NOT_FOUND) | — | — | — | |
| scene.query | 83a–83j | ✓ (no filters, NOT_FOUND) | — | — | — | |
| scene.get_tree | 19, 43, 43e, 43r | — | C8, C19, C20 | — | — | |

### Node Property & Method (8 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| node.get_property | 28, 31, 33, 36, 43b, 43i, 64g | — | C3, C6, C20 | — | — | |
| node.set_property | 27, 29, 30, 32, 34, 35 | — | C3, C6 | — | FIX-5, FIX-7, FIX-E, FIX-F | **GAP:** batch mode, LayerMask coercion, bare res:// guard |
| node.get_property_list | 38–40 | — | C5 | — | — | |
| node.call_method | 49, 50 | — | C9 | ✓ (CS3: C# hint) | — | |
| node.set_script | 37 | — | C5, C8 | — | — | |
| node.manage | 43a–43j | ✓ (43h2: properties) | C19 | — | FIX-K | |
| node.groups | 43k–43l | — | C19 | — | 462506b | **GAP:** batch mode untested |
| node.collision_from_sprite | 78a–78d | ✓ (INVALID_CLASS) | — | — | — | |

### Script Management (4 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| script.read | 15, 16 | — | — | — | — | |
| script.write | 2, 3 | — | C2, C5, C11, C23 | ✓ (C23: preload hint) | FIX-1 | **GAP:** diagnostics fields in response |
| script.delete | — | — | C2, C14 | — | — | Only in combos |
| script.check | 17 | — | C2, C11 | — | — | |

### Editor Core (7 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| editor.get_errors | — | — | — | — | — | **GAP:** no dedicated test |
| editor.save_scene | 55, 64 | — | C3, C5, C7, C8, C9 | — | — | |
| editor.screenshot | 56, 57 | — | — | — | — | |
| editor.refresh | 61 | — | C15, C16 | — | 5f96b62 | Renamed from reload_scripts |
| editor.get_console | 58, 58a–58h | ✓ (58d: invalid regex) | — | — | FIX-8 | **GAP:** clear_buffer param |
| editor.wait_for_idle | 60 | — | — | — | — | |
| execute.code | 58a_seed, 77 | — | — | — | FIX-4, FIX-H, 279efed | **GAP:** load() hint, singleton hint |

### Project Settings (5 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| project.get_settings | 11 | — | — | — | — | |
| project.set_setting | 62 | — | — | — | 23d69f9 | **GAP:** autoload key guard |
| autoload.manage | 43m–43p | — | — | — | FIX-D | **GAP:** EditorPlugin API immediacy |
| project.get_layer_names | 62b | — | — | — | — | |
| project.set_layer_names | 62a, 62c, 62d | ✓ (62c: invalid category) | — | — | — | |

### Asset Management (3 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| asset.list | 12 | — | C14, C18 | — | — | |
| asset.get_dependencies | 13 | — | — | — | — | |
| asset.import | 42, 42b | — | — | — | — | |

### Resource Management (3 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| resource.load | 14, 54a-verify, 54k-verify | — | C1, C12 | — | — | |
| resource.write | 4, 5, 6 | — | C1, C12 | — | — | |
| resource.delete | — | — | C1, C12, C14 | — | — | Only in combos |

### File Operations (1 tool)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| file.delete | — | — | C14 | — | — | Only in combos |

### Folder Management (2 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| folder.create | 1 | — | C17, C18 | — | — | |
| folder.delete | — | — | C17, C18 | — | — | Only in combos |

### ClassDB Introspection (2 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| classdb.get_info | 10 | — | — | — | — | |
| classdb.search | 9 | — | — | — | — | |

### Signal Management (3 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| signal.list | 44, 46, 48 | — | C7 | — | — | |
| signal.manage | 45, 47 | — | C7 | ✓ (method hint) | FIX-G, 5f96b62 | **GAP:** 3-case method hint validation |
| signal.emit | 79 | — | — | — | — | Runtime only |

### Input Map (2 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| input_map.action | 65 | — | C4 | — | 09a6392 | Param renamed: action_name → name |
| input_map.event | 66 | — | C4 | — | — | |

### Save System (4 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| save.write | 67 | — | — | — | — | |
| save.read | 68 | — | — | — | — | |
| save.list | 69 | — | — | — | — | |
| save.delete | 70 | — | — | — | — | |

### Playtest / Game Control (3 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| game.start | 71 | — | C8 | — | 4be3454, a28d17b | **GAP:** compilation failure guard, wait_for_runtime hint |
| game.stop | 81 | — | C8 | — | — | |
| debugger.get_log | 75, 75a–75f, 80 | ✓ (75d: invalid regex) | — | — | dec5b24, a828cb1 | **GAP:** cached log after crash, double-escape warning |

### Animation (3 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| animation.keyframe | 51, 52 | — | C9 | — | — | |
| animation.get_keys | 53 | — | C9 | — | — | |
| animationtree.edit | 54m–54s | ✓ (54s: INVALID_CLASS) | — | — | — | |

### TileMap (3 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| tilemap.set_cells | 54 | — | C10 | — | FIX-A, FIX-J | **GAP:** regions param, no-tileset rejection |
| tileset.create | 54a, 54b | ✓ (54b: NOT_FOUND) | C10 | — | FIX-I | **GAP:** type validation |
| tileset.edit | 54c–54j | ✓ (54j: invalid coords) | — | — | FIX-2 | **GAP:** layer validation guard |

### Theme (1 tool)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| theme.edit | 54k, 54l | ✓ (54l: invalid type) | — | — | — | |

### 3D Tools (4 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| 3d.create_primitive | 77a–77c, 77g | ✓ (77g: invalid shape) | — | — | — | |
| 3d.setup_environment | 77d | — | — | — | — | |
| 3d.create_light | 77e | — | — | — | — | |
| 3d.create_camera | 77f | — | — | — | — | |

### Audio Bus (1 tool)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| audiobus.edit | 81a–81g | ✓ (81f: Master removal) | — | — | — | |

### Navigation (1 tool)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| navigation.edit_polygon | 85a–85f | ✓ (85e: INVALID_CLASS) | — | — | — | |

### Particle System (1 tool)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| particles.create | 84a–84n | ✓ (84i–84m: guards) | — | — | — | |

### Path2D Curve (1 tool)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| path2d.edit_curve | 76a–76f | ✓ (76d: INVALID_CLASS) | — | — | — | |

### Procedural Resources (3 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| procedural.edit_gradient | 79a, 79b | — | — | — | — | |
| procedural.edit_curve | 79c | — | — | — | — | |
| procedural.edit_noise | 79d, 79e | ✓ (79e: invalid type) | — | — | — | |

### SpriteFrames (3 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| spriteframes.create | 82a, 82b, 82h–82j | ✓ (82h: empty, 82i: NOT_FOUND) | — | — | — | |
| spriteframes.edit | 82c–82f | — | — | — | — | |
| spriteframes.from_spritesheet | 82g | — | — | — | — | |

### Meta / Transport (3 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| meta.set_limits | — | — | — | — | — | **GAP:** no test |
| discover_tools | C21 (15 steps) | ✓ (reset, selective reset) | — | — | FIX-3, FIX-C | |
| extensions.refresh | E4b | — | — | — | — | Extension phase |

---

## Runtime-Only Tools (12 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| runtime.screenshot | 72 | — | — | — | — | |
| runtime.get_node_state | 73 | — | C8 | — | — | |
| runtime.get_script_vars | 74 | — | — | — | — | |
| runtime.set_property | — | — | — | — | c6d5f40 | **GAP:** no test + autoload warning |
| debugger.get_log | 75, 75a–75f | ✓ (75d) | — | — | dec5b24 | Shared with editor |
| signal.list | (via editor 44–48) | — | — | — | — | Runtime uses same handler |
| signal.connect | (via editor 45) | — | — | — | — | Runtime uses same handler |
| signal.disconnect | (via editor 47) | — | — | — | — | Runtime uses same handler |
| signal.emit | 79 | — | — | — | — | |
| input.simulate | 76 | — | — | — | — | |
| animation_player.control | 78 | — | — | — | — | |
| execute.code | 77 | — | — | — | FIX-4, 279efed | Runtime context |

---

## Gap Summary

**Tools with NO dedicated test:** 3
- `editor.get_errors` — no standalone test (partially covered by CS11.2)
- `meta.set_limits` — no test at all
- `runtime.set_property` — no test at all

**Tools with incomplete coverage (missing new params/guards):** 12
- `scene.create_node` — unique_name param
- `scene.instantiate` — properties param, auto-rename (FIX-K)
- `node.set_property` — batch mode (FIX-7), LayerMask coercion, bare res:// guard (FIX-F)
- `node.groups` — batch mode
- `script.write` — diagnostics response fields (FIX-1)
- `editor.get_console` — clear_buffer param (FIX-8)
- `execute.code` — singleton hints (FIX-4), load() hint (FIX-H, 279efed)
- `project.set_setting` — autoload key guard (23d69f9)
- `game.start` — compilation failure detection (4be3454), wait_for_runtime hint (a28d17b)
- `debugger.get_log` — cached log after crash (dec5b24), double-escape warning (a828cb1)
- `tilemap.set_cells` — regions param (FIX-A), no-tileset rejection (FIX-J)
- `signal.manage` — 3-case method hint validation (5f96b62)

**Renames to verify in sweep text:** 4
- `editor.reload_scripts` → `editor.refresh` (5f96b62)
- `input_map action_name` → `name` (09a6392)
- `signal_manage source_path` → `node_path` (FIX-G)
- `scene_instantiate packed_path` → `scene_path` (FIX-B)
