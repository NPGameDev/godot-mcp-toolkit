@tool
extends RefCounted
## Unit tests for the self-update's SHA-256 helpers: the hex digest of bytes, the raw
## digest, and the hex-digest shape check, against the published test vectors.

const ContentHash := preload("res://addons/godot_mcp_toolkit/update/content_hash.gd")
const LogBuffer := preload("res://addons/godot_mcp_toolkit/logging/log_buffer.gd")

const _EMPTY_SHA256 := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
const _ABC_SHA256 := "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"


static func run(testing) -> void:
	_test_digests(testing)
	_test_hex_shape(testing)


static func _test_digests(testing) -> void:
	testing.begin("Content hash: SHA-256 of bytes")
	LogBuffer.setup()
	var cursor: int = LogBuffer.get_cursor() - 1
	testing.eq(ContentHash.of_bytes(PackedByteArray()), _EMPTY_SHA256, "no bytes → the empty-input vector")
	if LogBuffer.uses_logger_api():
		var logged: Dictionary = LogBuffer.get_entries(100, ["error"], cursor)
		testing.eq(int(logged["returned"]), 0, "no bytes → no engine error")
	testing.eq(ContentHash.of_bytes("abc".to_utf8_buffer()), _ABC_SHA256, "\"abc\" → the FIPS 180 vector")
	testing.eq(ContentHash.digest("abc".to_utf8_buffer()).size(), 32, "the raw digest is 32 bytes")
	testing.eq(ContentHash.digest("abc".to_utf8_buffer()).hex_encode(), _ABC_SHA256, "the raw digest is the same SHA-256")
	print("")


static func _test_hex_shape(testing) -> void:
	testing.begin("Content hash: the hex digest shape")
	testing.ok(ContentHash.is_hex_digest(_ABC_SHA256), "64 lowercase hex characters → a digest")
	testing.ok(not ContentHash.is_hex_digest(_ABC_SHA256.to_upper()), "uppercase hex → not a digest")
	testing.ok(not ContentHash.is_hex_digest(_ABC_SHA256.left(63)), "63 characters → not a digest")
	testing.ok(not ContentHash.is_hex_digest(_ABC_SHA256 + "0"), "65 characters → not a digest")
	testing.ok(not ContentHash.is_hex_digest(_ABC_SHA256.left(63) + "g"), "a non-hex character → not a digest")
	testing.ok(not ContentHash.is_hex_digest(""), "empty → not a digest")
	print("")
