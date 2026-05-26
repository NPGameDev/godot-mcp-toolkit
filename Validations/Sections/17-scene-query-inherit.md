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

**17.10** `scene_query` guard — root_path=`"NonExistentNode"`
- **Expect:** NOT_FOUND

---

## Console error check

Call `editor_get_console` and scan output since section start for unexpected errors.
- **FAIL** if any line contains: `UndoRedo history mismatch`, `SCRIPT ERROR`, `FATAL`, or unexpected `ERROR:` lines not caused by intentional guard tests.
- **PASS** if only expected noise (e.g., `Failed loading resource` from NOT_FOUND guard tests).
- Note: expected errors from guard tests (e.g., loading nonexistent resources) are NOT failures.

## Cleanup

- `scene_delete` file_path=`res://sv2_validation/base_enemy.tscn`
- `scene_delete` file_path=`res://sv2_validation/slime.tscn`
