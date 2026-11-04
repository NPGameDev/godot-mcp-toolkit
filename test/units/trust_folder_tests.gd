@tool
extends RefCounted
## Unit tests for the repository's trust/ folder and the embedded document against it, through
## test/units/trust_folder_check.gd. The folder may hold no document yet, so each check is also
## run on scratch folders that must fail it.

const Testing := preload("res://test/units/testing.gd")
const EmbeddedTrustDocument := preload("res://addons/godot_mcp_toolkit/self_update/embedded_trust_document.gd")
const TrustFolderCheck := preload("res://test/units/trust_folder_check.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")
const TrustFixtures := preload("res://test/units/trust_fixtures.gd")

const _TRUST_FOLDER := "res://trust"
const _NO_PROBLEMS := ""


static func run(testing: Testing) -> void:
	_test_the_repository(testing)
	_test_walk_holds(testing)
	_test_walk_fails(testing)
	_test_embedded_holds(testing)
	_test_embedded_fails(testing)
	_test_embedded_differs_in_one_field(testing)


static func _test_the_repository(testing: Testing) -> void:
	testing.begin("Trust folder: the repository's")
	var problems := TrustFolderCheck.folder_problems(_TRUST_FOLDER)
	var embedded_problems := TrustFolderCheck.embedded_problems(_TRUST_FOLDER, EmbeddedTrustDocument.DOCUMENT)
	testing.ok(FileAccess.file_exists(_TRUST_FOLDER.path_join("released-manifests.txt")), "the folder is there, with its ledger")
	testing.eq(_joined(problems), _NO_PROBLEMS, "every document walks from its own first, named for its version")
	testing.eq(_joined(embedded_problems), _NO_PROBLEMS, "the embedded document is the highest one, or both are absent")
	print("")


static func _test_walk_holds(testing: Testing) -> void:
	testing.begin("Trust folder: a walk that holds")
	var folder := _folder("walk_holds")
	DirAccess.make_dir_recursive_absolute(folder)
	var empty := _joined(TrustFolderCheck.folder_problems(folder))
	_write_chain(folder, 7)
	var whole := _joined(TrustFolderCheck.folder_problems(folder))
	FolderFiles.write_checked(folder.path_join("released-manifests.txt"), "1.2.0 abc\n".to_utf8_buffer())
	var with_ledger := _joined(TrustFolderCheck.folder_problems(folder))
	UpdateFixtures.remove(folder)
	testing.eq(empty, _NO_PROBLEMS, "an empty folder holds")
	testing.eq(whole, _NO_PROBLEMS, "seven documents in order hold")
	testing.eq(with_ledger, _NO_PROBLEMS, "a file that is no document is left alone")
	print("")


static func _test_walk_fails(testing: Testing) -> void:
	testing.begin("Trust folder: a walk that fails")
	var root := TrustFixtures.root_key()
	var release := TrustFixtures.release_key()
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false

	var folder := _folder("walk_fails")
	_write_chain(folder, 6)
	_write(folder, "trust-7.json", TrustFixtures.file_of(TrustFixtures.body(8, [root], 1, [release]), [root]))
	var wrong_version := _joined(TrustFolderCheck.folder_problems(folder))
	UpdateFixtures.remove(folder)

	_write(folder, "trust-1.json", TrustFixtures.file_of(TrustFixtures.body(1, [root], 1, [release]), [TrustFixtures.second_root_key()]))
	var first_not_own := _joined(TrustFolderCheck.folder_problems(folder))
	UpdateFixtures.remove(folder)

	_write_chain(folder, 2)
	_write(folder, "trust-3.json", TrustFixtures.file_of(TrustFixtures.body(3, [root], 1, [release]), [TrustFixtures.second_root_key()]))
	var bad_signer := _joined(TrustFolderCheck.folder_problems(folder))
	UpdateFixtures.remove(folder)

	_write_chain(folder, 2)
	_write(folder, "trust-4.json", TrustFixtures.file_of(TrustFixtures.body(4, [root], 1, [release]), [root]))
	var gap := _joined(TrustFolderCheck.folder_problems(folder))
	UpdateFixtures.remove(folder)

	_write(folder, "trust-2.json", TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, [release]), [root]))
	var no_first := _joined(TrustFolderCheck.folder_problems(folder))
	UpdateFixtures.remove(folder)

	_write(folder, "trust-01.json", TrustFixtures.file_of(TrustFixtures.body(1, [root], 1, [release]), [root]))
	var stray_name := _joined(TrustFolderCheck.folder_problems(folder))
	UpdateFixtures.remove(folder)

	var missing := _joined(TrustFolderCheck.folder_problems(folder))
	Engine.print_error_messages = printed

	testing.ok(wrong_version.contains("trust-7.json carries version 8"), "a file named 7 holding 8")
	testing.ok(first_not_own.contains("trust-1.json") and first_not_own.contains("own root keys"), "a first document its own roots did not sign")
	testing.ok(bad_signer.contains("trust-3.json") and bad_signer.contains("previous document's root keys"), "a document the previous roots did not sign")
	testing.ok(gap.contains("has trust-4.json and no trust-3.json"), "a gap in the numbers")
	testing.ok(no_first.contains("no trust-1.json"), "a folder that does not start at 1")
	testing.ok(stray_name.contains("trust-01.json is not named"), "a document under another name")
	testing.ok(missing.contains("there is no folder"), "no folder at all")
	print("")


static func _test_embedded_holds(testing: Testing) -> void:
	testing.begin("Trust folder: an embedded document that holds")
	var folder := _folder("embedded_holds")
	var nothing := _joined(TrustFolderCheck.embedded_problems(folder, ""))
	_write_chain(folder, 3)
	var highest := FileAccess.get_file_as_string(folder.path_join("trust-3.json"))
	var same := _joined(TrustFolderCheck.embedded_problems(folder, highest))
	var with_crlf := _joined(TrustFolderCheck.embedded_problems(folder, highest + "\r\n"))
	UpdateFixtures.remove(folder)
	testing.eq(nothing, _NO_PROBLEMS, "both absent holds")
	testing.eq(same, _NO_PROBLEMS, "the highest document holds")
	testing.eq(with_crlf, _NO_PROBLEMS, "a line end added on checkout changes nothing")
	print("")


static func _test_embedded_fails(testing: Testing) -> void:
	testing.begin("Trust folder: an embedded document that fails")
	var root := TrustFixtures.root_key()
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false

	var folder := _folder("embedded_fails")
	var lone := TrustFixtures.first_document([TrustFixtures.release_key()])
	var without_document := _joined(TrustFolderCheck.embedded_problems(folder, lone))

	_write_chain(folder, 3)
	var lower := FileAccess.get_file_as_string(folder.path_join("trust-2.json"))
	var empty_beside := _joined(TrustFolderCheck.embedded_problems(folder, ""))
	var differs := _joined(TrustFolderCheck.embedded_problems(folder, lower))
	var not_json := _joined(TrustFolderCheck.embedded_problems(folder, "not json"))
	UpdateFixtures.remove(folder)

	# The folder's own document, signed by another key: only the run time's forgiveness differs.
	var unsigned_by_own := TrustFixtures.file_of(TrustFixtures.body(1, [root], 1, []), [TrustFixtures.second_root_key()])
	_write(folder, "trust-1.json", unsigned_by_own)
	var own_roots := _joined(TrustFolderCheck.embedded_problems(folder, unsigned_by_own.get_string_from_utf8()))
	UpdateFixtures.remove(folder)
	Engine.print_error_messages = printed

	testing.ok(without_document.contains("the folder has no document"), "set, with no document in the folder")
	testing.ok(empty_beside.contains("is empty, and the folder has trust-3.json"), "empty beside a document")
	testing.ok(differs.contains("differs from trust-3.json"), "a lower document than the highest")
	testing.ok(not_json.contains("differs from trust-3.json"), "text that is no document")
	testing.ok(own_roots.contains("own root keys") and not own_roots.contains("differs"), "the highest, not signed by its own roots")
	print("")


# The file carries signatures over both documents, so either document stands against its own
# roots and only the comparison of the two fields can tell them apart.
static func _test_embedded_differs_in_one_field(testing: Testing) -> void:
	testing.begin("Trust folder: an embedded document that differs in one field")
	var root := TrustFixtures.root_key()
	var committed := JSON.stringify(TrustFixtures.body(1, [root], 1, [TrustFixtures.release_key()])).to_utf8_buffer()
	var another := JSON.stringify(TrustFixtures.body(1, [root], 1, [TrustFixtures.next_release_key()])).to_utf8_buffer()
	var over_committed := TrustFixtures.signatures_over(committed, [root])
	var signatures: Array = over_committed + TrustFixtures.signatures_over(another, [root])
	var committed_file := TrustFixtures.envelope(committed, signatures)
	var folder := _folder("embedded_one_field")
	_write(folder, "trust-1.json", committed_file)
	var same := _joined(TrustFolderCheck.embedded_problems(folder, committed_file.get_string_from_utf8()))
	var other_signatures := _joined(TrustFolderCheck.embedded_problems(folder, TrustFixtures.envelope(committed, over_committed).get_string_from_utf8()))
	var other_document := _joined(TrustFolderCheck.embedded_problems(folder, TrustFixtures.envelope(another, signatures).get_string_from_utf8()))
	UpdateFixtures.remove(folder)
	testing.eq(same, _NO_PROBLEMS, "the committed file itself holds")
	testing.eq(other_signatures, "the embedded document differs from trust-1.json", "the same document with other signatures, and nothing else wrong")
	testing.eq(other_document, "the embedded document differs from trust-1.json", "the same signatures with another document, and nothing else wrong")
	print("")


# A list's str() escapes differently across engine versions, so problems compare joined.
static func _joined(problems: PackedStringArray) -> String:
	return "; ".join(problems)


# An empty scratch folder, as an absolute path. The folder itself is not created.
static func _folder(purpose: String) -> String:
	var folder := ProjectSettings.globalize_path(UpdateFixtures.scratch("trust_folder_" + purpose))
	UpdateFixtures.remove(folder)
	return folder


static func _write(folder: String, file_name: String, file_bytes: PackedByteArray) -> void:
	FolderFiles.write_checked(folder.path_join(file_name), file_bytes)


# Writes trust-1.json to trust-[count].json, each signed by the one root.
static func _write_chain(folder: String, count: int) -> void:
	var root := TrustFixtures.root_key()
	for number: int in range(1, count + 1):
		var document := TrustFixtures.body(number, [root], 1, [TrustFixtures.release_key()])
		_write(folder, "trust-%d.json" % number, TrustFixtures.file_of(document, [root]))
