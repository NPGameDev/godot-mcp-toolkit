# Section 21 — game_start Guards & Crash Recovery

**Dependencies:** Section 1 (sv2_validation/ exists)
**Tools tested:** game_start (guards), debugger_get_log (crash recovery cache)
**Tests:** 6

---

**21.1** Write broken script: `script_write` file_path=`res://sv2_validation/sv2_broken_main.gd`, content:
```gdscript
extends Node2D

func _ready():
	var x = {
```
- **Expect:** success (write succeeds, `valid: false` in diagnostics)

**21.2** Create scene with broken script:
- `scene_create` file_path=`res://sv2_validation/sv2_broken.tscn`, root_type=`Node2D`
- `scene_open` file_path=`res://sv2_validation/sv2_broken.tscn`
- `node_set_script` node_path=`.`, script_path=`res://sv2_validation/sv2_broken_main.gd`
- `editor_save_scene`
- `project_set_setting` application/run/main_scene = `"res://sv2_validation/sv2_broken.tscn"`
- **Expect:** all succeed

**21.3** `game_start` — with broken main scene script
- **Expect:** COMPILATION_FAILED error with hints about the script error

> **REGRESSION WATCH (4be3454):** If game_start succeeds (launches broken game)
> instead of catching the compilation failure pre-launch, the compilation check
> has regressed. Flag as **Critical**.

**21.4** Restore and run valid game:
- `project_set_setting` application/run/main_scene = `"res://sv2_validation/main.tscn"`
- `scene_open` file_path=`res://sv2_validation/main.tscn`
- `game_start`
- **Expect:** success (valid scene launches)
- Wait 2s, then `game_stop`

**21.5** `debugger_get_log` — (after game_stop, check cached log)
- **Expect:** success, log content available from the just-ended session

> **REGRESSION WATCH (dec5b24):** If debugger_get_log returns empty or NOT_FOUND
> immediately after game_stop, the editor-side log cache has regressed. The cache
> should persist until the next game_start clears it. Flag as **Major**.

**21.6** `debugger_get_log` — text_filter=`SV2_BROKEN`, is_regex=`false`
- **Expect:** count=0 (the broken scene never printed anything — validates filter on cached log)

---

## Cleanup

- `scene_open` file_path=`res://sv2_validation/main.tscn`
- `scene_delete` file_path=`res://sv2_validation/sv2_broken.tscn`
- `script_delete` file_path=`res://sv2_validation/sv2_broken_main.gd`
- `project_set_setting` — restore application/run/main_scene to original
