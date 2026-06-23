@tool
extends RefCounted
## MCPToolkitUndoRedoAction unit tests: the headless-safe subset (begin, fluent
## chaining, inactive no-op guards, double-commit guards) plus the registry
## factory. Exercises the public undo/redo action API without an editor plugin.


static func run(testing) -> void:
	_test_undo_redo_action(testing)


# --- MCPToolkitUndoRedoAction (headless-safe subset) -----------------------

static func _test_undo_redo_action(testing) -> void:
	testing.begin("MCPToolkitUndoRedoAction")

	# 1. begin() returns non-null instance
	var action := MCPToolkitUndoRedoAction.begin("test action")
	testing.ok(action != null, "begin() returns non-null instance")

	# 2. is_active() returns false in headless (no plugin loaded)
	testing.ok(not action.is_active(), "is_active() false in headless")

	# 3. Fluent chaining — every method returns self
	var chain_action := MCPToolkitUndoRedoAction.begin("chain test")
	var node := Node2D.new()
	var do_property_return = chain_action.do_property(node, &"position", Vector2(1, 2))
	testing.ok(do_property_return == chain_action, "do_property returns self")
	var undo_property_return = chain_action.undo_property(node, &"position", Vector2.ZERO)
	testing.ok(undo_property_return == chain_action, "undo_property returns self")
	var do_method_return = chain_action.do_method(node.set.bind(&"rotation", 1.0))
	testing.ok(do_method_return == chain_action, "do_method returns self")
	var undo_method_return = chain_action.undo_method(node.set.bind(&"rotation", 0.0))
	testing.ok(undo_method_return == chain_action, "undo_method returns self")
	var do_reference_return = chain_action.do_reference(node)
	testing.ok(do_reference_return == chain_action, "do_reference returns self")
	var undo_reference_return = chain_action.undo_reference(node)
	testing.ok(undo_reference_return == chain_action, "undo_reference returns self")
	node.free()

	# 4. All methods no-op without crash when inactive
	var inactive := MCPToolkitUndoRedoAction.begin("noop test")
	inactive.do_property(Node.new(), &"name", "test")  # won't crash
	inactive.undo_property(Node.new(), &"name", "old")
	inactive.do_method(Callable())
	inactive.undo_method(Callable())
	inactive.commit_recorded()
	testing.ok(true, "all methods no-op without crash when inactive")

	# 5. Double-commit guard — second call is no-op (warning logged)
	var double_commit_action := MCPToolkitUndoRedoAction.begin("double commit")
	double_commit_action.commit_recorded()
	double_commit_action.commit_recorded()  # should push_warning, not crash
	testing.ok(true, "double commit_recorded() does not crash")

	# 6. commit() also guarded
	var commit_guard_action := MCPToolkitUndoRedoAction.begin("commit guard")
	commit_guard_action.commit()
	commit_guard_action.commit()  # should push_warning, not crash
	testing.ok(true, "double commit() does not crash")

	# 7. Cross-commit guard (commit after commit_recorded)
	var cross_commit_action := MCPToolkitUndoRedoAction.begin("cross commit")
	cross_commit_action.commit_recorded()
	cross_commit_action.commit()  # should push_warning, not crash
	testing.ok(true, "commit() after commit_recorded() does not crash")

	# 8. Registry factory returns valid instance
	var registry := MCPToolkitCommandRegistry.new()
	var factory_action := registry.create_undo_action("factory test")
	testing.ok(factory_action != null, "create_undo_action() returns non-null")
	testing.ok(not factory_action.is_active(), "factory action inactive in headless")

	print("")
