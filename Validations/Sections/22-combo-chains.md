# Section 22 — Combo Chains

**Dependencies:** Section 1 (sv2_validation/ exists, Sv2Main.tscn with nodes)
**Tools tested:** Multi-tool workflows testing interoperability
**Tests:** 14 chains (each self-contained with own setup and cleanup)

---

## C1. Resource round-trip

`resource_write` (res://sv2_validation/c1_env.tres, type=Environment) → `resource_load` (verify class=Environment) → `resource_delete`
- **Expect:** write, load, verify, delete all succeed

## C2. Script validation pipeline

`script_write` (res://sv2_validation/c2_script.gd, content=`extends Node\nfunc hello(): pass`) → `script_check` (verify valid=true) → `script_delete`
- **Expect:** write succeeds with diagnostics, check passes, delete works

## C3. Scene build round-trip

`scene_create` (res://sv2_validation/c3_scene.tscn, Node2D) → `scene_open` → `scene_create_node` (Sprite2D, "C3Sprite") → `node_set_property` (position={100,200}) → `node_get_property` (verify 100,200) → `editor_save_scene` → `scene_open` Sv2Main.tscn → `scene_delete` c3_scene.tscn
- **Expect:** full create-edit-save-close cycle works

## C4. Signal persistence round-trip

`signal_manage` connect Sv2Player.hit → Sv2Label.set_text → `editor_save_scene` → `scene_open` sub.tscn (switch away) → `scene_open` Sv2Main.tscn (switch back) → `signal_list` include_connections=true → verify connection persisted → `signal_manage` disconnect
- **Expect:** signal connection survives save/reopen

## C5. Full game lifecycle

`scene_create` (res://sv2_validation/c5_game.tscn, Node2D, "C5Root") → `scene_open` → `scene_create_node` (Node2D, "C5Node") → `script_write` (res://sv2_validation/c5_script.gd, content with `print("C5_LIFECYCLE_OK")`) → `node_set_script` C5Node → `editor_save_scene` → `project_set_setting` main_scene=c5_game.tscn → `game_start` → wait 2s → `runtime_get_node_state` /root/C5Root/C5Node → `debugger_get_log` text_filter=C5_LIFECYCLE → `game_stop` → cleanup (restore main_scene, `scene_open` Sv2Main.tscn, `scene_delete` c5_game.tscn, `script_delete` c5_script.gd)
- **Expect:** complete build-run-inspect cycle

## C6. TileMap painting pipeline

`tileset_create` (res://sv2_validation/c6_ts.tres, texture_path=res://icon.svg, tile_size={32,32}, physics=true) → `tileset_setup_layers` (terrain_sets=[{mode:"match_corners_and_sides", terrains:["grass"]}]) → `scene_create_node` (TileMapLayer [4.3+] or TileMap [4.2], "C6Tile") → `node_set_property` (tile_set={"type":"Resource","path":"res://sv2_validation/c6_ts.tres"}) → `tilemap_set_cells` (tilemap_path=`C6Tile`, regions=[{x:0,y:0,width:3,height:3,source_id:0,atlas_x:0,atlas_y:0}]) → cleanup (`scene_delete_node` C6Tile, `resource_delete` c6_ts.tres)
- **Expect:** create→configure→paint pipeline works. **The terrain-set configuration tool is `tileset_setup_layers`** (not `tileset_edit`, which does not exist as a single tool — the per-tile editing surface is the 5-way-split `tileset_edit_*` family; see Section 14).
- **Known index-staleness caveat (Low, non-blocking):** after `resource_delete` on `c6_ts.tres`, `asset_list`/`resource_load` may keep serving a stale/in-memory-cached view of the file until a 2nd `resource_delete` + a full `editor_refresh(mode=full)` — see the Last-cleanup note. Confirm true deletion via the C6 leftover check in Last-cleanup rather than a single `resource_delete` response alone.

## C7. Script write → immediate check (targeted filesystem)

`script_write` (res://sv2_validation/c7_fs.gd, valid GDScript) → verify `indexed:true` in response → `script_check` (same path, NO `editor_refresh` between) → `script_delete`
- **Expect:** script_check passes immediately without editor_refresh

## C8. Node management pipeline

`scene_create` (res://sv2_validation/c8_nm.tscn, Node2D, "C8Root") → `scene_open` → `scene_create_node` (Sprite2D, "NM") → `node_manage` (duplicate, new_name="NMCopy") → `node_manage` (rename NMCopy → NMRenamed) → `node_manage` (reparent NMRenamed under NM) → `node_groups` (add, groups=["c8_test"]) → `node_groups` (list, verify c8_test) → `node_groups` (remove) → `editor_save_scene` → `scene_open` Sv2Main.tscn → `scene_delete` c8_nm.tscn
- **Expect:** full duplicate→rename→reparent→groups cycle

## C9. Batch instantiate with transforms

`scene_instantiate` batch — scene_path=res://sv2_validation/sub.tscn, instances=[{name:"C9A",position:{x:0,y:0}},{name:"C9B",position:{x:100,y:0},rotation:1.57},{name:"C9C",position:{x:200,y:0},scale:{x:0.5,y:0.5}}] → `scene_get_tree` (verify all 3) → `node_get_property` C9B rotation (verify ≈1.57) → cleanup (`scene_delete_node` C9A, C9B, C9C)
- **Expect:** batch with distinct transforms applied correctly

## C10. discover_tools & keyword search (standard mode)

Run discover_tools queries:
1. request="animation" → animation_authoring activated
2. request="tilemap" → tilemap activated
3. request="rename node" → no on-demand group match (node_manage/node_groups are CORE; verified working in C8 without activation) — CORRECT, not a failure
4. request="signal" → signals activated
5. request="input" → input_map activated
6. request="screenshot" → editor_advanced + core_matches
7. reset=true → all deactivated
8. (no params) → full catalog, all "available"
9. groups=["tilemap","audio"] → re-activate two
10. reset=["tilemap"] (array form) → only tilemap deactivated, audio remains
11. (no params) → verify tilemap="available", audio="already_loaded"
12. reset=true → final cleanup

> **REGRESSION WATCH (FIX-C, 7e63aee):** If discover_tools batch activation causes
> split notifications (tools temporarily unavailable between calls), FIX-C has
> regressed. Manifests as "tool not found" immediately after activation.
> Flag as **Major** — canary only, not deterministically reproducible.

> **CANARY (Pitfall 3):** discover_tools activates server-side, but Claude Code's
> deferred-tools caching may delay availability. PLATFORM limitation (not toolkit).
> If tools aren't callable immediately, retry once — do NOT record as toolkit FAIL.

> **CANARY (Pitfall 6):** Stale tool index after group activation — if a newly
> activated tool returns "not found," use two-step escalation (retry discover_tools
> → reset+reactivate). PLATFORM limitation, not toolkit regression.

## C11. editor_refresh targeted mode

`script_write` (res://sv2_validation/c11_targeted.gd, valid GDScript) → `editor_refresh` (file_paths=[res://sv2_validation/c11_targeted.gd]) → verify response mode="targeted", file_count=1 → `script_delete`
- **Expect:** targeted refresh works, returns mode field

## C12. folder_delete with open scene tabs

`folder_create` (res://sv2_validation/c12_tabs/) → `scene_create` (res://sv2_validation/c12_tabs/tabA.tscn) → `scene_create` (res://sv2_validation/c12_tabs/tabB.tscn) → `scene_open` tabA → `scene_open` tabB → `scene_open` Sv2Main.tscn (ensure outside scene active) → `folder_delete` (res://sv2_validation/c12_tabs/, recursive=true)
- **Expect:** no PATH_IN_USE errors, folder deleted successfully

## C27. Version-gate tool visibility (41l-undecies)

1. `project_get_settings` — extract Godot version from `application/config/features`
2. `discover_tools` (no params) — get full tool catalog
3. Check `scene.close` visibility:
   - If Godot ≥ 4.5: `scene.close` MUST appear in catalog
   - If Godot < 4.5: `scene.close` MUST NOT appear
4. If Godot ≥ 4.5: call `scene_close` on a non-active tab → **Expect:** success
5. If Godot < 4.5: call `scene_close` → **Expect:** UNSUPPORTED error mentioning "4.5+"
- **Expect:** Tool visibility matches Godot version, no phantom tools

## C28. control.set_layout round-trip (41l — W1 Lane 2)

`scene_create` (res://sv2_validation/c28_layout.tscn, Control, "C28Root") → `scene_open` → `scene_create_node` (Button, "C28Btn", parent=".") → `control_set_layout` (node_path="C28Btn", preset="PRESET_FULL_RECT") → `node_get_property` (C28Btn, "anchor_right") → verify anchor_right=1.0 → `control_set_layout` (node_path="C28Btn", preset="PRESET_CENTER", resize_mode="keep_size") → `node_get_property` (C28Btn, "anchor_left") → verify anchor_left=0.5 → `scene_open` Sv2Main.tscn → `scene_delete` c28_layout.tscn
- **Expect:** Layout presets correctly set anchors and readback confirms

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

Each chain cleans up after itself. After all chains, verify no leftover artifacts:
`editor_refresh` (full — no `file_paths`) FIRST — `asset_list`'s EditorFileSystem-backed view lags `resource_delete`'s deindex, so a refresh is needed before the `c*` check to avoid a false "leftover".
`asset_list` path_prefix=`res://sv2_validation/`, name_glob=`c*` → **Expect:** no matches
