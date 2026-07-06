# Section 20 — Game Start, Runtime & Debugging

**Dependencies:** Section 2 (Sv2Main.tscn with nodes, script attached to Sv2Player)
**Tools tested:** game_start, game_stop, runtime_screenshot, runtime_get_node_state, runtime_get_script_vars, runtime_set_property, debugger_get_log, input_simulate, execute_code (runtime), animation_player_control, signal_emit, autoload_manage (20.10 setup)
**Tests:** 32

---

**20.1** `project_set_setting` — setting=`application/run/main_scene`, value=`"res://sv2_validation/Sv2Main.tscn"`
- **Expect:** success

**20.2** `editor_save_scene`
- **Expect:** success

**20.2a** Register a temp user autoload (setup for 20.10) — the dogfood `project.godot` has only the plugin autoload (`MCPRuntimeServer`), so provision a user autoload **before launch** so it instantiates as a direct child of `/root` in the running game:
- `autoload_manage` — action=`register`, name=`Sv2RuntimeAutoload`, script_path=`res://sv2_validation/actor.gd`
- **Expect:** success (autoload registered + project settings persisted). It will appear at `/root/Sv2RuntimeAutoload` once the game launches.
- **Fallback (if 20.10's warning can't be driven):** after 20.5, verify the autoload is live with `runtime_get_node_state` `/root/Sv2RuntimeAutoload`; if it isn't present in the running tree, fall back to a committed dogfood autoload fixture. Either way 20.10 needs an autoload present at runtime.

**20.2b** Build a text-surface fixture for the `send_text` cases (20.17a–20.17g). These nodes must be **in `Sv2Main.tscn` before launch** so they are live in the running game. With `Sv2Main.tscn` open (from Section 2), as children of the `Sv2Main` root:
- `scene_create_node` — class=`LineEdit`, name=`Sv2FeedbackEdit`
- `scene_create_node` — class=`LineEdit`, name=`Sv2SecretEdit`, then `node_set_property` node_path=`Sv2SecretEdit`, property=`secret`, value=`true`
- `scene_create_node` — class=`TextEdit`, name=`Sv2MultilineEdit`
- `scene_create_node` — class=`Label`, name=`Sv2ReadonlyLabel`, then `node_set_property` text=`"readonly"` (a non-editable text surface for 20.17f)
- **Observer for 20.17d:** `script_write` a tiny observer to `res://sv2_validation/sv2_submit_observer.gd` (`extends LineEdit`; in `_ready` connect `text_submitted` to a method that `print("SV2_SUBMITTED:", t)`), then `node_set_script` it onto `Sv2FeedbackEdit` so the submit fires an observable log line.
- `editor_save_scene`
- **Expect:** success; once the game launches the fields are reachable at `/root/Sv2Main/Sv2FeedbackEdit`, `/root/Sv2Main/Sv2SecretEdit`, `/root/Sv2Main/Sv2MultilineEdit`, `/root/Sv2Main/Sv2ReadonlyLabel`.

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

**20.8b** `runtime_set_property` (wrong-type REJECTED, NON-DESTRUCTIVE — 41o C1 + destructive-zero regression) — first set a **non-zero prior**: `runtime_set_property` node_path=`/root/Sv2Main/Sv2Player`, property=`position`, value=`{"type":"Vector2","x":50,"y":50}` (success). Then node_path=`/root/Sv2Main/Sv2Player`, property=`position`, value=`"not a vector"`
- **Expect:** error `SET_FAILED` (NOT `success:true`, NOT an "adjusted" success+`warning`). `position` is a bound setter: it Variant-converts the String to a **ZERO** and briefly stores it (readback ≠ the (50,50) prior) — the regression case. Then `runtime_get_node_state` `/root/Sv2Main/Sv2Player` confirms `position` = **(50,50)** — the runtime **RESTORES** the prior on a drop (non-destructive), NOT (0,0). Runtime twin of editor 3.2b; both route through the shared `contract/property_set_check.gd` detector.

> **REGRESSION WATCH (41o C1 + destructive-zero):** from a NON-ZERO prior a bound-setter
> wrong-type write stores a ZERO (readback ≠ prior). If it returns `success` + a
> `warning` ("adjusted"), the family-gate classification regressed. If `position`
> reads back (0,0) instead of the (50,50) prior, the non-destructive restore regressed.
> Both **Major**. (Scalar/non-colon only — colon sub-paths stay best-effort. An
> in-family reshape like 20.8c legitimately returns success+warning.)

**20.8c** `runtime_set_property` (convertible value ADJUSTED → success + warning — 41o D1) — node_path=`/root/Sv2Main/Sv2Player`, property=`z_index`, value=`2.9`
- **Expect:** **success** (NOT `SET_FAILED`). `z_index` is `int`; the engine truncates `2.9` → `2` and ACCEPTS the write, so the response carries a `warning` naming the stored-vs-requested delta. `runtime_get_node_state` confirms `z_index` = 2. Same tri-state detector as the editor path (3.2c is its editor twin).
- Restore: `runtime_set_property` z_index=0.

> **REGRESSION WATCH (41o D1):** An accepted-but-adjusted runtime write (in-family
> truncate/sanitize/normalize) must return **success WITH a warning**, not
> `SET_FAILED` (that would be the D1 false-positive) and not a silent success. Only
> CROSS-family mismatches (20.8b) return `SET_FAILED`.

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
- **Expect:** the `file` source filters-then-slices, uniform with the `buffer` source. Either (a) file logging enabled → success, count ≥ 1, returned lines are the last `limit` **matching** lines, `total_lines` = matching-line count, `truncated` = matches exceeded `limit` (same as 20.13 from the buffer); or (b) file logging disabled → `LOG_UNAVAILABLE` with an enable-file-logging hint.

**20.16** `debugger_get_log` guard — text_filter=`(unclosed`, is_regex=`true`
- **Expect:** INVALID_PARAMS with actionable hint

**20.17** `input_simulate` — events=[{"event_type":"action","event_data":{"action":"ui_accept","pressed":true}}]
- **Expect:** success

**20.17a** `input_simulate` send_text into a named field — events=[{"event_type":"send_text","event_data":{"text":"hello","node_path":"/root/Sv2Main/Sv2FeedbackEdit"}}]
- **Expect:** success; `last_event.focus_source`="node_path", `focus_target.class`="LineEdit", `text_changed`=true, `text_after`="hello", `chars_sent`=5. No `hint` (clean success).

**20.17b** `input_simulate` send_text into the currently-focused field — first focus it with `input_simulate` events=[{"event_type":"click_node","event_data":{"node_path":"/root/Sv2Main/Sv2FeedbackEdit"}}] (or rely on 20.17a's focus), then events=[{"event_type":"send_text","event_data":{"text":" world"}}] (no node_path)
- **Expect:** success; `focus_source`="existing", `text_changed`=true (the field already held focus; text appended).

**20.17c** `input_simulate` send_text with nothing focused → hint — ensure no field has focus (e.g. send to a fresh scene state), events=[{"event_type":"send_text","event_data":{"text":"ghost"}}]
- **Expect:** success, `focus_source`="none", `focus_target`=null, and a `hint` mentioning `node_path`. `chars_sent`=5.

**20.17d** `input_simulate` send_text with submit → `text_submitted` — events=[{"event_type":"send_text","event_data":{"text":"go","node_path":"/root/Sv2Main/Sv2FeedbackEdit","submit":true}}], then `debugger_get_log` text_filter=`SV2_SUBMITTED`, is_regex=`false`
- **Expect:** send_text success; the log shows `SV2_SUBMITTED:...` (the observer script from 20.2b confirms the Enter fired `text_submitted` on the `LineEdit`).

**20.17e** `input_simulate` send_text into the secret field → redacted — events=[{"event_type":"send_text","event_data":{"text":"hunter2","node_path":"/root/Sv2Main/Sv2SecretEdit"}}]
- **Expect:** success, `text_changed`=true, and `text_after`="[redacted: 7 chars]" — the typed value `hunter2` is **absent** from the response. **Flag as Critical** if `hunter2` appears anywhere in the result.

**20.17f** `input_simulate` send_text targeting a non-editable surface → text_changed:false + hint — events=[{"event_type":"send_text","event_data":{"text":"nope","node_path":"/root/Sv2Main/Sv2ReadonlyLabel"}}]
- **Expect:** success; either `node_path` problem hint (a `Label` is not a focusable text field) or `text_changed`=false with a "didn't change" hint. The typed text does not land.

**20.17g** `input_simulate` send_text + submit into a multiline `TextEdit` → newline (not submit) — events=[{"event_type":"send_text","event_data":{"text":"line1","node_path":"/root/Sv2Main/Sv2MultilineEdit","submit":true}}]
- **Expect:** success, `text_changed`=true; the Enter inserts a newline in the multiline `TextEdit` (no `text_submitted`), so `text_after` contains `line1` plus a trailing newline.

**20.17h** `input_simulate` action guard (unknown action REJECTED — 41o C6) — events=[{"event_type":"action","event_data":{"action":"sv2_no_such_action_xyz"}}]
- **Expect:** error `INVALID_PARAMS` (NOT `success:true, dispatched:true`). The message names the unknown action `sv2_no_such_action_xyz` and the hint points at Project Settings → Input Map. The batch aborts at this event (`events_processed` reflects prior events). This guards ONLY the `action` event mode — `key`/`send_text`/`click` modes don't consult the InputMap and are unaffected.

> **REGRESSION WATCH (41o C6):** An action not registered in the InputMap used to
> dispatch as a silent no-op (`success:true`), matching nothing. `input_simulate`
> now rejects an unknown action with `INVALID_PARAMS` naming it. If an unregistered
> action returns success, the action guard has regressed. Flag as **Major**.

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
- `script_delete` — `res://sv2_validation/sv2_submit_observer.gd` (the 20.2b submit observer; the fixture nodes themselves live in `Sv2Main.tscn`, cleaned up globally)
- `project_set_setting` — restore `application/run/main_scene` to original value from Section 0
- Call `discover_tools` with reset=true to deactivate all on-demand groups activated during this section
