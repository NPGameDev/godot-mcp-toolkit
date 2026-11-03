@tool
extends RefCounted
## Unit tests for the release zip's layout check, on zips built in the run: a good
## release, each forbidden entry and name, the entry cap, collisions, folder entries, the
## file list it must equal, a missing or mismatched plugin.cfg, and reading an addon file back.

const Testing := preload("res://test/units/testing.gd")
const ReleaseArchive := preload("res://addons/godot_mcp_toolkit/self_update/release_archive.gd")
const ReleaseFileList := preload("res://addons/godot_mcp_toolkit/self_update/release_file_list.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

const _ADDON_ENTRY := "addons/godot_mcp_toolkit/"
const _NO_LIST := "the staged archive has no file list this version can read"


static func run(testing: Testing) -> void:
	_test_good_release(testing)
	_test_entry_rules(testing)
	_test_refused_names(testing)
	_test_legal_names(testing)
	_test_entry_cap(testing)
	_test_entry_cap_counts_folders(testing)
	_test_collisions(testing)
	_test_folder_entries(testing)
	_test_list_must_equal_entries(testing)
	_test_plugin_config(testing)
	_test_read_file(testing)


static func _inspect(name: String, entries: Dictionary, version: String = "1.2.0") -> Dictionary:
	var folder := UpdateFixtures.scratch("archive_" + name)
	var path := folder.path_join("release.zip")
	UpdateFixtures.write_zip(path, entries)
	var result := ReleaseArchive.inspect(path, version)
	UpdateFixtures.remove(folder)
	return result


# The fixture's zip of `entries`, then an empty entry per name in `repeated`.
static func _inspect_repeating(name: String, entries: Dictionary, repeated: PackedStringArray) -> Dictionary:
	var folder := UpdateFixtures.scratch("archive_" + name)
	var path := folder.path_join("release.zip")
	UpdateFixtures.write_zip(path, entries, repeated)
	var result := ReleaseArchive.inspect(path, "1.2.0")
	UpdateFixtures.remove(folder)
	return result


# A zip holding `extra` after a good release's entries, for what a dictionary cannot hold.
static func _inspect_with_extra(name: String, extra: PackedStringArray) -> Dictionary:
	var folder := UpdateFixtures.scratch("archive_" + name)
	var path := folder.path_join("release.zip")
	var entries := UpdateFixtures.release_entries("1.2.0", {"core/a.gd": "a"})
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var packer := ZIPPacker.new()
	packer.open(path)
	for entry: String in entries:
		packer.start_file(entry)
		packer.write_file(str(entries[entry]).to_utf8_buffer())
		packer.close_file()
	for entry: String in extra:
		packer.start_file(entry)
		packer.close_file()
	packer.close()
	var result := ReleaseArchive.inspect(path, "1.2.0")
	UpdateFixtures.remove(folder)
	return result


static func _test_good_release(testing: Testing) -> void:
	testing.begin("Release archive: a good release")
	var entries := UpdateFixtures.release_entries("1.2.0", {"plugin.gd": "@tool", "core/a.gd": "@tool"})
	var result := _inspect("good", entries)
	testing.eq(str(result["error"]), "", "no problem")
	var files: PackedStringArray = result["files"]
	var sorted := Array(files)
	sorted.sort()
	testing.eq(sorted, ["core/a.gd", "plugin.cfg", "plugin.gd", "release_files.sha256"],
			"its files, relative to the addon folder, directories left out")
	var list_bytes: PackedByteArray = result["list"]
	testing.eq(list_bytes.get_string_from_utf8(), str(entries[_ADDON_ENTRY + ReleaseFileList.FILE_NAME]),
			"the list's bytes come back with them")
	print("")


static func _test_entry_rules(testing: Testing) -> void:
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


static func _test_refused_names(testing: Testing) -> void:
	testing.begin("Release archive: names that are refused")
	var alias := "the archive holds a name Windows would change or refuse: "
	var cases := {
		"core/a.gd.": alias,
		"core/a.gd ": alias,
		"core./a.gd": alias,
		"core /a.gd": alias,
		"core/GIT~1": alias,
		"core/PROJEC~1.GOD": alias,
		"v2~1/a.gd": alias,
		"core/a~b~2.gd": alias,
		"CON": alias,
		"core/con": alias,
		"core/nul.gd": alias,
		"core/Aux.tar.gz": alias,
		"core/PRN .gd": alias,
		"com1/a.gd": alias,
		"core/COM9.gd": alias,
		"core/com¹.gd": alias,
		"core/LPT0": alias,
		"core/lpt³.gd": alias,
		".gdignore": "the archive holds an ignore file at the addon root: ",
		".gitignore": "the archive holds an ignore file at the addon root: ",
		".p4ignore": "the archive holds an ignore file at the addon root: ",
		".GDIgnore": "the archive holds an ignore file at the addon root: ",
		"project.godot": "the archive holds a project.godot: ",
		"core/project.godot": "the archive holds a project.godot: ",
		"CompanionSkills/deep/down/PROJECT.GODOT": "the archive holds a project.godot: ",
	}
	for name: String in cases:
		var entry := _ADDON_ENTRY + name
		testing.eq(ReleaseArchive.entry_problem(entry), str(cases[name]) + entry, "%s → refused" % name)
	var entries := UpdateFixtures.release_entries("1.2.0", {})
	entries[_ADDON_ENTRY + ".gdignore"] = ""
	testing.eq(str(_inspect("root_gdignore", entries)["error"]),
			"the archive holds an ignore file at the addon root: addons/godot_mcp_toolkit/.gdignore",
			"a zip holding a refused name → refused whole")
	print("")


static func _test_legal_names(testing: Testing) -> void:
	testing.begin("Release archive: names that look close and are fine")
	for name: String in ["CompanionSkills/.gdignore", "docs/.gitignore", "docs/.p4ignore", "core/console.gd", "core/com1x.gd",
			"core/com10.gd", "core/lpt.gd", "core/a~b.gd", "core/~.gd", "core/project.godot.txt", "core/a b.gd", "core/.hidden"]:
		testing.eq(ReleaseArchive.entry_problem(_ADDON_ENTRY + name), "", "%s → allowed" % name)
	print("")


# Two directory entries come with every zip the fixture writes, so these totals are exact.
static func _test_entry_cap(testing: Testing) -> void:
	testing.begin("Release archive: the entry cap")
	testing.eq(ReleaseArchive.MAX_ENTRIES, 5000, "5000 entries")
	var at_cap := {}
	for index: int in 4996:
		at_cap["f%d.gd" % index] = ""
	var at_cap_result := _inspect("at_cap", UpdateFixtures.release_entries("1.2.0", at_cap))
	testing.eq(str(at_cap_result["error"]), "", "exactly 5000 entries → allowed")
	var at_cap_files: PackedStringArray = at_cap_result.get("files", PackedStringArray())
	testing.eq(at_cap_files.size(), 4998, "… every file read")
	at_cap["one_more.gd"] = ""
	var over := UpdateFixtures.release_entries("1.2.0", at_cap)
	over.erase(_ADDON_ENTRY + "plugin.cfg")
	over[_ADDON_ENTRY + "one_more_again.gd"] = ""
	testing.eq(str(_inspect("over_cap", over)["error"]), "the archive holds 5001 entries, more than 5000",
			"5001 entries → refused, before the missing plugin.cfg is read")
	print("")


# A folder entry may repeat, so the cap is all that bounds how many a zip holds. The files
# sit in the addon folder and "addons/" repeats, so these totals are exact on every version.
static func _test_entry_cap_counts_folders(testing: Testing) -> void:
	testing.begin("Release archive: a folder entry counts toward the cap")
	var files := {}
	for index: int in 4995:
		files["f%d.gd" % index] = ""
	var at_cap := _inspect_repeating("folders_at_cap", UpdateFixtures.release_entries("1.2.0", files),
			PackedStringArray(["addons/"]))
	testing.eq(str(at_cap["error"]), "", "4997 files and 3 folder entries, one of them twice → allowed")
	files["one_more.gd"] = ""
	var over := _inspect_repeating("folders_over_cap", UpdateFixtures.release_entries("1.2.0", files),
			PackedStringArray(["addons/"]))
	testing.eq(str(over["error"]), "the archive holds 5001 entries, more than 5000",
			"4998 files and 3 folder entries, one of them twice → refused")
	print("")


static func _test_collisions(testing: Testing) -> void:
	testing.begin("Release archive: names that collide")
	testing.eq(str(_inspect_with_extra("twice", PackedStringArray([_ADDON_ENTRY + "core/a.gd"]))["error"]),
			"the archive holds an entry twice: addons/godot_mcp_toolkit/core/a.gd", "the same name twice → refused")
	testing.eq(str(_inspect_with_extra("case_file", PackedStringArray([_ADDON_ENTRY + "core/A.gd"]))["error"]),
			"the archive holds names that differ only in letter case: addons/godot_mcp_toolkit/core/a.gd, addons/godot_mcp_toolkit/core/A.gd",
			"a file differing only in case → refused")
	testing.eq(str(_inspect_with_extra("case_folder", PackedStringArray([_ADDON_ENTRY + "CORE/b.gd"]))["error"]),
			"the archive holds names that differ only in letter case: addons/godot_mcp_toolkit/core, addons/godot_mcp_toolkit/CORE",
			"a folder differing only in case → refused")
	testing.eq(str(_inspect_with_extra("directory", PackedStringArray([_ADDON_ENTRY + "core/"]))["error"]), "",
			"a folder's own entry beside its files → allowed")
	print("")


# The build's `zip -r` writes one entry per folder, its .NET twin none, and a packer may
# write one twice: the release is its files, whichever of these a zip holds.
static func _test_folder_entries(testing: Testing) -> void:
	testing.begin("Release archive: folder entries")
	var core_folder := _ADDON_ENTRY + "core/"
	var core_file := _ADDON_ENTRY + "core/a.gd"
	var entries := UpdateFixtures.release_entries("1.2.0", {"core/a.gd": "a"})
	testing.eq(str(_inspect_with_extra("folders_none", PackedStringArray())["error"]), "",
			"a zip packed from its files alone → allowed")
	var twice := _inspect_repeating("folders_twice", entries,
			PackedStringArray(["addons/", _ADDON_ENTRY, core_folder, core_folder]))
	testing.eq(str(twice["error"]), "", "each folder entry again → allowed")
	var twice_files: PackedStringArray = twice.get("files", PackedStringArray())
	var sorted := Array(twice_files)
	sorted.sort()
	testing.eq(sorted, ["core/a.gd", "plugin.cfg", "release_files.sha256"], "… and none of them reads as a file")
	testing.eq(str(_inspect_repeating("folder_and_file_twice", entries,
			PackedStringArray(["addons/", core_file]))["error"]),
			"the archive holds an entry twice: addons/godot_mcp_toolkit/core/a.gd",
			"a file twice beside a folder twice → refused")
	testing.eq(str(_inspect_repeating("folder_case", entries,
			PackedStringArray([_ADDON_ENTRY + "CORE/", _ADDON_ENTRY + "CORE/"]))["error"]),
			"the archive holds names that differ only in letter case: addons/godot_mcp_toolkit/core, addons/godot_mcp_toolkit/CORE",
			"a folder entry differing only in case → refused")
	testing.eq(str(_inspect_repeating("folder_outside", entries,
			PackedStringArray(["addons/other/", "addons/other/"]))["error"]),
			"the archive holds a path outside the addon folder: addons/other/",
			"a folder entry outside the addon folder → refused")
	var listing_folder := entries.duplicate()
	var list_entry := _ADDON_ENTRY + ReleaseFileList.FILE_NAME
	listing_folder[list_entry] = str(listing_folder[list_entry]) + "%s  core/\n" % "0".repeat(64)
	testing.eq(str(_inspect_repeating("list_folder", listing_folder, PackedStringArray([core_folder]))["error"]),
			"the archive's file list names core/, which it does not hold",
			"a list naming a folder the zip holds an entry for → refused")
	print("")


static func _test_list_must_equal_entries(testing: Testing) -> void:
	testing.begin("Release archive: the entries must equal the list")
	var list_entry := _ADDON_ENTRY + ReleaseFileList.FILE_NAME
	var unlisted := UpdateFixtures.release_entries("1.2.0", {"core/a.gd": "a"})
	unlisted[_ADDON_ENTRY + "extra.gd"] = "extra"
	testing.eq(str(_inspect("list_unlisted", unlisted)["error"]),
			"the archive holds extra.gd, which its file list does not name", "a file the list does not name → refused")
	var missing := UpdateFixtures.release_entries("1.2.0", {"core/a.gd": "a"})
	missing.erase(_ADDON_ENTRY + "core/a.gd")
	testing.eq(str(_inspect("list_missing", missing)["error"]),
			"the archive's file list names core/a.gd, which it does not hold", "a listed file it does not hold → refused")
	var other_case := UpdateFixtures.release_entries("1.2.0", {"core/a.gd": "a"})
	other_case[_ADDON_ENTRY + "core/A.gd"] = other_case[_ADDON_ENTRY + "core/a.gd"]
	other_case.erase(_ADDON_ENTRY + "core/a.gd")
	testing.eq(str(_inspect("list_case", other_case)["error"]),
			"the archive holds core/A.gd, which its file list does not name", "a file listed in another case → refused")
	var no_list := UpdateFixtures.release_entries("1.2.0", {"core/a.gd": "a"})
	no_list.erase(list_entry)
	testing.eq(str(_inspect("list_none", no_list)["error"]), _NO_LIST, "no list → refused")
	var damaged := UpdateFixtures.release_entries("1.2.0", {"core/a.gd": "a"})
	damaged[list_entry] = "not a list\n"
	testing.eq(str(_inspect("list_damaged", damaged)["error"]), _NO_LIST, "a damaged list → refused")
	var empty := UpdateFixtures.release_entries("1.2.0", {"core/a.gd": "a"})
	empty[list_entry] = ""
	testing.eq(str(_inspect("list_empty", empty)["error"]), _NO_LIST, "an empty list → refused")
	var names_itself := UpdateFixtures.release_entries("1.2.0", {"core/a.gd": "a"})
	names_itself[list_entry] = str(names_itself[list_entry]) + "%s  %s\n" % ["0".repeat(64), ReleaseFileList.FILE_NAME]
	testing.eq(str(_inspect("list_itself", names_itself)["error"]),
			"the archive's file list names release_files.sha256, which it does not hold", "a list naming itself → refused")
	print("")


static func _test_plugin_config(testing: Testing) -> void:
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


static func _test_read_file(testing: Testing) -> void:
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
