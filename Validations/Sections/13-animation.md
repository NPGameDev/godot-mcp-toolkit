# Section 13 — Animation & AnimationTree

**Dependencies:** Section 2 (Sv2AnimPlayer and Sv2AnimTree exist in main.tscn)
**Tools tested:** animation_keyframe, animation_get_keys, animationtree_edit, node_call_method
**Tests:** 12

---

**13.1** `node_call_method` — node_path=`Sv2AnimPlayer`, method=`add_animation_library`, args=`["sv2_lib", {"type":"Resource","path":"res://sv2_validation/anim_lib.tres"}]`
- **Expect:** success or null (built-in AnimationPlayer may return null without @tool)

**13.2** `animation_keyframe` — node_path=`Sv2AnimPlayer`, animation=`sv2_lib/idle`, track_property=`Sv2Sprite:position`, time=0.0, value=`{"type":"Vector2","x":100,"y":100}`
- **Expect:** success

**13.3** `animation_keyframe` — node_path=`Sv2AnimPlayer`, animation=`sv2_lib/idle`, track_property=`Sv2Sprite:position`, time=1.0, value=`{"type":"Vector2","x":200,"y":200}`
- **Expect:** success

**13.4** `animation_get_keys` — node_path=`Sv2AnimPlayer`, animation=`sv2_lib/idle`
- **Expect:** 2 keyframes on position track

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

**13.10** `animationtree_edit` (list) — node_path=`Sv2AnimTree`, action=`list`
- **Expect:** nodes=[idle, run], transitions=[2 entries]

**13.11** `animationtree_edit` guard — node_path=`Sv2Sprite`, action=`list`
- **Expect:** INVALID_CLASS mentioning AnimationTree

**13.12** `editor_save_scene`
- **Expect:** success

---

## Cleanup

None (animation state persists for runtime tests in Section 20).
