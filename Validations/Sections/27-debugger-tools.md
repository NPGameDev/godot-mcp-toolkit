# Section 27 — Debugger Tools (Breakpoint Management & Debug State)

**Dependencies:** Section 1 (`res://sv2_validation/` exists), Section 6 (script files available)
**Tools tested:** debug_state, debug_list_breakpoints, debug_set_breakpoint, debug_continue
**Groups to activate:** debugger
**Prerequisite:** Godot editor running with plugin enabled
**Tests:** 16 + 1 combo chain

---

## Setup

**27-S1.** `script_write` — file_path=`res://sv2_validation/sv2_debug_target.gd`, content:
```gdscript
extends Node2D

var counter: int = 0

func _ready() -> void:
	counter = 1
	print("counter = ", counter)

func _process(delta: float) -> void:
	counter += 1
```
- **Expect:** success

**27-S2.** `editor_refresh` — file_paths=`["res://sv2_validation/sv2_debug_target.gd"]`
- **Expect:** success

**27-S3.** `discover_tools` — groups=`["debugger"]`
- **Expect:** `debugger` group activated, 4 tools available:
  debug_state, debug_list_breakpoints, debug_set_breakpoint, debug_continue

---

## debug_state

**27.1** `debug_state` — (no params, no game running)
- **Expect:** success=true, active=false, breaked=false, can_debug=false

---

## debug_set_breakpoint

**27.2** `debug_set_breakpoint` — file_path=`res://sv2_validation/sv2_debug_target.gd`, line=6, enabled=true
- **Expect:** success=true, file_path=`res://sv2_validation/sv2_debug_target.gd`, line=6, enabled=true

**27.3** `debug_set_breakpoint` — file_path=`res://sv2_validation/sv2_debug_target.gd`, line=9, enabled=true
- **Expect:** success=true, line=9, enabled=true (second breakpoint on different line)

---

## debug_list_breakpoints

**27.4** `debug_list_breakpoints` — (no params)
- **Expect:** success=true, breakpoints array includes:
  - `{ file_path: "res://sv2_validation/sv2_debug_target.gd", line: 6 }`
  - `{ file_path: "res://sv2_validation/sv2_debug_target.gd", line: 9 }`
- count ≥ 2

---

## Breakpoint clear cycle

**27.5** `debug_set_breakpoint` — file_path=`res://sv2_validation/sv2_debug_target.gd`, line=6, enabled=false
- **Expect:** success=true, enabled=false

**27.6** `debug_list_breakpoints` — (no params)
- **Expect:** success=true, breakpoints should NOT include line 6, but SHOULD include line 9.
  Confirms individual breakpoint clearing works.

**27.7** `debug_set_breakpoint` — file_path=`res://sv2_validation/sv2_debug_target.gd`, line=9, enabled=false
- **Expect:** success=true, enabled=false

**27.8** `debug_list_breakpoints` — (no params)
- **Expect:** success=true, no breakpoints remain for sv2_debug_target.gd (count may be 0 or
  only contain breakpoints from other open files)

---

## Guards

**27.9** `debug_set_breakpoint` — file_path=`res://sv2_validation/test.cs`, line=1
- **Expect:** success=false, code=`UNSUPPORTED_FILE_TYPE`, error mentions "GDScript" and "IDE"

**27.10** `debug_set_breakpoint` — file_path=`res://sv2_validation/test.txt`, line=1
- **Expect:** success=false, code=`UNSUPPORTED_FILE_TYPE`, error mentions "GDScript"

**27.11** `debug_set_breakpoint` — file_path=`C:/Users/test/script.gd`, line=1
- **Expect:** success=false, code=`INVALID_PATH`, error mentions "res://"

**27.12** `debug_set_breakpoint` — file_path=`res://sv2_validation/nonexistent.gd`, line=1
- **Expect:** success=false, code=`NOT_FOUND`

**27.13** `debug_set_breakpoint` — file_path=`res://sv2_validation/sv2_debug_target.gd`, line=0
- **Expect:** success=false, code=`INVALID_PARAMS`, error mentions "line"

**27.14** `debug_set_breakpoint` — file_path=`res://sv2_validation/sv2_debug_target.gd`, line=9999
- **Expect:** success=false, code=`INVALID_PARAMS`, error mentions "exceeds"

---

## debug_continue

**27.15** `debug_continue` — (no params, no game running)
- **Expect:** success=false, code=`GAME_NOT_RUNNING`, error mentions "game.start"

**27.16** (Conditional — only if a game is running but NOT breaked)
`debug_continue` — (no params, game running but not paused)
- **Expect:** success=false, code=`NOT_BREAKED`, error mentions "breakpoint"
- **Note:** This test requires starting a game without hitting a breakpoint.
  If not practical during the sweep, mark as SKIP and verify during interactive validation.

---

## Combo Chains

### C26. Set breakpoint → start scene → hit breakpoint → continue → stop

1. `scene_create` — scene_path=`res://sv2_validation/sv2_debug_scene.tscn`, root_type=`Node2D`
   - **Expect:** success=true
2. `node_set_script` — node_path=`.`, file_path=`res://sv2_validation/sv2_debug_target.gd`
   - **Expect:** success=true (attaches the script with `_ready` breakpoint target)
3. `editor_save_scene`
   - **Expect:** success=true
4. `debug_set_breakpoint` — file_path=`res://sv2_validation/sv2_debug_target.gd`, line=6, enabled=true
   - **Expect:** success=true (breakpoint on `counter = 1` inside `_ready`)
5. `game_start` — scene_path=`res://sv2_validation/sv2_debug_scene.tscn`
   - **Expect:** success=true. Game launches and pauses at the breakpoint because
     `_ready()` executes immediately and line 6 is inside it.
6. `debug_state`
   - **Expect:** success=true, active=true, breaked=true, can_debug=true
7. `debug_continue`
   - **Expect:** success=true (game resumes past the breakpoint)
8. `debug_state`
   - **Expect:** active=true, breaked=false (game running, no longer paused)
9. `game_stop`
10. `debug_set_breakpoint` — file_path=`res://sv2_validation/sv2_debug_target.gd`, line=6, enabled=false
    - **Expect:** success=true (clean up breakpoint)
11. `debug_state` — **Expect:** active=false (game stopped)

---

## Cleanup

- `debug_set_breakpoint` res://sv2_validation/sv2_debug_target.gd, line=6, enabled=false (if set)
- `debug_set_breakpoint` res://sv2_validation/sv2_debug_target.gd, line=9, enabled=false (if set)
- `scene_delete` res://sv2_validation/sv2_debug_scene.tscn (if created in C26)
- `script_delete` res://sv2_validation/sv2_debug_target.gd
- `discover_tools` with reset=`["debugger"]`
