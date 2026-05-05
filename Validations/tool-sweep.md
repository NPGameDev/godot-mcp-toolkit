# Universal MCP Tool Sweep

A comprehensive, self-contained validation sweep for the Godot MCP Toolkit. Covers all 57 MCP tools with realistic scenarios, expected results, and detailed reporting.

## How to Use

- **Full sweep:** Paste this prompt into a Claude Code session with the MCP server connected. The sweep auto-detects your Godot version, project type (GDScript/C#), and profile.
- **Cleanup only:** If a previous sweep failed mid-way, tell the LLM: "Run the cleanup section from the tool-sweep validation." It will remove all `mcp_validation` artifacts.
- **All test artifacts** live under `res://mcp_validation/` and use the `McpVal` class-name prefix. Nothing touches your existing project files except temporary `project_set_setting` changes that are restored during cleanup.

---

## Phase 0 — Environment Detection

Before running any test, gather project context. Record these in your report header.

**0.1** Call `project_get_settings` — extract:
- `application/config/name` — project name
- `application/run/main_scene` — current main scene (save for restore)
- `application/config/features` — Godot version (e.g. `"4.5"`, `"4.6"`)
- Check for `dotnet/project/assembly_name` — if present, this is a C# (.NET) project

**0.2** Call `asset_list` with folder_path=`res://` — scan for `.csproj` or `.cs` files. If found alongside the dotnet setting, confirm **C# project**. Otherwise, **GDScript project**.

**0.3** Check available tools — attempt to list tools or check if `game_eval` is available:
- If `game_eval` and `node_call_method` are available: **power_user** profile
- If tools are missing: note the profile. Suggest the user switch to `power_user` for a complete sweep. Ask how to proceed:
  - (A) Skip gated/unavailable tools
  - (B) Wait for user to enable them
  - (C) Switch to power_user profile
- If tool groups need loading (non-power_user), call `enable_tool_group` for: `runtime`, `signals`, `animation_authoring`, `input_map`, `asset_management`, `user_data`

**0.4** If C# project detected, call `editor_get_errors` — check for C# build errors. If present, warn the user that C# scripts may not work correctly until the solution is built.

**0.5** Detect version-specific capabilities (from features string):
| Feature | 4.2 | 4.3 | 4.4 | 4.5+ |
|---|---|---|---|---|
| TileMapLayer node | No (use TileMap) | Yes | Yes | Yes |
| scene_close | No | No | No | Yes (active tab only) |
| Logger API (buffer source) | File-dependent | File-dependent | File-dependent | Yes |

**scene_close behavior:** `scene_close` only closes the **currently active tab**. If the target scene is open but in an inactive tab, it returns an error with a hint. To remove an inactive scene, use `scene_delete` directly (it works on inactive tabs) or switch to it with `scene_open` first. Do NOT rely on scene_close to close background tabs.

Record the detected environment as: `Godot X.Y | GDScript or C# | Profile | Main scene`

---

## Phase 1 — Scaffolding (8 calls)

Create all test artifacts. Everything lives under `res://mcp_validation/`.

**1.** `folder_create` — folder_path=`res://mcp_validation/`
- **Expect:** success

**2.** `script_write` — file_path=`res://mcp_validation/val_actor.gd`, content:
```gdscript
extends CharacterBody2D

class_name McpValActor

@export var speed := 100.0
@export var label := "default"

signal hit

func get_info() -> String:
    return "McpValActor v1"

func _ready() -> void:
    pass
```
- **Expect:** success

**3.** `script_write` — file_path=`res://mcp_validation/val_shader.gdshader`, content:
```glsl
shader_type canvas_item;
uniform float brightness : hint_range(0,1) = 0.5;
uniform vec4 tint : source_color = vec4(1,1,1,1);
void fragment() {
    COLOR = texture(TEXTURE, UV) * tint * brightness;
}
```
- **Expect:** success

**4.** `resource_write` — file_path=`res://mcp_validation/val_anim_lib.tres`, type=`AnimationLibrary`
- **Expect:** success, status=created

**5.** `resource_write` — file_path=`res://mcp_validation/val_material.tres`, type=`ShaderMaterial`, properties=`{"shader": {"type": "Resource", "path": "res://mcp_validation/val_shader.gdshader"}, "shader_parameter/brightness": 0.75}`
- **Expect:** success, resource_class=ShaderMaterial

**6.** `resource_write` — file_path=`res://mcp_validation/val_tileset.tres`, type=`TileSet`, properties=`{"tile_size": {"type": "Vector2i", "x": 16, "y": 16}}`
- **Expect:** success

**7.** `scene_create` — file_path=`res://mcp_validation/val_main.tscn`, root_type=`Node2D`, root_name=`ValMain`
- **Expect:** success

**8.** `scene_create` — file_path=`res://mcp_validation/val_sub.tscn`, root_type=`Node2D`, root_name=`ValSub`
- **Expect:** success

---

## Phase 2 — Individual Tool Calls

### Introspection (9 calls)

**9.** `classdb_search` — pattern=`CharacterBody`
- **Expect:** Results including CharacterBody2D and CharacterBody3D

**10.** `classdb_get_info` — class_name=`AnimationPlayer`
- **Expect:** Properties, methods, signals for AnimationPlayer

**11.** `project_get_settings` — (no params or defaults)
- **Expect:** Dictionary of project settings

**12.** `asset_list` — folder_path=`res://mcp_validation/`
- **Expect:** Lists all 6 files created in scaffolding (2 scripts, 3 resources, 2 scenes — minus folder)

**13.** `asset_get_dependencies` — file_path=`res://mcp_validation/val_material.tres`
- **Expect:** Dependency on `res://mcp_validation/val_shader.gdshader`

**14.** `resource_load` — file_path=`res://mcp_validation/val_material.tres`
- **Expect:** class=ShaderMaterial, properties include shader reference and brightness=0.75

**15.** `script_read` — file_path=`res://mcp_validation/val_actor.gd`
- **Expect:** Full script content matching what was written

**16.** `script_read_range` — file_path=`res://mcp_validation/val_actor.gd`, start_line=1, end_line=3
- **Expect:** First 3 lines only (`extends CharacterBody2D`, empty line, `class_name McpValActor`)

**17.** `script_check` — file_path=`res://mcp_validation/val_actor.gd`
- **Expect:** No errors (valid GDScript)

### Scene Building (26 calls)

**18.** `scene_open` — file_path=`res://mcp_validation/val_main.tscn`
- **Expect:** success

**19.** `scene_get_tree` — (no params)
- **Expect:** Tree with root node ValMain (Node2D)

**20.** `scene_create_node` — node_type=`Sprite2D`, node_name=`ValSprite`, parent_path=`.`
- **Expect:** success

**21.** `scene_create_node` — node_type=`Label`, node_name=`ValLabel`, parent_path=`.`
- **Expect:** success

**22.** `scene_create_node` — node_type=`AnimationPlayer`, node_name=`ValAnimPlayer`, parent_path=`.`
- **Expect:** success

**23.** `scene_create_node` — node_type=`AnimationTree`, node_name=`ValAnimTree`, parent_path=`.`
- **Expect:** success

**24.** `scene_create_node` — **[4.3+]** node_type=`TileMapLayer`, node_name=`ValTileLayer`, parent_path=`.` | **[4.2]** node_type=`TileMap`, node_name=`ValTileLayer`, parent_path=`.`
- **Expect:** success

**25.** `scene_create_node` — node_type=`CharacterBody2D`, node_name=`ValPlayer`, parent_path=`.`
- **Expect:** success

**26.** `scene_create_node` — node_type=`CollisionShape2D`, node_name=`ValCollider`, parent_path=`ValPlayer`
- **Expect:** success

**27.** `node_set_property` — node_path=`ValSprite`, property=`position`, value=`{"type":"Vector2","x":100,"y":100}`
- **Expect:** success

**28.** `node_get_property` — node_path=`ValSprite`, property=`position`
- **Expect:** Vector2(100, 100)

**29.** `node_set_property` — node_path=`ValLabel`, property=`text`, value=`"Hello Validation"`
- **Expect:** success

**30.** `node_set_property` — node_path=`ValLabel`, property=`theme_override_colors/font_color`, value=`{"type":"Color","r":1,"g":0,"b":0,"a":1}`
- **Expect:** success

**31.** `node_get_property` — node_path=`ValLabel`, property=`theme_override_colors/font_color`
- **Expect:** Color(1, 0, 0, 1)

**32.** `node_set_property` — node_path=`ValLabel`, property=`theme_override_font_sizes/font_size`, value=24
- **Expect:** success

**33.** `node_get_property` — node_path=`ValLabel`, property=`theme_override_font_sizes/font_size`
- **Expect:** 24

**34.** `node_set_property` — node_path=`ValSprite`, property=`material`, value=`{"type":"Resource","path":"res://mcp_validation/val_material.tres"}`
- **Expect:** success

**35.** `node_set_property` — node_path=`ValSprite`, property=`material:shader_parameter/brightness`, value=0.3
- **Expect:** success

**36.** `node_get_property` — node_path=`ValSprite`, property=`material:shader_parameter/brightness`
- **Expect:** 0.3

**37.** `node_set_script` — node_path=`ValPlayer`, script_path=`res://mcp_validation/val_actor.gd`
- **Expect:** success, exports include speed and label

**38.** `node_get_property_list` — node_path=`ValPlayer`, mask=`common`
- **Expect:** Commonly-used properties

**39.** `node_get_property_list` — node_path=`ValPlayer`, mask=`all`
- **Expect:** Full property list including engine + script properties

**40.** `node_get_property_list` — node_path=`ValPlayer`, mask=`script`
- **Expect:** Only script-defined properties: speed, label

**41.** `scene_instantiate` — scene_path=`res://mcp_validation/val_sub.tscn`, parent_path=`.`
- **Expect:** success, ValSub node added to tree

**42.** `asset_import` — Create a minimal SVG file at `res://mcp_validation/val_icon.svg` using your Write tool (not an MCP call — use your local file system access):
```svg
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="#478cbf"/></svg>
```
Then call `asset_import` with file_path=`res://mcp_validation/val_icon.svg`
- **Expect:** success (Godot imports the SVG as a texture resource), `class` field should be non-null (e.g. `CompressedTexture2D`)

**42b.** `asset_get_dependencies` — file_path=`res://mcp_validation/val_icon.svg` (immediate usability check — NO `editor_reload_scripts` between 42 and 42b)
- **Expect:** success — the imported asset is immediately queryable without a separate `editor_reload_scripts` call. If this fails with NOT_FOUND or returns empty, the asset_import auto-scan did not complete.

**43.** `scene_get_tree` — (verify all nodes present)
- **Expect:** Tree showing ValSprite, ValLabel, ValAnimPlayer, ValAnimTree, ValTileLayer, ValPlayer/ValCollider, ValSub

### Signals (5 calls)

**44.** `signal_list` — node_path=`ValPlayer`
- **Expect:** Includes `hit` signal from val_actor.gd. No `connections` key (include_connections defaults to false).

**45.** `signal_manage` — node_path=`ValPlayer`, signal_name=`hit`, operation=`connect`, target_path=`ValLabel`, method=`set_text`
- **Expect:** success

**46.** `signal_list` — node_path=`ValPlayer`, include_connections=`true` (verify connection)
- **Expect:** `hit` signal includes `connections` array with entry `{ target_path: "ValLabel", method_name: "set_text", flags: 0 }`

**47.** `signal_manage` — node_path=`ValPlayer`, signal_name=`hit`, operation=`disconnect`, target_path=`ValLabel`, method=`set_text`
- **Expect:** success

**48.** `signal_list` — node_path=`ValPlayer`, include_connections=`true` (verify disconnection)
- **Expect:** `hit` signal's `connections` array is empty

### Animation & TileMap (6 calls)

**49.** `node_call_method` — node_path=`ValAnimPlayer`, method=`add_animation_library`, args=`["val_lib", {"type":"Resource","path":"res://mcp_validation/val_anim_lib.tres"}]`
- **Expect:** success (or null with hint about non-@tool script — either is acceptable for built-in AnimationPlayer)

**50.** `node_call_method` — node_path=`ValAnimPlayer`, method=`get_animation_list`
- **Expect:** List of animations (may be empty if library add returned null)

**51.** `animation_keyframe` — node_path=`ValAnimPlayer`, animation=`val_lib/idle`, track_property=`ValSprite:position`, time=0.0, value=`{"type":"Vector2","x":100,"y":100}`
- **Expect:** success

**52.** `animation_keyframe` — node_path=`ValAnimPlayer`, animation=`val_lib/idle`, track_property=`ValSprite:position`, time=1.0, value=`{"type":"Vector2","x":200,"y":200}`
- **Expect:** success

**53.** `animation_get_keys` — node_path=`ValAnimPlayer`, animation=`val_lib/idle`
- **Expect:** 2 keyframes on position track

**54.** `tilemap_set_cells` — node_path=`ValTileLayer`, cells=`[{"x":0,"y":0,"source_id":0,"atlas_x":0,"atlas_y":0},{"x":1,"y":0,"source_id":0,"atlas_x":0,"atlas_y":0}]`
- **Expect:** success (may warn about missing TileSet source — that's acceptable)

### Editor Operations (12 calls)

**55.** `editor_save_scene`
- **Expect:** success

**56.** `editor_screenshot`
- **Expect:** Returns inline PNG image

**57.** First assign the imported SVG as a texture: `node_set_property` — node_path=`ValSprite`, property=`texture`, value=`{"type":"Resource","path":"res://mcp_validation/val_icon.svg"}`. Then `editor_screenshot_node` — node_path=`ValSprite`
- **Expect:** Returns inline PNG image focused on ValSprite (now has visible texture content). Without a texture, Sprite2D returns EMPTY_CONTENT.

**58.** `editor_get_errors`
- **Expect:** success (may return errors — note count and whether any are validation-related)

**59.** `editor_get_console` — (default params)
- **Expect:** success, returns recent console output. **[4.5+]:** buffer source works instantly. **[<4.5]:** may require file logging enabled.

**60.** `editor_wait_for_idle`
- **Expect:** success (returns when EditorFileSystem is idle)

**61.** `editor_reload_scripts`
- **Expect:** success (flushes all filesystem changes — scripts, scenes, resources, imports �� to the editor)

**62.** `project_set_setting` — setting=`application/config/name`, value=`"McpValidationSweep"`
- **Expect:** success (will be restored during cleanup)

**63.** `scene_diff`
- **Expect:** success (diff of current scene state, may show unsaved changes from call 62)

**64.** `editor_save_scene` — (save after property changes)
- **Expect:** success

### Scene close/delete guards (6 calls) [4.5+ for scene_close tests, all versions for scene_delete tests]

Validates active-tab enforcement for both `scene_close` and `scene_delete`.

**64a.** `scene_create` — file_path=`res://mcp_validation/val_close_probe.tscn`, root_type=`Node2D`. Then `scene_open` same path.
- **Expect:** success — val_close_probe is now the active tab, val_main is inactive

**64b.** **[4.5+]** `scene_close` — file_path=`res://mcp_validation/val_main.tscn` (inactive tab)
- **Expect:** Error `EDITED_SCENE` with hint: "scene.close only closes the active tab ... use scene.delete directly (works on inactive tabs)."

**64c.** `scene_delete` — file_path=`res://mcp_validation/val_close_probe.tscn` (active tab)
- **Expect:** Error `EDITED_SCENE` — cannot delete the currently-edited scene

**64d.** `scene_open` — file_path=`res://mcp_validation/val_main.tscn` (switch back, val_close_probe now inactive)

**64e.** `scene_delete` — file_path=`res://mcp_validation/val_close_probe.tscn` (inactive tab)
- **Expect:** success — file deleted, stale tab is harmless

**64f.** **[4.5+]** `scene_open` — file_path=`res://mcp_validation/val_sub.tscn` (makes it active). Then `scene_close` — file_path=`res://mcp_validation/val_sub.tscn` (active tab)
- **Expect:** success — val_sub tab closed, val_main becomes the active tab again

**65.** `input_map_action` — action_name=`mcp_val_jump`, operation=`add`
- **Expect:** success

**66.** `input_map_event` — action_name=`mcp_val_jump`, event_type=`key`, keycode=`KEY_SPACE`, operation=`add`
- **Expect:** success

### Save System (4 calls)

**67.** `save_write` — save_path=`user://saves/mcp_validation_save.json`, content=`{"score": 42, "level": 3, "validation": true}`
- **Expect:** success

**68.** `save_read` — save_path=`user://saves/mcp_validation_save.json`
- **Expect:** Returns the JSON content written above

**69.** `save_list`
- **Expect:** Includes `mcp_validation_save.json`

**70.** `save_delete` — save_path=`user://saves/mcp_validation_save.json`
- **Expect:** success

### Runtime (11 calls)

**First:** `project_set_setting` — setting=`application/run/main_scene`, value=`"res://mcp_validation/val_main.tscn"`

**71.** `game_start`
- **Expect:** success, game launches

**72.** Wait 2-3 seconds for runtime to initialize, then: `runtime_screenshot`
- **Expect:** Returns inline PNG of running game

**73.** `runtime_get_node_state` — node_path=`/root/ValMain/ValPlayer`
- **Expect:** Node state with class, path, properties

**74.** `runtime_get_script_vars` — node_path=`/root/ValMain/ValPlayer`
- **Expect:** Script variables: speed=100.0, label="default" — both classified as public

**75.** `debugger_get_log`
- **Expect:** Recent game output (may be empty if no print statements)

**76.** `input_simulate` — events=`[{"event_type":"action","event_data":{"action":"mcp_val_jump","pressed":true}}]`
- **Expect:** success, event injected

**77.** `game_eval` — code=`get_tree().current_scene.name` — **[gated: skip if unavailable]**
- **Expect:** Returns `"ValMain"`

**78.** `animation_player_control` — node_path=`/root/ValMain/ValAnimPlayer`, operation=`play`, animation_name=`val_lib/idle`
- **Expect:** success (or error if animation wasn't created — note in report)

**79.** `signal_emit` — node_path=`/root/ValMain/ValPlayer`, signal_name=`hit`
- **Expect:** success

**80.** `debugger_get_log` — (check for any signal-related output)
- **Expect:** success

**81.** `game_stop`
- **Expect:** success, game stops

---

## Phase 3 — C# Compatibility Probes (conditional)

**Skip this entire phase if Phase 0 detected a GDScript-only project.**

Open the project's existing main scene (or any scene with C# nodes) before starting. If the project has no C# nodes, create test artifacts:

### CS-Setup: Create C# test artifacts

**CS-S1.** `script_write` — file_path=`res://mcp_validation/McpValCsNode.cs`, content:
```csharp
using Godot;

public partial class McpValCsNode : Node
{
    [Export] public int TestValue { get; set; } = 42;
    [Export] public string TestLabel { get; set; } = "validation";

    [Signal] public delegate void TestFiredEventHandler();

    public int GetTestValue() => TestValue;

    public override void _Ready()
    {
        GD.Print("McpValCsNode _Ready: TestValue=" + TestValue);
    }
}
```
- **Expect:** success

**CS-S1b.** `script_write` — file_path=`res://mcp_validation/McpValCsGlobal.cs`, content:
```csharp
using Godot;

[GlobalClass]
public partial class McpValCsGlobal : Node
{
    [Export] public int GlobalVal { get; set; } = 7;
}
```
- **Expect:** success
- **Purpose:** Provides a `[GlobalClass]` type for CS9 ClassDB tests. Without this attribute, C# classes don't appear in `classdb_search`.

**CS-S1c.** Build the .NET solution — run `dotnet build` in the project root directory (use the Bash tool). This is required before C# `[Export]` properties and `[GlobalClass]` registration take effect.
- **Expect:** `Build succeeded` in output. If the build fails, check for .NET SDK version mismatches (4.2 uses net6.0, 4.3+ uses net8.0).

**CS-S2.** `editor_reload_scripts` — trigger the editor to pick up the rebuilt assembly
- **Expect:** success

**CS-S3.** Open `res://mcp_validation/val_main.tscn`, then `scene_create_node` — node_type=`Node`, node_name=`ValCsNode`, parent_path=`.`
- **Expect:** success

**CS-S4.** `node_set_script` — node_path=`ValCsNode`, script_path=`res://mcp_validation/McpValCsNode.cs`
- **Expect:** success

**CS-S5.** `editor_save_scene`
- **Expect:** success

### CS1. C# [Export] property read/write

**CS1.1** `node_get_property` — node_path=`ValCsNode`, property=`TestValue`
- **Expect:** 42

**CS1.2** `node_get_property` — node_path=`ValCsNode`, property=`TestLabel`
- **Expect:** "validation"

**CS1.3** `node_set_property` — node_path=`ValCsNode`, property=`TestValue`, value=99
- **Expect:** success

**CS1.4** `node_get_property` — node_path=`ValCsNode`, property=`TestValue`
- **Expect:** 99

**CS1.5** `node_set_property` — node_path=`ValCsNode`, property=`TestValue`, value=42
- **Expect:** success (restore default for runtime test later)

### CS2. C# property_list masks

**CS2.1** `node_get_property_list` — node_path=`ValCsNode`, mask=`script`
- **Expect:** TestValue, TestLabel

**CS2.2** `node_get_property_list` — node_path=`ValCsNode`, mask=`all`
- **Expect:** Full list including C# [Export] props

### CS3. C# method call (editor-mode limitation)

**CS3.1** `node_call_method` — node_path=`ValCsNode`, method=`GetTestValue`, args=`[]`
- **Expect:** Returns null. Response MUST include a hint containing:
  - "C# methods cannot execute in editor mode"
  - Mention of `[Tool]` attribute
  - Suggestion to use `game_eval` at runtime
- **CRITICAL:** This is a key C# UX validation. The hint must be specific to C#, not the generic GDScript hint.

### CS4. C# signals — list, connect, disconnect

**CS4.1** `signal_list` — node_path=`ValCsNode`
- **Expect:** Includes `TestFired` signal

**CS4.2** `signal_manage` — node_path=`ValCsNode`, signal_name=`TestFired`, operation=`connect`, target_path=`ValLabel`, method=`set_text`
- **Expect:** success — C# [Signal] connections work the same as GDScript signals

**CS4.3** `signal_list` — node_path=`ValCsNode`, include_connections=`true` (verify connection)
- **Expect:** `TestFired` includes `connections` array with entry `{ target_path: "ValLabel", method_name: "set_text", flags: 0 }`

**CS4.4** `signal_manage` — node_path=`ValCsNode`, signal_name=`TestFired`, operation=`disconnect`, target_path=`ValLabel`, method=`set_text`
- **Expect:** success

### CS5. C# script read/write roundtrip

**CS5.1** `script_read` — file_path=`res://mcp_validation/McpValCsNode.cs`
- **Expect:** Returns the C# source code written in CS-S1

**CS5.2** `script_write` — file_path=`res://mcp_validation/McpValCsTemp.cs`, content:
```csharp
using Godot;
public partial class McpValCsTemp : Node2D
{
    [Export] public float TempSpeed { get; set; } = 5.0f;
}
```
- **Expect:** success

**CS5.3** `script_read` — file_path=`res://mcp_validation/McpValCsTemp.cs`
- **Expect:** Returns the content just written

**CS5.4** `script_delete` — file_path=`res://mcp_validation/McpValCsTemp.cs`
- **Expect:** success

### CS6. script_check rejects .cs

**CS6.1** `script_check` — file_path=`res://mcp_validation/McpValCsNode.cs`
- **Expect:** Error with code `INVALID_PARAMS`, message stating "only supports .gd files"

### CS7. Scene tree with C# scripts

**CS7.1** `scene_get_tree`
- **Expect:** Tree includes ValCsNode with its `.cs` script path visible in the node metadata

**CS7.2** `editor_save_scene`
- **Expect:** success

### CS8. Asset introspection with .cs files

**CS8.1** `asset_list` — folder_path=`res://mcp_validation/`
- **Expect:** List includes `McpValCsNode.cs` alongside the GDScript artifacts

**CS8.2** `asset_get_dependencies` — file_path=`res://mcp_validation/val_main.tscn`
- **Expect:** Dependencies include `McpValCsNode.cs` (scene references the C# script)

### CS9. C# [GlobalClass] in ClassDB

Tests `[GlobalClass]` registration using `McpValCsGlobal` (created in CS-S1b). Requires `dotnet build` + `editor_reload_scripts` to have completed (CS-S1c/CS-S2).

**CS9.1** `classdb_search` — pattern=`McpValCsGlobal`
- **Expect:** `McpValCsGlobal` found in results. Also verify `McpValCsNode` is NOT found (it lacks `[GlobalClass]`).

**CS9.2** `classdb_get_info` — class_name=`McpValCsGlobal`
- **Expect:** Properties include `GlobalVal` (int), inherits from `Node`

**CS9.3** `scene_create_node` — node_type=`McpValCsGlobal`, node_name=`ValCsGlobal`, parent_path=`.`
- **Expect:** success — `[GlobalClass]` types are usable as node types in the editor

**CS9.4** `scene_delete_node` — node_path=`ValCsGlobal`
- **Expect:** success

### CS10. C# runtime — full runtime probe on C# node

**[gated: skip if game_eval unavailable]**

**CS10.1** `project_set_setting` — setting=`application/run/main_scene`, value=`"res://mcp_validation/val_main.tscn"`

**CS10.2** `game_start`
- **Expect:** success

**CS10.3** Wait 3 seconds for managed runtime to initialize.

**CS10.4** `runtime_get_node_state` — node_path=`/root/ValMain/ValCsNode`
- **Expect:** Node state showing class=`Node` (or `McpValCsNode` if [GlobalClass]), path, and properties including TestValue and TestLabel

**CS10.5** `runtime_get_script_vars` — node_path=`/root/ValMain/ValCsNode`
- **Expect:** Script variables: TestValue=42, TestLabel="validation" — both classified as public (C# privates are hidden by absence, not by flag)

**CS10.6** `game_eval` — code=`GetTestValue()`, scope_path=`/root/ValMain/ValCsNode`
- **Expect:** Returns 42
- **CRITICAL:** Validates that C# managed methods ARE callable at runtime, unlike editor mode.

**CS10.7** `debugger_get_log`
- **Expect:** Should include the `_Ready` print: `"McpValCsNode _Ready: TestValue=42"`
- **KEY:** Validates that C# GD.Print output appears in the debug log

**CS10.8** `signal_emit` — node_path=`/root/ValMain/ValCsNode`, signal_name=`TestFired`
- **Expect:** success — C# signals can be emitted at runtime

**CS10.9** `animation_player_control` — node_path=`/root/ValMain/ValAnimPlayer`, operation=`play`, animation_name=`val_lib/idle`
- **Expect:** success (validates runtime animation works in a scene containing C# nodes)

**CS10.10** `input_simulate` — events=`[{"event_type":"action","event_data":{"action":"mcp_val_jump","pressed":true}}]`
- **Expect:** success (validates input injection works in a C# project context)

**CS10.11** `game_stop`
- **Expect:** success

### CS11. editor operations with C# present

**CS11.1** `editor_reload_scripts`
- **Expect:** success — flushes all filesystem changes to the editor; C# scripts are handled by the .NET build system, not this call

**CS11.2** `editor_get_errors`
- **Expect:** Note any C# compilation errors. Report count and whether they are from validation artifacts or pre-existing.

**CS11.3** `editor_get_console`
- **Expect:** success — verify that C#-related log output (build messages, etc.) appears in the console

### CS12. Scene instantiation with C# scripts

Create a sub-scene with a C# script and instantiate it.

**CS12.1** `scene_create` — file_path=`res://mcp_validation/val_cs_sub.tscn`, root_type=`Node`, root_name=`ValCsSub`
- **Expect:** success

**CS12.2** `scene_open` — file_path=`res://mcp_validation/val_cs_sub.tscn`

**CS12.3** `node_set_script` — node_path=`.`, script_path=`res://mcp_validation/McpValCsNode.cs`
- **Expect:** success

**CS12.4** `editor_save_scene`

**CS12.5** `scene_open` — file_path=`res://mcp_validation/val_main.tscn`

**CS12.6** `scene_instantiate` — scene_path=`res://mcp_validation/val_cs_sub.tscn`, parent_path=`.`
- **Expect:** success — instantiating a scene with a C# root script works

**CS12.7** `scene_get_tree` — verify ValCsSub appears in tree
- **Expect:** ValCsSub node present with C# script reference

**CS12.8** `scene_delete_node` — node_path=`ValCsSub`
- **Expect:** success

**CS12.9** `scene_delete` — file_path=`res://mcp_validation/val_cs_sub.tscn`
- **Do NOT call `scene_close` before this step.** `val_main` is the active tab (from CS12.5), so `scene_delete` works directly on the inactive tab. `scene_close` would return an error here anyway (target is not the active tab).
- **Expect:** success

---

## Phase 4 — Combo Chains

Multi-tool workflows that test tool interoperability. Create fresh artifacts for each chain, clean up after each.

### C1. Resource round-trip
`resource_write` (file_path=`res://mcp_validation/val_combo_res.tres`, type=`Environment`) -> `resource_load` (same path) -> verify class and properties -> `resource_delete` (same path)
- **Expect:** Write, load, verify, delete all succeed

### C2. Script validation pipeline
`script_write` (file_path=`res://mcp_validation/val_combo_script.gd`, valid GDScript) -> `script_check` (same path) -> verify no errors -> `script_delete` (same path)
- **Expect:** Write, check passes, delete succeeds

### C3. Scene build round-trip
`scene_create` (file_path=`res://mcp_validation/val_combo_scene.tscn`) -> `scene_open` -> `scene_create_node` (Sprite2D) -> `node_set_property` (position) -> `node_get_property` (verify position) -> `editor_save_scene` -> `scene_close` **[4.5+]** or `scene_open` main scene **[<4.5]** -> `scene_delete` -> cleanup
- **Expect:** Full create-edit-save-close cycle works. On <4.5, switching away from the scene tab before deletion avoids stale-tab issues.

### C4. Input map pipeline
`input_map_action` (action_name=`mcp_val_combo_action`, operation=`add`) -> `input_map_event` (key binding) -> verify -> `input_map_action` (operation=`remove`)
- **Expect:** Action created, event bound, action removed

### C5. Script-to-scene attachment
`script_write` (.gd with @export var) -> `scene_create` -> `scene_open` -> `scene_create_node` -> `node_set_script` -> `node_get_property_list` (mask=`script`, verify exports appear) -> `editor_save_scene` -> cleanup all
- **Expect:** Script exports visible after attachment

### C6. Shader material colon-chain
`resource_write` (ShaderMaterial with shader) -> `scene_open` (val_main) -> `scene_create_node` (Sprite2D) -> `node_set_property` (material resource ref) -> `node_set_property` (material:shader_parameter/brightness) -> `node_get_property` (verify colon-path value) -> cleanup node
- **Expect:** Colon-delimited property path works for nested resource properties

### C7. Signal persistence round-trip
`signal_manage` (connect ValPlayer.hit -> ValLabel.set_text) -> `editor_save_scene` -> `scene_close` **[4.5+]** or `scene_open` a different scene **[<4.5]** -> `scene_open` (val_main) -> `signal_list` (include_connections=true, verify connection persisted) -> `signal_manage` (disconnect)
- **Expect:** Signal connection survives save/reopen. `signal_list` with `include_connections=true` shows the restored connection. On <4.5, opening a different scene then re-opening val_main forces a reload without scene_close.

### C8. Full game lifecycle
`scene_create` (game scene) -> add nodes -> `script_write` -> `node_set_script` -> `editor_save_scene` -> `project_set_setting` (main_scene) -> `game_start` -> `runtime_get_node_state` -> `game_stop` -> cleanup
- **Expect:** Complete build-run-inspect cycle works

### C9. Animation authoring pipeline
Open val_main -> `scene_create_node` (AnimationPlayer) -> `node_call_method` (add_animation_library) -> `animation_keyframe` (x2, different times) -> `animation_get_keys` (verify both keys) -> `editor_save_scene` -> cleanup node
- **Expect:** Animation created with 2 keyframes, keys retrievable

### C10. TileMap painting
`resource_write` (TileSet) -> open val_main -> `scene_create_node` (**TileMapLayer** [4.3+] or **TileMap** [4.2]) -> `node_set_property` (tile_set resource) -> `tilemap_set_cells` -> `editor_save_scene` -> cleanup
- **Expect:** Cells painted on tile layer

### C11. Script write → immediate check (targeted filesystem)
`script_write` (file_path=`res://mcp_validation/val_fs_script.gd`, valid GDScript) -> verify `indexed: true` in response -> `script_check` (same path, **no** `editor_reload_scripts` between) -> `script_delete`
- **Expect:** `script_write` returns `indexed: true`; `script_check` passes immediately without needing `editor_reload_scripts`

### C12. Resource create → immediate load (targeted filesystem)
`resource_write` (file_path=`res://mcp_validation/val_fs_resource.tres`, type=`Environment`) -> verify `indexed: true` in response -> `resource_load` (same path, **no** `editor_reload_scripts` between) -> `resource_delete`
- **Expect:** `resource_write` returns `indexed: true`; `resource_load` returns the resource immediately

### C13. Scene create → immediate open (targeted filesystem)
`scene_create` (file_path=`res://mcp_validation/val_fs_scene.tscn`) -> verify `indexed: true` in response -> `scene_open` (same path, **no** `editor_reload_scripts` between) -> cleanup (open main scene, delete scene file)
- **Expect:** `scene_create` returns `indexed: true`; `scene_open` succeeds immediately

### C14. File delete → immediate deindex (targeted filesystem)
`script_write` (file_path=`res://mcp_validation/val_fs_del.gd`) -> `file_delete` (same path) -> verify `deindexed: true` in response -> `asset_list` (path_prefix=`res://mcp_validation/`, name_glob=`val_fs_del*`) -> verify file absent from results
- **Expect:** `file_delete` returns `deindexed: true`; `asset_list` shows no matching entry

### C15. editor_reload_scripts targeted mode
`script_write` (file_path=`res://mcp_validation/val_fs_targeted.gd`) -> `editor_reload_scripts` (file_paths=[`res://mcp_validation/val_fs_targeted.gd`]) -> verify `mode: "targeted"` in response -> `script_delete`
- **Expect:** Response contains `"mode": "targeted"` and `"file_count": 1`

### C16. editor_reload_scripts full mode (backward compat)
`editor_reload_scripts` (no params) -> verify `mode: "full"` in response
- **Expect:** Response contains `"mode": "full"` and `"scan_waited_ms"` field (backward compatible)

### C17. New-directory indexing (scan fallback)
`folder_create` (file_path=`res://mcp_validation/val_fs_subdir/`) -> `script_write` (file_path=`res://mcp_validation/val_fs_subdir/val_fs_newdir.gd`, valid GDScript) -> check `indexed` field in response -> `script_check` (same path, **no** `editor_reload_scripts` between) -> `folder_delete` (folder_path=`res://mcp_validation/val_fs_subdir/`, recursive=true)
- **Expect:** `script_check` passes immediately without `editor_reload_scripts`. The `indexed` field may be `true` or `false` depending on Godot version and editor build — on .NET builds, `scan()` may not complete within the timeout for the first file in a new directory. This is acceptable: `indexed` is advisory, not a functional gate. All downstream operations (`script_check`, `resource_load`, `scene_open`) work regardless of the `indexed` value. Mark PASS if `script_check` succeeds.

### C18. folder_delete auto-closes scene tabs [4.5+ for full validation, all versions for deletion]
`scene_create` (file_path=`res://mcp_validation/val_fs_tabA.tscn`) -> `scene_create` (file_path=`res://mcp_validation/val_fs_tabB.tscn`) -> `scene_open` (val_fs_tabA) -> `scene_open` (val_fs_tabB) -> ensure val_main.tscn is also open via `scene_open` -> `folder_delete` (folder_path=`res://mcp_validation/`, recursive=true) — **IMPORTANT:** first re-create `res://mcp_validation/` and move the two scene files inside it, since earlier combo chains may have deleted them. Alternatively, create a fresh subfolder for this test.
- **Simplified version:** `folder_create` (`res://mcp_validation/val_fs_tabs/`) -> `scene_create` (2 scenes inside it) -> `scene_open` (both) -> ensure a scene **outside** the folder is open -> `folder_delete` (`res://mcp_validation/val_fs_tabs/`, recursive=true)
- **Expect:** `folder_delete` succeeds without PATH_IN_USE errors. If the active scene was inside the folder, it auto-switches to an outside scene first. Stale tabs for deleted scenes may remain in the editor (cosmetic — they vanish on restart).

---

## Phase 4b — Extension Discovery (conditional)

Skip this phase if no extension addons are present. If the project has extension classes (GDScript extending `MCPToolkitExtension` — any class name; or C# with `MCPToolkit`-prefixed `[Tool][GlobalClass]` on `RefCounted`), run these checks.

### E1. extensions.list returns discovered commands
Call any tool to confirm the bridge is connected, then check if extension groups appear in `enable_tool_group`'s description (standard profile) or if extension tools are directly available (power_user profile).
- **Standard profile:** Verify `enable_tool_group` description lists the extension group name and its tools.
- **Power user:** Verify extension tools are directly callable without `enable_tool_group`.
- **Expect:** Extension commands appear with correct method names, descriptions, and annotations.

### E2. Extension group lazy-load (standard profile only)
Call `enable_tool_group` with the extension group name (e.g., `["scenestats"]`).
- **Expect:** Returns `{ success: true, groups: { "<name>": { loaded: true, tools: [...] } } }`. The tools listed are now callable.

### E3. Extension tool call
Call one of the loaded extension tools with valid input.
- **Expect:** Returns a valid result from the GDScript/C# handler. No bridge errors.

### E4a. Discovery re-entrancy (foundational check)
This tests that `discoverExtensions` can run again without duplicating tools. Simulate by calling `extensions.list` directly via the bridge (if available) or by triggering a config reload that re-runs discovery.
- **Expect:** Tool count remains the same. No duplicate tool names in `tools/list`. `enable_tool_group` description doesn't show duplicate entries.

### E4b. Live extension hot-reload (requires 41k-bis — skip if not implemented)
Test that adding/removing/modifying extension scripts mid-session updates the tool list without reconnecting.

**Add:**
1. Create a new GDScript file with any `class_name` that `extends MCPToolkitExtension`, implementing `register()` with at least one `registry.add()` call. No `MCPToolkit` prefix required for GDScript — discovery is by base class.
2. Save the file. Alt-tab to the Godot editor (or call `extensions.refresh`) to trigger filesystem scan.
3. Verify the new tool appears (power_user: directly callable; standard: in `enable_tool_group` description).
4. Call the new tool — **Expect:** valid response from the handler.

**Content change (modify existing extension):**
1. Add a new tool to an already-loaded extension (add another `registry.add()` call).
2. Save the file. Alt-tab to editor or call `extensions.refresh`.
3. Verify the new tool appears alongside existing tools from the same extension.
4. Verify existing tools from the extension still work.

**Remove:**
1. Delete or rename the extension script file (remove the class).
2. Alt-tab to editor or call `extensions.refresh`.
3. Verify the tool disappears from `tools/list`.
4. Attempt to call the removed tool — **Expect:** error response (NOT a crash or hang).

**No-op:**
1. Call `extensions.refresh` when nothing has changed.
2. Verify tool list is identical — no duplicates, no spurious `notifications/tools/list_changed`.

**Programmatic refresh:**
1. Create an extension file externally (e.g., from terminal or Claude Code).
2. Without alt-tabbing to editor, call `extensions.refresh`.
3. **Expect:** the new tool appears — `extensions.refresh` forces `scan_sources()` internally.

**C# variant (if .NET project):**
1. Same add/remove/modify flow with a C# extension (`[Tool][GlobalClass]` on `RefCounted`, class name must start with `MCPToolkit`).
2. Note: C# requires `dotnet build` between file changes and discovery. After build, call `extensions.refresh` or alt-tab to editor.
3. Verify content-change detection works after rebuild (add a tool, rebuild, refresh — new tool appears).

### E5. Extension with JSON Schema input validation
If the extension declares an `input_schema` with typed properties, call the tool with:
1. Valid input matching the schema — **Expect:** success.
2. Missing a required field — **Expect:** SDK validation error (not a bridge crash).
- **Note:** The server converts JSON Schema from extensions to Zod at registration time. This verifies the conversion works for string, boolean, number, and array types.

### E6. Multiple extensions (if applicable)
If multiple extension addons are present, verify:
- Each extension's commands appear in the correct group.
- Groups from different extensions don't collide.
- Ungrouped extension tools are callable immediately (no `enable_tool_group` needed).

### E7. Extension deletion while tool is loaded (requires 41k-bis)
Tests graceful handling when a loaded extension's script is deleted mid-session.
1. Load an extension group (or have it eagerly loaded on power_user).
2. Confirm the tool works (call it once).
3. Delete the extension script file.
4. Call the tool again — **Expect:** bridge error (handler no longer exists), NOT a server crash. The error message should indicate the extension is unavailable.
5. Verify the tool is removed from `tools/list` after the next filesystem scan.
- **C# note:** Deletion of a .cs file may not immediately remove the class from `get_global_class_list()` until `dotnet build` re-runs. The tool may remain callable (returning stale results from the compiled DLL) until rebuild.

---

## Phase 5 — Cleanup

Remove ALL validation artifacts and restore project state. This section can be run standalone if a previous sweep failed.

### 5a. Identify validation artifacts

Call `asset_list` with folder_path=`res://mcp_validation/` to see what exists. Also check for any combo-chain leftovers.

### 5b. Stop game if running

If game is still running, call `game_stop`.

### 5c. Switch away from validation scenes

Open the project's original main scene (saved in Phase 0) via `scene_open`. This makes it the active tab. Do NOT call `scene_close` on inactive validation tabs — `scene_delete` in the next step handles them directly.

### 5d. Delete files (order matters: scripts/resources before scenes before folders)

1. Delete any combo-chain leftover files (val_combo_*.gd, val_combo_*.tres, val_combo_*.tscn)
2. Delete C# validation scripts (if C# project):
   - `script_delete` — `res://mcp_validation/McpValCsNode.cs` (if exists)
   - `script_delete` — `res://mcp_validation/McpValCsGlobal.cs` (if exists)
   - `script_delete` — `res://mcp_validation/McpValCsTemp.cs` (if exists — should already be deleted in CS5.4)
3. Delete C# sub-scene: `scene_delete` — `res://mcp_validation/val_cs_sub.tscn` (if exists — should already be deleted in CS12.9)
4. Delete GDScript: `script_delete` — `res://mcp_validation/val_actor.gd`
5. Delete shader: `file_delete` — `res://mcp_validation/val_shader.gdshader`
6. Delete SVG and import companion: `file_delete` — `res://mcp_validation/val_icon.svg`
7. Delete resources: `resource_delete` for each .tres in `res://mcp_validation/`
8. Delete scenes: `scene_delete` for each .tscn in `res://mcp_validation/`
9. Delete folder: `folder_delete` — folder_path=`res://mcp_validation/`, recursive=true

### 5e. Restore project settings

1. `project_set_setting` — setting=`application/config/name`, value=`"<original name from Phase 0>"`
2. `project_set_setting` — setting=`application/run/main_scene`, value=`"<original main scene from Phase 0>"`

### 5f. Remove input map action

`input_map_action` — action_name=`mcp_val_jump`, operation=`remove`

### 5g. Remove save data

`save_delete` — save_path=`user://saves/mcp_validation_save.json` (if exists)

### 5h. Verify cleanup

`asset_list` — folder_path=`res://mcp_validation/` — expect NOT_FOUND or empty (folder deleted).

---

## Phase 6 — Reporting

Write `RESULTS.md` in the current directory with the following structure:

### Header

```
# MCP Tool Sweep Results

- **Date:** YYYY-MM-DD
- **Godot version:** X.Y.Z
- **Project type:** GDScript | C# (.NET)
- **Profile:** power_user | standard | minimal
- **Project name:** <name>
- **Total:** X passed, Y failed, Z skipped (W total)
```

### Individual Tool Results

| # | Tool | Stage | Key Params | Expected | Actual | Result | Notes |
|---|------|-------|------------|----------|--------|--------|-------|
| 1 | folder_create | Scaffolding | res://mcp_validation/ | success | success | PASS | |
| 2 | script_write | Scaffolding | val_actor.gd | success | success | PASS | |
| ... | | | | | | | |

### C# Compatibility Results (if applicable)

| # | Category | Tool | Expected | Actual | Result | Notes |
|---|----------|------|----------|--------|--------|-------|
| CS1.1-1.5 | Export read/write | node_get/set_property | read 42, write 99, verify | | | |
| CS2.1-2.2 | Property list masks | node_get_property_list | script: TestValue,TestLabel | | | |
| CS3.1 | Editor method call | node_call_method | null + C# hint | | | CRITICAL — hint must mention C# |
| CS4.1-4.4 | Signal connect/disconnect | signal_list, signal_manage | TestFired, connect/disconnect works | | | |
| CS5.1-5.4 | Script read/write/delete | script_read/write/delete | .cs roundtrip works | | | |
| CS6.1 | script_check rejection | script_check | INVALID_PARAMS: .gd only | | | |
| CS7.1-7.2 | Scene tree with C# | scene_get_tree | .cs script path visible | | | |
| CS8.1-8.2 | Asset introspection | asset_list, asset_get_deps | .cs files listed, deps correct | | | |
| CS9.1-9.4 | [GlobalClass] ClassDB | classdb_search/get_info/create_node | McpValCsGlobal found, usable as node type | | | |
| CS10.1-10.11 | Runtime full probe | runtime_*, game_eval, signal_emit | C# methods callable, GD.Print captured | | | CRITICAL — runtime parity |
| CS11.1-11.3 | Editor ops with C# | editor_reload, errors, console | success, C# output visible | | | |
| CS12.1-12.9 | Scene instantiation | scene_create, instantiate | .cs-scripted sub-scene works | | | |

### Extension Discovery Results (if applicable)

| # | Check | Expected | Actual | Result | Notes |
|---|-------|----------|--------|--------|-------|
| E1 | extensions.list discovery | commands appear | | | |
| E2 | Group lazy-load | enable_tool_group loads group | | | standard only |
| E3 | Extension tool call | valid result | | | |
| E4a | Discovery re-entrancy | no duplicates | | | |
| E4b-add | Hot-reload: add extension | tool appears mid-session | | | |
| E4b-modify | Hot-reload: content change | new tool appears, old works | | | |
| E4b-remove | Hot-reload: delete extension | tool disappears, error on call | | | |
| E4b-noop | Hot-reload: no-op refresh | no duplicates, no spurious notify | | | |
| E4b-refresh | Hot-reload: programmatic refresh | extensions.refresh forces scan | | | |
| E4b-csharp | Hot-reload: C# add/modify/remove | works after dotnet build+refresh | | | .NET only |
| E5 | JSON Schema validation | valid passes, missing fails | | | |
| E6 | Multiple extensions | groups don't collide | | | if applicable |
| E7 | Deletion while loaded | bridge error, not crash | | | |

### Combo Chain Results

| Chain | Description | Steps | Result | Notes |
|-------|-------------|-------|--------|-------|
| C1 | Resource round-trip | 4 | PASS | |
| C2 | Script validation | 3 | PASS | |
| ... | | | | |

### Version-Specific Observations

- [ ] Plugin loaded successfully
- [ ] TileMapLayer/TileMap: used correct type for version
- [ ] scene_close: supported (active tab only) / skipped (version)
- [ ] Logger API: buffer source works / file-dependent
- [ ] All tools functional for this Godot version

### Pitfalls Discovered

List any unexpected behaviors, confusing error messages, or tool interactions that didn't work as expected. For each:
- **Tool:** which tool(s)
- **Severity:** Critical / Major / Minor
- **Description:** what happened
- **Expected vs Actual:** the discrepancy
- **Workaround:** if any

### Cleanup Verification

- [ ] `res://mcp_validation/` folder deleted
- [ ] Project name restored
- [ ] Main scene restored
- [ ] Input map action removed
- [ ] Save data removed
