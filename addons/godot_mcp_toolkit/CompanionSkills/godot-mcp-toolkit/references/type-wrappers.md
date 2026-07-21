# Type wrappers for `node_set_property`

`node_set_property` (and its `batch` form) coerces plain scalars automatically:
plain numbers, strings, and booleans need **no** wrapper. Engine types must be
passed as a `{type: "...", ...}` object. An unknown `type` tag is rejected with
the list of supported tags, so a typo fails loudly rather than silently.

## Scalar and vector types

| Type tag | Format | Example |
|----------|--------|---------|
| `Vector2` | `{x, y}` | `{type: "Vector2", x: 100, y: 200}` |
| `Vector3` | `{x, y, z}` | `{type: "Vector3", x: 1, y: 2, z: 3}` |
| `Vector4` | `{x, y, z, w}` | `{type: "Vector4", x: 1, y: 2, z: 3, w: 4}` |
| `Vector2i` | integer `{x, y}` | `{type: "Vector2i", x: 10, y: 20}` |
| `Vector3i` | integer `{x, y, z}` | `{type: "Vector3i", x: 1, y: 2, z: 3}` |
| `Color` | `{r, g, b, a}` (a defaults to 1.0) | `{type: "Color", r: 1, g: 0, b: 0}` |
| `Rect2` | `{x, y, w, h}` | `{type: "Rect2", x: 0, y: 0, w: 100, h: 50}` |
| `Rect2i` | integer `{x, y, w, h}` | `{type: "Rect2i", x: 0, y: 0, w: 64, h: 64}` |
| `NodePath` | `{path}` | `{type: "NodePath", path: "../Player"}` |

## Resources

| Type tag | Format | Notes |
|----------|--------|-------|
| `Resource` | `{path}` | Bind an existing resource file: `{type: "Resource", path: "res://icon.png"}` |
| `NewResource` | `{class, properties}` | Build an inline sub-resource, e.g. a shape: `{type: "NewResource", class: "CircleShape2D", properties: {radius: 16}}` |

## Transforms

- `Transform2D`: `{type: "Transform2D", x_axis: {x, y}, y_axis: {x, y}, origin: {x, y}}`
- `Transform3D`: `{type: "Transform3D", x_axis: {x, y, z}, y_axis: {x, y, z}, z_axis: {x, y, z}, origin: {x, y, z}}`

## Packed arrays

Element values are themselves wrapped:

- `PackedVector2Array`: `{type: "PackedVector2Array", values: [{type: "Vector2", x: 0, y: 0}, {type: "Vector2", x: 1, y: 1}]}`
- `PackedVector3Array`: `{type: "PackedVector3Array", values: [{type: "Vector3", x: 0, y: 0, z: 0}, ...]}`
- `PackedColorArray`: `{type: "PackedColorArray", values: [{type: "Color", r: 1, g: 0, b: 0}, ...]}`

## Layer masks

`LayerMask` sets a collision/visibility bitmask by layer **number** or by
**name** (names come from a prior `layer_names_set` call). `category` defaults
to `2d_physics`.

- By number: `{type: "LayerMask", category: "2d_physics", layers: [1, 3]}`
- By name: `{type: "LayerMask", category: "2d_physics", layers: ["player", "enemy"]}`

## Compound property paths

- `/` separates sub-properties: `property: "position:x"` sets one component.
- `:` chains into a sub-resource: `property: "material:shader_parameter/value"`.
- `make_unique: true` (single or per-batch-entry) duplicates a shared external
  `.tres` before editing it, so the change does not leak into other users of
  that resource.

## Anchor caveat

Setting `anchors_preset` alone may not apply the corresponding offsets. Set the
`anchor_*` / `offset_*` sides explicitly, or use `control_set_layout` (anchor
preset + optional margins in one call, returns the final rect).
