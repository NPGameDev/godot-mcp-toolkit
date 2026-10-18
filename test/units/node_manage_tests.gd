@tool
extends RefCounted
## node.manage root-guard unit tests: the scene root CAN be renamed (the guard
## was relaxed — node.set_property already renamed it via "name", so the two
## paths must agree), while reparent / reorder / duplicate on the root stay
## rejected (structurally invalid for a root). Drives the commands/node_commands
## _manage_* handlers directly with a standalone tree — no editor; the undo
## builder runs as its documented headless no-op, so undo recording is exercised
## crash-free here and verified interactively by the sweep.
## Also checks that duplicate gives the copy's descendants the scene root as
## owner, so the saved scene keeps them, under the original's parent or another
## one, including nodes the scene added under an instanced child, and leaves an
## instanced sub-scene's internals owned by the copy.

const NodeCommands := preload("res://addons/godot_mcp_toolkit/commands/node_commands.gd")
const _SUB_SCENE_FIXTURE := "user://node_manage_sub_scene_fixture.tscn"


static func run(testing) -> void:
	_test_root_rename_allowed(testing)
	_test_root_structural_guards_kept(testing)
	_test_duplicate_owns_descendants(testing)
	_test_duplicate_keeps_instance_internals(testing)
	_test_duplicate_under_other_parent(testing)
	_test_duplicate_keeps_nodes_added_under_an_instance(testing)


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


static func _test_duplicate_owns_descendants(testing) -> void:
	testing.begin("node.manage duplicate saves the copy's descendants")
	var root := Node2D.new()
	root.name = "Root"
	var original := Node2D.new()
	original.name = "Original"
	root.add_child(original)
	original.owner = root
	var child := Node2D.new()
	child.name = "Child"
	original.add_child(child)
	child.owner = root
	var grandchild := Node.new()
	grandchild.name = "Grandchild"
	child.add_child(grandchild)
	grandchild.owner = root

	var duplicated := NodeCommands._manage_duplicate(root, original, "Original", {"new_name": "Copy"})
	testing.ok(bool(duplicated.get("success", false)), "duplicate → success")
	var copy := root.get_node_or_null("Copy")
	testing.ok(copy != null and copy.get_node_or_null("Child/Grandchild") != null,
		"copy has its descendants in the tree")
	testing.ok(copy != null and copy.get_node_or_null("Child") != null
			and copy.get_node("Child").owner == root, "copy's child owned by the scene root")
	testing.ok(copy != null and copy.get_node_or_null("Child/Grandchild") != null
			and copy.get_node("Child/Grandchild").owner == root,
		"copy's grandchild owned by the scene root")

	# The saver keeps only nodes the scene root owns; pack + instantiate is what
	# a saved .tscn reloads as.
	var packed := PackedScene.new()
	packed.pack(root)
	var reloaded := packed.instantiate()
	testing.ok(reloaded.get_node_or_null("Copy/Child/Grandchild") != null,
		"packed scene keeps the copy's descendants")

	reloaded.free()
	root.free()
	print("")


static func _test_duplicate_keeps_instance_internals(testing) -> void:
	testing.begin("node.manage duplicate leaves an instance's internals to the instance")
	var sub_scene := _save_sub_scene_fixture(testing)
	if sub_scene == null:
		_remove_sub_scene_fixture()
		print("")
		return

	var root := Node2D.new()
	root.name = "Root"
	var instance := sub_scene.instantiate()
	root.add_child(instance)
	instance.owner = root

	var duplicated := NodeCommands._manage_duplicate(root, instance, "Sub", {"new_name": "SubCopy"})
	testing.ok(bool(duplicated.get("success", false)), "duplicate instance → success")
	var copy := root.get_node_or_null("SubCopy")
	testing.ok(copy != null and copy.owner == root, "instance copy owned by the scene root")
	testing.ok(copy != null and copy.get_node_or_null("Inner") != null
			and copy.get_node("Inner").owner == copy,
		"instance copy's internal child stays owned by the copy")

	root.free()
	_remove_sub_scene_fixture()
	print("")


static func _test_duplicate_under_other_parent(testing) -> void:
	testing.begin("node.manage duplicate under another parent saves the copy's descendants")
	var root := Node2D.new()
	root.name = "Root"
	var original := _add_owned_child(root, Node2D.new(), "Original", root)
	var child := _add_owned_child(original, Node2D.new(), "Child", root)
	_add_owned_child(child, Node.new(), "Grandchild", root)
	_add_owned_child(root, Node2D.new(), "Holder", root)

	var duplicated := NodeCommands._manage_duplicate(root, original, "Original",
			{"new_name": "Copy", "parent_path": "Holder"})
	testing.ok(bool(duplicated.get("success", false)), "duplicate under Holder → success")
	testing.eq(str(duplicated.get("path", "")), "Holder/Copy", "copy lands under Holder")
	testing.ok(_is_owned_by(root, "Holder/Copy/Child", root),
		"copy's child owned by the scene root")
	testing.ok(_is_owned_by(root, "Holder/Copy/Child/Grandchild", root),
		"copy's grandchild owned by the scene root")

	var reloaded := _pack_and_reload(root)
	testing.ok(reloaded.get_node_or_null("Holder/Copy/Child/Grandchild") != null,
		"packed scene keeps the copy's descendants under Holder")

	reloaded.free()
	root.free()
	print("")


static func _test_duplicate_keeps_nodes_added_under_an_instance(testing) -> void:
	testing.begin("node.manage duplicate saves nodes the scene added under an instanced child")
	var sub_scene := _save_sub_scene_fixture(testing)
	if sub_scene == null:
		_remove_sub_scene_fixture()
		print("")
		return

	# Original holds an instance with a node the scene root owns, added straight
	# under the instance.
	var root := Node2D.new()
	root.name = "Root"
	var original := _add_owned_child(root, Node2D.new(), "Original", root)
	var instance := _add_owned_child(original, sub_scene.instantiate(), "Pod", root)
	_add_owned_child(instance, Node.new(), "Added", root)

	var duplicated := NodeCommands._manage_duplicate(root, original, "Original", {"new_name": "Copy"})
	testing.ok(bool(duplicated.get("success", false)), "duplicate → success")
	testing.ok(_is_owned_by(root, "Copy/Pod", root), "copied instance owned by the scene root")
	testing.ok(_is_owned_by(root, "Copy/Pod/Added", root),
		"node added under the copied instance owned by the scene root")
	testing.ok(root.get_node_or_null("Copy/Pod") != null
			and _is_owned_by(root, "Copy/Pod/Inner", root.get_node("Copy/Pod")),
		"copied instance's internal child stays owned by the instance")

	var reloaded := _pack_and_reload(root)
	testing.ok(reloaded.get_node_or_null("Copy/Pod/Added") != null,
		"packed scene keeps the node added under the copied instance")

	reloaded.free()
	root.free()
	_remove_sub_scene_fixture()
	print("")


## Adds [param child] under [param parent] as [param child_name], owned by
## [param owner], the way a scene's own nodes are. Returns [param child].
static func _add_owned_child(parent: Node, child: Node, child_name: String, owner: Node) -> Node:
	child.name = child_name
	parent.add_child(child)
	child.owner = owner
	return child


## Returns whether the node at [param path] under [param root] exists and is
## owned by [param owner].
static func _is_owned_by(root: Node, path: String, owner: Node) -> bool:
	var node := root.get_node_or_null(path)
	return node != null and node.owner == owner


## Packs [param root] and instantiates the result, which is what a saved .tscn
## reloads as: the saver keeps only the nodes the scene root owns.
static func _pack_and_reload(root: Node) -> Node:
	var packed := PackedScene.new()
	packed.pack(root)
	return packed.instantiate()


## Saves a sub-scene (a Node2D "Sub" with one internal child, "Inner") to a
## user:// fixture and returns it loaded back, or null when the save fails.
## Node.duplicate() re-instances only a file-backed scene, so an instance under
## test needs a scene on disk.
static func _save_sub_scene_fixture(testing) -> PackedScene:
	var sub_root := Node2D.new()
	sub_root.name = "Sub"
	var inner := Node.new()
	inner.name = "Inner"
	sub_root.add_child(inner)
	inner.owner = sub_root
	var packed_sub := PackedScene.new()
	packed_sub.pack(sub_root)
	sub_root.free()
	var save_error := ResourceSaver.save(packed_sub, _SUB_SCENE_FIXTURE)
	testing.eq(save_error, OK, "sub-scene fixture saved")
	if save_error != OK:
		return null
	var sub_scene := ResourceLoader.load(_SUB_SCENE_FIXTURE) as PackedScene
	testing.ok(sub_scene != null, "sub-scene fixture loaded")
	return sub_scene


static func _remove_sub_scene_fixture() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_SUB_SCENE_FIXTURE))
