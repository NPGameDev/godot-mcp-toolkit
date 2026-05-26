@tool
extends Node
## Integration test helper for MCPToolkitUndoRedoAction.
##
## Attach to a node in the edited scene, then call methods via
## node_call_method to test undo/redo of MCP mutations.
##
## Usage during tool sweep:
##   1. scene.create_node — add a Node named "UndoRedoHelper"
##   2. node.set_script — attach res://test/test_undo_redo_action.gd
##   3. node_call_method — trigger_undo / trigger_redo / run_undo_redo_tests
##
## The trigger_undo / trigger_redo methods operate on the edited scene's
## undo history by default. Pass a node_path to target a specific node's
## history (for multi-tab editing scenarios).

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")


# -- Agent-facing methods (called via node_call_method) -----------------------


## Trigger undo on the edited scene's history. Returns a status dict.
## [param context_node_path]: optional path relative to scene root — uses
##   that node's history. Empty string = edited scene root's history.
func trigger_undo(context_node_path: String = "") -> Dictionary:
	var ur = _Hub.get_undo_redo()
	if ur == null:
		return {"status": "error", "message": "EditorUndoRedoManager not available (headless or plugin not loaded)"}

	var history_id := _resolve_history_id(ur, context_node_path)
	if history_id == -99:  # INVALID_HISTORY
		return {"status": "error", "message": "Could not resolve history for '%s'" % context_node_path}

	var undo_redo = ur.get_history_undo_redo(history_id)
	if not undo_redo.has_undo():
		return {"status": "error", "message": "No undo actions in history %d" % history_id}

	var ok = undo_redo.undo()
	return {"status": "ok" if ok else "error", "history_id": history_id}


## Trigger redo on the edited scene's history. Returns a status dict.
func trigger_redo(context_node_path: String = "") -> Dictionary:
	var ur = _Hub.get_undo_redo()
	if ur == null:
		return {"status": "error", "message": "EditorUndoRedoManager not available (headless or plugin not loaded)"}

	var history_id := _resolve_history_id(ur, context_node_path)
	if history_id == -99:
		return {"status": "error", "message": "Could not resolve history for '%s'" % context_node_path}

	var undo_redo = ur.get_history_undo_redo(history_id)
	if not undo_redo.has_redo():
		return {"status": "error", "message": "No redo actions in history %d" % history_id}

	var ok = undo_redo.redo()
	return {"status": "ok" if ok else "error", "history_id": history_id}


## Run self-contained integration tests of MCPToolkitUndoRedoAction.
## Creates temporary nodes, mutates via the builder, undoes/redoes
## programmatically, and verifies state. Cleans up afterward.
func run_undo_redo_tests() -> Dictionary:
	var ur = _Hub.get_undo_redo()
	if ur == null:
		return {"status": "skipped", "message": "No EditorUndoRedoManager — cannot run integration tests"}

	var root = EditorInterface.get_edited_scene_root()
	if root == null:
		return {"status": "error", "message": "No edited scene open"}

	var results: Array[Dictionary] = []

	# --- Test 1: Property set + undo/redo (commit_recorded) ---
	var t1 = _test_property_undo_redo(ur, root)
	results.append_array(t1)

	# --- Test 2: Method-based undo/redo (add_child/remove_child) ---
	var t2 = _test_method_undo_redo(ur, root)
	results.append_array(t2)

	# --- Test 3: commit() executes do-side ---
	var t3 = _test_commit_executes_do(ur, root)
	results.append_array(t3)

	var passed := results.filter(func(r: Dictionary) -> bool: return r["pass"]).size()
	var failed := results.filter(func(r: Dictionary) -> bool: return not r["pass"]).size()
	return {
		"status": "ok" if failed == 0 else "fail",
		"passed": passed,
		"failed": failed,
		"total": results.size(),
		"results": results,
	}


# -- Internal helpers ---------------------------------------------------------


func _resolve_history_id(ur, context_node_path: String) -> int:
	var root = EditorInterface.get_edited_scene_root()
	if root == null:
		return -99  # INVALID_HISTORY
	if context_node_path != "":
		var node = root.get_node_or_null(context_node_path)
		if node == null:
			return -99
		return ur.get_object_history_id(node)
	return ur.get_object_history_id(root)


func _undo_for(ur, node: Node) -> bool:
	var hist_id := int(ur.get_object_history_id(node))
	var undo_redo = ur.get_history_undo_redo(hist_id)
	if undo_redo.has_undo():
		return undo_redo.undo()
	return false


func _redo_for(ur, node: Node) -> bool:
	var hist_id := int(ur.get_object_history_id(node))
	var undo_redo = ur.get_history_undo_redo(hist_id)
	if undo_redo.has_redo():
		return undo_redo.redo()
	return false


## Test 1: simple property set → undo → redo via commit_recorded().
func _test_property_undo_redo(ur, root: Node) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var node := Node2D.new()
	node.name = "URTest_PropNode"
	root.add_child(node)
	node.owner = root

	var old_pos := node.position  # Vector2(0, 0)
	var new_pos := Vector2(123, 456)

	# Apply mutation first, then record.
	node.position = new_pos
	MCPToolkitUndoRedoAction.begin("test property", node) \
		.do_property(node, &"position", new_pos) \
		.undo_property(node, &"position", old_pos) \
		.commit_recorded()

	results.append({"test": "prop_set", "pass": node.position == new_pos})

	# Undo — should revert to old_pos.
	_undo_for(ur, node)
	results.append({"test": "prop_undo", "pass": node.position == old_pos})

	# Redo — should restore new_pos.
	_redo_for(ur, node)
	results.append({"test": "prop_redo", "pass": node.position == new_pos})

	# Cleanup: undo to remove state, then free.
	_undo_for(ur, node)
	node.get_parent().remove_child(node)
	node.queue_free()
	return results


## Test 2: method-based add_child / remove_child + references.
func _test_method_undo_redo(ur, root: Node) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var child := Sprite2D.new()
	child.name = "URTest_MethodChild"

	# Apply mutation first: add child to root.
	root.add_child(child)
	child.owner = root

	# Record for undo: do=add_child, undo=remove_child.
	MCPToolkitUndoRedoAction.begin("test method add", child) \
		.do_method(root.add_child.bind(child)) \
		.do_method(child.set.bind(&"owner", root)) \
		.do_reference(child) \
		.undo_method(root.remove_child.bind(child)) \
		.undo_reference(child) \
		.commit_recorded()

	results.append({"test": "method_added", "pass": root.has_node("URTest_MethodChild")})

	# Undo — child should be removed.
	_undo_for(ur, root)
	results.append({"test": "method_undo", "pass": not root.has_node("URTest_MethodChild")})

	# Redo — child should be back.
	_redo_for(ur, root)
	var re_added := root.has_node("URTest_MethodChild")
	results.append({"test": "method_redo", "pass": re_added})

	# Cleanup: undo to remove, then free.
	_undo_for(ur, root)
	if is_instance_valid(child) and child.get_parent() != null:
		child.get_parent().remove_child(child)
	if is_instance_valid(child):
		child.queue_free()
	return results


## Test 3: commit() (non-recorded) executes the do-side immediately.
func _test_commit_executes_do(ur, root: Node) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var node := Node2D.new()
	node.name = "URTest_CommitNode"
	root.add_child(node)
	node.owner = root

	var old_vis := node.visible  # true
	# Do NOT apply mutation — commit() will execute the do-side.
	MCPToolkitUndoRedoAction.begin("test commit do-side", node) \
		.do_property(node, &"visible", false) \
		.undo_property(node, &"visible", old_vis) \
		.commit()

	results.append({"test": "commit_do_executes", "pass": node.visible == false})

	# Undo — should restore visibility.
	_undo_for(ur, node)
	results.append({"test": "commit_undo", "pass": node.visible == old_vis})

	# Cleanup.
	node.get_parent().remove_child(node)
	node.queue_free()
	return results
