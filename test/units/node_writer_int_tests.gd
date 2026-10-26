@tool
extends RefCounted
## The node-side writers (node.set_property single and batch, scene.instantiate's
## and node.manage duplicate's properties) mostly on a node whose script is not @tool,
## which the placeholder_like_node.gd fixture stands in for: a JSON float on an int
## property stays an int, and a bare path on a Resource property is refused and not
## stored. The handlers run on a standalone tree, so no editor is needed; the undo
## builder runs as its documented headless no-op.

const NodeCommands := preload("res://addons/godot_mcp_toolkit/commands/node_commands.gd")
const SceneCommands := preload("res://addons/godot_mcp_toolkit/commands/scene_commands.gd")
const UndoRedoHelpers := preload("res://addons/godot_mcp_toolkit/scene/undo_redo_helpers.gd")
const PlaceholderLikeNode := preload("res://test/fixtures/placeholder_like_node.gd")
const TEXTURE_PATH := "res://test/fixtures/placeholder_texture.tres"


static func run(testing) -> void:
	_test_set_property_single(testing)
	_test_set_property_batch(testing)
	_test_instantiate_properties(testing)
	_test_duplicate_properties(testing)
	_test_batch_truncation_has_no_shared_note(testing)
	_test_batch_shared_external_write_keeps_note(testing)
	_test_clamp_after_fit_names_requested_value(testing)
	_test_group_header_does_not_hide_int(testing)
	_test_set_property_bare_res_path(testing)
	_test_set_property_bare_uid_and_user_paths(testing)
	_test_set_property_bare_path_on_placeholder(testing)
	_test_batch_bare_path_on_placeholder(testing)
	_test_batch_bare_uid_path(testing)
	_test_instantiate_bare_path_on_placeholder(testing)
	_test_instantiate_bare_user_path(testing)
	_test_duplicate_bare_path_on_placeholder(testing)
	_test_duplicate_bare_user_path(testing)


static func _test_set_property_single(testing) -> void:
	testing.begin("node.set_property keeps an int export an int")
	var root := _scene_with_pod()
	var pod := root.get_node("Pod")

	var whole := NodeCommands._set_property_scalar_single(pod, "Pod", "hp", 100.0)
	testing.ok(bool(whole.get("success", false)), "whole float → success")
	_expect_int(testing, pod.get("hp"), 100, "whole float 100.0")
	testing.ok(not whole.has("warning"), "whole float → no warning")

	var fraction := NodeCommands._set_property_scalar_single(pod, "Pod", "hp", 100.5)
	testing.ok(bool(fraction.get("success", false)), "fraction → success")
	_expect_int(testing, pod.get("hp"), 100, "100.5 truncated")
	_expect_truncation_warning(testing, str(fraction.get("warning", "")), "100", "100.5")

	root.free()
	print("")


static func _test_set_property_batch(testing) -> void:
	testing.begin("node.set_property batch keeps an int export an int")
	var root := _scene_with_pod()
	var pod := root.get_node("Pod")
	var server := _server_with_undo_helpers(testing)

	var whole := NodeCommands._batch_set_properties(server, root,
			[{"node_path": "Pod", "property": "hp", "value": 101.0}])
	var whole_entry := _first_result(whole)
	testing.ok(bool(whole_entry.get("success", false)), "whole float → entry success")
	_expect_int(testing, pod.get("hp"), 101, "whole float 101.0")
	testing.ok(not whole_entry.has("warning"), "whole float → no entry warning")

	var fraction := NodeCommands._batch_set_properties(server, root,
			[{"node_path": "Pod", "property": "hp", "value": 101.5}])
	var fraction_entry := _first_result(fraction)
	testing.ok(bool(fraction_entry.get("success", false)), "fraction → entry success")
	_expect_int(testing, pod.get("hp"), 101, "101.5 truncated")
	_expect_truncation_warning(testing, str(fraction_entry.get("warning", "")), "101", "101.5")

	server.get("undo_helpers").free()
	server.free()
	root.free()
	print("")


static func _test_instantiate_properties(testing) -> void:
	testing.begin("scene.instantiate instances[].properties keeps an int export an int")
	var sub_root := Node.new()
	sub_root.name = "Pod"
	sub_root.set_script(PlaceholderLikeNode)
	var packed := PackedScene.new()
	testing.eq(packed.pack(sub_root), OK, "sub-scene packs")
	sub_root.free()
	var owner_root := Node.new()
	owner_root.name = "Outer"

	var response := SceneCommands._batch_instantiate(
			null, owner_root, owner_root, packed, "res://pod.tscn", ".",
			[{"name": "Whole", "properties": {"hp": 102.0}},
				{"name": "Fraction", "properties": {"hp": 102.5}}])
	testing.eq(response.get("count"), 2, "both instances created")
	var whole := owner_root.get_node_or_null("Whole")
	var fraction := owner_root.get_node_or_null("Fraction")
	testing.ok(whole != null and fraction != null, "both instances in the tree")
	if whole != null and fraction != null:
		_expect_int(testing, whole.get("hp"), 102, "whole float 102.0")
		_expect_int(testing, fraction.get("hp"), 102, "102.5 truncated")
	var results: Array = response.get("results", [])
	var whole_row: Dictionary = results[0] if results.size() > 0 else {}
	var fraction_row: Dictionary = results[1] if results.size() > 1 else {}
	testing.ok(not whole_row.has("warnings"), "whole float → no warnings on its row")
	var row_warnings: Array = fraction_row.get("warnings", [])
	testing.eq(row_warnings.size(), 1, "102.5 → exactly one warning on its row")
	_expect_truncation_warning(testing,
			str(row_warnings[0]) if not row_warnings.is_empty() else "", "102", "102.5")

	owner_root.free()
	print("")


static func _test_duplicate_properties(testing) -> void:
	testing.begin("node.manage duplicate properties keeps an int export an int")
	var root := _scene_with_pod()
	var pod := root.get_node("Pod")

	var whole := NodeCommands._manage_duplicate(root, pod, "Pod",
			{"new_name": "Whole", "properties": {"hp": 103.0}})
	testing.ok(bool(whole.get("success", false)), "whole float → success")
	var whole_copy := root.get_node_or_null(str(whole.get("path", "")))
	testing.ok(whole_copy != null, "whole-float copy in the tree")
	if whole_copy != null:
		_expect_int(testing, whole_copy.get("hp"), 103, "whole float 103.0")
	testing.ok(not whole.has("warnings"), "whole float → no warnings")

	var fraction := NodeCommands._manage_duplicate(root, pod, "Pod",
			{"new_name": "Fraction", "properties": {"hp": 103.5}})
	testing.ok(bool(fraction.get("success", false)), "fraction → success")
	var fraction_copy := root.get_node_or_null(str(fraction.get("path", "")))
	testing.ok(fraction_copy != null, "fraction copy in the tree")
	if fraction_copy != null:
		_expect_int(testing, fraction_copy.get("hp"), 103, "103.5 truncated")
	var warnings: Array = fraction.get("warnings", [])
	testing.eq(warnings.size(), 1, "103.5 → exactly one warning")
	_expect_truncation_warning(testing,
			str(warnings[0]) if not warnings.is_empty() else "", "103", "103.5")

	root.free()
	print("")


static func _test_batch_truncation_has_no_shared_note(testing) -> void:
	testing.begin("node.set_property batch truncation adds no shared-resource note")
	var root := _scene_with_pod()
	var server := _server_with_undo_helpers(testing)

	var response := NodeCommands._batch_set_properties(server, root,
			[{"node_path": "Pod", "property": "hp", "value": 104.5}])
	testing.ok(_first_result(response).has("warning"), "104.5 → the entry carries its warning")
	testing.ok(not response.has("warning"),
			"104.5 → no top-level note about shared external sub-resources")

	server.get("undo_helpers").free()
	server.free()
	root.free()
	print("")


static func _test_batch_shared_external_write_keeps_note(testing) -> void:
	testing.begin("node.set_property batch notes a write on a shared external sub-resource")
	var root := Node.new()
	root.name = "Root"
	var sprite := Node2D.new()
	sprite.name = "Sprite"
	var material := CanvasItemMaterial.new()
	# An in-memory path makes the material read as an external file; none is written.
	material.resource_path = "res://shared_note_test.tres"
	sprite.material = material
	root.add_child(sprite)
	var server := _server_with_undo_helpers(testing)

	var response := NodeCommands._batch_set_properties(server, root,
			[{"node_path": "Sprite", "property": "material:blend_mode", "value": 1}])
	testing.ok(str(response.get("warning", "")).contains("material:blend_mode"),
			"the top-level note names material:blend_mode")

	server.get("undo_helpers").free()
	server.free()
	root.free()
	print("")


static func _test_clamp_after_fit_names_requested_value(testing) -> void:
	testing.begin("node.set_property names the requested value when a clamp follows the fit")
	var root := Node.new()
	root.name = "Root"
	var gauge := _node_with_source(testing, "Gauge", root,
			"extends Node\nvar hp: int = 0:\n\tset(value):\n\t\thp = clampi(value, 0, 100)\n")
	var server := _server_with_undo_helpers(testing)

	var single := NodeCommands._set_property_scalar_single(gauge, "Gauge", "hp", 150.5)
	testing.ok(bool(single.get("success", false)), "single 150.5 → success")
	_expect_int(testing, gauge.get("hp"), 100, "single 150.5 clamped")
	_expect_truncation_warning(testing, str(single.get("warning", "")), "100", "150.5")

	var batch := NodeCommands._batch_set_properties(server, root,
			[{"node_path": "Gauge", "property": "hp", "value": 160.5}])
	_expect_int(testing, gauge.get("hp"), 100, "batch 160.5 clamped")
	_expect_truncation_warning(testing,
			str(_first_result(batch).get("warning", "")), "100", "160.5")

	server.get("undo_helpers").free()
	server.free()
	root.free()
	print("")


static func _test_group_header_does_not_hide_int(testing) -> void:
	testing.begin("an @export_group header named like an int export does not hide its type")
	var root := Node.new()
	root.name = "Root"
	# A placeholder lists the group header ahead of the property it groups.
	var mover := _node_with_source(testing, "Mover", root, "\n".join([
		"extends Node",
		"var _values := {&\"speed\": 0}",
		"func _get_property_list() -> Array[Dictionary]:",
		"\treturn [",
		"\t\t{\"name\": \"speed\", \"type\": TYPE_NIL, \"usage\": PROPERTY_USAGE_GROUP},",
		"\t\t{\"name\": \"speed\", \"type\": TYPE_INT, \"usage\": PROPERTY_USAGE_DEFAULT},",
		"\t]",
		"func _set(property: StringName, value: Variant) -> bool:",
		"\tif property == &\"speed\":",
		"\t\t_values[property] = value",
		"\t\treturn true",
		"\treturn false",
		"func _get(property: StringName) -> Variant:",
		"\treturn _values.get(property)",
		"",
	]))

	var response := NodeCommands._set_property_scalar_single(mover, "Mover", "speed", 100.0)
	testing.ok(bool(response.get("success", false)), "whole float → success")
	_expect_int(testing, mover.get("speed"), 100, "whole float 100.0 under a same-named group")

	root.free()
	print("")


# A bare path is a String given where a Resource is expected. The writer refuses
# it, names the tagged form the caller meant and keeps the property's value.
static func _test_set_property_bare_res_path(testing) -> void:
	testing.begin("node.set_property refuses a bare res:// path on a Resource property")
	var sprite := Sprite2D.new()
	var response := NodeCommands._set_property_scalar_single(
			sprite, "Sprite", "texture", TEXTURE_PATH)
	testing.ok(not bool(response.get("success", true)), "bare res:// path → failure")
	testing.eq(str(response.get("code", "")), "INVALID_VALUE", "bare res:// path → INVALID_VALUE")
	testing.eq(str(response.get("error", "")),
			"property 'texture' expects a Resource, not a bare string path. Use "
			+ "{\"type\": \"Resource\", \"path\": \"res://test/fixtures/placeholder_texture.tres\"}"
			+ " as the value.",
			"the error names the tagged form with the same path")
	testing.eq(sprite.texture, null, "the texture is left unset")
	sprite.free()
	print("")


# A uid:// or user:// String is a bare path too. The UID is registered here and
# removed before the assertions.
static func _test_set_property_bare_uid_and_user_paths(testing) -> void:
	testing.begin("node.set_property refuses a bare uid:// or user:// path")
	var sprite := Sprite2D.new()
	var uid := ResourceUID.create_id()
	ResourceUID.add_id(uid, TEXTURE_PATH)
	var by_uid := NodeCommands._set_property_scalar_single(
			sprite, "Sprite", "texture", ResourceUID.id_to_text(uid))
	ResourceUID.remove_id(uid)
	var by_user := NodeCommands._set_property_scalar_single(
			sprite, "Sprite", "texture", "user://icon.tres")

	testing.eq(str(by_uid.get("code", "")), "INVALID_VALUE", "bare uid:// → INVALID_VALUE")
	testing.ok(str(by_uid.get("error", "")).contains(
			"{\"type\": \"Resource\", \"path\": \"%s\"}" % TEXTURE_PATH),
			"the error gives the tagged form with the path the UID names")
	testing.eq(str(by_user.get("code", "")), "INVALID_VALUE", "bare user:// → INVALID_VALUE")
	testing.ok(str(by_user.get("error", "")).contains("only a res:// resource can be bound"),
			"the error refuses the user:// file")
	testing.eq(sprite.texture, null, "the texture is left unset")
	sprite.free()
	print("")


# The editor's placeholder for a script that is not @tool stores a String given for
# a Texture2D export, so a check that reads the value back cannot see the bare path.
static func _test_set_property_bare_path_on_placeholder(testing) -> void:
	testing.begin("node.set_property refuses a bare res:// path on a placeholder")
	var root := _scene_with_pod()
	var pod := root.get_node("Pod")

	var response := NodeCommands._set_property_scalar_single(pod, "Pod", "icon", TEXTURE_PATH)
	testing.eq(str(response.get("code", "")), "INVALID_VALUE", "bare res:// path → INVALID_VALUE")
	testing.eq(pod.get("icon"), null, "the placeholder doesn't store the String")

	root.free()
	print("")


static func _test_batch_bare_path_on_placeholder(testing) -> void:
	testing.begin("node.set_property batch fails a bare res:// path on a placeholder")
	var root := _scene_with_pod()
	var pod := root.get_node("Pod")
	var server := _server_with_undo_helpers(testing)

	var response := NodeCommands._batch_set_properties(server, root, [
		{"node_path": "Pod", "property": "icon", "value": TEXTURE_PATH},
		{"node_path": "Pod", "property": "hp", "value": 7},
	])
	var results: Array = response.get("results", [])
	var icon_entry: Dictionary = results[0] if results.size() > 0 else {}
	var hp_entry: Dictionary = results[1] if results.size() > 1 else {}
	testing.ok(not bool(icon_entry.get("success", true)), "bare res:// path → entry failure")
	testing.ok(str(icon_entry.get("error", "")).contains(
			"{\"type\": \"Resource\", \"path\": \"%s\"}" % TEXTURE_PATH),
			"the entry error names the tagged form with the same path")
	testing.eq(pod.get("icon"), null, "the placeholder doesn't store the String")
	testing.ok(bool(hp_entry.get("success", false)), "the other entry → success")
	_expect_int(testing, pod.get("hp"), 7, "the other entry's 7")

	server.get("undo_helpers").free()
	server.free()
	root.free()
	print("")


# The UID is registered here and removed before the assertions.
static func _test_batch_bare_uid_path(testing) -> void:
	testing.begin("node.set_property batch fails a bare uid:// path")
	var root := _scene_with_pod()
	var pod := root.get_node("Pod")
	var server := _server_with_undo_helpers(testing)
	var uid := ResourceUID.create_id()
	ResourceUID.add_id(uid, TEXTURE_PATH)

	var response := NodeCommands._batch_set_properties(server, root,
			[{"node_path": "Pod", "property": "icon", "value": ResourceUID.id_to_text(uid)}])
	ResourceUID.remove_id(uid)
	var entry := _first_result(response)
	testing.ok(not bool(entry.get("success", true)), "bare uid:// → entry failure")
	testing.ok(str(entry.get("error", "")).contains(
			"{\"type\": \"Resource\", \"path\": \"%s\"}" % TEXTURE_PATH),
			"the entry error gives the tagged form with the path the UID names")
	testing.eq(pod.get("icon"), null, "the placeholder doesn't store the String")

	server.get("undo_helpers").free()
	server.free()
	root.free()
	print("")


static func _test_instantiate_bare_path_on_placeholder(testing) -> void:
	testing.begin("scene.instantiate reports a bare res:// path on a placeholder")
	var owner_root := Node.new()
	owner_root.name = "Outer"

	var response := SceneCommands._batch_instantiate(
			null, owner_root, owner_root, _packed_pod(testing), "res://pod.tscn", ".",
			[{"name": "Bare", "properties": {"icon": TEXTURE_PATH, "hp": 8}}])
	testing.eq(response.get("count"), 1, "the instance is created")
	var results: Array = response.get("results", [])
	var row: Dictionary = results[0] if not results.is_empty() else {}
	var property_errors: Array = row.get("property_errors", [])
	testing.eq(property_errors.size(), 1, "bare res:// path → one property error")
	var error_row: Dictionary = property_errors[0] if not property_errors.is_empty() else {}
	testing.eq(str(error_row.get("property", "")), "icon", "the error row names icon")
	testing.ok(str(error_row.get("error", "")).contains(
			"{\"type\": \"Resource\", \"path\": \"%s\"}" % TEXTURE_PATH),
			"the error names the tagged form with the same path")
	var bare := owner_root.get_node_or_null("Bare")
	testing.ok(bare != null, "the instance is in the tree")
	if bare != null:
		testing.eq(bare.get("icon"), null, "the placeholder doesn't store the String")
		_expect_int(testing, bare.get("hp"), 8, "the other key's 8")

	owner_root.free()
	print("")


static func _test_instantiate_bare_user_path(testing) -> void:
	testing.begin("scene.instantiate reports a bare user:// path")
	var owner_root := Node.new()
	owner_root.name = "Outer"

	var response := SceneCommands._batch_instantiate(
			null, owner_root, owner_root, _packed_pod(testing), "res://pod.tscn", ".",
			[{"name": "Bare", "properties": {"icon": "user://icon.tres"}}])
	var results: Array = response.get("results", [])
	var row: Dictionary = results[0] if not results.is_empty() else {}
	var property_errors: Array = row.get("property_errors", [])
	testing.eq(property_errors.size(), 1, "bare user:// → one property error")
	var error_row: Dictionary = property_errors[0] if not property_errors.is_empty() else {}
	testing.ok(str(error_row.get("error", "")).contains("only a res:// resource can be bound"),
			"the error refuses the user:// file")
	var bare := owner_root.get_node_or_null("Bare")
	testing.ok(bare != null and bare.get("icon") == null,
			"the placeholder doesn't store the String")

	owner_root.free()
	print("")


static func _test_duplicate_bare_path_on_placeholder(testing) -> void:
	testing.begin("node.manage duplicate refuses a bare res:// path on a placeholder")
	var root := _scene_with_pod()
	var pod := root.get_node("Pod")

	var response := NodeCommands._manage_duplicate(root, pod, "Pod",
			{"new_name": "Copy", "properties": {"icon": TEXTURE_PATH}})
	testing.eq(str(response.get("code", "")), "INVALID_PARAMS", "bare res:// path → INVALID_PARAMS")
	testing.ok(str(response.get("error", "")).contains(
			"{\"type\": \"Resource\", \"path\": \"%s\"}" % TEXTURE_PATH),
			"the error names the tagged form with the same path")
	testing.eq(root.get_child_count(), 1, "no copy is added to the parent")
	testing.eq(root.get_node_or_null("Copy"), null, "no node has the copy's name")

	root.free()
	print("")


static func _test_duplicate_bare_user_path(testing) -> void:
	testing.begin("node.manage duplicate refuses a bare user:// path")
	var root := _scene_with_pod()
	var pod := root.get_node("Pod")

	var response := NodeCommands._manage_duplicate(root, pod, "Pod",
			{"new_name": "Copy", "properties": {"icon": "user://icon.tres"}})
	testing.eq(str(response.get("code", "")), "INVALID_PARAMS", "bare user:// → INVALID_PARAMS")
	testing.ok(str(response.get("error", "")).contains("only a res:// resource can be bound"),
			"the error refuses the user:// file")
	testing.eq(root.get_child_count(), 1, "no copy is added to the parent")
	testing.eq(root.get_node_or_null("Copy"), null, "no node has the copy's name")

	root.free()
	print("")


## A child of [param root] named [param node_name] whose script compiles from
## [param source]; [param testing] records the compile.
static func _node_with_source(
		testing, node_name: String, root: Node, source: String) -> Node:
	var script := GDScript.new()
	script.source_code = source
	testing.eq(script.reload(), OK, "%s script compiles" % node_name)
	var node := Node.new()
	node.name = node_name
	node.set_script(script)
	root.add_child(node)
	return node


## A scene root with one child "Pod" that carries the placeholder-like script.
static func _scene_with_pod() -> Node:
	var root := Node.new()
	root.name = "Root"
	var pod := Node.new()
	pod.name = "Pod"
	pod.set_script(PlaceholderLikeNode)
	root.add_child(pod)
	return root


## A packed sub-scene whose root "Pod" carries the placeholder-like script;
## [param testing] records the pack.
static func _packed_pod(testing) -> PackedScene:
	var sub_root := Node.new()
	sub_root.name = "Pod"
	sub_root.set_script(PlaceholderLikeNode)
	var packed := PackedScene.new()
	testing.eq(packed.pack(sub_root), OK, "sub-scene packs")
	sub_root.free()
	return packed


## A stand-in for the editor server: the batch writer records undo through its
## [code]undo_helpers[/code] node.
static func _server_with_undo_helpers(testing) -> Node:
	var server_script := GDScript.new()
	server_script.source_code = "extends Node\nvar undo_helpers: Node = null\n"
	testing.eq(server_script.reload(), OK, "server stand-in script compiles")
	var server := Node.new()
	server.set_script(server_script)
	server.set("undo_helpers", UndoRedoHelpers.new())
	return server


static func _first_result(response: Dictionary) -> Dictionary:
	var results: Array = response.get("results", [])
	return results[0] if not results.is_empty() else {}


static func _expect_int(testing, stored: Variant, expected: int, label: String) -> void:
	testing.eq(typeof(stored), TYPE_INT, "%s on an int property → stored as an int" % label)
	testing.eq(stored, expected, "%s → stores %d" % [label, expected])


static func _expect_truncation_warning(
		testing, warning: String, stored: String, requested: String) -> void:
	testing.ok(warning.contains("'hp'"), "the warning names the property")
	testing.ok(warning.contains("stored %s " % stored), "the warning names the stored %s" % stored)
	testing.ok(warning.contains(requested), "the warning names the requested %s" % requested)
