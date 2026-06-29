# Section 4 — Node Management

**Dependencies:** Section 2 (nodes exist in Sv2Main.tscn)
**Tools tested:** node_manage (rename, reparent, reorder, duplicate), node_groups
**Tests:** 16

---

**4.1** `node_manage` (rename) — action=`rename`, node_path=`Sv2Label`, new_name=`Sv2LabelRenamed`
- **Expect:** success

**4.2** `node_get_property` — node_path=`Sv2LabelRenamed`, property=`text`
- **Expect:** "Hello Sweep v2" (reachable under new name)

**4.3** `node_manage` (rename back) — action=`rename`, node_path=`Sv2LabelRenamed`, new_name=`Sv2Label`
- **Expect:** success

**4.4** `node_manage` (reparent) — action=`reparent`, node_path=`Sv2Sprite`, new_parent_path=`Sv2Player`
- **Expect:** success

**4.5** `scene_get_tree` — verify Sv2Sprite under Sv2Player
- **Expect:** Sv2Sprite as child of Sv2Player

**4.6** `node_manage` (reparent back) — action=`reparent`, node_path=`Sv2Player/Sv2Sprite`, new_parent_path=`.`
- **Expect:** success

**4.7** `node_manage` (reorder) — action=`reorder`, node_path=`Sv2Label`, new_index=0
- **Expect:** success

**4.8** `node_manage` (duplicate) — action=`duplicate`, node_path=`Sv2Label`, new_name=`Sv2LabelCopy`
- **Expect:** success

**4.9** `node_get_property` — node_path=`Sv2LabelCopy`, property=`text`
- **Expect:** "Hello Sweep v2" (inherits value)

**4.10** `node_manage` (duplicate with properties) — action=`duplicate`, node_path=`Sv2Sprite`, new_name=`Sv2SpriteCopy`, properties=`{"position":{"x":200,"y":300}}`
- **Expect:** success

> **REGRESSION WATCH (c61d994):** If properties override is ignored and the copy
> has the original position, duplicate-with-properties coercion has regressed.
> The tool should infer Vector2 type from the existing property when caller omits
> the "type" key. Flag as **Major**.

**4.11** Verify — `node_get_property` node_path=`Sv2SpriteCopy`, property=`position`
- **Expect:** Vector2(200, 300), NOT the original sprite position

**4.12** `node_groups` (batch add) — action=`add`, entries=`[{"node_path":"Sv2Player","group":"sv2_enemies"},{"node_path":"Sv2Player","group":"sv2_actors"}]`
- **Expect:** success, results array with 2 entries (status="added")

> **REGRESSION WATCH (462506b):** Batch mode is the `entries` array — each item is
> a `{node_path, group}` pair (the handler ignores any top-level `node_path`/`group`
> when `entries` is present). If `entries` is rejected and only single `group` mode
> works, batch node_groups has regressed. Flag as **Major**.

**4.13** `node_groups` (list) — action=`list`, node_path=`Sv2Player`
- **Expect:** includes both `sv2_enemies` and `sv2_actors`

**4.14** `node_groups` (batch remove) — action=`remove`, entries=`[{"node_path":"Sv2Player","group":"sv2_enemies"},{"node_path":"Sv2Player","group":"sv2_actors"}]`
- **Expect:** success, results array with 2 entries (status="removed")

**4.15** `node_groups` (batch partial failure — top-level rollup) — action=`add`, entries=`[{"node_path":"Sv2Player","group":"sv2_actors"},{"node_path":"Sv2NoSuchNode","group":"sv2_actors"}]`
- **Expect:** success (the call itself succeeds). `results[0]` status="added"; `results[1]` carries an `error` ("node not found") and **no** `status` key (this is the site-2 batch shape — entries have no `success` field). A top-level `failed` = **1** (compare as `int(failed) == 1` — the JSON round-trip floats ints) AND a top-level `hint` "1 of 2 entries failed — inspect results[] for per-entry .error." is present.
- Restore: `node_groups` action=`remove`, entries=`[{"node_path":"Sv2Player","group":"sv2_actors"}]` (drop the group added by `results[0]`).

> **REGRESSION WATCH (concern 034 D, summarize_batch / eb25de5):** `node_groups`
> batch entries use the `{status?, error?}` shape with **no** `success` key, so the
> rollup must catch them via the shape-tolerant predicate (no-success + error =
> failure). A top-level `failed`/`hint` must appear here even though entries have no
> `success` field. If `failed`/`hint` are absent, either the wiring at
> `_batch_node_groups` regressed or the helper's tolerant predicate stopped covering
> site-2's shape. Flag as **Major**. (`failed` crosses JSON → coerce with `int(...)`.)

**4.16** `node_groups` (batch all-success — rollup keys ABSENT) — action=`add`, entries=`[{"node_path":"Sv2Player","group":"sv2_actors"},{"node_path":"Sv2Player","group":"sv2_enemies"}]`
- **Expect:** success, both `results` entries status="added", and **NO** top-level `failed` key and **NO** top-level `hint` key (additive-only: an all-success batch keeps the prior `{action, results, count}` shape).
- Restore: `node_groups` action=`remove`, entries=`[{"node_path":"Sv2Player","group":"sv2_actors"},{"node_path":"Sv2Player","group":"sv2_enemies"}]`

> **REGRESSION WATCH (concern 034 D, summarize_batch):** Additive-only control for
> the site-2 shape — `failed`/`hint` must NOT appear when every entry succeeded. If
> either shows up on an all-success `node_groups` batch, the `failed > 0` gate
> regressed. Flag as **Major**.

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- `scene_delete_node` node_path=`Sv2LabelCopy`
- `scene_delete_node` node_path=`Sv2SpriteCopy`
