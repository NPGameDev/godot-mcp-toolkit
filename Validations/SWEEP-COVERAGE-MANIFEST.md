# Sweep Coverage Manifest

**Last updated:** 2026-07-13 (41o-quater-bis — surgical `script.edit` handler added (§6 6.10–6.16): happy-path single replace, NOT_FOUND, NOT_UNIQUE, replace_all newline-adjacency, empty-`new_string` span delete, no-op / empty-`old_string` INVALID_PARAMS. Prior (41o-terdecies close-out): animationtree_edit add_node `nodes_count` version-gated omission + `note` on 4.2-4.4 (§13 13.6/13.7); execute_code load()-hint both-remedies + parse-error framing (§09 9.4/9.7))
**Toolkit commit:** T:2e2e6d9
**Total tools (agent-facing):** 112 + 2 meta — canonical count in server
`src/registration/catalogue.ts` (`--tools-count`).
**Toolkit surfaces (non-disjoint — do not sum):** 101 editor-registered (incl. the 4 `debug.*`) ·
12 runtime (4 names overlap the editor 101) · 7 LSP (server-side only).
**Sweep scale:** per-section defined-case counts in the `tool-sweep.md` index; last full-run tally in
`RESULTS.md` (479 tests · 2026-07-03 · Godot 4.7). **Combo chains: 18** (C1–C12 & C27–C28 in §22;
C24–C26 & C29 in §§26–27).

---

## Version-Parity Invariant (hand-maintained — D-#1)

> A version-gated built-in needs BOTH a toolkit gate (`.with_min_godot_version`)
> AND a matching server-catalogue bound (`ToolDef.godotMinVersion`). The **server
> bound is authoritative for the `UNSUPPORTED` error message** (`"… (connected:
> <maj>.<min>)"`); the toolkit's own version-block branch
> (`transport/mcp_toolkit_command_registry.gd`) mirrors that wording. No automated
> cross-repo parity check ships for 1.0 — keep the two version tables in sync **by
> hand** whenever you add or change a version-gated built-in. Currently exactly
> one: `scene.close` (server `scene_close`) @ 4.5+. Automated guard deferred to
> PostRelease.

---

## Tool → Sweep Test Matrix

### Scene Management (11 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| scene.create | 7, 8, 17.1, 17.1b | — | C3, C5, C8 | — | — | 17.1/17.1b: root_name override + stem default |
| scene.open | 18, 64a, 64d, 64f | — | C3, C7, C8 | — | — | |
| scene.close | 18.3, 18.14, 64b, 64f | ✓ (non-active, last tab) | C3, C7, C27 | ✓ (_set_main_scene_state hint) | — | 4.5+ only (version-gated via min_godot_version). Response discloses `unsaved_changes_discarded: <bool>` on 4.7+ (omitted below 4.7) |
| scene.delete | 18.4, 18.6, 64c, 64e | ✓ (active tab, non-active tab) | C3 | ✓ (tab_closed, phantom warning) | — | |
| scene.create_node | 20–26, 2.13a, 64h | ✓ (2.12: CLASS_MISMATCH; 2.13a: bad-form inline props → `properties_set:0` + `properties_failed` names texture+scale) | C5, C8, C10 | ✓ (preload, unique_name; 2.13a: drop `error` mirrors node.set_property incl. bare-res:// steer) | FIX-G (P6), cb4e162, 41o-duodecies-ter F2 | 2.13a: inline `properties` are readback-verified per key — a silently-dropped `Object.set()` write (bare-string texture, bare-array scale) is reported in `properties_failed` and excluded from `properties_set` (parity with node.set_property; adjusted writes surface in `warnings[]`). Headless unit `scene.create_node inline-property drop` pins the same classifier. **GAP:** unique_name param untested |
| scene.delete_node | 43j, 43s, 64i | — | — | — | — | |
| scene.instantiate | 41, 43q–43s, 2.15, 2.15a | — | C9, C9b | — | FIX-B, FIX-9, FIX-K, concern 034 | 2.15a: all-success batch → `failed`/`hint` ABSENT (additive rollup, summarize_batch). Whole-entry failure (`instantiate()==null`) is unit-pinned (`_test_summarize_batch`) — not selectively triggerable from a valid .tscn. C9: tagged-Vector2 batch transforms apply. C9b: bare untagged `{x,y}` transform → `property_errors` (not a silent drop); single-mode rejects the same with `INVALID_PARAMS` (2.15 note). **GAP:** properties param, auto-rename |
| scene.diff | 63 | — | — | — | — | |
| scene.create_inherited | 80a–80d | ✓ (NOT_FOUND) | — | — | — | |
| scene.query | 17.5–17.8, 17.11–17.18 | ✓ (17.9 no filters, 17.10 NOT_FOUND) | — | ✓ (17.11 paging hint, 17.17 clamp hint) | — | 17.11–17.18: self-describing pagination envelope — `returned` (was `count`), `has_more` (was `truncated`), always-present `total_matches`, `next_offset`+`hint` only while `has_more`. Invariants: `total_matches` constant across pages · Σ`returned` == `total_matches` · pages disjoint · union == full match set · determinism (two identical calls → byte-identical page). Plus past-end (17.15 empty/`has_more:false`), offset floor (17.16 `maxi(0,·)`), `MAX_LIMIT=200` clamp+disclose (17.17 `limit_clamped`), no-match (17.18 `total_matches:0`) | |
| scene.get_tree | 19, 43, 43e, 43r | — | C8 | — | — | |

### Node Property & Method (9 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| node.get_property | 28, 31, 33, 36, 43b, 43i, 64g, 3.20b | — | C3, C6 | — | concern 053 | 3.20b: Packed read-back is the TAGGED dict (not var_to_str) + read==write (concern 053, T:8856546) |
| node.set_property | 27, 29, 30, 32, 34, 35, 3.2b, 3.2c, 3.2d, 3.20b, 3.14c, 3.14d, 3.29 | ✓ (3.14a: groups single-reject, 3.14b: groups batch per-entry reject; **3.2b: cross-family wrong-type → SET_FAILED; 3.2c: convertible value → ADJUSTED success+warning, 41o C1/D1**) | C3, C6 | ✓ (3.14a/3.14b: hint → node.groups; 3.2c: adjusted `warning`; 3.2d: readback-null → attach-script-first hint) | FIX-5, FIX-7, FIX-E, FIX-F, concern 032, concern 053, concern 034, 41o C1/D1, 41o-quater run-1 | groups property steered to node.groups (single whole-reject + batch per-entry); 3.2b/3.2c: tri-state set outcome — a CROSS-family wrong-type (String/Color on Vector2) returns SET_FAILED, while an in-family convertible value (float→int z_index 2.9→2) is ACCEPTED with a `warning` naming the reshape, not a false success (headless units `wrong-type set rejection` + `describe_set_drop tri-state` pin the same `contract/property_set_check.gd` detector). 3.2d: readback-null drop — set() no-ops and the readback stays null → the hint leads with the unattached-script cause (a script-defined property set before its script is attached), then mistyped-name / dedicated-API. 3.20b sets a top-level PackedVector2Array (Line2D.points) for the 053 read-back round-trip. 3.14c/3.14d: batch partial-failure rollup — 3.14c asserts top-level `failed`(int, `int(...)`-coerced)+`hint` on a one-bad-entry batch; 3.14d asserts both ABSENT on all-success (summarize_batch, additive). 3.29: root rename via `name` (agrees with node.manage 4.17). **GAP:** LayerMask coercion, bare res:// guard |
| node.get_property_list | 38–40 | — | C5 | — | — | |
| node.call_method | 49, 50 | — | C9 | ✓ (CS3: C# hint) | — | |
| node.set_script | 37 | — | C5, C8 | — | — | |
| node.manage | 43a–43j, 4.17–4.18 | ✓ (43h2: properties; 4.17: root reparent/reorder/duplicate stay INVALID_PATH) | — | — | FIX-K | 4.17–4.18: root RENAME allowed (guard relaxed, 41n-undecies H — agrees with node.set_property `name`, 3.29); headless units pin root rename + kept structural guards |
| node.groups | 43k–43l, 4.12–4.16 | — | — | — | 462506b, concern 034 | 4.12/4.14: batch add/remove happy path; 4.15/4.16: batch partial-failure rollup — 4.15 asserts top-level `failed`(int)+`hint` via the shape-tolerant predicate on site-2's `{status?, error?}` (no-`success`) entries; 4.16 asserts both ABSENT on all-success (summarize_batch, additive) |
| collision_from_texture | 19.1, 19.2, §25 UR12 | ✓ (19.3: INVALID_CLASS) | — | — | — | `parent_path` param (renamed from `target_parent`) |
| control.set_layout | 3.24–3.26 | ✓ (3.27: invalid preset, 3.28: wrong class) | C28 | — | 4d7e432 | W1 Lane 2 |

### Script Management (5 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| script.read | 15, 16, 6.2, 6.2b | — | — | ✓ (6.2 has_more `hint`) | concern 054; ledger #20 | 6.2/6.2b: uniform pagination contract — every success carries `has_more`+`total_lines`+`returned` (this window's line count, added ledger #20); a windowed read before EOF adds `next_start_line` (1-based = end_line+1) + a prose `hint`; full read / window-at-EOF = `has_more:false`, no hint. Mirrors save.read SHAPE in line units. ledger #20 renamed `truncated`→`has_more` + added `returned`. |
| script.write | 2, 3 | — | C2, C5, C11 | ✓ (6.5: preload hint) | FIX-1 | **GAP:** diagnostics fields in response |
| script.edit | 6.11 (happy: replacements=1 + undoable/indexed/valid), 6.14 (replace_all replacements=2 newline-adjacency), 6.15 (empty new_string span delete) | 6.12 (NOT_FOUND absent), 6.13 (NOT_UNIQUE ambiguous), 6.16a (INVALID_PARAMS no-op), 6.16b (INVALID_PARAMS empty old_string) | — | ✓ (6.12 NOT_FOUND re-read hint; 6.13 NOT_UNIQUE context/replace_all hint) | 41o-quater-bis | eager; surgical MCP analogue of native Edit. Reuses `script.write`'s write/undo/index/diagnose pipeline (`_commit_content`) → identical envelope + `replacements`. `NOT_UNIQUE` is new to `MCPToolkitError.CODES` (57 total). |
| script.delete | — | — | C2 | — | — | Only in combos |
| script.check | 17 | — | C2, C11 | — | — | |

### Editor Core (7 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| editor.save_scene | 55, 64 | — | C3, C5, C7, C8, C9 | — | — | |
| editor.screenshot | 7.2, 7.2b, 7.2c, 7.2d, 7.2e, 7.2f, 7.2g, 7.2h, 7.2i, 7.2j, 7.2k | ✓ (7.2d: EDITOR_VIEWPORT_UNAVAILABLE minimized; 7.2k: image_detail=huge → INVALID_PARAMS) | — | ✓ (7.2d minimized hint; 7.2e foregrounded_editor; 7.2i oversize→disk hint) | — | 7.2b: wrong-screen auto-heal → `remediation:["switched_main_screen"]`; 7.2c: node-focused heal (Node2D→2D, Node3D→3D); 7.2e: `force_foreground_editor:true` un-minimizes + `remediation` foregrounded_editor; 7.2f: unfocused-but-visible → fresh frame (cause-C regression); 7.2g: `image_response_mode:"disk"` → lean envelope (no `image_base64`, file on disk); 7.2h: `"both"` → image + globalized `path`; 7.2i: oversize 3D-node inline → `RESPONSE_TOO_LARGE` whose hint names `image_response_mode:"disk"` → disk retry succeeds (the F1 escape-hatch proof); 7.2j/7.2k: `image_detail` `full`/`mid`(≤1024)/`low`(≤512) inline cap — proportional + aspect-preserving + shrink-only, echoes `image_detail`+`returned` "WxH"; bad value → INVALID_PARAMS (41o-quater-ter). **`size` param retired** (was node-focus exact-WxH; superseded by `image_detail`'s proportional cap — node framing stays `node_path`'s job) |
| editor.refresh | 61 | — | — | — | 5f96b62 | Renamed from reload_scripts |
| editor.get_console | 58, 58a–58h, 7.6–7.8, 7.10, 7.12 | ✓ (58d: invalid regex) | — | — | FIX-8 | **GAP:** clear_buffer param; ledger #20 (supersedes #9): total_lines/next_id/has_more (was truncated) + returned (was count) — §07 7.6–7.12 assert `returned` as the matching-line count. LOG_BUSY/LOG_UNAVAILABLE hints version-gated (4.5+ buffer-steer only) — §07 REGRESSION WATCH note + server smoke §14 own the truth-table (41n-undecies-bis-bis) |
| editor.wait_for_idle | 60 | — | — | — | — | |
| execute.code | 58a_seed, 77, 9.4, 9.7 | — | — | ✓ (9.4 load() hint; 9.7 parse framing) | FIX-4, FIX-H, 279efed | 9.4: load()-failure hint now offers BOTH remedies (node_set_property for resource assignment AND the @tool-script workflow) regardless of target type; the `.gd` suffix only orders which leads. 9.7: PARSE_ERROR reframed to carry the raw parser text + the expression-only constraint + a steer. **GAP:** singleton hint |
| editor.set_lsp_status | — | — | — | — | — | Internal (MCP server → plugin LSP-status push; dock-only publisher); not agent-facing — 7th registration in `commands/editor/editor_commands.gd` |

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
| asset.list | 12, 6.7, 6.9 | ✓ (6.9 over-max limit clamp; ≤0 reject) | — | ✓ (6.9 limit_clamped clamp clause) | ledger #20 | ledger #20 (supersedes #9): total_assets/has_more (was truncated) + returned (was count), cursor-less. 6.9: over-max `limit` (>2000) CLAMPs + `limit_clamped` (was INVALID_PARAMS — D8 flagged behavior change); ≤0 still rejects. |
| asset.get_dependencies | 13, 6.8 | — | — | — | ledger #20 | ledger #20 (supersedes #9): total_dependencies/has_more (was truncated) + returned (was count), cursor-less. |
| asset.import | 42, 42b | — | — | — | — | |

### Resource Management (3 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| resource.load | 14, 54a-verify, 54k-verify | — | C1, C12 | — | — | |
| resource.write | 4, 5, 6 | — | C1, C12 | — | — | |
| resource.delete | — | — | C1, C12 | — | — | Only in combos |

### File Operations (1 tool)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| file.delete | 18.7, 18.11 | — | — | ✓ (tab_closed for .tscn) | — | 18.11: .tscn tab close |

### Folder Management (2 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| folder.create | 1 | — | — | — | — | |
| folder.delete | 18.12, 18.13 | — | — | ✓ (tab_closed, stale_tabs) | — | 18.12: 1 scene, 18.13: 2 scenes + follow-up |

### ClassDB Introspection (2 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| classdb.get_info | 10, 12.5, 12.6, 12.11 | ✓ (12.11 limit=0 → INVALID_PARAMS) | — | ✓ (has_more hint; limit clamp clause) | 45975fc; ledger #20 | Offset pagination (W1); ledger #20 (supersedes #9): total_<section> (was *_total)/has_more (was truncated)/next_offset + returned (was count). **D11 caller `limit`** (default 200, per-section; clamp>200+`limit_clamped`; <1 reject) — 12.11. |
| classdb.search | 9, 12.7, 12.8, 12.9, 12.10 | ✓ (12.10 limit=0 → INVALID_PARAMS) | — | ✓ (has_more hint; limit clamp clause) | 45975fc; ledger #20 | Offset pagination (W1); ledger #20 (supersedes #9): total_classes (was total)/next_offset/has_more (was truncated)/returned (was count). **D11 caller `limit`** (default 200; sub-max shrinks page [12.8]; clamp>200+`limit_clamped` [12.9]; <1 reject [12.10]). |

### Signal Management (3 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| signal.list | 44, 46, 48 | — | C7 | — | — | |
| signal.manage | 45, 47, 5.2, 5.5 | — | C7 | ✓ (method hint) | FIX-G, 5f96b62 | Success payload key `source_path`→`node_path` (connect + disconnect), aligning output with the FIX-G input rename — asserted at 5.2/5.5. **GAP:** 3-case method hint validation |
| signal.emit | 79 | — | — | — | — | Runtime only |

### Input Map (2 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| input_map.action | 65 | — | — | — | 09a6392 | Param renamed: action_name → name |
| input_map.event | 66 | — | — | — | — | |

### Save System (4 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| save.write | 67 | — | — | — | — | |
| save.read | 68, 11.7 | ✓ (11.5 PATH_DENIED, 11.7.6 cap exceeded) | — | ✓ (11.7 has_more `hint`) | concern 025, 054; ledger #20 | 11.7: byte `offset` paging (`offset`/`next_offset`/`total_bytes`/`has_more`/`returned`) + configurable `save_read_cap_kb` (default 256, min 64) + FILE_TOO_LARGE frame guard (base64 1.33× vs `ws_buffer_kb`). ledger #20 renamed `truncated`→`has_more` + `bytes_returned`→`returned`: a `has_more` window carries a prose `hint` naming `next_offset`; absent once `has_more` is false (uniform pagination contract, shared SHAPE with script.read). |
| save.list | 69 | — | — | — | — | |
| save.delete | 70 | — | — | — | — | |

### Playtest / Game Control (3 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| game.start | 71 | ✓ (`target:"main"` NO_SCENE pre-guard, 41o — unit `game.start main-scene pre-guard`; interactive-only: needs `application/run/main_scene` UNSET, which the dogfood never is) | C8 | — | 4be3454, a28d17b, 41o | `target:"main"` with no main scene set returns `NO_SCENE` (not a false success + engine modal); predicate `_main_scene_missing()` is headless-unit-pinned. **GAP:** compilation failure guard, wait_for_runtime hint |
| game.stop | 81 | — | C8 | — | — | |
| debugger.get_log | 75, 75a–75f, 80, 80a–80f, 20.13–20.15a | ✓ (75d: invalid regex) | — | — | dec5b24, a828cb1; ledger #20 | **GAP:** double-escape warning. 80a–80f: debug_state + error_buffer (41l-quater-bis). ledger #20 (supersedes #9): total_lines/has_more (was truncated) + returned (was count), capped tail; 20.13–20.15 assert `returned` as the matching-line count; 20.15a: file source under a `text_filter` filters-then-slices, uniform with buffer (41n-ter-bis #7a — supersedes the file-path capped-tail `has_more=start>0`); LOG_BUSY hint version-gated via shared MCPToolkitError.log_busy_hint (41n-undecies-bis-bis) |

### Animation (4 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| animation.keyframe | 51, 52 | — | C9 | — | — | |
| animation.get_keys | 53 | — | C9 | — | — | |
| animationtree.edit | 13.5–13.9 | — | — | ✓ (13.6/13.7 version-aware `nodes_count`) | — | 5 mutating sub-ops; `list` extracted to `animationtree.list` (ledger #3 CQS split). 13.6/13.7 add_node: `nodes_count` present + accurate on 4.5+; **omitted on 4.2-4.4** (no `get_node_list`) with a `note` — never a fabricated 0 that would read as a failed add. _Test IDs reconciled to current `Sections/13` scheme (were stale `54m–54s`)._ |
| animationtree.list | 13.10 | ✓ (13.11: INVALID_CLASS) | — | — | — | Read-only structure list (extracted from `animationtree.edit`, ledger #3) |

### TileMap (2 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| tilemap.set_cells | 14.18–14.19 | ✓ (14.20: no-tileset) | C10 | — | FIX-A, FIX-J | |
| tilemap.read_cells | 14.21–14.22 | ✓ (14.23: NOT_FOUND, 14.24: wrong class, 14.25: missing param) | — | — | c7f56c8; ledger #20 | read-only; ledger #20 (supersedes #9): total_cells (was cells_total)/has_more (was truncated) + returned (was cell_count); cursor-less (bounds nav aid) |

### TileSet — structural (6 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| tileset.create | 14.1–14.2 | ✓ (14.8: NOT_FOUND) | — | — | FIX-I | |
| tileset.setup_layers | 14.3 | — | — | — | — | |
| tileset.add_source | 14.4 | — | — | — | — | |
| tileset.remove_source | 14.5 | ✓ (14.9: NOT_FOUND) | — | — | — | destructiveHint |
| tileset.add_alternative | 14.6 | — | — | — | — | |
| tileset.remove_alternative | 14.7 | ✓ (14.10: NOT_FOUND) | — | — | — | destructiveHint |

### TileSet — per-tile editing (5 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| tileset.edit_physics | 14.11 | ✓ (14.16: invalid coords, 14.17: missing file, 14.29: foreign key → edit_terrain) | — | ✓ (14.29: hint names owning tool) | concern 031 | per-verb key allow-list |
| tileset.edit_terrain | 14.12 | ✓ (14.30: foreign key → edit_physics) | — | ✓ (14.30) | concern 031 | per-verb key allow-list |
| tileset.edit_navigation | 14.13 | ✓ (14.31: foreign key → edit_visuals) | — | ✓ (14.31) | concern 031 | per-verb key allow-list |
| tileset.edit_visuals | 14.14 | ✓ (14.32: foreign key → edit_custom_data) | — | ✓ (14.32) | FIX-2, concern 031 | bundles occlusion+animation+probability |
| tileset.edit_custom_data | 14.15 | ✓ (14.33: foreign key → edit_navigation) | — | ✓ (14.33) | concern 031 | per-verb key allow-list |

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

### Audio Bus (2 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| audiobus.edit | 15.4–15.6, 15.8 | ✓ (15.8: Master removal) | — | — | — | Mutating sub-ops; `list` extracted to `audiobus.list` (ledger #3 CQS split). _Test IDs reconciled to current `Sections/15` scheme (were stale `81a–81g`)._ |
| audiobus.list | 15.7 | — | — | ✓ (envelope) | — | Read-only bus-layout snapshot (extracted from `audiobus.edit`, ledger #3). `buses` wrapped in the untrusted envelope (`kind="audiobus"`), parity with `resource.load`/`save.read`; `bus_count` stays an unwrapped scalar |

### Navigation (1 tool)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| navigation_edit | 16.12–16.15, §25 UR13 | ✓ (16.16: INVALID_CLASS) | — | — | — | Undo/redo regression watch in §25 UR13 (polygon mutations register undo; bake stays direct) |

### Particle System (1 tool)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| particles.create | 16.17–16.20 | ✓ (16.21–16.23: guards) | — | — | — | |

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
| spriteframes.create | 15.9 | ✓ (15.13: NOT_FOUND texture, 15.14: INVALID_PATH) | — | — | — | |
| spriteframes.edit | 15.10, 15.11 | — | — | — | — | |
| spriteframes.from_spritesheet | 15.12 | — | — | — | — | |

### Meta / Transport (3 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| meta.set_limits | — | — | — | — | — | Internal (server→plugin); not agent-facing |
| discover_tools | C10 (12 steps), 28.8 | ✓ (reset, selective reset) | — | — | FIX-3, FIX-C | **dominant-match (Item C, 41m-sexies):** a vague multi-word query activates only the dominant group (28.8: "placeholder texture sprite sound" → only `placeholders`); server smoke §39 asserts prune + recall |
| extensions.refresh | E5 | — | — | — | — | Extension phase |
| *(extension API)* | E10a–E10d | E10c (guard) | — | E10a, E10b (hints) | — | success_hint + MCPToolkitError (41l-vicies-ter) |

### LSP Tools (7 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| lsp_diagnostics | 26.1–26.3 | 26.4–26.6 | C24 | — | — | Freshness: 26.22–26.23 |
| lsp_symbols | 26.8–26.10 | (shared 26.4–26.7) | C25 | — | — | |
| lsp_hover | 26.11–26.14 | 26.7 | — | — | — | I5 envelope check (26.11) |
| lsp_completion | 26.15–26.16 | (shared) | — | — | — | |
| lsp_definition | 26.17–26.19 | (shared) | C25 | — | — | |
| lsp_references | 26.20–26.21 | (shared) | — | — | — | |
| lsp_project_diagnostics | 26.24–26.26 | (shared 26.4–26.7 guards) | C29 | 26.24 (hint → lsp_diagnostics + debugger_get_log) | — | Project-wide compile scan (server LSP fan-out); include_addons (26.25) + include_warnings (26.26); accounting invariant `scanned == clean + files_with_diagnostics + timed_out + read_failed`. C29 = single-file check → project scan → fix → re-scan freshness (project-scope C24). Sweep drives via the MCP server so the successHint IS present (unlike smoke §48's direct-handler path) |

### Debugger Tools (4 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| debug.state | 27.1 | — | C26 | — | — | |
| debug.list_breakpoints | 27.4, 27.6, 27.8 | — | — | — | — | GDScript only |
| debug.set_breakpoint | 27.2, 27.3, 27.5, 27.7 | 27.9–27.14 | C26 | — | — | GDScript only. 27.2: breakpoint bound by script **identity** (not "current editor"), set is verified via `is_line_breakpointed`, and the echoed `file_path` is the **verified** path — a stale/phantom tab (4.2-4.4, no auto-close) that blocks foregrounding now yields `INTERNAL` rather than a misrouted set with a false echo. |
| debug.continue | 27.15 | 27.16 | C26 | — | — | |

### Undo/Redo Verification (cross-cutting, Section 25)

> **60** numbered UR sub-cases (UR1.x–UR13.x) — scaffolding (UR-Setup/UR-S1–S3,
> UR-Console, UR-Cleanup/UR-C1–C7) excluded. Matches the `tool-sweep.md` index and
> the `Sections/25-undo-redo.md` header. UR4–UR12 are `context_object` regression
> guards (missing-context → `UndoRedo history mismatch`); UR13 watches navigation's
> UndoRedo adoption.

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| MCPToolkitUndoRedoAction (builder) | UR-S3 | — | — | — | — | Self-contained integration tests via run_undo_redo_tests() |
| node.set_property | UR1.1–UR1.6 | — | — | — | — | Property undo/redo via trigger_undo/trigger_redo |
| node.manage (rename) | UR2.1–UR2.4 | — | — | — | — | Rename undo/redo |
| node.groups (add) | UR3.1–UR3.4 | — | — | — | — | Group add undo/redo |
| node.manage (reorder) | UR4.1–UR4.5 | — | — | — | — | Reorder undo/redo (context_object regression guard) |
| node.manage (duplicate) | UR5.1–UR5.3 | — | — | — | — | Duplicate undo/redo (context_object regression guard) |
| node.groups (remove + batch) | UR6.1–UR6.7 | — | — | — | — | Group remove + batch undo/redo (context_object regression guard) |
| scene.delete_node | UR7.1–UR7.3 | — | — | — | — | Node deletion undo/redo (context_object regression guard) |
| control.set_layout | UR8.1–UR8.4 | — | — | — | — | Layout preset undo/redo (context_object regression guard) |
| signal.manage (connect/disconnect) | UR9.1–UR9.7 | — | — | — | — | Signal connect/disconnect undo/redo (context_object regression guard) |
| path2d.edit_curve | UR10.1–UR10.4 | — | — | — | — | Curve edit undo/redo (context_object regression guard) |
| particles.create | UR11.1–UR11.4 | — | — | — | — | Particles create undo/redo (context_object regression guard) |
| collision_from_texture | UR12.1–UR12.5 | — | — | — | — | Collision-from-texture undo/redo (context_object regression guard) |
| navigation_edit | UR13.1–UR13.4 | — | — | — | — | Navigation polygon undo/redo (UndoRedo adoption watch; bake stays direct) |

---

## Runtime-Only Tools (12 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| runtime.screenshot | 20.5, 20.5b, 20.5c, 20.5d, 20.5e, 20.5f, 20.5g, 20.5h, 20.5i | ✓ (20.5c: RUNTIME_WINDOW_MINIMIZED; 20.5f: save_path res:// → PATH_DENIED; 20.5h: image_detail=huge → INVALID_PARAMS) | — | ✓ (20.5c minimized hint; 20.5i full-res disk hint) | — | 20.5b: unfocused-but-visible → fresh frame; 20.5c: minimized → RUNTIME_WINDOW_MINIMIZED (not TIMEOUT/stale); 20.5d: `force_foreground_game:true` un-minimizes + fresh frame; 20.5e: `image_response_mode:"disk"` → lean envelope (no `image_base64`, file on disk); 20.5f: `save_path:"res://…"` → PATH_DENIED (runtime allowlist is `user://screenshots/` only); 20.5g/20.5h: `image_detail` `full`/`mid`(≤1024)/`low`(≤512) inline cap — proportional + aspect-preserving + shrink-only, echoes `image_detail`+`returned` "WxH"; bad value → INVALID_PARAMS; 20.5i: `both`+`low` disk×detail orthogonality — inline downscaled BUT disk `path` full-res + full-res `hint` (41o-quater-ter) |
| runtime.get_node_state | 73 | — | C8 | — | — | |
| runtime.get_script_vars | 74 | — | — | — | — | |
| runtime.set_property | 20.8, 20.8b, 20.8c, 20.10 | ✓ (20.8b: cross-family wrong-type → SET_FAILED; 20.8c: convertible → ADJUSTED success+warning, 41o C1/D1) | — | ✓ (20.8c: adjusted `warning`) | c6d5f40, 41o C1/D1 | 20.8: happy (speed); 20.10: autoload-persistence warning; 20.8b/20.8c: tri-state via the shared `contract/property_set_check.gd` detector (runtime twins of editor 3.2b/3.2c). Headless unit `runtime.set_property tri-state pipeline` pins the coerce→set→describe_set_drop pipeline (dropped/ok/adjusted) |
| debugger.get_log | 75, 75a–75f, 80a–80f, 20.13–20.15a | ✓ (75d) | — | — | dec5b24; ledger #20 | Shared with editor; 80a–80f: bridge error_buffer + debug_state; ledger #20 (supersedes #9): runtime total→total_lines + has_more (was truncated) + returned (was count), capped tail; 20.13–20.15 assert `returned`; 20.15a: file source under a `text_filter` filters-then-slices, uniform with buffer (41n-ter-bis #7a); LOG_BUSY/LOG_UNAVAILABLE hints version-gated via shared MCPToolkitError.log_busy_hint/log_unavailable_hint (41n-undecies-bis-bis) |
| signal.list | (via editor 44–48) | — | — | — | — | Runtime uses same handler |
| signal.connect | (via editor 45) | — | — | — | — | Runtime uses same handler |
| signal.disconnect | (via editor 47) | — | — | — | — | Runtime uses same handler |
| signal.emit | 79 | — | — | — | — | |
| input.simulate | 20.17, 20.17a–20.17g, 20.17h | ✓ (20.17h: unknown action → INVALID_PARAMS, 41o C6) | — | ✓ (20.17c no-focus, 20.17f non-editable) | — | send_text event (41n-sexies): node_path focus + text_changed (20.17a), current-focus (20.17b), no-focus→hint (20.17c), submit→text_submitted via observer (20.17d), secret→redacted (20.17e), non-editable→text_changed:false+hint (20.17f), multiline newline-on-submit (20.17g). 20.17h: action-mode InputMap guard — an unregistered action is rejected (INVALID_PARAMS naming it), not a silent no-op (key/text/click modes unaffected). FLAG-5: reconciled stale flat `76`→20.x section-local numbering |
| animation_player.control | 78 | — | — | — | — | |
| execute.code | 77 | — | — | — | FIX-4, 279efed | Runtime context |

---

## Gap Summary

**Tools with NO dedicated sweep test:** 2
- `meta.set_limits` — sweep-side untested by design (internal); wire contract owned by smoke §21 (`21_response_caps.ts` hard-asserts override + floor-clamp + restore)
- `editor.set_lsp_status` — untested by design (internal): MCP server → plugin LSP-status push, dock-only publisher; not agent-facing (7th registration in `commands/editor/editor_commands.gd`)

**Tools with incomplete coverage (missing new params/guards):** 12
- `scene.create_node` — unique_name param
- `scene.instantiate` — properties param, auto-rename (FIX-K)
- `node.set_property` — LayerMask coercion, bare res:// guard (FIX-F). _Batch mode covered (3.12 happy path + 3.14c/3.14d partial-failure rollup, concern 034 D)._
- `node.groups` — _batch mode covered (4.12/4.14 happy path + 4.15/4.16 partial-failure rollup, concern 034 D)._
- `script.write` — diagnostics response fields (FIX-1)
- `editor.get_console` — clear_buffer param (FIX-8)
- `execute.code` — singleton hints (FIX-4). _load() hint (both remedies) + parse-error framing now covered by 9.4/9.7._
- `project.set_setting` — autoload key guard (23d69f9)
- `game.start` — compilation failure detection (4be3454), wait_for_runtime hint (a28d17b)
- `debugger.get_log` — double-escape warning (a828cb1). Cached-log-after-crash gap closed by 21.5b/21.10 (41l-quater-bis)
- `tilemap.set_cells` — regions param (FIX-A), no-tileset rejection (FIX-J)
- `signal.manage` — 3-case method hint validation (5f96b62)

**Renames to verify in sweep text:** 4
- `editor.reload_scripts` → `editor.refresh` (5f96b62)
- `input_map action_name` → `name` (09a6392)
- `signal_manage source_path` → `node_path` (FIX-G)
- `scene_instantiate packed_path` → `scene_path` (FIX-B)

**Param removals to verify absent from sweep text:** 1
- `editor_screenshot size` `{width,height}` — **retired** (41o-quater-ter). Superseded by the universal `image_detail` proportional inline cap on both capture tools (`size` was node-focus-only exact-WxH, could aspect-distort/upscale). Node framing stays `node_path`'s job. Verify no `editor_screenshot size` remains in §07 (7.2i reworded to drop the `size` mention; 7.2j/7.2k add `image_detail`); §20 gains 20.5g–20.5i for `image_detail` + disk-full-res.

---

## Spatial Map & Placeholder Generation (3 tools — 41m-quinquies, Section 28)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| scene_spatial_map | 28.1–28.7b | ✓ (28.7: **-32602** detail [enum, server-side] + INVALID_PARAMS region size) | — | ✓ (has_more hint, successHint → node_set_property) | ledger #20 | eager; read-only; 2D + 3D dispatch; ledger #20 (supersedes #9): total_nodes (was node_count)/has_more (was truncated) + returned (kept); cursor-less (bounds nav aid) |
| texture_generate | 28.8–28.15 | ✓ (28.15: INVALID_PATH png, PATH_DENIED, INVALID_PARAMS transparent, **-32602** shape [enum], ALREADY_EXISTS) | — | ✓ (successHint → Sprite2D.texture / spriteframes_create) | — | `placeholders` group; all 7 shapes, colour formats, hollow, label, dim cap; **class always Texture2D, no settle wait (Item B, 41m-sexies)** |
| sound_generate | 28.16–28.19 | ✓ (28.19: INVALID_PATH wav, PATH_DENIED, **-32602** waveform [enum]) | — | ✓ (successHint → AudioStreamPlayer.stream) | — | `placeholders` group; all 5 waveforms, sweep, decay, duration cap; **class always AudioStreamWAV (Item B)** |

> **runtime_set_property** was demoted eager → `runtime_advanced` group in
> 41m-quinquies; it remains covered in the runtime sweep (Section 20). The sweep
> calls it through the MCP tool surface, so the agent must `discover_tools` the
> `runtime_advanced` group first.
