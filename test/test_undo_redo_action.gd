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
##   3. node_call_method — diagnose_undo_redo (check environment first)
##   4. node_call_method — trigger_undo / trigger_redo / run_undo_redo_tests
##
## The trigger_undo / trigger_redo methods operate on the edited scene's
## undo history by default. Pass a node_path to target a specific node's
## history (for multi-tab editing scenarios).

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const MCPToolkitUndoRedoAction = preload("res://addons/godot_mcp_toolkit/scene/mcp_toolkit_undo_redo_action.gd")


# -- Diagnostics (call first to verify environment) ---------------------------


## Returns diagnostic info about the undo/redo environment.
## Call this before any tests to verify the builder is functional.
func diagnose_undo_redo() -> Dictionary:
	var diagnostics := {}

	# 1. Hub plugin reference
	diagnostics["hub_plugin_set"] = Modules.EditorAccess.has_plugin()

	# 2. EditorUndoRedoManager
	var undo_redo_manager = Modules.EditorAccess.get_undo_redo()
	diagnostics["undo_redo_null"] = undo_redo_manager == null
	if undo_redo_manager != null:
		diagnostics["undo_redo_class"] = undo_redo_manager.get_class()

	# 3. Scene context
	var root = EditorInterface.get_edited_scene_root()
	diagnostics["scene_root_null"] = root == null
	if root != null:
		diagnostics["scene_root_name"] = root.name

	# 4. History resolution
	if undo_redo_manager != null and root != null:
		var history_id = undo_redo_manager.get_object_history_id(root)
		diagnostics["root_history_id"] = history_id
		var undo_redo = undo_redo_manager.get_history_undo_redo(history_id)
		diagnostics["history_undo_redo_null"] = undo_redo == null
		if undo_redo != null:
			diagnostics["has_undo"] = undo_redo.has_undo()
			diagnostics["has_redo"] = undo_redo.has_redo()

	# 5. Builder smoke test: create and commit a trivial action
	if undo_redo_manager != null and root != null:
		var test_node := Node2D.new()
		test_node.name = "URDiag_SmokeNode"
		root.add_child(test_node)
		test_node.owner = root

		var action = MCPToolkitUndoRedoAction.begin("diag smoke", test_node)
		diagnostics["builder_active"] = action.is_active()

		test_node.position = Vector2(99, 99)
		action.do_property(test_node, &"position", Vector2(99, 99))
		action.undo_property(test_node, &"position", Vector2.ZERO)
		action.commit_recorded()

		# Check if action was recorded
		var smoke_history_id = undo_redo_manager.get_object_history_id(test_node)
		diagnostics["smoke_history_id"] = smoke_history_id
		var smoke_undo_redo = undo_redo_manager.get_history_undo_redo(smoke_history_id)
		if smoke_undo_redo != null:
			diagnostics["smoke_has_undo_after_commit"] = smoke_undo_redo.has_undo()
			# Try undo
			if smoke_undo_redo.has_undo():
				smoke_undo_redo.undo()
				diagnostics["smoke_pos_after_undo"] = str(test_node.position)
				diagnostics["smoke_undo_worked"] = test_node.position == Vector2.ZERO
				# Redo
				if smoke_undo_redo.has_redo():
					smoke_undo_redo.redo()
					diagnostics["smoke_pos_after_redo"] = str(test_node.position)
				# Undo again to clean up
				if smoke_undo_redo.has_undo():
					smoke_undo_redo.undo()
		else:
			diagnostics["smoke_undo_redo_null"] = true

		# Cleanup
		test_node.get_parent().remove_child(test_node)
		test_node.queue_free()

	return diagnostics


# -- Agent-facing methods (called via node_call_method) -----------------------


## Trigger undo on the edited scene's history. Returns a status dict.
## [param context_node_path]: optional path relative to scene root — uses
##   that node's history. Empty string = edited scene root's history.
func trigger_undo(context_node_path: String = "") -> Dictionary:
	var undo_redo_manager = Modules.EditorAccess.get_undo_redo()
	if undo_redo_manager == null:
		return {"status": "error", "message": "EditorUndoRedoManager not available (headless or plugin not loaded)"}

	var history_id := _resolve_history_id(undo_redo_manager, context_node_path)
	if history_id == -99:  # INVALID_HISTORY
		return {"status": "error", "message": "Could not resolve history for '%s'" % context_node_path}

	var undo_redo = undo_redo_manager.get_history_undo_redo(history_id)
	if undo_redo == null:
		return {"status": "error", "message": "get_history_undo_redo(%d) returned null" % history_id}
	if not undo_redo.has_undo():
		return {"status": "error", "message": "No undo actions in history %d" % history_id, "history_id": history_id}

	var ok = undo_redo.undo()
	return {"status": "ok" if ok else "error", "history_id": history_id}


## Trigger redo on the edited scene's history. Returns a status dict.
func trigger_redo(context_node_path: String = "") -> Dictionary:
	var undo_redo_manager = Modules.EditorAccess.get_undo_redo()
	if undo_redo_manager == null:
		return {"status": "error", "message": "EditorUndoRedoManager not available (headless or plugin not loaded)"}

	var history_id := _resolve_history_id(undo_redo_manager, context_node_path)
	if history_id == -99:
		return {"status": "error", "message": "Could not resolve history for '%s'" % context_node_path}

	var undo_redo = undo_redo_manager.get_history_undo_redo(history_id)
	if undo_redo == null:
		return {"status": "error", "message": "get_history_undo_redo(%d) returned null" % history_id}
	if not undo_redo.has_redo():
		return {"status": "error", "message": "No redo actions in history %d" % history_id, "history_id": history_id}

	var ok = undo_redo.redo()
	return {"status": "ok" if ok else "error", "history_id": history_id}


## Run self-contained integration tests of MCPToolkitUndoRedoAction.
## Creates temporary nodes, mutates via the builder, undoes/redoes
## programmatically, and verifies state. Cleans up afterward.
func run_undo_redo_tests() -> Dictionary:
	var undo_redo_manager = Modules.EditorAccess.get_undo_redo()
	if undo_redo_manager == null:
		return {"status": "skipped", "message": "No EditorUndoRedoManager — cannot run integration tests"}

	var root = EditorInterface.get_edited_scene_root()
	if root == null:
		return {"status": "error", "message": "No edited scene open"}

	var results: Array[Dictionary] = []

	# --- Test 1: Property set + undo/redo (commit_recorded) ---
	var property_results = _test_property_undo_redo(undo_redo_manager, root)
	results.append_array(property_results)

	# --- Test 2: Method-based undo/redo (add_child/remove_child) ---
	var method_results = _test_method_undo_redo(undo_redo_manager, root)
	results.append_array(method_results)

	# --- Test 3: commit() executes do-side ---
	var commit_results = _test_commit_executes_do(undo_redo_manager, root)
	results.append_array(commit_results)

	var passed := results.filter(func(result: Dictionary) -> bool: return result["pass"]).size()
	var failed := results.filter(func(result: Dictionary) -> bool: return not result["pass"]).size()
	return {
		"status": "ok" if failed == 0 else "fail",
		"passed": passed,
		"failed": failed,
		"total": results.size(),
		"results": results,
	}


# -- Internal helpers ---------------------------------------------------------


func _resolve_history_id(undo_redo_manager, context_node_path: String) -> int:
	var root = EditorInterface.get_edited_scene_root()
	if root == null:
		return -99  # INVALID_HISTORY
	if context_node_path != "":
		var node = root.get_node_or_null(context_node_path)
		if node == null:
			return -99
		return undo_redo_manager.get_object_history_id(node)
	return undo_redo_manager.get_object_history_id(root)


func _undo_for(undo_redo_manager, node: Node) -> Dictionary:
	var history_id = undo_redo_manager.get_object_history_id(node)
	var undo_redo = undo_redo_manager.get_history_undo_redo(history_id)
	if undo_redo == null:
		return {"ok": false, "reason": "undo_redo null for history %s" % str(history_id)}
	if not undo_redo.has_undo():
		return {"ok": false, "reason": "has_undo false in history %s" % str(history_id)}
	var success = undo_redo.undo()
	return {"ok": bool(success), "history_id": history_id}


func _redo_for(undo_redo_manager, node: Node) -> Dictionary:
	var history_id = undo_redo_manager.get_object_history_id(node)
	var undo_redo = undo_redo_manager.get_history_undo_redo(history_id)
	if undo_redo == null:
		return {"ok": false, "reason": "undo_redo null for history %s" % str(history_id)}
	if not undo_redo.has_redo():
		return {"ok": false, "reason": "has_redo false in history %s" % str(history_id)}
	var success = undo_redo.redo()
	return {"ok": bool(success), "history_id": history_id}


## Test 1: simple property set -> undo -> redo via commit_recorded().
func _test_property_undo_redo(undo_redo_manager, root: Node) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var node := Node2D.new()
	node.name = "URTest_PropNode"
	root.add_child(node)
	node.owner = root

	var old_pos := node.position
	var new_pos := Vector2(123, 456)

	node.position = new_pos
	MCPToolkitUndoRedoAction.begin("test property", node) \
		.do_property(node, &"position", new_pos) \
		.undo_property(node, &"position", old_pos) \
		.commit_recorded()

	results.append({"test": "prop_set", "pass": node.position == new_pos})

	_undo_for(undo_redo_manager, node)
	results.append({"test": "prop_undo", "pass": node.position == old_pos})

	_redo_for(undo_redo_manager, node)
	results.append({"test": "prop_redo", "pass": node.position == new_pos})

	_undo_for(undo_redo_manager, node)
	node.get_parent().remove_child(node)
	node.queue_free()
	return results


## Test 2: method-based add_child / remove_child + references.
func _test_method_undo_redo(undo_redo_manager, root: Node) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var child := Sprite2D.new()
	child.name = "URTest_MethodChild"

	root.add_child(child)
	child.owner = root

	MCPToolkitUndoRedoAction.begin("test method add", child) \
		.do_method(root.add_child.bind(child)) \
		.do_method(child.set.bind(&"owner", root)) \
		.do_reference(child) \
		.undo_method(root.remove_child.bind(child)) \
		.undo_reference(child) \
		.commit_recorded()

	results.append({"test": "method_added", "pass": root.has_node("URTest_MethodChild")})

	_undo_for(undo_redo_manager, root)
	results.append({"test": "method_undo", "pass": not root.has_node("URTest_MethodChild")})

	_redo_for(undo_redo_manager, root)
	results.append({"test": "method_redo", "pass": root.has_node("URTest_MethodChild")})

	_undo_for(undo_redo_manager, root)
	if is_instance_valid(child) and child.get_parent() != null:
		child.get_parent().remove_child(child)
	if is_instance_valid(child):
		child.queue_free()
	return results


## Test 3: commit() (non-recorded) executes the do-side immediately.
func _test_commit_executes_do(undo_redo_manager, root: Node) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var node := Node2D.new()
	node.name = "URTest_CommitNode"
	root.add_child(node)
	node.owner = root

	var old_vis := node.visible
	MCPToolkitUndoRedoAction.begin("test commit do-side", node) \
		.do_property(node, &"visible", false) \
		.undo_property(node, &"visible", old_vis) \
		.commit()

	results.append({"test": "commit_do_executes", "pass": node.visible == false})

	_undo_for(undo_redo_manager, node)
	results.append({"test": "commit_undo", "pass": node.visible == old_vis})

	node.get_parent().remove_child(node)
	node.queue_free()
	return results
