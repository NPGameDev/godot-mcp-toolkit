@tool
extends RefCounted
## Unit tests for the Windows PATH lookup the Node.js probe runs before it spawns
## anything: which PATH entries are tried, in what order, and in what form. The
## lookup tests answer file_exists from a fake, so they behave the same on every host
## OS; the last group reads the real filesystem through DirAccess. Nothing here
## starts a process.

const NodejsCheck := preload("res://addons/godot_mcp_toolkit/versioning/nodejs_check.gd")


static func run(testing) -> void:
	_test_match_in_middle_entry(testing)
	_test_quoted_and_trailing_separator_entries(testing)
	_test_empty_and_relative_entries_skipped(testing)
	_test_no_match(testing)
	_test_first_match_wins(testing)
	_test_real_directory_access(testing)


# The walk follows PATH order and stops at the first file that exists, so an entry after
# the winner is never probed.
static func _test_match_in_middle_entry(testing) -> void:
	testing.begin("Node.js PATH lookup: match in a middle entry")
	var fake := _FakeFiles.new(["C:/Program Files/nodejs/node.exe"])
	var found := NodejsCheck.resolve_on_path(
			"C:\\Windows\\system32;C:\\Program Files\\nodejs;D:\\Tools", "node.exe", fake.exists)
	testing.eq(found, "C:/Program Files/nodejs/node.exe", "returns the matching entry's node.exe")
	testing.eq(fake.probed, ["C:/Windows/system32/node.exe", "C:/Program Files/nodejs/node.exe"],
			"probes entries in PATH order and stops at the match")
	print("")


# Real PATH values quote entries that contain spaces and often end them with a separator;
# the joined candidate must come out the same either way.
static func _test_quoted_and_trailing_separator_entries(testing) -> void:
	testing.begin("Node.js PATH lookup: quoted and trailing-separator entries")
	var nodejs := "C:/Program Files/nodejs/node.exe"
	testing.eq(_resolve("\"C:\\Program Files\\nodejs\"", [nodejs]), nodejs,
			"surrounding double quotes are dropped")
	testing.eq(_resolve("\"C:\\Program Files\\nodejs\\\"", [nodejs]), nodejs,
			"a trailing backslash inside the quotes is dropped")
	testing.eq(_resolve("C:\\Program Files\\nodejs\\", [nodejs]), nodejs,
			"a trailing backslash is dropped")
	testing.eq(_resolve("C:/Program Files/nodejs/", [nodejs]), nodejs,
			"a trailing forward slash is dropped")
	testing.eq(_resolve("C:\\Tools\\\\", ["C:/Tools/node.exe"]), "C:/Tools/node.exe",
			"repeated trailing separators are all dropped")
	testing.eq(_resolve("C:\\", ["C:/node.exe"]), "C:/node.exe",
			"a drive root joins as C:/node.exe, not C://node.exe")
	testing.eq(_resolve("c:\\tools", ["c:/tools/node.exe"]), "c:/tools/node.exe",
			"a lowercase drive letter is a fixed location")
	testing.eq(
			_resolve("\\\\build\\share\\bin\\", ["//build/share/bin/node.exe"]),
			"//build/share/bin/node.exe",
			"a network share entry is a fixed location")
	print("")


# Each of these resolves against the working directory or the current drive. The editor's
# working directory is the project root, so a node.exe that "exists" through any of them
# must never be picked up, and the lookup must not even ask about it.
static func _test_empty_and_relative_entries_skipped(testing) -> void:
	testing.begin("Node.js PATH lookup: empty and relative entries are never tried")
	var lookalikes := [
		"node.exe",
		"./node.exe",
		".\\node.exe",
		"bin/node.exe",
		"../tools/node.exe",
		"/tools/node.exe",
		"%USERPROFILE%/bin/node.exe",
		"C:tools/node.exe",
	]
	var fake := _FakeFiles.new(lookalikes)
	var relative_path := ";.;;bin;..\\tools;C:tools;\\tools;/tools;%USERPROFILE%\\bin;\"\""
	var found := NodejsCheck.resolve_on_path(relative_path, "node.exe", fake.exists)
	testing.eq(found, "", "no node.exe is found through relative or empty entries")
	testing.eq(fake.probed, [], "relative and empty entries are never even probed")

	var around_fixed := _FakeFiles.new([])
	var around_fixed_result := NodejsCheck.resolve_on_path(
			".;C:\\Windows;;", "node.exe", around_fixed.exists)
	testing.eq(around_fixed_result, "", "relative entries around a fixed one change nothing")
	testing.eq(around_fixed.probed, ["C:/Windows/node.exe"], "only the fixed entry is probed")
	print("")


static func _test_no_match(testing) -> void:
	testing.begin("Node.js PATH lookup: no match")
	var fake := _FakeFiles.new([])
	var found := NodejsCheck.resolve_on_path("C:\\first;C:\\second", "node.exe", fake.exists)
	testing.eq(found, "", "an empty result when no entry holds the file")
	testing.eq(fake.probed, ["C:/first/node.exe", "C:/second/node.exe"],
			"every entry is tried before giving up")

	var empty_path_fake := _FakeFiles.new([])
	var empty_path_result := NodejsCheck.resolve_on_path("", "node.exe", empty_path_fake.exists)
	testing.eq(empty_path_result, "", "an empty PATH resolves nothing")
	testing.eq(empty_path_fake.probed, [], "an empty PATH probes nothing")
	print("")


static func _test_first_match_wins(testing) -> void:
	testing.begin("Node.js PATH lookup: first match wins")
	# The set lists the later entry first, so only PATH order can explain the result.
	var fake := _FakeFiles.new(["C:/second/node.exe", "C:/first/node.exe"])
	var found := NodejsCheck.resolve_on_path("C:\\first;C:\\second", "node.exe", fake.exists)
	testing.eq(found, "C:/first/node.exe", "the earlier PATH entry wins")
	testing.eq(fake.probed, ["C:/first/node.exe"], "later entries are not probed once one matches")
	print("")


# The Windows probe relies on DirAccess.file_exists answering an absolute path as written
# and not counting a directory as a file. This checks that contract on the host's own
# DirAccess, so it covers the probe's implementation only when the suite runs on Windows.
static func _test_real_directory_access(testing) -> void:
	testing.begin("Node.js PATH lookup: DirAccess answers for absolute paths")
	var files := DirAccess.open(OS.get_executable_path().get_base_dir())
	testing.ok(files != null, "a DirAccess opens on the editor's own folder")
	if files == null:
		print("")
		return
	var project_file := ProjectSettings.globalize_path("res://project.godot")
	testing.ok(files.file_exists(project_file), "an existing file is found by its absolute path")
	testing.ok(not files.file_exists(project_file + ".missing"), "a missing file is not found")
	testing.ok(not files.file_exists(project_file.get_base_dir()),
			"a directory does not count as a file")
	print("")


# Resolves node.exe over path_variable, treating only the paths in present as existing files.
static func _resolve(path_variable: String, present: Array) -> String:
	var fake := _FakeFiles.new(present)
	return NodejsCheck.resolve_on_path(path_variable, "node.exe", fake.exists)


# Answers file_exists from a fixed set and records every candidate it was asked about.
class _FakeFiles extends RefCounted:
	var present: Array
	var probed := []

	func _init(present_paths: Array) -> void:
		present = present_paths

	func exists(path: String) -> bool:
		probed.append(path)
		return present.has(path)
