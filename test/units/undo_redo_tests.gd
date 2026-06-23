@tool
extends RefCounted
## MCPToolkitUndoRedoAction unit tests: the headless-safe subset (begin, fluent
## chaining, inactive no-op guards, double-commit guards) plus the registry
## factory. Exercises the public undo/redo action API without an editor plugin.


static func run(h) -> void:
	_test_undo_redo_action(h)


# --- MCPToolkitUndoRedoAction (headless-safe subset) -----------------------

static func _test_undo_redo_action(h) -> void:
	h.begin("MCPToolkitUndoRedoAction")

	# 1. begin() returns non-null instance
	var action := MCPToolkitUndoRedoAction.begin("test action")
	h.ok(action != null, "begin() returns non-null instance")

	# 2. is_active() returns false in headless (no plugin loaded)
	h.ok(not action.is_active(), "is_active() false in headless")

	# 3. Fluent chaining — every method returns self
	var a2 := MCPToolkitUndoRedoAction.begin("chain test")
	var node := Node2D.new()
	var r1 = a2.do_property(node, &"position", Vector2(1, 2))
	h.ok(r1 == a2, "do_property returns self")
	var r2 = a2.undo_property(node, &"position", Vector2.ZERO)
	h.ok(r2 == a2, "undo_property returns self")
	var r3 = a2.do_method(node.set.bind(&"rotation", 1.0))
	h.ok(r3 == a2, "do_method returns self")
	var r4 = a2.undo_method(node.set.bind(&"rotation", 0.0))
	h.ok(r4 == a2, "undo_method returns self")
	var r5 = a2.do_reference(node)
	h.ok(r5 == a2, "do_reference returns self")
	var r6 = a2.undo_reference(node)
	h.ok(r6 == a2, "undo_reference returns self")
	node.free()

	# 4. All methods no-op without crash when inactive
	var inactive := MCPToolkitUndoRedoAction.begin("noop test")
	inactive.do_property(Node.new(), &"name", "test")  # won't crash
	inactive.undo_property(Node.new(), &"name", "old")
	inactive.do_method(Callable())
	inactive.undo_method(Callable())
	inactive.commit_recorded()
	h.ok(true, "all methods no-op without crash when inactive")

	# 5. Double-commit guard — second call is no-op (warning logged)
	var a3 := MCPToolkitUndoRedoAction.begin("double commit")
	a3.commit_recorded()
	a3.commit_recorded()  # should push_warning, not crash
	h.ok(true, "double commit_recorded() does not crash")

	# 6. commit() also guarded
	var a4 := MCPToolkitUndoRedoAction.begin("commit guard")
	a4.commit()
	a4.commit()  # should push_warning, not crash
	h.ok(true, "double commit() does not crash")

	# 7. Cross-commit guard (commit after commit_recorded)
	var a5 := MCPToolkitUndoRedoAction.begin("cross commit")
	a5.commit_recorded()
	a5.commit()  # should push_warning, not crash
	h.ok(true, "commit() after commit_recorded() does not crash")

	# 8. Registry factory returns valid instance
	var reg := MCPToolkitCommandRegistry.new()
	var factory_action := reg.create_undo_action("factory test")
	h.ok(factory_action != null, "create_undo_action() returns non-null")
	h.ok(not factory_action.is_active(), "factory action inactive in headless")

	print("")
