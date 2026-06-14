# MCP Tool Sweep v2 Results

- **Date:** 2026-06-07
- **Godot version:** 4.5
- **Project type:** GDScript
- **Mode:** standard
- **Merged commit:** 0366560 (41l-tricies dispatch-safety fix: editor.refresh precision + save re-entrancy guard)
- **MCP port:** 6550
- **Sections run:** 0–27 + Last-cleanup (full sweep — all tests mandatory, no skips)
- **Total:** ≈391 checks passed · 1 failed (extension live-discovery) · Section 23 (C#) N/A · Section 24 E1–E10 blocked by the discovery failure. **Zero console regressions; both focus fixes (editor.refresh precision + UndoRedo dispatch-safety) verified clean.**

> Prior sweep runs (2026-05-24 through 2026-05-26) are preserved in git history.
> This file is the fresh full-sweep record for commit 0366560.
> **Special focus:** Section 7 (editor_refresh / save_scene — the shared flow the 41l-tricies fix changed).
>
> **2026-06-08 update:** Section 24 (Extensions) was re-run against commit `d948f61` to verify the
> in-session extension-discovery fix — see the dated Section 24 block. Result: **fix VERIFIED**; the
> Section-24 test extensions need a `class_name` (Finding A); and a **new CRITICAL crash** was found
> when calling a live-discovered extension tool (Finding B). The rest of this file remains the 0366560 record.

---

## Section 0 — Environment Detection (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 0.1 | PASS | Project "Godot MCP Toolkit", main_scene=res://Main.tscn, features="4.5","GL Compatibility", no dotnet setting |
| 0.2 | PASS | asset_list res:// (ext cs,csproj) → 0 files. GDScript project confirmed |
| 0.3 | PASS | discover_tools activation works (asset_ops activated); core tools execute_code + node_call_method available in standard mode |
| 0.4 | N/A | Not a C# project |
| 0.5 | PASS | Godot 4.5: TileMapLayer=Yes, scene_close=Yes, Logger API (buffer source)=Yes |
| 0.6 | PASS | scene_close visible in cleanup group (registered min_godot 4.5) — matches detected version |
| 0.7 | N/A | No version-bounded extensions detected |

Console error check: PASS (0 errors/warnings, no UndoRedo mismatch).

## Section 1 — Scaffolding & Core Files (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 1.1 | PASS | folder_create res://sv2_validation/ status=created |
| 1.2 | PASS | script_write actor.gd 196 bytes, valid=true |
| 1.3 | PASS | REGR OK FIX-1: valid=true + diagnostics=[] inline in script_write response |
| 1.4 | PASS | shader.gdshader 196 bytes written (indexed=true) |
| 1.5 | PASS | anim_lib.tres AnimationLibrary status=created |
| 1.6 | PASS | material.tres ShaderMaterial (shader ref + brightness=0.75) status=created |
| 1.7 | PASS | tileset.tres TileSet (tile_size Vector2i 16x16) status=created |
| 1.8 | PASS | main.tscn root="main" (Node2D) status=created |
| 1.9 | PASS | sub.tscn root="sub" (Node2D) status=created |
| 1.10 | PASS | scene_open main.tscn success |

Console error check: PASS (0 errors/warnings).

## Section 2 — Scene Tree & Node Creation (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 2.1 | PASS | Root "main" (Node2D) confirmed |
| 2.2 | PASS | Sprite2D Sv2Sprite created |
| 2.3 | PASS | Label Sv2Label created |
| 2.4 | PASS | AnimationPlayer Sv2AnimPlayer created |
| 2.5 | PASS | AnimationTree Sv2AnimTree created |
| 2.6 | PASS | TileMapLayer Sv2TileLayer created (4.5) |
| 2.7 | PASS | CharacterBody2D Sv2Player created |
| 2.8 | PASS | CollisionShape2D Sv2Collider under Sv2Player |
| 2.9 | PASS | Path2D Sv2Path created |
| 2.10 | PASS | NavigationRegion2D Sv2NavRegion created |
| 2.11 | PASS | REGR OK a46487b: unique_name=true in response |
| 2.12 | PASS | REGR OK cb4e162: CLASS_MISMATCH "as Label, not Button" |
| 2.13 | PASS | Idempotent status=returned |
| 2.14 | PASS | REGR OK FIX-B (7e63aee): scene_path param works, Sv2Sub created |
| 2.15 | PASS | REGR OK 462506b: transform overrides applied, position=(50,75) verified |
| 2.16 | PASS | Tree shows all 11 nodes at depth=2 |
| 2.17 | PASS | editor_save_scene success |
| 2.18 | PASS | Path normalization /root/main/Sv2Sprite → visible=true |

Console error check: PASS (0 errors/warnings). Cleanup: Sv2SubProps + Sv2Sub deleted.

## Section 3 — Node Properties & Methods (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 3.1 | PASS | Vector2 position set on Sv2Sprite |
| 3.2 | PASS | Readback Vector2(100,100) |
| 3.3 | PASS | Label text set |
| 3.4 | PASS | Compound theme_override_colors/font_color set |
| 3.5 | PASS | Readback Color(1,0,0,1) |
| 3.6 | PASS | REGR OK FIX-E: {type:Resource,path:...} material ref set |
| 3.7 | PASS | REGR OK Pitfall-4: ResourceRef alias accepted |
| 3.8 | PASS | **IMPROVED** colon-chain SET material:shader_parameter/brightness=0.3 returns success + honest warning ("set on shared external sub-resource in memory, may not persist after save/reload; retry make_unique:true") |
| 3.9 | PASS | **IMPROVED** colon-chain GET returns 0.3 (read-after-write now reflects the SET; was 0.75/FAIL in all prior sweeps) |
| 3.10 | PASS | REGR OK FIX-F: bare "res://icon.svg" rejected INVALID_VALUE with actionable {type:Resource} hint |
| 3.11 | PASS | REGR OK 462506b: LayerMask type tag accepted. NOTE: documented {layers:[1,3]} → collision_layer=5 (verified); sweep-doc's {value:5} form silently yields 0 — **doc format bug, not toolkit regression** |
| 3.12 | PASS | REGR OK FIX-7: batch mode returns per-item results (2 entries both success) |
| 3.13 | PASS | Batch verified: text=Batch1, visible=false |
| 3.14 | PASS | Restored visible=true, text="Hello Sweep v2" |
| 3.15 | PASS | node_set_script returns exports speed(float), label(String) |
| 3.16 | PASS | mask=script: speed, label (both public) |
| 3.17 | PASS | mask=common: 9 curated properties |
| 3.18 | PASS | mask=all: 45 full properties (engine + script) |
| 3.19 | PASS | node_call_method dispatched (success=true), result=null + hint. Non-@tool editor-side callv limitation — logs expected "get_info: Method not found" in console (NOT a regression). Real exec validated at runtime in S20 |
| 3.20 | PASS | REGR OK FIX-5: PackedVector2Array type tag accepted (error is NOT_FOUND "curve is null" — path issue, not type rejection) |
| 3.21 | PASS | theme_override_font_sizes/font_size set to 24 |
| 3.22 | PASS | Readback 24 |
| 3.23 | PASS | Control Sv2LayoutTest created |
| 3.24 | PASS | PRESET_FULL_RECT success |
| 3.25 | PASS | PRESET_CENTER keep_size success |
| 3.26 | PASS | PRESET_TOP_WIDE margins applied (final_rect pos=10,5) |
| 3.27 | PASS | INVALID_PARAMS lists 16 valid presets |
| 3.28 | PASS | INVALID_CLASS: "Sprite2D — requires a Control node" |

Console error check: PASS (no UndoRedo mismatch). One expected error logged: get_info "Method not found" from 3.19 (non-@tool editor-side call). Cleanup: Sv2RefTest + Sv2LayoutTest deleted, scene saved.

## Section 4 — Node Management (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 4.1 | PASS | Rename Sv2Label → Sv2LabelRenamed |
| 4.2 | PASS | Reachable under new name, text="Hello Sweep v2" |
| 4.3 | PASS | Rename back to Sv2Label |
| 4.4 | PASS | Reparent Sv2Sprite under Sv2Player |
| 4.5 | PASS | Tree confirms Sv2Player/Sv2Sprite |
| 4.6 | PASS | Reparent Sv2Sprite back to root |
| 4.7 | PASS | Reorder Sv2Label to index 0 |
| 4.8 | PASS | Duplicate Sv2Label → Sv2LabelCopy |
| 4.9 | PASS | Copy inherits text="Hello Sweep v2" |
| 4.10 | PASS | Duplicate Sv2Sprite → Sv2SpriteCopy with position override |
| 4.11 | PASS | REGR OK c61d994: position=(200,300) — Vector2 inferred without type key |
| 4.12 | PASS | REGR OK 462506b: batch add via `entries` array, count=2 (sv2_enemies, sv2_actors). NOTE: tool uses `entries:[{node_path,group}]`, not doc's `groups:[]` |
| 4.13 | PASS | List shows sv2_enemies, sv2_actors |
| 4.14 | PASS | Batch remove via `entries`, count=2 both removed |

Console error check: PASS (0 errors/warnings). Cleanup: Sv2LabelCopy + Sv2SpriteCopy deleted, scene saved.

## Section 5 — Signals (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 5.1 | PASS | hit signal listed (args=[]) among 23 signals |
| 5.2 | PASS | REGR OK FIX-G: connect via node_path param, status=created |
| 5.3 | PASS | include_connections shows hit→Sv2Label.set_text (flags=2 PERSIST) |
| 5.4 | PASS | REGR OK 5f96b62: method hint fires — INVALID_PARAMS "method not on Sv2Label; no script attached" |
| 5.5 | PASS | Disconnect set_text success |
| 5.6 | PASS | No connection existed (5.4 rejected); disconnect refuses gracefully with method-validation INVALID_PARAMS (functionally = NOT_FOUND/no-op) |
| 5.7 | PASS | hit connections=[] after disconnect |

Console error check: PASS (0 errors/warnings).

## Section 6 — Script Operations (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 6.1 | PASS | Full content matches S1 write (15 lines) |
| 6.2 | PASS | Lines 1-3 only (range read) |
| 6.3 | PASS | valid=true, 0 diagnostics |
| 6.4 | PASS | FIX-1 OK: valid=false, inline diagnostics (compile error) |
| 6.5 | PASS | REGR OK a46487b: preload hint — "Use load() instead — it evaluates at runtime" |
| 6.6 | PASS | script_check valid=false with diagnostics |
| 6.7 | PASS | asset_list (*.gd) finds 3 files (actor, sv2_bad_script, sv2_preload_test) |
| 6.8 | PASS | asset_get_dependencies material.tres → shader.gdshader |

Console error check: PASS (6 errors — all intentional parse/preload errors from guard scripts 6.4–6.6; no UndoRedo mismatch). Cleanup: sv2_bad_script.gd + sv2_preload_test.gd deleted.

## Section 7 — Editor Operations & Console ⭐ FOCUS (2026-06-07)

> **Special-focus section** — editor_refresh / editor_save_scene are the shared flow the
> 41l-tricies fix (commit 0366560) changed (editor.refresh precision + save re-entrancy guard).

| Test | Status | Notes |
|------|--------|-------|
| 7.1 | PASS | editor_save_scene success |
| 7.2 | PASS | editor_screenshot returns inline PNG (2×2 — main 2D viewport empty; editor window backgrounded/minimized, environmental) |
| 7.3 | PASS | Node-focused screenshot Sv2Sprite returns correct 1280×720 PNG (atomic focus-restore, correct path/dims). Content black — editor viewport not actively rendering (environmental, not a tool regression) |
| 7.4 | PASS | editor_get_console returns success (empty after setup clear) |
| 7.5 | PASS | execute_code **enabled** (gate open) — push_warning succeeded. NOTE: first editor-context push_warning missed an immediate read by ~1 frame (flush timing); re-seed confirmed print/warn/error all captured |
| 7.6 | PASS | text_filter "SV2_SEED" plain → count=3 (print+warn+error markers) |
| 7.7 | PASS* | regex "Alpha\d+" is_regex=true → count=1 (matched "Alpha42"). *NO proactive double-escape warning hint in response — **REGRESSION WATCH a828cb1 flag** (regex functionality works; only the heads-up hint is absent — minor DX) |
| 7.8 | PASS | text_filter "test_line(parens)" plain → count=1 (metacharacters literal) |
| 7.9 | PASS | invalid regex "(unclosed" is_regex=true → INVALID_PARAMS with regex hint |
| 7.10 | PASS | text_filter "SV2_SEED" + level_filter=["warning"] → count=1 (AND compose) |
| 7.11 | PASS | FIX-8 OK: clear_buffer accepted, buffer cleared |
| 7.12 | PASS | count=0 after clear |
| 7.13 | PASS | editor_wait_for_idle success (was_scanning=false, waited_ms=0) |
| 7.14 | PASS | **editor_refresh full**: mode="full", scan_waited_ms=73, reloaded=0, errors_cleared=0 |
| 7.15 | PASS | **editor_refresh targeted** [actor.gd]: mode="targeted", **file_count=1** (precise). Extra: [actor.gd, material.tres] → file_count=2 (precision confirmed) |
| 7.16 | PASS | Error retrieval via editor_get_console error filter → count=0. (editor_get_errors is not a distinct registered tool — maps to console error filter) |

**Extra re-entrancy check (FOCUS):** editor_save_scene → full refresh → targeted refresh → 2-file refresh → **editor_save_scene immediately after refresh** all succeeded with **zero console errors**.

Console error check: **PASS** — 0 errors/warnings across the entire save↔refresh shared flow. No UndoRedo mismatch, no re-entrancy errors. **41l-tricies fix verified — no regression.** Cleanup: none (no persistent artifacts).

## Section 8 — Project Settings & Autoloads (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 8.1 | PASS | project_get_settings (no filter) returns full dict (~67KB, spilled to file — full-dump path works) |
| 8.2 | PASS | Name set to Sv2Validation, previous_value="Godot MCP Toolkit" captured |
| 8.3 | PASS | prefix=application/config/ → name=Sv2Validation (15 keys) |
| 8.4 | PASS | REGR OK 23d69f9: autoload key guard — INVALID_PARAMS with "use autoload_manage" hint |
| 8.5 | PASS | Autoload list shows MCPRuntimeServer (count=1) |
| 8.6 | PASS | REGR OK FIX-D: register Sv2Autoload, "editor cache updated" in hint |
| 8.7 | PASS | List shows Sv2Autoload enabled=true (immediately, no manual refresh) |
| 8.8 | PASS | Unregister Sv2Autoload success |
| 8.9 | PASS | layer_names_set 2d_physics (Ground/Player/Enemies), layers_set=3 |
| 8.10 | PASS | layer_names_get roundtrip {1:Ground,2:Player,5:Enemies} |
| 8.11 | PASS | Invalid category rejected — MCP schema enum validation lists 4 valid categories |
| 8.12 | PASS | Layer names cleared (layers_set=3 with empty strings) |

Console error check: PASS (1 expected toolkit warning about project-rename user:// path shift from the name set/restore; no UndoRedo mismatch). Cleanup: project name restored to "Godot MCP Toolkit".

## Section 9 — execute_code & Hints (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 9.1 | PASS | 2 + 2 = 4 |
| 9.2 | PASS | EditorInterface singleton hint (expected — "global singleton not accessible in Expression; use dedicated MCP tools") |
| 9.3 | PASS | REGR OK FIX-4: OS singleton hint mentioning Expression limitations |
| 9.4 | PASS | REGR OK FIX-H/279efed: load() context-aware hint ("Assign resources via node_set_property with {type:Resource,path}") |
| 9.5 | PASS | get_tree().get_nodes_in_group("sv2_test") → [] |
| 9.6 | PASS | Engine singleton hint |
| 9.7 | PASS | invalid syntax → EXECUTE_FAILED parse error |
| 9.8 | PASS | ProjectSettings singleton hint |

Console error check: PASS (0 errors/warnings — execute_code errors returned to caller, not logged).

## Section 10 — Input Map (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 10.1 | PASS | REGR OK 09a6392: action=add, name=sv2_jump, status=created |
| 10.2 | PASS | Bind key Space (keycode=32) to sv2_jump, status=created |
| 10.3 | PASS | Unbind Space success |
| 10.4 | PASS | Remove action sv2_jump success |

Console error check: PASS (0 errors/warnings).

## Section 11 — Save System (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 11.1 | PASS | save_write user://saves/sv2_save.json (25 bytes). user_data **enabled** (gate open — was gated in original sweep) |
| 11.2 | PASS | save_read content score=42, level=3 (untrusted envelope) |
| 11.3 | PASS | save_list user://saves/ → files=["sv2_save.json"] |
| 11.4 | PASS | save_delete success |
| 11.5 | PASS | PATH_DENIED reading user://addons/godot_mcp_toolkit/ (plugin internals protected) |
| 11.6 | PASS | PATH_DENIED writing to plugin internals |

Console error check: PASS (0 errors/warnings).

## Section 12 — ClassDB Introspection (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 12.1 | PASS | CharacterBody2D + CharacterBody3D found (total=2) |
| 12.2 | PASS | AnimationPlayer: 13 props, 53 methods, 2 signals, inheritance chain |
| 12.3 | PASS | Sv2Actor found as global class (source=global, parent CharacterBody2D) |
| 12.4 | PASS | UNKNOWN_CLASS with hint "Use classdb.search" |
| 12.5 | PASS | **FIXED** Node2D offset=0 → properties_total=13, methods_total=33, signals_total=0, constants_total=0 (all totals present; offset typed integer) |
| 12.6 | PASS | **FIXED** (was type-coercion FAIL) offset=20 paging → properties=[] past-end, total=13 unchanged, truncated=true |
| 12.7 | PASS | **FIXED** (was type-coercion FAIL) classdb_search Control offset=5 → total=3, truncated=true |

Console error check: PASS (0 errors/warnings). Offset pagination (12.6/12.7) — previously systemic MCP param type-coercion failures — now resolved (offset is a typed integer in the schema).

## Section 13 — Animation & AnimationTree (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 13.1 | PASS | add_animation_library via node_call_method → returned 0 (was gated/SKIP in original sweep — node_call_method now enabled) |
| 13.2 | PASS | keyframe t=0 Vector2(100,100) — auto-created sv2_lib/idle animation + track |
| 13.3 | PASS | keyframe t=1 Vector2(200,200) |
| 13.4 | PASS | animation_get_keys: 2 keyframes on Sv2Sprite:position track |
| 13.5 | PASS | set_root AnimationNodeStateMachine |
| 13.6 | PASS | add_node idle (nodes_count=3) |
| 13.7 | PASS | add_node run (nodes_count=4) |
| 13.8 | PASS | add_transition idle→run with advance_condition=is_running |
| 13.9 | PASS | add_transition run→idle with advance_mode=auto |
| 13.10 | PASS | list: 4 nodes (Start/End/idle/run), 2 transitions verified |
| 13.11 | PASS | INVALID_CLASS guard (Sv2Sprite is Sprite2D not AnimationTree) |
| 13.12 | PASS | editor_save_scene |

Console error check: PASS (0 errors/warnings). Animation state persists for runtime tests in S20.

## Section 14 — TileSet & TileMap (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 14.1 | PASS | FIX-I OK: tileset_create source_id=0, 4×4=16 tiles, physics. **tile_size {x:32,y:32} now works** (typed object — was string-coerced to 16×16 in original sweep) |
| 14.2 | PASS | resource_load confirms TileSet, physics_layer_0, tile_size Vector2i(32,32) |
| 14.3 | PASS | setup_layers: terrain(grass/dirt), custom_data(damage), nav=1, occlusion=1, physics=1 |
| 14.4 | PASS | **FIXED** add_source tile_size{x:64,y:64} → new_source_id=1 (was type-coercion FAIL) |
| 14.5 | PASS | **FIXED** remove_source(1) → removed_source_id=1 |
| 14.6 | PASS | **FIXED** add_alternative (1,0) flip_h → new_alternative_id=1 |
| 14.7 | PASS | remove_alternative(1) → removed_alternative_id=1 |
| 14.8 | PASS | tileset_create NOT_FOUND for nonexistent texture |
| 14.9 | PASS | remove_source(999) NOT_FOUND guard |
| 14.10 | PASS | remove_alternative(999) NOT_FOUND guard |
| 14.11 | PASS | **FIXED** edit_physics: 'none' + custom polygon array → tiles_modified=2 |
| 14.12 | PASS | **FIXED** edit_terrain → tiles_modified=1 |
| 14.13 | PASS | edit_navigation 'full' → tiles_modified=1 |
| 14.14 | PASS | edit_visuals occlusion+probability → tiles_modified=1 |
| 14.15 | PASS | edit_custom_data {damage:10} → tiles_modified=1 |
| 14.16 | PASS | FIX-2 OK: invalid coords (99,99) → success errors[]=["tile not found"], tiles_modified=0 (no crash) |
| 14.17 | PASS | edit_physics missing file → NOT_FOUND |
| 14.18 | PASS | tilemap_set_cells 1 cell (after tile_set assigned to Sv2TileLayer) |
| 14.19 | PASS | FIX-A OK: regions bulk-fill 5×5 → 24 written + 1 unchanged = 25 |
| 14.20 | PASS | FIX-J OK: no-tileset guard (Sv2TileNoTS) → INVALID_STATE "cells would be invisible" |
| 14.21 | PASS | read_cells → 25 cells with coords/source_id/atlas_coords/alternative_tile |
| 14.22 | PASS | Round-trip: set_cells → read_cells match (all source_id=0, atlas(0,0)) |
| 14.23 | PASS | read_cells NonExistentNode999 → NOT_FOUND |
| 14.24 | PASS | read_cells Sv2Sprite → INVALID_CLASS (not TileMap/TileMapLayer) |
| 14.25 | PASS | read_cells missing node_path → schema validation error (INVALID_PARAMS) |
| 14.26 | PASS | discover_tools tileset → 6 tools |
| 14.27 | PASS | discover_tools tileset_edit → 5 tools |
| 14.28 | PASS | discover_tools tilemap → 2 tools |

Console error check: PASS (0 errors/warnings). **All TileSet param type-coercion failures from the original sweep (14.4–14.6, layers, polygons) are resolved** — schemas now use typed objects/arrays/integers. Cleanup: Sv2TileNoTS deleted; atlas_tileset.tres retained (referenced by Sv2TileLayer) for global folder cleanup.

## Section 15 — Theme, Audio, SpriteFrames (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 15.1 | PASS | theme_edit edits_applied=2 (Button font_color, Label font_size) |
| 15.2 | PASS | resource_load: Button/colors/font_color=Color(1,0,0,1), Label/font_sizes/font_size=24 |
| 15.3 | PASS | Invalid property_type rejected by schema enum (lists 6 valid: color/constant/font/font_size/icon/stylebox) |
| 15.4 | PASS | add_bus Sv2Music (send Master), bus_count=2 |
| 15.5 | PASS | **FIXED** set_bus volume_db=-6 (typed number — was coercion FAIL) |
| 15.6 | PASS | **FIXED** add_effect → AudioEffectReverb (effect object — was coercion FAIL) |
| 15.7 | PASS | list: Master + Sv2Music (volume=-6, send=Master, effects=[AudioEffectReverb]) |
| 15.8 | PASS | Cannot remove Master bus → INVALID_PARAMS |
| 15.9 | PASS | **FIXED** spriteframes_create: idle(2 frames), run(4 frames) — animations array (was coercion FAIL) |
| 15.10 | PASS | spriteframes_edit add_animation jump (fps=6) |
| 15.11 | PASS | list: idle, jump, run (3 animations) |
| 15.12 | PASS | spriteframes_from_spritesheet: walk (2 frames) from icon.svg grid |

Console error check: PASS (0 errors/warnings). Cleanup: Sv2Music removed; theme/spriteframes/spritesheet_frames .tres deleted.

## Section 16 — 3D, Path2D, Navigation, Particles, Procedural (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 16.1 | PASS | 3d box created (size + StandardMaterial3D albedo) |
| 16.2 | PASS | 3d sphere Sv2Sphere |
| 16.3 | PASS | WorldEnvironment, tonemap=filmic |
| 16.4 | PASS | **FIXED** DirectionalLight3D, shadow=true (typed boolean — was coercion FAIL) |
| 16.5 | PASS | **FIXED** Camera3D, fov=75 (typed number — was coercion FAIL) |
| 16.6 | PASS | invalid_shape rejected by enum (box/sphere/cylinder/capsule/plane/prism) |
| 16.7 | PASS | path2d set 4 points, baked_length=335 |
| 16.8 | PASS | **FIXED** path2d add index=2 → point_count=5 (typed integer — was coercion FAIL) |
| 16.9 | PASS | path2d remove index=0 → point_count=4 |
| 16.10 | PASS | INVALID_CLASS: Sv2Sprite not Path2D |
| 16.11 | PASS | path2d clear → point_count=0 |
| 16.12 | PASS | **FIXED** navigation set outlines → outline_count=1 (typed array — was coercion FAIL) |
| 16.13 | PASS | **FIXED** add_outline → outline_count=2 |
| 16.14 | PASS | **FIXED** bake → polygon_count=1 |
| 16.15 | PASS | **FIXED** remove_outline index=1 → outline_count=1 |
| 16.16 | PASS | INVALID_CLASS: root Node2D not NavigationRegion2D |
| 16.17 | PASS | fire 2d particles, preset_applied=fire, properties_set=13 (minimal call — preset convenience intact, schema's ~28 "required" not enforced) |
| 16.18 | PASS | **FIXED** rain amount=100 → overrides_applied=["amount"] (was coercion SKIP) |
| 16.19 | PASS | **FIXED** 3d sparks mesh=quad → GPUParticles3D |
| 16.20 | PASS | **FIXED** All 8 presets create as 2d (fire/smoke/sparks/rain/snow/explosion/magic/dust) |
| 16.21 | PASS | type=4d rejected by enum (2d/3d) |
| 16.22 | PASS | preset=lava rejected by enum (8 presets) |
| 16.23 | PASS | NOT_FOUND: parent NonExistent |
| 16.24 | PASS | gradient set 3 color stops |
| 16.25 | PASS | gradient add_point → point_count=4 |
| 16.26 | PASS | **FIXED** curve set 3 points (position-wrapper format — was "position key expected" FAIL) |
| 16.27 | PASS | noise simplex, frequency=0.05 |
| 16.28 | PASS | invalid_noise rejected by enum |

Console error check: PASS (0 errors/warnings). **Nearly all original-sweep type-coercion failures resolved** (16.4/16.5 light+camera, 16.8 path index, 16.12–16.16 nav outlines, 16.18–16.20 particles, 16.26 curve). Cleanup: 14 nodes + 3 procedural .tres deleted.

## Section 17 — Scene Inheritance & Query (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 17.1 | PASS | base_enemy.tscn (CharacterBody2D) created |
| 17.2 | PASS | Inherited slime.tscn from base, root_name=SlimeEnemy |
| 17.3 | PASS | NOT_FOUND for nonexistent base scene |
| 17.4 | PASS | main.tscn re-opened |
| 17.5 | PASS | class_filter=CharacterBody2D → Sv2Player (count=1) |
| 17.6 | PASS | name_pattern=Sv2* → 10 nodes, all "Sv2*" |
| 17.7 | PASS | class_filter=Node2D + include_properties → 8 nodes each with position+visible |
| 17.8 | PASS | root_path=Sv2Player → 2 nodes (subtree: Sv2Player + Sv2Collider) |
| 17.9 | PASS | No filters → INVALID_PARAMS "At least one filter is required" |
| 17.10 | PASS | root_path=NonExistentNode → NOT_FOUND |

Console error check: PASS (0 errors/warnings). Cleanup: base_enemy.tscn + slime.tscn deleted.

## Section 18 — Phantom Tab Cleanup & File Operations (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 18.1 | PASS | probe.tscn created |
| 18.2 | PASS | probe opened (active) |
| 18.3 | PASS | scene_close main.tscn (non-active) with _set_main_scene_state hint |
| 18.4 | PASS | scene_delete probe (active), tab_closed=true |
| 18.5 | PASS | Recreated probe; main active, probe non-active |
| 18.6 | PASS | scene_delete probe (non-active), tab_closed=true + hint |
| 18.7 | PASS | file_delete shader.gdshader, deindexed=true, no tab_closed field |
| 18.8 | PASS | shader.gdshader recreated (196 bytes) |
| 18.9 | PASS | material.tres loads, shader ref valid (brightness=0.75) |
| 18.10 | PASS | asset_import icon_test.svg → CompressedTexture2D. NOTE: SVG import not "immediate" — class empty at 3s, became CompressedTexture2D after editor_wait_for_idle (tool warned to do exactly this) |
| 18.11 | PASS | file_delete file_del_probe.tscn (open tab) → tab_closed=true |
| 18.12 | PASS | folder_delete (1 scene) recursive → tab_closed=inner.tscn, files_deleted=1 |
| 18.13 | PASS | folder_delete (2 scenes) → stale_tabs=[inner1,inner2] (2 entries); scene_close each succeeded |
| 18.14 | PASS | scene_close last tab → engine auto-creates empty scene |
| 18.15 | PASS | scene_open main.tscn restored |

Console error check: PASS — only a benign toolkit audit-log warning ("[MCPTools] folder.delete recursive"). **Notably the predicted `_set_main_scene_state` engine errors did NOT appear** — the 41l editor-safe scene ops (C1/C2/C3) closed every tab cleanly. No UndoRedo mismatch. Cleanup: icon_test.svg deleted.

## Section 19 — collision_from_sprite (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 19.1 | PASS | Sv2CollSprite Sprite2D created + texture=res://icon.svg (set inline) |
| 19.2 | PASS | collision_from_texture → polygon_count=1, total_points=20 |
| 19.3 | PASS | INVALID_CLASS: "node at . is Node2D — expected Sprite2D or TextureRect" |

Console error check: PASS (0 errors/warnings). Cleanup: Sv2CollSprite + Sv2CollSprite_collision deleted, scene saved.

## Section 20 — Game Start, Runtime & Debugging (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 20.1 | PASS | main_scene set to sv2_validation/main.tscn |
| 20.2 | PASS | editor_save_scene |
| 20.3 | PASS | game_start success, target=main, runtime_port=6570 |
| 20.4 | PASS | REGR OK a28d17b: wait_for_runtime=false → "runtime_ready is false" gated hint |
| 20.5 | PASS | runtime_screenshot: 1152×648 PNG, **real game render** (tilemap visible — game window renders, unlike editor viewport) |
| 20.6 | PASS | runtime_get_node_state Sv2Player: CharacterBody2D, position, collision_layer=5, script actor.gd |
| 20.7 | PASS | runtime_get_script_vars: speed=100, label="default" |
| 20.8 | PASS | runtime_set_property speed 100→200 |
| 20.9 | PASS | Verified speed=200 |
| 20.10 | PASS | REGR OK c6d5f40: autoload (MCPRuntimeServer) set → "persists across scene transitions" warning |
| 20.11 | PASS | debugger_get_log: runtime server startup lines |
| 20.12 | PASS | execute_code (game) print seed succeeded |
| 20.13 | PASS | filter SV2_RUNTIME_SEED → count=2 |
| 20.14 | PASS | **IMPROVED** regex SV2_RUNTIME_SEED_Beta\d+ → count=2 (was platform double-escape FAIL in original sweep — now \d+ matches) |
| 20.15 | PASS | filter check(braces) plain → count=2 (literal parens) |
| 20.16 | PASS | invalid regex "(unclosed" → INVALID_PARAMS with hint |
| 20.17 | PASS | input_simulate action ui_accept dispatched=true |
| 20.18 | PASS | execute_code (game) get_tree().current_scene.name = "main" (chaining works in runtime) |
| 20.19 | PASS | animation_player_control play sv2_lib/idle, current_animation confirmed |
| 20.20 | PASS | signal_emit hit (mode=runtime) success |
| 20.21 | PASS | debugger_get_log: 6 lines (the "missing closing parenthesis" entry is the intentional 20.16 invalid-regex guard, not a crash) |
| 20.22 | PASS | game_stop, was_running=true |

Console error check: PASS (editor console clean post-game; no UndoRedo mismatch). Cleanup: main_scene restored to res://Main.tscn.

## Section 21 — game_start Guards & Crash Recovery (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 21.1 | PASS | Broken script written, valid=false |
| 21.2 | PASS | Broken scene setup (attach + save + main_scene) |
| 21.3 | PASS | game_start succeeds=true (Godot launches despite broken node script) |
| 21.3b | PASS | debugger_get_log → GAME_NOT_RUNNING but hint surfaces actual parse errors via editor-console fallback |
| 21.3c | PASS | game_stop |
| 21.4 | PASS | Valid game launched (runtime_port=6570, ready) + stopped |
| 21.5 | PASS | REGR OK dec5b24/e2c7041: post-stop source=cache, debug_state={active:false}, NOT GAME_NOT_RUNNING |
| 21.6 | PASS* | Cache count=0 (no SV2_BROKEN). *First call hit a **transient race** — "runtime cleared by notification, registry not yet updated" (GAME_NOT_RUNNING); self-healed on immediate retry. Minor timing window when 2 debugger_get_log calls fire in rapid succession right after game_stop |
| 21.7 | PASS | Error script written, valid=true (null-ref is runtime, not parse) |
| 21.8 | PASS | Error scene launched, runtime connected |
| 21.9 | PASS | game_stop |
| 21.10 | PASS | error_buffer: type=log_scan, source=sv2_error_main.gd, function=_ready, line=6, "Cannot call method 'queue_free' on a null value"; debug_state present |
| 21.11 | PASS | REGR OK 8a6cbf0: filter queue_free → count=1, error_buffer retains source/function/line (unfiltered scan) |
| 21.12 | PASS | filter NONEXISTENT → count=0 (lines empty) but error_buffer still present |
| 21.13 | PASS | No-params golden path: lines + debug_state + error_buffer all present |

Console error check: PASS (2 errors — both intentional parse errors from the broken guard script; no UndoRedo mismatch). **Observation (minor):** 21.6 transient race in crash-recovery fallback — rapid successive debugger_get_log right after game_stop can briefly return GAME_NOT_RUNNING before the cache fallback settles (~1s self-heal). Cleanup: error/broken scenes+scripts deleted, main_scene restored.

## Section 22 — Combo Chains (2026-06-07)
| Chain | Status | Notes |
|------|--------|-------|
| C1 | PASS | resource_write(Environment) → load(verify class) → delete |
| C2 | PASS | script_write(valid) → script_check(valid) → delete |
| C3 | PASS | scene create→open→node→set pos→verify(100,200)→save→open main→delete |
| C4 | PASS | signal connect→save→switch to sub→back to main→verify persisted (flags=2)→disconnect |
| C5 | PASS | build scene+script→run→runtime_get_node_state→debugger_get_log "C5_LIFECYCLE_OK"→stop→cleanup |
| C6 | PASS | tileset_create→setup_layers(terrain)→TileMapLayer+tile_set→set_cells(9 cells)→cleanup. (_meta.concurrency scene-lease confirms editor serializes mutations) |
| C7 | PASS | script_write(indexed=true)→script_check passes immediately (no refresh) |
| C8 | PASS | create→duplicate→rename→reparent→groups add/list/remove→save→cleanup |
| C9 | PASS | batch instantiate 3 copies; C9B rotation=1.57 verified |
| C10 | PASS | FIX-C OK: keyword search (loose_keyword "animation"), batch activate (exact_name), selective reset — no split-notification "tool not found" |
| C11 | PASS | editor_refresh targeted, mode=targeted, file_count=1 |
| C12 | PASS | folder_delete with open tabs → no PATH_IN_USE, stale_tabs handled |
| C27 | PASS | Godot 4.5: scene_close visible + functional on non-active tabs |
| C28 | PASS | FULL_RECT anchor_right=1.0, CENTER anchor_left=0.5 (readback confirmed) |

Console error check: PASS (0 errors/warnings). Cleanup verified: Glob `sv2_validation/c*` → no files. All 14 chains pass.

## Section 23 — C# Compatibility (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| All (~50) | N/A | GDScript project (S0 confirmed 0 .cs/.csproj files). C# section not applicable. |

## Section 24 — Extension Discovery (2026-06-08 — targeted re-run, commit d948f61)

> **Targeted re-run** verifying `d948f61 fix(extensions): discover NEW extensions on
> extensions_refresh in-session` — the fix for the Major "extension live-discovery"
> failure recorded in the 2026-06-07 full sweep below. Godot 4.5, editor running, MCP
> port 6550. **This block supersedes the 2026-06-07 EXT-S2 FAIL / E1–E10 BLOCKED result.**
> Run halted at E3 by an editor crash (Finding B).
>
> **✅ RESOLVED 2026-06-08 (continuation session).** Finding B was root-caused + fixed —
> a **latent Godot 4.2 engine SIGSEGV** (`CACHE_MODE_IGNORE` duplicate synchronous load of
> a freshly-written `@tool` script *during* `EditorFileSystem` reimport — hypothesis (c)
> below CONFIRMED; (a) instance/`Callable` lifetime REFUTED, the loader already retains
> instances on `_instances`). It is **4.2-only** (full Section 24 sweeps are crash-free on
> 4.3 / 4.4 / 4.5) and was *exposed*, not caused, by d948f61 — a pre-fix bisect crashes
> 4.2 too, just later (E8 vs E3). **Fix:** toolkit `5f23232` gates `_cmd_refresh` to
> `CACHE_MODE_REUSE` + `is_scanning` on 4.2 only; 4.3+ unchanged; the 4.2 in-session-edit
> trade-off is surfaced via an `extensions.refresh` restart `hint`. E1–E10 since
> re-validated crash-free across 4.2 / 4.3 / 4.4 / 4.5. Full record:
> `Plan/ExecutionPlan/41l-tricies-ter-extension-live-discovery.md` + engine audit
> `Insights/extension-reimport-crash-4.2-vs-4.3-analysis.md` (in the plan repo).

| Test | Status | Notes |
|------|--------|-------|
| EXT-S1 | PASS | Extension written `res://sv2_validation/sv2_test_extension.gd`, valid=true. ⚠ **As written in the section file it has no `class_name`** (see Finding A) |
| EXT-S2 (literal) | **FAIL — misleading, NOT a fix failure** | `extensions_refresh` → `commands:[]`. **Root cause = no `class_name`:** the loader enumerates extensions ONLY from `ProjectSettings.get_global_class_list()` (`extension_loader.gd:113-125, 288-297`); a script without `class_name` is never a global class, so it is structurally absent. Confirmed via `.godot/global_script_class_cache.cfg` — the script is not listed. Undiscoverable by ANY loader version. |
| EXT-S2 (corrected) | **PASS ✅ — d948f61 VERIFIED** | Re-wrote the same extension adding `class_name MCPToolkitSv2TestExt` (a genuinely-new class_name — exactly the fix's target scenario). `extensions_refresh` → discovered **both** `sv2_ext.hello` + `sv2_ext.add` with full metadata + group `sv2_test_group`, **in-session, no restart.** The documented pre-fix timing (diff against a stale class list) could not reliably produce this → the editor is running the fixed loader and the flush-barrier works. **The Major finding from the 2026-06-07 run is RESOLVED.** |
| E1 | PASS | `discover_tools` → group `sv2_test_group` listed with 2 tools, correct descriptions |
| E2 | PASS | `discover_tools request:["sv2_test_group"]` → activated; `sv2_ext_hello` + `sv2_ext_add` exposed with parameter schemas (dot→underscore in MCP tool name) |
| E3 | **CRASH — CRITICAL** | Calling the discovered tools **crashed the Godot editor.** `sv2_ext_hello(name:"Sweep")` returned empty `{}` (no greeting payload); `sv2_ext_add(a:3,b:7)` → `DISCONNECTED "WebSocket closed before response"`; follow-up `extensions_refresh` → `no connection to ws://127.0.0.1:6550 after 10000ms`. Editor process down. See Finding B. |
| E4–E10 | **BLOCKED** | Editor crashed at E3. Re-entrancy (E4), hot-reload add/modify/remove (E5), keywords (E6), deletion-while-loaded (E7), annotation options (E8), version bounds (E9), success-hints/error-API (E10) not reachable until restart. |

**Finding A (Major — sweep test-authoring bug; affects EXT-S1, E5, E6, E8, E9, E10):**
Every test extension in `Sections/24-extensions.md` is `@tool` / `extends MCPToolkitExtension`
with **no `class_name`**. The loader discovers extensions ONLY by scanning
`ProjectSettings.get_global_class_list()` for entries whose `base == "MCPToolkitExtension"`
(`extension_loader.gd::_is_extension_candidate` → `_discover_and_register` / `_do_rescan`). A
script with no `class_name` is not a global class → absent from that list → **undiscoverable,
independent of the d948f61 fix.** This bug masked the real verification: the literal run fails
even on a perfectly-working loader. **Action:** add a unique `class_name` to each Section-24 test
extension (e.g. `class_name MCPToolkitSv2TestExt` / `…AnnotatedExt` / `…VersionedExt` / `…HintsExt`).
(Also a doc mismatch: `extension_loader.gd` header says GDScript extensions have "no naming
restriction" — true, any `class_name` works since detection is by base class — while CLAUDE.md
says the class name "must start with MCPToolkit"; only the C# path enforces the prefix.)

**Finding B (CRITICAL — NEW; almost certainly unmasked by the now-working discovery):**
Invoking an extension command that was discovered **in-session via the d948f61 `_cmd_refresh`
path** crashes the editor process. Before d948f61 in-session discovery never worked, so this
live dispatch path was never exercised — the discovery fix appears to have unmasked a latent
crash when calling an extension `Callable` registered through the refresh path. Not yet
root-caused: the interactive editor's crash was not captured to disk (file logging off; the only
`godot.log` present is the headless 145-unit run). **Hypotheses to check:** (a) instance/`Callable`
lifetime — refresh-loaded instances are retained on `watcher._instances` whereas startup-loaded
ones go to `registry.set_meta("_extension_instances")`; a GC of the watcher-held instance would
dangle the lambda's `self`; (b) the two E3 calls were sent in one batch → possible re-entrancy in
extension dispatch; (c) `ResourceLoader.load(..., CACHE_MODE_IGNORE)` on a `class_name`'d script
creates a duplicate Script identity. **Repro plan (post-restart):** call ONE extension tool alone
and capture the editor's stderr/crash trace; then retry as a 2-call batch to test the re-entrancy angle.

Console error check: N/A — editor crashed. Cleanup: PENDING editor restart — `res://sv2_validation/`
(incl. `sv2_test_extension.gd` / `class_name MCPToolkitSv2TestExt`) is still on disk. It auto-loads
at next startup (harmless — startup loads but does not call), but should be removed before a clean sweep.

## Section 25 — Undo/Redo Verification (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| UR-Setup diag | PASS | diagnose_undo_redo ALL GREEN: builder_active=true, smoke undo/redo work, EditorUndoRedoManager, history_id=22 |
| UR-S3 | PASS | run_undo_redo_tests: **8/8** (prop_set/undo/redo, method_added/undo/redo, commit_do_executes, commit_undo) |
| UR1 (set_property) | PASS | 6/6 — pos set→undo→(0,0)→redo→(200,300) |
| UR2 (rename) | PASS | 4/4 — rename→undo reverts→redo restores |
| UR3 (groups add) | PASS | 4/4 — group removed by undo (count=0) |
| UR4 (reorder) | PASS | 5/5 — reorder index 0→undo back to original index 11 |
| UR5 (duplicate) | PASS | 3/3 — URDuplicate removed by undo |
| UR6 (groups remove+batch) | PASS | 7/7 — remove undone; batch-add undone across BOTH URTarget+URSibling |
| UR7 (delete_node) | PASS | 3/3 — deleted URSibling restored by undo |
| UR8 (control.set_layout) | PASS | 4/4 — anchor_left reverts 0.5→0 |
| UR9 (signal connect/disconnect) | PASS | 7/7 — connect undone; disconnect undone (show restored flags=2) |
| UR10 (path2d.edit_curve) | PASS | 4/4 — point removed by undo (count 1→0) |
| UR11 (particles.create) | PASS | 4/4 — GPUParticles2D removed by undo |
| UR12 (collision_from_sprite) | PASS | 5/5 — CollisionPolygon2D (20 pts) removed by undo, URSprite retained |
| **UR-CON.1** | **PASS** | **CRITICAL GATE: ZERO `UndoRedo history mismatch` errors** across all 12 tool sections |
| UR-Cleanup | PASS | 6 UR nodes deleted, scene saved |

Console error check: PASS (0 errors/warnings). **All 48 tests pass.** The @tool helper executes editor-side via node_call_method; the builder routes all mutation types (property/method/group) through EditorUndoRedoManager cleanly. **41l-tricies dispatch-safety + 53796f7 context_object fixes fully verified — no history mismatch.**

## Section 26 — LSP Tools (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 26.1 | PASS | lsp_diagnostics valid file → diagnostics=[], count=0 |
| 26.2 | PASS | bad file → 7 Error diagnostics with line/character/severity |
| 26.3 | PASS* | .gdshader → 8 diagnostics, but they are **GDScript parse errors** ("Unexpected identifier 'shader_type' in class body"). Godot's LSP is GDScript-only — it can't parse shaders. Tool returns success+array (loose expectation met) but content is GDScript-parse noise. *Godot LSP limitation |
| 26.4 | PASS | .cs → UNSUPPORTED_FILE_TYPE (mentions C#/.NET) |
| 26.5 | PASS | .cpp → UNSUPPORTED_FILE_TYPE (mentions GDExtension/C++) |
| 26.6 | PASS | absolute path → INVALID_PATH "must start with res://" |
| 26.7 | PASS | lsp_hover .cs → UNSUPPORTED_FILE_TYPE (shared guard across tools) |
| 26.8 | PASS | symbols: speed, health, damage_taken, _ready, take_damage (kinds + line ranges) |
| 26.9 | PASS | minimal: 1 implicit class symbol |
| 26.10 | PASS* | .gdshader symbols → empty (GDScript LSP can't extract shader symbols — same limitation as 26.3) |
| 26.11 | PASS | hover Node2D: class info in untrusted envelope (I5 — kind=hover, source=godot-lsp) |
| 26.12 | PASS | hover speed → "var speed: float = 100.0" |
| 26.13 | PASS | hover take_damage → "func take_damage(amount: int) -> void" |
| 26.14 | PASS | hover empty line → empty contents, no crash |
| 26.15 | PASS | completion → 10 items (total=2123), each label+kind |
| 26.16 | PASS | limit=3 respected → count=3 |
| 26.17 | PASS | definition take_damage call → res:// line 11 |
| 26.18 | PASS | definition damage_taken emit → signal decl res:// line 6 |
| 26.19 | PASS | definition Node2D → [] (engine class, no user source) |
| 26.20 | PASS | references damage_taken → 2 (decl + emit), res:// 1-based |
| 26.21 | PASS | references health → 3 (decl + 2 usages), res:// 1-based |
| C24 | PASS | write broken → diagnose (7 err) → fix → **targeted** refresh → diagnose clean. WATCH timing issue did NOT recur (tally 0/N this run) |
| C25 | PASS | symbols take_damage start_line=11 == definition line=11 (groups compose) |
| 26.22 | PASS | fresh file diagnostics without editor_refresh → recognized, clean, no crash |
| 26.23 | PASS | fresh file with targeted refresh → diagnostics=[] |

Console error check: PASS (0 errors — bad-file parse errors cleared by editor_refresh). **Note (Godot LSP limitation):** shader files (26.3, 26.10) are parsed by the GDScript LSP → spurious GDScript-parse errors / no symbols. Not a toolkit regression; the toolkit forwards .gdshader to Godot's GDScript-only LSP. Cleanup: 4 LSP test files deleted.

## Section 27 — Debugger Tools (2026-06-07)
| Test | Status | Notes |
|------|--------|-------|
| 27.1 | PASS | debug_state: active=false, breaked=false, can_debug=false |
| 27.2 | PASS | set breakpoint line 6, enabled=true |
| 27.3 | PASS | set breakpoint line 9, enabled=true |
| 27.4 | PASS | list includes line 6 + line 9 (count=14: our 2 + 12 pre-existing _stress_script_* breakpoints) |
| 27.5 | PASS | clear line 6 (enabled=false) |
| 27.6 | PASS | list: no line 6, has line 9 |
| 27.7 | PASS | clear line 9 |
| 27.8 | PASS | list: no sv2_debug_target breakpoints remain |
| 27.9 | PASS | .cs → UNSUPPORTED_FILE_TYPE (mentions C#/IDE) |
| 27.10 | PASS | .txt → UNSUPPORTED_FILE_TYPE (GDScript) |
| 27.11 | PASS | absolute path → INVALID_PATH (res://) |
| 27.12 | PASS | nonexistent.gd → NOT_FOUND |
| 27.13 | PASS | line=0 → INVALID_PARAMS "line must be >= 1" |
| 27.14 | PASS | line=9999 → INVALID_PARAMS "exceeds file length (11 lines)" |
| 27.15 | PASS | debug_continue (no game) → GAME_NOT_RUNNING (mentions game.start) |
| 27.16 | PASS | debug_continue (running, not breaked) → NOT_BREAKED |
| C26 | PASS | **Full breakpoint flow:** set bp→game_start→**breakpoint HIT (active=true, breaked=true, can_debug=true)**→continue→breaked=false→game_stop→active=false |

Console error check: PASS (no UndoRedo mismatch). 6 "File not found" errors on game_start for c5_script/sv2_broken_main/sv2_error_main — **phantom script-editor tabs** for scripts deleted in earlier sections (script_delete doesn't close editor tabs; known Pitfall-3-family limitation), not a regression. **Pre-existing state observed:** 12 breakpoints in untracked `res://_stress_script_*.gd` files (from prior stress test, visible in session's initial git status). Cleanup: debug scene+script deleted, breakpoint cleared.

---

# Final Summary (2026-06-07)

## Section Results
| Section | Result | Notes |
|---------|--------|-------|
| 0 Environment | 5 PASS, 2 N/A | GDScript, Godot 4.5 |
| 1 Scaffolding | 10/10 | |
| 2 Scene Tree | 18/18 | |
| 3 Node Properties | 28/28 | **3.8/3.9 colon-chain SET/GET now works in-memory** (was historical FAIL) |
| 4 Node Management | 14/14 | |
| 5 Signals | 7/7 | |
| 6 Scripts | 8/8 | |
| **7 Editor/Console ⭐** | 16/16 | **FOCUS — refresh precision + save re-entrancy clean** |
| 8 Project Settings | 12/12 | |
| 9 execute_code | 8/8 | gate open |
| 10 Input Map | 4/4 | |
| 11 Save System | 6/6 | gate open |
| 12 ClassDB | 7/7 | **12.6/12.7 offset pagination fixed** |
| 13 Animation | 12/12 | node_call_method gate open |
| 14 TileSet/TileMap | 28/28 | **all type-coercion fixed** |
| 15 Theme/Audio/Sprites | 12/12 | **volume_db/effect/animations fixed** |
| 16 Domain (3D/path/nav/particles/proc) | 28/28 | **all coercion fixed** |
| 17 Scene Query | 10/10 | |
| 18 File Ops/Phantom Tabs | 15/15 | **no _set_main_scene_state errors** |
| 19 collision_from_sprite | 3/3 | |
| 20 Runtime | 22/22 | **20.14 regex \d+ now matches** |
| 21 Game Guards/Crash | 13/13 | 21.6 transient race (self-heals) |
| 22 Combo Chains | 14/14 | |
| 23 C# | N/A | GDScript project |
| 24 Extensions | **Re-run 2026-06-08 (d948f61):** EXT-S2 PASS w/ class_name (**fix VERIFIED**); E1–E2 PASS; **E3 CRASH; E4–E10 BLOCKED** | in-session discovery FIXED; NEW crash calling extension tool (Finding B); sweep test exts miss class_name (Finding A) |
| **25 Undo/Redo ⭐** | 48/48 | **FOCUS — UR-CON.1 zero history mismatch** |
| 26 LSP | 25/25 | shader = GDScript-LSP limitation |
| 27 Debugger | 17/17 | C26 breakpoint HIT verified |
| Last-cleanup | DONE | folder removed (phantom-tab workaround) |

## ⭐ Focus Verdict — 41l-tricies dispatch-safety fix (commit 0366560)
**VERIFIED — no regression.**
- **Section 7 (editor.refresh precision + save re-entrancy guard):** Full refresh (`mode=full`) and targeted refresh (`mode=targeted`, `file_count` exactly matches input — 1 for one file, 2 for two) both correct. `editor_save_scene` works standalone, immediately after a refresh, and interleaved with refreshes — **zero console errors** across the entire shared save↔refresh flow. No re-entrancy errors.
- **Section 25 (UndoRedo dispatch):** **UR-CON.1 critical gate PASS — ZERO `UndoRedo history mismatch` errors** across all 12 mutation tools + builder integration (8/8) + 47 undo/redo cycles. Property-, method-, and group-based mutations all route through EditorUndoRedoManager cleanly.

## Regression Watch — all monitored fixes hold
| Fix Ref | Status | Where |
|---------|--------|-------|
| FIX-1 inline diagnostics | PASS | 1.3, 6.4 |
| FIX-4 OS singleton hint | PASS | 9.3 |
| FIX-5 PackedVector2Array tag | PASS | 3.20 |
| FIX-7 batch mode results | PASS | 3.12 |
| FIX-8 clear_buffer | PASS | 7.11 |
| FIX-A regions bulk-fill | PASS | 14.19 |
| FIX-B scene_path param | PASS | 2.14 |
| FIX-C discover_tools no split-notify | PASS | C10 |
| FIX-D autoload editor cache | PASS | 8.6 |
| FIX-E Resource type tag | PASS | 3.6 |
| FIX-F bare res:// guard | PASS | 3.10 |
| FIX-G signal node_path | PASS | 5.2 |
| FIX-H/279efed load() hint | PASS | 9.4 |
| FIX-I tileset_create valid TileSet | PASS | 14.1 |
| FIX-J no-tileset guard | PASS | 14.20 |
| FIX-2 tileset layer-count guard | PASS | 14.16 |
| a46487b unique_name + preload hint | PASS | 2.11, 6.5 |
| cb4e162 CLASS_MISMATCH | PASS | 2.12 |
| 23d69f9 autoload key guard | PASS | 8.4 |
| 5f96b62 signal method hint | PASS | 5.4 |
| c61d994 dup-with-properties | PASS | 4.11 |
| 462506b LayerMask / batch groups | PASS | 3.11, 4.12 |
| dec5b24 / e2c7041 crash-log cache | PASS | 21.5 |
| 8a6cbf0 error_buffer unfiltered scan | PASS | 21.11 |
| 53796f7 context_object (UR-CON) | PASS | UR-CON.1 |
| a28d17b wait_for_runtime hint | PASS | 20.4 |
| c6d5f40 autoload persistence warning | PASS | 20.10 |
| a828cb1 double-escape warning | ⚠ WATCH | 7.7 — regex works, but no proactive hint emitted |

## Findings & Pitfalls
| # | Severity | Finding | Detail |
|---|----------|---------|--------|
| 1 | **RESOLVED 2026-06-08 (d948f61)** | ~~Extension live-discovery broken in-session~~ → **FIXED** | The 2026-06-07 `commands=[]` had TWO causes: (a) the sweep's test extension has no `class_name`, so it is never a global class and is undiscoverable by design (Finding A in the re-run); (b) pre-d948f61 `_cmd_refresh` diffed a stale class list. Re-run 2026-06-08 with a `class_name`'d extension → **discovered in-session** (updated Section 24, EXT-S2 corrected). **Finding B — RESOLVED 2026-06-08 (`5f23232`):** the live-call crash is a latent **4.2-only** reimport SIGSEGV (`CACHE_MODE_IGNORE` duplicate load during reimport); 4.2 gated to `CACHE_MODE_REUSE`, 4.3/4.4/4.5 crash-free. See iter `41l-tricies-ter` + `Insights/extension-reimport-crash-4.2-vs-4.3-analysis.md`. |
| 2 | Minor | Phantom script-editor tabs (Pitfall-3) | `script_delete` leaves the script's editor tab open. Causes (a) "File not found" errors on later `game_start` (S27), and (b) `folder_delete` PATH_IN_USE blocking (Last-cleanup). No MCP API closes script tabs — requires editor restart. Workaround: delete empty folder via filesystem. |
| 3 | Minor | 21.6 crash-recovery transient race | Two `debugger_get_log` calls in rapid succession right after `game_stop` can briefly hit GAME_NOT_RUNNING ("registry not yet updated") before the cache fallback settles (~1s self-heal). |
| 4 | Info | Shader LSP = GDScript LSP | `.gdshader` diagnostics/symbols come back as GDScript-parse noise / empty — Godot's LSP is GDScript-only. Not a toolkit bug. |
| 5 | Info (doc) | Sweep-doc format drift | Several section docs specify shapes the tools don't use: LayerMask `{value:N}` (tool uses `{layers:[...]}`, 3.11), node_groups `groups:[]` (tool uses `entries:[{node_path,group}]`, 4.12), navigation `navigation_edit_polygon` (tool is `navigation_edit`), signal_manage `operation`/`source_path` (tool uses `action`/`node_path`). Tools work with the documented schema shapes; **the sweep section files need updating** (see maintenance note). |
| 6 | Info | Pre-existing project state | 12 breakpoints in untracked `res://_stress_script_*.gd` files (repo root, from a prior stress test — present in the session's initial git status). Not sweep artifacts; left untouched. |

## Improvement vs original 2026-05-24 sweep
The original full sweep recorded **12 failures + 59 skips** dominated by two systemic issues, both now resolved:
- **MCP param type-coercion** (offset, layers, volume_db, effect, animations, index, outlines, curve points, shadow, fov): the schemas are now properly typed (int/object/array/enum) — **every previously-failing coercion test passes** (12.6/12.7, 14.4–14.6, 15.5/15.6/15.9, 16.4/16.5/16.8/16.12–16.16/16.18–16.20/16.26).
- **Feature-gate desync** (execute_code, node_call_method, user_data returned FEATURE_GATED): all three gates are **open** this run — Sections 9, 11, 13.1, 20 runtime, 21 all execute (were SKIP before).
- **Colon-chain shader_parameter SET** (3.8) — the long-standing FAIL — now applies in-memory and reads back correctly (with an honest "shared external sub-resource" persistence warning).

The single net-new regression is **Finding #1 (extension live-discovery)** — worth a maintainer's look against commit 8d2a265.

## Cleanup state
All `res://sv2_validation/` artifacts removed; folder deleted (via filesystem workaround for the phantom-tab block). Project name restored to "Godot MCP Toolkit", main_scene restored to `res://Main.tscn`. No stray audio buses / input actions / save data. Editor was closed by the user at the end (clearing all phantom script tabs).

---

## Section 28 — Spatial Map & Placeholder Generators (2026-06-14 09:43)

> **Targeted single-section re-run** (not part of the 2026-06-07 full sweep above).
> Godot 4.5+ (dogfood repo project; `scene_close` present in cleanup group confirms ≥4.5).
> Repo HEAD `bec44d9` (placeholders/spatial feature from `b92f62a`). Tools exercised:
> `scene_spatial_map` (eager), `texture_generate` + `sound_generate` (`placeholders` group).
> **Setup:** `main.tscn` pre-existed as an empty `main` (Node2D) root — used as host scene
> (nodes created at `parent_path="."`). Section-2 scaffolding not needed.

| Test | Status | Notes |
|------|--------|-------|
| 28.1 | PASS | 3 Sprite2D (Sv2SpatA/B/C) created at (0,0)/(20,0)/(500,500); texture=res://icon.svg + Vector2 position set via batch (6/6 ok) |
| 28.2 | PASS | detail=full,class=Sprite2D: Sv2SpatA space=2d, bounds {pos[-64,-64],size[128,128]}, overlaps=[./Sv2SpatB] (C excluded), nearest=./Sv2SpatB dist=20. Confirms `radius` is omittable despite schema marking it required (minimal call) |
| 28.3 | PASS | detail=brief: 3 nodes carry position/size/space only — NO overlaps/bounds keys |
| 28.4 | PASS | region=[-100,-100,300,300]: node_count=2, Sv2SpatA+B present, Sv2SpatC absent (outside region) |
| 28.5 | PASS | radius=150,center=[0,0]: Sv2SpatC absent (~693 > 150); A+B present |
| 28.6 | PASS | max_nodes=1: returned=1, truncated=true, hint "narrow with subtree/class/region/radius, or raise max_nodes (<=1000)" |
| 28.7 | PASS | guards: detail=verbose → -32602 INVALID_PARAMS listing brief\|normal\|full (mentions `detail`); region=[1,2,3] → INVALID_PARAMS "region must have 4 numbers...got 3" (mentions `region`) |
| 28.7b | PASS | MeshInstance3D Sv2SpatMesh pos Vector3(1,2,3); subtree map → space=3d, bounds {pos[1,2,3],size[0,0,0]}, size len 3 — mesh-less zero-size AABB at origin |
| 28.8 | PASS | discover_tools "placeholder texture sprite sound" → placeholders activated; texture_generate + sound_generate registered (loose keyword also pulled asset_ops + path_editing) |
| 28.9 | PASS | all 7 shapes (solid/circle/triangle/diamond/arrow/checkerboard/grid) → status=created; class=null + index warning (accepted per test) |
| 28.10 | PASS | 4 colour formats all parse + create: hex "#ff8800", named "red", 0-1 array [0.1,0.2,0.9], 0-255 array [255,128,0] |
| 28.11 | PASS | hollow circle (fill [0,0,0,0] transparent + outline #00ff00 width 3) created |
| 28.12 | PASS | label overlay "Enemy"/#ffffff on #444444 solid created (call ok; bitmap not visually inspected) |
| 28.13 | PASS | dimension cap 4096×4096 → response echoes width=1024, height=1024 (clamped, NOT rejected) |
| 28.14 | PASS | if_exists chain: replace→status=created; return→status=returned (idempotent no-op); fail→ALREADY_EXISTS with replace/return hint |
| 28.15 | PASS | guards: .jpg→INVALID_PATH "expected: png"; res://../escape.png→PATH_DENIED "contains '..'"; all-transparent→INVALID_PARAMS "fully transparent"; shape=hexagon→-32602 (mentions `shape`) |
| 28.16 | PASS | all 5 waveforms (sine/square/triangle/sawtooth/noise) → status=created; class=null + index warning |
| 28.17 | PASS | pitch sweep square 200→900, decay 0.1: response echoes end_frequency=900 |
| 28.18 | PASS | duration cap 30s → response echoes duration=5 (clamped) |
| 28.19 | PASS | guards: .mp3→INVALID_PATH "expected: wav"; waveform=fmsynth→-32602 (mentions `waveform`); res://../escape.wav→PATH_DENIED |

Console error check: **PASS** — `UndoRedo history mismatch` count=0, error-level count=0, buffer clean (cleared at section start). The expected PNG/WAV reimport noise did not surface as console errors during the run.

**Observation (not a fail):** every `texture_generate`/`sound_generate` returned `class:null` with an "EditorFileSystem did not index … within 5000ms — call editor.wait_for_idle" warning — the asset write succeeds but the import scan doesn't finish inside the 5 s window under rapid batched writes. The test explicitly accepts "null with an index warning", so this is expected behavior, not a regression. Callers needing the imported `class` immediately should pass `wait_for_scan_ms` or follow with `editor_wait_for_idle`.

Cleanup: Sv2SpatA/B/C/Mesh deleted (4/4); `folder_delete` placeholders recursive → 35 files removed (15 PNG + 7 WAV assets + ~13 `.import` companions; the rest hadn't been indexed yet); verified via filesystem — only `sv2_validation/main.tscn` remains. Groups placeholders/asset_ops/path_editing reset. `main.tscn` left in place (pre-existing empty Node2D; test nodes were in-memory only — `editor_save_scene` never called — so disk was never modified).

**Verdict: 20/20 PASS (28.1–28.19 + 28.7b). Zero failures, zero console regressions.**

---

## 41m-sexies gate (4.5) (2026-06-14)

- **Godot version:** 4.5
- **Scope:** Section 28 full (28.1–28.19 + 28.7b) + Section 18 folder_delete (18.12, 18.13) + point-checks P1–P5.
- **What changed this iter:** B (asset settle — `class` always populated, no index warning, `wait_for_scan_ms` defaults to 0, fast return), C (discover_tools dominant-group activation), D (invalid enums rejected server-side as JSON-RPC -32602).
- **Verdict: ALL GREEN.** Section 28 = 20/20 PASS. Section 18 folder_delete = 2/2 PASS. Point-checks P1–P5 = 5/5 PASS. Zero console regressions (no UndoRedo mismatch, no errors; only benign `[MCPTools]` operational info-warnings + one stray Control-anchor editor warning unrelated to our ops).

### Item B regression-positive (vs the prior Section 28 block above)
The earlier block recorded `class:null` + "did not index within 5000ms" warning as accepted behavior. **41m-sexies flips this:** every `texture_generate` now returns `class:"Texture2D"` and every `sound_generate` returns `class:"AudioStreamWAV"` — **always populated by construction**, `warnings:[]` (no index warning), `elapsed_ms:0` on the default path. Confirmed across all of 28.9 (7 shapes), 28.16 (5 waveforms), and P1.

### Section 28
| Test | Status | Notes |
|------|--------|-------|
| 28.1 | PASS | 3 Sprite2D (Sv2SpatA/B/C) at (0,0)/(20,0)/(500,500), texture=res://icon.svg via batch (all ok) |
| 28.2 | PASS | detail=full: Sv2SpatA space=2d, bounds pos[-64,-64] size[128,128], overlaps=[./Sv2SpatB] (C excluded), nearest=./Sv2SpatB dist=20 |
| 28.3 | PASS | detail=brief: position/size/space only — NO overlaps/bounds keys |
| 28.4 | PASS | region=[-100,-100,300,300]: node_count=2 (A+B), C absent |
| 28.5 | PASS | radius=150 center=[0,0]: C absent (~693>150), A+B present |
| 28.6 | PASS | max_nodes=1: returned=1, truncated=true, hint to narrow/raise cap (<=1000) |
| 28.7 | PASS | detail=verbose → **-32602** naming `detail` (server Zod); region=[1,2,3] → **INVALID_PARAMS** "region must have 4 numbers...got 3" (plugin) — dual contract confirmed |
| 28.7b | PASS | MeshInstance3D pos Vector3(1,2,3), subtree map → space=3d, bounds/size length 3 (zero-size AABB at origin) |
| 28.8 | PASS | discover_tools "placeholder texture sprite sound" → **only** `placeholders` returned; asset_ops/path_editing pruned (Item C dominant-match) |
| 28.9 | PASS | all 7 shapes → class="Texture2D" (always), warnings=[], elapsed_ms=0, status=created |
| 28.10 | PASS | 4 colour formats parse+create: "#ff8800", "red", [0.1,0.2,0.9], [255,128,0] |
| 28.11 | PASS | hollow circle (transparent fill + #00ff00 outline width 3) created |
| 28.12 | PASS | label overlay "Enemy"/#ffffff on #444444 solid (call ok; bitmap not visually inspected) |
| 28.13 | PASS | dim cap 4096×4096 → echoes width=1024 height=1024 (clamped) |
| 28.14 | PASS | if_exists: replace→created; return→status=returned; fail→ALREADY_EXISTS |
| 28.15 | PASS | .jpg→INVALID_PATH "png"; res://../escape.png→PATH_DENIED; all-transparent→INVALID_PARAMS "transparent"; shape=hexagon→**-32602** naming `shape` |
| 28.16 | PASS | all 5 waveforms → class="AudioStreamWAV" (always), warnings=[], elapsed_ms=0 |
| 28.17 | PASS | sweep square 200→900 decay 0.1 → echoes end_frequency=900 |
| 28.18 | PASS | duration cap 30 → echoes duration=5 (clamped) |
| 28.19 | PASS | .mp3→INVALID_PATH "wav"; waveform=fmsynth→**-32602** naming `waveform`; res://../escape.wav→PATH_DENIED |

Console error check (Section 28): **PASS** — buffer cleared at start; ending buffer held one benign `[MCPTools] auto-created directory` info-warning + one generic Control-anchor editor warning (background, not from our ops). No UndoRedo mismatch, no errors. No PNG/WAV reimport noise (consistent with the fast no-poll settle).

### Section 18 (folder_delete)
| Test | Status | Notes |
|------|--------|-------|
| 18.12 | PASS | 1 scene inside del_folder → folder_delete recursive: tab_closed=inner.tscn, directories_deleted=1, no stale_tabs |
| 18.13 | PASS | 2 scenes + main active → stale_tabs=[inner1.tscn, inner2.tscn] (2 entries), hint names _set_main_scene_state; scene_close on both succeeded |

### Point-checks
| Check | Status | Notes |
|-------|--------|-------|
| P1 | PASS | Batched 3 textures + 2 sounds (default path) → all non-null class (Texture2D/AudioStreamWAV), warnings=[], elapsed_ms=0; batch prompt. **Caveat:** explicit `wait_for_scan_ms` 2000/4000/5000 all emitted the "did not index within Xms" timeout warning even after `editor_wait_for_idle` reported FS idle (`was_scanning:false`). Asset still created with class populated; a targeted `editor_refresh` then indexed it (errors_cleared:1). The opt-in poll does NOT settle for FileAccess-written files without a refresh in-session — consistent with *why* Item B demoted the poll to opt-in. Item B's core guarantee (class always populated, no blocking, no default warning) holds. |
| P2 | PASS | `scene_spatial_map` with NO arguments → success, node_count=5, space="mixed"; radius/max_nodes/region/center confirmed optional (no missing-required-param error) |
| P3 | PASS | detail=verbose, shape=hexagon, waveform=fmsynth → all **JSON-RPC -32602** with the offending param named — server path, NOT plugin INVALID_PARAMS |
| P4 | PASS | flat folder (2 files) → directories_deleted=1; nested (root+sub_a+sub_b) → directories_deleted=3 (1 + 2 subdirs); both gone (re-delete → NOT_FOUND) |
| P5 | PASS | "placeholder texture sprite sound" → only `placeholders` (asset_ops/path_editing pruned); "sound" → both `placeholders` AND `audio` (recall preserved); discover_tools(reset:true) deactivated all groups |

Cleanup: Sv2SpatA/B/C/Mesh deleted (4/4), main.tscn saved, `folder_delete placeholders` recursive → 60 files removed (PNG/WAV assets + .import companions), p4_flat/p4_nested/del_folder all removed during their tests, all tool groups reset. Scene tree verified back to childless `main` Node2D. Final console buffer cleared.

**Gate verdict: PASS — all 5 point-checks green; Section 28 (20/20) + Section 18 folder_delete (2/2) clean; no unexpected console errors. Items B/C/D all verified working.**

---

## 41m-sexies gate (4.2) (2026-06-14)

- **Godot version:** 4.2 (project `application/config/features` = `PackedStringArray("4.2", "GL Compatibility")`; the dogfood repo is 4.5-cached, opened in a live 4.2 editor for this gate)
- **MCP:** connected via repo `.mcp.json`
- **Scope:** Section 28 full (28.1–28.19 + 28.7b) against the 4.2 editor. **Mandatory pre-41n pass** — last iter before the 41n architecture-review series. Goal: confirm **no 4.2-only regression** in the version-independent changed behaviors (B/C/D).
- **Setup:** `res://sv2_validation/main.tscn` pre-existed as an empty `main` (Node2D) — opened as host scene; test nodes created at `parent_path="."`. No project reimport/load noise observed when scanning the console (the one-time 4.5→4.2 reimport, if any, had settled before the run; buffer cleared at start).
- **Verdict: PASS — 20/20.** Every observed value is **identical to the 4.5 run** (same block above). No 4.2-only regression in Items B, C, or D. Zero console errors, no UndoRedo mismatch.

### Item B (asset settle) — identical on 4.2, no regression
`class` is **always populated by construction** on 4.2 exactly as on 4.5: every `texture_generate` → `class:"Texture2D"`, every `sound_generate` → `class:"AudioStreamWAV"`, **`warnings:[]`** (no "did not index within 5000ms" warning), **`elapsed_ms:0`**. Verified across 28.9 (7 shapes), 28.10–28.14 (8 more textures), and 28.16 (5 waveforms) + 28.17/28.18. As predicted, the generators derive `class` and skip the FS poll — no version-specific API touched. (`Image.save_png`, `AudioStreamWAV.save_to_wav`, `update_file`, `get_file_type` all behave on 4.2.)

### Item D (enum contract) — identical on 4.2 (server-side Zod)
Invalid **enums** rejected as JSON-RPC **-32602** naming the param — version-independent, confirmed on 4.2: `detail=verbose` → -32602 `detail`; `shape=hexagon` → -32602 `shape`; `waveform=fmsynth` → -32602 `waveform`. Non-enum guards reach the plugin and return toolkit codes (INVALID_PATH / PATH_DENIED / INVALID_PARAMS), same as 4.5.

### Item C (discover_tools dominant-match) — identical on 4.2 (server-side)
28.8: `discover_tools "placeholder texture sprite sound"` activated **only** `placeholders` (asset_ops / path_editing pruned) — dominant-match is server-side, version-independent. Confirmed on 4.2.

### Section 28
| Test | Status | Notes |
|------|--------|-------|
| 28.1 | PASS | 3 Sprite2D (Sv2SpatA/B/C) at (0,0)/(20,0)/(500,500), texture=res://icon.svg + Vector2 position via inline props (2/2 each, 6/6) |
| 28.2 | PASS | detail=full: Sv2SpatA space=2d, bounds pos[-64,-64] size[128,128], overlaps=[./Sv2SpatB] (C excluded), nearest=./Sv2SpatB dist=20 |
| 28.3 | PASS | detail=brief: position/size/space only — NO overlaps/bounds keys |
| 28.4 | PASS | region=[-100,-100,300,300]: node_count=2 (A+B), C absent |
| 28.5 | PASS | radius=150 center=[0,0]: C absent (~693>150), A+B present |
| 28.6 | PASS | max_nodes=1: returned=1, truncated=true, hint to narrow/raise cap (<=1000) |
| 28.7 | PASS | detail=verbose → **-32602** naming `detail` (server Zod); region=[1,2,3] → **INVALID_PARAMS** "region must have 4 numbers...got 3" (plugin) — dual contract confirmed |
| 28.7b | PASS | MeshInstance3D pos Vector3(1,2,3), subtree map → space=3d, bounds pos[1,2,3] size[0,0,0], size length 3 (zero-size AABB at origin) |
| 28.8 | PASS | discover_tools "placeholder texture sprite sound" → **only** `placeholders` returned; asset_ops/path_editing pruned (Item C dominant-match) |
| 28.9 | PASS | all 7 shapes (solid/circle/triangle/diamond/arrow/checkerboard/grid) → class="Texture2D" (always), warnings=[], elapsed_ms=0, status=created |
| 28.10 | PASS | 4 colour formats parse+create: "#ff8800", "red", [0.1,0.2,0.9], [255,128,0] |
| 28.11 | PASS | hollow circle (transparent fill [0,0,0,0] + #00ff00 outline width 3) created |
| 28.12 | PASS | label overlay "Enemy"/#ffffff on #444444 solid (call ok; bitmap not visually inspected) |
| 28.13 | PASS | dim cap 4096×4096 → echoes width=1024 height=1024 (clamped, not rejected) |
| 28.14 | PASS | if_exists: replace→status=created; return→status=returned (no-op); fail→ALREADY_EXISTS with replace/return hint |
| 28.15 | PASS | .jpg→INVALID_PATH "expected: png"; res://../escape.png→PATH_DENIED "contains '..'"; all-transparent→INVALID_PARAMS "fully transparent"; shape=hexagon→**-32602** naming `shape` |
| 28.16 | PASS | all 5 waveforms (sine/square/triangle/sawtooth/noise) → class="AudioStreamWAV" (always), warnings=[], elapsed_ms=0 |
| 28.17 | PASS | sweep square 200→900 decay 0.1 → echoes end_frequency=900 |
| 28.18 | PASS | duration cap 30 → echoes duration=5 (clamped) |
| 28.19 | PASS | .mp3→INVALID_PATH "expected: wav"; waveform=fmsynth→**-32602** naming `waveform`; res://../escape.wav→PATH_DENIED |

Console error check (Section 28): **PASS** — buffer cleared at start; mid-run and end-of-run reads both returned 0 lines. No UndoRedo mismatch, no errors, **no PNG/WAV reimport noise** (consistent with the fast no-poll settle — no `.import` companions were even created, see Cleanup). No 4.2 editor console errors of any kind during Section 28.

Cleanup: Sv2SpatA/B/C/Mesh deleted (4/4), `editor_save_scene` → main.tscn saved, `folder_delete placeholders` recursive → **22 files removed** (15 PNG + 7 WAV — exactly the generated assets; **no `.import` companions**, since the no-poll path never triggered a reimport in-session). Scene tree verified back to childless `main` Node2D; final console buffer clean. All tool groups reset (placeholders + cleanup deactivated).

**4.2 gate verdict: PASS — Section 28 clean 20/20, every value matching the 4.5 run, no 4.2-only regression in Items B/C/D, no unexpected console errors. Cleared for the 41n architecture-review series.**
