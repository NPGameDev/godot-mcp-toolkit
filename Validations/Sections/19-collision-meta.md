# Section 19 — collision_from_sprite

**Dependencies:** Section 2 (main.tscn open)
**Tools tested:** collision_from_sprite
**Tests:** 3

> **Note:** `meta.set_limits` is an internal bridge tool (server → plugin) and is NOT
> exposed to agents. It is not tested here.

---

**19.1** Create sprite with texture:
- `scene_create_node` node_type=`Sprite2D`, node_name=`Sv2CollSprite`, parent_path=`.`
- `node_set_property` node_path=`Sv2CollSprite`, property=`texture`, value=`{"type":"Resource","path":"res://icon.svg"}`
- **Expect:** both succeed

**19.2** `collision_from_sprite` — sprite_path=`Sv2CollSprite`, simplification=2.0
- **Expect:** success, polygon_count > 0, total_points > 0

**19.3** `collision_from_sprite` guard — sprite_path=`.` (scene root, not Sprite2D)
- **Expect:** INVALID_CLASS mentioning Sprite2D

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- `scene_delete_node` node_path=`Sv2CollSprite` (also removes collision children)
