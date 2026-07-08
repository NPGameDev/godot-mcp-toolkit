# Section 15 — Theme, Audio, SpriteFrames

**Dependencies:** Section 1 (sv2_validation/ folder exists)
**Tools tested:** theme_edit, audiobus_edit, audiobus_list, spriteframes_create, spriteframes_edit, spriteframes_from_spritesheet
**Tests:** 14

---

**15.1** `theme_edit` — file_path=`res://sv2_validation/theme.tres`, edits=[{type_name:"Button", property_type:"color", property:"font_color", value:{r:1,g:0,b:0,a:1}}, {type_name:"Label", property_type:"font_size", property:"font_size", value:24}]
- **Expect:** success, edits_applied=2

**15.2** `resource_load` — file_path=`res://sv2_validation/theme.tres`
- **Expect:** Theme with Button font_color and Label font_size set

**15.3** `theme_edit` guard — file_path=`res://sv2_validation/theme.tres`, edits=[{type_name:"Button", property_type:"invalid_type", property:"x", value:1}]
- **Expect:** MCP schema-enum rejection (`-32602`) listing the 6 valid `property_type` values (color/constant/font/font_size/icon/stylebox). The rejection does NOT echo the literal invalid value `"invalid_type"` back — that is an acceptable guard form for a Zod enum (pre-plugin validation), not a plugin-level `INVALID_PARAMS` with the offending value quoted.

**15.4** `audiobus_edit` — action=`add_bus`, bus_name=`"Sv2Music"`, send_to=`"Master"`
- **Expect:** success

**15.5** `audiobus_edit` — action=`set_bus`, bus_name=`"Sv2Music"`, volume_db=-6.0
- **Expect:** success

**15.6** `audiobus_edit` — action=`add_effect`, bus_name=`"Sv2Music"`, effect=`{"type":"Reverb"}`
- **Expect:** success

**15.7** `audiobus_list` — (no params)
- **Expect:** buses include Master + Sv2Music with Reverb effect

**15.8** `audiobus_edit` guard — action=`remove_bus`, bus_name=`"Master"`
- **Expect:** INVALID_PARAMS — cannot remove Master bus

**15.9** `spriteframes_create` — file_path=`res://sv2_validation/spriteframes.tres`, animations=[{name:"idle", frames:[{texture_path:"res://icon.svg"}]}, {name:"run", frames:[{texture_path:"res://icon.svg"},{texture_path:"res://icon.svg"}]}]
- **Expect:** success, 2 animations with correct frame counts (idle=1, run=2)

> **Fixture size — keep tiny on purpose.** Distinct per-animation frame counts
> (1 and 2) prove the frame-count contract exactly as larger counts would;
> byte-identical extra frames add no coverage. Do not inflate.

**15.10** `spriteframes_edit` — action=`add_animation`, animation_name=`"jump"`, file_path=`res://sv2_validation/spriteframes.tres`, fps=6
- **Expect:** success

**15.11** `spriteframes_edit` — action=`list`, file_path=`res://sv2_validation/spriteframes.tres`
- **Expect:** 3 animations: idle, run, jump

**15.12** `spriteframes_from_spritesheet` — texture_path=`res://icon.svg`, frame_size=`{"x":32,"y":32}`, file_path=`res://sv2_validation/spritesheet_frames.tres`, animations=[{name:"walk", row:0, frame_count:2}]
- **Expect:** success

**15.13** `spriteframes_create` guard — file_path=`res://sv2_validation/sf_guard.tres`, animations=[{name:"idle", frames:[{texture_path:"res://nonexistent_frame.png"}]}]
- **Expect:** NOT_FOUND naming the missing texture (no .tres written — guard fires before save)

**15.14** `spriteframes_create` guard — file_path=`res://sv2_validation/sf_guard.png`, animations=[{name:"idle", frames:[{texture_path:"res://icon.svg"}]}]
- **Expect:** INVALID_PATH mentioning `.tres` (writes .tres files — no file written)

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- `audiobus_edit` action=`remove_bus`, bus_name=`"Sv2Music"`
- `resource_delete` file_path=`res://sv2_validation/theme.tres`
- `resource_delete` file_path=`res://sv2_validation/spriteframes.tres`
- `resource_delete` file_path=`res://sv2_validation/spritesheet_frames.tres`
- Call `discover_tools` with reset=true to deactivate all on-demand groups activated during this section
