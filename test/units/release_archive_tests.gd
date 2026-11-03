@tool
extends RefCounted
## Unit tests for the release zip's layout check, on zips built in the run: a good
## release, each forbidden entry, a missing or mismatched plugin.cfg, an unreadable
## file, and reading an addon file back.

const ReleaseArchive := preload("res://addons/godot_mcp_toolkit/update/release_archive.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")


static func run(testing) -> void:
	_test_good_release(testing)
	_test_entry_rules(testing)
	_test_plugin_config(testing)
	_test_read_file(testing)


static func _inspect(name: String, entries: Dictionary, version: String = "1.2.0") -> Dictionary:
	var folder := UpdateFixtures.scratch("archive_" + name)
	var path := folder.path_join("release.zip")
	UpdateFixtures.write_zip(path, entries)
	var result := ReleaseArchive.inspect(path, version)
	UpdateFixtures.remove(folder)
	return result


static func _test_good_release(testing) -> void:
	testing.begin("Release archive: a good release")
	var result := _inspect("good", UpdateFixtures.release_entries("1.2.0", {"plugin.gd": "@tool", "core/a.gd": "@tool"}))
	testing.eq(str(result["error"]), "", "no problem")
	var files: PackedStringArray = result["files"]
	var sorted := Array(files)
	sorted.sort()
	testing.eq(sorted, ["core/a.gd", "plugin.cfg", "plugin.gd", "release_files.sha256"],
			"its files, relative to the addon folder, directories left out")
	print("")


static func _test_entry_rules(testing) -> void:
	testing.begin("Release archive: entries outside the addon folder")
	testing.eq(ReleaseArchive.entry_problem("addons/"), "", "the addons directory → allowed")
	testing.eq(ReleaseArchive.entry_problem("addons/godot_mcp_toolkit/core/a.gd"), "", "a file in the addon folder → allowed")
	testing.eq(ReleaseArchive.entry_problem("addons/other/a.gd"),
			"the archive holds a path outside the addon folder: addons/other/a.gd", "another addon → refused")
	testing.eq(ReleaseArchive.entry_problem("project.godot"),
			"the archive holds a path outside the addon folder: project.godot", "a project file → refused")
	testing.eq(ReleaseArchive.entry_problem("/etc/passwd"),
			"the archive holds an absolute or malformed path: /etc/passwd", "an absolute path → refused")
	testing.eq(ReleaseArchive.entry_problem("C:/a.gd"),
			"the archive holds an absolute or malformed path: C:/a.gd", "a drive letter → refused")
	testing.eq(ReleaseArchive.entry_problem("addons\\godot_mcp_toolkit\\a.gd"),
			"the archive holds an absolute or malformed path: addons\\godot_mcp_toolkit\\a.gd", "backslashes → refused")
	testing.eq(ReleaseArchive.entry_problem("addons/godot_mcp_toolkit/../../project.godot"),
			"the archive holds a path with an empty, . or .. segment: addons/godot_mcp_toolkit/../../project.godot",
			"a .. segment → refused")
	testing.eq(ReleaseArchive.entry_problem("addons/godot_mcp_toolkit//a.gd"),
			"the archive holds a path with an empty, . or .. segment: addons/godot_mcp_toolkit//a.gd",
			"an empty segment → refused")
	var entries := UpdateFixtures.release_entries("1.2.0", {})
	entries["addons/godot_mcp_toolkit/../evil.gd"] = "x"
	testing.ok(str(_inspect("dotdot", entries)["error"]).begins_with(
			"the archive holds a path with an empty, . or .. segment: addons/godot_mcp_toolkit/.."),
			"a zip holding a .. entry → refused whole")
	print("")


static func _test_plugin_config(testing) -> void:
	testing.begin("Release archive: the plugin.cfg it carries")
	var entries := UpdateFixtures.release_entries("1.2.0", {})
	entries.erase("addons/godot_mcp_toolkit/plugin.cfg")
	testing.eq(str(_inspect("no_config", entries)["error"]), "the archive has no plugin.cfg", "no plugin.cfg → refused")
	testing.eq(str(_inspect("other_version", UpdateFixtures.release_entries("1.2.1", {}))["error"]),
			"the archive's plugin.cfg names version 1.2.1, not 1.2.0", "another version → refused")
	var folder := UpdateFixtures.scratch("archive_not_zip")
	var path := ProjectSettings.globalize_path(folder).path_join("release.zip")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("not a zip")
	file.close()
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var not_zip := ReleaseArchive.inspect(path, "1.2.0")
	Engine.print_error_messages = printed
	UpdateFixtures.remove(folder)
	testing.eq(str(not_zip["error"]), "the archive is not a readable zip", "a file that is not a zip → refused")
	print("")


static func _test_read_file(testing) -> void:
	testing.begin("Release archive: reading an addon file")
	var folder := UpdateFixtures.scratch("archive_read")
	var path := folder.path_join("release.zip")
	UpdateFixtures.write_zip(path, UpdateFixtures.release_entries("1.2.0", {"core/a.gd": "content of a"}))
	var reader := ZIPReader.new()
	reader.open(path)
	var text := ReleaseArchive.read_file(reader, "core/a.gd").get_string_from_utf8()
	reader.close()
	UpdateFixtures.remove(folder)
	testing.eq(text, "content of a", "a path relative to the addon folder → its bytes")
	print("")
