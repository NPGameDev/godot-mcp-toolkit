# Section 15 — Theme, Audio, SpriteFrames

**Dependencies:** Section 1 (sv2_validation/ folder exists)
**Tools tested:** theme_edit, audiobus_edit, spriteframes_create, spriteframes_edit, spriteframes_from_spritesheet
**Tests:** 12

---

**15.1** `theme_edit` — file_path=`res://sv2_validation/theme.tres`, edits=[{type_name:"Button", property_type:"color", property_name:"font_color", value:{r:1,g:0,b:0,a:1}}, {type_name:"Label", property_type:"font_size", property_name:"font_size", value:24}]
- **Expect:** success, edits_applied=2

**15.2** `resource_load` — file_path=`res://sv2_validation/theme.tres`
- **Expect:** Theme with Button font_color and Label font_size set

**15.3** `theme_edit` guard — file_path=`res://sv2_validation/theme.tres`, edits=[{type_name:"Button", property_type:"invalid_type", property_name:"x", value:1}]
- **Expect:** INVALID_PARAMS mentioning "invalid_type"

**15.4** `audiobus_edit` — action=`add_bus`, bus_name=`"Sv2Music"`, send_to=`"Master"`
- **Expect:** success

**15.5** `audiobus_edit` — action=`set_bus`, bus_name=`"Sv2Music"`, volume_db=-6.0
- **Expect:** success

**15.6** `audiobus_edit` — action=`add_effect`, bus_name=`"Sv2Music"`, effect=`{"type":"Reverb"}`
- **Expect:** success

**15.7** `audiobus_edit` — action=`list`
- **Expect:** buses include Master + Sv2Music with Reverb effect

**15.8** `audiobus_edit` guard — action=`remove_bus`, bus_name=`"Master"`
- **Expect:** INVALID_PARAMS — cannot remove Master bus

**15.9** `spriteframes_create` — file_path=`res://sv2_validation/spriteframes.tres`, animations=[{name:"idle", frames:[{texture:"res://icon.svg"},{texture:"res://icon.svg"}]}, {name:"run", frames:[{texture:"res://icon.svg"},{texture:"res://icon.svg"},{texture:"res://icon.svg"},{texture:"res://icon.svg"}]}]
- **Expect:** success, 2 animations with correct frame counts

**15.10** `spriteframes_edit` — action=`add_animation`, animation_name=`"jump"`, file_path=`res://sv2_validation/spriteframes.tres`, fps=6
- **Expect:** success

**15.11** `spriteframes_edit` — action=`list`, file_path=`res://sv2_validation/spriteframes.tres`
- **Expect:** 3 animations: idle, run, jump

**15.12** `spriteframes_from_spritesheet` — texture_path=`res://icon.svg`, frame_size=`{"x":32,"y":32}`, file_path=`res://sv2_validation/spritesheet_frames.tres`, animations=[{name:"walk", row:0, frame_count:2}]
- **Expect:** success

---

## Cleanup

- `audiobus_edit` action=`remove_bus`, bus_name=`"Sv2Music"`
- `resource_delete` file_path=`res://sv2_validation/theme.tres`
- `resource_delete` file_path=`res://sv2_validation/spriteframes.tres`
- `resource_delete` file_path=`res://sv2_validation/spritesheet_frames.tres`
- If `theme` or `audio` groups were activated: call `discover_tools` with reset=["theme", "audio"] to deactivate them
