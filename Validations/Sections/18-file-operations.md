# Section 18 — Phantom Tab Cleanup & File Operations

**Dependencies:** Section 1 (Sv2Main.tscn exists)
**Tools tested:** scene_close, scene_delete, file_delete, folder_delete, asset_import, scene_open
**Tests:** 16

---

**18.1** `scene_create` — file_path=`res://sv2_validation/probe.tscn`, root_type=`Node2D`
- **Expect:** success

**18.2** `scene_open` — file_path=`res://sv2_validation/probe.tscn` (now active tab)
- **Expect:** success

**18.3** **[4.5+]** `scene_close` — file_path=`res://sv2_validation/Sv2Main.tscn` (non-active tab)
- **Expect:** success — non-active tab closed. Response includes `hint` about `_set_main_scene_state` engine noise.

**18.4** **[4.5+]** `scene_delete` — file_path=`res://sv2_validation/probe.tscn` (active tab)
- **Expect:** success, `tab_closed: true` — active tab auto-closed before deletion. **A `hint` DOES fire here too** (reconfirmed across multiple runs, incl. 4.7) — do not treat its presence as a failure; the earlier "no hint on active-tab delete" expectation was itself stale.

**18.5** Recreate probe for further tests:
- `scene_create` file_path=`res://sv2_validation/probe.tscn`, root_type=`Node2D`
- `scene_open` file_path=`res://sv2_validation/Sv2Main.tscn` (make main active)
- `scene_open` file_path=`res://sv2_validation/probe.tscn` (open probe as non-active... then switch to main)
- `scene_open` file_path=`res://sv2_validation/Sv2Main.tscn`
- **Expect:** all succeed, main is active, probe is open but non-active

**18.6** `scene_delete` — file_path=`res://sv2_validation/probe.tscn` (non-active open tab)
- **Expect:** success, `tab_closed: true`, hint present about `_set_main_scene_state`

**18.7** `file_delete` — file_path=`res://sv2_validation/shader.gdshader`
- **Expect:** success, deindexed:true, no tab_closed field (not a scene file)

**18.8** Recreate shader for later sections: `script_write` — file_path=`res://sv2_validation/shader.gdshader`, same content as Section 1.4
- **Expect:** success

**18.9** `resource_load` — file_path=`res://sv2_validation/material.tres`
- **Expect:** success (shader reference valid after recreate)

**18.10** `asset_import` — Create SVG then import:
1. Write file at `res://sv2_validation/icon_test.svg` (use Write tool, not MCP):
```svg
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="#478cbf"/></svg>
```
2. Call `asset_import` dest_path=`res://sv2_validation/icon_test.svg`, source_path=`res://sv2_validation/icon_test.svg`, if_exists=`replace`, wait_for_scan_ms=`5000`
- **Expect:** success, status=`created` or `replaced`, class=CompressedTexture2D.
- **Param + timing notes:** the JSON schema only marks `dest_path` as required, but **`source_path` or `base64_data` is mandatory at runtime** — a `dest_path`-only call fails with `INVALID_PARAMS`; always pass one of them. If the file was pre-indexed by the FS watcher (e.g. via a raw `Write`-tool file drop) before this call, the response may still report `class:null` until the scan settles — indexing can take longer than a short `wait_for_scan_ms`; **5000ms is a more reliable wait** than shorter values (timing-variance, not a functional bug). If it still reports `class:null`, call `editor_wait_for_idle` and retry `resource_load`.

**18.11** **[4.5+]** `file_delete` on `.tscn` with open tab:
- `scene_create` file_path=`res://sv2_validation/file_del_probe.tscn`, root_type=`Node2D`
- `scene_open` file_path=`res://sv2_validation/file_del_probe.tscn`
- `scene_open` file_path=`res://sv2_validation/Sv2Main.tscn` (main active, probe non-active)
- `file_delete` file_path=`res://sv2_validation/file_del_probe.tscn`
- **Expect:** success, `tab_closed: true`, hint about `_set_main_scene_state`

**18.12** **[4.5+]** `folder_delete` with 1 scene inside:
- `folder_create` folder_path=`res://sv2_validation/del_folder`
- `scene_create` file_path=`res://sv2_validation/del_folder/inner.tscn`, root_type=`Node2D`
- `scene_open` file_path=`res://sv2_validation/del_folder/inner.tscn`
- `folder_delete` folder_path=`res://sv2_validation/del_folder`, recursive=true
- **Expect:** success, `tab_closed` = `res://sv2_validation/del_folder/inner.tscn`, no `stale_tabs`

**18.13** **[4.5+]** `folder_delete` with 2 scenes → stale_tabs follow-up:
- `folder_create` folder_path=`res://sv2_validation/del_folder`
- `scene_create` 2 scenes inside (`inner1.tscn`, `inner2.tscn`)
- `scene_open` both + ensure Sv2Main.tscn is also open
- `scene_open` file_path=`res://sv2_validation/Sv2Main.tscn` (main active)
- `folder_delete` folder_path=`res://sv2_validation/del_folder`, recursive=true
- **Expect:** success, `stale_tabs` array has 2 entries, hint mentions `_set_main_scene_state`
- Call `scene_close` on each stale tab path
- **Expect:** both close successfully

> **4.2–4.4 hint variant (version-aware).** The stale-tabs `hint` is keyed on
> `EditorInterface.has_method("close_scene")` (4.5+). On **4.2–4.4** (no close API)
> the hint does NOT name `scene_close` (that tool is 4.5+-only) — it instead says
> Godot 4.2–4.4 has no API to close scene tabs and to restart the editor to clear
> them. A 4.2 run of this flow should see that variant, not the `_set_main_scene_state`
> wording. (This whole case is `[4.5+]` because the `scene_close` follow-up is 4.5+;
> the hint-variant note documents the 4.2–4.4 behavior for the routine 4.2 sweep.)

**18.14** **[4.5+]** `scene_close` on last tab:
- Close all tabs except one: close Sv2Main.tscn if other tabs exist
- Close the final remaining tab
- **Expect:** success — engine auto-creates empty scene tab

**18.15** Restore main scene: `scene_open` file_path=`res://sv2_validation/Sv2Main.tscn`
- **Expect:** success

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- `file_delete` file_path=`res://sv2_validation/icon_test.svg`
- Call `discover_tools` with reset=true to deactivate all on-demand groups activated during this section
