# Section 25 — Undo/Redo Verification

**Dependencies:** Section 2 (nodes exist in `res://sv2_validation/Sv2Main.tscn`)
**Tools tested:** node.set_property, scene.create_node, node.manage, node.groups, node.call_method, scene.delete_node, control.set_layout, signal.manage, path2d.edit_curve, particles.create, node.collision_from_sprite, node.set_script
**Tests:** 48
**Note:** Tests that MCP mutations register in the editor's undo history and can be reversed. Uses `test/test_undo_redo_action.gd` as a helper script attached to a node in the scene. Sections UR4–UR12 are regression guards for tools that previously had missing `context_object` in their `MCPToolkitUndoRedoAction.begin()` calls, which caused `UndoRedo history mismatch` errors.

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
- **Constraint (41n-ter-bis #8):** drive UR1.4→UR1.6 (set→undo→redo) **tightly within the same session/dispatch chain**. The production redo is sound — `trigger_redo`'s self-test passes 8/8, and a tight same-session set→undo→redo round-trips cleanly (re-confirmed on 4.7, 2026-06-30, identical `history_id` on undo + redo). A redo issued across *separate* dispatch round-trips or separate test sessions can hit editor-history contention (a different `history_id` context) and appear to no-op — an env/sequencing artifact, not a production bug.

---

## UR2. node.manage rename undo/redo

**UR2.1** Rename test node:
- `node.manage` — node_path=`URTarget`, action=`rename`, new_name=`URRenamed`
- **Expect:** success

**UR2.2** Trigger undo (use the current name `URRenamed` or empty path `""` — NOT the stale pre-rename path):
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_undo`, args=`[""]`
- **Expect:** status=`ok`. **By design:** undo history is scene-keyed and the helper resolves via the *live* node path, so a stale **pre-rename** path (`URTarget` — the node now lives at `URRenamed`) cannot resolve ("Could not resolve history"). Pass the current name (`URRenamed`) or empty path `""` (targets scene history directly).
- **Constraint:** after a rename, always reference the node by its *current* name (or `""` for scene history) when driving undo/redo — the old path is dead.

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

## UR4. node.manage reorder undo/redo

**UR4.1** Create a sibling node:
- `scene.create_node` — type=`Node2D`, name=`URSibling`, parent=scene root
- **Expect:** success

**UR4.2** Record original index:
- `scene.get_tree` — note the child index of `URSibling`
- **Expect:** `URSibling` exists in tree

**UR4.3** Reorder:
- `node.manage` — node_path=`URSibling`, action=`reorder`, new_index=`0`
- **Expect:** success

**UR4.4** Trigger undo:
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_undo`, args=`["URSibling"]`
- **Expect:** status=`ok`

**UR4.5** Verify order restored:
- `scene.get_tree` — check `URSibling` is back at its original index (not index 0)
- **Expect:** original index restored

---

## UR5. node.manage duplicate undo/redo

**UR5.1** Duplicate:
- `node.manage` — node_path=`URTarget`, action=`duplicate`, new_name=`URDuplicate`
- **Expect:** success

**UR5.2** Trigger undo:
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_undo`, args=`[""]`
- **Expect:** status=`ok`

**UR5.3** Verify duplicate removed:
- `scene.get_tree` — confirm `URDuplicate` does NOT exist
- **Expect:** no node named `URDuplicate`

---

## UR6. node.groups remove + batch undo/redo

**UR6.1** Add URTarget to group for remove test:
- `node.groups` — node_path=`URTarget`, action=`add`, group=`ur_remove_test`
- **Expect:** success

**UR6.2** Remove from group:
- `node.groups` — node_path=`URTarget`, action=`remove`, group=`ur_remove_test`
- **Expect:** success

**UR6.3** Trigger undo:
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_undo`, args=`["URTarget"]`
- **Expect:** status=`ok`

**UR6.4** Verify group restored:
- `node.groups` — node_path=`URTarget`, action=`list`
- **Expect:** `ur_remove_test` in groups

**UR6.5** Batch add groups:
- `node.groups` — action=`add`, entries=`[{"node_path": "URTarget", "group": "ur_batch_a"}, {"node_path": "URSibling", "group": "ur_batch_a"}]`
- **Expect:** success, 2 entries added

**UR6.6** Trigger undo:
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_undo`, args=`[""]`
- **Expect:** status=`ok`

**UR6.7** Verify batch undone:
- `node.groups` — node_path=`URTarget`, action=`list`
- **Expect:** `ur_batch_a` NOT in groups
- `node.groups` — node_path=`URSibling`, action=`list`
- **Expect:** `ur_batch_a` NOT in groups

---

## UR7. scene.delete_node undo/redo

**UR7.1** Delete node:
- `scene.delete_node` — node_path=`URSibling`
- **Expect:** success

**UR7.2** Trigger undo:
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_undo`, args=`[""]`
- **Expect:** status=`ok`

**UR7.3** Verify node restored:
- `scene.get_tree` — confirm `URSibling` exists
- **Expect:** `URSibling` back in tree

---

## UR8. control.set_layout undo/redo

**UR8.1** Create a Control node:
- `scene.create_node` — type=`Control`, name=`URControl`, parent=scene root
- **Expect:** success

**UR8.2** Set layout:
- `control.set_layout` — node_path=`URControl`, preset=`PRESET_CENTER`
- **Expect:** success

**UR8.3** Trigger undo:
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_undo`, args=`["URControl"]`
- **Expect:** status=`ok`

**UR8.4** Verify layout reverted:
- `node.get_property` — node_path=`URControl`, property=`anchor_left`
- **Expect:** value=`0` (default, not the center preset value of 0.5)

---

## UR9. signal.manage connect/disconnect undo/redo

**UR9.1** Connect a signal:
- `signal.manage` — action=`connect`, source_path=`URTarget`, signal_name=`visibility_changed`, target_path=`URSibling`, method_name=`show`
- **Expect:** success (status=`created`)

**UR9.2** Trigger undo:
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_undo`, args=`["URTarget"]`
- **Expect:** status=`ok`

**UR9.3** Verify disconnected:
- `signal.list` — node_path=`URTarget`
- **Expect:** `visibility_changed` NOT connected to `URSibling.show`

**UR9.4** Reconnect (for disconnect test):
- `signal.manage` — action=`connect`, source_path=`URTarget`, signal_name=`visibility_changed`, target_path=`URSibling`, method_name=`show`
- **Expect:** success

**UR9.5** Disconnect:
- `signal.manage` — action=`disconnect`, source_path=`URTarget`, signal_name=`visibility_changed`, target_path=`URSibling`, method_name=`show`
- **Expect:** success

**UR9.6** Trigger undo:
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_undo`, args=`["URTarget"]`
- **Expect:** status=`ok`

**UR9.7** Verify reconnected:
- `signal.list` — node_path=`URTarget`
- **Expect:** `visibility_changed` connected to `URSibling.show`

---

## UR10. path2d.edit_curve undo/redo

**UR10.1** Create a Path2D:
- `scene.create_node` — type=`Path2D`, name=`URPath`, parent=scene root
- **Expect:** success

**UR10.2** Add a point:
- `path2d.edit_curve` — node_path=`URPath`, action=`add`, points=`[{"position": {"x": 100, "y": 200}}]`
- **Expect:** success, point_count=1

**UR10.3** Trigger undo:
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_undo`, args=`["URPath"]`
- **Expect:** status=`ok`

**UR10.4** Verify point removed:
- `node.get_property` — node_path=`URPath`, property=`curve:point_count`
- **Expect:** 0 (empty curve restored by undo)

---

## UR11. particles.create undo/redo

**UR11.1** Create a particle effect:
- `particles.create` — parent_path=scene root, type=`2d`
- **Expect:** success, returns the created node path

**UR11.2** Verify node exists:
- `scene.get_tree` — confirm the particle node exists (name from UR11.1 response)
- **Expect:** GPUParticles2D node in tree

**UR11.3** Trigger undo:
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_undo`, args=`[""]`
- **Expect:** status=`ok`

**UR11.4** Verify particle removed:
- `scene.get_tree` — confirm the particle node is gone
- **Expect:** no GPUParticles2D node (the one created in UR11.1)

---

## UR12. node.collision_from_sprite undo/redo

**UR12.1** Create a Sprite2D:
- `scene.create_node` — type=`Sprite2D`, name=`URSprite`, parent=scene root
- **Expect:** success

**UR12.2** Assign texture:
- `node.set_property` — node_path=`URSprite`, property=`texture`, value=`{"type":"Resource","path":"res://icon.svg"}`
- **Expect:** success

**UR12.3** Generate collision:
- `node.collision_from_sprite` — node_path=`URSprite`
- **Expect:** success, collision polygon(s) created

**UR12.4** Trigger undo:
- `node.call_method` — node_path=`URHelper`, method_name=`trigger_undo`, args=`[""]`
- **Expect:** status=`ok`

**UR12.5** Verify collision removed:
- `scene.get_tree` — confirm no CollisionPolygon2D children under the scene root (or wherever collision was placed)
- **Expect:** collision node(s) created in UR12.3 are gone

---

## UR-Console: History mismatch error check

**UR-CON.1** Read editor console:
- `editor_get_console`
- Scan output for `UndoRedo history mismatch`
- **FAIL** if any `UndoRedo history mismatch` line appears.
- **Note:** This is the critical regression gate. All 12 tools above previously had missing or orphaned `context_object` in their `MCPToolkitUndoRedoAction.begin()` calls. Console errors indicate a regression — report the full error context and which tool section triggered it.

**UR-CON.2** Clear console buffer:
- `editor_get_console` — clear_buffer=`true`
- **Expect:** success (prevents stale mismatch errors from bleeding into subsequent sections)

---

## UR-Cleanup: Remove test nodes

**UR-C1.** Delete `URSprite`:
- `scene.delete_node` — node_path=`URSprite`
- **Expect:** success

**UR-C2.** Delete `URPath`:
- `scene.delete_node` — node_path=`URPath`
- **Expect:** success

**UR-C3.** Delete `URControl`:
- `scene.delete_node` — node_path=`URControl`
- **Expect:** success

**UR-C4.** Delete `URSibling`:
- `scene.delete_node` — node_path=`URSibling`
- **Expect:** success (or already removed — skip if not found)

**UR-C5.** Delete `URTarget` (or `URRenamed`, whichever name it currently has):
- `scene.delete_node` — node_path matching current name
- **Expect:** success (or already removed by undo)

**UR-C6.** Delete `URHelper`:
- `scene.delete_node` — node_path=`URHelper`
- **Expect:** success

**UR-C7.** Save scene:
- `editor_save_scene`
- **Expect:** success
