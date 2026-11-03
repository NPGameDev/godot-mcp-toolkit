@tool
extends RefCounted
## SHA-256 digests of bytes, as lowercase hex.
##
## The self-update compares every file it writes, the archive it downloads and the
## release file list against these digests; [code]folder_files.gd[/code] reads the
## files.


## The SHA-256 of [param bytes] as 64 lowercase hex characters.
static func of_bytes(bytes: PackedByteArray) -> String:
	return digest(bytes).hex_encode()


## The raw 32-byte SHA-256 of [param bytes], the form [method Crypto.verify] takes.
static func digest(bytes: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	# update() refuses an empty buffer with an engine error; finish() alone yields the
	# empty input's digest.
	if not bytes.is_empty():
		context.update(bytes)
	return context.finish()


## Whether [param text] is a SHA-256 in the form [method of_bytes] returns.
static func is_hex_digest(text: String) -> bool:
	if text.length() != 64:
		return false
	for character in text:
		if "0123456789abcdef".find(character) < 0:
			return false
	return true
