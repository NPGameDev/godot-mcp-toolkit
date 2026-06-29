# Section 17 — Scene Inheritance & Query

**Dependencies:** Section 1 (sv2_validation/ exists)
**Tools tested:** scene_create_inherited, scene_query
**Tests:** 10

---

**17.1** `scene_create` — file_path=`res://sv2_validation/base_enemy.tscn`, root_type=`CharacterBody2D`, root_name=`BaseEnemy`
- **Expect:** success

**17.2** `scene_create_inherited` — file_path=`res://sv2_validation/slime.tscn`, base_scene=`res://sv2_validation/base_enemy.tscn`, root_name=`SlimeEnemy`
- **Expect:** success, root_name=SlimeEnemy

**17.3** `scene_create_inherited` guard — base_scene=`res://nonexistent.tscn`
- **Expect:** NOT_FOUND

**17.4** Open main scene: `scene_open` file_path=`res://sv2_validation/main.tscn`

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

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- `scene_delete` file_path=`res://sv2_validation/base_enemy.tscn`
- `scene_delete` file_path=`res://sv2_validation/slime.tscn`
