# MCP Tool Sweep v2 Results

- **Date:** 2026-06-29
- **Sweep:** 41n-bis Pass-3 cumulative validation
- **Godot version:** 4.5 (features `"4.5", "GL Compatibility"`)
- **Project type:** GDScript (0 .cs/.csproj found)
- **Main scene (original):** res://Main.tscn
- **Project name (original):** Godot MCP Toolkit
- **MCP server:** godot-mcp-toolkit (port 6550)
- **Status:** COMPLETE
- **Total:** 450 tests | 445 passed | 1 failed | 2 blocked | 2 skipped | + S23 section BLOCKED (C# on GDScript project)
- **Regressions:** 0 new. The single FAIL (26.15 lsp_completion default count=20 vs schema's documented 10) is a pre-existing schema/impl mismatch — the 2026-06-24 run failed it identically.
- **Blast radius (41n-bis) — all green:** discover_tools group activation + dominant-match (placeholders-only); dispatch/error envelopes (`<untrusted-…>` wraps on console/scene_tree/resource/hover/game_log; -32602 enum vs toolkit-code guards); LSP §41 (6 lsp_* tools + **I5 hover untrusted-wrap** + diagnostics valid/bad/shared-guard); extension hot-reload (create→edit→remove asserted on **refresh-response + discover_tools**, live on 4.5); screenshots (editor full+node, runtime live game).

---

## Section Results

| Section | Tests | Passed | Failed | Skipped | Notes |
|---------|-------|--------|--------|---------|-------|
| S0 — Environment Detection | 7 | 7 | 0 | 0 | Godot 4.5, GDScript, scene_close visible (4.5+ gated), group activation w/ schemas OK, console clean |
| S1 — Scaffolding | 10 | 10 | 0 | 0 | FIX-1 PASS (valid:true+diagnostics:[] inline on actor.gd); roots=main/sub (filename stem); material w/ shader subresource OK; console clean |
| S2 — Scene Tree & Node Creation | 19 | 19 | 0 | 0 | param=class_name (not node_type); unique_name(a46487b)✓; CLASS_MISMATCH(cb4e162)✓; scene_path(FIX-B)✓; transform pos=(50,75)(462506b)✓; batch all-success NO failed/hint(034D)✓; path-norm /root/main/Sv2Sprite✓; console clean |
| S3 — Node Properties & Methods | 34 | 34 | 0 | 0 | FIX-E(Resource)✓ c61d994(ResourceRef alias)✓ FIX-F(bare-res INVALID_VALUE+hint)✓ 462506b(LayerMask[1,3]→5)✓ FIX-7(batch results)✓ 034D(partial failed:1+hint / all-success absent)✓ concern-032(groups reject single+batch+invalid-path-edge→INVALID_PARAMS not NOT_FOUND)✓ 053(Packed read==write TAGGED dict)✓ control_set_layout(presets+margins+INVALID_PARAMS+INVALID_CLASS)✓; 3.19 get_info→null (non-@tool editor limit, hint); console: 1 expected callv error, no UndoRedo mismatch |
| S4 — Node Management | 16 | 16 | 0 | 0 | rename/reparent/reorder/duplicate✓; c61d994(dup bare {x,y}→Vector2 inferred→(200,300))✓; 462506b(entries batch)✓; 034D site-2 partial(failed:1+hint, results[1] error+no-status) / all-success(no failed/hint)✓; console clean |
| S5 — Signals | 7 | 7 | 0 | 0 | FIX-G node_path✓; connect→hit conn{flags:2 PERSIST,set_text,Sv2Label}✓; 5f96b62 method-hint(nonexistent→INVALID_PARAMS naming method+node_set_script hint)✓; disconnect→empty✓; 5.6 INVALID_PARAMS(method DNE); console clean |
| S6 — Script Operations | 9 | 9 | 0 | 0 | concern-054(full:truncated:false+total_lines:15 no cursor / range1-3:truncated:true+next_start_line:4+hint)✓; FIX-1(bad→valid:false+diag)✓; a46487b(preload→load() hint)✓; script_check valid/invalid✓; asset_list path_prefix→3 .gd files✓; deps→shader.gdshader✓; console: 7 expected parse errors (guard), no UndoRedo mismatch |
| S7 — Editor Operations & Console | 16 | 15 | 0 | 1 | screenshots(full PNG 2x2 + node PNG 1280x720)✓; 7.5 execute_code context=editor seed✓ (prior FAIL was missing param); FIX-8 clear_buffer✓; a828cb1 double-escape warning FIRES(\d→"use [0-9]")✓ [prior INCONCLUSIVE→now PASS]; 7.9 invalid-regex INVALID_PARAMS✓; refresh full/targeted(file_count=1)✓; wait_for_idle✓; BLOCKED 7.16 editor_get_errors (unregistered MCP tool — known catalog gap); console clean |
| S8 — Project Settings & Autoloads | 12 | 12 | 0 | 0 | name set/restore (conn survived rename)✓; 23d69f9 autoload-key guard(INVALID_PARAMS+hint)✓; FIX-D register→editor cache updated+immediately in list✓; layer_names set(3)/get/clear✓; invalid category→-32602 enum✓; console: 4 expected token-rotation lines, no UndoRedo mismatch |
| S9 — execute_code & Hints | 8 | 8 | 0 | 0 | 2+2→4✓; FIX-4 singleton hints(EditorInterface/OS/Engine/ProjectSettings all EXECUTE_FAILED+MCP-tool hint)✓; FIX-H/279efed load() hint(→node_set_property)✓; get_nodes_in_group→[]✓; 9.7 EXECUTE_FAILED(identifier err); context=editor throughout; console clean |
| S10 — Input Map | 4 | 4 | 0 | 0 | 09a6392 name param✓; action=add/remove, bind/unbind; event={type:key,keycode:Space→32}✓; console clean |
| S11 — Save System | 7 | 6 | 0 | 1 | params use `path` (not save_path); save round-trip(user-file envelope)✓; 11.5/11.6 PATH_DENIED(plugin internals)✓; concern-054 byte-paging(400/800 truncated+hint, final 200B truncated:false+no hint, EOF bytes=0)✓; BLOCKED 11.7.6 cap (project_set_setting refuses mcp_toolkit/*, no meta_set_limits MCP tool); console clean |
| S12 — ClassDB Introspection | 7 | 7 | 0 | 0 | search CharacterBody2D/3D✓; Sv2Actor found source:global✓; UNKNOWN_CLASS+hint✓; offset pagination(Node2D props_total=13 stable, offset=20→empty+truncated; search Control total=3)✓; console clean |
| S13 — Animation & AnimationTree | 12 | 12 | 0 | 0 | add_animation_library→OK(0); keyframe add×2(sv2_lib/idle, key_idx 0/1)+get_keys(2 keys)✓; animationtree set_root/add_node×2/add_transition×2/list(Start/End/idle/run+2 trans)✓; INVALID_CLASS on Sprite2D✓; console: 1 info audit line, no UndoRedo mismatch |
| S14 — TileSet & TileMap | 33 | 33 | 0 | 0 | FIX-I(create→16-tile TileSet)✓; setup_layers/add+remove source(id1)/add+remove alt(id1)✓; 3 NOT_FOUND guards✓; per-tile edits×5✓; FIX-2(invalid coords→errors[],tiles_modified:0)✓; concern-031 ALL 5 foreign-key→INVALID_PARAMS naming owning tool✓; tilemap_path(set)/node_path(read); FIX-A regions(5×5→24+1)✓; FIX-J no-tileset→INVALID_STATE✓; read round-trip(25 cells)✓; NOT_FOUND/INVALID_CLASS/missing-node_path guards✓; group activation tileset(6)/tileset_edit(5)/tilemap(2)✓; console: 1 expected bad-texture guard error |
| S15 — Theme, Audio, SpriteFrames | 12 | 12 | 0 | 0 | theme edit(2)+readback✓; invalid_type→-32602 enum✓; audiobus add/set(-6db)/effect(AudioEffectReverb)/list/Master-guard(INVALID_PARAMS)✓; spriteframes create(idle2/run4)/add(jump6fps)/list(3)/from_spritesheet(walk2)✓; console clean |
| S16 — 3D/Path2D/Nav/Particles/Procedural | 28 | 28 | 0 | 0 | 3d box/sphere/env(filmic)/light/camera + invalid_shape→-32602✓; path2d set(4)/add(5)/remove(4)/clear(0)+INVALID_CLASS✓; nav set/add/bake(polygon_count=1)/remove+INVALID_CLASS✓; particles ALL 8 presets(2d)+rain amount override+sparks 3d + 4d/lava→-32602 + NonExistent NOT_FOUND✓; procedural gradient(3→4)/curve(position shape)/noise(simplex)+invalid_noise→-32602✓; 13 nodes+3 res cleaned; console clean |
| S17 — Scene Inheritance & Query | 10 | 10 | 0 | 0 | scene_create_inherited(SlimeEnemy)+NOT_FOUND guard✓; scene_query class(Sv2Player)/name-glob(10 Sv2*)/properties(pos+visible)/root_path(2 under Sv2Player)✓; no-filter→INVALID_PARAMS✓; bad-root→NOT_FOUND✓; console clean |
| S18 — Phantom Tab Cleanup & File Ops | 16 | 16 | 0 | 0 | scene_close non-active(hint)/active-last✓; scene_delete active+non-active(tab_closed:true)✓; file_delete plain(no tab)+.tscn(tab_closed)✓; asset_import base64→CompressedTexture2D 64×64(after wait_for_idle; 5s warning is timing)✓; folder_delete 1-scene(tab_closed=inner)/2-scene(stale_tabs[2]+follow-up scene_close)✓; console: 2 folder.delete audit warnings, no UndoRedo mismatch |
| S19 — collision_from_sprite | 3 | 3 | 0 | 0 | tool is collision_from_texture (not collision_from_sprite); polygon_count=1 total_points=20✓; INVALID_CLASS on Node2D✓; console clean |
| S20 — Game Start, Runtime & Debugging | 22 | 21 | 0 | 1 | a28d17b wait_for_runtime:false→hint✓ [prior SKIP→now PASS]; runtime_screenshot(1152×648 live game)✓; get/set speed 100→200✓; /root/main (not Sv2Main); get_tree().current_scene.name→"main" (chaining ok)✓; anim play sv2_lib/idle✓; signal_emit runtime✓; input_simulate ui_accept✓; debugger_get_log filters([0-9]+ regex, check(braces) literal, (unclosed→INVALID_PARAMS)✓; SKIP 20.10 (no user autoload); editor console: 1 info line, no UndoRedo mismatch |
| S21 — game_start Guards & Crash Recovery | 13 | 13 | 0 | 0 | broken-script launches(success=true,runtime not connected)✓; 21.3b parse error in GAME_NOT_RUNNING hint(editor-console fallback)✓; dec5b24/e2c7041 cache+debug_state after stop✓ (NOTE: first immediate-after-stop call hit transient "registry not yet updated" race→GAME_NOT_RUNNING, self-resolves on retry — Low pitfall); 41l-quater-bis error_buffer{type:log_scan,source,function:_ready,line:6}✓; 8a6cbf0 error_buffer survives text_filter✓; no-param golden path✓; console: 3 expected broken-script parse errors + 3 game_stopped info, no UndoRedo mismatch |
| S22 — Combo Chains | 14 | 14 | 0 | 0 | C1 resource round-trip✓ C2 script pipeline✓ C3 scene build✓ C4 signal persists across save/reopen✓ C5 full game lifecycle(C5_LIFECYCLE_OK)✓ C6 tileset→paint pipeline✓ C7 indexed:true immediate check✓ C8 dup/rename/reparent/groups✓ C9 batch transforms(C9B rot=1.57)✓ C10 keyword+dominant-match(placeholders only)+selective-reset(FIX-C no split)✓ C11 targeted refresh✓ C12 folder_delete open tabs(no PATH_IN_USE)✓ C27 scene_close 4.5 gate✓ C28 anchor round-trip(1.0/0.5)✓; FINDINGS: (a) S19 collision node is root sibling not child—sprite-delete leaves it (cleaned); (b) C6 resource_delete reported deindexed:true but .tres stayed on disk (Windows/OneDrive lock on recently-referenced res), retry removed it; console: 2 expected audit/info lines |
| S23 — C# Compatibility | — | — | — | BLOCKED | Gate not met: GDScript-only project (S0: 0 .cs/.csproj, no dotnet). Non-.NET editor cannot compile C#. Section skipped per gate; no artifacts created. |
| S24 — Extension Discovery | 19 | 19 | 0 | 0 | **BLAST-RADIUS**: create→refresh registers (EXT-S2: 2 cmds on refresh response); E1/E2 discover_tools shows group+2 tools; E3 hello/add callable; E4 re-entrancy no-dupes; **E5 hot-reload LIVE on 4.5** (edit→refresh 3 cmds incl multiply via refresh+discover; remove→refresh commands:[] + ghost call graceful "No such tool" error); E6 keywords(math match/unrelated no); E7 covered by E5-remove (delete-while-loaded→graceful error); E8 annotations(readOnlyHint+timeout_ms:5000); E9 version-bounds(new_only 4.5 visible+callable / old_only 4.4 hidden); E10a hint-inject/E10b handler-override/E10c MCPToolkitError.require→INVALID_PARAMS+hint/E10d happy✓; (de)registration asserted on refresh-response+discover_tools per instruction; one transient refresh→discover propagation race (resolved on retry); console: 46 info hot-reload audit lines, no UndoRedo mismatch |
| S25 — Undo/Redo Verification | 48 | 48 | 0 | 0 | builder integration 8/8 (UR-S3); UR1 set_property(200,300↔0,0)✓ UR2 rename↔✓ UR3 groups-add↔✓ UR4 reorder(idx 11↔0)✓ UR5 duplicate↔(URDuplicate gone)✓ UR6 groups remove↔ + batch↔✓ UR7 delete_node↔(restored)✓ UR8 control layout(anchor 0.5→0)✓ UR9 signal connect↔/disconnect↔✓ UR10 path2d point(1→0)✓ UR11 particles↔(gone)✓ UR12 collision_from_texture↔(gone)✓; used trigger_undo/redo("")=scene history(id:28); **UR-CON regression gate CLEAR: ZERO UndoRedo history mismatch** (18 info audit lines only) |
| S26 — LSP Tools | 25 | 24 | 1 | 0 | **BLAST-RADIUS §41**: all 6 lsp_* tools work; diagnostics valid(0)/bad(7 errors 1-based)/shader(errors—LSP treats .gdshader as GDScript on 4.5, expected); shared guard(.cs/.cpp→UNSUPPORTED_FILE_TYPE, abs→INVALID_PATH, hover same); symbols(tree)/minimal(1)/shader(empty); **I5 hover untrusted-wrap CONFIRMED** (`<untrusted kind=hover source=godot-lsp>`: Node2D/float/take_damage sig/empty-no-crash); **FAIL 26.15 completion default count=20** (schema documents default 10 — known schema/impl mismatch, prior run also FAIL); 26.16 limit=3✓; definition(take_damage→11/damage_taken→6/Node2D→[]); references(damage_taken→2/health→3); C24 write→diagnose→fix(targeted refresh sufficient, WATCH 0/1); C25 symbols+def compose; 26.22/23 freshness✓; NOTE: def/ref paths are file:// URIs not res://-normalized (Low); OPT-1 connect-failure hint not testable (needs editor shutdown); console clean |
| S27 — Debugger Tools | 17 | 16 | 0 | 1 | debug_state(inactive)✓; set/list breakpoints cycle(line6+9→clear→empty)✓; guards(.cs/.txt→UNSUPPORTED_FILE_TYPE, abs→INVALID_PATH, nonexistent→NOT_FOUND, line0→">=1", line9999→"exceeds file length (11 lines)")✓; debug_continue no-game→GAME_NOT_RUNNING✓; SKIP 27.16(NOT_BREAKED not practical); **C26 live debugger: BP→start→hit(breaked:true)→continue→running(breaked:false)→stop→inactive**✓; console: 1 info line, clean |
| S28 — Placeholders & Spatial Map | 22 | 22 | 0 | 0 | spatial 2D full(SpatA overlaps SpatB not SpatC, nearest dist 20)/brief/region/radius(SpatC excluded)/max_nodes=1(truncated+hint)✓; guards verbose→-32602, region[1,2,3]→INVALID_PARAMS✓; 3D AABB(MeshInstance3D space:3d)✓; 28.8 dominant-match(only placeholders)✓; texture all 7 shapes(class:Texture2D,elapsed_ms:0,no-warning)✓; 4 colour formats✓; hollow/label/dim-cap(4096→1024)✓; if_exists(replace/return/fail→ALREADY_EXISTS)✓; texture guards(jpg→INVALID_PATH, ..→PATH_DENIED, transparent→INVALID_PARAMS, hexagon→-32602)✓; sound all 5 waveforms(AudioStreamWAV)✓; sweep(end_frequency:900)/decay✓; dur-cap 30→5✓; sound guards(mp3→INVALID_PATH, fmsynth→-32602, ..→PATH_DENIED)✓; cleanup 4 nodes+22 placeholder files; console: 2 expected audit warnings |

---

## Regression Watch Results (all PASS — 0 regressions)

| Fix Ref | Section | Status | Notes |
|---------|---------|--------|-------|
| FIX-1 (inline diagnostics on script_write) | S1, S6 | PASS | valid+diagnostics inline |
| cb4e162 (CLASS_MISMATCH) / a46487b (unique_name) | S2 | PASS | |
| FIX-B (scene_path) / 462506b (transform, LayerMask, entries) | S2,S3,S4 | PASS | |
| concern-034D (batch rollup failed/hint additive) | S2,S3,S4 | PASS | partial→failed+hint; all-success→absent; site-2 shape |
| FIX-E/F/7, c61d994 (ResourceRef), concern-032 (groups reject), concern-053 (Packed tagged read==write) | S3 | PASS | 032 edge: invalid-path+groups→INVALID_PARAMS not NOT_FOUND |
| FIX-G / 5f96b62 (signal node_path + method hint) | S5 | PASS | |
| concern-054 (script.read + save.read pagination) | S6, S11 | PASS | truncated+total+next cursor+hint |
| FIX-8 (clear_buffer) / a828cb1 (double-escape warning) | S7 | PASS | a828cb1 now FIRES (prior INCONCLUSIVE) |
| 23d69f9 (autoload-key guard) / FIX-D (editor cache) | S8 | PASS | |
| FIX-4 (singleton hints) / FIX-H+279efed (load hint) | S9 | PASS | |
| 09a6392 (input_map name param) | S10 | PASS | |
| FIX-I/A/J/2 (tileset/tilemap) / concern-031 (per-verb foreign key ×5) | S14 | PASS | |
| 4be3454/a28d17b (game_start guard + wait hint) | S20,S21 | PASS | a28d17b wait_for_runtime:false→hint (prior SKIP) |
| dec5b24/e2c7041 (cached log after stop) / 8a6cbf0 (error_buffer vs filter) / 41l-quater-bis (error_buffer/debug_state/log_scan) | S21 | PASS | NOTE transient post-stop "registry not yet updated" race, self-resolves on retry |
| FIX-C (discover_tools no split notifications) | S22 C10 | PASS | dominant-match: placeholder query→only placeholders |
| 41l extension API (success_hint, handler-override, MCPToolkitError, version-bounds, annotations) | S24 | PASS | hot-reload live on 4.5 |
| UndoRedo context_object (UR4–UR12) | S25 | PASS | **ZERO history mismatch** (regression gate CLEAR) |
| I5 (lsp_hover untrusted envelope) | S26 | PASS | `<untrusted kind=hover source=godot-lsp>` |

## Pitfalls / Findings

| Area | Severity | Description | Workaround |
|------|----------|-------------|------------|
| lsp_completion (26.15) | Medium | Default count=20; schema documents default 10 (schema/impl mismatch, persistent from prior run) | Pass explicit `limit=N` (26.16 limit=3 honored) |
| resource_delete (S22 C6) | Medium | Reported `deindexed:true` but the .tres remained on disk (Windows/OneDrive lock on a just-referenced resource); retry removed it | Retry resource_delete, or editor_refresh then retry |
| folder_delete phantom script tab (Last-cleanup) | Low | A deleted .gd's script-editor tab (c5_script.gd) still blocks folder_delete with PATH_IN_USE (no programmatic tab-close API) | Delete files individually; folder becomes empty (git ignores empty dirs); rmdir husk |
| debugger_get_log post-stop race (21.5) | Low | First debugger_get_log immediately after game_stop can return GAME_NOT_RUNNING ("registry not yet updated"); cache fallback serves on next call | Retry once |
| collision_from_texture node placement (S19/S22) | Low | Creates `<sprite>_collision` as a root **sibling**, not a child — deleting the sprite leaves it | Delete the `_collision` node separately |
| lsp_definition/references paths (S26) | Low | Returns `file://` URIs, not res://-normalized | Cosmetic; line targeting correct |
| collision_from_texture / control_set_layout tool names | Low | Section docs say collision_from_sprite / project_*_layer_names; actual: collision_from_texture / layer_names_set/get | Use actual names |

## Notes
- **Tool-param drift confirmed (docs stale, tools correct):** `class_name` (not node_type), `tilemap_path` (set) vs `node_path` (read), `player_path`/`animation_name`/`track_path` (animation), `name` (input_map), `path` (save_*), `as_name`/`transform` (scene_instantiate single).
- **scene roots derive from filename stem** (main.tscn → root "main", not "Sv2Main"); runtime paths `/root/main/...`.
- **S23 (C#)** BLOCKED per gate — GDScript-only project, non-.NET editor.
- **Cleanup:** all res://sv2_validation artifacts removed (folder gone). git status shows only `M Validations/RESULTS.md` (this report) + `M project.godot` (Godot window-layout churn, no stray settings — name/main_scene/layers all restored).
