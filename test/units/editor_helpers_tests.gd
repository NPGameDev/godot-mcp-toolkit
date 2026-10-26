@tool
extends RefCounted
## CommandHelpers.bare_path_message on its own: the message for each kind of bare
## path a String gives where a Resource is expected, and no message for a value that
## is not one. The writers' tests check that each writer routes the message.

const Helpers := preload("res://addons/godot_mcp_toolkit/commands/editor_helpers.gd")
const TEXTURE_PATH := "res://test/fixtures/placeholder_texture.tres"


static func run(testing) -> void:
	_test_bare_res_path(testing)
	_test_bare_known_uid(testing)
	_test_bare_unknown_uid(testing)
	_test_bare_user_path(testing)
	_test_not_a_bare_path(testing)


static func _test_bare_res_path(testing) -> void:
	testing.begin("bare_path_message names the tagged form for a res:// path")
	testing.eq(Helpers.bare_path_message("icon", TEXTURE_PATH, TYPE_OBJECT),
			"property 'icon' expects a Resource, not a bare string path. Use "
			+ "{\"type\": \"Resource\", \"path\": \"res://test/fixtures/placeholder_texture.tres\"}"
			+ " as the value",
			"res:// path → the tagged form with the same path")
	print("")


# The UID is registered here and removed before the assertions, so the case does not
# depend on the project's UID cache.
static func _test_bare_known_uid(testing) -> void:
	testing.begin("bare_path_message names the tagged form with the path a uid:// names")
	var uid := ResourceUID.create_id()
	ResourceUID.add_id(uid, TEXTURE_PATH)
	var uid_text := ResourceUID.id_to_text(uid)
	var message := Helpers.bare_path_message("icon", uid_text, TYPE_OBJECT)
	ResourceUID.remove_id(uid)
	testing.eq(message,
			"property 'icon' expects a Resource, not a bare string path. Use "
			+ "{\"type\": \"Resource\", \"path\": \"res://test/fixtures/placeholder_texture.tres\"}"
			+ " as the value",
			"known uid:// → the tagged form with the res:// path it names")
	print("")


static func _test_bare_unknown_uid(testing) -> void:
	testing.begin("bare_path_message says no resource has an unknown uid://")
	var uid_text := ResourceUID.id_to_text(ResourceUID.create_id())
	testing.eq(Helpers.bare_path_message("icon", uid_text, TYPE_OBJECT),
			"property 'icon' expects a Resource, not a bare string path, and no resource "
			+ "has the UID %s" % uid_text,
			"unregistered uid:// → no resource has that UID")
	testing.eq(Helpers.bare_path_message("icon", "uid://", TYPE_OBJECT),
			"property 'icon' expects a Resource, not a bare string path, and no resource "
			+ "has the UID uid://",
			"malformed uid:// → no resource has that UID")
	print("")


static func _test_bare_user_path(testing) -> void:
	testing.begin("bare_path_message refuses a user:// path")
	testing.eq(Helpers.bare_path_message("icon", "user://icon.tres", TYPE_OBJECT),
			"property 'icon' expects a Resource, not a bare string path, and only a res:// "
			+ "resource can be bound, not a user:// file",
			"user:// path → only a res:// resource can be bound")
	print("")


# A String property may hold a path (an @export_file); only an Object property makes a
# String a bare path.
static func _test_not_a_bare_path(testing) -> void:
	testing.begin("bare_path_message gives no message for a value that is not a bare path")
	testing.eq(Helpers.bare_path_message("icon_path", TEXTURE_PATH, TYPE_STRING), "",
			"res:// path on a String property → no message")
	testing.eq(Helpers.bare_path_message("icon", {"type": "Resource", "path": TEXTURE_PATH},
			TYPE_OBJECT), "", "the tagged form → no message")
	testing.eq(Helpers.bare_path_message("icon", "icons/a.png", TYPE_OBJECT), "",
			"a String with no res://, uid:// or user:// prefix → no message")
	print("")
