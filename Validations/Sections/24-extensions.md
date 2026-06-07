# Section 24 — Extension Discovery

**Dependencies:** Section 1 (sv2_validation/ exists)
**Tools tested:** discover_tools, extensions.refresh
**Tests:** 9+
**Note:** This section creates its own test extensions — no pre-existing extensions required.

> **⚠️ Discovery requirement — a GDScript extension MUST declare an explicit `class_name`.**
> Extension discovery scans `ProjectSettings.get_global_class_list()`, which contains
> **only** scripts that declare an explicit `class_name`. A bare
> `extends MCPToolkitExtension` with no `class_name` is **never** discovered —
> `extensions.refresh` returns `commands=[]` for it no matter how many times you call
> it (it is not a registration bug; the script simply is not a global class). Every
> test script below therefore declares a `class_name` (it can be any unique name —
> discovery is by base class, not by the name). If a discovery step unexpectedly
> returns `commands=[]`, first confirm the script has a `class_name` before suspecting
> the tool. **C# extensions use a different marker** — a `MCPToolkit`-prefixed
> `[GlobalClass]` — see Section 23 / CS14.

---

## EXT-Setup: Create test extension

**EXT-S1.** `script_write` — file_path=`res://sv2_validation/sv2_test_extension.gd`, content:
```gdscript
@tool
class_name Sv2TestExtension
extends MCPToolkitExtension

func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("sv2_ext.hello", func(params: Dictionary) -> Dictionary:
		var name := str(params.get("name", "world"))
		return {"success": true, "message": "Hello, %s!" % name}
	, MCPToolkitExtensionOptions.new("Test extension tool — returns a greeting")
		.with_input_schema({
			"type": "object",
			"properties": {
				"name": {"type": "string", "description": "Name to greet"}
			}
		})
		.with_group("sv2_test_group", "Test extension group"))

	registry.add("sv2_ext.add", func(params: Dictionary) -> Dictionary:
		var a := int(params.get("a", 0))
		var b := int(params.get("b", 0))
		return {"success": true, "result": a + b}
	, MCPToolkitExtensionOptions.new("Test extension tool — adds two numbers")
		.with_input_schema({
			"type": "object",
			"properties": {
				"a": {"type": "integer"},
				"b": {"type": "integer"}
			},
			"required": ["a", "b"]
		})
		.with_group("sv2_test_group", "Test extension group"))
```
- **Expect:** success

**EXT-S2.** `extensions.refresh` — trigger discovery of the new extension
- **Expect:** success, sv2_test_group appears

**EXT-S3.** Wait a moment for filesystem scan, then verify extension is detected.

---

## E1. extensions.list returns discovered commands

Check extension visibility:
- **Standard mode:** `discover_tools` (no params) — verify description lists `sv2_test_group` with 2 tools
- **After activation:** Verify `sv2_ext.hello` and `sv2_ext.add` are directly callable
- **Expect:** Extension commands appear with correct method names and descriptions

## E2. Extension group lazy-load (standard only)

`discover_tools` with groups=`["sv2_test_group"]`
- **Expect:** activated, tools `sv2_ext.hello` and `sv2_ext.add` listed

## E3. Extension tool call

Call `sv2_ext.hello` with name=`"Sweep"`
- **Expect:** `{"success": true, "message": "Hello, Sweep!"}`

Call `sv2_ext.add` with a=3, b=7
- **Expect:** `{"success": true, "result": 10}`

## E4. Discovery re-entrancy

Call `extensions.refresh` again (no changes made).
- **Expect:** tool count unchanged, no duplicates, no spurious notifications

## E5. Hot-reload (add/modify/remove)

**Modify:**
1. `script_write` — rewrite `res://sv2_validation/sv2_test_extension.gd` adding a third tool (`sv2_ext.multiply`) — **keep the `@tool` / `class_name Sv2TestExtension` / `extends MCPToolkitExtension` header**, or discovery breaks
2. `extensions.refresh`
3. Verify `sv2_ext.multiply` appears alongside `sv2_ext.hello` and `sv2_ext.add`
4. Call `sv2_ext.multiply` — **Expect:** valid result

**Remove:**
1. `script_delete` — `res://sv2_validation/sv2_test_extension.gd`
2. `extensions.refresh`
3. Verify all `sv2_ext.*` tools are gone from tools/list
4. Call `sv2_ext.hello` — **Expect:** error (handler gone), NOT a crash

## E6. Extension keywords for discover_tools

1. `script_write` — recreate extension (keeping the `class_name Sv2TestExtension` header) with `"keywords": ["math", "arithmetic"]` in the group dict
2. `extensions.refresh`
3. `discover_tools` request=`"math"` — **Expect:** sv2_test_group in results
4. `discover_tools` request=`"unrelated_xyz"` — **Expect:** sv2_test_group NOT in results

## E7. Extension deletion while loaded

1. Confirm extension is loaded (call `sv2_ext.hello` → works)
2. `script_delete` — `res://sv2_validation/sv2_test_extension.gd`
3. Call `sv2_ext.hello` again — **Expect:** error (not crash), tool unavailable
4. `extensions.refresh` — verify clean removal

## E8. Extension annotation options (41l-nonis: timeout + read-only)

1. `script_write` — file_path=`res://sv2_validation/sv2_ext_annotated.gd`, content:
```gdscript
@tool
class_name Sv2ExtAnnotated
extends MCPToolkitExtension

func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("sv2_ext.slow", func(params: Dictionary) -> Dictionary:
		OS.delay_msec(100)
		return {"success": true, "result": "done"}
	, MCPToolkitExtensionOptions.new("Slow tool with custom timeout")
		.mark_read_only()
		.with_timeout_ms(5000)
		.with_input_schema({"type": "object", "properties": {}})
		.with_group("sv2_annotated_group", "Annotated extension group"))
	registry.add("sv2_ext.writer", func(params: Dictionary) -> Dictionary:
		return {"success": true, "wrote": true}
	, MCPToolkitExtensionOptions.new("Mutation tool")
		.with_input_schema({"type": "object", "properties": {}})
		.with_group("sv2_annotated_group", "Annotated extension group"))
```
2. `extensions.refresh`
3. `discover_tools` groups=`["sv2_annotated_group"]`
   - **Expect:** 2 tools activated
4. Call `sv2_ext.slow` — **Expect:** success (completes within 5s timeout)
5. Verify `sv2_ext.slow` is callable in read-only mode (it's marked `is_read_only: true`)
6. Verify `sv2_ext.writer` is blocked in read-only mode (if read-only is active) or succeeds in standard mode
7. Cleanup: `script_delete` res://sv2_validation/sv2_ext_annotated.gd, `extensions.refresh`

## E9. Extension version bounds (41l-undecies)

1. `script_write` — file_path=`res://sv2_validation/sv2_ext_versioned.gd`, content:
```gdscript
@tool
class_name Sv2ExtVersioned
extends MCPToolkitExtension

func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("sv2_ext.new_only", func(params: Dictionary) -> Dictionary:
		return {"success": true}
	, MCPToolkitExtensionOptions.new("Only on Godot 4.5+")
		.with_min_godot_version("4.5")
		.with_input_schema({"type": "object", "properties": {}})
		.with_group("sv2_versioned_group", "Version-gated extension group"))
	registry.add("sv2_ext.old_only", func(params: Dictionary) -> Dictionary:
		return {"success": true}
	, MCPToolkitExtensionOptions.new("Only on Godot <=4.4")
		.with_max_godot_version("4.4")
		.with_input_schema({"type": "object", "properties": {}})
		.with_group("sv2_versioned_group", "Version-gated extension group"))
```
2. `extensions.refresh`
3. `discover_tools` groups=`["sv2_versioned_group"]`
4. Check tool visibility against current Godot version:
   - If Godot ≥ 4.5: `sv2_ext.new_only` available, `sv2_ext.old_only` hidden
   - If Godot < 4.5: `sv2_ext.new_only` hidden, `sv2_ext.old_only` available
5. Call the visible tool — **Expect:** success
6. Call the hidden tool — **Expect:** error (method not found / not registered)
7. Cleanup: `script_delete` res://sv2_validation/sv2_ext_versioned.gd, `extensions.refresh`

---

## E10. Extension success hints and error API (41l-vicies-ter)

1. `script_write` — file_path=`res://sv2_validation/sv2_ext_hints.gd`, content:
```gdscript
@tool
class_name Sv2ExtHints
extends MCPToolkitExtension

func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	# Tool with registered success hint
	registry.add("sv2_ext.hinted", func(params: Dictionary) -> Dictionary:
		return {"success": true, "data": "result"}
	, MCPToolkitExtensionOptions.new("Tool with a success hint")
		.with_success_hint("Call sv2_ext.check_status to see details.")
		.with_group("sv2_hint_group", "Hint testing"))

	# Tool where handler overrides the registered hint
	registry.add("sv2_ext.hint_override", func(params: Dictionary) -> Dictionary:
		return {"success": true, "hint": "Dynamic hint from handler"}
	, MCPToolkitExtensionOptions.new("Tool that overrides its hint")
		.with_success_hint("This should be overridden")
		.with_group("sv2_hint_group", "Hint testing"))

	# Tool using MCPToolkitError.fail() for structured errors
	registry.add("sv2_ext.guarded", func(params: Dictionary) -> Dictionary:
		var err = MCPToolkitError.require(params, ["node_path"])
		if err != null:
			return err
		return {"success": true, "path": params["node_path"]}
	, MCPToolkitExtensionOptions.new("Tool that validates params with MCPToolkitError")
		.with_input_schema({
			"type": "object",
			"properties": {
				"node_path": {"type": "string", "description": "Node path to validate"}
			},
			"required": ["node_path"]
		})
		.with_group("sv2_hint_group", "Hint testing"))
```
2. `extensions.refresh`
3. `discover_tools` groups=`["sv2_hint_group"]`
   - **Expect:** 3 tools activated

**E10a. Success hint auto-injection:**
- Call `sv2_ext.hinted` (no params needed)
- **Expect:** `{"success": true, "data": "result", "hint": "Call sv2_ext.check_status to see details."}`

**E10b. Handler hint overrides registered hint:**
- Call `sv2_ext.hint_override`
- **Expect:** `{"success": true, "hint": "Dynamic hint from handler"}` (NOT "This should be overridden")

**E10c. MCPToolkitError.fail() structured error:**
- Call `sv2_ext.guarded` with `node_path=""`
- **Expect:** `{"success": false, "code": "INVALID_PARAMS", "hint": "Use scene.get_tree to list valid node paths..."}` (auto-hint from HINT_NODE_PATH)

**E10d. MCPToolkitError.require() happy path:**
- Call `sv2_ext.guarded` with `node_path="/root/Player"`
- **Expect:** `{"success": true, "path": "/root/Player"}`

**E10e.** Cleanup: `script_delete` res://sv2_validation/sv2_ext_hints.gd, `extensions.refresh`

---

## Multi-Session Behavior Note (41l-decies)

> **Concurrency documentation (not a test — verified by integration tests):**
> When multiple MCP connections are active simultaneously, mutation commands
> serialize across peers (queued FIFO). Read-only tools (including read-only
> extension tools) bypass the lock. Queued entries for dead peers are skipped.
> Agents see `_queued` / `_executing` notifications. This behavior is validated
> by the post-merge integration test suite (41l-undecies-septies), not the sweep.

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- `script_delete` res://sv2_validation/sv2_test_extension.gd (if still exists)
- `script_delete` res://sv2_validation/sv2_ext_annotated.gd (if still exists)
- `script_delete` res://sv2_validation/sv2_ext_versioned.gd (if still exists)
- `script_delete` res://sv2_validation/sv2_ext_hints.gd (if still exists)
- Call `discover_tools` with reset=true to deactivate all on-demand groups
