# Section 23 — C# Compatibility

**Dependencies:** Section 2 (nodes in main.tscn), .NET project detected in Section 0
**Tools tested:** All tools interacting with C# scripts/nodes
**Tests:** ~50
**Gate:** Skip entire section if Section 0 detected GDScript-only project

---

## CS-Setup: Create C# test artifacts

**CS-S1.** `script_write` — file_path=`res://sv2_validation/Sv2CsNode.cs`, content:
```csharp
using Godot;

public partial class Sv2CsNode : Node
{
	[Export] public int TestValue { get; set; } = 42;
	[Export] public string TestLabel { get; set; } = "validation";

	[Signal] public delegate void TestFiredEventHandler();

	public int GetTestValue() => TestValue;

	public override void _Ready()
	{
		GD.Print("Sv2CsNode _Ready: TestValue=" + TestValue);
	}
}
```
- **Expect:** success

**CS-S1b.** `script_write` — file_path=`res://sv2_validation/Sv2CsGlobal.cs`, content:
```csharp
using Godot;

[GlobalClass]
public partial class Sv2CsGlobal : Node
{
	[Export] public int GlobalVal { get; set; } = 7;
}
```
- **Expect:** success

**CS-S1c.** Build .NET solution — run `dotnet build` in project root (Bash tool).
- **Expect:** `Build succeeded`. If fails, check .NET SDK version (4.2=net6.0, 4.3+=net8.0).

**CS-S2.** `editor_refresh` — pick up rebuilt assembly
- **Expect:** success

**CS-S3.** `scene_open` main.tscn → `scene_create_node` Node, name=`Sv2CsNode`, parent=`.` → `node_set_script` script_path=`res://sv2_validation/Sv2CsNode.cs` → `editor_save_scene`
- **Expect:** all succeed

---

## CS1. [Export] property read/write

**CS1.1** `node_get_property` Sv2CsNode TestValue → **Expect:** 42
**CS1.2** `node_get_property` Sv2CsNode TestLabel → **Expect:** "validation"
**CS1.3** `node_set_property` TestValue=99 → **Expect:** success
**CS1.4** `node_get_property` TestValue → **Expect:** 99
**CS1.5** `node_set_property` TestValue=42 (restore) → **Expect:** success

## CS2. Property list masks

**CS2.1** `node_get_property_list` Sv2CsNode mask=`script` → **Expect:** TestValue, TestLabel
**CS2.2** `node_get_property_list` Sv2CsNode mask=`all` → **Expect:** includes C# exports

## CS3. C# method call (editor limitation)

**CS3.1** `node_call_method` Sv2CsNode GetTestValue args=[]
- **Expect:** Returns null. Response MUST include hint containing:
  - "C# methods cannot execute in editor mode"
  - Mention of `[Tool]` attribute
  - Suggestion to use execute_code at runtime
- **CRITICAL:** Hint must be C#-specific, not generic GDScript hint.

## CS4. C# signals

**CS4.1** `signal_list` Sv2CsNode → **Expect:** includes TestFired
**CS4.2** `signal_manage` connect TestFired → Sv2Label.set_text → **Expect:** success

> **REGRESSION WATCH (5f96b62):** If signal_manage connecting to a C# signal target
> fails without proper method hint, the signal/C# integration has regressed.

**CS4.3** `signal_list` Sv2CsNode include_connections=true → **Expect:** TestFired connected to Sv2Label.set_text
**CS4.4** `signal_manage` disconnect TestFired → **Expect:** success

## CS5. Script read/write roundtrip

**CS5.1** `script_read` Sv2CsNode.cs → **Expect:** C# source code
**CS5.2** `script_write` res://sv2_validation/Sv2CsTemp.cs (simple C# class)
**CS5.3** `script_read` Sv2CsTemp.cs → **Expect:** content matches
**CS5.4** `script_delete` Sv2CsTemp.cs → **Expect:** success

## CS6. script_check rejects .cs

**CS6.1** `script_check` Sv2CsNode.cs → **Expect:** INVALID_PARAMS "only supports .gd"

## CS7. Scene tree with C# scripts

**CS7.1** `scene_get_tree` → **Expect:** Sv2CsNode visible with .cs script path
**CS7.2** `editor_save_scene` → **Expect:** success

## CS8. Asset introspection

**CS8.1** `asset_list` folder_path=res://sv2_validation/ → **Expect:** includes .cs files
**CS8.2** `asset_get_dependencies` main.tscn → **Expect:** includes Sv2CsNode.cs

## CS9. [GlobalClass] in ClassDB

**CS9.1** `classdb_search` pattern=Sv2CsGlobal → **Expect:** found
**CS9.2** `classdb_get_info` Sv2CsGlobal → **Expect:** GlobalVal property, inherits Node
**CS9.3** `scene_create_node` type=Sv2CsGlobal, name=Sv2CsGlobalNode → **Expect:** success

> **REGRESSION WATCH (cb4e162):** If scene_create_node with a C# [GlobalClass]
> type fails with CLASS_MISMATCH when the class exists, C# class_name resolution
> has regressed. Flag as **Critical**.

**CS9.4** `scene_delete_node` Sv2CsGlobalNode → **Expect:** success

## CS10. Runtime probe on C# node

**CS10.1** `project_set_setting` main_scene=main.tscn
**CS10.2** `game_start` → **Expect:** success
**CS10.3** Wait 3 seconds for .NET runtime
**CS10.4** `runtime_get_node_state` /root/Sv2Main/Sv2CsNode → **Expect:** class, properties
**CS10.5** `runtime_get_script_vars` → **Expect:** TestValue=42, TestLabel="validation"
**CS10.6** `execute_code` code=`GetTestValue()`, scope_path=/root/Sv2Main/Sv2CsNode → **Expect:** 42
  - **CRITICAL:** Validates C# methods callable at runtime (unlike editor)
**CS10.7** `debugger_get_log` → **Expect:** includes "Sv2CsNode _Ready: TestValue=42"
**CS10.8** `signal_emit` /root/Sv2Main/Sv2CsNode TestFired → **Expect:** success
**CS10.9** `animation_player_control` play → **Expect:** success (validates runtime with C# nodes)
**CS10.10** `input_simulate` → **Expect:** success (validates input in C# project)
**CS10.11** `game_stop` → **Expect:** success

## CS11. Editor ops with C#

**CS11.1** `editor_refresh` → **Expect:** success
**CS11.2** `editor_get_console` level_filter=["error"] → note any C# errors
**CS11.3** `editor_get_console` → **Expect:** C# build messages visible

## CS12. Scene instantiation with C# scripts

**CS12.1** `scene_create` res://sv2_validation/cs_sub.tscn, Node, ValCsSub
**CS12.2** `scene_open` cs_sub.tscn
**CS12.3** `node_set_script` root → Sv2CsNode.cs
**CS12.4** `editor_save_scene`
**CS12.5** `scene_open` main.tscn
**CS12.6** `scene_instantiate` scene_path=cs_sub.tscn → **Expect:** success
**CS12.7** `scene_get_tree` → **Expect:** ValCsSub present with C# script
**CS12.8** `scene_delete_node` ValCsSub
**CS12.9** `scene_delete` cs_sub.tscn

---

## CS13. Core tool rerun with C# nodes (coercion & interaction canaries)

These tests exercise core tools specifically against C# nodes in the scene, catching unexpected type coercion or interaction issues that wouldn't surface in a GDScript-only sweep.

**CS13.1** `node_set_property` Sv2CsNode TestValue=`{"type":"int","value":77}`
- **Expect:** success — int coercion works for C# [Export] int

**CS13.2** `node_set_property` Sv2CsNode TestLabel=`"coercion_test"`
- **Expect:** success — string assignment to C# [Export] string

**CS13.3** `node_get_property` Sv2CsNode TestValue → **Expect:** 77

**CS13.4** `node_manage` duplicate Sv2CsNode new_name=`Sv2CsDupe`
- **Expect:** success — duplicate preserves script reference

**CS13.5** `node_get_property` Sv2CsDupe TestValue → **Expect:** 77 (inherited from source)

**CS13.6** `scene_query` class_filter=`"Node"`, name_pattern=`"Sv2Cs*"`
- **Expect:** returns both Sv2CsNode and Sv2CsDupe

**CS13.7** `node_manage` rename Sv2CsDupe new_name=`Sv2CsRenamed`
- **Expect:** success — rename works on C# scripted nodes

**CS13.8** `node_set_property` (batch) batch=[{"node_path":"Sv2CsNode","property":"TestValue","value":42},{"node_path":"Sv2CsRenamed","property":"TestValue","value":99}]
- **Expect:** success, both items report success — batch mode works across C# nodes

**CS13.9** `node_get_property_list` Sv2CsRenamed mask=`script`
- **Expect:** TestValue, TestLabel — duplicated C# node still exposes exports

**CS13.10** `scene_delete_node` Sv2CsRenamed
- **Expect:** success

---

## CS14. C# Extension Discovery

Tests the C# extension pattern: `[Tool][GlobalClass]` on a `RefCounted` subclass with class name prefixed `MCPToolkit`.

> **⚠️ Discovery requirement — the `MCPToolkit` class-name prefix is REQUIRED for C#.**
> C# classes cannot extend the GDScript `MCPToolkitExtension` base, so the loader
> identifies a C# extension by a **`[GlobalClass]` whose class name begins with
> `MCPToolkit`** (plus a `Register` method). A `[GlobalClass]` *without* the prefix —
> or a `MCPToolkit`-prefixed class that is *not* `[GlobalClass]` — is **never**
> discovered, and `extensions.refresh` returns `commands=[]` for it (not a registration
> bug — it fails the discovery marker). The class below (`MCPToolkitSv2CsExt`) is named
> accordingly. (GDScript uses the base class + an explicit `class_name` of any name
> instead; see Section 24.)

**CS14.1** `script_write` — file_path=`res://sv2_validation/MCPToolkitSv2CsExt.cs`, content:
```csharp
using Godot;
using Godot.Collections;

[Tool]
[GlobalClass]
public partial class MCPToolkitSv2CsExt : RefCounted
{
	public void Register(Node registry)
	{
		registry.Call("add", "sv2_cs_ext.greet", Callable.From((Dictionary parameters) =>
		{
			var name = parameters.GetValueOrDefault("name", (Variant)"world").AsString();
			return new Dictionary
			{
				{ "success", true },
				{ "message", $"Hello from C#, {name}!" }
			};
		}), new Dictionary
		{
			{ "group", "sv2_cs_test_group" },
			{ "description", "C# test extension — greeting tool" },
			{ "input_schema", new Dictionary
				{
					{ "type", "object" },
					{ "properties", new Dictionary
						{
							{ "name", new Dictionary { { "type", "string" } } }
						}
					}
				}
			}
		});
	}
}
```
- **Expect:** success

**CS14.2** Build .NET solution — `dotnet build` in project root
- **Expect:** Build succeeded (the new class compiles)

**CS14.3** `extensions.refresh` — trigger discovery
- **Expect:** success, sv2_cs_test_group detected

**CS14.4** Call `sv2_cs_ext.greet` with name=`"CSharp"`
- **Expect:** `{"success": true, "message": "Hello from C#, CSharp!"}`

**CS14.5** `script_delete` — res://sv2_validation/MCPToolkitSv2CsExt.cs
- **Expect:** success

**CS14.6** `dotnet build` — rebuild without the extension
- **Expect:** Build succeeded

**CS14.7** `extensions.refresh`
- **Expect:** sv2_cs_ext.greet no longer available

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- `scene_delete_node` Sv2CsNode
- `script_delete` Sv2CsNode.cs
- `script_delete` Sv2CsGlobal.cs
- `script_delete` MCPToolkitSv2CsExt.cs (if still exists)
- `project_set_setting` restore main_scene
