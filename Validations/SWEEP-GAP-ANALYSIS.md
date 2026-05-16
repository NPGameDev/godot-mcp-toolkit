# Sweep Gap Analysis

**Date:** 2026-05-16
**Commit range:** `a83771e..dec5b24` (31 commits)
**Sweep baseline:** 41k-quater-et-vicies (152/154, T:a83771e)
**Analyzed by:** Claude Code (41k-ter-et-tricies iteration)

---

## Summary

- **31 commits** analyzed since last comprehensive sweep update
- **7** already tracked or docs-only (no sweep action needed)
- **14** contain tool behavior changes needing sweep coverage
- **10** are skill/chore/docs changes (informing combo patterns but not directly testable)

---

## Commit Categorization

| SHA | Subject | Category | Tracked? | Action Needed |
|-----|---------|----------|----------|---------------|
| dec5b24 | feat(plugin): editor-side runtime log cache for post-crash debugger_get_log | Bug fix / New behavior | No | Add test: debugger_get_log with cached log after crash scenario |
| 2f431f2 | feat(skill): add fast-forward testing pattern with runtime_set_property | Skill changes | N/A | Informs combo chain: runtime_set_property state-jumping pattern |
| 8cdcb92 | fix(skill): add latency + ambiguity arguments against screenshots | Skill changes | N/A | — |
| ca4c77e | fix(skill): clarify screenshot rule — logic vs visuals | Skill changes | N/A | — |
| 85ceb21 | fix(skill): strengthen screenshot guidance — never for debugging | Skill changes | N/A | — |
| 47c8f33 | fix(skill): add Read(project.godot) as cheap settings survey option | Skill changes | N/A | Informs combo: project_get_settings vs file read trade-off |
| f120bfd | fix(skill): add runtime verification cost ladder | Skill changes | N/A | Informs combo: runtime tool selection hierarchy |
| 8478406 | fix(skill): add autoload stale-cache warning | Skill changes | N/A | Informs combo: autoload + editor.refresh interaction |
| 503f889 | fix(skill): add project_get_settings token-waste warning | Skill changes | N/A | Informs combo: project_get_settings usage pattern |
| 5818209 | feat(skill): add godot-mcp-toolkit companion skill (486 lines) | Skill changes | N/A | Informs combo patterns: type wrappers, error recovery flows |
| a28d17b | fix(plugin): gate game_start hint text on wait_for_runtime=false | Hint improvements | No | Add test: game_start with wait_for_runtime=false should show different hint |
| 462506b | feat(tools): LayerMask type tag, node_groups batch, scene_instantiate properties | New parameters | No | Add tests: LayerMask coercion, node_groups batch op, scene_instantiate properties param |
| 5f96b62 | fix(tools): rename editor.reload_scripts → editor.refresh + signal_manage method hint | Refactor + Hint | Partial | Verify sweep uses editor.refresh (not reload_scripts); add signal_manage method hint test |
| cb4e162 | fix(tools): class mismatch guard on scene_create_node + preload hint off-by-one | Guard additions | No | Add test: scene_create_node with wrong class → CLASS_MISMATCH error |
| a46487b | fix(tools): preload hint in script_write + unique_name on scene_create_node | New parameters + Hints | No | Add tests: script_write preload hint check, scene_create_node unique_name param |
| 09a6392 | fix(tools): rename input_map action_name param to name | Refactor | Partial | Verify sweep uses `name` param (not `action_name`) for input_map tools |
| 279efed | fix(tools): context-aware load() hint in execute_code (editor + runtime) | Hint improvements | No | Add test: execute_code load() attempt → context-aware hint |
| 4be3454 | fix(tools): detect compilation failure in game_start + enriched hints | Guard additions | No | Add test: game_start after script error → COMPILATION_FAILED + hints |
| 23d69f9 | fix(tools): autoload DX hints + project_set_setting guard | Guard + Hints | No | Add tests: project_set_setting autoload key guard; autoload hint in relevant tools |
| 7e63aee | fix(tools): DX octies validation — 11 fixes | Multiple | Partial | FIX-A through FIX-K: tilemap regions, scene_path rename, batch activation, autoload API, Resource type detection, bare res:// hint, signal node_path rename, load() expansion, tileset_create validation, tilemap no-tileset rejection, auto-rename collision |
| 84b104c | chore: track nodejs_check.gd.uid | Chore | N/A | — |
| c6d5f40 | fix(runtime): warn when runtime_set_property modifies an autoload | Guard additions | No | Add test: runtime_set_property on autoload → warning in response |
| 98c02f3 | fix(tools): DX evaluation fixes — script diagnostics, coercion, batch, ownership | Multiple | Partial | FIX-1: script_write diagnostics; FIX-5: packed array coercion; FIX-7: batch node_set_property; FIX-8: clear_buffer param; FIX-9: scene_instantiate ownership |
| 3d8f5da | fix(config): update project.godot feature gate to execute_code rename | Chore | N/A | Gate verified: uses `allow_execute_code` (confirmed) |
| 2ee36a1 | feat(plugin): Node.js dependency detection + extension docs | New feature | No | Not sweep-testable (editor UI + docs only), but note extension graceful handling |
| 3f415ff | docs(validation): tool-sweep results + fix validation | Docs | Already tracked | — |
| a828cb1 | fix(plugin): warn on double-escaped regex metacharacters in text_filter | Guard additions | Partial | Already has regex test (58b); needs annotation for double-escape warning |
| c61d994 | fix(plugin): type-aware property coercion for duplicate + ResourceRef alias | Guard + New params | Partial | Already has tests (43h2, fix-validation); needs manifest entry + annotation |
| 2ca9f5b | docs(sweep): clarify selective reset steps in discover_tools section | Docs | Already tracked | — |
| 4c882c1 | fix(plugin): add missing navigation_commands.gd.uid | Chore | N/A | — |
| 5f4209e | docs(sweep): add node_manage duplicate+properties and discover_tools selective reset | Docs | Already tracked | — |

---

## DX Fix Cross-Reference (23 fixes)

### FIX-1 through FIX-9 (41k-quinquies-et-vicies)

| Fix | What Changed | Sweep Test? | Action |
|-----|-------------|-------------|--------|
| FIX-1 | script_write returns inline diagnostics | No | Add test verifying `valid` + `diagnostics` fields in response |
| FIX-2 | tileset_edit layer validation (int coercion) | No | Add guard test with non-integer layer input |
| FIX-3 | asset_management group split into 3 | Partial (discover_tools tests exist) | Verify discover_tools tests reflect new group names |
| FIX-4 | execute_code singleton hints (EditorInterface, load()) | No | Add test: execute_code with EditorInterface → hint |
| FIX-5 | PackedVector2Array/PackedColorArray coercion + type tag validation | No | Add test with PackedVector2Array type tag |
| FIX-6 | Runtime NOT_FOUND includes sibling list | No | Runtime test: bad node_path → hint includes siblings |
| FIX-7 | node_set_property batch mode | No | Add batch test with multiple nodes/properties |
| FIX-8 | editor_get_console clear_buffer param | No | Add test exercising clear_buffer=true |
| FIX-9 | scene_instantiate set_owner (non-recursive) | Partial (41 tests instantiate) | Add annotation at test 41 |

### FIX-A through FIX-K (41k-octies-et-vicies)

| Fix | What Changed | Sweep Test? | Action |
|-----|-------------|-------------|--------|
| FIX-A | tilemap_set_cells regions param for bulk fill | No | Add test with regions param |
| FIX-B | scene_instantiate scene_path rename (from packed_path) | Partial | Verify sweep uses `scene_path` |
| FIX-C | Batch activation single notification | No | Canary annotation on discover_tools test |
| FIX-D | autoload.manage EditorPlugin API call | No | Add test: autoload.manage registers + immediately available |
| FIX-E | Resource type tag in node_set_property description | Hint only | Annotation on property-setting tests |
| FIX-F | Bare res:// detection + hint | No | Add guard test: bare string without type wrapper |
| FIX-G | signal_manage source_path → node_path rename | Partial | Verify sweep uses `node_path` |
| FIX-H | execute_code load() error expansion | No | Add test: execute_code load() → expanded hint |
| FIX-I | tileset_create type validation | No | Add guard test for malformed tileset creation |
| FIX-J | tilemap_set_cells no-tileset rejection | No | Add guard test: paint cells without tileset |
| FIX-K | Auto-rename on duplicate instance | No | Add test: duplicate → suffix added |

### Pitfalls 3, 4, 6

| Pitfall | What It Is | Sweep Test? | Action |
|---------|-----------|-------------|--------|
| P3 | discover_tools activates but tools may not be immediately callable (deferred-tools caching) | N/A | Canary annotation — platform-side, not toolkit regression |
| P4 | ResourceRef alias for Resource type tag | Partial (fix-validation) | Annotation on resource property tests |
| P6 | Stale tool index after group activation (retry or reset+reactivate) | N/A | Canary annotation — platform-side, not toolkit regression |

---

## Gap Summary

**Untracked behavior changes requiring new test cases:** 24
**Untracked parameters requiring test coverage:** 8
**Renames requiring sweep text verification:** 4
**Canary annotations needed (platform-side):** 3
**Already tracked (no action):** 7
**Skill/chore (informing combo patterns):** 10
