# Section 21 — game_start Guards & Crash Recovery

**Dependencies:** Section 1 (sv2_validation/ exists)
**Tools tested:** game_start (guards), debugger_get_log (crash recovery cache, debug_state, error_buffer)
**Tests:** 12

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
- **Expect:** success=true (game launches — Godot does NOT block launch for individual broken node scripts)
- **Known limitation:** The COMPILATION_FAILED check (4be3454) only fires when the game process completely fails to start (e.g., missing main scene). Individual script errors manifest at runtime, not pre-launch. The agent discovers them via `debugger_get_log` after launch.

**21.3b** `debugger_get_log` — immediately after 21.3's game_start
- **Expect:** contains GDScript parse error for sv2_broken_main.gd (the error surfaces in runtime logs)

**21.3c** `game_stop`
- **Expect:** success

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

**21.5b** `debugger_get_log` — verify `debug_state` field on 21.5's response
- **Expect:** response includes `debug_state` with `active: false` (game just stopped). If `debug_state` is missing, the debug bridge integration has regressed.

> **REGRESSION WATCH (41l-quater-bis):** `debug_state` must be present in every
> editor-side debugger_get_log response when the debug bridge is active. Its
> absence indicates the bridge was not injected into PlaytestCommands. Flag as **Major**.

**21.6** `debugger_get_log` — text_filter=`SV2_BROKEN`, is_regex=`false`
- **Expect:** count=0 (the broken scene never printed anything — validates filter on cached log)

---

### Error capture via debugger bridge (41l-quater-bis)

Tests both paths: old (log file lines) and new (error_buffer + debug_state).

**21.7** Write error-triggering script: `script_write` file_path=`res://sv2_validation/sv2_error_main.gd`, content:
```gdscript
extends Node2D

func _ready():
	# Triggers null-ref at runtime — not a parse error but an execution error.
	var n: Node = null
	n.queue_free()
```
- **Expect:** success

**21.8** Create scene + launch with error script:
- `scene_create` file_path=`res://sv2_validation/sv2_error.tscn`, root_type=`Node2D`
- `scene_open` file_path=`res://sv2_validation/sv2_error.tscn`
- `node_set_script` node_path=`.`, script_path=`res://sv2_validation/sv2_error_main.gd`
- `editor_save_scene`
- `project_set_setting` application/run/main_scene = `"res://sv2_validation/sv2_error.tscn"`
- `game_start`
- **Expect:** all succeed, game launches (runtime error is non-fatal in Godot)

**21.9** Wait 2-3s, then `game_stop`
- **Expect:** success

**21.10** `debugger_get_log` — error capture + old-path check
- **Expect (old path — always works):** `lines` array includes null-ref error text from log file
- **Expect (new path):** `debug_state` present with `active: false`. `error_buffer` array present with at least one entry containing the null-ref error. Entry type depends on which capture path fired:
  - `"error"` — `_capture` intercepted the debugger protocol message (ideal, version-dependent)
  - `"break"` — `_on_breaked` fallback fired (requires "Break on Errors" enabled)
  - `"log_scan"` — log-line scanning parsed error patterns from the log file (reliable fallback)
- `error_buffer` entries should include `message`, `source` (file path), `function`, and `line` fields.

> **NOTE:** On Godot 4.0-4.5, `_capture("error")` does NOT fire for built-in error
> messages (ScriptEditorDebugger handles them first). The `log_scan` fallback parses
> SCRIPT ERROR / USER SCRIPT ERROR / ERROR lines from the log file with "at:" location.
> This is the expected path on current Godot versions.

**21.11** `debugger_get_log` — text_filter=`queue_free`, is_regex=`false` (filter on error output)
- **Expect:** count >= 1 (the null-ref error mentions queue_free)

**21.12** `debugger_get_log` — verify `debug_state` field on error-capture response
- **Expect:** `debug_state.active` = false, `debug_state.breaked` = false (game stopped, not paused)

---

## Cleanup

- `scene_open` file_path=`res://sv2_validation/main.tscn`
- `scene_delete` file_path=`res://sv2_validation/sv2_error.tscn`
- `script_delete` file_path=`res://sv2_validation/sv2_error_main.gd`
- `scene_delete` file_path=`res://sv2_validation/sv2_broken.tscn`
- `script_delete` file_path=`res://sv2_validation/sv2_broken_main.gd`
- `project_set_setting` — restore application/run/main_scene to original
