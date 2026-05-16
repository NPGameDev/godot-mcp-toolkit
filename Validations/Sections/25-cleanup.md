# Section 25 — Global Cleanup

**Dependencies:** Any (can run standalone to clean up after failed sweep)
**Purpose:** Remove ALL sv2_validation artifacts and restore project state

---

## 25a. Re-activate groups if needed

If `discover_tools(reset=true)` was run during the sweep, re-activate groups needed for cleanup:
```
discover_tools groups=["asset_management", "input_map", "node_management"]
```

## 25b. Stop game if running

`game_stop` (if game is currently running)

## 25c. Open original main scene

`scene_open` — open the original main scene saved in Section 0 report header. This makes it the active tab.

## 25d. Delete files (order: scripts → resources → scenes → folders)

1. **C# scripts** (if applicable):
   - `script_delete` res://sv2_validation/Sv2CsNode.cs
   - `script_delete` res://sv2_validation/Sv2CsGlobal.cs
   - `script_delete` res://sv2_validation/Sv2CsTemp.cs (if exists)

2. **GDScript:**
   - `script_delete` res://sv2_validation/actor.gd

3. **Shader:**
   - `file_delete` res://sv2_validation/shader.gdshader

4. **SVG:**
   - `file_delete` res://sv2_validation/icon_test.svg (if exists)

5. **Resources:** `resource_delete` for each .tres in sv2_validation/
   - Use `asset_list` folder_path=res://sv2_validation/, name_glob=*.tres to find all

6. **Scenes:** `scene_delete` for each .tscn in sv2_validation/
   - Use `asset_list` folder_path=res://sv2_validation/, name_glob=*.tscn to find all

7. **Subfolders:** `folder_delete` for any subdirs
   - c12_tabs/, etc.

8. **Root folder:** `folder_delete` folder_path=`res://sv2_validation/`, recursive=true

## 25e. Restore project settings

1. `project_set_setting` application/config/name → original (from Section 0)
2. `project_set_setting` application/run/main_scene → original (from Section 0)

## 25f. Remove audio buses

`audiobus_edit` action=remove_bus for any buses matching `Sv2*` (if Section 15 cleanup was skipped)

## 25g. Remove input map actions

`input_map_action` name=sv2_jump, operation=remove (if Section 10 cleanup was skipped)

## 25h. Remove save data

`save_delete` save_path=user://saves/sv2_save.json (if exists)

## 25i. Verify cleanup

`asset_list` folder_path=`res://sv2_validation/` → **Expect:** NOT_FOUND or empty (folder deleted)

---

## Notes

- Run this section if a previous sweep failed mid-way and left artifacts
- Safe to run multiple times (all operations are idempotent — NOT_FOUND on already-deleted items is fine)
- If `scene_delete` fails with EDITED_SCENE, `scene_open` a different scene first
