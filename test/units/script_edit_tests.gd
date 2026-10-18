@tool
extends RefCounted
## script.edit's edits array: several edits apply in order in one call, and one that
## doesn't match leaves the file as it was. The success path ends in the editor's
## undo and reindex, which a headless run lacks, so the groups drive _apply_edits for
## the edited text and the handler only for failures, which return before any write.

const ScriptCommands := preload("res://addons/godot_mcp_toolkit/commands/script_commands.gd")

const FIXTURE := "res://test/fixtures/script_edit_fixture.gd"
const SOURCE := "extends Node\n\n\nfunc old_name() -> int:\n\treturn 1\n\n\nfunc caller() -> int:\n\treturn old_name()\n"


static func run(testing) -> void:
	_test_edits_apply_in_order(testing)
	_test_edit_sees_earlier_edits(testing)
	_test_unmatched_edit_fails_whole_call(testing)
	await _test_handler_writes_nothing_on_unmatched_edit(testing)
	await _test_handler_rejects_mixed_forms(testing)
	await _test_handler_hints_edit_order_on_not_unique(testing)
	await _test_handler_tolerates_replace_all_false(testing)


static func _test_edits_apply_in_order(testing) -> void:
	testing.begin("script.edit edits: rename a function and its caller in one call")
	var edits := [
		{"old_string": "func old_name()", "new_string": "func new_name()"},
		{"old_string": "return old_name()", "new_string": "return new_name()"},
		{"old_string": "-> int", "new_string": "-> float", "replace_all": true},
	]
	var applied := ScriptCommands._apply_edits(SOURCE, edits, FIXTURE, true)
	testing.ok(not applied.has("error"), "three edits → no error")
	testing.eq(str(applied.get("content", "")),
			"extends Node\n\n\nfunc new_name() -> float:\n\treturn 1\n\n\nfunc caller() -> float:\n\treturn new_name()\n",
			"every edit applied")
	testing.eq(applied.get("replacements", 0), 4, "replacements counts every span, replace_all included")
	print("")


static func _test_edit_sees_earlier_edits(testing) -> void:
	testing.begin("script.edit edits: each edit matches the text the earlier ones leave")
	var edits := [
		{"old_string": "return 1", "new_string": "return 2"},
		{"old_string": "return 2", "new_string": "return 3"},
	]
	var applied := ScriptCommands._apply_edits(SOURCE, edits, FIXTURE, true)
	testing.ok(str(applied.get("content", "")).contains("\treturn 3\n"), "second edit matched the first's output")
	print("")


static func _test_unmatched_edit_fails_whole_call(testing) -> void:
	testing.begin("script.edit edits: an unmatched or ambiguous edit fails the call")
	var missing := ScriptCommands._apply_edits(SOURCE, [
		{"old_string": "func old_name()", "new_string": "func new_name()"},
		{"old_string": "never_present", "new_string": "x"},
	], FIXTURE, true)
	testing.eq(missing.get("code", ""), "NOT_FOUND", "absent old_string → NOT_FOUND")
	testing.ok(str(missing.get("error", "")).begins_with("edits[1]: "), "the error names edits[1]")
	testing.ok(not missing.has("content"), "no edited content returned")

	var ambiguous := ScriptCommands._apply_edits(SOURCE, [
		{"old_string": "-> int", "new_string": "-> float"},
	], FIXTURE, true)
	testing.eq(ambiguous.get("code", ""), "NOT_UNIQUE", "two matches without replace_all → NOT_UNIQUE")
	testing.ok(str(ambiguous.get("error", "")).begins_with("edits[0]: "), "the error names edits[0]")
	print("")


static func _test_handler_writes_nothing_on_unmatched_edit(testing) -> void:
	testing.begin("script.edit handler: an unmatched edit writes nothing")
	var checkout := _write_fixture()
	testing.eq(FileAccess.get_file_as_string(FIXTURE), SOURCE, "fixture holds the expected source")
	var result: Dictionary = await ScriptCommands._cmd_script_edit(null, {
		"file_path": FIXTURE,
		"edits": [
			{"old_string": "func old_name()", "new_string": "func new_name()"},
			{"old_string": "never_present", "new_string": "x"},
		],
	})
	testing.eq(result.get("code", ""), "NOT_FOUND", "second edit unmatched → NOT_FOUND")
	testing.ok(str(result.get("error", "")).begins_with("edits[1]: "), "the error names edits[1]")
	testing.eq(FileAccess.get_file_as_string(FIXTURE), SOURCE, "the file is unchanged")
	_restore_fixture(checkout)
	print("")


static func _test_handler_rejects_mixed_forms(testing) -> void:
	testing.begin("script.edit handler: edits alone, never beside old_string")
	var checkout := _write_fixture()
	var mixed: Dictionary = await ScriptCommands._cmd_script_edit(null, {
		"file_path": FIXTURE,
		"old_string": "return 1",
		"new_string": "return 2",
		"edits": [{"old_string": "caller", "new_string": "other"}],
	})
	testing.eq(mixed.get("code", ""), "INVALID_PARAMS", "edits beside old_string → INVALID_PARAMS")
	var empty: Dictionary = await ScriptCommands._cmd_script_edit(null, {"file_path": FIXTURE, "edits": []})
	testing.eq(empty.get("code", ""), "INVALID_PARAMS", "empty edits → INVALID_PARAMS")
	var same: Dictionary = await ScriptCommands._cmd_script_edit(null, {
		"file_path": FIXTURE,
		"edits": [{"old_string": "return 1", "new_string": "return 1"}],
	})
	testing.eq(same.get("code", ""), "INVALID_PARAMS", "a no-op edit → INVALID_PARAMS")
	testing.eq(FileAccess.get_file_as_string(FIXTURE), SOURCE, "the file is unchanged")
	_restore_fixture(checkout)
	print("")


static func _test_handler_hints_edit_order_on_not_unique(testing) -> void:
	testing.begin("script.edit handler: an ambiguous edit in the edits form hints at the edit order")
	var checkout := _write_fixture()
	var ambiguous: Dictionary = await ScriptCommands._cmd_script_edit(null, {
		"file_path": FIXTURE,
		"edits": [{"old_string": "-> int", "new_string": "-> float"}],
	})
	testing.eq(ambiguous.get("code", ""), "NOT_UNIQUE", "two matches without replace_all → NOT_UNIQUE")
	testing.ok(str(ambiguous.get("hint", "")).contains("Edits apply in order"),
			"the hint says the edits apply in order")
	var single: Dictionary = await ScriptCommands._cmd_script_edit(null, {
		"file_path": FIXTURE,
		"old_string": "-> int",
		"new_string": "-> float",
	})
	testing.eq(single.get("code", ""), "NOT_UNIQUE", "the single form → NOT_UNIQUE too")
	testing.ok(not str(single.get("hint", "")).contains("Edits apply in order"),
			"the single form's hint does not mention edits")
	testing.eq(FileAccess.get_file_as_string(FIXTURE), SOURCE, "the file is unchanged")
	_restore_fixture(checkout)
	print("")


static func _test_handler_tolerates_replace_all_false(testing) -> void:
	testing.begin("script.edit handler: a default replace_all:false beside edits is not a second form")
	var checkout := _write_fixture()
	var defaulted: Dictionary = await ScriptCommands._cmd_script_edit(null, {
		"file_path": FIXTURE,
		"replace_all": false,
		"edits": [
			{"old_string": "func old_name()", "new_string": "func new_name()"},
			{"old_string": "never_present", "new_string": "x"},
		],
	})
	testing.eq(defaulted.get("code", ""), "NOT_FOUND", "the edits run, and the unmatched one → NOT_FOUND")
	testing.ok(str(defaulted.get("error", "")).begins_with("edits[1]: "), "the error names edits[1]")
	var conflicting: Dictionary = await ScriptCommands._cmd_script_edit(null, {
		"file_path": FIXTURE,
		"replace_all": true,
		"edits": [{"old_string": "return 1", "new_string": "return 2"}],
	})
	testing.eq(conflicting.get("code", ""), "INVALID_PARAMS", "replace_all:true beside edits → INVALID_PARAMS")
	testing.eq(FileAccess.get_file_as_string(FIXTURE), SOURCE, "the file is unchanged")
	_restore_fixture(checkout)
	print("")


## Writes [constant SOURCE] to the fixture with LF line endings, so the byte-for-byte
## asserts hold on a checkout that converts text files to CRLF. Returns the bytes the
## checkout held, for [method _restore_fixture].
static func _write_fixture() -> PackedByteArray:
	var checkout := FileAccess.get_file_as_bytes(FIXTURE)
	if checkout.is_empty():
		checkout = SOURCE.to_utf8_buffer()
	var file := FileAccess.open(FIXTURE, FileAccess.WRITE)
	file.store_string(SOURCE)
	file.close()
	return checkout


## Puts back the bytes [method _write_fixture] replaced, so a run leaves the working
## tree as it found it.
static func _restore_fixture(checkout: PackedByteArray) -> void:
	var file := FileAccess.open(FIXTURE, FileAccess.WRITE)
	file.store_buffer(checkout)
	file.close()
