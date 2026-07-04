# Sweep Coverage Manifest

**Last updated:** 2026-07-05 (41n-undecies-bis-bis — version-gated LOG_BUSY/LOG_UNAVAILABLE hint SSOT; §07 REGRESSION WATCH note)
**Toolkit commit:** T:ffe7a13 + 41m-quinquies + 41n-034-D (final SHA recorded at bookkeeping)
**Total tools:** 122 (100 editor-side + 6 LSP + 4 debugger + 12 runtime)
**Sweep test count:** ~295 numbered test cases + 28 combo chains + C# phase + extension phase (Section 28 adds 22) — concern 034 D added 5 batch-rollup cases (3.14c/3.14d, 4.15/4.16, 2.15a); 41n-sexies added 7 send_text cases (20.17a–20.17g)

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
| scene.create | 7, 8, 17.1, 17.1b | — | C3, C5, C8, C13, C18, C19 | — | — | 17.1/17.1b: root_name override + stem default |
| scene.open | 18, 64a, 64d, 64f | — | C3, C7, C8 | — | — | |
| scene.close | 18.3, 18.14, 64b, 64f | ✓ (non-active, last tab) | C3, C7, C27 | ✓ (_set_main_scene_state hint) | — | 4.5+ only (version-gated via min_godot_version) |
| scene.delete | 18.4, 18.6, 64c, 64e | ✓ (active tab, non-active tab) | C3, C18 | ✓ (tab_closed, phantom warning) | — | |
| scene.create_node | 20–26, 64h | ✓ (C22: CLASS_MISMATCH) | C5, C8, C10, C19 | ✓ (preload, unique_name) | FIX-G (P6), cb4e162 | **GAP:** unique_name param untested |
| scene.delete_node | 43j, 43s, 64i | — | C19 | — | — | |
| scene.instantiate | 41, 43q–43s, 2.15a | — | C20 | — | FIX-B, FIX-9, FIX-K, concern 034 | 2.15a: all-success batch → `failed`/`hint` ABSENT (additive rollup, summarize_batch). Partial-failure path (`instantiate()==null`) is unit-pinned (`_test_summarize_batch`) — not selectively triggerable from a valid .tscn. **GAP:** properties param, auto-rename |
| scene.diff | 63 | — | — | — | — | |
| scene.create_inherited | 80a–80d | ✓ (NOT_FOUND) | — | — | — | |
| scene.query | 83a–83j | ✓ (no filters, NOT_FOUND) | — | — | — | |
| scene.get_tree | 19, 43, 43e, 43r | — | C8, C19, C20 | — | — | |

### Node Property & Method (9 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| node.get_property | 28, 31, 33, 36, 43b, 43i, 64g, 3.20b | — | C3, C6, C20 | — | concern 053 | 3.20b: Packed read-back is the TAGGED dict (not var_to_str) + read==write (concern 053, T:8856546) |
| node.set_property | 27, 29, 30, 32, 34, 35, 3.20b, 3.14c, 3.14d, 3.29 | ✓ (3.14a: groups single-reject, 3.14b: groups batch per-entry reject) | C3, C6 | ✓ (3.14a/3.14b: hint → node.groups) | FIX-5, FIX-7, FIX-E, FIX-F, concern 032, concern 053, concern 034 | groups property steered to node.groups (single whole-reject + batch per-entry); 3.20b sets a top-level PackedVector2Array (Line2D.points) for the 053 read-back round-trip. 3.14c/3.14d: batch partial-failure rollup — 3.14c asserts top-level `failed`(int, `int(...)`-coerced)+`hint` on a one-bad-entry batch; 3.14d asserts both ABSENT on all-success (summarize_batch, additive). 3.29: root rename via `name` (agrees with node.manage 4.17). **GAP:** LayerMask coercion, bare res:// guard |
| node.get_property_list | 38–40 | — | C5 | — | — | |
| node.call_method | 49, 50 | — | C9 | ✓ (CS3: C# hint) | — | |
| node.set_script | 37 | — | C5, C8 | — | — | |
| node.manage | 43a–43j, 4.17–4.18 | ✓ (43h2: properties; 4.17: root reparent/reorder/duplicate stay INVALID_PATH) | C19 | — | FIX-K | 4.17–4.18: root RENAME allowed (guard relaxed, 41n-undecies H — agrees with node.set_property `name`, 3.29); headless units pin root rename + kept structural guards |
| node.groups | 43k–43l, 4.12–4.16 | — | C19 | — | 462506b, concern 034 | 4.12/4.14: batch add/remove happy path; 4.15/4.16: batch partial-failure rollup — 4.15 asserts top-level `failed`(int)+`hint` via the shape-tolerant predicate on site-2's `{status?, error?}` (no-`success`) entries; 4.16 asserts both ABSENT on all-success (summarize_batch, additive) |
| node.collision_from_sprite | 78a–78d | ✓ (INVALID_CLASS) | — | — | — | |
| control.set_layout | 3.24–3.26 | ✓ (3.27: invalid preset, 3.28: wrong class) | C28 | — | 4d7e432 | W1 Lane 2 |

### Script Management (4 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| script.read | 15, 16, 6.2, 6.2b | — | — | ✓ (6.2 truncated `hint`) | concern 054 | 6.2/6.2b: uniform pagination contract — every success carries `truncated`+`total_lines`; a windowed read before EOF adds `next_start_line` (1-based = end_line+1) + a prose `hint`; full read / window-at-EOF = `truncated:false`, no hint. Mirrors save.read SHAPE in line units. |
| script.write | 2, 3 | — | C2, C5, C11, C23 | ✓ (C23: preload hint) | FIX-1 | **GAP:** diagnostics fields in response |
| script.delete | — | — | C2, C14 | — | — | Only in combos |
| script.check | 17 | — | C2, C11 | — | — | |

### Editor Core (6 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| editor.save_scene | 55, 64 | — | C3, C5, C7, C8, C9 | — | — | |
| editor.screenshot | 56, 57 | — | — | — | — | |
| editor.refresh | 61 | — | C15, C16 | — | 5f96b62 | Renamed from reload_scripts |
| editor.get_console | 58, 58a–58h | ✓ (58d: invalid regex) | — | — | FIX-8 | **GAP:** clear_buffer param; ledger #9: total_lines/next_id/truncated. LOG_BUSY/LOG_UNAVAILABLE hints version-gated (4.5+ buffer-steer only) — §07 REGRESSION WATCH note + server smoke §14 own the truth-table (41n-undecies-bis-bis) |
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
| asset.list | 12 | — | C14, C18 | — | — | ledger #9: total_assets/truncated (cursor-less) |
| asset.get_dependencies | 13 | — | — | — | — | ledger #9: total_dependencies/truncated (cursor-less) |
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
| file.delete | 18.7, 18.11 | — | C14 | ✓ (tab_closed for .tscn) | — | 18.11: .tscn tab close |

### Folder Management (2 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| folder.create | 1 | — | C17, C18 | — | — | |
| folder.delete | 18.12, 18.13 | — | C17, C18 | ✓ (tab_closed, stale_tabs) | — | 18.12: 1 scene, 18.13: 2 scenes + follow-up |

### ClassDB Introspection (2 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| classdb.get_info | 10, 12.5, 12.6 | — | — | ✓ (truncation hint) | 45975fc | Offset pagination (W1); ledger #9: total_<section> (was *_total)/truncated/next_offset |
| classdb.search | 9, 12.7 | — | — | ✓ (pagination hint) | 45975fc | Offset pagination (W1); ledger #9: total_classes (was total)/next_offset |

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
| save.read | 68, 11.7 | ✓ (11.5 PATH_DENIED, 11.7.6 cap exceeded) | — | ✓ (11.7 truncated `hint`) | concern 025, 054 | 11.7: byte `offset` paging (`offset`/`next_offset`/`total_bytes`/`truncated`) + configurable `save_read_cap_kb` (default 256, min 64) + FILE_TOO_LARGE frame guard (base64 1.33× vs `ws_buffer_kb`). Concern 054: truncated window carries a prose `hint` naming `next_offset`; absent once `truncated` is false (uniform pagination contract, shared SHAPE with script.read). |
| save.list | 69 | — | — | — | — | |
| save.delete | 70 | — | — | — | — | |

### Playtest / Game Control (3 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| game.start | 71 | — | C8 | — | 4be3454, a28d17b | **GAP:** compilation failure guard, wait_for_runtime hint |
| game.stop | 81 | — | C8 | — | — | |
| debugger.get_log | 75, 75a–75f, 80, 80a–80f, 20.15a | ✓ (75d: invalid regex) | — | — | dec5b24, a828cb1 | **GAP:** double-escape warning. 80a–80f: debug_state + error_buffer (41l-quater-bis). ledger #9: total_lines/truncated (capped tail); 20.15a: file source under a `text_filter` filters-then-slices, uniform with buffer (41n-ter-bis #7a — supersedes the file-path capped-tail `truncated=start>0`); LOG_BUSY hint version-gated via shared MCPToolkitError.log_busy_hint (41n-undecies-bis-bis) |

### Animation (4 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| animation.keyframe | 51, 52 | — | C9 | — | — | |
| animation.get_keys | 53 | — | C9 | — | — | |
| animationtree.edit | 13.5–13.9 | — | — | — | — | 5 mutating sub-ops; `list` extracted to `animationtree.list` (ledger #3 CQS split). _Test IDs reconciled to current `Sections/13` scheme (were stale `54m–54s`)._ |
| animationtree.list | 13.10 | ✓ (13.11: INVALID_CLASS) | — | — | — | Read-only structure list (extracted from `animationtree.edit`, ledger #3) |

### TileMap (2 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| tilemap.set_cells | 14.18–14.19 | ✓ (14.20: no-tileset) | C10 | — | FIX-A, FIX-J | |
| tilemap.read_cells | 14.21–14.22 | ✓ (14.23: NOT_FOUND, 14.24: wrong class, 14.25: missing param) | — | — | c7f56c8 | read-only; ledger #9: total_cells (was cells_total)/truncated |

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
| audiobus.list | 15.7 | — | — | — | — | Read-only bus-layout snapshot (extracted from `audiobus.edit`, ledger #3) |

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
| meta.set_limits | — | — | — | — | — | Internal (server→plugin); not agent-facing |
| discover_tools | C10 (12 steps), 28.8 | ✓ (reset, selective reset) | — | — | FIX-3, FIX-C | **dominant-match (Item C, 41m-sexies):** a vague multi-word query activates only the dominant group (28.8: "placeholder texture sprite sound" → only `placeholders`); server smoke §39 asserts prune + recall |
| extensions.refresh | E5 | — | — | — | — | Extension phase |
| *(extension API)* | E10a–E10d | E10c (guard) | — | E10a, E10b (hints) | — | success_hint + MCPToolkitError (41l-vicies-ter) |

### LSP Tools (6 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| lsp_diagnostics | 26.1–26.3 | 26.4–26.6 | C24 | — | — | Freshness: 26.22–26.23 |
| lsp_symbols | 26.8–26.10 | (shared 26.4–26.7) | C25 | — | — | |
| lsp_hover | 26.11–26.14 | 26.7 | — | — | — | I5 envelope check (26.11) |
| lsp_completion | 26.15–26.16 | (shared) | — | — | — | |
| lsp_definition | 26.17–26.19 | (shared) | C25 | — | — | |
| lsp_references | 26.20–26.21 | (shared) | — | — | — | |

### Debugger Tools (4 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| debug.state | 27.1 | — | C26 | — | — | |
| debug.list_breakpoints | 27.4, 27.6, 27.8 | — | — | — | — | GDScript only |
| debug.set_breakpoint | 27.2, 27.3, 27.5, 27.7 | 27.9–27.14 | C26 | — | — | GDScript only |
| debug.continue | 27.15 | 27.16 | C26 | — | — | |

### Undo/Redo Verification (cross-cutting, Section 25)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| MCPToolkitUndoRedoAction (builder) | UR-S3 | — | — | — | — | Self-contained integration tests via run_undo_redo_tests() |
| node.set_property | UR1.1–UR1.6 | — | — | — | — | Property undo/redo via trigger_undo/trigger_redo |
| node.manage (rename) | UR2.1–UR2.4 | — | — | — | — | Rename undo/redo |
| node.groups (add) | UR3.1–UR3.4 | — | — | — | — | Group add undo/redo |

---

## Runtime-Only Tools (12 tools)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| runtime.screenshot | 72 | — | — | — | — | |
| runtime.get_node_state | 73 | — | C8 | — | — | |
| runtime.get_script_vars | 74 | — | — | — | — | |
| runtime.set_property | — | — | — | — | c6d5f40 | **GAP:** no test + autoload warning |
| debugger.get_log | 75, 75a–75f, 80a–80f, 20.15a | ✓ (75d) | — | — | dec5b24 | Shared with editor; 80a–80f: bridge error_buffer + debug_state; ledger #9: runtime total→total_lines + truncated (capped tail); 20.15a: file source under a `text_filter` filters-then-slices, uniform with buffer (41n-ter-bis #7a); LOG_BUSY/LOG_UNAVAILABLE hints version-gated via shared MCPToolkitError.log_busy_hint/log_unavailable_hint (41n-undecies-bis-bis) |
| signal.list | (via editor 44–48) | — | — | — | — | Runtime uses same handler |
| signal.connect | (via editor 45) | — | — | — | — | Runtime uses same handler |
| signal.disconnect | (via editor 47) | — | — | — | — | Runtime uses same handler |
| signal.emit | 79 | — | — | — | — | |
| input.simulate | 20.17, 20.17a–20.17g | — | — | ✓ (20.17c no-focus, 20.17f non-editable) | — | send_text event (41n-sexies): node_path focus + text_changed (20.17a), current-focus (20.17b), no-focus→hint (20.17c), submit→text_submitted via observer (20.17d), secret→redacted (20.17e), non-editable→text_changed:false+hint (20.17f), multiline newline-on-submit (20.17g). FLAG-5: reconciled stale flat `76`→20.x section-local numbering |
| animation_player.control | 78 | — | — | — | — | |
| execute.code | 77 | — | — | — | FIX-4, 279efed | Runtime context |

---

## Gap Summary

**Tools with NO dedicated test:** 2
- `meta.set_limits` — no test at all
- `runtime.set_property` — no test at all

**Tools with incomplete coverage (missing new params/guards):** 12
- `scene.create_node` — unique_name param
- `scene.instantiate` — properties param, auto-rename (FIX-K)
- `node.set_property` — LayerMask coercion, bare res:// guard (FIX-F). _Batch mode covered (3.12 happy path + 3.14c/3.14d partial-failure rollup, concern 034 D)._
- `node.groups` — _batch mode covered (4.12/4.14 happy path + 4.15/4.16 partial-failure rollup, concern 034 D)._
- `script.write` — diagnostics response fields (FIX-1)
- `editor.get_console` — clear_buffer param (FIX-8)
- `execute.code` — singleton hints (FIX-4), load() hint (FIX-H, 279efed)
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

---

## Spatial Map & Placeholder Generation (3 tools — 41m-quinquies, Section 28)

| Tool Name | Sweep Tests | Guard Tests | Combo Chain | Hint Checks | DX Fix Ref | Notes |
|---|---|---|---|---|---|---|
| scene_spatial_map | 28.1–28.7b | ✓ (28.7: **-32602** detail [enum, server-side] + INVALID_PARAMS region size) | — | ✓ (truncation hint, successHint → node_set_property) | — | eager; read-only; 2D + 3D dispatch; ledger #9: total_nodes (was node_count)/truncated |
| texture_generate | 28.8–28.15 | ✓ (28.15: INVALID_PATH png, PATH_DENIED, INVALID_PARAMS transparent, **-32602** shape [enum], ALREADY_EXISTS) | — | ✓ (successHint → Sprite2D.texture / spriteframes_create) | — | `placeholders` group; all 7 shapes, colour formats, hollow, label, dim cap; **class always Texture2D, no settle wait (Item B, 41m-sexies)** |
| sound_generate | 28.16–28.19 | ✓ (28.19: INVALID_PATH wav, PATH_DENIED, **-32602** waveform [enum]) | — | ✓ (successHint → AudioStreamPlayer.stream) | — | `placeholders` group; all 5 waveforms, sweep, decay, duration cap; **class always AudioStreamWAV (Item B)** |

> **runtime_set_property** was demoted eager → `runtime_advanced` group in
> 41m-quinquies; it remains covered in the runtime sweep (Section 20). The sweep
> calls it through the MCP tool surface, so the agent must `discover_tools` the
> `runtime_advanced` group first.
