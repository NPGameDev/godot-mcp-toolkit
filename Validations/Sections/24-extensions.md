# Section 24 — Extension Discovery

**Dependencies:** Extensions present in the project
**Tools tested:** discover_tools, extensions.refresh
**Tests:** 7+
**Gate:** Skip if no extension addons are present

---

## E1. extensions.list returns discovered commands

Call any tool to confirm bridge is connected, then check extension visibility:
- **Standard profile:** Verify `discover_tools` description lists the extension group name and tools
- **Power user:** Verify extension tools are directly callable
- **Expect:** Extension commands appear with correct method names and descriptions

## E2. Extension group lazy-load (standard only)

`discover_tools` with groups: `["<extension_group_name>"]`
- **Expect:** activated, tools listed and callable

## E3. Extension tool call

Call one loaded extension tool with valid input.
- **Expect:** valid result from GDScript/C# handler, no bridge errors

## E4. Discovery re-entrancy

Trigger re-discovery (call `extensions.refresh` or config reload).
- **Expect:** tool count unchanged, no duplicates in tools/list

## E5. Hot-reload (add/modify/remove)

**Add:**
1. Create new GDScript extending `MCPToolkitExtension` with `register()` containing `registry.add()`
2. `extensions.refresh`
3. Verify new tool appears, call it → valid response

**Modify:**
1. Add another `registry.add()` call to existing extension
2. `extensions.refresh`
3. Verify new tool appears alongside existing ones

**Remove:**
1. Delete extension script
2. `extensions.refresh`
3. Verify tool gone from tools/list
4. Call removed tool → **Expect:** error, NOT crash

**No-op:**
1. `extensions.refresh` with no changes
2. Verify identical tool list, no duplicates

## E6. Extension keywords for discover_tools

1. Create extension with grouped tool declaring `"keywords": ["physics", "force"]`
2. `extensions.refresh`
3. `discover_tools` request="physics" → extension group in results
4. `discover_tools` request="unrelated" → extension group NOT in results
5. Cleanup: delete extension script

## E7. Extension deletion while loaded

1. Load extension (or have it eagerly loaded on power_user)
2. Call tool once → confirm works
3. Delete extension script
4. Call tool again → **Expect:** error (handler gone), NOT crash
5. Verify tool removed from tools/list after next filesystem scan

---

## Cleanup

Delete any test extension scripts created during this section.
