# Section 0 — Environment Detection

**Dependencies:** None
**Tools tested:** project_get_settings, asset_list, discover_tools, editor_get_console

Before running any test, gather project context. Record these in your report header.

> **The running Godot version is established by the [Version Preflight](../tool-sweep.md#version-preflight) (mandatory, run once before this section) — that is the authoritative source. The reads below record the project's *declared* metadata; wherever they touch version, defer to the Preflight, never the `features` string.**

---

**0.1** Call `project_get_settings` — extract:
- `application/config/name` — project name
- `application/run/main_scene` — current main scene (save for restore)
- `application/config/features` — the project's **declared floor**, NOT the running engine (a newer editor opens an older-tagged project without changing it). Record it only as the declared floor; the authoritative running version is the **[Version Preflight](../tool-sweep.md#version-preflight)** result, never this field.
- Check for `dotnet/project/assembly_name` — if present, this is a C# (.NET) project

**0.2** Call `asset_list` with path_prefix=`res://` — scan for `.csproj` or `.cs` files. If found alongside the dotnet setting, confirm **C# project**. Otherwise, **GDScript project**.

**0.3** Activate all on-demand tool groups:
- Call `discover_tools` with groups: `["runtime_advanced", "signals", "animation_authoring", "input_map", "asset_ops", "user_data", "scene_advanced", "editor_advanced", "tilemap", "theme"]`
- **Note:** the group is named `asset_ops`, not `asset_management`. There is no `node_management` group — `node_manage` and `node_groups` are **core** tools (always available, no `discover_tools` activation needed).
- Verify `execute_code` and `node_call_method` are available

**0.4** If C# project detected, call `editor_get_console` with level_filter `["error"]` — check for C# build errors. If present, warn the user that C# scripts may not work correctly until the solution is built.

**0.5** Detect version-specific capabilities (keyed to the **Version Preflight** result — NOT the `features` string):
| Feature | 4.2 | 4.3 | 4.4 | 4.5+ |
|---|---|---|---|---|
| TileMapLayer node | No (use TileMap) | Yes | Yes | Yes |
| scene_close | No | No | No | Yes (active tab only) |
| Logger API (buffer source) | File-dependent | File-dependent | File-dependent | Yes |

> **`TileMapLayer` (via `classdb_get_info`) present ⟹ engine ≥ 4.3 ONLY — it does not distinguish 4.3 / 4.4 / 4.5. `scene_close` visible in the live tools/list ⟹ engine ≥ 4.5; on 4.3 / 4.4 it is legitimately absent, and that absence means `< 4.5`, NOT a missing tool.**

Record: `Godot X.Y | GDScript or C# | Main scene` (X.Y from the Version Preflight)

**0.6** Detect version-gated tools (cross-check of the Version Preflight):
- In the **live tools/list** (not the static `discover_tools` catalogue), check `scene_close` visibility:
  - **Godot 4.5+:** `scene_close` IS present (registered with `min_godot_version: "4.5"`).
  - **Godot 4.2–4.4:** `scene_close` is **absent — and that absence is expected**, meaning `engine < 4.5`, NOT a missing/broken tool. (Absence alone is `< 4.5` *or* version-not-yet-resolved, so it only *cross-checks* the Preflight; the Preflight's `node_call_method` probe is authoritative.)
- Cross-reference against the **Version Preflight** version (never the `features` PSA): `scene_close` present must line up with Preflight ≥ 4.5. A mismatch → HALT and investigate.

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
