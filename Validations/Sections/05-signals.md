# Section 5 — Signals

**Dependencies:** Section 2 (Sv2Player with script attached from Section 3)
**Tools tested:** signal_list, signal_manage
**Tests:** 7

---

**5.1** `signal_list` — node_path=`Sv2Player`
- **Expect:** Includes `hit` signal from actor.gd

**5.2** `signal_manage` — node_path=`Sv2Player`, signal_name=`hit`, action=`connect`, target_path=`Sv2Label`, method_name=`set_text`
- **Expect:** success. The success payload echoes the node under the `node_path` key (not the old `source_path`).

> **REGRESSION WATCH (FIX-G, 7e63aee):** Parameter must be `node_path`, not old
> `source_path`. If tool rejects `node_path`, the rename has regressed.

> **REGRESSION WATCH (output-key rename):** The success body's node key must be
> `node_path`, not `source_path` — the output now matches the input param name.
> A `source_path` key in the response is a regression.

**5.3** `signal_list` — node_path=`Sv2Player`, include_connections=`true`
- **Expect:** `hit` signal connections array contains `{ target_path: "Sv2Label", method_name: "set_text" }`

**5.4** `signal_manage` (method hint test) — node_path=`Sv2Player`, signal_name=`hit`, action=`connect`, target_path=`Sv2Label`, method_name=`nonexistent_method_xyz`
- **Expect:** success OR warning with method hint. The 3-case diagnostic should fire:
  1. If method exists → connect silently
  2. If method doesn't exist but similar ones do → hint with suggestions
  3. If no methods match → generic warning

> **REGRESSION WATCH (5f96b62):** If no method hint appears when connecting to
> a non-existent method, the signal_manage method diagnostic has regressed.
> Flag as **Major**.

**5.5** `signal_manage` (disconnect) — node_path=`Sv2Player`, signal_name=`hit`, action=`disconnect`, target_path=`Sv2Label`, method_name=`set_text`
- **Expect:** success. The disconnect success payload also echoes the node under `node_path` (not `source_path`).

**5.6** `signal_manage` (disconnect invalid method) — disconnect `nonexistent_method_xyz` connection from 5.4
- **Expect:** success (or NOT_FOUND if connection wasn't created)

**5.7** `signal_list` — node_path=`Sv2Player`, include_connections=`true`
- **Expect:** `hit` connections array is empty

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- Call `discover_tools` with reset=true to deactivate all on-demand groups activated during this section
