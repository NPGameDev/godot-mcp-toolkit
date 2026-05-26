# Section 25 — Undo/Redo Verification

**Dependencies:** Section 2 (nodes exist in `res://sv2_validation/main.tscn`)
**Tools tested:** node.set_property, scene.create_node, node.manage, node.groups, node.call_method
**Tests:** 14
**Note:** Tests that MCP mutations register in the editor's undo history and can be reversed. Uses `test/test_undo_redo_action.gd` as a helper script attached to a node in the scene.

---

## UR-Setup: Attach undo/redo helper

**UR-S1.** `scene.create_node` — type=`Node`, name=`URHelper`, parent=scene root
- **Expect:** success

**UR-S2.** `node.set_script` — node_path=`URHelper`, script_path=`res://test/test_undo_redo_action.gd`
- **Expect:** success

**UR-S3.** `node.call_method` — node_path=`URHelper`, method_name=`run_undo_redo_tests`, args=`[]`
- **Expect:** status=`ok`, all sub-tests pass (prop_set, prop_undo, prop_redo, method_added, method_undo, method_redo, commit_do_executes, commit_undo)
- **Note:** This runs the self-contained builder integration tests. If any sub-test fails, investigate before continuing — the builder itself is broken.

---

## UR1. node.set_property undo/redo

**UR1.1** Create a test node:
- `scene.create_node` — type=`Node2D`, name=`URTarget`, parent=scene root
- **Expect:** success

**UR1.2** Set position:
- `node.set_property` — node_path=`URTarget`, property=`position`, value=`{"x": 200, "y": 300}`
- **Expect:** success

**UR1.3** Trigger undo:
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_undo`, args=`["URTarget"]`
- **Expect:** status=`ok`

**UR1.4** Verify position reverted:
- `node.get_property` — node_path=`URTarget`, property=`position`
- **Expect:** value near `(0, 0)` (default position)

**UR1.5** Trigger redo:
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_redo`, args=`["URTarget"]`
- **Expect:** status=`ok`

**UR1.6** Verify position restored:
- `node.get_property` — node_path=`URTarget`, property=`position`
- **Expect:** value=`(200, 300)`

---

## UR2. node.manage rename undo/redo

**UR2.1** Rename test node:
- `node.manage` — node_path=`URTarget`, action=`rename`, new_name=`URRenamed`
- **Expect:** success

**UR2.2** Trigger undo:
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_undo`, args=`["URTarget"]`
- **Expect:** status=`ok` (uses the original path for history lookup — node may still be at old path)

**UR2.3** Verify name reverted:
- `scene.get_tree` — verify `URTarget` exists (original name restored)
- **Expect:** `URTarget` in tree

**UR2.4** Trigger redo:
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_undo`, args=`[]`
- **Note:** If undo restored the name, redo changes it back. Use empty path to target scene history.
- Actually use `trigger_redo` with empty path:
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_redo`, args=`[""]`
- **Expect:** status=`ok`, node renamed back to `URRenamed`

---

## UR3. node.groups add undo/redo

**UR3.1** Re-establish node name (undo the rename from UR2 if needed):
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_undo`, args=`[""]`
- Or use current node name from UR2.

**UR3.2** Add group:
- `node.groups` — node_path=`URTarget` (or current name), action=`add`, groups=`["ur_test_group"]`
- **Expect:** success

**UR3.3** Trigger undo:
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_undo`, args=`["URTarget"]`
- **Expect:** status=`ok`

**UR3.4** Verify group removed:
- `node.get_property` — node_path=`URTarget`, property=`groups` (or use `node.groups` action=`list`)
- **Expect:** `ur_test_group` NOT in groups

---

## UR-Cleanup: Remove test nodes

**UR-C1.** Delete `URTarget` (or `URRenamed`, whichever name it currently has):
- `scene.delete_node` — node_path matching current name
- **Expect:** success (or already removed by undo)

**UR-C2.** Delete `URHelper`:
- `scene.delete_node` — node_path=`URHelper`
- **Expect:** success

**UR-C3.** Save scene:
- `editor_save_scene`
- **Expect:** success
