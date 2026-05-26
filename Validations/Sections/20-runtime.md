# Section 20 — Game Start, Runtime & Debugging

**Dependencies:** Section 2 (main.tscn with nodes, script attached to Sv2Player)
**Tools tested:** game_start, game_stop, runtime_screenshot, runtime_get_node_state, runtime_get_script_vars, runtime_set_property, debugger_get_log, input_simulate, execute_code (runtime), animation_player_control, signal_emit
**Tests:** 22

---

**20.1** `project_set_setting` — setting=`application/run/main_scene`, value=`"res://sv2_validation/main.tscn"`
- **Expect:** success

**20.2** `editor_save_scene`
- **Expect:** success

**20.3** `game_start`
- **Expect:** success, game launches

> **REGRESSION WATCH (4be3454):** If game_start succeeds even when scripts have
> compile errors (should detect COMPILATION_FAILED and return error with hints),
> the compilation guard has regressed. Flag as **Critical**. Note: this test
> uses a valid scene — the guard is tested explicitly in Section 21.

**20.4** Observe `game_start` response — if called with wait_for_runtime=false, check for hint text about runtime initialization timing
- **Expect:** if wait_for_runtime=false was used, hint about "runtime not connected yet" should appear

> **REGRESSION WATCH (a28d17b):** If wait_for_runtime=false produces no hint text,
> the gated hint has regressed. Flag as **Minor**.

**20.5** Wait 2-3 seconds for runtime, then: `runtime_screenshot`
- **Expect:** PNG of running game

**20.6** `runtime_get_node_state` — node_path=`/root/Sv2Main/Sv2Player`
- **Expect:** class, path, properties including position

**20.7** `runtime_get_script_vars` — node_path=`/root/Sv2Main/Sv2Player`
- **Expect:** speed=100.0, label="default"

**20.8** `runtime_set_property` — node_path=`/root/Sv2Main/Sv2Player`, property=`speed`, value=200.0
- **Expect:** success

**20.9** `runtime_get_script_vars` — node_path=`/root/Sv2Main/Sv2Player` (verify change)
- **Expect:** speed=200.0

**20.10** `runtime_set_property` (autoload warning) — target an autoload node if one exists. If no autoload registered, skip this test.
- **Expect:** If targeting an autoload: response includes warning about property persistence across scene transitions

> **REGRESSION WATCH (c6d5f40):** If runtime_set_property on an autoload produces
> no warning, the autoload persistence warning has regressed. Flag as **Minor**.
> Skip if no autoloads registered.

**20.11** `debugger_get_log`
- **Expect:** success, game output (may include _ready prints)

**20.12** Seed runtime log — `execute_code` code=`print("SV2_RUNTIME_SEED_Beta99 check(braces)")` **[gated: skip if execute_code unavailable]**
- **Expect:** success

**20.13** `debugger_get_log` — text_filter=`SV2_RUNTIME_SEED`, is_regex=`false`
- **Expect:** count >= 1

**20.14** `debugger_get_log` — text_filter=`SV2_RUNTIME_SEED_Beta\\d+`, is_regex=`true`
- **Expect:** count >= 1

**20.15** `debugger_get_log` — text_filter=`check(braces)`, is_regex=`false`
- **Expect:** count >= 1 (parens literal in plain mode)

**20.16** `debugger_get_log` guard — text_filter=`(unclosed`, is_regex=`true`
- **Expect:** INVALID_PARAMS with actionable hint

**20.17** `input_simulate` — events=[{"event_type":"action","event_data":{"action":"ui_accept","pressed":true}}]
- **Expect:** success

**20.18** `execute_code` (runtime) — code=`get_tree().current_scene.name` **[gated]**
- **Expect:** "Sv2Main"

**20.19** `animation_player_control` — node_path=`/root/Sv2Main/Sv2AnimPlayer`, operation=`play`, animation_name=`sv2_lib/idle`
- **Expect:** success (or error if animation wasn't created — note in report)

**20.20** `signal_emit` — node_path=`/root/Sv2Main/Sv2Player`, signal_name=`hit`
- **Expect:** success

**20.21** `debugger_get_log` — (check for any signal-related output)
- **Expect:** success

**20.22** `game_stop`
- **Expect:** success

---

## Console error check

Call `editor_get_console` and scan output since section start for `UndoRedo history mismatch`. Guard tests produce intentional error logs (e.g., `Failed loading resource`) — ignore those.
- **FAIL** if any `UndoRedo history mismatch` line appears.
- **PASS** otherwise.

## Cleanup

- `project_set_setting` — restore `application/run/main_scene` to original value from Section 0
- Call `discover_tools` with reset=true to deactivate all on-demand groups activated during this section
