# Section 1 — Scaffolding & Core File Operations

**Dependencies:** Section 0
**Tools tested:** folder_create, script_write, resource_write, scene_create, scene_open
**Tests:** 10

Creates all shared test artifacts used by later sections.

---

**1.1** `folder_create` — folder_path=`res://sv2_validation/`
- **Expect:** success

**1.2** `script_write` — file_path=`res://sv2_validation/actor.gd`, content:
```gdscript
extends CharacterBody2D

class_name Sv2Actor

@export var speed := 100.0
@export var label := "default"

signal hit

func get_info() -> String:
	return "Sv2Actor v1"

func _ready() -> void:
	pass
```
- **Expect:** success

> **REGRESSION WATCH (FIX-1, T:98c02f3):** Response MUST include `valid` and
> `diagnostics` fields. If only `success` is returned without inline diagnostics,
> the script_write auto-check has regressed. Flag as **Critical**.

**1.3** Verify `script_write` diagnostics — check that the response from 1.2 contains:
- `valid: true` (script has no errors)
- `diagnostics: []` (empty array, no issues)
- If these fields are missing, record as FAIL with note "FIX-1 regression: diagnostics not inline"

**1.4** `script_write` — file_path=`res://sv2_validation/shader.gdshader`, content:
```glsl
shader_type canvas_item;
uniform float brightness : hint_range(0,1) = 0.5;
uniform vec4 tint : source_color = vec4(1,1,1,1);
void fragment() {
	COLOR = texture(TEXTURE, UV) * tint * brightness;
}
```
- **Expect:** success

**1.5** `resource_write` — file_path=`res://sv2_validation/anim_lib.tres`, type=`AnimationLibrary`
- **Expect:** success, status=created

**1.6** `resource_write` — file_path=`res://sv2_validation/material.tres`, type=`ShaderMaterial`, properties=`{"shader": {"type": "Resource", "path": "res://sv2_validation/shader.gdshader"}, "shader_parameter/brightness": 0.75}`
- **Expect:** success, resource_class=ShaderMaterial

**1.7** `resource_write` — file_path=`res://sv2_validation/tileset.tres`, type=`TileSet`, properties=`{"tile_size": {"type": "Vector2i", "x": 16, "y": 16}}`
- **Expect:** success

**1.8** `scene_create` — file_path=`res://sv2_validation/main.tscn`, root_type=`Node2D`, root_name=`Sv2Main`
- **Expect:** success

**1.9** `scene_create` — file_path=`res://sv2_validation/sub.tscn`, root_type=`Node2D`, root_name=`Sv2Sub`
- **Expect:** success

**1.10** `scene_open` — file_path=`res://sv2_validation/main.tscn`
- **Expect:** success

---

## Console error check

Call `editor_get_console` and scan output since section start for unexpected errors.
- **FAIL** if any line contains: `UndoRedo history mismatch`, `SCRIPT ERROR`, `FATAL`, or unexpected `ERROR:` lines not caused by intentional guard tests.
- **PASS** if only expected noise (e.g., `Failed loading resource` from NOT_FOUND guard tests).
- Note: expected errors from guard tests (e.g., loading nonexistent resources) are NOT failures.

## Cleanup

None — artifacts are used by all subsequent sections. Global cleanup (Section 25) handles removal.
