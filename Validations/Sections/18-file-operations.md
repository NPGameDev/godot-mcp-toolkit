# Section 18 — Phantom Tab Cleanup & File Operations

**Dependencies:** Section 1 (main.tscn exists)
**Tools tested:** scene_close, scene_delete, file_delete, folder_delete, asset_import, scene_open
**Tests:** 16

---

**18.1** `scene_create` — file_path=`res://sv2_validation/probe.tscn`, root_type=`Node2D`
- **Expect:** success

**18.2** `scene_open` — file_path=`res://sv2_validation/probe.tscn` (now active tab)
- **Expect:** success

**18.3** **[4.5+]** `scene_close` — file_path=`res://sv2_validation/main.tscn` (non-active tab)
- **Expect:** success — non-active tab closed. Response includes `hint` about `_set_main_scene_state` engine noise.

**18.4** **[4.5+]** `scene_delete` — file_path=`res://sv2_validation/probe.tscn` (active tab)
- **Expect:** success, `tab_closed: true` — active tab auto-closed before deletion. No hint (active tab doesn't switch).

**18.5** Recreate probe for further tests:
- `scene_create` file_path=`res://sv2_validation/probe.tscn`, root_type=`Node2D`
- `scene_open` file_path=`res://sv2_validation/main.tscn` (make main active)
- `scene_open` file_path=`res://sv2_validation/probe.tscn` (open probe as non-active... then switch to main)
- `scene_open` file_path=`res://sv2_validation/main.tscn`
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
2. Call `asset_import` file_path=`res://sv2_validation/icon_test.svg`
- **Expect:** success, class=CompressedTexture2D (imported immediately)

**18.11** **[4.5+]** `file_delete` on `.tscn` with open tab:
- `scene_create` file_path=`res://sv2_validation/file_del_probe.tscn`, root_type=`Node2D`
- `scene_open` file_path=`res://sv2_validation/file_del_probe.tscn`
- `scene_open` file_path=`res://sv2_validation/main.tscn` (main active, probe non-active)
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
- `scene_open` both + ensure main.tscn is also open
- `scene_open` file_path=`res://sv2_validation/main.tscn` (main active)
- `folder_delete` folder_path=`res://sv2_validation/del_folder`, recursive=true
- **Expect:** success, `stale_tabs` array has 2 entries, hint mentions `_set_main_scene_state`
- Call `scene_close` on each stale tab path
- **Expect:** both close successfully

**18.14** **[4.5+]** `scene_close` on last tab:
- Close all tabs except one: close main.tscn if other tabs exist
- Close the final remaining tab
- **Expect:** success — engine auto-creates empty scene tab

**18.15** Restore main scene: `scene_open` file_path=`res://sv2_validation/main.tscn`
- **Expect:** success

---

## Console error check

Call `editor_get_console` and scan output since section start for unexpected errors.
- **FAIL** if any line contains: `UndoRedo history mismatch`, `SCRIPT ERROR`, `FATAL`, or unexpected `ERROR:` lines not caused by intentional guard tests.
- **PASS** if only expected noise (e.g., `Failed loading resource` from NOT_FOUND guard tests).
- Note: expected errors from guard tests (e.g., loading nonexistent resources) are NOT failures.

## Cleanup

- `file_delete` file_path=`res://sv2_validation/icon_test.svg`
- Call `discover_tools` with reset=true to deactivate all on-demand groups activated during this section
