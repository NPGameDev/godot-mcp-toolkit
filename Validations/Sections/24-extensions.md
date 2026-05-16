# Section 24 — Extension Discovery

**Dependencies:** Section 1 (sv2_validation/ exists)
**Tools tested:** discover_tools, extensions.refresh
**Tests:** 7+
**Note:** This section creates its own test extension — no pre-existing extensions required.

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
- **Standard profile:** `discover_tools` (no params) — verify description lists `sv2_test_group` with 2 tools
- **Power user:** Verify `sv2_ext.hello` and `sv2_ext.add` are directly callable
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

---

## Cleanup

- `script_delete` res://sv2_validation/sv2_test_extension.gd (if still exists)
- Call `discover_tools` with reset=true to deactivate all on-demand groups
