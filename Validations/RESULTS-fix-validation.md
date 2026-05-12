# Fix Validation Results

**Date:** 2026-05-12
**Godot version:** 4.4 (dogfood project)
**Tester:** Claude Code (automated MCP tool calls)

---

## Test 1 — node_manage duplicate with properties override (was FAIL 43h2)

**Result: PASS**

| Step | Action | Result |
|------|--------|--------|
| 1 | scene_create_node Sprite2D "FixTestSprite" | created |
| 2 | node_set_property position={Vector2, 50, 50} | success |
| 3 | discover_tools(groups=["node_management"]) | activated |
| 4 | node_manage duplicate, properties={"position":{"x":200,"y":300}} (no "type" key) | success |
| 5 | node_get_property FixTestCopy position | **x=200, y=300** |
| 6 | Cleanup: deleted FixTestCopy + FixTestSprite | success |

The fix correctly infers Vector2 from the existing property when the caller omits the `"type"` key.

---

## Test 2 — ResourceRef alias (was Pitfall 4)

**Result: PASS**

| Step | Action | Result |
|------|--------|--------|
| 1 | scene_create_node Sprite2D "RefTestSprite" | created |
| 2 | node_set_property texture={"type":"ResourceRef","path":"res://icon.svg"} | success |
| 3 | node_get_property RefTestSprite texture | **CompressedTexture2D, path=res://icon.svg** |
| 4 | Cleanup: deleted RefTestSprite | success |

`"ResourceRef"` is correctly accepted as an alias for `"Resource"` and loads the texture.

---

## Test 3 — regex text_filter with proper escaping (was FAIL 58b)

**Result: PASS (with escaping note)**

| Step | Action | Result |
|------|--------|--------|
| 1 | execute_code push_warning("FIXTEST_Digits123_here") | seeded |
| 2 | editor_get_console text_filter="FIXTEST_Digits", is_regex=false | **count=1** |
| 3a | editor_get_console text_filter="FIXTEST_Digits\\d+", is_regex=true | count=0 (double-escaped) |
| 3b | editor_get_console text_filter="FIXTEST_Digits\d+", is_regex=true | **count=1** |

The regex filter itself works correctly — `\d+` matched the `123` digits in the seeded warning.

**Escaping note:** When the tool parameter value is written with a JSON-escaped
double backslash (`\\d`), the regex engine receives a literal backslash+d instead
of the digit shorthand. The correct way to send `\d` through the MCP tool call
layer is as a raw single backslash in the parameter string. This is a caller-side
encoding nuance, not a bug in the filter implementation.

---

## Test 4 — discover_tools >5 groups warning

**Result: PASS**

| Step | Action | Result |
|------|--------|--------|
| 1 | discover_tools(groups=[7 groups]) | success, **warning field present** |
| 2 | discover_tools(reset=true) | all 7 groups deactivated |

Warning text: *"6 groups activated at once. This adds many tools to your context
and may degrade response quality. Prefer activating only the groups needed for
your current task. Use reset to deactivate groups you no longer need."*

Note: warning says "6 groups" because `node_management` was `already_loaded`
from Test 1, so only 6 were newly activated. The warning threshold correctly
fired for the batch.

---

## Summary

| Test | Issue | Result |
|------|-------|--------|
| 1 — duplicate + properties | FAIL 43h2 | **PASS** |
| 2 — ResourceRef alias | Pitfall 4 | **PASS** |
| 3 — regex text_filter | FAIL 58b | **PASS** |
| 4 — >5 groups warning | New feature | **PASS** |

**All 4 tests passed.**
