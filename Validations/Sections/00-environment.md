# Section 0 — Environment Detection

**Dependencies:** None
**Tools tested:** project_get_settings, asset_list, discover_tools, editor_get_console

Before running any test, gather project context. Record these in your report header.

---

**0.1** Call `project_get_settings` — extract:
- `application/config/name` — project name
- `application/run/main_scene` — current main scene (save for restore)
- `application/config/features` — Godot version (e.g. `"4.5"`, `"4.6"`)
- Check for `dotnet/project/assembly_name` — if present, this is a C# (.NET) project

**0.2** Call `asset_list` with path_prefix=`res://` — scan for `.csproj` or `.cs` files. If found alongside the dotnet setting, confirm **C# project**. Otherwise, **GDScript project**.

**0.3** Activate all on-demand tool groups:
- Call `discover_tools` with groups: `["runtime_advanced", "signals", "animation_authoring", "input_map", "asset_ops", "user_data", "scene_advanced", "editor_advanced", "tilemap", "theme"]`
- **Note:** the group is named `asset_ops`, not `asset_management`. There is no `node_management` group — `node_manage` and `node_groups` are **core** tools (always available, no `discover_tools` activation needed).
- Verify `execute_code` and `node_call_method` are available

**0.4** If C# project detected, call `editor_get_console` with level_filter `["error"]` — check for C# build errors. If present, warn the user that C# scripts may not work correctly until the solution is built.

**0.5** Detect version-specific capabilities (from features string):
| Feature | 4.2 | 4.3 | 4.4 | 4.5+ |
|---|---|---|---|---|
| TileMapLayer node | No (use TileMap) | Yes | Yes | Yes |
| scene_close | No | No | No | Yes (active tab only) |
| Logger API (buffer source) | File-dependent | File-dependent | File-dependent | Yes |

Record: `Godot X.Y | GDScript or C# | Main scene`

**0.6** Detect version-gated tools:
- From the `discover_tools` response or tool list, check for `scene.close` visibility:
  - **Godot 4.5+:** `scene.close` should be available (registered with `min_godot_version: "4.5"`)
  - **Godot 4.2–4.4:** `scene.close` should NOT appear in the tool list
- If version info is available in `project_get_settings` features, cross-reference: the tool visibility must match the detected version.

**0.7** Detect extension version bounds:
- If any extensions are loaded with `min_godot_version` or `max_godot_version` annotations, verify:
  - Tools outside the current Godot version range are hidden from the tool list
  - Tools within range are visible
- **Note:** This test is informational — if no version-bounded extensions exist, record "N/A" and move on. The version-gate mechanism is verified by `scene.close` behavior above.

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

None needed — this section only reads state.
