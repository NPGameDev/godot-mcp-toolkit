# Section 10 — Input Map

**Dependencies:** None
**Tools tested:** input_map_action, input_map_event
**Tests:** 5

---

**10.1** `input_map_action` — action=`add`, name=`sv2_jump`
- **Expect:** success, status=created, deadzone defaults to 0.5. **Param shape:** the operation is carried by `action` (`add`/`remove`), not a separate `operation` param; `name` is the input-map action name (correct — see the watch below).

> **REGRESSION WATCH (09a6392):** Parameter must be `name`, not old `action_name`.
> If tool rejects `name` param, the rename has regressed.

**10.1b** An action saved in `project.godot`, then a built-in action ([#14](https://github.com/NPGameDev/godot-mcp-toolkit/issues/14)). The editor loads only the built-in actions into its input map, so a project action exists there only as its `input/<name>` setting. `project_set_setting` seeds that state: it writes the setting and leaves the editor's input map alone. Run in order:
1. `project_set_setting` — setting=`input/sv2_saved`, value=`{"deadzone":0.3,"events":[{"type":"NewResource","class":"InputEventKey","properties":{"physical_keycode":81}}]}` (81 is the Q key)
2. `input_map_event` — action=`bind`, name=`sv2_saved`, event=`{"type":"key","keycode":"E"}`
3. `input_map_action` — action=`add`, name=`sv2_saved`
4. `input_map_event` — action=`bind`, name=`sv2_saved`, event=`{"type":"key","keycode":"Q"}`
5. `input_map_action` — action=`remove`, name=`sv2_saved`; then `input_map_event` — action=`bind`, name=`sv2_saved`, event=`{"type":"key","keycode":"E"}`
6. `input_map_action` — action=`remove`, name=`ui_select`
- **Expect:** (1) success. (2) success, status=`created`. (3) success, status=`returned`, deadzone ≈ 0.3 (the saved value, not the 0.5 default). (4) status=`returned`: the saved Q event is still bound. (5) the remove succeeds, and the bind after it answers `NOT_FOUND`: the action is gone from the input map and from `project.godot`. (6) `INVALID_PARAMS`, refusing to remove a built-in action.

> **REGRESSION WATCH (#14):** (2) `NOT_FOUND`, or (3) status=`created` with the Q event gone, means the handlers no longer see actions saved in `project.godot`. (6) succeeding means the built-in check lets a built-in action through, and the editor has lost `ui_select` until it restarts. Flag either as **Major**.

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
