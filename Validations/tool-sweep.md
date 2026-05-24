# Universal MCP Tool Sweep v2

A comprehensive, modular validation sweep for the Godot MCP Toolkit covering all 117 MCP tools (95 editor-side + 6 LSP + 4 debugger + 12 runtime).

## How to Use

- **Full sweep:** Tell the agent: "Run the full tool sweep from `Validations/tool-sweep.md`." Read this index, then execute each section file sequentially.
- **Section-only:** Tell the agent: "Run sections 3, 7, 14 from the tool sweep." The agent reads only the relevant `Sections/XX-*.md` files. Each section is self-contained with setup/cleanup.
- **Cleanup only:** Tell the agent: "Run section 25 (Global Cleanup) from the tool sweep."
- **Artifacts:** All test files use prefix `sv2_` and live under `res://sv2_validation/`. Nothing touches existing project files except temporary `project_set_setting` changes restored in cleanup.

## Prerequisites

- Godot editor open with the MCP plugin enabled
- MCP server connected (Claude Code has tool access)
- Standard mode recommended for full coverage (all tools available). Read-only mode blocks mutations.

## Execution Protocol

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

### Deferred-Tools Cache (Claude Code Platform Note)

In Claude Code, `ToolSearch` may not return newly-activated tools due to the deferred-tools cache. **This does NOT mean the tools can't be called.** The MCP tools are available on the server side immediately after `discover_tools` activates them — just call them directly by name. Do not treat a missing ToolSearch result as a failure. Only record FAIL if the actual tool call returns "method not found" from the MCP server.

## Section Map

| # | File | Title | Tests | Tools Covered | Dependencies |
|---|------|-------|-------|---------------|--------------|
| 0 | [00-environment.md](Sections/00-environment.md) | Environment Detection | 7 | project_get_settings, asset_list, discover_tools | None |
| 1 | [01-scaffolding.md](Sections/01-scaffolding.md) | Scaffolding & Core Files | 10 | folder_create, script_write, resource_write, scene_create, scene_open | S0 |
| 2 | [02-scene-tree.md](Sections/02-scene-tree.md) | Scene Tree & Node Creation | 18 | scene_create_node, scene_instantiate, scene_get_tree, editor_save_scene | S1 |
| 3 | [03-node-properties.md](Sections/03-node-properties.md) | Node Properties & Methods | 28 | node_set/get_property, node_set_script, node_get_property_list, node_call_method, control_set_layout | S2 |
| 4 | [04-node-management.md](Sections/04-node-management.md) | Node Management | 14 | node_manage, node_groups | S2 |
| 5 | [05-signals.md](Sections/05-signals.md) | Signals | 7 | signal_list, signal_manage | S2 |
| 6 | [06-scripts.md](Sections/06-scripts.md) | Script Operations | 8 | script_read, script_write, script_check, asset_list, asset_get_dependencies | S1 |
| 7 | [07-editor-console.md](Sections/07-editor-console.md) | Editor Operations & Console | 16 | editor_save_scene, editor_screenshot, editor_get_console, editor_get_errors, editor_wait_for_idle, editor_refresh | S2 |
| 8 | [08-project-settings.md](Sections/08-project-settings.md) | Project Settings & Autoloads | 12 | project_get/set_settings, autoload_manage, layer_names_get/set | S1 |
| 9 | [09-execute-code.md](Sections/09-execute-code.md) | execute_code & Hints | 8 | execute_code | S2 (gated) |
| 10 | [10-input-map.md](Sections/10-input-map.md) | Input Map | 4 | input_map_action, input_map_event | None |
| 11 | [11-save-system.md](Sections/11-save-system.md) | Save System | 4 | save_write, save_read, save_list, save_delete | None |
| 12 | [12-classdb.md](Sections/12-classdb.md) | ClassDB Introspection | 7 | classdb_search, classdb_get_info | None |
| 13 | [13-animation.md](Sections/13-animation.md) | Animation & AnimationTree | 12 | animation_keyframe, animation_get_keys, animationtree_edit | S2 |
| 14 | [14-tileset-tilemap.md](Sections/14-tileset-tilemap.md) | TileSet & TileMap | 19 | tileset_create, tileset_edit, tilemap_set_cells, tilemap_read_cells | S2 |
| 15 | [15-theme-audio-sprites.md](Sections/15-theme-audio-sprites.md) | Theme, Audio, SpriteFrames | 12 | theme_edit, audiobus_edit, spriteframes_create/edit/from_spritesheet | S1 |
| 16 | [16-domain-tools.md](Sections/16-domain-tools.md) | 3D, Path2D, Navigation, Particles, Procedural | 28 | 3d_*, path2d_edit_curve, navigation_edit_polygon, particles_create, procedural_edit_* | S2 |
| 17 | [17-scene-query-inherit.md](Sections/17-scene-query-inherit.md) | Scene Inheritance & Query | 10 | scene_create_inherited, scene_query | S1 |
| 18 | [18-file-operations.md](Sections/18-file-operations.md) | Phantom Tab Cleanup & File Operations | 16 | scene_close, scene_delete, file_delete, folder_delete, asset_import | S1 |
| 19 | [19-collision-meta.md](Sections/19-collision-meta.md) | collision_from_sprite | 3 | collision_from_sprite | S2 |
| 20 | [20-runtime.md](Sections/20-runtime.md) | Game Start, Runtime & Debugging | 22 | game_start/stop, runtime_*, debugger_get_log, input_simulate, execute_code, animation_player_control, signal_emit | S2 |
| 21 | [21-game-guards.md](Sections/21-game-guards.md) | game_start Guards & Crash Recovery | 13 | game_start, debugger_get_log (debug_state, error_buffer, log_scan) | S1 |
| 22 | [22-combo-chains.md](Sections/22-combo-chains.md) | Combo Chains | 14 chains | Multi-tool workflows | S1 |
| 23 | [23-csharp.md](Sections/23-csharp.md) | C# Compatibility | ~50 | All tools with C# nodes | S2, .NET project |
| 24 | [24-extensions.md](Sections/24-extensions.md) | Extension Discovery | 9+ | discover_tools, extensions.refresh | Extensions present |
| 25 | [25-cleanup.md](Sections/25-cleanup.md) | Global Cleanup | — | folder_delete, resource_delete, scene_delete, script_delete | Any |
| 26 | [26-lsp-tools.md](Sections/26-lsp-tools.md) | LSP Tools | 23+2 | lsp_diagnostics, lsp_symbols, lsp_hover, lsp_completion, lsp_definition, lsp_references | S1, LSP on port 6005 |
| 27 | [27-debugger-tools.md](Sections/27-debugger-tools.md) | Debugger Tools | 16+1 | debug_state, debug_list_breakpoints, debug_set_breakpoint, debug_continue | S1 |

## Dependency Legend

- **S0** = Section 0 completed (environment detected)
- **S1** = Section 1 completed (scaffolding artifacts exist under `res://sv2_validation/`)
- **S2** = Section 2 completed (nodes exist in `res://sv2_validation/main.tscn`)
- **None** = Fully standalone, can run independently

## Regression Watch Summary

The sweep includes **37 REGRESSION WATCH** annotations covering DX fixes, bug fixes, and parameter renames from the 41k + 41l validation clusters. These appear inline in the relevant section files. If a test marked with REGRESSION WATCH fails, it indicates a previously-fixed behavior has regressed — flag prominently.

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
- **Mode:** standard | read-only
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
