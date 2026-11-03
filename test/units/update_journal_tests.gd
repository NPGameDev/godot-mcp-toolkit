@tool
extends RefCounted
## Unit tests for the update journal: its round trip, the journal 1.2.0 writes, what reads
## as no journal, a field of the wrong type, a write that cannot happen, and clearing.

const Testing := preload("res://test/units/testing.gd")
const UpdateJournal := preload("res://addons/godot_mcp_toolkit/self_update/update_journal.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

# The journal the 1.2.0 toolkit writes. 1.2.0's code stays on users' machines and writes
# this for a later release to read, so this text never changes: if a test against it
# fails, the change that broke it needs a bridge release.
const _PINNED_1_2_0_JOURNAL := """{
	"attempts": 2,
	"backup": "backup-1.1.0",
	"changed_files": [
		"core/a.gd"
	],
	"compatible_server": "1.1.0",
	"expected_tree_hash": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
	"format": 1,
	"from": "1.1.0",
	"reason": "a held file",
	"state": "staged",
	"to": "1.2.0"
}"""


static func run(testing: Testing) -> void:
	_test_round_trip(testing)
	_test_pinned_journal(testing)
	_test_states(testing)
	_test_defaults(testing)
	_test_bad_versions(testing)
	_test_unknown_state(testing)
	_test_mistyped_fields(testing)
	_test_unknown_keys(testing)
	_test_write_that_fails(testing)
	_test_clear(testing)


static func _empty() -> Dictionary:
	return {"state": "", "from": "", "to": "", "backup": "", "expected_tree_hash": "",
			"compatible_server": "", "reason": "", "attempts": 0, "changed_files": PackedStringArray()}


static func _write_text(folder: String, text: String) -> void:
	var path := ProjectSettings.globalize_path(folder).path_join("journal.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


# What a journal reads as, given its fields as JSON, in a folder of its own.
static func _read_fields(purpose: String, fields: Dictionary) -> Dictionary:
	var folder := UpdateFixtures.scratch(purpose)
	_write_text(folder, JSON.stringify(fields))
	var record := UpdateJournal.read(folder)
	UpdateFixtures.remove(folder)
	return record


static func _test_round_trip(testing: Testing) -> void:
	testing.begin("Update journal: the round trip")
	var folder := UpdateFixtures.scratch("journal_round_trip")
	var full := {"state": "applying", "from": "1.1.0", "to": "1.2.0", "backup": "backup-1.1.0",
			"expected_tree_hash": "abc", "compatible_server": "1.1.0", "reason": "a held file",
			"attempts": 3, "changed_files": PackedStringArray(["core/a.gd"])}
	var written := UpdateJournal.write(full, folder)
	var record := UpdateJournal.read(folder)
	UpdateJournal.write({"state": "staged", "from": "1.1.0", "to": "1.2.0"}, folder)
	var sparse := UpdateJournal.read(folder)
	UpdateFixtures.remove(folder)
	testing.ok(written, "a write that holds → true")
	testing.eq(record, full, "every field back")
	var expected := _empty()
	expected["state"] = "staged"
	expected["from"] = "1.1.0"
	expected["to"] = "1.2.0"
	testing.eq(sparse, expected, "a field left out → empty")
	print("")


static func _test_pinned_journal(testing: Testing) -> void:
	testing.begin("Update journal: the journal 1.2.0 writes")
	var folder := UpdateFixtures.scratch("journal_pinned")
	_write_text(folder, _PINNED_1_2_0_JOURNAL)
	var record := UpdateJournal.read(folder)
	UpdateFixtures.remove(folder)
	testing.eq(record, {"state": "staged", "from": "1.1.0", "to": "1.2.0", "backup": "backup-1.1.0",
			"expected_tree_hash": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
			"compatible_server": "1.1.0", "reason": "a held file", "attempts": 2,
			"changed_files": PackedStringArray(["core/a.gd"])}, "this and every later version reads it whole")
	print("")


static func _test_states(testing: Testing) -> void:
	testing.begin("Update journal: the states on disk")
	testing.eq(UpdateJournal.FORMAT, 1, "the format")
	testing.eq(UpdateJournal.VERIFIED, "verified", "verified")
	testing.eq(UpdateJournal.STAGED, "staged", "staged")
	testing.eq(UpdateJournal.APPLYING, "applying", "applying")
	testing.eq(UpdateJournal.APPLIED, "applied", "applied")
	testing.eq(UpdateJournal.NOT_APPLIED, "not_applied", "not applied")
	print("")


static func _test_defaults(testing: Testing) -> void:
	testing.begin("Update journal: missing, broken and newer journals")
	var folder := UpdateFixtures.scratch("journal_defaults")
	var missing := UpdateJournal.read(folder)
	_write_text(folder, "{broken")
	var broken := UpdateJournal.read(folder)
	_write_text(folder, "{\"format\": 1, \"state\": \"staged\", \"from\": \"1.1")
	var torn := UpdateJournal.read(folder)
	_write_text(folder, JSON.stringify({"format": 2, "state": "staged", "from": "1.1.0", "to": "9.0.0"}))
	var newer := UpdateJournal.read(folder)
	UpdateFixtures.remove(folder)
	testing.eq(missing, _empty(), "no journal → every field empty")
	testing.eq(broken, _empty(), "broken JSON → every field empty")
	testing.eq(torn, _empty(), "a journal cut short by a kill → every field empty")
	testing.eq(newer, _empty(), "a newer format → every field empty")
	print("")


static func _test_bad_versions(testing: Testing) -> void:
	testing.begin("Update journal: a version paths cannot be built from")
	var valid := {"format": 1, "state": "staged", "from": "1.1.0", "to": "1.2.0"}
	var bad_values := ["../../evil", "1.2", "1.2.0-beta", "", 3, null]
	for index: int in range(bad_values.size()):
		var bad_to := valid.duplicate()
		bad_to["to"] = bad_values[index]
		var bad_from := valid.duplicate()
		bad_from["from"] = bad_values[index]
		var label := str(bad_values[index])
		testing.eq(_read_fields("journal_bad_to_%d" % index, bad_to), _empty(), "to = %s → no journal" % label)
		testing.eq(_read_fields("journal_bad_from_%d" % index, bad_from), _empty(), "from = %s → no journal" % label)
	var no_to := valid.duplicate()
	no_to.erase("to")
	var no_from := valid.duplicate()
	no_from.erase("from")
	testing.eq(_read_fields("journal_no_to", no_to), _empty(), "no to → no journal")
	testing.eq(_read_fields("journal_no_from", no_from), _empty(), "no from → no journal")
	var bad_backups := ["../../addons", "backup-../..", "backup-1.0.0", "stage", 3]
	for index: int in range(bad_backups.size()):
		var bad_backup := valid.duplicate()
		bad_backup["backup"] = bad_backups[index]
		testing.eq(_read_fields("journal_bad_backup_%d" % index, bad_backup), _empty(),
				"backup = %s → no journal" % str(bad_backups[index]))
	print("")


static func _test_unknown_state(testing: Testing) -> void:
	testing.begin("Update journal: a state this version does not know")
	var valid := {"format": 1, "from": "1.1.0", "to": "1.2.0"}
	var states := ["rolled_back", "a_later_state", "", 3]
	for index: int in range(states.size()):
		var fields := valid.duplicate()
		fields["state"] = states[index]
		testing.eq(_read_fields("journal_state_%d" % index, fields), _empty(),
				"state = %s → no journal" % str(states[index]))
	testing.eq(_read_fields("journal_no_state", valid), _empty(), "no state → no journal")
	print("")


static func _test_mistyped_fields(testing: Testing) -> void:
	testing.begin("Update journal: a field of the wrong type")
	var record := _read_fields("journal_mistyped", {"format": 1, "state": "staged", "from": "1.1.0", "to": "1.2.0",
			"reason": 3, "compatible_server": ["1.1.0"], "expected_tree_hash": 4, "attempts": "two",
			"changed_files": ["a", 4]})
	var expected := _empty()
	expected["state"] = "staged"
	expected["from"] = "1.1.0"
	expected["to"] = "1.2.0"
	expected["changed_files"] = PackedStringArray(["a"])
	testing.eq(record, expected, "empty, the others kept")
	var negative := _read_fields("journal_negative_attempts", {"format": 1, "state": "staged", "from": "1.1.0", "to": "1.2.0",
			"attempts": -2})
	testing.eq(negative["attempts"], 0, "negative attempts → 0")
	print("")


static func _test_unknown_keys(testing: Testing) -> void:
	testing.begin("Update journal: a key a later version added")
	var record := _read_fields("journal_unknown_key", {"format": 1, "state": "staged", "from": "1.1.0", "to": "1.2.0",
			"a_later_key": "value"})
	testing.eq(record["state"], "staged", "the journal still reads")
	testing.ok(not record.has("a_later_key"), "the key is ignored")
	print("")


static func _test_write_that_fails(testing: Testing) -> void:
	testing.begin("Update journal: a write that cannot happen")
	var folder := UpdateFixtures.scratch("journal_write_blocked")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder).path_join("journal.json"))
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var written := UpdateJournal.write({"state": "applying", "from": "1.1.0", "to": "1.2.0"}, folder)
	Engine.print_error_messages = printed
	UpdateFixtures.remove(folder)
	testing.ok(not written, "a folder where the journal goes → false")
	print("")


static func _test_clear(testing: Testing) -> void:
	testing.begin("Update journal: clearing")
	var folder := UpdateFixtures.scratch("journal_clear")
	var absolute := ProjectSettings.globalize_path(folder)
	UpdateJournal.write({"state": "staged", "from": "1.1.0", "to": "1.2.0"}, folder)
	FolderFiles.write_checked(absolute.path_join("install.log"), "kept\n".to_utf8_buffer())
	FolderFiles.write_checked(absolute.path_join(".gitignore"), "*\n".to_utf8_buffer())
	FolderFiles.write_checked(absolute.path_join("1.2.0/a.zip"), "a".to_utf8_buffer())
	FolderFiles.write_checked(absolute.path_join("stage/a.gd"), "a".to_utf8_buffer())
	FolderFiles.write_checked(absolute.path_join("backup-1.1.0/core/a.gd"), "a".to_utf8_buffer())
	UpdateJournal.clear(folder)
	var journal_gone := not FileAccess.file_exists(absolute.path_join("journal.json"))
	var version_gone := not DirAccess.dir_exists_absolute(absolute.path_join("1.2.0"))
	var stage_gone := not DirAccess.dir_exists_absolute(absolute.path_join("stage"))
	var backup_kept := FileAccess.file_exists(absolute.path_join("backup-1.1.0/core/a.gd"))
	var log_kept := FileAccess.file_exists(absolute.path_join("install.log"))
	var ignore_kept := FileAccess.file_exists(absolute.path_join(".gitignore"))
	UpdateJournal.clear(folder)
	var backup_kept_again := FileAccess.file_exists(absolute.path_join("backup-1.1.0/core/a.gd"))
	UpdateFixtures.remove(folder)
	UpdateJournal.clear(folder)
	testing.ok(journal_gone, "the journal → deleted")
	testing.ok(version_gone, "a version folder → deleted")
	testing.ok(stage_gone, "the stage → deleted")
	testing.ok(backup_kept, "the backup → kept")
	testing.ok(log_kept, "the install log → kept")
	testing.ok(ignore_kept, "the ignore files → kept")
	testing.ok(backup_kept_again, "clearing with no journal → the backup still kept")
	testing.ok(not DirAccess.dir_exists_absolute(absolute), "clearing a folder that vanished → nothing happens")
	print("")
