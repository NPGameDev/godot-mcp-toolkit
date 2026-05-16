# Section 18 — Scene Close/Delete Guards & File Operations

**Dependencies:** Section 1 (main.tscn exists)
**Tools tested:** scene_close, scene_delete, file_delete, asset_import, scene_open
**Tests:** 10

---

**18.1** `scene_create` — file_path=`res://sv2_validation/probe.tscn`, root_type=`Node2D`
- **Expect:** success

**18.2** `scene_open` — file_path=`res://sv2_validation/probe.tscn` (now active tab)
- **Expect:** success

**18.3** **[4.5+]** `scene_close` — file_path=`res://sv2_validation/main.tscn` (inactive tab)
- **Expect:** Error with hint: "scene.close only closes the active tab ... use scene.delete directly"

**18.4** `scene_delete` — file_path=`res://sv2_validation/probe.tscn` (active tab)
- **Expect:** EDITED_SCENE error — cannot delete the currently-edited scene

**18.5** `scene_open` — file_path=`res://sv2_validation/main.tscn` (switch back, probe now inactive)
- **Expect:** success

**18.6** `scene_delete` — file_path=`res://sv2_validation/probe.tscn` (now inactive)
- **Expect:** success — file deleted

**18.7** `file_delete` — file_path=`res://sv2_validation/shader.gdshader`
- **Expect:** success, deindexed:true

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

---

## Cleanup

- `file_delete` file_path=`res://sv2_validation/icon_test.svg`
- If `asset_management` group was activated for this section: call `discover_tools` with reset=["asset_management"] to deactivate it
