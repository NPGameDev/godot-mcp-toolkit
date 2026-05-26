# Section 10 — Input Map

**Dependencies:** None
**Tools tested:** input_map_action, input_map_event
**Tests:** 4

---

**10.1** `input_map_action` — name=`sv2_jump`, operation=`add`
- **Expect:** success

> **REGRESSION WATCH (09a6392):** Parameter must be `name`, not old `action_name`.
> If tool rejects `name` param, the rename has regressed.

**10.2** `input_map_event` — name=`sv2_jump`, event_type=`key`, keycode=`KEY_SPACE`, operation=`add`
- **Expect:** success

**10.3** `input_map_event` — name=`sv2_jump`, event_type=`key`, keycode=`KEY_SPACE`, operation=`remove`
- **Expect:** success

**10.4** `input_map_action` — name=`sv2_jump`, operation=`remove`
- **Expect:** success

---

## Console error check

Call `editor_get_console` and scan output since section start for unexpected errors.
- **FAIL** if any line contains: `UndoRedo history mismatch`, `SCRIPT ERROR`, `FATAL`, or unexpected `ERROR:` lines not caused by intentional guard tests.
- **PASS** if only expected noise (e.g., `Failed loading resource` from NOT_FOUND guard tests).
- Note: expected errors from guard tests (e.g., loading nonexistent resources) are NOT failures.

## Cleanup

- Call `discover_tools` with reset=true to deactivate all on-demand groups activated during this section
