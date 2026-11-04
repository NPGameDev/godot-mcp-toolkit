@tool
extends RefCounted
## Unit tests for the trust chain, on documents made in the run and scratch store folders:
## rotation, a leak, a change of roots, thresholds, every refusal, the store, the walk's
## limit, and going back. The exit's reading of the chain is in the applier's tests.

const Testing := preload("res://test/units/testing.gd")
const TrustChain := preload("res://addons/godot_mcp_toolkit/self_update/trust_chain.gd")
const ReleaseSignature := preload("res://addons/godot_mcp_toolkit/self_update/release_signature.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")
const TrustFixtures := preload("res://test/units/trust_fixtures.gd")


static func run(testing: Testing) -> void:
	_test_rotation(testing)
	_test_leak(testing)
	_test_root_change(testing)
	_test_two_of_two(testing)
	_test_key_listed_twice(testing)
	_test_each_check_counts_a_key_once(testing)
	_test_key_layouts(testing)
	_test_order_of_reading(testing)
	_test_refusals(testing)
	_test_values_only_coercion_would_pass(testing)
	_test_edges(testing)
	_test_outer_file_formatting(testing)
	_test_duplicate_key(testing)
	_test_empty_release_keys(testing)
	_test_embedded(testing)
	_test_self_signed(testing)
	_test_store_tampered(testing)
	_test_store_tampered_past_a_good_file(testing)
	_test_store_deleted(testing)
	_test_store_gap(testing)
	_test_accept_closes_a_gap(testing)
	_test_store_never_goes_lower(testing)
	_test_store_oversized(testing)
	_test_failed_write(testing)
	_test_concurrent_editor(testing)
	_test_no_store(testing)
	_test_store_folder(testing)
	_test_walk_limit(testing)
	_test_unknown_field(testing)
	_test_going_back(testing)
	_test_outcome_strings(testing)


# An empty scratch folder for a store. The folder itself is not created.
static func _store(purpose: String) -> String:
	var folder := UpdateFixtures.scratch("trust_" + purpose)
	UpdateFixtures.remove(folder)
	return folder


static func _store_files(folder: String) -> PackedStringArray:
	return FolderFiles.list(ProjectSettings.globalize_path(folder))


static func _write_to_store(folder: String, number: int, bytes: PackedByteArray) -> void:
	FolderFiles.write_checked(ProjectSettings.globalize_path(folder).path_join("trust-%d.json" % number), bytes)


static func _read_from_store(folder: String, number: int) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(folder).path_join("trust-%d.json" % number))


# Loads with engine errors silenced, for a document that makes one on purpose.
static func _load(document: String, store: String) -> TrustChain:
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var chain := TrustChain.new(document, store)
	Engine.print_error_messages = printed
	return chain


# Offers a file with engine errors silenced, and answers its outcome.
static func _offer(chain: TrustChain, file_bytes: PackedByteArray) -> String:
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var outcome := str(chain.accept(file_bytes)["outcome"])
	Engine.print_error_messages = printed
	return outcome


# Offers a file with engine errors silenced, and answers why it was refused: empty if taken.
static func _refusal_reason(chain: TrustChain, file_bytes: PackedByteArray) -> String:
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var reason := str(chain.accept(file_bytes)["reason"])
	Engine.print_error_messages = printed
	return reason


static func _signed_by(key: CryptoKey, manifest: PackedByteArray) -> PackedByteArray:
	return UpdateFixtures.signature_of(manifest, key)


static func _test_rotation(testing: Testing) -> void:
	testing.begin("Trust chain: a rotation reaches a release signed by the new key")
	var root := TrustFixtures.root_key()
	var manifest := "a later release".to_utf8_buffer()
	var signature := _signed_by(TrustFixtures.next_release_key(), manifest)
	var store := _store("rotation")
	var source := {"trust_document": TrustFixtures.first_document([TrustFixtures.release_key()]), "trust_store": store}
	var before := ReleaseSignature.is_trusted(manifest, signature, null, source)
	var chain := ReleaseSignature.chain(source)
	var next_before := chain.next_version()
	var outcome := _offer(chain, TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, [TrustFixtures.next_release_key()]), [root]))
	var moved_to := chain.version()
	var next_after := chain.next_version()
	var after := ReleaseSignature.is_trusted(manifest, signature, null, source)
	var stored := _store_files(store)
	UpdateFixtures.remove(store)
	testing.ok(not before, "before the document, the new key is not trusted")
	testing.eq(next_before, 2, "the chain asks for the next version")
	testing.eq(outcome, TrustChain.ACCEPTED, "the next document is accepted")
	testing.eq(moved_to, 2, "the chain moves to it")
	testing.eq(next_after, 3, "and asks for the one after")
	testing.ok(after, "a fresh load from the store trusts the new key")
	testing.eq(stored, PackedStringArray(["trust-2.json"]), "the store holds that one file, no temporary")
	print("")


static func _test_leak(testing: Testing) -> void:
	testing.begin("Trust chain: a dropped key is refused once the document is seen")
	var root := TrustFixtures.root_key()
	var manifest := "a release signed by a leaked key".to_utf8_buffer()
	var signature := _signed_by(TrustFixtures.release_key(), manifest)
	var store := _store("leak")
	var source := {"trust_document": TrustFixtures.first_document([TrustFixtures.release_key()]), "trust_store": store}
	var before := ReleaseSignature.is_trusted(manifest, signature, null, source)
	var outcome := _offer(ReleaseSignature.chain(source), TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, [TrustFixtures.next_release_key()]), [root]))
	var after := ReleaseSignature.is_trusted(manifest, signature, null, source)
	UpdateFixtures.remove(store)
	testing.ok(before, "before the document, the key is trusted")
	testing.eq(outcome, TrustChain.ACCEPTED, "the dropping document is accepted")
	testing.ok(not after, "after it, the same signature is refused")
	print("")


static func _test_root_change(testing: Testing) -> void:
	testing.begin("Trust chain: changing a root takes the old and the new")
	var old_root := TrustFixtures.root_key()
	var new_root := TrustFixtures.second_root_key()
	var release := TrustFixtures.release_key()
	var first := TrustFixtures.first_document([release])
	var moved := TrustFixtures.body(2, [new_root], 1, [release])
	var store := _store("root_change")
	var only_old := _offer(_load(first, store), TrustFixtures.file_of(moved, [old_root]))
	var only_new := _offer(_load(first, store), TrustFixtures.file_of(moved, [new_root]))
	var chain := _load(first, store)
	var both := _offer(chain, TrustFixtures.file_of(moved, [old_root, new_root]))
	var third := TrustFixtures.body(3, [new_root], 1, [release])
	var by_retired_root := _offer(chain, TrustFixtures.file_of(third, [old_root]))
	var by_current_root := _offer(chain, TrustFixtures.file_of(third, [new_root]))
	UpdateFixtures.remove(store)
	testing.eq(only_old, TrustChain.INVALID, "signed by the old root only → refused")
	testing.eq(only_new, TrustChain.INVALID, "signed by the new root only → refused")
	testing.eq(both, TrustChain.ACCEPTED, "signed by both → accepted")
	testing.eq(by_retired_root, TrustChain.INVALID, "the next document by the retired root → refused")
	testing.eq(by_current_root, TrustChain.ACCEPTED, "the next document by the current root → accepted")
	print("")


static func _test_two_of_two(testing: Testing) -> void:
	testing.begin("Trust chain: a threshold of two of two needs both roots")
	var root := TrustFixtures.root_key()
	var second_root := TrustFixtures.second_root_key()
	var release := TrustFixtures.release_key()
	var first := TrustFixtures.file_of(TrustFixtures.body(1, [root, second_root], 2, [release]), [root, second_root]).get_string_from_utf8()
	var next := TrustFixtures.body(2, [root, second_root], 2, [release])
	var decoded := JSON.stringify(next).to_utf8_buffer()
	var one_signature := TrustFixtures.signatures_over(decoded, [root])
	var store := _store("two_of_two")
	var both := _offer(_load(first, store), TrustFixtures.file_of(next, [root, second_root]))
	UpdateFixtures.remove(store)
	var one := _offer(_load(first, store), TrustFixtures.file_of(next, [root]))
	var same_twice := _offer(_load(first, store), TrustFixtures.envelope(decoded, one_signature + one_signature))
	UpdateFixtures.remove(store)
	testing.eq(both, TrustChain.ACCEPTED, "signed by both → accepted")
	testing.eq(one, TrustChain.INVALID, "signed by one → refused")
	testing.eq(same_twice, TrustChain.INVALID, "one key's signature held twice → refused")
	print("")


static func _test_key_listed_twice(testing: Testing) -> void:
	testing.begin("Trust chain: a key listed twice counts once toward its document's threshold")
	var root := TrustFixtures.root_key()
	var second_root := TrustFixtures.second_root_key()
	var release := TrustFixtures.release_key()
	var first := TrustFixtures.file_of(TrustFixtures.body(1, [root, second_root], 2, [release]), [root, second_root]).get_string_from_utf8()
	var pem := UpdateFixtures.public_pem(root)
	var store := _store("listed_twice")
	var listed_twice_needing_two := _offer(_load(first, store), TrustFixtures.file_of(TrustFixtures.body(2, [pem, pem], 2, [release]), [root, second_root]))
	var chain := _load(first, store)
	var listed_twice_needing_one := _offer(chain, TrustFixtures.file_of(TrustFixtures.body(2, [pem, pem], 1, [release]), [root, second_root]))
	var from_listed_twice := TrustFixtures.body(3, [root], 1, [release])
	var after_listed_twice := _offer(chain, TrustFixtures.file_of(from_listed_twice, [root]))
	UpdateFixtures.remove(store)
	testing.eq(listed_twice_needing_two, TrustChain.INVALID, "a key listed twice, a threshold of 2 → refused")
	testing.eq(listed_twice_needing_one, TrustChain.ACCEPTED, "a key listed twice, a threshold of 1 → accepted")
	testing.eq(after_listed_twice, TrustChain.ACCEPTED, "and the chain moves on from it")
	print("")


# Each document here passes one check with a single signature, so only the other check can
# refuse the repeat, and a check that counted repeats would take it alone.
static func _test_each_check_counts_a_key_once(testing: Testing) -> void:
	testing.begin("Trust chain: each signature check counts one key's signature once")
	var root := TrustFixtures.root_key()
	var second_root := TrustFixtures.second_root_key()
	var release := TrustFixtures.release_key()
	var two_roots := TrustFixtures.file_of(TrustFixtures.body(1, [root, second_root], 2, [release]), [root, second_root]).get_string_from_utf8()
	var to_one_root := TrustFixtures.body(2, [root], 1, [release])
	var to_two_roots := TrustFixtures.body(2, [root, second_root], 2, [release])
	var store := _store("each_check")
	var previous_twice := _refusal_reason(_load(two_roots, store), _signed_twice_by(root, to_one_root))
	UpdateFixtures.remove(store)
	var previous_both := _offer(_load(two_roots, store), TrustFixtures.file_of(to_one_root, [root, second_root]))
	UpdateFixtures.remove(store)
	var one_root := TrustFixtures.first_document([release])
	var own_twice := _refusal_reason(_load(one_root, store), _signed_twice_by(root, to_two_roots))
	UpdateFixtures.remove(store)
	var own_both := _offer(_load(one_root, store), TrustFixtures.file_of(to_two_roots, [root, second_root]))
	UpdateFixtures.remove(store)
	testing.eq(previous_twice, "too few of the previous document's root keys signed it",
			"a 2-of-2 previous, a next that needs one, one key's signature twice → the previous roots refuse")
	testing.eq(previous_both, TrustChain.ACCEPTED, "that document signed by both → accepted")
	testing.eq(own_twice, "too few of the document's own root keys signed it",
			"a previous that needs one, a next that needs two, one key's signature twice → its own roots refuse")
	testing.eq(own_both, TrustChain.ACCEPTED, "that document signed by both → accepted")
	print("")


# A file holding `document` and the signature of `key` over it, twice.
static func _signed_twice_by(key: CryptoKey, document: Dictionary) -> PackedByteArray:
	var decoded := JSON.stringify(document).to_utf8_buffer()
	var signature := TrustFixtures.signatures_over(decoded, [key])
	return TrustFixtures.envelope(decoded, signature + signature)


static func _test_key_layouts(testing: Testing) -> void:
	testing.begin("Trust chain: one key in two PEM layouts counts once")
	var root := TrustFixtures.root_key()
	var second := TrustFixtures.second_root_key()
	var release := TrustFixtures.release_key()
	var pem := UpdateFixtures.public_pem(root)
	var crlf := TrustFixtures.crlf_layout(pem)
	var rewrapped := TrustFixtures.rewrapped_layout(pem)
	var first := TrustFixtures.first_document([release])
	var store := _store("layouts")
	var crlf_alone := _offer(_load(first, store), TrustFixtures.file_of(TrustFixtures.body(2, [crlf], 1, [release]), [root]))
	UpdateFixtures.remove(store)
	var rewrapped_alone := _offer(_load(first, store), TrustFixtures.file_of(TrustFixtures.body(2, [rewrapped], 1, [release]), [root]))
	UpdateFixtures.remove(store)
	var three_layouts_needing_two := _offer(_load(first, store), TrustFixtures.file_of(TrustFixtures.body(2, [pem, crlf, rewrapped], 2, [release]), [root]))
	var other_key_makes_two := _offer(_load(first, store), TrustFixtures.file_of(TrustFixtures.body(2, [crlf, second], 2, [release]), [root, second]))
	UpdateFixtures.remove(store)
	var embedded_two_layouts := TrustFixtures.file_of(TrustFixtures.body(1, [pem, crlf], 2, [release]), [root]).get_string_from_utf8()
	var embedded_version := _load(embedded_two_layouts, store).version()
	UpdateFixtures.remove(store)
	testing.ok(crlf != pem and rewrapped != pem and crlf != rewrapped, "the three layouts differ as text")
	testing.eq(crlf_alone, TrustChain.ACCEPTED, "the CRLF layout loads and verifies")
	testing.eq(rewrapped_alone, TrustChain.ACCEPTED, "the rewrapped layout loads and verifies")
	testing.eq(three_layouts_needing_two, TrustChain.INVALID, "one key in three layouts, a threshold of 2 → refused")
	testing.eq(other_key_makes_two, TrustChain.ACCEPTED, "that key beside another, a threshold of 2 → accepted")
	testing.eq(embedded_version, 0, "an embedded document that counts it twice reads as empty")
	print("")


static func _test_order_of_reading(testing: Testing) -> void:
	testing.begin("Trust chain: nothing in a document is read before the roots vouch")
	var root := TrustFixtures.root_key()
	var previous := TrustChain.read_embedded(TrustFixtures.first_document([TrustFixtures.release_key()]))
	var stranger := TrustFixtures.second_root_key()
	var bad_body := TrustFixtures.signed_file("not json".to_utf8_buffer(), [stranger])
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var by_stranger := TrustChain.read_next(previous, bad_body)
	var by_root := TrustChain.read_next(previous, TrustFixtures.signed_file("not json".to_utf8_buffer(), [root]))
	Engine.print_error_messages = printed
	testing.eq(by_stranger, {"error": "too few of the previous document's root keys signed it"},
			"a broken body signed by a stranger → refused for its signature")
	testing.eq(by_root, {"error": "the document is not a JSON object"},
			"the same body signed by the root → refused for its body")
	print("")


# Each row differs from an accepted document by the one thing it names, and holds the reason
# it is refused for: without its own check, most of these still fall to a later one.
static func _refusal_rows() -> Array:
	var root := TrustFixtures.root_key()
	var other := TrustFixtures.second_root_key()
	var release := TrustFixtures.release_key()
	var good := TrustFixtures.body(2, [root], 1, [release])
	var decoded := JSON.stringify(good).to_utf8_buffer()
	var good_signatures := TrustFixtures.signatures_over(decoded, [root])
	var changed := TrustFixtures.body(2, [root], 1, [TrustFixtures.next_release_key()])
	var previous_roots := "too few of the previous document's root keys signed it"
	var not_held := "the file does not hold a document and its signatures"
	var not_an_object := "the file is not a JSON object"
	var bad_version := "the document's version is not a whole number"
	var not_next := "the document's version is not 2"
	var bad_roots := "the document's root keys are empty or do not load"
	var bad_threshold := "the document's root threshold is not between 1 and its distinct root keys"
	var bad_format := "the document's format is not 1"
	var bad_release_keys := "the document's release keys are not a list"
	var rows := [
		["a skipped version", TrustFixtures.file_of(TrustFixtures.body(3, [root], 1, [release]), [root]), not_next],
		["a repeated version", TrustFixtures.file_of(TrustFixtures.body(1, [root], 1, [release]), [root]), not_next],
		["a version with a fraction", TrustFixtures.file_of(TrustFixtures.body(2.5, [root], 1, [release]), [root]), bad_version],
		["a version that is text", TrustFixtures.file_of(TrustFixtures.body("2", [root], 1, [release]), [root]), bad_version],
		["empty root_keys", TrustFixtures.file_of(TrustFixtures.body(2, [], 1, [release]), [root]), bad_roots],
		["a root key that does not load", TrustFixtures.file_of(TrustFixtures.body(2, [root, "not a key"], 1, [release]), [root]), bad_roots],
		["a root key that is no string", TrustFixtures.file_of(TrustFixtures.body(2, [root, 7], 1, [release]), [root]), bad_roots],
		["a threshold of 0", TrustFixtures.file_of(TrustFixtures.body(2, [root], 0, [release]), [root]), bad_threshold],
		["a threshold above the roots", TrustFixtures.file_of(TrustFixtures.body(2, [root], 2, [release]), [root]), bad_threshold],
		["a threshold with a fraction", TrustFixtures.file_of(TrustFixtures.body(2, [root], 1.5, [release]), [root]), bad_threshold],
		["a threshold that is text", TrustFixtures.file_of(TrustFixtures.body(2, [root], "1", [release]), [root]), bad_threshold],
		["a threshold its own roots do not meet", TrustFixtures.file_of(TrustFixtures.body(2, [root, other], 2, [release]), [root]), "too few of the document's own root keys signed it"],
		["a tampered document", TrustFixtures.envelope(JSON.stringify(changed).to_utf8_buffer(), good_signatures), previous_roots],
		["no signatures", TrustFixtures.envelope(decoded, []), previous_roots],
		["a signature by a stranger", TrustFixtures.file_of(good, [other]), previous_roots],
		["a good signature beside one that does not decode", TrustFixtures.envelope(decoded, good_signatures + ["!!!!"]), "a signature does not decode"],
		["a good signature beside an empty one", TrustFixtures.envelope(decoded, good_signatures + [""]), "a signature does not decode"],
		["a good signature beside one that is no string", TrustFixtures.envelope(decoded, good_signatures + [7]), "a signature is not a string"],
		["a document that does not decode", JSON.stringify({"document": "!!!!", "signatures": good_signatures}).to_utf8_buffer(), "the document does not decode"],
		["an empty document", JSON.stringify({"document": "", "signatures": good_signatures}).to_utf8_buffer(), "the document does not decode"],
		["a document that is no string", JSON.stringify({"document": 7, "signatures": good_signatures}).to_utf8_buffer(), not_held],
		["no document", JSON.stringify({"signatures": good_signatures}).to_utf8_buffer(), not_held],
		["signatures that are no list", JSON.stringify({"document": Marshalls.raw_to_base64(decoded), "signatures": good_signatures[0]}).to_utf8_buffer(), not_held],
		["a file that is not JSON", "not json".to_utf8_buffer(), not_an_object],
		["a file that is a JSON list", "[1, 2]".to_utf8_buffer(), not_an_object],
		["an empty file", PackedByteArray(), not_an_object],
	]
	var missing_field_reasons := {
		"format": bad_format,
		"version": bad_version,
		"root_keys": bad_roots,
		"root_threshold": bad_threshold,
		"release_keys": bad_release_keys,
	}
	for field: String in missing_field_reasons:
		var without := good.duplicate()
		without.erase(field)
		rows.append(["no %s" % field, TrustFixtures.file_of(without, [root]), missing_field_reasons[field]])
	var format_two := good.duplicate()
	format_two["format"] = 2
	rows.append(["a format of 2", TrustFixtures.file_of(format_two, [root]), bad_format])
	var keys_not_listed := good.duplicate()
	keys_not_listed["release_keys"] = "a key"
	rows.append(["release_keys that are no list", TrustFixtures.file_of(keys_not_listed, [root]), bad_release_keys])
	return rows


static func _test_refusals(testing: Testing) -> void:
	testing.begin("Trust chain: what refuses a document")
	var root := TrustFixtures.root_key()
	var release := TrustFixtures.release_key()
	var first := TrustFixtures.first_document([release])
	var store := _store("refusals")
	var rows := _refusal_rows()
	for row: Array in rows:
		var chain := _load(first, store)
		var outcome := _offer(chain, row[1])
		var reason := _refusal_reason(chain, row[1])
		testing.eq(outcome, TrustChain.INVALID, "%s → refused" % row[0])
		testing.eq(reason, row[2], "%s → for that reason" % row[0])
		testing.eq(chain.version(), 1, "%s → the chain stays" % row[0])
		testing.eq(_store_files(store), PackedStringArray(), "%s → nothing written" % row[0])
	var accepted := _offer(_load(first, store), TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, [release]), [root]))
	UpdateFixtures.remove(store)
	testing.eq(accepted, TrustChain.ACCEPTED, "the document those rows change → accepted")
	print("")


# int(1.5) reads as the format and str(true) decodes as base64, so each row stands only on
# its type check. The boolean, since JSON numbers read as floats and str(1234.0) keeps a "."
# from 4.4 on, which does not decode.
static func _test_values_only_coercion_would_pass(testing: Testing) -> void:
	testing.begin("Trust chain: a value that holds only once coerced")
	var root := TrustFixtures.root_key()
	var release := TrustFixtures.release_key()
	var first := TrustFixtures.first_document([release])
	var good := TrustFixtures.body(2, [root], 1, [release])
	var decoded := JSON.stringify(good).to_utf8_buffer()
	var good_signatures := TrustFixtures.signatures_over(decoded, [root])
	var fractional_format := good.duplicate()
	fractional_format["format"] = 1.5
	var store := _store("coerced")
	var format_reason := _refusal_reason(_load(first, store), TrustFixtures.file_of(fractional_format, [root]))
	UpdateFixtures.remove(store)
	var signature_reason := _refusal_reason(_load(first, store), TrustFixtures.envelope(decoded, good_signatures + [true]))
	UpdateFixtures.remove(store)
	var without_them := _offer(_load(first, store), TrustFixtures.envelope(decoded, good_signatures))
	UpdateFixtures.remove(store)
	testing.eq(format_reason, "the document's format is not 1", "a format of 1.5 → refused")
	testing.eq(Marshalls.base64_to_raw(str(true)).size(), 3, "the boolean's text decodes as base64")
	testing.eq(signature_reason, "a signature is not a string", "a good signature beside that boolean → refused")
	testing.eq(without_them, TrustChain.ACCEPTED, "the document with neither → accepted")
	print("")


# A chain fresh from the first document takes `file_bytes` or not, on an empty store.
static func _edge_outcome(file_bytes: PackedByteArray) -> String:
	var store := _store("edges")
	var outcome := _offer(_load(TrustFixtures.first_document([TrustFixtures.release_key()]), store), file_bytes)
	UpdateFixtures.remove(store)
	return outcome


static func _test_edges(testing: Testing) -> void:
	testing.begin("Trust chain: the file and signature limits, at and past the edge")
	var root := TrustFixtures.root_key()
	var document := TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, [TrustFixtures.release_key()]), [root])
	var decoded := JSON.stringify(TrustFixtures.body(2, [root], 1, [TrustFixtures.release_key()])).to_utf8_buffer()
	var good := TrustFixtures.signatures_over(decoded, [root])

	var at_limit := document.duplicate()
	at_limit.resize(TrustChain.MAX_FILE_BYTES)
	at_limit.fill(0x20)
	for index: int in document.size():
		at_limit[index] = document[index]
	var past_limit := at_limit.duplicate()
	past_limit.append(0x20)

	var filler := PackedByteArray()
	filler.resize(256)
	var filler_signature := Marshalls.raw_to_base64(filler)
	var fifteen_more := []
	for _index: int in 15:
		fifteen_more.append(filler_signature)

	var largest := PackedByteArray()
	largest.resize(TrustChain.MAX_SIGNATURE_BYTES)
	var too_large := largest.duplicate()
	too_large.append(0)

	var at_file_limit := _edge_outcome(at_limit)
	var past_file_limit := _edge_outcome(past_limit)
	var at_count := _edge_outcome(TrustFixtures.envelope(decoded, good + fifteen_more))
	var past_count := _edge_outcome(TrustFixtures.envelope(decoded, good + fifteen_more + [filler_signature]))
	var at_size := _edge_outcome(TrustFixtures.envelope(decoded, good + [Marshalls.raw_to_base64(largest)]))
	var past_size := _edge_outcome(TrustFixtures.envelope(decoded, good + [Marshalls.raw_to_base64(too_large)]))

	testing.eq(TrustChain.MAX_FILE_BYTES, 1048576, "the file limit stays 1 MiB")
	testing.eq(TrustChain.MAX_SIGNATURES, 16, "the signature count stays 16")
	testing.eq(TrustChain.MAX_SIGNATURE_BYTES, 4096, "the signature size stays 4096")
	testing.eq(TrustChain.MAX_DOCUMENTS_PER_WALK, 32, "the walk stays 32 documents")
	testing.eq(ReleaseSignature.MAX_BYTES, 4096, "the manifest's signature limit is the same one")
	testing.eq(at_file_limit, TrustChain.ACCEPTED, "a file of exactly 1 MiB → accepted")
	testing.eq(past_file_limit, TrustChain.INVALID, "one byte more → refused")
	testing.eq(at_count, TrustChain.ACCEPTED, "16 signatures → accepted")
	testing.eq(past_count, TrustChain.INVALID, "17 signatures → refused")
	testing.eq(at_size, TrustChain.ACCEPTED, "a signature of 4096 bytes → accepted")
	testing.eq(past_size, TrustChain.INVALID, "a signature of 4097 bytes → refused")
	print("")


static func _test_outer_file_formatting(testing: Testing) -> void:
	testing.begin("Trust chain: CRLF in the outer file changes nothing")
	var root := TrustFixtures.root_key()
	var decoded := JSON.stringify(TrustFixtures.body(2, [root], 1, [TrustFixtures.release_key()])).to_utf8_buffer()
	var pretty := JSON.stringify({
		"document": Marshalls.raw_to_base64(decoded),
		"signatures": TrustFixtures.signatures_over(decoded, [root]),
	}, "\t").replace("\n", "\r\n")
	testing.ok(pretty.contains("\r\n"), "the file has CRLF line ends")
	testing.eq(_edge_outcome(pretty.to_utf8_buffer()), TrustChain.ACCEPTED, "it is accepted")
	print("")


# The signatures vouch for the bytes, and Godot's JSON keeps the last duplicate key, so the
# checks and the result must read the one dictionary.
static func _test_duplicate_key(testing: Testing) -> void:
	testing.begin("Trust chain: a duplicate key is read as Godot's JSON reads it, once")
	var root := TrustFixtures.root_key()
	var previous := TrustChain.read_embedded(TrustFixtures.first_document([TrustFixtures.release_key()]))
	var body := JSON.stringify(TrustFixtures.body(2, [root], 1, [TrustFixtures.next_release_key()]))
	var last_wins := body.trim_suffix("}") + ",\"version\":9}"
	var first_wrong := "{\"version\":9," + body.trim_prefix("{")
	var refused := TrustChain.read_next(previous, TrustFixtures.signed_file(last_wins.to_utf8_buffer(), [root]))
	var read := TrustChain.read_next(previous, TrustFixtures.signed_file(first_wrong.to_utf8_buffer(), [root]))
	testing.eq(refused, {"error": "the document's version is not 2"}, "the last version counts: 9 → refused")
	testing.eq(read.get("version"), 2, "an earlier 9 before the last 2 → read as 2")
	print("")


static func _test_empty_release_keys(testing: Testing) -> void:
	testing.begin("Trust chain: empty release keys are accepted and trust nothing")
	var root := TrustFixtures.root_key()
	var manifest := "any release".to_utf8_buffer()
	var signature := _signed_by(TrustFixtures.release_key(), manifest)
	var store := _store("empty_release")
	var source := {"trust_document": TrustFixtures.first_document([TrustFixtures.release_key()]), "trust_store": store}
	var before := ReleaseSignature.is_trusted(manifest, signature, null, source)
	var chain := ReleaseSignature.chain(source)
	var outcome := _offer(chain, TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, []), [root]))
	var keys := chain.release_keys()
	var after := ReleaseSignature.is_trusted(manifest, signature, null, source)
	UpdateFixtures.remove(store)
	testing.ok(before, "before it, the key is trusted")
	testing.eq(outcome, TrustChain.ACCEPTED, "the emergency stop is accepted")
	testing.eq(keys, [], "the chain lists no release key")
	testing.ok(not after, "and trusts nothing")
	print("")


static func _test_embedded(testing: Testing) -> void:
	testing.begin("Trust chain: an embedded document the reader would refuse reads as empty")
	var root := TrustFixtures.root_key()
	var release := TrustFixtures.release_key()
	var manifest := "a release".to_utf8_buffer()
	var signature := _signed_by(release, manifest)
	var store := _store("embedded")
	# A valid next document, so a row that wrongly read as a chain would walk on to it.
	_write_to_store(store, 2, TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, [release]), [root]))
	var rows := [
		["empty", ""],
		["not JSON", "not json"],
		["a threshold of 0", TrustFixtures.file_of(TrustFixtures.body(1, [root], 0, [release]), [root]).get_string_from_utf8()],
		["a threshold above the roots", TrustFixtures.file_of(TrustFixtures.body(1, [root], 2, [release]), [root]).get_string_from_utf8()],
		["empty root_keys", TrustFixtures.file_of(TrustFixtures.body(1, [], 1, [release]), [root]).get_string_from_utf8()],
		["a version of 0", TrustFixtures.file_of(TrustFixtures.body(0, [root], 1, [release]), [root]).get_string_from_utf8()],
		["a version that is text", TrustFixtures.file_of(TrustFixtures.body("1", [root], 1, [release]), [root]).get_string_from_utf8()],
	]
	var results := []
	for row: Array in rows:
		var chain := _load(row[1], store)
		var printed := Engine.print_error_messages
		Engine.print_error_messages = false
		var trusted := ReleaseSignature.is_trusted(manifest, signature, null, {"trust_document": row[1], "trust_store": store})
		Engine.print_error_messages = printed
		results.append({
			"label": row[0],
			"version": chain.version(),
			"next_version": chain.next_version(),
			"release_keys": chain.release_keys(),
			"outcome": _offer(chain, _read_from_store(store, 2)),
			"trusted": trusted,
		})
	var read_empty := TrustChain.read_embedded("")
	var unsigned := TrustFixtures.file_of(TrustFixtures.body(1, [root], 1, [release]), []).get_string_from_utf8()
	var chain := _load(unsigned, store)
	var version_walked := chain.version()
	var trusted_unsigned := ReleaseSignature.is_trusted(manifest, signature, null, {"trust_document": unsigned, "trust_store": store})
	UpdateFixtures.remove(store)
	for result: Dictionary in results:
		testing.eq(result["version"], 0, "%s → no chain" % result["label"])
		testing.eq(result["next_version"], 0, "%s → no walk" % result["label"])
		testing.eq(result["release_keys"], [], "%s → no key" % result["label"])
		testing.eq(result["outcome"], TrustChain.NOT_EXPECTED, "%s → takes no document" % result["label"])
		testing.ok(not result["trusted"], "%s → the release is not trusted" % result["label"])
	testing.eq(read_empty, {"error": "there is no document"}, "empty → read_embedded says there is no document")
	testing.eq(version_walked, 2, "signatures are not checked on it, and the walk starts from it")
	testing.ok(trusted_unsigned, "the release key it leads to is trusted")
	print("")


static func _test_self_signed(testing: Testing) -> void:
	testing.begin("Trust chain: a first document held to its own roots")
	var root := TrustFixtures.root_key()
	var second := TrustFixtures.second_root_key()
	var release := TrustFixtures.release_key()
	var signed := TrustChain.read_self_signed(TrustFixtures.file_of(TrustFixtures.body(1, [root], 1, [release]), [root]))
	var unsigned := TrustChain.read_self_signed(TrustFixtures.file_of(TrustFixtures.body(1, [root], 1, [release]), []))
	var by_stranger := TrustChain.read_self_signed(TrustFixtures.file_of(TrustFixtures.body(1, [root], 1, [release]), [second]))
	var short := TrustChain.read_self_signed(TrustFixtures.file_of(TrustFixtures.body(1, [root, second], 2, [release]), [root]))
	testing.eq(signed["error"], "", "signed by its root → read")
	testing.eq(signed["version"], 1, "the result carries the version the document lists")
	testing.eq(signed["root_threshold"], 1, "and the threshold it lists")
	testing.eq(signed["release_keys"], [UpdateFixtures.public_pem(release)], "its release keys, as listed")
	testing.eq(unsigned, {"error": "too few of the document's own root keys signed it"}, "unsigned → refused")
	testing.eq(by_stranger, {"error": "too few of the document's own root keys signed it"}, "signed by a stranger → refused")
	testing.eq(short, {"error": "too few of the document's own root keys signed it"}, "below its own threshold → refused")
	print("")


static func _test_store_tampered(testing: Testing) -> void:
	testing.begin("Trust chain: a tampered file is ignored and refetched")
	var root := TrustFixtures.root_key()
	var first := TrustFixtures.first_document([TrustFixtures.release_key()])
	var document := TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, [TrustFixtures.next_release_key()]), [root])
	var store := _store("tampered")
	var intact_version := 0
	if _offer(_load(first, store), document) == TrustChain.ACCEPTED:
		intact_version = _load(first, store).version()
	# The real file's signatures over a document that lists another key.
	var genuine_bytes := JSON.stringify(TrustFixtures.body(2, [root], 1, [TrustFixtures.next_release_key()])).to_utf8_buffer()
	var other_bytes := JSON.stringify(TrustFixtures.body(2, [root], 1, [TrustFixtures.second_root_key()])).to_utf8_buffer()
	_write_to_store(store, 2, TrustFixtures.envelope(other_bytes, TrustFixtures.signatures_over(genuine_bytes, [root])))
	var chain := _load(first, store)
	var version_with_tampered := chain.version()
	var keys_with_tampered := chain.release_keys()
	var next_with_tampered := chain.next_version()
	var outcome := _offer(chain, document)
	var restored := _read_from_store(store, 2) == document
	var version_after := _load(first, store).version()
	UpdateFixtures.remove(store)
	testing.eq(intact_version, 2, "the file as written loads")
	testing.eq(version_with_tampered, 1, "tampered, the walk stops before it")
	testing.eq(keys_with_tampered, [UpdateFixtures.public_pem(TrustFixtures.release_key())], "and its keys count for nothing")
	testing.eq(next_with_tampered, 2, "the chain asks for it again")
	testing.eq(outcome, TrustChain.ACCEPTED, "the real document is accepted")
	testing.ok(restored, "and overwrites the tampered file")
	testing.eq(version_after, 2, "the next load reaches it")
	print("")


static func _test_store_tampered_past_a_good_file(testing: Testing) -> void:
	testing.begin("Trust chain: a tampered file past a good one stops the walk at the good one")
	var root := TrustFixtures.root_key()
	var first := TrustFixtures.first_document([TrustFixtures.release_key()])
	var third := TrustFixtures.body(3, [root], 1, [TrustFixtures.release_key()])
	var store := _store("tampered_past_good")
	_write_to_store(store, 2, TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, [TrustFixtures.next_release_key()]), [root]))
	_write_to_store(store, 3, TrustFixtures.file_of(third, [root]))
	var intact_version := _load(first, store).version()
	# The real file's signatures over a document that lists another key.
	var other_bytes := JSON.stringify(TrustFixtures.body(3, [root], 1, [TrustFixtures.second_root_key()])).to_utf8_buffer()
	_write_to_store(store, 3, TrustFixtures.envelope(other_bytes, TrustFixtures.signatures_over(JSON.stringify(third).to_utf8_buffer(), [root])))
	var chain := _load(first, store)
	var version_with_tampered := chain.version()
	var keys_with_tampered := chain.release_keys()
	var next_with_tampered := chain.next_version()
	UpdateFixtures.remove(store)
	testing.eq(intact_version, 3, "the files as written load to 3")
	testing.eq(version_with_tampered, 2, "tampered trust-3 → the walk stops at 2, not at the embedded document")
	testing.eq(keys_with_tampered, [UpdateFixtures.public_pem(TrustFixtures.next_release_key())], "with trust-2's keys")
	testing.eq(next_with_tampered, 3, "and asks for 3")
	print("")


static func _test_store_deleted(testing: Testing) -> void:
	testing.begin("Trust chain: a deleted file falls back and walks again")
	var root := TrustFixtures.root_key()
	var first := TrustFixtures.first_document([TrustFixtures.release_key()])
	var document := TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, [TrustFixtures.next_release_key()]), [root])
	var store := _store("deleted")
	# The offer's result is dropped: version_stored shows whether the file landed.
	_offer(_load(first, store), document)
	var version_stored := _load(first, store).version()
	UpdateFixtures.remove(store)
	var chain := _load(first, store)
	var version_deleted := chain.version()
	var keys_deleted := chain.release_keys()
	var next_deleted := chain.next_version()
	var outcome := _offer(chain, document)
	var version_after := _load(first, store).version()
	UpdateFixtures.remove(store)
	testing.eq(version_stored, 2, "with the file, the load reaches it")
	testing.eq(version_deleted, 1, "without it, the embedded document stands")
	testing.eq(keys_deleted, [UpdateFixtures.public_pem(TrustFixtures.release_key())], "with its keys")
	testing.eq(next_deleted, 2, "the chain asks for it again")
	testing.eq(outcome, TrustChain.ACCEPTED, "and takes it")
	testing.eq(version_after, 2, "the next load reaches it")
	print("")


static func _test_store_gap(testing: Testing) -> void:
	testing.begin("Trust chain: the first gap ends the walk")
	var root := TrustFixtures.root_key()
	var release := TrustFixtures.release_key()
	var first := TrustFixtures.first_document([release])
	var store := _store("gap")
	_write_to_store(store, 2, TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, [release]), [root]))
	_write_to_store(store, 4, TrustFixtures.file_of(TrustFixtures.body(4, [root], 1, [release]), [root]))
	var with_gap := _load(first, store)
	var gap_version := with_gap.version()
	var gap_next := with_gap.next_version()
	UpdateFixtures.remove(store)
	testing.eq(gap_version, 2, "trust-3 missing → the walk stops at 2, past trust-4 unread")
	testing.eq(gap_next, 3, "and asks for 3")
	print("")


static func _test_accept_closes_a_gap(testing: Testing) -> void:
	testing.begin("Trust chain: taking the document a gap lacks walks on through what is stored past it")
	var root := TrustFixtures.root_key()
	var release := TrustFixtures.release_key()
	var store := _store("gap_closed")
	_write_to_store(store, 2, TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, [release]), [root]))
	_write_to_store(store, 3, TrustFixtures.file_of(TrustFixtures.body(3, [root], 1, [release]), [root]))
	_write_to_store(store, 5, TrustFixtures.file_of(TrustFixtures.body(5, [root], 1, [TrustFixtures.next_release_key()]), [root]))
	var chain := _load(TrustFixtures.first_document([release]), store)
	var version_at_gap := chain.version()
	var outcome := _offer(chain, TrustFixtures.file_of(TrustFixtures.body(4, [root], 1, [release]), [root]))
	var version_after := chain.version()
	var next_after := chain.next_version()
	var keys_after := chain.release_keys()
	UpdateFixtures.remove(store)
	testing.eq(version_at_gap, 3, "the walk stops at the gap")
	testing.eq(outcome, TrustChain.ACCEPTED, "the missing document is accepted")
	testing.eq(next_after, 6, "the chain asks past the file it already holds")
	testing.eq(version_after, 5, "it stands on that file")
	testing.eq(keys_after, [UpdateFixtures.public_pem(TrustFixtures.next_release_key())], "with that file's keys")
	print("")


static func _test_store_never_goes_lower(testing: Testing) -> void:
	testing.begin("Trust chain: an embedded document never walks to a lower file")
	var root := TrustFixtures.root_key()
	var release := TrustFixtures.release_key()
	var store := _store("lower")
	_write_to_store(store, 2, TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, [release]), [root]))
	_write_to_store(store, 4, TrustFixtures.file_of(TrustFixtures.body(4, [root], 1, [release]), [root]))
	var at_three := TrustFixtures.file_of(TrustFixtures.body(3, [root], 1, [release]), [root]).get_string_from_utf8()
	var version_from_three := _load(at_three, store).version()
	var at_five := TrustFixtures.file_of(TrustFixtures.body(5, [root], 1, [TrustFixtures.next_release_key()]), [root]).get_string_from_utf8()
	var from_five := _load(at_five, store)
	var version_from_five := from_five.version()
	var keys_from_five := from_five.release_keys()
	UpdateFixtures.remove(store)
	testing.eq(version_from_three, 4, "an embedded 3 reads trust-4 and ignores trust-2")
	testing.eq(version_from_five, 5, "an embedded 5 stays at 5 over lower files")
	testing.eq(keys_from_five, [UpdateFixtures.public_pem(TrustFixtures.next_release_key())], "with its own keys")
	print("")


static func _test_store_oversized(testing: Testing) -> void:
	testing.begin("Trust chain: a stored file over the limit is ignored")
	var root := TrustFixtures.root_key()
	var first := TrustFixtures.first_document([TrustFixtures.release_key()])
	var document := TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, [TrustFixtures.next_release_key()]), [root])
	var padded := document.duplicate()
	padded.resize(TrustChain.MAX_FILE_BYTES + 1)
	padded.fill(0x20)
	for index: int in document.size():
		padded[index] = document[index]
	var store := _store("oversized")
	_write_to_store(store, 2, padded)
	var version_over := _load(first, store).version()
	_write_to_store(store, 2, padded.slice(0, TrustChain.MAX_FILE_BYTES))
	var version_at := _load(first, store).version()
	UpdateFixtures.remove(store)
	testing.eq(version_over, 1, "one byte past the limit → the walk stops before it")
	testing.eq(version_at, 2, "at the limit → read")
	print("")


static func _test_failed_write(testing: Testing) -> void:
	testing.begin("Trust chain: a failed write fails the walk")
	var root := TrustFixtures.root_key()
	var release := TrustFixtures.release_key()
	var first := TrustFixtures.first_document([release])
	var document := TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, [TrustFixtures.next_release_key()]), [root])

	# A file where the store's folder should be.
	var file_as_store := _store("write_file_in_the_way")
	FolderFiles.write_checked(ProjectSettings.globalize_path(file_as_store), "a file".to_utf8_buffer())
	var blocked_folder := _load(first, file_as_store)
	var folder_outcome := _offer(blocked_folder, document)
	var folder_version := blocked_folder.version()
	var folder_keys := blocked_folder.release_keys()
	var folder_reason := _refusal_reason(blocked_folder, document)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(file_as_store))

	# A folder where the file should land: the temporary file writes, the rename cannot.
	var target_store := _store("write_target_in_the_way")
	var target_path := ProjectSettings.globalize_path(target_store)
	DirAccess.make_dir_recursive_absolute(target_path.path_join("trust-2.json"))
	var blocked_rename := _load(first, target_store)
	var rename_outcome := _offer(blocked_rename, document)
	var rename_version := blocked_rename.version()
	var rename_reason := _refusal_reason(blocked_rename, document)
	var leftovers := _store_files(target_store)
	UpdateFixtures.remove(target_store)

	# A folder at this process's temporary name pins that the name carries the process id.
	var temporary_store := _store("write_temporary_in_the_way")
	var temporary_path := ProjectSettings.globalize_path(temporary_store)
	DirAccess.make_dir_recursive_absolute(temporary_path.path_join("trust-2.json.%d.tmp" % OS.get_process_id()))
	var temporary_outcome := _offer(_load(first, temporary_store), document)
	UpdateFixtures.remove(temporary_store)

	testing.eq(folder_outcome, TrustChain.WRITE_FAILED, "a store folder that cannot be made → the write fails")
	testing.eq(folder_reason, "could not write trust-2.json", "and says so, before any read-back")
	testing.eq(folder_version, 1, "the chain stays")
	testing.eq(folder_keys, [UpdateFixtures.public_pem(release)], "with the keys it had")
	testing.eq(rename_outcome, TrustChain.WRITE_FAILED, "a target that cannot be replaced → the write fails")
	testing.eq(rename_reason, "could not write trust-2.json", "and says so, before any read-back")
	testing.eq(rename_version, 1, "the chain stays")
	testing.eq(leftovers, PackedStringArray(), "no temporary file is left")
	testing.eq(temporary_outcome, TrustChain.WRITE_FAILED, "the temporary file is named for this process")
	print("")


static func _test_concurrent_editor(testing: Testing) -> void:
	testing.begin("Trust chain: another editor wrote the document first")
	var root := TrustFixtures.root_key()
	var first := TrustFixtures.first_document([TrustFixtures.release_key()])
	var decoded := JSON.stringify(TrustFixtures.body(2, [root], 1, [TrustFixtures.next_release_key()])).to_utf8_buffer()
	var theirs := TrustFixtures.signed_file(decoded, [root])
	var mine := TrustFixtures.signed_file(decoded, [root, TrustFixtures.second_root_key()])
	var store := _store("concurrent")
	var chain := _load(first, store)
	var before := chain.version()
	_write_to_store(store, 2, theirs)
	var outcome := _offer(chain, mine)
	var kept := _read_from_store(store, 2) == theirs
	var files := _store_files(store)
	var after := chain.version()
	UpdateFixtures.remove(store)
	testing.ok(theirs != mine, "the two files differ")
	testing.eq(before, 1, "this editor loaded before the other wrote")
	testing.eq(outcome, TrustChain.ACCEPTED, "the document is accepted")
	testing.ok(kept, "the verified target is not written over")
	testing.eq(files, PackedStringArray(["trust-2.json"]), "and no temporary file is left")
	testing.eq(after, 2, "the chain moves on")
	print("")


static func _test_no_store(testing: Testing) -> void:
	testing.begin("Trust chain: a folder that is not absolute is no store")
	var root := TrustFixtures.root_key()
	var release := TrustFixtures.release_key()
	var first := TrustFixtures.first_document([release])
	var document := TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, [release]), [root])
	var relative := "update_tests_%d_trust_relative/trust" % OS.get_process_id()
	for folder: String in ["./" + relative, relative, "."]:
		var chain := _load(first, folder)
		testing.ok(not chain.has_store(), "%s → no store" % folder)
		testing.eq(chain.version(), 1, "%s → the embedded document still stands" % folder)
		testing.eq(chain.release_keys(), [UpdateFixtures.public_pem(release)], "%s → with its keys" % folder)
		testing.eq(chain.next_version(), 0, "%s → no walk" % folder)
		testing.eq(_offer(chain, document), TrustChain.NO_STORE, "%s → a document is not taken" % folder)
		testing.ok(not FileAccess.file_exists(folder.path_join("trust-2.json")), "%s → nothing written" % folder)
	testing.ok(not DirAccess.dir_exists_absolute(relative.get_base_dir()), "no folder is made")
	var absolute := _store("no_store_absolute")
	testing.ok(_load(first, absolute).has_store(), "an absolute folder → a store")
	print("")


static func _test_store_folder(testing: Testing) -> void:
	testing.begin("Trust chain: the store is in the OS's data folder")
	testing.eq(TrustChain.store_folder(), OS.get_data_dir().path_join("godot_mcp_toolkit/trust"), "the toolkit's folder under the OS's data folder, whatever the project")
	testing.ok(TrustChain.store_folder().is_absolute_path(), "absolute on a machine that sets HOME or APPDATA")
	print("")


static func _test_walk_limit(testing: Testing) -> void:
	testing.begin("Trust chain: one walk takes 32 documents, and the next load carries on")
	var root := TrustFixtures.root_key()
	var release := TrustFixtures.release_key()
	var first := TrustFixtures.first_document([release])
	var store := _store("walk_limit")
	var chain := _load(first, store)
	var outcomes := {}
	for number: int in range(2, 34):
		var outcome := _offer(chain, TrustFixtures.file_of(TrustFixtures.body(number, [root], 1, [release]), [root]))
		outcomes[outcome] = int(outcomes.get(outcome, 0)) + 1
	var version_at_limit := chain.version()
	var next_at_limit := chain.next_version()
	var document_34 := TrustFixtures.file_of(TrustFixtures.body(34, [root], 1, [release]), [root])
	var past_limit := _offer(chain, document_34)
	var version_past_limit := chain.version()
	var stored_past_limit := FileAccess.file_exists(ProjectSettings.globalize_path(store).path_join("trust-34.json"))
	var resumed := _load(first, store)
	var resumed_version := resumed.version()
	var resumed_next := resumed.next_version()
	var resumed_outcome := _offer(resumed, document_34)
	var total_version := _load(first, store).version()
	UpdateFixtures.remove(store)
	testing.eq(outcomes, {TrustChain.ACCEPTED: 32}, "32 documents → all accepted")
	testing.eq(version_at_limit, 33, "the chain is at the last of them")
	testing.eq(next_at_limit, 0, "nothing more to fetch in this walk")
	testing.eq(past_limit, TrustChain.NOT_EXPECTED, "a 33rd in this walk → not taken")
	testing.eq(version_past_limit, 33, "the chain stays")
	testing.ok(not stored_past_limit, "and nothing is written")
	testing.eq(resumed_version, 33, "a new load reads every stored file")
	testing.eq(resumed_next, 34, "and asks for the next")
	testing.eq(resumed_outcome, TrustChain.ACCEPTED, "and takes it")
	testing.eq(total_version, 34, "so a load has no total limit")
	print("")


static func _test_unknown_field(testing: Testing) -> void:
	testing.begin("Trust chain: a field this reader does not know is ignored")
	var root := TrustFixtures.root_key()
	var release := TrustFixtures.next_release_key()
	var body := TrustFixtures.body(2, [root], 1, [release])
	body["pins"] = {"1.3.0": "a hash"}
	var store := _store("unknown_field")
	var chain := _load(TrustFixtures.first_document([TrustFixtures.release_key()]), store)
	var outcome := _offer(chain, TrustFixtures.file_of(body, [root]))
	var keys := chain.release_keys()
	UpdateFixtures.remove(store)
	testing.eq(outcome, TrustChain.ACCEPTED, "a document with pins → accepted")
	testing.eq(keys, [UpdateFixtures.public_pem(release)], "its release keys are read as ever")
	print("")


static func _test_going_back(testing: Testing) -> void:
	testing.begin("Trust chain: an older release walks to the same document")
	var root := TrustFixtures.root_key()
	var old_release := TrustFixtures.release_key()
	var new_release := TrustFixtures.next_release_key()
	var older := TrustFixtures.first_document([old_release])
	var document_2 := TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, [old_release]), [root])
	var document_3 := TrustFixtures.file_of(TrustFixtures.body(3, [root], 1, [new_release]), [root])
	var manifest := "a release signed by a dropped key".to_utf8_buffer()
	var signature := _signed_by(old_release, manifest)
	var store := _store("going_back")
	var source := {"trust_document": older, "trust_store": store}
	var walker := _load(older, store)
	# The offers' results are dropped: reached shows whether both landed.
	_offer(walker, document_2)
	_offer(walker, document_3)
	var older_chain := ReleaseSignature.chain(source)
	var reached := older_chain.version()
	var keys := older_chain.release_keys()
	var dropped_key_trusted := ReleaseSignature.is_trusted(manifest, signature, null, source)
	UpdateFixtures.remove(store)
	# A machine that only ever saw the newer release's embedded document stored nothing.
	var newer := document_3.get_string_from_utf8()
	var newer_chain := _load(newer, store)
	var newer_version := newer_chain.version()
	var newer_files := _store_files(store)
	var unstored := ReleaseSignature.chain(source)
	var next_unstored := unstored.next_version()
	var taken_2 := _offer(unstored, document_2)
	var taken_3 := _offer(unstored, document_3)
	var fetched_version := unstored.version()
	UpdateFixtures.remove(store)
	testing.eq(reached, 3, "from an older embedded document, the store leads to the current one")
	testing.eq(keys, [UpdateFixtures.public_pem(new_release)], "with the current keys")
	testing.ok(not dropped_key_trusted, "so going back undoes no revocation")
	testing.eq(newer_version, 3, "a newer embedded document reads as itself")
	testing.eq(newer_files, PackedStringArray(), "and stores nothing")
	testing.eq(next_unstored, 2, "so the older release asks from its own document")
	testing.eq(taken_2, TrustChain.ACCEPTED, "takes the first it never stored")
	testing.eq(taken_3, TrustChain.ACCEPTED, "and the next")
	testing.eq(fetched_version, 3, "and reaches the same document")
	print("")


static func _test_outcome_strings(testing: Testing) -> void:
	testing.begin("Trust chain: accept's outcomes keep their strings")
	testing.eq(TrustChain.ACCEPTED, "accepted", "the chain moved on")
	testing.eq(TrustChain.INVALID, "invalid", "the bytes are not the next document")
	testing.eq(TrustChain.WRITE_FAILED, "write_failed", "the document did not reach the disk")
	testing.eq(TrustChain.NO_STORE, "no_store", "the data folder is no store")
	testing.eq(TrustChain.NOT_EXPECTED, "not_expected", "no document can be taken now")
	print("")
