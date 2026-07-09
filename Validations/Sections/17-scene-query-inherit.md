# Section 17 — Scene Inheritance & Query

**Dependencies:** Section 1 (sv2_validation/ exists)
**Tools tested:** scene_create, scene_create_inherited, scene_query
**Tests:** 19

---

**17.1** `scene_create` — file_path=`res://sv2_validation/base_enemy.tscn`, root_type=`CharacterBody2D`, root_name=`BaseEnemy`
- **Expect:** success, `root_name=BaseEnemy` — the optional override is honored, so the root node is named `BaseEnemy` (not the filename stem `base_enemy`). Harmonizes with `scene_create_inherited`'s `root_name`.

**17.1b** `scene_create` default root_name — file_path=`res://sv2_validation/default_root.tscn`, root_type=`Node2D` (omit `root_name`)
- **Expect:** success, `root_name=default_root` — omitting `root_name` falls back to the filename stem (preserves the prior default behavior).

**17.2** `scene_create_inherited` — file_path=`res://sv2_validation/slime.tscn`, base_scene=`res://sv2_validation/base_enemy.tscn`, root_name=`SlimeEnemy`
- **Expect:** success, root_name=SlimeEnemy

**17.3** `scene_create_inherited` guard — base_scene=`res://nonexistent.tscn`
- **Expect:** NOT_FOUND

**17.4** Open main scene: `scene_open` file_path=`res://sv2_validation/Sv2Main.tscn`

**17.5** `scene_query` — class_filter=`"CharacterBody2D"`
- **Expect:** success, includes Sv2Player

**17.6** `scene_query` — name_pattern=`"Sv2*"`
- **Expect:** success, all returned nodes start with "Sv2"

**17.7** `scene_query` — class_filter=`"Node2D"`, include_properties=["position","visible"]
- **Expect:** each result has position and visible fields

**17.8** `scene_query` — root_path=`"Sv2Player"`, class_filter=`"Node"`
- **Expect:** only nodes under Sv2Player

**17.9** `scene_query` guard — (no filters provided)
- **Expect:** INVALID_PARAMS mentioning "filter"

**17.10** `scene_query` guard — root_path=`"NonExistentNode"`, class_filter=`"Node"`
- **Expect:** NOT_FOUND ("Root node not found"). NOTE: `scene_query` requires at least one filter (`class_filter`/`group_filter`/`name_pattern`/`property_filters`); `root_path` is NOT a filter, so a `root_path`-only call trips the filter-required guard (that is 17.9's case) *before* the node-existence check. Pair the bad `root_path` with any filter to reach the NOT_FOUND path. (Verified 41n-ter: tool returns NOT_FOUND correctly with a filter present — the prior filterless spec could never reach it.)

---

### Pagination (17.11–17.18)

`scene_query` returns a self-describing pagination envelope: `nodes` (≤ effective `limit`) plus
`offset`, `limit`, `returned` (page size), `total_matches` (walk-all count), and `has_more` — always
present. When `has_more` is true it adds `next_offset` (= `offset + returned`) and a prose `hint`.
When `has_more` is false those two keys are ABSENT. Fields cross JSON as floats — compare int fields
with `int(...)` coercion, never a whole-dict compare.

**Fixture (5-node isolated match set):** create five plain `Node`s under the scene root, each in a
dedicated group so nothing incidental matches, then page at `limit: 2`. Batch all five in one message:
- `scene_create_node` class_name=`Node`, node_name=`Sv2Page1`, parent_path=`.`
- `scene_create_node` class_name=`Node`, node_name=`Sv2Page2`, parent_path=`.`
- `scene_create_node` class_name=`Node`, node_name=`Sv2Page3`, parent_path=`.`
- `scene_create_node` class_name=`Node`, node_name=`Sv2Page4`, parent_path=`.`
- `scene_create_node` class_name=`Node`, node_name=`Sv2Page5`, parent_path=`.`
- `node_groups` action=`add`, entries=`[{"node_path":"Sv2Page1","group":"pagetest"},{"node_path":"Sv2Page2","group":"pagetest"},{"node_path":"Sv2Page3","group":"pagetest"},{"node_path":"Sv2Page4","group":"pagetest"},{"node_path":"Sv2Page5","group":"pagetest"}]`

**17.11** `scene_query` page 1 — group_filter=`"pagetest"`, limit=`2`, offset=`0`
- **Expect:** success. `int(total_matches) == 5`; `int(returned) == 2`; `nodes` has 2 entries; `int(offset) == 0`; `int(limit) == 2`; `has_more == true`; `int(next_offset) == 2`; a `hint` naming `next_offset` is present.

**17.12** `scene_query` page 2 — group_filter=`"pagetest"`, limit=`2`, offset=`2`
- **Expect:** success. `int(total_matches) == 5` (constant across pages); `int(returned) == 2`; `int(offset) == 2`; `has_more == true`; `int(next_offset) == 4`. The 2 paths in `nodes` are DISJOINT from 17.11's 2 paths.

**17.13** `scene_query` final page — group_filter=`"pagetest"`, limit=`2`, offset=`4`
- **Expect:** success. `int(total_matches) == 5`; `int(returned) == 1` (the last partial page); `int(offset) == 4`; `has_more == false`; **NO** `next_offset` key and **NO** `hint` key. Its 1 path is disjoint from both 17.11 and 17.12.

> **Completeness invariant:** across 17.11–17.13 the sum of `returned` is `2 + 2 + 1 == 5 == total_matches`; the union of the three pages' `nodes` paths == all five `Sv2Page*` nodes, with no repeats. If any page repeats or omits a node, deterministic paging has regressed. Flag as **Major**.

**17.14** `scene_query` determinism — repeat 17.11 verbatim (group_filter=`"pagetest"`, limit=`2`, offset=`0`)
- **Expect:** byte-identical to 17.11 — same `total_matches`, same `returned`, same two `nodes` in the same order (an unchanged tree + the same query ⇒ the same DFS pre-order page). If the order differs between two identical calls, the walk is non-deterministic. Flag as **Major**.

**17.15** `scene_query` past-the-end — group_filter=`"pagetest"`, limit=`2`, offset=`5`
- **Expect:** success (NOT an error). `nodes` is empty (`[]`); `int(returned) == 0`; `int(total_matches) == 5`; `int(offset) == 5` (echoed as-sent, NOT clamped down to total_matches, so the caller can see it overshot); `has_more == false`; **NO** `next_offset`/`hint`.

**17.16** `scene_query` offset floor — group_filter=`"pagetest"`, limit=`2`, offset=`-3`
- **Expect:** success. `int(offset) == 0` — a negative offset is floored to 0 (defensive clamp), so this returns page 1 (same as 17.11): `int(returned) == 2`, `has_more == true`.

**17.17** `scene_query` limit clamp disclosure — group_filter=`"pagetest"`, limit=`500`
- **Expect:** success. `int(limit) == 200` (the effective/clamped page size, NOT the requested 500); `limit_clamped == true`; the `hint` contains a clamp clause naming the max (200). `int(total_matches) == 5`; `int(returned) == 5` (all matches fit under the clamped limit); `has_more == false` (5 < 200), so NO `next_offset`. (The `limit_clamped` key is ABSENT on the un-clamped pages 17.11–17.16.)

**17.18** `scene_query` no-match — group_filter=`"pagetest_none"` (a group nothing is in)
- **Expect:** success (NOT an error). `nodes` empty (`[]`); `int(returned) == 0`; `int(total_matches) == 0`; `has_more == false`; **NO** `next_offset`/`hint`/`limit_clamped`.

> **REGRESSION WATCH (scene_query pagination envelope):** the response must be the self-describing
> envelope — `returned` (NOT the old `count`), `has_more` (NOT `truncated`), always-present
> `total_matches`, and `next_offset`/`hint` only while `has_more`. If a response still carries `count`
> or `truncated`, or omits `total_matches`, the pagination reshape has regressed. Flag as **Major**.

**Fixture cleanup (before Section cleanup):**
- `scene_delete_node` node_path=`Sv2Page1`
- `scene_delete_node` node_path=`Sv2Page2`
- `scene_delete_node` node_path=`Sv2Page3`
- `scene_delete_node` node_path=`Sv2Page4`
- `scene_delete_node` node_path=`Sv2Page5`

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- `scene_delete` file_path=`res://sv2_validation/base_enemy.tscn`
- `scene_delete` file_path=`res://sv2_validation/slime.tscn`
- `scene_delete` file_path=`res://sv2_validation/default_root.tscn`
