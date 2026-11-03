@tool
extends RefCounted
## Unit tests for the release file list: its sha256sum-format text, read and written,
## the damaged lists it refuses whole, and reading an installed folder's list.

const ReleaseFileList := preload("res://addons/godot_mcp_toolkit/update/release_file_list.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

const _A := "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
const _B := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"


static func run(testing) -> void:
	_test_format(testing)
	_test_parse(testing)
	_test_damaged(testing)
	_test_installed(testing)


static func _test_format(testing) -> void:
	testing.begin("Release file list: the text it writes")
	testing.eq(ReleaseFileList.format({"plugin.gd": _A, "core/a.gd": _B}),
			_B + "  core/a.gd\n" + _A + "  plugin.gd\n", "one sha256sum line per file, sorted by path")
	testing.eq(ReleaseFileList.format({}), "", "no files → empty text")
	print("")


static func _test_parse(testing) -> void:
	testing.begin("Release file list: reading it")
	testing.eq(ReleaseFileList.parse(_B + "  core/a.gd\n" + _A + "  plugin.gd\n"), {"core/a.gd": _B, "plugin.gd": _A},
			"each line → path to SHA-256")
	testing.eq(ReleaseFileList.parse("\n" + _A + "  plugin.gd\r\n\n"), {"plugin.gd": _A},
			"blank lines and CRLF endings → skipped")
	testing.eq(ReleaseFileList.parse(_A + "  docs/a file.md\n"), {"docs/a file.md": _A}, "a path with a space → kept whole")
	print("")


static func _test_damaged(testing) -> void:
	testing.begin("Release file list: a damaged list is refused whole")
	testing.eq(ReleaseFileList.parse(_A + "  plugin.gd\n" + _B + " core/a.gd\n"), {}, "one space before the path → empty")
	testing.eq(ReleaseFileList.parse(_A.to_upper() + "  plugin.gd\n"), {}, "an uppercase digest → empty")
	testing.eq(ReleaseFileList.parse(_A + "  \n"), {}, "no path → empty")
	testing.eq(ReleaseFileList.parse(_A + "  ../project.godot\n"), {}, "a .. path → empty")
	testing.eq(ReleaseFileList.parse(_A + "  /etc/passwd\n"), {}, "an absolute path → empty")
	print("")


static func _test_installed(testing) -> void:
	testing.begin("Release file list: an installed folder's list")
	var folder := UpdateFixtures.scratch("file_list")
	UpdateFixtures.make_addon(folder, "1.1.0", {"core/a.gd": "abc"})
	var listed := ReleaseFileList.read_installed(ProjectSettings.globalize_path(folder))
	var missing := ReleaseFileList.read_installed(ProjectSettings.globalize_path(folder).path_join("nowhere"))
	UpdateFixtures.remove(folder)
	testing.eq(listed.get("core/a.gd", ""), _A, "a listed file → its SHA-256")
	testing.ok(not listed.has(ReleaseFileList.FILE_NAME), "the list leaves itself out")
	testing.eq(missing, {}, "a folder without a list → empty")
	print("")
