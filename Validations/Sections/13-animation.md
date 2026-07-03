# Section 13 — Animation & AnimationTree

**Dependencies:** Section 2 (Sv2AnimPlayer and Sv2AnimTree exist in Sv2Main.tscn)
**Tools tested:** animation_keyframe, animation_get_keys, animationtree_edit, animationtree_list, node_call_method
**Tests:** 12

---

**13.1** `node_call_method` — node_path=`Sv2AnimPlayer`, method=`add_animation_library`, args=`["sv2_lib", {"type":"Resource","path":"res://sv2_validation/anim_lib.tres"}]`
- **Expect:** success or null (built-in AnimationPlayer may return null without @tool)

**13.2** `animation_keyframe` — action=`add`, player_path=`Sv2AnimPlayer`, animation_name=`sv2_lib/idle`, track_path=`Sv2Sprite:position`, time=0.0, value=`{"type":"Vector2","x":100,"y":100}`
- **Expect:** success. **Param shape:** `player_path` (not `node_path`), `animation_name` (not `animation`), `track_path` (not `track_property`), plus a required `action` (`add`/`remove`). The library/animation `sv2_lib/idle` did not pre-exist in the empty `anim_lib` library — `animation_keyframe` **auto-creates** the animation on first keyframe write; the tool does NOT require it to already exist despite older prose to the contrary.

**13.3** `animation_keyframe` — action=`add`, player_path=`Sv2AnimPlayer`, animation_name=`sv2_lib/idle`, track_path=`Sv2Sprite:position`, time=1.0, value=`{"type":"Vector2","x":200,"y":200}`
- **Expect:** success

**13.4** `animation_get_keys` — player_path=`Sv2AnimPlayer`, animation_name=`sv2_lib/idle`, track_path=`Sv2Sprite:position`
- **Expect:** 2 keyframes on the position track: t=0→(100,100), t=1→(200,200). **`track_path` is required** — it was missing from the older param list.

**13.5** `animationtree_edit` (set root) — node_path=`Sv2AnimTree`, action=`set_root`, root_type=`AnimationNodeStateMachine`
- **Expect:** success

**13.6** `animationtree_edit` (add node) — node_path=`Sv2AnimTree`, action=`add_node`, node_name=`idle`, node_type=`AnimationNodeAnimation`, animation_name=`idle`
- **Expect:** success

**13.7** `animationtree_edit` (add node) — node_path=`Sv2AnimTree`, action=`add_node`, node_name=`run`, node_type=`AnimationNodeAnimation`, animation_name=`run`
- **Expect:** success

**13.8** `animationtree_edit` (add transition) — node_path=`Sv2AnimTree`, action=`add_transition`, from=`idle`, to=`run`, advance_condition=`is_running`
- **Expect:** success

**13.9** `animationtree_edit` (add transition) — node_path=`Sv2AnimTree`, action=`add_transition`, from=`run`, to=`idle`, advance_mode=`auto`
- **Expect:** success

**13.10** `animationtree_list` — node_path=`Sv2AnimTree`
- **Expect:** nodes=[idle, run], transitions=[2 entries]

**13.11** `animationtree_list` guard — node_path=`Sv2Sprite`
- **Expect:** INVALID_CLASS mentioning AnimationTree

**13.12** `editor_save_scene`
- **Expect:** success

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- Call `discover_tools` with reset=true to deactivate all on-demand groups activated during this section
- Animation state persists for runtime tests in Section 20.
