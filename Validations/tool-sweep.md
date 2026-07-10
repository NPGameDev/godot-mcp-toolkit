# Universal MCP Tool Sweep v2

A comprehensive, modular validation sweep for the Godot MCP Toolkit.

**Total tools (agent-facing):** 110 + 2 meta — canonical count in server
`src/registration/catalogue.ts` (`--tools-count`).
**Toolkit surfaces (non-disjoint — do not sum):** 100 editor-registered (incl. the 4 `debug.*`) ·
12 runtime (4 names overlap the editor 100) · 6 LSP (server-side only).
**Sweep scale:** per-section defined-case counts in the Section Map below; last full-run tally in
`RESULTS.md` (479 tests · 2026-07-03 · Godot 4.7). **Combo chains: 17** (C1–C12 & C27–C28 in §22;
C24–C26 in §§26–27).

## How to Use

- **Full sweep:** Tell the agent: "Run the full tool sweep from `Validations/tool-sweep.md`." Read this index, then execute each section file sequentially.
- **Section-only (targeted):** Tell the agent: "Run sections 3, 7, 14 from the tool sweep." The agent reads only the relevant `Sections/XX-*.md` files. Each section is self-contained with setup/cleanup.
- **Cleanup only:** Tell the agent: "Run Global Cleanup (Last-cleanup) from the tool sweep."
- **Artifacts:** All test files use prefix `sv2_` and live under `res://sv2_validation/`. Nothing touches existing project files except temporary `project_set_setting` changes restored in cleanup.

### Completeness Rule

**During a full sweep, ALL sections and ALL test cases within each section
are mandatory.** Do not skip sections or individual tests based on
assumptions about speed, redundancy with individual-tool tests, or time
pressure. Combo chains test tool *interactions* that isolated tests cannot
catch. Extension tests validate the lazy-loading lifecycle. Guard tests
verify error contracts. Every test exists for a reason.

**Exception:** Targeted runs (section-only mode) may run a subset of
sections — this is explicitly directed by the user/prompt, not an agent
decision. Within each requested section, all tests are still mandatory.

## Prerequisites

- Godot editor open with the MCP plugin enabled
- MCP server connected (Claude Code has tool access)

## Execution Protocol

### Version Preflight

**MANDATORY — run once, before Section 0.**

The running **editor** version changes behavior — which tools are gated (`scene_close`
is 4.5+), which classes exist (`TileMapLayer` is 4.3+), and which degraded results are
legitimate on the floor. **Getting it wrong turns real regressions into "expected on
this version" excuses — silent false negatives.** So establish it **empirically, once,
before any section runs.**

**Do NOT infer the version from any of these — none report the running binary:**
- **`application/config/features`** (the value S0.1 reads via `project_get_settings`) —
  the project's *declared floor*, written to `project.godot` at save time by whatever
  editor last saved it. A 4.7 editor opens a `"4.2"`-tagged project and still reports
  `features:["4.2"]`. It describes the *project*, not the *engine*.
- **The boot banner / `editor_get_console source:"file"`** — 4.2/4.3 editors write no
  session log, so this silently returns a **stale** file (in the 41n-nonies run, a prior
  `--headless` log — the source of the bogus "headless / RendererDummy" conclusion).
- **Catalogue membership** in a `discover_tools` listing — the catalogue is static and
  lists version-gated tools on *every* version.

**Authoritative probe.** `execute_code` **cannot** read the version — its `Expression`
sandbox resolves no engine singletons (`Engine`, `OS`, `ProjectSettings` all fail). But
`node_call_method` dispatches a real `@tool` method via `callv()`, which reaches
`Engine`. A **committed probe fixture** is ready in the repo — **open it and call one
method, no setup:**

| # | Call | Args |
|---|------|------|
| P.1 | `scene_open` | `file_path=res://Validations/fixtures/EnvProbe.tscn` |
| P.2 | `node_call_method` | `node_path=.`, `method_name=get_engine_version` |

P.2 returns `result: {major, minor, patch, string, …}` — the running editor reporting
its **own** version. Record `Godot <major>.<minor>` as the DEFINITIVE version.

The fixture (`Validations/fixtures/EnvProbe.tscn` + `env_probe.gd`, a one-method `@tool`
`Node`) is committed to the toolkit repo, so it is ready the moment the sweep starts — no
per-run scaffolding. **If a non-dogfood target lacks it** (e.g. the C# dogfood, minigames,
or a fresh cross-version copy where `Validations/` isn't present), create it inline
instead — `script_write` the `@tool` body below → `scene_create` a `Node` root →
`node_set_script` → `node_call_method` — or fall back to the ClassDB cross-check:

```gdscript
# env_probe.gd — MUST be @tool, or callv() returns null in the editor
@tool
extends Node
func get_engine_version() -> Dictionary:
	return Engine.get_version_info()
```

**Cross-checks (independent — must agree with P.6):**
- **`classdb_get_info(class_name="TileMapLayer")`** → success ⟹ engine ≥ 4.3;
  `NOT_FOUND` ⟹ 4.2 (legacy `TileMap` only). **This distinguishes only 4.2 vs ≥4.3 —
  NOT 4.3 vs 4.4 vs 4.5.** "TileMapLayer present" does **not** mean modern/4.5 features
  are available.
- **`scene_close` in the live tools/list** (not the catalogue) is present **iff**
  engine ≥ 4.5. So on **4.3 or 4.4** — where `TileMapLayer` *is* present — `scene_close`
  is **legitimately absent, and that absence means "engine < 4.5," not a broken/missing
  tool.** Present ⟹ ≥4.5. (Absence alone is `<4.5` *or* version-not-yet-resolved — which
  is exactly why P.6 is authoritative and this is only a cross-check.)

**Gate:**
1. State the **TARGET** version the run is validating (e.g. "4.2 floor").
2. Establish the **ACTUAL** version from P.6 (cross-checked above).
3. **HALT the sweep if ACTUAL ≠ TARGET** — do not run a single section; re-point the
   editor/port and re-probe. A wrong version silently poisons every degradation judgment.
4. RESULTS header: `Godot X.Y — via node_call_method Engine.get_version_info() (P.2);
   TileMapLayer=<y/n>, scene_close visible=<y/n>; features PSA / boot-banner NOT used.`
5. **Every "excused as <ver> degradation" call downstream MUST cite this
   empirically-established version** — never a version inferred from a string or a log.

> **Temporary workaround.** This probe scene exists only because no MCP tool yet
> surfaces the running version — the server already has it (editor auth-ack →
> `Engine.get_version_info()`) but doesn't expose it. To be replaced by a first-class
> version field/tool and reverted then. Tracked: PostRelease idea, tag
> `authoritative-engine-version`.

### Progress Logging

After completing each section, **immediately** append results to `Validations/RESULTS.md` before moving to the next section. Format:

```markdown
## Section N — Title (YYYY-MM-DD HH:MM)
| Test | Status | Notes |
|------|--------|-------|
| N.1 | PASS | |
| N.2 | FAIL | [brief reason] |
```

This ensures progress is saved incrementally. If the session crashes, another agent can resume from the last logged section.

### Tool Group Management

To avoid bloating the agent's context with tool definitions:
1. **Before each section:** activate only the tool groups needed for that section's tools (listed in the section header).
2. **After each section cleanup:** deactivate groups no longer needed via `discover_tools(reset=[...])` with the specific group names.
3. **Exception:** Core tools (scene, node, editor, project) are always available in standard mode — no activation needed.

### Console Isolation

Every section ends with a `## Console error check` block. The full procedure is defined here — section files reference this protocol.

**Setup (before each section's first test):**
1. Call `editor_get_console` with `clear_buffer=true` to discard stale entries from previous sections.
2. Do not fail if the buffer is empty or unavailable.

**Check (at the end of each section, under `## Console error check`):**
1. Call `editor_get_console` and scan output for `UndoRedo history mismatch`.
2. Ignore intentional error logs from guard tests (e.g., `Failed loading resource`).
3. **FAIL** if any `UndoRedo history mismatch` line appears.
4. **PASS** if no mismatch lines found, or if the console buffer is empty/unavailable.

**Teardown (after scanning):**
1. Call `editor_get_console` with `clear_buffer=true` to flush the buffer for the next section.

**Alternative (`since_id`):** Instead of clearing, record the `next_id` returned by the setup call and pass it as `since_id` in the check call. This avoids clearing and works with file-based log sources (`source="file"`). Agents may use either approach.

### Deferred-Tools Cache (Claude Code Platform Note)

In Claude Code, `ToolSearch` may not return newly-activated tools due to the deferred-tools cache. **This does NOT mean the tools can't be called.** The MCP tools are available on the server side immediately after `discover_tools` activates them — just call them directly by name. Do not treat a missing ToolSearch result as a failure. Only record FAIL if the actual tool call returns "method not found" from the MCP server.

### Tool-Name Resolution & Mismatch Handling

**Authoring rule (naming SSOT).** Every tool reference in this index, the section files, and
`SWEEP-COVERAGE-MANIFEST.md` MUST use the **agent-facing MCP tool name** (as returned by
`tools/list` / `discover_tools`), never the toolkit's internal dotted *method* name. For most
tools the two differ only by `.`↔`_` (`node.set_property` → `node_set_property`); where the
**stem** diverges, the tool name wins — `collision_from_texture` (not
`node.collision_from_sprite`), `navigation_edit` (not `navigation_edit_polygon`). A test that
names a tool the agent can't call is a manifest defect, not a missing capability.

**Robustness rule (not-found tool).** If a step calls a tool name the MCP server rejects with
"method not found" *after its group is active* (distinct from the deferred-tools-cache case
above, which is not a failure):
1. **Do not** mark the behavior PASS, and **do not** abort the section.
2. **Flag** it in `RESULTS.md` → *Pitfalls Discovered* (the stale name + "section/manifest
   names an unregistered tool").
3. **Work around it to still test the behavior:** run `discover_tools`, match the intended tool
   by stem/purpose (a "navigation polygon edit" step → `navigation_edit`), and run the intended
   check against the real tool — recording that PASS/FAIL separately from the doc defect.
4. If nothing matches, record BLOCKED (doc defect), never PASS.

### Batching & Efficiency (learned 2026-06-07 full run)

The biggest speed-up: **the Godot editor processes MCP commands serially on its
main thread, in arrival order, and preserves order within a single batch.**
So you do NOT need to split dependent operations across messages.

- **Batch aggressively.** Put a whole chain in one message — e.g.
  `create → set_property → get_property(verify) → save → open main → delete`,
  or all of a section's independent reads/guards at once. Earlier writes are
  visible to later calls in the same batch (confirmed: tilemap `set_cells` then
  `regions` reports `cells_unchanged:1`; tileset edits accumulate). Splitting
  one-op-per-message (the slow way) is unnecessary; reserve a separate message
  only when you must read a result to decide the *next* call.
- **Tool schemas: "required" is often not enforced, enums are.** Many tools
  list ~all params as `required` but accept minimal calls (e.g. `particles_create`
  works with just `parent_path`+`type`+`preset`). Conversely some need filler:
  single-mode `node_set_property` wants `make_unique:false, batch:[]`;
  `control_set_layout` wants `margins:{}`; `node_manage` wants `new_index:0,
  properties:{}`. Invalid enum values ARE rejected server-side (-32602) — use
  that for "invalid option" guard tests (preset, category, noise_type, type).
- **Group management:** swap in one call — `discover_tools(request:[new...],
  reset:[old...])`. Keep `cleanup` + `resource_io` active across the whole run;
  re-activate `editor_advanced` whenever you need `editor_refresh`. After
  `script_write`, the file is `indexed:true` immediately — no refresh needed
  before `script_check`/LSP on that file (LSP cross-file resolution may still
  want a targeted `editor_refresh`).
- **Console isolation, 2 calls/section:** `editor_get_console(clear_buffer:true)`
  at section start; a plain read at section end (scan for `UndoRedo history
  mismatch`). The next section's setup-clear doubles as teardown.
- **Param-shape drift to fix in the section files** (tools work, docs are stale):
  LayerMask is `{type:LayerMask, layers:[1,3]}` not `{value:5}` (S3.11);
  `node_groups` batch is `entries:[{node_path,group}]` not `groups:[]` (S4);
  the nav tool is `navigation_edit` not `navigation_edit_polygon` (S16);
  `signal_manage` uses `action`/`node_path` not `operation`/`source_path` (S5);
  `audiobus_edit`/`spriteframes_edit` require filler params for non-applicable
  fields. Section files should be aligned to the live schemas.
- **Section 24 (extensions) needs an editor restart.** `extensions_refresh` does
  NOT pick up a newly-created extension in-session (verified in both `addons/`
  and project folders, even after full refresh). To validate E1–E10, restart the
  editor (or disable/re-enable the plugin) between writing the extension and
  refreshing — otherwise expect `commands:[]` and mark E1–E10 BLOCKED.
- **Last-cleanup: phantom script tabs block `folder_delete`.** `script_delete`
  doesn't close the script-editor tab, so `folder_delete` on the parent reports
  `PATH_IN_USE`. Delete files individually first, then remove the now-empty
  `sv2_validation/` directory from the filesystem (or restart the editor to drop
  the tabs). Phantom tabs also cause harmless "File not found" console errors on
  later `game_start`.

## Section Map

| # | File | Title | Tests | Tools Covered | Dependencies |
|---|------|-------|-------|---------------|--------------|
| 0 | [00-environment.md](Sections/00-environment.md) | Environment Detection | 7 | project_get_settings, asset_list, discover_tools | None |
| 1 | [01-scaffolding.md](Sections/01-scaffolding.md) | Scaffolding & Core Files | 10 | folder_create, script_write, resource_write, scene_create, scene_open | S0 |
| 2 | [02-scene-tree.md](Sections/02-scene-tree.md) | Scene Tree & Node Creation | 19 | scene_create_node, scene_instantiate, scene_get_tree, editor_save_scene | S1 |
| 3 | [03-node-properties.md](Sections/03-node-properties.md) | Node Properties & Methods | 35 | node_set/get_property, node_set_script, node_get_property_list, node_call_method, control_set_layout | S2 |
| 4 | [04-node-management.md](Sections/04-node-management.md) | Node Management | 18 | node_manage, node_groups | S2 |
| 5 | [05-signals.md](Sections/05-signals.md) | Signals | 7 | signal_list, signal_manage | S2 |
| 6 | [06-scripts.md](Sections/06-scripts.md) | Script Operations | 9 | script_read, script_write, script_check, asset_list, asset_get_dependencies | S1 |
| 7 | [07-editor-console.md](Sections/07-editor-console.md) | Editor Operations & Console | 15 | editor_save_scene, editor_screenshot, editor_get_console, editor_wait_for_idle, editor_refresh | S2 |
| 8 | [08-project-settings.md](Sections/08-project-settings.md) | Project Settings & Autoloads | 12 | project_get/set_settings, autoload_manage, layer_names_get/set | S1 |
| 9 | [09-execute-code.md](Sections/09-execute-code.md) | execute_code & Hints | 8 | execute_code | S2 |
| 10 | [10-input-map.md](Sections/10-input-map.md) | Input Map | 4 | input_map_action, input_map_event | None |
| 11 | [11-save-system.md](Sections/11-save-system.md) | Save System | 6 | save_write, save_read, save_list, save_delete | None |
| 12 | [12-classdb.md](Sections/12-classdb.md) | ClassDB Introspection | 11 | classdb_search, classdb_get_info | None |
| 13 | [13-animation.md](Sections/13-animation.md) | Animation & AnimationTree | 12 | animation_keyframe, animation_get_keys, animationtree_edit, animationtree_list | S2 |
| 14 | [14-tileset-tilemap.md](Sections/14-tileset-tilemap.md) | TileSet & TileMap | 19 | tileset_create, tileset_edit, tilemap_set_cells, tilemap_read_cells | S2 |
| 15 | [15-theme-audio-sprites.md](Sections/15-theme-audio-sprites.md) | Theme, Audio, SpriteFrames | 14 | theme_edit, audiobus_edit, audiobus_list, spriteframes_create/edit/from_spritesheet | S1 |
| 16 | [16-domain-tools.md](Sections/16-domain-tools.md) | 3D, Path2D, Navigation, Particles, Procedural | 28 | 3d_*, path2d_edit_curve, navigation_edit, particles_create, procedural_edit_* | S2 |
| 17 | [17-scene-query-inherit.md](Sections/17-scene-query-inherit.md) | Scene Inheritance & Query | 19 | scene_create_inherited, scene_query | S1 |
| 18 | [18-file-operations.md](Sections/18-file-operations.md) | Phantom Tab Cleanup & File Operations | 16 | scene_close, scene_delete, file_delete, folder_delete, asset_import | S1 |
| 19 | [19-collision-meta.md](Sections/19-collision-meta.md) | collision_from_texture | 3 | collision_from_texture | S2 |
| 20 | [20-runtime.md](Sections/20-runtime.md) | Game Start, Runtime & Debugging | 29 | game_start/stop, runtime_*, debugger_get_log, input_simulate (send_text), execute_code, animation_player_control, signal_emit | S2 |
| 21 | [21-game-guards.md](Sections/21-game-guards.md) | game_start Guards & Crash Recovery | 13 | game_start, debugger_get_log (debug_state, error_buffer, log_scan) | S1 |
| 22 | [22-combo-chains.md](Sections/22-combo-chains.md) | Combo Chains | 14 chains (+3 in §§26–27 = 17 total) | Multi-tool workflows | S1 |
| 23 | [23-csharp.md](Sections/23-csharp.md) | C# Compatibility | ~50 | All tools with C# nodes | S2, .NET project |
| 24 | [24-extensions.md](Sections/24-extensions.md) | Extension Discovery | 9+ | discover_tools, extensions.refresh | Extensions present |
| 25 | [25-undo-redo.md](Sections/25-undo-redo.md) | Undo/Redo Verification | 60 | node.set_property, scene.create_node, node.manage, node.groups, node.call_method | S2 |
| 26 | [26-lsp-tools.md](Sections/26-lsp-tools.md) | LSP Tools | 23+2 | lsp_diagnostics, lsp_symbols, lsp_hover, lsp_completion, lsp_definition, lsp_references | S1, LSP on port 6005 |
| 27 | [27-debugger-tools.md](Sections/27-debugger-tools.md) | Debugger Tools | 16+1 | debug_state, debug_list_breakpoints, debug_set_breakpoint, debug_continue | S1 |
| 28 | [28-placeholders-spatial.md](Sections/28-placeholders-spatial.md) | Spatial Map & Placeholder Generators | 22 | scene_spatial_map, texture_generate, sound_generate | S2 |

### Global Cleanup (always runs last)

| # | File | Description | Tests | Tools | Deps |
|----|------|-------------|-------|-------|------|
| Last | [Last-cleanup.md](Sections/Last-cleanup.md) | Global Cleanup | — | folder_delete, resource_delete, scene_delete, script_delete | Any |

## Dependency Legend

- **S0** = Section 0 completed (environment detected)
- **S1** = Section 1 completed (scaffolding artifacts exist under `res://sv2_validation/`)
- **S2** = Section 2 completed (nodes exist in `res://sv2_validation/Sv2Main.tscn`)
- **None** = Fully standalone, can run independently

## Regression Watch Summary

The sweep includes **57 REGRESSION WATCH** annotations covering DX fixes, bug fixes, and parameter renames from the 41k + 41l validation clusters. These appear inline in the relevant section files. If a test marked with REGRESSION WATCH fails, it indicates a previously-fixed behavior has regressed — flag prominently.

| Category | Count | Sections |
|----------|-------|----------|
| FIX-1 through FIX-9 | 7 | S1, S3, S6, S7, S9, S14 |
| FIX-A through FIX-K | 11 | S2, S3, S5, S8, S14, S22 |
| Pitfalls 3, 4, 6 | 3 (canary) | S3, S22 |
| Commit-ref fixes (41k) | 10 | S2, S3, S4, S5, S7, S10, S20, S23 |
| Commit-ref fixes (41l) | 6 | S5, S20, S21 |

## Reporting Template

After running the sweep, produce `Validations/RESULTS.md` with:

```markdown
# MCP Tool Sweep v2 Results

- **Date:** YYYY-MM-DD
- **Godot version:** X.Y
- **Project type:** GDScript | C# (.NET)
- **Sections run:** 0-25 (full) | N, M, O (targeted)
- **Total:** X passed, Y failed, Z skipped (W total)

## Section Results
| Section | Tests | Passed | Failed | Skipped | Notes |
|---------|-------|--------|--------|---------|-------|

## Regression Watch Results
| Fix Ref | Section.Test | Status | Notes |
|---------|-------------|--------|-------|

## Pitfalls Discovered
| Tool | Severity | Description | Expected vs Actual | Workaround |
|------|----------|-------------|-------------------|------------|
```
