@tool
extends RefCounted
## Unit tests for the pending update record: its round trip, the defaults of a
## missing, broken or newer-format record, clearing with and without the backup, the
## folder paths and the install log.

const PendingUpdate := preload("res://addons/godot_mcp_toolkit/update/pending_update.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")


static func run(testing) -> void:
	_test_round_trip(testing)
	_test_defaults(testing)
	_test_clear(testing)
	_test_paths_and_log(testing)


static func _empty() -> Dictionary:
	return {"state": "", "version": "", "from_version": "", "compatible_server": "", "reason": "",
			"changed_files": PackedStringArray()}


static func _write_text(folder: String, text: String) -> void:
	var path := ProjectSettings.globalize_path(folder).path_join("pending_update.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


static func _test_round_trip(testing) -> void:
	testing.begin("Pending update: the record round trip")
	var folder := UpdateFixtures.scratch("pending_round_trip")
	PendingUpdate.write({"state": "staged", "version": "1.2.0", "from_version": "1.1.0",
			"compatible_server": "1.1.0", "changed_files": PackedStringArray(["core/a.gd"])}, folder)
	var record := PendingUpdate.read(folder)
	UpdateFixtures.remove(folder)
	testing.eq(record, {"state": "staged", "version": "1.2.0", "from_version": "1.1.0", "compatible_server": "1.1.0",
			"reason": "", "changed_files": PackedStringArray(["core/a.gd"])}, "every field back, a missing one empty")
	print("")


static func _test_defaults(testing) -> void:
	testing.begin("Pending update: missing, broken and newer records")
	var folder := UpdateFixtures.scratch("pending_defaults")
	var missing := PendingUpdate.read(folder)
	_write_text(folder, "{broken")
	var broken := PendingUpdate.read(folder)
	_write_text(folder, JSON.stringify({"format": 2, "state": "staged", "version": "9.0.0"}))
	var newer := PendingUpdate.read(folder)
	_write_text(folder, JSON.stringify({"format": 1, "state": 3, "version": "1.2.0", "changed_files": ["a", 4]}))
	var mistyped := PendingUpdate.read(folder)
	UpdateFixtures.remove(folder)
	testing.eq(missing, _empty(), "no record → every field empty")
	testing.eq(broken, _empty(), "broken JSON → every field empty")
	testing.eq(newer, _empty(), "a newer format → every field empty")
	var expected := _empty()
	expected["version"] = "1.2.0"
	expected["changed_files"] = PackedStringArray(["a"])
	testing.eq(mistyped, expected, "a field of the wrong type → empty, the others kept")
	print("")


static func _test_clear(testing) -> void:
	testing.begin("Pending update: clearing")
	var folder := UpdateFixtures.scratch("pending_clear")
	var absolute := ProjectSettings.globalize_path(folder)
	PendingUpdate.write({"state": "staged", "version": "1.2.0"}, folder)
	PendingUpdate.log_line("kept", folder)
	DirAccess.make_dir_recursive_absolute(absolute.path_join("1.2.0"))
	DirAccess.make_dir_recursive_absolute(absolute.path_join("backup/core"))
	PendingUpdate.clear(folder, true)
	var backup_kept := DirAccess.dir_exists_absolute(absolute.path_join("backup/core"))
	var version_gone := not DirAccess.dir_exists_absolute(absolute.path_join("1.2.0"))
	var record_gone: bool = PendingUpdate.read(folder)["state"] == ""
	PendingUpdate.clear(folder)
	var backup_gone := not DirAccess.dir_exists_absolute(absolute.path_join("backup"))
	var log_kept := FileAccess.file_exists(absolute.path_join("install.log"))
	UpdateFixtures.remove(folder)
	testing.ok(record_gone, "the record → deleted")
	testing.ok(version_gone, "a version folder → deleted")
	testing.ok(backup_kept, "keep_backup → the backup stays")
	testing.ok(backup_gone, "without keep_backup → the backup goes")
	testing.ok(log_kept, "the install log → kept")
	print("")


static func _test_paths_and_log(testing) -> void:
	testing.begin("Pending update: folders and the install log")
	testing.eq(PendingUpdate.version_folder("1.2.0"), "user://addons/godot_mcp_toolkit/update/1.2.0", "a version's folder")
	testing.eq(PendingUpdate.backup_folder(), "user://addons/godot_mcp_toolkit/update/backup", "the backup folder")
	var folder := UpdateFixtures.scratch("pending_log")
	PendingUpdate.log_line("first", folder)
	PendingUpdate.log_line("second", folder)
	var lines := FileAccess.get_file_as_string(PendingUpdate.log_path(folder)).strip_edges().split("\n")
	UpdateFixtures.remove(folder)
	testing.eq(lines.size(), 2, "each call → one line")
	testing.ok(lines[0].ends_with(" first") and lines[1].ends_with(" second"), "appended in order, after a timestamp")
	print("")
