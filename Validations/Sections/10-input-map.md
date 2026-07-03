# Section 10 — Input Map

**Dependencies:** None
**Tools tested:** input_map_action, input_map_event
**Tests:** 4

---

**10.1** `input_map_action` — action=`add`, name=`sv2_jump`
- **Expect:** success, status=created, deadzone defaults to 0.5. **Param shape:** the operation is carried by `action` (`add`/`remove`), not a separate `operation` param; `name` is the input-map action name (correct — see the watch below).

> **REGRESSION WATCH (09a6392):** Parameter must be `name`, not old `action_name`.
> If tool rejects `name` param, the rename has regressed.

**10.2** `input_map_event` — action=`bind`, name=`sv2_jump`, event=`{"type":"key","keycode":"Space"}`
- **Expect:** success, status=created, keycode resolves to `Space`/32. **Param shape:** the operation is `action` (`bind`/`unbind`), not `event_type`; the event is a single nested `event` object `{type, keycode, …}` — there is no top-level `event_type`/`keycode`. `keycode` is a string key name (e.g. `"Space"`), not an engine `KEY_*` constant.

**10.3** `input_map_event` — action=`unbind`, name=`sv2_jump`, event=`{"type":"key","keycode":"Space"}`
- **Expect:** success

**10.4** `input_map_action` — action=`remove`, name=`sv2_jump`
- **Expect:** success

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- Call `discover_tools` with reset=true to deactivate all on-demand groups activated during this section
