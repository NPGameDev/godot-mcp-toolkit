@tool
extends RefCounted
## Unit tests for the trust chain's reader on documents scripts/trust-document.sh made: a
## rotation, a leak, a change of roots, a threshold of 2 and RSA-4096, on every engine version.
## The documents are under test/fixtures/trust/, made by the tool's build and sign.

const Testing := preload("res://test/units/testing.gd")
const TrustChain := preload("res://addons/godot_mcp_toolkit/self_update/trust_chain.gd")
const ReleaseSignature := preload("res://addons/godot_mcp_toolkit/self_update/release_signature.gd")
const TrustFolderCheck := preload("res://test/units/trust_folder_check.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")
const TrustFixtures := preload("res://test/units/trust_fixtures.gd")

const _FIXTURES := "res://test/fixtures/trust"

# Made with `openssl dgst -sha256 -sign` over _MANIFEST by the release keys the documents list;
# every private half was discarded.
const _MANIFEST := "the manifest of a later release\n"
const _SIGNED_BY_FIRST_RELEASE := "pw4w1JlRzs2OPYp+UowWR2trwA8TBfSCRu5+yFbX09M/oh2OTuoYX758WDKHwGQ9wzOery4tcb1C+XDMOiZbHDMRKNqYXwz6UpwV8lmsNzJpesHTzese/NbWi577eZV+byCo3is9+qkea0dSLu2znjAqd/txwiH1eew7jGP7t4zP2Qnqf8Aup6M0W5GtuC/y5XVyGPvTdaqdCrRmZgLiO2Ns3fGudVZ1JbZDfqzkvfRyWmVb12hv71nCZiXjN1oEsx/1nzV+f9ANp+lxh58WUzdEn1B9LDuDEyjZAPWM5RP8mlkR7CP866zG78LKmqqQydXR+EwIOfbXGsOJlAD++A=="
const _SIGNED_BY_NEXT_RELEASE := "7EJUlVImMksUvVAYwIfLGnuQhJ7XXgw/wzJcx9lU5hjgUGu+di/PivYWeEXmNhW6UGssa7utROGrbSknyFcgU4xS+qPyL2EjrVWgfKbqsQ7HTSfe+qYZJiE9rcoYsg6uzYk1GW68Kgfj0OrbqNXJ4yM1mwYgE2HFZkZbt8IoSXhdYRaRKtLERk/qp+4WtpzQ4MMrN8KDznih3JEnI8PykVSKYACS6ruf15z4IffTduWKcHAM/2v7CAVLoEc/fX9IwZmuBfWs39J8it4GP3RsoL4a16NE+y/ban41ttHQkHMKAlK2KVFjCnyKALZin9noK1tEKb9YyGIIs78zfjEeng=="
const _SIGNED_BY_LARGE_RELEASE := "K3diasvC+HNoWs2vdRZpM3KTDWE5vqOtxlp3JZMgv7KdE2F549LTuvDb08CCV7OncvfRAlVfonKpePgEnhrfwtcb5cdyKWn1DqzL5pgkRane0va+aONpB0N9pp5V9ixMqbdT8ydAiKYPCqdojSZ5om75OUSouCvKzXnkR4aVxLy1l65rQUfOjb/n+l7rtGv0PPYEZpKcz6jj0D2CLMytlByAfXZ741BrfJsuT6K1zOxRVkebOJHvz3OQyq7inlbGOTfc9mcMT71ZOuzZdIpiwXtwx895e6cY/okz5SEyXtmH9ojjbSPGKtvCWsLa+ojhdfp3LKRl3TMBrBwuHpu5gOsl0zAW/s8gAvAhuslpCy4JXM1h6l1btMM0InARAaZZTknxS4b9Q4pNTwX3cURtrV735H574j6xADwEeKbesIS023ny7sLmrJ8K62b+RDO3D3ADXL29dbnj4PY0m+2vwpbjhHoh2l5VoOI6vraW/UL7q+3kbd3x+q8wBpj3Gd/6NnfKtTUB7vHa69h6kZZ+BGjWYBEr1Pc19jQtfj2myx0lS95Vpd8Z/zrYvoX5sui4v3/oIzusd+3qx75VJotHKfTuyL82FqvAXbLt4gApapUOoOxmu7gly2igMvUXRy/er9mvmcsg3qafVERVqJuyTwtt+gxOkrXIWrfsMt35CNE="


static func run(testing: Testing) -> void:
	_test_folders_walk(testing)
	_test_rotation(testing)
	_test_leak(testing)
	_test_root_change(testing)
	_test_two_of_two(testing)
	_test_rsa_4096(testing)


static func _test_folders_walk(testing: Testing) -> void:
	testing.begin("Trust pinned: each folder the tool made walks")
	for folder_name: String in ["one_root", "two_of_two", "rsa_4096"]:
		var problems := TrustFolderCheck.folder_problems(_FIXTURES.path_join(folder_name))
		testing.eq("; ".join(problems), "", "%s walks from its first document" % folder_name)
	print("")


static func _test_rotation(testing: Testing) -> void:
	testing.begin("Trust pinned: a rotation reaches a release signed by the new key")
	var store := _store("rotation")
	var source := {"trust_document": _text("one_root", 1), "trust_store": store}
	var manifest := _MANIFEST.to_utf8_buffer()
	var signature := Marshalls.base64_to_raw(_SIGNED_BY_NEXT_RELEASE)
	var before := ReleaseSignature.is_trusted(manifest, signature, null, source)
	var outcome := str(ReleaseSignature.chain(source).accept(_file("one_root", 2))["outcome"])
	var after := ReleaseSignature.is_trusted(manifest, signature, null, source)
	var changed := ReleaseSignature.is_trusted("changed".to_utf8_buffer(), signature, null, source)
	UpdateFixtures.remove(store)
	testing.ok(not before, "before it sees the document, the new key is not trusted")
	testing.eq(outcome, TrustChain.ACCEPTED, "it takes the tool's next document")
	testing.ok(after, "after it, the new key is trusted")
	testing.ok(not changed, "and a changed manifest is not")
	print("")


static func _test_leak(testing: Testing) -> void:
	testing.begin("Trust pinned: a leaked key is refused once the document is seen")
	var store := _store("leak")
	var source := {"trust_document": _text("one_root", 1), "trust_store": store}
	var manifest := _MANIFEST.to_utf8_buffer()
	var signature := Marshalls.base64_to_raw(_SIGNED_BY_FIRST_RELEASE)
	var before := ReleaseSignature.is_trusted(manifest, signature, null, source)
	var outcome := str(ReleaseSignature.chain(source).accept(_file("one_root", 2))["outcome"])
	var after := ReleaseSignature.is_trusted(manifest, signature, null, source)
	UpdateFixtures.remove(store)
	testing.ok(before, "before it sees the document, the old key is trusted")
	testing.eq(outcome, TrustChain.ACCEPTED, "it takes the document that drops the key")
	testing.ok(not after, "after it, the old key is refused")
	print("")


static func _test_root_change(testing: Testing) -> void:
	testing.begin("Trust pinned: a change of roots needs the old and the new")
	var second := TrustChain.read_next(TrustChain.read_self_signed(_file("one_root", 1)), _file("one_root", 2))
	var both := TrustChain.read_next(second, _file("one_root", 3))
	var old_root_only := TrustChain.read_next(second, _with_signatures("one_root", 3, [0]))
	var new_root_only := TrustChain.read_next(second, _with_signatures("one_root", 3, [1]))
	testing.eq(str(second["error"]), "", "the document before it reads")
	testing.eq(str(both["error"]), "", "signed by both, it reads")
	testing.ok(str(old_root_only["error"]).contains("own root keys"), "signed by the old root only, it is refused")
	testing.ok(str(new_root_only["error"]).contains("previous document's root keys"), "signed by the new root only, it is refused")
	print("")


static func _test_two_of_two(testing: Testing) -> void:
	testing.begin("Trust pinned: a threshold of 2")
	var first := TrustChain.read_self_signed(_file("two_of_two", 1))
	var first_alone := TrustChain.read_self_signed(_with_signatures("two_of_two", 1, [0]))
	var both := TrustChain.read_next(first, _file("two_of_two", 2))
	var one_alone := TrustChain.read_next(first, _with_signatures("two_of_two", 2, [1]))
	var one_twice := TrustChain.read_next(first, _with_signatures("two_of_two", 2, [0, 0]))
	testing.eq(str(first["error"]), "", "the first document, signed by both, reads")
	testing.eq(int(first["root_threshold"]), 2, "its threshold is 2")
	testing.ok(not str(first_alone["error"]).is_empty(), "the first document signed by one is refused")
	testing.eq(str(both["error"]), "", "the next document, signed by both, reads")
	testing.ok(not str(one_alone["error"]).is_empty(), "the next document signed by one is refused")
	testing.ok(not str(one_twice["error"]).is_empty(), "one key's signature twice counts once")
	print("")


static func _test_rsa_4096(testing: Testing) -> void:
	testing.begin("Trust pinned: RSA-4096 keys, made by openssl")
	var store := _store("rsa_4096")
	var source := {"trust_document": _text("rsa_4096", 1), "trust_store": store}
	var manifest := _MANIFEST.to_utf8_buffer()
	var signature := Marshalls.base64_to_raw(_SIGNED_BY_LARGE_RELEASE)
	var outer: Dictionary = JSON.parse_string(_text("rsa_4096", 2))
	var signatures: Array = outer["signatures"]
	var root_signature_bytes := Marshalls.base64_to_raw(str(signatures[0])).size()
	var before := ReleaseSignature.is_trusted(manifest, signature, null, source)
	var outcome := str(ReleaseSignature.chain(source).accept(_file("rsa_4096", 2))["outcome"])
	var after := ReleaseSignature.is_trusted(manifest, signature, null, source)
	var changed := ReleaseSignature.is_trusted("changed".to_utf8_buffer(), signature, null, source)
	UpdateFixtures.remove(store)
	testing.eq(root_signature_bytes, 512, "the root's signature is RSA-4096's size")
	testing.eq(signature.size(), 512, "and so is the release key's")
	testing.ok(not before, "the first document does not list the 4096 release key")
	testing.eq(outcome, TrustChain.ACCEPTED, "a 4096 root's signature verifies")
	testing.ok(after, "a 4096 release key's signature verifies")
	testing.ok(not changed, "and fails over a changed manifest")
	print("")


static func _path(folder_name: String, number: int) -> String:
	return _FIXTURES.path_join(folder_name).path_join("trust-%d.json" % number)


static func _file(folder_name: String, number: int) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(_path(folder_name, number))


static func _text(folder_name: String, number: int) -> String:
	return _file(folder_name, number).get_string_from_utf8()


# The pinned file with only the signatures at the given positions, in that order. Its private
# halves are gone, so a document short of a signature can only come from taking one away.
static func _with_signatures(folder_name: String, number: int, positions: Array) -> PackedByteArray:
	var outer: Dictionary = JSON.parse_string(_text(folder_name, number))
	var signatures: Array = outer["signatures"]
	var kept := []
	for position: int in positions:
		kept.append(signatures[position])
	return TrustFixtures.envelope(Marshalls.base64_to_raw(str(outer["document"])), kept)


# An empty scratch folder for a store. The folder itself is not created.
static func _store(purpose: String) -> String:
	var folder := UpdateFixtures.scratch("trust_pinned_" + purpose)
	UpdateFixtures.remove(folder)
	return folder
