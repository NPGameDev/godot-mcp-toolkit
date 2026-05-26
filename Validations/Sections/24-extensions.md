# Section 24 — Extension Discovery

**Dependencies:** Section 1 (sv2_validation/ exists)
**Tools tested:** discover_tools, extensions.refresh
**Tests:** 9+
**Note:** This section creates its own test extensions — no pre-existing extensions required.

---

## EXT-Setup: Create test extension

**EXT-S1.** `script_write` — file_path=`res://sv2_validation/sv2_test_extension.gd`, content:
```gdscript
@tool
extends MCPToolkitExtension

func register(registry) -> void:
	registry.add("sv2_ext.hello", func(params: Dictionary) -> Dictionary:
		var name := str(params.get("name", "world"))
		return {"success": true, "message": "Hello, %s!" % name}
	, {
		"group": "sv2_test_group",
		"description": "Test extension tool — returns a greeting",
		"input_schema": {
			"type": "object",
			"properties": {
				"name": {"type": "string", "description": "Name to greet"}
			}
		}
	})

	registry.add("sv2_ext.add", func(params: Dictionary) -> Dictionary:
		var a := int(params.get("a", 0))
		var b := int(params.get("b", 0))
		return {"success": true, "result": a + b}
	, {
		"group": "sv2_test_group",
		"description": "Test extension tool — adds two numbers",
		"input_schema": {
			"type": "object",
			"properties": {
				"a": {"type": "integer"},
				"b": {"type": "integer"}
			},
			"required": ["a", "b"]
		}
	})
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
1. `script_write` — rewrite `res://sv2_validation/sv2_test_extension.gd` adding a third tool (`sv2_ext.multiply`)
2. `extensions.refresh`
3. Verify `sv2_ext.multiply` appears alongside `sv2_ext.hello` and `sv2_ext.add`
4. Call `sv2_ext.multiply` — **Expect:** valid result

**Remove:**
1. `script_delete` — `res://sv2_validation/sv2_test_extension.gd`
2. `extensions.refresh`
3. Verify all `sv2_ext.*` tools are gone from tools/list
4. Call `sv2_ext.hello` — **Expect:** error (handler gone), NOT a crash

## E6. Extension keywords for discover_tools

1. `script_write` — recreate extension with `"keywords": ["math", "arithmetic"]` in the group dict
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
extends MCPToolkitExtension

func register(registry) -> void:
	registry.add("sv2_ext.slow", func(params: Dictionary) -> Dictionary:
		OS.delay_msec(100)
		return {"success": true, "result": "done"}
	, {
		"group": "sv2_annotated_group",
		"description": "Slow tool with custom timeout",
		"is_read_only": true,
		"timeout_ms": 5000,
		"input_schema": {"type": "object", "properties": {}}
	})
	registry.add("sv2_ext.writer", func(params: Dictionary) -> Dictionary:
		return {"success": true, "wrote": true}
	, {
		"group": "sv2_annotated_group",
		"description": "Mutation tool",
		"is_read_only": false,
		"input_schema": {"type": "object", "properties": {}}
	})
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
extends MCPToolkitExtension

func register(registry) -> void:
	registry.add("sv2_ext.new_only", func(params: Dictionary) -> Dictionary:
		return {"success": true}
	, {
		"group": "sv2_versioned_group",
		"description": "Only on Godot 4.5+",
		"min_godot_version": "4.5",
		"input_schema": {"type": "object", "properties": {}}
	})
	registry.add("sv2_ext.old_only", func(params: Dictionary) -> Dictionary:
		return {"success": true}
	, {
		"group": "sv2_versioned_group",
		"description": "Only on Godot <=4.4",
		"max_godot_version": "4.4",
		"input_schema": {"type": "object", "properties": {}}
	})
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

## Multi-Session Behavior Note (41l-decies)

> **Concurrency documentation (not a test — verified by integration tests):**
> When multiple MCP connections are active simultaneously, mutation commands
> serialize across peers (queued FIFO). Read-only tools (including read-only
> extension tools) bypass the lock. Queued entries for dead peers are skipped.
> Agents see `_queued` / `_executing` notifications. This behavior is validated
> by the post-merge integration test suite (41l-undecies-septies), not the sweep.

---

## Console error check

Call `editor_get_console` and scan output since section start for `UndoRedo history mismatch`. Guard tests produce intentional error logs (e.g., `Failed loading resource`) — ignore those.
- **FAIL** if any `UndoRedo history mismatch` line appears.
- **PASS** otherwise.

## Cleanup

- `script_delete` res://sv2_validation/sv2_test_extension.gd (if still exists)
- `script_delete` res://sv2_validation/sv2_ext_annotated.gd (if still exists)
- `script_delete` res://sv2_validation/sv2_ext_versioned.gd (if still exists)
- Call `discover_tools` with reset=true to deactivate all on-demand groups
