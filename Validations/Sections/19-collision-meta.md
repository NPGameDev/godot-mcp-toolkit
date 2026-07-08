# Section 19 — collision_from_texture

**Dependencies:** Section 2 (Sv2Main.tscn open)
**Tools tested:** collision_from_texture
**Tests:** 3

> **Note:** `meta.set_limits` is an internal bridge tool (server → plugin) and is NOT
> exposed to agents. It is not tested here.

---

**19.1** Create sprite with texture:
- `scene_create_node` node_type=`Sprite2D`, node_name=`Sv2CollSprite`, parent_path=`.`
- `node_set_property` node_path=`Sv2CollSprite`, property=`texture`, value=`{"type":"Resource","path":"res://icon.svg"}`
- **Expect:** both succeed

**19.2** `collision_from_texture` — sprite_path=`Sv2CollSprite`, simplification=2.0
- **Expect:** success, polygon_count > 0, total_points > 0

**19.3** `collision_from_texture` guard — sprite_path=`.` (scene root, not Sprite2D)
- **Expect:** INVALID_CLASS mentioning Sprite2D

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- `scene_delete_node` node_path=`Sv2CollSprite`
- `scene_delete_node` node_path=`Sv2CollSprite_collision` (the generated CollisionPolygon2D is a **sibling** of the sprite at the scene root — `collision_from_texture`'s `parent_path` defaults to the sprite's *parent*, not the sprite — so delete it separately; it is NOT a child of the sprite)
