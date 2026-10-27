# Section 21 — game_start Guards & Crash Recovery

**Dependencies:** Section 1 (sv2_validation/ exists)
**Tools tested:** game_start (guards, error-break hint), debugger_get_log (crash recovery cache, debug_state, error_buffer, log_scan, latest debugger session)
**Tests:** 15

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
- **Expect:** success=true (game launches — Godot does NOT block launch for individual broken node scripts), `runtime_ready:false`, returned within a few seconds rather than after the 10 s wait, with the hint `The game is paused at a script error and cannot continue, so waiting won't help: Parser Error: <message>, at res://sv2_validation/sv2_broken_main.gd:<line>. Fix it, then game_stop and game_start.`
- **Known limitation:** The COMPILATION_FAILED check (4be3454) only fires when the game process completely fails to start (e.g., missing main scene). Individual script errors manifest at runtime, not pre-launch: the parse error stops the game at an error break before its runtime connects.

> **REGRESSION WATCH (toolkit #95):** the "game may need more time" hint, a wait of about 10 s, or an
> error-break hint with no `res://…:<line>` means `game_start` no longer reads the debugger's stop.
> Flag as **Major**.

**21.3b** `debugger_get_log` — immediately after 21.3's game_start
- **Expect (every version, 4.2 included):** success, `debug_state {active:true, breaked:true, can_debug:false}`, and `error_buffer` with one entry of `type:"break"`: its `message` starts `Game paused at a script error it cannot continue from: Parser Error:` and carries `, at res://sv2_validation/sv2_broken_main.gd:<line>.`; its `source` is that path and its `line` > 0. On Windows the game holds its log open, so `lines` is empty and a note says to stop the game and read again.
- **Note:** the parse error stops the game at an error break before it prints anything, so neither its log nor the editor's Errors tab has the text; the entry takes it from the editor's debugger.

**21.3c** `game_stop`
- **Expect:** success

---

### Editor-side fallback + debug_state (41l-quater-bis)

**21.4** Restore and run valid game:
- `project_set_setting` application/run/main_scene = `"res://sv2_validation/Sv2Main.tscn"`
- `scene_open` file_path=`res://sv2_validation/Sv2Main.tscn`
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
- **Expect:** all succeed, game launches. The null call stops the game at an error break. `game_start` usually returns `runtime_ready:true` with no hint, since the runtime connects before `_ready` runs; when the break comes first, it returns the error-break hint naming `res://sv2_validation/sv2_error_main.gd:6`. Either is a pass.

**21.9** Wait 2-3s, then `debugger_get_log`, then `game_stop`
- **Expect:** `debugger_get_log` succeeds with `debug_state {active:true, breaked:true, can_debug:false}` and an `error_buffer` entry of `type:"break"` whose `message` carries the null-call error, with `source` `res://sv2_validation/sv2_error_main.gd`, `function` `_ready` and `line` 6, on Windows, where the game holds its log; elsewhere on 4.5+ a `log_scan` entry with the same fields. `game_stop` succeeds.

**21.10** `debugger_get_log` — unfiltered error capture (both paths)
- **Expect (old path):** `lines` array includes null-ref error text (SCRIPT ERROR with queue_free); on 4.2–4.4 no SCRIPT ERROR line is written
- **Expect (new path):**
  - `debug_state` present: `{active: false, breaked: false, can_debug: false}`
  - `error_buffer` array present with >= 1 entry
  - Entry `type`: `"log_scan"` when the log holds the SCRIPT ERROR line; else `"break"`, the entry 21.9's error break recorded (Godot 4.2–4.4 write no SCRIPT ERROR line for it)
  - Entry `message`: contains the null-ref error text
  - Entry `source`: `res://sv2_validation/sv2_error_main.gd`
  - Entry `function`: `_ready`
  - Entry `line`: `6`

> **NOTE:** `EditorDebuggerPlugin._capture("error")` does NOT fire for built-in error
> messages (ScriptEditorDebugger handles them first). The `log_scan` fallback parses
> SCRIPT ERROR / USER SCRIPT ERROR / ERROR lines with their adjacent "at:" lines from the
> unfiltered log, and it replaces a buffer that holds only `break` entries when it finds
> any. The `break` entry takes its location from the editor debugger's stack, so it
> carries the same `source`/`function`/`line`.

**21.11** `debugger_get_log` — text_filter=`queue_free`, is_regex=`false`
- **Expect:** count >= 1 (the null-ref error mentions queue_free); 0 on Godot 4.2–4.4, whose log has no SCRIPT ERROR line
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

### Whose game the latest debugger session is

**21.14** A playtest the editor starts without `game_start` — `execute_code` channel=`editor`, code=`EditorInterface.play_custom_scene("res://sv2_validation/Sv2Main.tscn")`; wait 2s; `execute_code` channel=`editor`, code=`EditorInterface.stop_playing_scene()`; then `debugger_get_log`
- **Expect:** success, `lines` holds this run's log, `debug_state.active` false, and no note that no playtest has run. This is the path of the editor's Play buttons.

> **REGRESSION WATCH (toolkit #97):** a "no playtest" or "no game session" note, or the log of an earlier
> `game_start` run, means `debugger_get_log` reads only `game_start` runs again. Flag as **Major**.

**21.15** A one-click deploy with remote debug (**env-gated:** needs a one-click deploy target, such as an Android device or a Web export served locally, with Debug > Deploy with Remote Debug on; expected-SKIP on the dogfood machine without one)
- (a) Deploy the project from the editor's one-click deploy button; once its game attaches to the debugger, `debugger_get_log`.
  **Expect:** success with no `lines` and the note that the latest debugger session is a game this editor did not run on this machine, whose log stays with that game, and that `editor_get_console(source:"file")` reads the last local playtest. This machine's earlier playtest log is never served as the deploy's.
- (b) Deploy to a target whose game never attaches, then `debugger_get_log`.
  **Expect:** the last local playtest's log stays readable, as before the deploy.

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- `scene_open` file_path=`res://sv2_validation/Sv2Main.tscn`
- `scene_delete` file_path=`res://sv2_validation/sv2_error.tscn`
- `script_delete` file_path=`res://sv2_validation/sv2_error_main.gd`
- `scene_delete` file_path=`res://sv2_validation/sv2_broken.tscn`
- `script_delete` file_path=`res://sv2_validation/sv2_broken_main.gd`
- `project_set_setting` — restore application/run/main_scene to original
