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

**0.2** Call `asset_list` with folder_path=`res://` — scan for `.csproj` or `.cs` files. If found alongside the dotnet setting, confirm **C# project**. Otherwise, **GDScript project**.

**0.3** Check available tools — attempt to list tools or check if `execute_code` is available:
- If `execute_code` and `node_call_method` are available: **power_user** profile
- If tools are missing: note the profile. Suggest the user switch to `power_user` for a complete sweep. Ask how to proceed:
  - (A) Skip gated/unavailable tools
  - (B) Wait for user to enable them
  - (C) Switch to power_user profile
- If tool groups need loading (non-power_user), call `discover_tools` with groups: `["runtime_advanced", "signals", "animation_authoring", "input_map", "asset_management", "user_data", "scene_advanced", "editor_advanced", "tilemap", "theme", "node_management"]`

**0.4** If C# project detected, call `editor_get_console` with level_filter `["error"]` — check for C# build errors. If present, warn the user that C# scripts may not work correctly until the solution is built.

**0.5** Detect version-specific capabilities (from features string):
| Feature | 4.2 | 4.3 | 4.4 | 4.5+ |
|---|---|---|---|---|
| TileMapLayer node | No (use TileMap) | Yes | Yes | Yes |
| scene_close | No | No | No | Yes (active tab only) |
| Logger API (buffer source) | File-dependent | File-dependent | File-dependent | Yes |

Record: `Godot X.Y | GDScript or C# | Profile | Main scene`

---

## Cleanup

None needed — this section only reads state.
