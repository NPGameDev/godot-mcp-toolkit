@tool
extends SceneTree
## Reads documents that scripts/trust-document.sh made in this run with the reader clients run,
## so the pinned fixtures cannot drift from the tool, and writes one of the reader's side for
## the tool to check.
##
## scripts/test_trust_documents.sh lays out the folder it names: [code]chain/[/code] holding
## [code]trust-1.json[/code] onward, [code]next.json[/code] that follows them,
## [code]refused/[/code] holding files that must not follow them, and a manifest signed by a
## key the chain lists and by one it dropped. It writes [code]godot-made.json[/code] there.
## [codeblock]
## godot --headless --path . --script res://test/tools/read_trust_documents.gd -- <folder>
## [/codeblock]
## The engine prints its own lines around the verdict, and its exit code is unreliable on
## Windows, so the verdict is the line that starts with [constant RESULT_MARKER].

const TrustChain := preload("res://addons/godot_mcp_toolkit/self_update/trust_chain.gd")
const ReleaseSignature := preload("res://addons/godot_mcp_toolkit/self_update/release_signature.gd")
const TrustFolderCheck := preload("res://test/units/trust_folder_check.gd")
const TrustFixtures := preload("res://test/units/trust_fixtures.gd")

## Prefix of the output line that carries the verdict.
const RESULT_MARKER := "TRUST_READER_RESULT "

var _failed := 0


func _init() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.is_empty():
		print(RESULT_MARKER + "no folder given")
		quit(2)
		return
	_read(arguments[0])
	print(RESULT_MARKER + ("pass" if _failed == 0 else "fail"))
	quit(0 if _failed == 0 else 1)


func _read(folder: String) -> void:
	var chain_folder := folder.path_join("chain")
	_expect(TrustFolderCheck.folder_problems(chain_folder).is_empty(), "the chain walks from its first document")

	var first_text := FileAccess.get_file_as_string(chain_folder.path_join("trust-1.json"))
	var source := {"trust_document": first_text, "trust_store": chain_folder}
	var manifest := FileAccess.get_file_as_bytes(folder.path_join("manifest.txt"))
	var new_key := FileAccess.get_file_as_bytes(folder.path_join("new-key.signature"))
	var dropped_key := FileAccess.get_file_as_bytes(folder.path_join("dropped-key.signature"))
	_expect(ReleaseSignature.chain(source).version() == 3, "a client on the first document walks to the third")
	_expect(ReleaseSignature.is_trusted(manifest, new_key, null, source), "a release signed by the rotated key is trusted")
	_expect(not ReleaseSignature.is_trusted(manifest, dropped_key, null, source), "a release signed by the dropped key is not")

	var latest := TrustChain.read_self_signed(FileAccess.get_file_as_bytes(chain_folder.path_join("trust-1.json")))
	for number: int in [2, 3]:
		latest = TrustChain.read_next(latest, FileAccess.get_file_as_bytes(chain_folder.path_join("trust-%d.json" % number)))
	var next := TrustChain.read_next(latest, FileAccess.get_file_as_bytes(folder.path_join("next.json")))
	_expect(str(next["error"]).is_empty(), "the next document follows them: %s" % next["error"])

	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var refused_folder := folder.path_join("refused")
	var refused_files := DirAccess.get_files_at(refused_folder)
	_expect(not refused_files.is_empty(), "there are files to refuse")
	for file_name: String in refused_files:
		var refused := TrustChain.read_next(latest, FileAccess.get_file_as_bytes(refused_folder.path_join(file_name)))
		_expect(not str(refused["error"]).is_empty(), "%s is refused" % file_name)
	Engine.print_error_messages = printed

	var root := TrustFixtures.root_key()
	var written := TrustFixtures.file_of(TrustFixtures.body(1, [root], 1, [TrustFixtures.release_key()]), [root])
	var file := FileAccess.open(folder.path_join("godot-made.json"), FileAccess.WRITE)
	_expect(file != null, "the reader's side can write its document")
	if file != null:
		file.store_buffer(written)
		file.close()


func _expect(holds: bool, label: String) -> void:
	print("  %s %s" % ["ok  " if holds else "FAIL", label])
	if not holds:
		_failed += 1
