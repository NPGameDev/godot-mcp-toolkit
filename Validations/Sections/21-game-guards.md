# Section 21 — game_start Guards & Crash Recovery

**Dependencies:** Section 1 (sv2_validation/ exists)
**Tools tested:** game_start (guards), debugger_get_log (crash recovery cache, debug_state, error_buffer, log_scan)
**Tests:** 13

---

### Parse-error game launch (existing)

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

---

### Editor-side fallback + debug_state (41l-quater-bis)

**21.4** Restore and run valid game:
- `project_set_setting` application/run/main_scene = `"res://sv2_validation/main.tscn"`
- `scene_open` file_path=`res://sv2_validation/main.tscn`
- `game_start`
- **Expect:** success (valid scene launches)
- Wait 2s, then `game_stop`

**21.5** `debugger_get_log` — cached log + debug_state after clean stop
- **Expect:** success=true (not GAME_NOT_RUNNING), `lines` has log content from the just-ended session, `debug_state` present with `active: false`.

> **REGRESSION WATCH (dec5b24):** If debugger_get_log returns empty or NOT_FOUND
> immediately after game_stop, the editor-side log cache has regressed. The cache
> should persist until the next game_start clears it. Flag as **Major**.

> **REGRESSION WATCH (41l-quater-bis, e2c7041):** If debugger_get_log returns
> GAME_NOT_RUNNING after game_stop, the server-side fallback is broken — it
> should route to the editor-side handler, not reject the call. Flag as **Critical**.

**21.6** `debugger_get_log` — text_filter=`SV2_BROKEN`, is_regex=`false`
- **Expect:** count=0 (the broken scene never printed anything — validates filter on cached log)

---

### Runtime error capture via log_scan (41l-quater-bis)

Tests both paths: old (log file `lines`) and new (`error_buffer` + `debug_state`).
The `error_buffer` is populated by scanning unfiltered log lines for error patterns,
so it always has full source location context regardless of `text_filter`.

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

**21.10** `debugger_get_log` — unfiltered error capture (both paths)
- **Expect (old path):** `lines` array includes null-ref error text (SCRIPT ERROR with queue_free)
- **Expect (new path):**
  - `debug_state` present: `{active: false, breaked: false, can_debug: false}`
  - `error_buffer` array present with >= 1 entry
  - Entry `type`: `"log_scan"` (expected on Godot 4.0–4.5; `"error"` or `"break"` also valid)
  - Entry `message`: contains the null-ref error text
  - Entry `source`: file path (e.g. `res://sv2_validation/sv2_error_main.gd`)
  - Entry `function`: function name (e.g. `_ready`)
  - Entry `line`: line number > 0 (e.g. `4`)

> **NOTE:** On Godot 4.0–4.5, `EditorDebuggerPlugin._capture("error")` does NOT fire
> for built-in error messages (ScriptEditorDebugger handles them first). The `log_scan`
> fallback parses SCRIPT ERROR / USER SCRIPT ERROR / ERROR lines with their adjacent
> "at:" lines from the unfiltered log. This is the expected path on current Godot versions.

**21.11** `debugger_get_log` — text_filter=`queue_free`, is_regex=`false`
- **Expect:** count >= 1 (the null-ref error mentions queue_free)
- **Expect:** `error_buffer` present with same source/function/line as 21.10 — the error scan runs on unfiltered log lines, so `text_filter` does NOT strip context from `error_buffer` entries.

> **REGRESSION WATCH (8a6cbf0):** If `error_buffer` entries have empty `source`/`line`
> when `text_filter` is active, the unfiltered-scan fix has regressed — `_merge_debug_bridge_data`
> is scanning filtered lines instead of the full log. Flag as **Major**.

**21.12** `debugger_get_log` — text_filter=`NONEXISTENT_STRING_12345`, is_regex=`false`
- **Expect:** count=0 (no lines match), but `error_buffer` still present with the error entry (scanned from unfiltered log, unaffected by filter).

> This verifies the error_buffer and lines are independent: the filter empties `lines`
> but `error_buffer` is built from the full unfiltered log and always reflects all errors.

**21.13** `debugger_get_log` — no parameters (verify all fields present in default call)
- **Expect:** success=true, `lines` (all game output), `debug_state` present, `error_buffer` present with full context. This is the "agent calls debugger_get_log with no args after a crash" golden path.

---

## Console error check

Call `editor_get_console` and scan output since section start for `UndoRedo history mismatch`. Guard tests produce intentional error logs (e.g., `Failed loading resource`) — ignore those.
- **FAIL** if any `UndoRedo history mismatch` line appears.
- **PASS** otherwise.

## Cleanup

- `scene_open` file_path=`res://sv2_validation/main.tscn`
- `scene_delete` file_path=`res://sv2_validation/sv2_error.tscn`
- `script_delete` file_path=`res://sv2_validation/sv2_error_main.gd`
- `scene_delete` file_path=`res://sv2_validation/sv2_broken.tscn`
- `script_delete` file_path=`res://sv2_validation/sv2_broken_main.gd`
- `project_set_setting` — restore application/run/main_scene to original
