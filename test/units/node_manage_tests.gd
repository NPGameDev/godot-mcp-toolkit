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
## instanced sub-scene's internals owned by the copy. A duplicated scene instance
## packs as an instance with only its overrides, and a node duplicated inside an
## editable instance keeps the children the instance owns.

const NodeCommands := preload("res://addons/godot_mcp_toolkit/commands/node_commands.gd")
const _SUB_SCENE_FIXTURE := "user://node_manage_sub_scene_fixture.tscn"
const _DEEP_SUB_SCENE_FIXTURE := "user://node_manage_deep_sub_scene_fixture.tscn"


static func run(testing) -> void:
	_test_root_rename_allowed(testing)
	_test_root_structural_guards_kept(testing)
	_test_duplicate_owns_descendants(testing)
	_test_duplicate_keeps_instance_internals(testing)
	_test_duplicate_under_other_parent(testing)
	_test_duplicate_keeps_nodes_added_under_an_instance(testing)
	_test_duplicate_keeps_instance_linked(testing)
	_test_duplicate_inside_editable_instance_keeps_children(testing)


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


static func _test_duplicate_keeps_instance_linked(testing) -> void:
	testing.begin("node.manage duplicate keeps a duplicated scene instance linked to its scene")
	var sub_scene := _save_deep_sub_scene_fixture(testing)
	if sub_scene == null:
		_remove_deep_sub_scene_fixture()
		print("")
		return

	# The editor opens a scene's instances with their instance state, which is what
	# lets the saver store only an instance's overrides.
	var root := Node2D.new()
	root.name = "Root"
	var instance := _add_owned_child(root,
			sub_scene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE), "Pod", root) as Node2D
	instance.position = Vector2(3, 4)

	var duplicated := NodeCommands._manage_duplicate(root, instance, "Pod", {"new_name": "PodCopy"})
	testing.ok(bool(duplicated.get("success", false)), "duplicate instance → success")

	var packed := PackedScene.new()
	packed.pack(root)
	var state := packed.get_state()
	var original_index := _state_node_index(state, "Pod")
	var copy_index := _state_node_index(state, "PodCopy")
	testing.ok(original_index >= 0 and copy_index >= 0,
			"packed scene holds the original and the copy")
	if copy_index >= 0:
		testing.ok(state.get_node_instance(copy_index) != null, "packed copy is a scene instance")
		testing.eq(str(state.get_node_type(copy_index)), "",
				"packed copy has no type of its own (its scene gives it)")
		testing.eq(_state_property_list(state, copy_index), "position",
				"packed copy stores only the one override")
	if original_index >= 0 and copy_index >= 0:
		testing.eq(_state_property_list(state, copy_index),
				_state_property_list(state, original_index),
				"packed copy stores what the original stores")

	root.free()
	_remove_deep_sub_scene_fixture()
	print("")


static func _test_duplicate_inside_editable_instance_keeps_children(testing) -> void:
	testing.begin("node.manage duplicate inside an editable instance keeps the instance's children")
	var sub_scene := _save_deep_sub_scene_fixture(testing)
	if sub_scene == null:
		_remove_deep_sub_scene_fixture()
		print("")
		return

	var root := Node2D.new()
	root.name = "Root"
	var instance := _add_owned_child(root,
			sub_scene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE), "Pod", root)
	root.set_editable_instance(instance, true)
	var inner := instance.get_node("Inner")

	var duplicated := NodeCommands._manage_duplicate(root, inner, "Pod/Inner",
			{"new_name": "InnerCopy"})
	testing.ok(bool(duplicated.get("success", false)), "duplicate inner node → success")
	testing.ok(_is_owned_by(root, "Pod/InnerCopy/Leaf", root),
			"copy's child owned by the scene root")
	testing.ok(_is_owned_by(root, "Pod/InnerCopy/Leaf/Tip", root),
			"copy's grandchild owned by the scene root")

	var reloaded := _pack_and_reload(root)
	testing.ok(reloaded.get_node_or_null("Pod/InnerCopy/Leaf/Tip") != null,
			"packed scene keeps the copied inner node's children")

	reloaded.free()
	root.free()
	_remove_deep_sub_scene_fixture()
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


## Saves a sub-scene to a user:// fixture and returns it loaded back, or null when
## the save fails: a Node2D "Sub" turned away from the class default, so a copy
## that loses its link to the scene stores the turn itself, and an internal chain
## "Inner/Leaf/Tip" the scene owns.
static func _save_deep_sub_scene_fixture(testing) -> PackedScene:
	var sub_root := Node2D.new()
	sub_root.name = "Sub"
	sub_root.rotation = 0.5
	var inner := _add_owned_child(sub_root, Node2D.new(), "Inner", sub_root)
	var leaf := _add_owned_child(inner, Node2D.new(), "Leaf", sub_root)
	_add_owned_child(leaf, Node.new(), "Tip", sub_root)
	var packed_sub := PackedScene.new()
	packed_sub.pack(sub_root)
	sub_root.free()
	var save_error := ResourceSaver.save(packed_sub, _DEEP_SUB_SCENE_FIXTURE)
	testing.eq(save_error, OK, "deep sub-scene fixture saved")
	if save_error != OK:
		return null
	var sub_scene := ResourceLoader.load(
			_DEEP_SUB_SCENE_FIXTURE, "", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	testing.ok(sub_scene != null, "deep sub-scene fixture loaded")
	return sub_scene


static func _remove_deep_sub_scene_fixture() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_DEEP_SUB_SCENE_FIXTURE))


## Returns the index of the node at [param path] (relative to the packed root) in
## [param state], or -1 when it holds no such node.
static func _state_node_index(state: SceneState, path: String) -> int:
	for index in state.get_node_count():
		if str(state.get_node_path(index)).trim_prefix("./") == path:
			return index
	return -1


## Returns the names of the properties [param state] stores for the node at
## [param index], sorted and comma-separated.
static func _state_property_list(state: SceneState, index: int) -> String:
	var names := PackedStringArray()
	for property_index in state.get_node_property_count(index):
		names.append(str(state.get_node_property_name(index, property_index)))
	names.sort()
	return ",".join(names)
