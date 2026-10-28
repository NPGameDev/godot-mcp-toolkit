@tool
extends RefCounted
## Unit tests for the manifest signature check: a signature made in the run, one made
## by openssl (the release script's tool) over a fixed manifest, a tampered message,
## an untrusted key, and a key list.

const ReleaseSignature := preload("res://addons/godot_mcp_toolkit/update/release_signature.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

# Made with `openssl dgst -sha256 -sign` over _OPENSSL_MESSAGE by the key whose public
# half is below; the private half was discarded.
const _OPENSSL_PUBLIC_KEY := """-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwNu0OXU0D9wbjLNisCRY
BvLsK8ivq1Gdj18cN6qXzKgU1xb/mZGnvRSkSBX2RYQpe8vgwgBqhCgh7RjtuN6Q
vlIpq3KnTlWMd0O29QiqJqNTAP2Y5YBA+N3w8OtJXxSYzmlZkyW3myjqJctKn6mF
qKZWkNfvYkLCN25D5uDbyWQ+DiHrDRP4O0DbckhZ7PrSx9DGnBVndnjsdHl8HJR8
RuczvEPfxkCnrP0MbBbutMpy4GAe9hZDMA/UZjIolDevlBA3KIEMX7mNpU3r7+mG
q3daOSdyEojf2MFg1vzlBUfad2X+pnqPKl4VwIt4SnXH82ExaLWV5yr5UDKPCSCb
oQIDAQAB
-----END PUBLIC KEY-----
"""
const _OPENSSL_MESSAGE := "{\"format\": 1, \"version\": \"1.2.0\", \"archive\": \"godot-mcp-toolkit-1.2.0.zip\", \"archive_size\": 734482, \"archive_sha256\": \"3370a7ff44d61ecd5519ab44ccd866d68644c4b099de1e85e5fad913dbdd12f8\", \"min_godot\": \"4.2\"}\n"
const _OPENSSL_SIGNATURE := "Sba5fSItkcKvaCG4xz4r3TymOX2gxgzlLiUK9aftiSf2LDQNShdKbx2UjHv1XvTKUhXZHAr3PpRxaLnOh1E8e1ogjUIsz/mqc2tr4NUQBQ2Jf6Y9xt4eTDVJdTg3S28Qju0b5VpWaWYKjSz6Y6l+E0o5FwwLeWcc/YnFpq0wAnSPQFDCUjV8O8NALvB5mbvUQtT7QIYAJqYhez/1q1nnfSEFpEteb3DfWMM6oJj+6MOq7tZNsgzzPwkJf9ZC6ABScid4aL4vEIa8QJGGabB5+0ENJFNDWRckeVjGTiwzBIFI2yQHFVBAB5rdch9UXY7RdhHllPTiRPYBGlMjkbqL3A=="


static func run(testing) -> void:
	_test_run_key(testing)
	_test_openssl_interop(testing)
	_test_key_list(testing)


static func _test_run_key(testing) -> void:
	testing.begin("Release signature: a key made in the run")
	var message := "the manifest".to_utf8_buffer()
	var signature := UpdateFixtures.signature_of(message, UpdateFixtures.key())
	var trusted := [UpdateFixtures.public_pem(UpdateFixtures.key())]
	testing.ok(ReleaseSignature.is_valid(message, signature, trusted), "its signature over the message → valid")
	testing.ok(not ReleaseSignature.is_valid("the manifest!".to_utf8_buffer(), signature, trusted),
			"the same signature over a changed message → invalid")
	testing.ok(not ReleaseSignature.is_valid(message, signature, [UpdateFixtures.public_pem(UpdateFixtures.other_key())]),
			"a key that did not sign → invalid")
	print("")


static func _test_openssl_interop(testing) -> void:
	testing.begin("Release signature: a signature openssl made")
	var signature := Marshalls.base64_to_raw(_OPENSSL_SIGNATURE)
	testing.ok(ReleaseSignature.is_valid(_OPENSSL_MESSAGE.to_utf8_buffer(), signature, [_OPENSSL_PUBLIC_KEY]),
			"openssl dgst -sha256 -sign over the manifest → valid")
	testing.ok(not ReleaseSignature.is_valid(_OPENSSL_MESSAGE.replace("734482", "734483").to_utf8_buffer(), signature, [_OPENSSL_PUBLIC_KEY]),
			"a manifest with one digit changed → invalid")
	print("")


static func _test_key_list(testing) -> void:
	testing.begin("Release signature: any trusted key counts")
	var message := "rotated".to_utf8_buffer()
	var signature := UpdateFixtures.signature_of(message, UpdateFixtures.key())
	var both := [UpdateFixtures.public_pem(UpdateFixtures.other_key()), UpdateFixtures.public_pem(UpdateFixtures.key())]
	testing.ok(ReleaseSignature.is_valid(message, signature, both), "the second key of two signed → valid")
	testing.ok(not ReleaseSignature.is_valid(message, signature, []), "no trusted key → invalid")
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var with_garbage := ReleaseSignature.is_valid(message, signature, ["not a key", UpdateFixtures.public_pem(UpdateFixtures.key())])
	Engine.print_error_messages = printed
	testing.ok(with_garbage, "an unreadable key beside the signing one → valid")
	print("")

