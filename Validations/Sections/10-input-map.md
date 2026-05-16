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

## Cleanup

None (action removed in 10.4).
