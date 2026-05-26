# Section 4 — Node Management

**Dependencies:** Section 2 (nodes exist in main.tscn)
**Tools tested:** node_manage (rename, reparent, reorder, duplicate), node_groups
**Tests:** 14

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

**4.12** `node_groups` (batch add) — action=`add`, node_path=`Sv2Player`, groups=`["sv2_enemies", "sv2_actors"]`
- **Expect:** success

> **REGRESSION WATCH (462506b):** If `groups` array (batch mode) is rejected and
> only single `group` param works, batch node_groups has regressed. Flag as **Major**.

**4.13** `node_groups` (list) — action=`list`, node_path=`Sv2Player`
- **Expect:** includes both `sv2_enemies` and `sv2_actors`

**4.14** `node_groups` (batch remove) — action=`remove`, node_path=`Sv2Player`, groups=`["sv2_enemies", "sv2_actors"]`
- **Expect:** success

---

## Console error check

Call `editor_get_console` and scan output since section start for `UndoRedo history mismatch`. Guard tests produce intentional error logs (e.g., `Failed loading resource`) — ignore those.
- **FAIL** if any `UndoRedo history mismatch` line appears.
- **PASS** otherwise.

## Cleanup

- `scene_delete_node` node_path=`Sv2LabelCopy`
- `scene_delete_node` node_path=`Sv2SpriteCopy`
