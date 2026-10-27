# Section 2 — Scene Tree & Node Creation

**Dependencies:** Section 1 (Sv2Main.tscn exists and is open)
**Tools tested:** scene_create_node, scene_instantiate, scene_get_tree, editor_save_scene
**Tests:** 22

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

**2.13a** `scene_create_node` (bad-form inline properties reported, NOT silently counted — 41o-duodecies-ter F2) — node_type=`Sprite2D`, node_name=`Sv2DropProbe`, parent_path=`.`, properties=`{"texture":"res://icon.svg","scale":[4,4]}`
- **Expect:** the node **is created** (`status:"created"`, partial-set truthfulness), but **`properties_set` = 0** and **`properties_failed`** has **2** entries naming `texture` and `scale`. Both are wire-form values `Object.set()` silently drops (a bare string on a Texture2D, a bare array on a Vector2) — the same values `node_set_property` rejects (3.2b/GAP). The `texture` entry's `error` steers to the tagged `{"type":"Resource","path":...}` form; the `scale` entry's `error` names the expected `Vector2` type. A `properties_set:2` with no `properties_failed` here is the pre-fix bug. Cleanup: `scene_delete_node` node_path=`Sv2DropProbe`.
> **REGRESSION WATCH (41o-duodecies-ter F2):** `scene_create_node` used to count every well-formed-looking inline value as set, even ones `set()` discarded. It now readback-verifies each and reports drops in `properties_failed` (parity with `node_set_property`). If both bad-form values land in `properties_set` with no failure reported, the drop reporting regressed. Flag as **Major**.

**2.13b** `scene_create_node` (bare `uid://` and `user://` paths) — node_type=`Sprite2D`, node_name=`Sv2BareProbe`, parent_path=`.`, properties=`{"texture":"uid://nosuchuid0000"}`; then node_name=`Sv2BareProbe2`, properties=`{"texture":"user://icon.svg"}`
- **Expect:** each node is created with `properties_set` = 0 and one `properties_failed` entry naming `texture`, whose `error` starts `property 'texture' expects a Resource, not a bare string path`: the first says no resource has the UID `uid://nosuchuid0000`, the second that only a res:// resource can be bound. Cleanup: `scene_delete_node` `Sv2BareProbe` and `Sv2BareProbe2`.

> **REGRESSION WATCH (toolkit #48):** a `uid://` or `user://` String counted in `properties_set`, or a generic drop error with no UID or `user://` wording, means the bare-path check regressed. Flag as **Major**.

**2.14** `scene_instantiate` — scene_path=`res://sv2_validation/sub.tscn`, parent_path=`.`
- **Expect:** success, Sv2Sub node added
- **Saved-file check:** `editor_save_scene`, then `script_read` file_path=`res://sv2_validation/Sv2Main.tscn`. The `[node name="Sv2Sub" ...]` header carries `instance=ExtResource(...)` and **no** `type=`, and the node's block under it has no `script =` line: the instance saves the way the editor saves a scene dropped into another. `sub.tscn`'s root is a scriptless `Node2D` (1.9), so the `type=` half is the one that catches a regression here; the `script =` half fires only for a sub-scene whose root has a script.

> **REGRESSION WATCH (FIX-B, 7e63aee):** Parameter must be `scene_path`, not
> the old `packed_path`. If the tool rejects `scene_path`, the rename has regressed.
>
> **REGRESSION WATCH (#12):** A `type=` on an instance's header means
> `scene_instantiate` instances without the edit state again: the save pins the
> sub-scene root's class and properties into the owner scene, so later changes to
> that root never reach the instance. With 1.9's scriptless `Sv2Sub` root, `type=`
> is the sign this step can show; a pinned `script =` line in the block appears
> only when the sub-scene's root has a script. Flag as **Major**.

**2.14b** `scene_instantiate` (imported model) — scene_path=`res://Validations/fixtures/imported_triangle.glb`, parent_path=`.`, as_name=`Sv2Model`
- **Expect:** success, Sv2Model added. The `.glb` is a committed one-triangle fixture the editor imports as a scene (its `.import` sidecar is tracked beside it).
- **Setup:** the step needs the toolkit dogfood's committed fixtures, `Validations/fixtures/imported_triangle.glb` and `mesh_triangle.obj`, each with its `.import` sidecar. **If a non-dogfood target lacks them** (e.g. the C# dogfood, minigames, or a fresh cross-version copy where `Validations/` isn't present), copy both fixtures and their sidecars into the target's `res://Validations/fixtures/`, then `editor_refresh` so the editor imports them (the same targets `tool-sweep.md` P.1 covers for the `EnvProbe` fixture).
- **Sidecar noise on 4.2–4.4:** the tracked sidecars are written by a 4.5 editor. A 4.2–4.4 editor on a fresh `.godot/` reimports both fixtures and rewrites the two `.import` files with its own option list. That rewrite is noise: never stage it, and restore the 4.5 copies after the run (`git restore Validations/fixtures/imported_triangle.glb.import Validations/fixtures/mesh_triangle.obj.import`).
- **Saved-file check:** `editor_save_scene`, then `script_read` file_path=`res://sv2_validation/Sv2Main.tscn`. An `[ext_resource type="PackedScene" ...]` line points at `res://Validations/fixtures/imported_triangle.glb`, and the `[node name="Sv2Model" ...]` header carries `instance=ExtResource(...)` with that id and **no** `type=`.
- **Guard:** `scene_instantiate` scene_path=`res://Validations/fixtures/mesh_triangle.obj`, parent_path=`.`, as_name=`Sv2MeshModel` → **Expect:** `INVALID_CLASS`. The `.obj` fixture is imported as a mesh, and `.obj` is on the scene-extension list whichever importer a file uses, so loading the file is what refuses it.
- Cleanup: `scene_delete_node` node_path=`Sv2Model`, then `editor_save_scene`

> **REGRESSION WATCH (#39):** `INVALID_PATH` on the `.glb` means `scene_instantiate`
> takes `.tscn` files only again. A success on the `.obj` means the load-then-
> `PackedScene` check is gone. A `LOAD_FAILED` naming `editor_refresh` means the
> editor hasn't imported the fixture: run `editor_refresh` and retry before
> flagging. Flag a real regression as **Major**.

**2.15** `scene_instantiate` (with transform override) — scene_path=`res://sv2_validation/sub.tscn`, parent_path=`.`, name=`Sv2SubProps`, transform=`{"position": {"type": "Vector2", "x": 50, "y": 75}}`
- **Expect:** success, Sv2SubProps created. Verify via `node_get_property` position = (50, 75). **Param name is `transform`, not `properties`** — single-mode `scene_instantiate` has no `properties` param; passing `properties` silently no-ops (success:true, position stays 0,0, no error) because `properties` is batch-only (inside `instances[]` entries — see 2.15a/C9). Use `transform` for the single-mode override.

> **REGRESSION WATCH (462506b):** If `transform` param is rejected or position
> is not applied, scene_instantiate's single-mode transform-override support has regressed. Flag as **Major**.
>
> **Bare-dict transforms are rejected, not dropped.** A single-mode `transform`
> with a bare untagged `{"x":.,"y":.}` `position`/`scale` (no `type` tag) is
> rejected `INVALID_PARAMS` with a hint to tag it as `{type:'Vector2', x, y}` — it
> no longer silently no-ops to (0,0). The batch analogue surfaces the same in
> `property_errors` (see C9b). Always tag transform vectors.

**2.15a** `scene_instantiate` (batch all-success — rollup keys ABSENT) — scene_path=`res://sv2_validation/sub.tscn`, parent_path=`.`, instances=`[{"name":"Sv2SubBatchA"},{"name":"Sv2SubBatchB"}]`
- **Expect:** success, `instances` array with 2 created nodes (Sv2SubBatchA, Sv2SubBatchB), `count`=2, and **NO** top-level `failed` key and **NO** top-level `hint` key (the batch-rollup is purely additive — an all-success batch keeps its prior `{status, count, instances, results}` shape). The per-entry `results` rows are all success=true.
- **Saved-file check (before the cleanup):** `editor_save_scene`, then `script_read` file_path=`res://sv2_validation/Sv2Main.tscn`. The `Sv2SubBatchA` and `Sv2SubBatchB` headers each carry `instance=ExtResource(...)` and **no** `type=`, and neither node's block has a `script =` line (2.14's #12 watch: as there, `type=` is the half that catches a regression, since `sub.tscn`'s root has no script).
- Cleanup: `scene_delete_node` node_path=`Sv2SubBatchA`, `scene_delete_node` node_path=`Sv2SubBatchB`

> **REGRESSION WATCH (concern 034 D, summarize_batch / 7244950):** `scene_instantiate`
> batch is wired to `Helpers.summarize_batch` over its `results[]`. On all-success,
> `failed`/`hint` must be ABSENT. If either key appears here, the `failed > 0` gate
> regressed. Flag as **Major**.
> **Partial-failure note:** the whole-entry failing path (a per-entry `{index,
> success:false, error}` row) only fires when `PackedScene.instantiate()` returns null
> for an entry, which cannot be selectively triggered from a valid `.tscn` via the MCP
> surface (a corrupt/missing scene fails the whole call at `LOAD_FAILED`/`NOT_FOUND`
> before the batch loop). That whole-entry rollup is therefore pinned by the headless
> unit `_test_summarize_batch` (site-3 `{success:false}` shape) rather than this sweep —
> see `test/run_unit_tests.gd`. A **per-key** transform error (bare-dict `position`/
> `scale`) IS reachable and attaches to a *succeeding* entry as `property_errors`
> without bumping top-level `failed` — covered by C9b.

**2.16** `scene_get_tree` — max_depth=2
- **Expect:** Tree shows all created nodes: Sv2Sprite, Sv2Label, Sv2AnimPlayer, Sv2AnimTree, Sv2TileLayer, Sv2Player/Sv2Collider, Sv2Path, Sv2NavRegion, Sv2Unique, Sv2Sub, Sv2SubProps

**2.17** `editor_save_scene`
- **Expect:** success

**2.18** Path normalization — `node_get_property` node_path=`/root/Sv2Main/Sv2Sprite`, property=`visible`
- **Expect:** success (toolkit normalizes `/root/Sv2Main/Sv2Sprite` → `Sv2Sprite`)

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

Delete instantiated sub-scenes (not needed for later sections):
- `scene_delete_node` node_path=`Sv2SubProps`
- `scene_delete_node` node_path=`Sv2Sub`
