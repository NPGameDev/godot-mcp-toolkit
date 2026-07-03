@tool
extends RefCounted
## node.manage root-guard unit tests: the scene root CAN be renamed (the guard
## was relaxed — node.set_property already renamed it via "name", so the two
## paths must agree), while reparent / reorder / duplicate on the root stay
## rejected (structurally invalid for a root). Drives the commands/node_commands
## _manage_* handlers directly with a standalone tree — no editor; the undo
## builder runs as its documented headless no-op, so undo recording is exercised
## crash-free here and verified interactively by the sweep.

const NodeCommands := preload("res://addons/godot_mcp_toolkit/commands/node_commands.gd")


static func run(testing) -> void:
	_test_root_rename_allowed(testing)
	_test_root_structural_guards_kept(testing)


static func _test_root_rename_allowed(testing) -> void:
	testing.begin("node.manage root rename")
	var root := Node2D.new()
	root.name = "OriginalRoot"
	var child := Node.new()
	child.name = "Child"
	root.add_child(child)

	var renamed := NodeCommands._manage_rename(root, root, ".", {"new_name": "RenamedRoot"})
	testing.ok(bool(renamed.get("success", false)), "root rename → success (no INVALID_PATH)")
	testing.eq(str(root.name), "RenamedRoot", "root name applied")
	testing.eq(str(renamed.get("action", "")), "rename", "payload action = rename")
	testing.eq(str(renamed.get("old_name", "")), "OriginalRoot", "payload old_name preserved")
	testing.eq(str(renamed.get("new_name", "")), "RenamedRoot", "payload new_name")
	testing.eq(str(renamed.get("new_path", "")), ".", "payload new_path is '.' for the root")
	# Reaching here means the undo chain (begin → do/undo property with the
	# pre-mutation old name → commit_recorded) ran through the relaxed path
	# without crashing; headless it is the documented no-op.
	testing.ok(true, "undo recording path exercised without crash")

	# Non-root rename unchanged (control).
	var child_rename := NodeCommands._manage_rename(root, child, "Child", {"new_name": "RenamedChild"})
	testing.ok(bool(child_rename.get("success", false)), "child rename still succeeds")
	testing.eq(str(child_rename.get("new_path", "")), "RenamedChild", "child new_path")

	# Guard order unchanged: a missing new_name still rejects before anything else.
	var missing_name := NodeCommands._manage_rename(root, root, ".", {})
	testing.ok(not bool(missing_name.get("success", true)), "missing new_name → still rejected")
	testing.eq(str(missing_name.get("code", "")), "INVALID_PARAMS", "missing new_name code")

	root.free()
	print("")


static func _test_root_structural_guards_kept(testing) -> void:
	testing.begin("node.manage root structural guards kept")
	var root := Node2D.new()
	root.name = "Root"
	var child := Node.new()
	child.name = "Child"
	root.add_child(child)

	# Only RENAME was relaxed — the three structurally-invalid root operations
	# must keep rejecting with INVALID_PATH.
	var reparented := NodeCommands._manage_reparent(root, root, ".", {"new_parent_path": "Child"})
	testing.ok(not bool(reparented.get("success", true)), "root reparent → rejected")
	testing.eq(str(reparented.get("code", "")), "INVALID_PATH", "root reparent code INVALID_PATH")
	testing.ok(str(reparented.get("error", "")).contains("reparent"), "root reparent error names the action")

	var reordered := NodeCommands._manage_reorder(root, root, ".", {"new_index": 0})
	testing.ok(not bool(reordered.get("success", true)), "root reorder → rejected")
	testing.eq(str(reordered.get("code", "")), "INVALID_PATH", "root reorder code INVALID_PATH")
	testing.ok(str(reordered.get("error", "")).contains("reorder"), "root reorder error names the action")

	var duplicated := NodeCommands._manage_duplicate(root, root, ".", {})
	testing.ok(not bool(duplicated.get("success", true)), "root duplicate → rejected")
	testing.eq(str(duplicated.get("code", "")), "INVALID_PATH", "root duplicate code INVALID_PATH")
	testing.ok(str(duplicated.get("error", "")).contains("duplicate"), "root duplicate error names the action")

	root.free()
	print("")
