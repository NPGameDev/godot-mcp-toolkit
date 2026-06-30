# Section 20 — Game Start, Runtime & Debugging

**Dependencies:** Section 2 (Sv2Main.tscn with nodes, script attached to Sv2Player)
**Tools tested:** game_start, game_stop, runtime_screenshot, runtime_get_node_state, runtime_get_script_vars, runtime_set_property, debugger_get_log, input_simulate, execute_code (runtime), animation_player_control, signal_emit, autoload_manage (20.10 setup)
**Tests:** 22

---

**20.1** `project_set_setting` — setting=`application/run/main_scene`, value=`"res://sv2_validation/Sv2Main.tscn"`
- **Expect:** success

**20.2** `editor_save_scene`
- **Expect:** success

**20.2a** Register a temp user autoload (setup for 20.10) — the dogfood `project.godot` has only the plugin autoload (`MCPRuntimeServer`), so provision a user autoload **before launch** so it instantiates as a direct child of `/root` in the running game:
- `autoload_manage` — action=`register`, name=`Sv2RuntimeAutoload`, script_path=`res://sv2_validation/actor.gd`
- **Expect:** success (autoload registered + project settings persisted). It will appear at `/root/Sv2RuntimeAutoload` once the game launches.
- **Fallback (if 20.10's warning can't be driven):** after 20.5, verify the autoload is live with `runtime_get_node_state` `/root/Sv2RuntimeAutoload`; if it isn't present in the running tree, fall back to a committed dogfood autoload fixture. Either way 20.10 needs an autoload present at runtime.

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

> **Note — runtime port scan range.** The runtime WebSocket server allocates
> `runtime_port` from the range **6570–6585** (`runtime/mcp_runtime_server.gd`:
> `PORT_BASE = 6570` + `PORT_RANGE = 16` → 6570..6585 inclusive). A connect
> response reporting a `runtime_port` in that range (e.g. `6570`) is **in-range —
> not a drift**; do not flag it. (Some older docs cite a stale, lower range;
> `6570–6585` is authoritative and code-confirmed.)

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

**20.10** `runtime_set_property` autoload-persistence warning (DRIVABLE — uses the temp autoload from 20.2a) — `runtime_set_property` node_path=`/root/Sv2RuntimeAutoload`, property=`speed`, value=300.0
- **Expect:** success, **and** the response carries a `warning` that the node is an autoload which persists across scene transitions (the change carries forward through restarts/level changes unless the game resets it). The warning fires because the target is a direct child of `/root` (an autoload singleton) in the running game.

> **REGRESSION WATCH (c6d5f40):** If runtime_set_property on the
> `/root/Sv2RuntimeAutoload` autoload produces no `warning`, the autoload
> persistence warning has regressed. Flag as **Minor**.

**20.11** `debugger_get_log`
- **Expect:** success, game output (may include _ready prints)

**20.12** Seed runtime log — `execute_code` code=`print("SV2_RUNTIME_SEED_Beta99 check(braces)")`
- **Expect:** success

**20.13** `debugger_get_log` — text_filter=`SV2_RUNTIME_SEED`, is_regex=`false`
- **Expect:** count >= 1

**20.14** `debugger_get_log` — text_filter=`SV2_RUNTIME_SEED_Beta\\d+`, is_regex=`true`
- **Expect:** count >= 1

**20.15** `debugger_get_log` — text_filter=`check(braces)`, is_regex=`false`
- **Expect:** count >= 1 (parens literal in plain mode)

**20.15a** `debugger_get_log` file source under filter — source=`file`, text_filter=`SV2_RUNTIME_SEED`, is_regex=`false`
- **Expect:** the `file` source filters-then-slices, **uniform with the `buffer` source** (41n-ter-bis #7a). Either (a) file logging enabled → success, count >= 1, and the returned lines are the last `limit` **matching** lines (not the matches within the last `limit` raw lines); `total_lines` = number of matching lines, `truncated` = matches exceeded `limit` — same semantics 20.13 reports from the buffer; or (b) file logging disabled → `LOG_UNAVAILABLE` with an enable-file-logging hint (also suggesting `source="buffer"`).

**20.16** `debugger_get_log` guard — text_filter=`(unclosed`, is_regex=`true`
- **Expect:** INVALID_PARAMS with actionable hint

**20.17** `input_simulate` — events=[{"event_type":"action","event_data":{"action":"ui_accept","pressed":true}}]
- **Expect:** success

**20.18** `execute_code` (runtime) — code=`get_tree().current_scene.name`
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

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- `autoload_manage` — action=`unregister`, name=`Sv2RuntimeAutoload` (remove the temp autoload registered in 20.2a)
- `project_set_setting` — restore `application/run/main_scene` to original value from Section 0
- Call `discover_tools` with reset=true to deactivate all on-demand groups activated during this section
