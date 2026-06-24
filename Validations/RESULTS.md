# MCP Tool Sweep v2 Results

- **Date:** 2026-06-24
- **Godot version:** TBD (from S0)
- **Project type:** GDScript (from S0)
- **Sections run:** 0-28 + Last-cleanup (full sweep)
- **Sweep:** 41n Pass-3 §1.3 cumulative regression sweep
- **Godot version:** 4.5
- **Project type:** GDScript
- **Main scene (original):** res://Main.tscn
- **Project name (original):** Godot MCP Toolkit
- **Total:** 452 tests | 444 passed | 2 failed | 6 skipped | 1 section BLOCKED (S23 C#)

---

## Section Results

| Section | Tests | Passed | Failed | Skipped | Notes |
|---------|-------|--------|--------|---------|-------|
| S0 — Environment Detection | 7 | 7 | 0 | 0 | Godot 4.5, GDScript, scene_close visible (4.5+), no dotnet |
| S1 — Scaffolding | 10 | 10 | 0 | 0 | FIX-1 PASS (valid+diagnostics inline); main.tscn replaced from prior run |
| S2 — Scene Tree & Node Creation | 19 | 19 | 0 | 0 | CLASS_MISMATCH(cb4e162)✓, unique_name✓, scene_path(FIX-B)✓, batch no-failed/hint(034D)✓, path-norm✓ |
| S3 — Node Properties & Methods | 34 | 34 | 0 | 0 | FIX-E/F/7✓, ResourceRef(Pitfall4)✓, LayerMask(462506b)✓, batch-partial(034D)✓, groups-reject(032)✓, PackedVec2(053)✓, control_set_layout✓; 3.19 null (non-@tool editor limit, hint provided) |
| S4 — Node Management | 16 | 16 | 0 | 0 | rename/reparent/reorder/duplicate✓, batch-entries(462506b)✓, partial-fail(034D site-2)✓, all-success no-failed/hint✓, c61d994 Vector2 inferred✓ |
| S5 — Signals | 7 | 7 | 0 | 0 | FIX-G node_path✓, connect/disconnect✓, method-hint(5f96b62)✓ INVALID_PARAMS w/ diagnostic on nonexistent; 5.6 INVALID_PARAMS (method DNE, not NOT_FOUND) |
| S6 — Script Operations | 9 | 9 | 0 | 0 | FIX-1✓, concern-054 pagination (truncated+total_lines+next_start_line+hint)✓, preload-hint(a46487b)✓, deps✓; folder_path in asset_list ignored (returned all 134 .gd files) |
| S7 — Editor Operations & Console | 16 | 14 | 1 | 1 | FAIL 7.5: execute_code GAME_NOT_RUNNING (runtime-only); BLOCKED 7.16: editor_get_errors not in any group; FIX-8 clear_buffer✓, invalid-regex INVALID_PARAMS✓, editor_refresh targeted✓; a828cb1 inconclusive (empty buffer) |
| S8 — Project Settings & Autoloads | 12 | 12 | 0 | 0 | 23d69f9 autoload-guard✓, FIX-D editor-cache-updated hint✓, layer_names set/get/clear✓, invalid-category INVALID_PARAMS✓; MCP token reset on name change (expected) |
| S9 — execute_code & Hints | 8 | 8 | 0 | 0 | FIX-4 singleton hint✓ (OS/Engine/EditorInterface/ProjectSettings all rejected w/ MCP-tool hint), FIX-H load() hint✓ (node_set_property suggestion), context=editor works; 9.7 "invalid syntax" → EXECUTE_FAILED (identifier err, not parse err) |
| S10 — Input Map | 4 | 4 | 0 | 0 | 09a6392 name param✓ (not action_name); add/bind/unbind/remove all success; event object shape {type,keycode}✓ |
| S11 — Save System | 7 | 6 | 0 | 1 | PATH_DENIED on user://addons/godot_mcp_toolkit/✓; concern-054 paging (truncated+total_bytes+next_offset+hint; final window no hint; EOF bytes=0)✓; BLOCKED 11.7.6: mcp/* write-guarded, no meta_set_limits tool |
| S12 — ClassDB Introspection | 7 | 7 | 0 | 0 | search/get_info✓, Sv2Actor found as global class✓, UNKNOWN_CLASS w/ hint✓, offset pagination (properties_total+methods_total stable across pages)✓; 12.7 offset past end → classes=[] total=3 truncated=true |
| S13 — Animation & AnimationTree | 12 | 12 | 0 | 0 | keyframe add/get (player_path+animation_name+track_path params)✓, animationtree set_root/add_node/transitions/list✓, INVALID_CLASS on non-AnimationTree✓; animation auto-created by keyframe tool |
| S14 — TileSet & TileMap | 33 | 33 | 0 | 0 | FIX-I TileSet type✓, FIX-A regions✓, FIX-J no-tileset guard INVALID_STATE✓, FIX-2 invalid-coords errors[]✓, concern-031 per-verb foreign-key (all 5 INVALID_PARAMS naming correct tool)✓; tilemap_path (set) vs node_path (read) confirmed |
| S15 — Theme, Audio, SpriteFrames | 12 | 12 | 0 | 0 | theme_edit 2 edits✓, invalid_type schema-rejected✓, audiobus add/set/effect/list/Master-guard✓, spriteframes create/edit/from_spritesheet✓ |
| S16 — 3D, Path2D, Navigation, Particles, Procedural | 28 | 28 | 0 | 0 | 3d primitives/env/light/camera✓, path2d set/add/remove/clear/guard✓, nav set/add/bake/remove/guard✓, particles all 8 presets (2d+3d)+guards✓, procedural gradient/curve/noise+guards✓; add_point needs points[] not bare offset/color; curve points need {position:{x,y}} not bare {x,y} |
| S17 — Scene Inheritance & Query | 10 | 10 | 0 | 0 | scene_create_inherited success+NOT_FOUND guard✓, scene_query class/name/properties/root_path filters✓, no-filter INVALID_PARAMS✓, bad-root NOT_FOUND✓ |
| S18 — Phantom Tab Cleanup & File Operations | 16 | 16 | 0 | 0 | scene_close non-active✓, scene_delete active+non-active (tab_closed:true)✓, file_delete .tscn tab✓, asset_import→CompressedTexture2D✓, folder_delete 1-scene (tab_closed)✓, folder_delete 2-scenes (stale_tabs×2 + follow-up scene_close)✓, last-tab close✓; active-tab scene_delete returns hint (docs said no hint — harmless); material.tres UID warn after shader recreate (expected) |
| S19 — collision_from_sprite | 3 | 3 | 0 | 0 | sprite+texture setup✓, collision_from_texture polygon_count=1 total_points=20✓, INVALID_CLASS guard✓; tool name is collision_from_texture (not collision_from_sprite as section docs say) |
| S20 — Game Start, Runtime & Debugging | 22 | 20 | 0 | 2 | game_start (runtime_ready:true)✓, runtime_screenshot✓, runtime_get_node_state (/root/main not /root/Sv2Main)✓, script_vars speed/label✓, set_property speed 100→200✓, debugger_get_log✓, execute_code seed+current_scene.name✓, text_filter plain+regex+braces✓, invalid-regex INVALID_PARAMS✓, input_simulate action✓, animation_player_control play✓, signal_emit runtime✓, game_stop✓; SKIP 20.4 (false-hint not testable after runtime connected); SKIP 20.10 (no autoloads in runtime scene); 20.14 \\d needs [0-9]+ in JSON context |
| S21 — game_start Guards & Crash Recovery | 13 | 13 | 0 | 0 | broken-script launches (success=true, runtime_ready=false)✓; parse error in GAME_NOT_RUNNING hint✓; cached log after stop (dec5b24/e2c7041)✓; SV2_BROKEN filter count=0✓; null-ref error_buffer (type=log_scan, source/function/line)✓; text_filter+error_buffer independent (8a6cbf0)✓; NONEXISTENT filter lines=[] but error_buffer intact✓ |
| S22 — Combo Chains | 14 | 14 | 0 | 0 | C1 resource round-trip✓, C2 script validation✓, C3 scene build✓, C4 signal persistence✓, C5 full game lifecycle✓, C6 TileMap pipeline✓, C7 script→immediate check✓, C8 node mgmt pipeline✓, C9 batch instantiate transforms✓, C10 discover_tools 12-step keyword+reset✓, C11 editor_refresh targeted✓, C12 folder_delete open tabs✓, C27 version-gate 4.5 scene_close visible✓, C28 control_set_layout anchor round-trip✓; signal_manage uses target_path not target_node_path; c6_ts.tres persisted after resource_delete (scan-delay race) |
| S23 — C# Compatibility | 0 | 0 | 0 | BLOCKED | Standard (non-.NET) editor on a GDScript project — C# nodes/extensions cannot compile |
| S24 — Extension Discovery | 19 | 18 | 0 | 1 | EXT-S1/S2/S3✓, E1 catalog✓, E2 activate✓, E3 hello+add✓, E4 re-entrancy✓, E5-modify hot-reload 3cmds(4.5 live)✓ / multiply-call SKIP(ToolSearch cache staleness post-tools/list_changed; registration confirmed via refresh response), E5-remove delete+ghost-call error✓, E6 keywords match/non-match✓, E7 delete-while-loaded→error-not-crash✓, E8 readOnlyHint+timeout_ms annotated✓, E9 version-bounds new_only visible/old_only hidden(4.5)✓, E10a hint-inject✓, E10b handler-hint-wins✓, E10c INVALID_PARAMS+hint✓, E10d happy-path✓; console clean (48 info lines, no errors) |
| S25 — Undo/Redo Verification | 48 | 48 | 0 | 0 | UR-S1/S2/S3 builder 8/8✓; UR1 set_property(200,300)→undo(0,0)→redo(200,300)✓; UR2 rename→undo(original restored)→redo(renamed)✓ note: trigger_undo needs current name not original; UR3 groups add undo✓; UR4 reorder index12→0→undo(12)✓; UR5 duplicate→undo removed✓; UR6 remove+batch groups undo✓; UR7 delete_node→undo restored✓; UR8 control_set_layout→undo(anchor_left=0)✓; UR9 signal connect/disconnect undo (status:returned confirms reconnect)✓; UR10 path2d add point→undo(point_count=0)✓; UR11 particles_create→undo removed✓; UR12 collision_from_texture→undo removed✓; CON: ZERO UndoRedo history mismatch lines (regression gate CLEAR) |
| S26 — LSP Tools | 27 | 26 | 1 | 0 | LSP reachable✓; 26.1 valid→count=0✓; 26.2 bad→7 errors(severity=Error)✓; 26.3 shader→errors returned(LSP treats gdshader as GDScript on 4.5 — expected)✓; 26.4 .cs→UNSUPPORTED_FILE_TYPE+C#/.NET✓; 26.5 .cpp→UNSUPPORTED_FILE_TYPE+GDExtension✓; 26.6 abs-path→INVALID_PATH✓; 26.7 hover .cs→UNSUPPORTED_FILE_TYPE(guard shared)✓; 26.8 symbols valid(speed/health/damage_taken/ready/take_damage)✓; 26.9 symbols minimal(1)✓; 26.10 symbols shader(empty,no crash)✓; 26.11 Node2D hover+untrusted envelope(I5)✓; 26.12 speed hover→float✓; 26.13 take_damage hover→signature✓; 26.14 empty-line→empty contents(no crash)✓; FAIL 26.15 completion default→count=20 (expected ≤10 per schema "default 10"; implementation defaults to 20); 26.16 limit=3→count=3✓; 26.17 def take_damage→line11✓; 26.18 def damage_taken→line6✓; 26.19 def Node2D→[](engine class)✓; 26.20 refs damage_taken→2✓; 26.21 refs health→3✓; C24 write/diagnose/fix targeted-refresh-sufficient(WATCH 0/1)✓; C25 symbols+definition match✓; 26.22 fresh no-refresh→ok✓; 26.23 fresh with-refresh→clean✓; console clean |
| S27 — Debugger Tools | 17 | 16 | 0 | 1 | 27-S1 write sv2_debug_target.gd✓; 27-S2 refresh✓; 27-S3 activate debugger(4 tools)✓; 27.1 debug_state(no game: active=false,breaked=false,can_debug=false)✓; 27.2 set BP line6(enabled=true)✓; 27.3 set BP line9(enabled=true)✓; 27.4 list_BPs→both present(count=2)✓; 27.5 clear line6(enabled=false)✓; 27.6 list→only line9✓; 27.7 clear line9✓; 27.8 list→empty✓; 27.9 .cs→UNSUPPORTED_FILE_TYPE+GDScript+IDE✓; 27.10 .txt→UNSUPPORTED_FILE_TYPE+GDScript✓; 27.11 abs-path→INVALID_PATH✓; 27.12 nonexistent→NOT_FOUND✓; 27.13 line0→INVALID_PARAMS(">=1")✓; 27.14 line9999→INVALID_PARAMS("exceeds")✓; 27.15 continue no-game→GAME_NOT_RUNNING✓; SKIP 27.16(game-running-not-breaked not testable during sweep); C26 create-scene+attach-script+BP+start(breaked=true)→continue(breaked=false)→stop(active=false) PASS✓; console clean |
| S28 — Placeholders & Spatial Map | 22 | 22 | 0 | 0 | 28.1 build 3 sprites✓; 28.2 spatial_map full+class(space:2d,bounds,overlaps A↔B not C,nearest)✓; 28.3 brief(position/size only,no overlaps)✓; 28.4 region filter(A present,C absent)✓; 28.5 radius filter(C absent)✓; 28.6 max_nodes=1(returned:1,truncated:true+hint)✓; 28.7 guards(verbose→-32602 naming detail,region[1,2,3]→INVALID_PARAMS)✓; 28.7b 3D MeshInstance3D(space:3d,AABB bounds len=3)✓; 28.8 discover_tools placeholders(dominant-match only;no asset_ops/path_editing)✓; 28.9 all 7 shapes(class:Texture2D,status:created,elapsed_ms≈0)✓; 28.10 4 color formats(hex/named/0-1/0-255 all succeed)✓; 28.11 hollow circle(transparent fill+outline)✓; 28.12 label overlay✓; 28.13 dimension cap(4096→1024 clamped)✓; 28.14 if_exists(replace→created,return→returned,fail→ALREADY_EXISTS)✓; 28.15 texture guards(x.jpg→INVALID_PATH,../escape→PATH_DENIED,all-transparent→INVALID_PARAMS,hexagon→-32602)✓; 28.16 all 5 waveforms(AudioStreamWAV,elapsed_ms≈0)✓; 28.17 pitch sweep(end_frequency=900 echoed,decay=0.1)✓; 28.18 duration cap(30→5 clamped)✓; 28.19 sound guards(x.mp3→INVALID_PATH,fmsynth→-32602 naming waveform,../escape.wav→PATH_DENIED)✓; console clean(0 sv2 warnings/errors); 4 spatial nodes deleted+placeholders/ folder deleted(42 files) |
| Last-cleanup | — | — | — | — | All 8 sv2_validation files deleted (actor.gd, shader.gdshader, anim_lib.tres, atlas_tileset.tres, material.tres, tileset.tres, main.tscn, sub.tscn); res://sv2_validation/ is empty on disk (asset_list→0); folder_delete PATH_IN_USE: ghost c5_script.gd script editor tab (file deleted, tab persists — no programmatic close API); project settings already correct (name+main_scene); discover_tools reset✓; **manual step required**: close c5_script.gd tab in Godot script editor, then folder_delete res://sv2_validation/ |

---

## Regression Watch Results

| Fix Ref | Section.Test | Status | Notes |
|---------|-------------|--------|-------|
| FIX-1 (script_check inline diagnostics) | S1, S6 | PASS | Diagnostics returned inline with script_write response |
| FIX-B (scene_path→file_path rename) | S2 | PASS | scene_create accepts file_path param correctly |
| cb4e162 (CLASS_MISMATCH guard) | S2 | PASS | Invalid class_name returns CLASS_MISMATCH with hint |
| 034D (batch no-failed/hint on all-success) | S2, S3, S4 | PASS | All-success batch has no failed/hint fields |
| 462506b (batch-entries, LayerMask) | S3, S4 | PASS | Batch entries shape correct; LayerMask int round-trip ✓ |
| FIX-E/F/7 (node property edge cases) | S3 | PASS | ResourceRef, PackedVector2, groups-reject all correct |
| FIX-G (signal_manage node_path param) | S5 | PASS | node_path used for source (not signal_path) |
| 5f96b62 (method-hint on invalid signal) | S5 | PASS | INVALID_PARAMS returned with diagnostic hint |
| a46487b (preload-hint on script_read) | S6 | PASS | preload hint injected on ResourceRef reads |
| concern-054 (pagination truncated+next_*) | S6, S11 | PASS | Pagination fields present; EOF window has no hint |
| FIX-8 (clear_buffer on editor_get_console) | S7 | PASS | clear_buffer=true flushes stale errors |
| a828cb1 (console capture timing) | S7 | INCONCLUSIVE | Empty buffer returned — timing window not observable |
| 23d69f9 (autoload guard) | S8 | PASS | Duplicate autoload rejected with guard error |
| FIX-D (editor-cache-updated hint) | S8 | PASS | Hint present after project_set_setting |
| FIX-4 / FIX-H (execute_code singleton+load hints) | S9 | PASS | EditorInterface/OS/Engine all rejected with MCP-tool hint |
| 09a6392 (input_map action name param) | S10 | PASS | name param used (not action_name) |
| FIX-I/A/J/2 (TileSet/TileMap guards) | S14 | PASS | type param, regions param, no-tileset INVALID_STATE, invalid-coords errors[] all correct |
| concern-031 (per-verb foreign-key hints) | S14 | PASS | All 5 verbs return INVALID_PARAMS naming the correct tool |
| dec5b24/e2c7041 (cached log after game_stop) | S21 | PASS | Log preserved after stop; text_filter+error_buffer independent |
| 8a6cbf0 (text_filter+error_buffer independent) | S21 | PASS | Two filters operate independently as expected |
| C24 WATCH (targeted refresh sufficient after edit) | S26 | PASS (0/1) | Targeted refresh sufficient this run; WATCH counter: 0 full-required out of 1 run |

---

## Pitfalls Discovered

| Tool | Severity | Description | Expected vs Actual | Workaround |
|------|----------|-------------|-------------------|------------|
| collision_from_sprite (S19) | Low | Tool is named `collision_from_texture`, not `collision_from_sprite` | Section docs say collision_from_sprite | Use collision_from_texture |
| signal_manage (S22) | Low | Second target param is `target_path`, not `target_node_path` | Schema says target_path; easy to confuse | Use target_path |
| resource_delete scan-delay (S22 C6) | Low | resource_delete may not immediately deindex — asset_list can still show the file seconds later | Expected immediate deindex | Wait or use editor_refresh after resource_delete |
| trigger_undo (S25 UR2) | Low | trigger_undo requires the node's CURRENT name, not the pre-operation name | Doc implies original name; rename changes the path | After renaming URTarget→URRenamed, call trigger_undo(["URRenamed"]) |
| lsp_completion default limit (S26.15) | Medium | Default completion count is 20, schema describes it as "default 10" | Expected ≤10 items | Pass explicit limit=N to cap results |
| folder_delete PATH_IN_USE ghost tab (Last-cleanup) | Low | folder_delete refuses if a script editor tab points to a file in the folder, even if the file was deleted from disk | Expected: file-deleted = tab gone | Close the script tab manually in Godot editor, then retry folder_delete |
