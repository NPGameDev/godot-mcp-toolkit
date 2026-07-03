# Section 3 — Node Properties & Methods

**Dependencies:** Section 2 (nodes exist in Sv2Main.tscn)
**Tools tested:** node_set_property, node_get_property, node_set_script, node_get_property_list, node_call_method, control_set_layout
**Tests:** 35

---

**3.1** `node_set_property` — node_path=`Sv2Sprite`, property=`position`, value=`{"type":"Vector2","x":100,"y":100}`
- **Expect:** success

**3.2** `node_get_property` — node_path=`Sv2Sprite`, property=`position`
- **Expect:** Vector2(100, 100)

**3.3** `node_set_property` — node_path=`Sv2Label`, property=`text`, value=`"Hello Sweep v2"`
- **Expect:** success

**3.4** `node_set_property` (compound path) — node_path=`Sv2Label`, property=`theme_override_colors/font_color`, value=`{"type":"Color","r":1,"g":0,"b":0,"a":1}`
- **Expect:** success

**3.5** `node_get_property` (compound path) — node_path=`Sv2Label`, property=`theme_override_colors/font_color`
- **Expect:** Color(1, 0, 0, 1)

**3.6** `node_set_property` (Resource ref) — node_path=`Sv2Sprite`, property=`material`, value=`{"type":"Resource","path":"res://sv2_validation/material.tres"}`
- **Expect:** success

> **REGRESSION WATCH (FIX-E, 7e63aee):** Resource type tag `{"type":"Resource","path":"..."}` must work.
> If the tool requires a different format or fails silently, Resource type handling has regressed.

**3.7** `node_set_property` (ResourceRef alias) — create temp Sprite2D, set texture:
- First: `scene_create_node` node_type=`Sprite2D`, node_name=`Sv2RefTest`, parent_path=`.`
- Then: `node_set_property` node_path=`Sv2RefTest`, property=`texture`, value=`{"type":"ResourceRef","path":"res://icon.svg"}`
- **Expect:** success — "ResourceRef" alias accepted

> **REGRESSION WATCH (c61d994, Pitfall 4):** If "ResourceRef" is rejected and only
> "Resource" works, the alias support has regressed. Flag as **Major**.

**3.8** `node_set_property` (colon-chain) — node_path=`Sv2Sprite`, property=`material:shader_parameter/brightness`, value=0.3
- **Expect:** success

**3.9** `node_get_property` (colon-chain readback) — node_path=`Sv2Sprite`, property=`material:shader_parameter/brightness`
- **Expect:** 0.3

**3.10** `node_set_property` (bare res:// guard) — node_path=`Sv2RefTest`, property=`texture`, value=`"res://icon.svg"`
- **Expect:** success OR hint warning about bare string without type wrapper

> **REGRESSION WATCH (FIX-F, 7e63aee):** If a bare `res://` string is silently
> accepted without any hint/warning, the bare-res detection has regressed. The tool
> should either reject with a hint or accept with a diagnostic note.

**3.11** `node_set_property` (LayerMask coercion) — node_path=`Sv2Player`, property=`collision_layer`, value=`{"type":"LayerMask","layers":[1,3]}`
- **Expect:** success, collision_layer set to 5 (layers 1 and 3 → bits 0 and 2 → 1 + 4 = 5)

> **REGRESSION WATCH (462506b):** If `LayerMask` type tag is rejected, coercion
> has regressed. Flag as **Major**.

**3.12** `node_set_property` (batch mode) — batch=`[{"node_path":"Sv2Label","property":"text","value":"Batch1"},{"node_path":"Sv2Sprite","property":"visible","value":false}]`
- **Expect:** success, results array with 2 entries both showing success

> **REGRESSION WATCH (FIX-7, T:98c02f3):** If `batch` parameter is rejected or
> returns a single result instead of per-item results, batch mode has regressed.
> Flag as **Critical**.

**3.13** Verify batch — `node_get_property` Sv2Label text = "Batch1", `node_get_property` Sv2Sprite visible = false
- **Expect:** Both match

**3.14** Restore — `node_set_property` Sv2Sprite visible=true, Sv2Label text="Hello Sweep v2"

**3.14c** `node_set_property` (batch partial failure — top-level rollup) — batch=`[{"node_path":"Sv2Label","property":"text","value":"BatchOK"},{"node_path":"Sv2NoSuchNode","property":"text","value":"x"}]`
- **Expect:** success (the call itself succeeds). `results[0]` success=true; `results[1]` success=false with error "node not found". A top-level `failed` = **1** (integer — the round-trip floats ints, so compare as `int(failed) == 1`, never a bare-int whole-dict compare) AND a top-level `hint` string is present, reading "1 of 2 entries failed — inspect results[] for per-entry .error.". The valid sibling still committed: `node_get_property` Sv2Label text = "BatchOK".
- Restore: `node_set_property` Sv2Label text="Hello Sweep v2"

> **REGRESSION WATCH (concern 034 D, summarize_batch / eb25de5):** A batch with ≥1
> failing entry must surface a top-level `failed` (int count) + `hint` so a caller
> reading only the top of the response sees the partial failure without inspecting
> every entry. The fields come from `Helpers.summarize_batch` (`editor_helpers.gd`).
> If `failed`/`hint` are absent when an entry failed, the additive rollup has
> regressed. Flag as **Major**. (`failed` crosses a JSON boundary → coerce with
> `int(...)`; never assert the whole response dict by equality.)

**3.14d** `node_set_property` (batch all-success — rollup ABSENT) — batch=`[{"node_path":"Sv2Label","property":"text","value":"AllOK"},{"node_path":"Sv2Sprite","property":"visible","value":true}]`
- **Expect:** success, both `results` entries success=true, and **NO** top-level `failed` key. `node_set_property` emits a generic boilerplate top-level `hint` key on **every** response regardless of outcome (has since 3.1 — a plain single-prop success carries it too), so its literal presence/absence is not the signal here. What must be ABSENT on an all-success batch is the **failure-rollup hint TEXT** — the "N of M entries failed — inspect results[] for per-entry .error." message from 3.14c. Read "no hint" as "no failure-diagnostic hint text", not "no `hint` key" (the additive rollup is purely about `failed` + that specific text).
- Restore: `node_set_property` Sv2Label text="Hello Sweep v2"

> **REGRESSION WATCH (concern 034 D, summarize_batch):** This is the additive-only
> control — the top-level `failed` key and the failure-rollup hint TEXT must NOT
> appear when every entry succeeded. If `failed` shows up, or the boilerplate
> `hint` key's text reads as a failure-rollup message, on an all-success batch,
> the helper stopped gating on `failed > 0` and existing clients would see a
> changed shape. Flag as **Major**.

**3.14a** `node_set_property` (groups rejection, single) — node_path=`Sv2Sprite`, property=`groups`, value=`["enemies"]`
- **Expect:** INVALID_PARAMS, whole call rejected, hint names `node.groups`. The node's group membership is unchanged (nothing added/stripped).

> **REGRESSION WATCH (concern 032):** `node_set_property` must NOT set `groups`.
> It does a declarative full-set replace (would silently drop groups not listed);
> group mutation belongs to `node_groups` (incremental). If `property:"groups"`
> succeeds or alters membership, the rejection has regressed. Flag as **Major**.
> The guard is parameter-level (fires BEFORE node resolution, mirroring the batch
> path): an invalid `node_path` with `property:"groups"` must still return
> INVALID_PARAMS + the `node.groups` hint, NOT NOT_FOUND. If it returns NOT_FOUND,
> the reject has drifted back behind node resolution.

**3.14b** `node_set_property` (groups rejection, batch — rest still applies) — batch=`[{"node_path":"Sv2Sprite","property":"groups","value":["enemies"]},{"node_path":"Sv2Label","property":"text","value":"AfterGroups"}]`
- **Expect:** `results[0]` success=false with an error + hint naming `node.groups` (the groups entry is skipped); `results[1]` success=true. Verify `node_get_property` Sv2Label text = "AfterGroups" (the valid sibling entry committed) and Sv2Sprite is NOT in group "enemies".
- Restore: `node_set_property` Sv2Label text="Hello Sweep v2"

> **REGRESSION WATCH (concern 032):** This pins the per-entry batch contract —
> a rejected entry must not abort the batch. Before the fix the batch path had no
> groups branch, so `property:"groups"` fell through to a silent no-op. If the
> whole batch is rejected, or the groups entry silently "succeeds", flag as **Major**.

**3.15** `node_set_script` — node_path=`Sv2Player`, script_path=`res://sv2_validation/actor.gd`
- **Expect:** success

**3.16** `node_get_property_list` — node_path=`Sv2Player`, mask=`script`
- **Expect:** Only script-defined properties: speed, label

**3.17** `node_get_property_list` — node_path=`Sv2Player`, mask=`common`
- **Expect:** Curated commonly-used properties

**3.18** `node_get_property_list` — node_path=`Sv2Player`, mask=`all`
- **Expect:** Full property list including engine + script properties

**3.19** `node_call_method` — node_path=`Sv2Player`, method=`get_info`, args=`[]`
- **Expect:** `result: null`, `success: true` — `Sv2Player`'s `actor.gd` is **not** `@tool`, so the editor never runs it and `callv` cannot dispatch `get_info` (editor console logs "Method not found"). Response carries a hint that **leads with the runtime path** (game.start + execute_code / runtime_get_node_state on the live node), then the editor `@tool` fix, version-gated: on **4.5+** add `@tool` then close+reopen the scene (`scene_close` + `scene_open`; editor_refresh is not sufficient); **below 4.5** add `@tool` then relaunch the editor. The hint must **not** blame "uninitialized state / _Ready() not run".

**3.20** `node_set_property` (PackedVector2Array) — node_path=`Sv2Path`, property=`curve:_data:points`, value=`{"type":"PackedVector2Array","values":[{"type":"Vector2","x":0,"y":0},{"type":"Vector2","x":100,"y":50},{"type":"Vector2","x":200,"y":0}]}`
- **Expect:** success OR acceptable error (Curve2D has specific internal format). **Payload shape:** the array key is `values` (not `value`) with Vector2-**tagged** elements (not bare `{x,y}`) — matches 3.20b's confirmed tagged round-trip shape. `Sv2Path`'s curve is null by default, so `NOT_FOUND` here is expected/acceptable and is NOT a rejection of the `PackedVector2Array` type tag (see FIX-5 below).

> **REGRESSION WATCH (FIX-5, T:98c02f3):** If `PackedVector2Array` type tag is
> rejected with "unknown type", packed array coercion has regressed. Flag as **Major**.

> **REGRESSION WATCH (concern 053):** Reading a Packed property
> (`PackedVector2Array`/`PackedVector3Array`/`PackedColorArray`) back via
> `node_get_property` must now return the TAGGED dict form
> `{"type":"PackedVector2Array","values":[…]}`, NOT a `var_to_str` string like
> `"PackedVector2Array(1, 2, …)"`. Read-form must equal write-form so the LLM can
> round-trip (read→modify→write `Polygon2D.polygon`, `Line2D.points`, etc.). A
> string read-back means the `serialize_value` symmetry regressed. (The unit suite
> holds the authoritative coerce∘serialize round-trip.) Flag as **Major**.

**3.20a** Setup — `scene_create_node` node_type=`Line2D`, node_name=`Sv2PackedLine`, parent_path=`.`
- **Expect:** success (a node whose `points` is a top-level `PackedVector2Array` — no sub-resource path, so the read==write contract is exercised directly).

**3.20b** `node_set_property` then `node_get_property` (Packed read-back is TAGGED — concern 053):
- First: `node_set_property` node_path=`Sv2PackedLine`, property=`points`, value=`{"type":"PackedVector2Array","values":[{"type":"Vector2","x":0,"y":0},{"type":"Vector2","x":100,"y":50},{"type":"Vector2","x":200,"y":0}]}`
- Then: `node_get_property` node_path=`Sv2PackedLine`, property=`points`
- **Expect:** the read returns the TAGGED dict `{"type":"PackedVector2Array","values":[{"type":"Vector2","x":0,"y":0},{"type":"Vector2","x":100,"y":50},{"type":"Vector2","x":200,"y":0}]}` — a Dictionary with `type=="PackedVector2Array"` and a `values` array, **NOT** a `var_to_str` string like `"PackedVector2Array((0, 0), (100, 50), (200, 0))"`. The read value must equal what was written (read==write round-trip).

> **REGRESSION WATCH (concern 053, T:8856546):** This is the executable backing for
> the concern-053 watch on 3.20. `node_get_property` of a `PackedVector2Array`
> property must return the tagged dict (so the LLM can read→modify→write
> `Line2D.points` / `Polygon2D.polygon`). A String read-back (or any non-Dictionary)
> means `serialize_value` stopped routing the read path — flag as **Major**. The
> headless unit `_test_node_packed_property_serialize` pins the same contract on a
> node-sourced value without an editor.

**3.21** `node_set_property` (integer font size) — node_path=`Sv2Label`, property=`theme_override_font_sizes/font_size`, value=24
- **Expect:** success

**3.22** `node_get_property` — node_path=`Sv2Label`, property=`theme_override_font_sizes/font_size`
- **Expect:** 24

## control.set_layout (41l — W1 Lane 2)

**3.23** Setup — `scene_create_node` node_type=`Control`, node_name=`Sv2LayoutTest`, parent_path=`.`
- **Expect:** success

**3.24** `control_set_layout` — node_path=`Sv2LayoutTest`, preset=`PRESET_FULL_RECT`
- **Expect:** success, anchors set to full rect (0,0,1,1). **Caveat:** if the response's `final_rect` reports `(0,0)` instead of a computed size, this is expected when the control's parent (`Sv2LayoutTest`'s parent is the scene root, a `Node2D`) is not itself a `Control` — there is no reference size to compute against, and it is NOT a preset-logic bug. Verify the anchors directly via `node_get_property` (`anchor_left`/`anchor_right`/`anchor_top`/`anchor_bottom`) rather than relying on `final_rect` in this context.

**3.25** `control_set_layout` — node_path=`Sv2LayoutTest`, preset=`PRESET_CENTER`, resize_mode=`keep_size`
- **Expect:** success

**3.26** `control_set_layout` (with margins) — node_path=`Sv2LayoutTest`, preset=`PRESET_TOP_WIDE`, margins=`{"left":10,"right":10,"top":5,"bottom":0}`
- **Expect:** success, margins applied

**3.27** `control_set_layout` guard (invalid preset) — node_path=`Sv2LayoutTest`, preset=`INVALID_PRESET_NAME`
- **Expect:** INVALID_PARAMS, error mentions valid preset names

**3.28** `control_set_layout` guard (wrong node type) — node_path=`Sv2Sprite`, preset=`PRESET_FULL_RECT`
- **Expect:** error (INVALID_CLASS or similar — Sprite2D is not a Control)

**3.29** `node_set_property` (rename the scene ROOT via the `name` property) — node_path=`.`, property=`name`, value=`"Sv2MainPropRenamed"`
- **Expect:** success — `name` is an ordinary settable property, root included; the root can be renamed both here and via `node_manage` rename (4.17 — the two paths agree since the manage root-guard relax).
- Restore: `node_set_property` node_path=`.`, property=`name`, value=`"Sv2Main"` (later sections depend on the root name).

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- `scene_delete_node` node_path=`Sv2RefTest`
- `scene_delete_node` node_path=`Sv2LayoutTest`
- `scene_delete_node` node_path=`Sv2PackedLine`
