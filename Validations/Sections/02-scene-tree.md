# Section 2 — Scene Tree & Node Creation

**Dependencies:** Section 1 (main.tscn exists and is open)
**Tools tested:** scene_create_node, scene_instantiate, scene_get_tree, editor_save_scene
**Tests:** 18

---

**2.1** `scene_get_tree`
- **Expect:** Tree with root Sv2Main (Node2D)

**2.2** `scene_create_node` — node_type=`Sprite2D`, node_name=`Sv2Sprite`, parent_path=`.`
- **Expect:** success

**2.3** `scene_create_node` — node_type=`Label`, node_name=`Sv2Label`, parent_path=`.`
- **Expect:** success

**2.4** `scene_create_node` — node_type=`AnimationPlayer`, node_name=`Sv2AnimPlayer`, parent_path=`.`
- **Expect:** success

**2.5** `scene_create_node` — node_type=`AnimationTree`, node_name=`Sv2AnimTree`, parent_path=`.`
- **Expect:** success

**2.6** `scene_create_node` — **[4.3+]** node_type=`TileMapLayer`, node_name=`Sv2TileLayer`, parent_path=`.` | **[4.2]** node_type=`TileMap`, node_name=`Sv2TileLayer`, parent_path=`.`
- **Expect:** success

**2.7** `scene_create_node` — node_type=`CharacterBody2D`, node_name=`Sv2Player`, parent_path=`.`
- **Expect:** success

**2.8** `scene_create_node` — node_type=`CollisionShape2D`, node_name=`Sv2Collider`, parent_path=`Sv2Player`
- **Expect:** success

**2.9** `scene_create_node` — node_type=`Path2D`, node_name=`Sv2Path`, parent_path=`.`
- **Expect:** success

**2.10** `scene_create_node` — node_type=`NavigationRegion2D`, node_name=`Sv2NavRegion`, parent_path=`.`
- **Expect:** success

**2.11** `scene_create_node` (unique_name) — node_type=`Node2D`, node_name=`Sv2Unique`, parent_path=`.`, unique_name=`true`
- **Expect:** success, node created with unique name access enabled (`%Sv2Unique`)

> **REGRESSION WATCH (a46487b):** If `unique_name` param is rejected or ignored,
> scene_create_node unique_name support has regressed. Flag as **Major**.

**2.12** `scene_create_node` (CLASS_MISMATCH guard) — node_type=`Button`, node_name=`Sv2Label`, parent_path=`.`
- **Expect:** `CLASS_MISMATCH` error mentioning Label vs Button

> **REGRESSION WATCH (cb4e162):** If the tool returns success (silently reuses
> the existing Label node) or a generic NAME_EXISTS error without class info,
> the CLASS_MISMATCH guard has regressed. Flag as **Critical**.

**2.13** `scene_create_node` (idempotent) — node_type=`Label`, node_name=`Sv2Label`, parent_path=`.`
- **Expect:** status=`returned` (idempotent, same class + same name)

**2.14** `scene_instantiate` — scene_path=`res://sv2_validation/sub.tscn`, parent_path=`.`
- **Expect:** success, Sv2Sub node added

> **REGRESSION WATCH (FIX-B, 7e63aee):** Parameter must be `scene_path`, not
> the old `packed_path`. If the tool rejects `scene_path`, the rename has regressed.

**2.15** `scene_instantiate` (with properties) — scene_path=`res://sv2_validation/sub.tscn`, parent_path=`.`, name=`Sv2SubProps`, properties=`{"position": {"type": "Vector2", "x": 50, "y": 75}}`
- **Expect:** success, Sv2SubProps created. Verify via `node_get_property` position = (50, 75)

> **REGRESSION WATCH (462506b):** If `properties` param is rejected or position
> is not applied, scene_instantiate properties support has regressed. Flag as **Major**.

**2.16** `scene_get_tree` — depth=2
- **Expect:** Tree shows all created nodes: Sv2Sprite, Sv2Label, Sv2AnimPlayer, Sv2AnimTree, Sv2TileLayer, Sv2Player/Sv2Collider, Sv2Path, Sv2NavRegion, Sv2Unique, Sv2Sub, Sv2SubProps

**2.17** `editor_save_scene`
- **Expect:** success

**2.18** Path normalization — `node_get_property` node_path=`/root/Sv2Main/Sv2Sprite`, property=`visible`
- **Expect:** success (toolkit normalizes `/root/Sv2Main/Sv2Sprite` → `Sv2Sprite`)

---

## Console error check

Call `editor_get_console` and scan output since section start for unexpected errors.
- **FAIL** if any line contains: `UndoRedo history mismatch`, `SCRIPT ERROR`, `FATAL`, or unexpected `ERROR:` lines not caused by intentional guard tests.
- **PASS** if only expected noise (e.g., `Failed loading resource` from NOT_FOUND guard tests).
- Note: expected errors from guard tests (e.g., loading nonexistent resources) are NOT failures.

## Cleanup

Delete instantiated sub-scenes (not needed for later sections):
- `scene_delete_node` node_path=`Sv2SubProps`
- `scene_delete_node` node_path=`Sv2Sub`
