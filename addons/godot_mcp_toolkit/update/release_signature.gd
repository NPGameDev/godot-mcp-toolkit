@tool
extends RefCounted
## Checks a release manifest's signature against the trusted public keys.
##
## A release is signed with [code]openssl dgst -sha256 -sign[/code] over the
## manifest's exact bytes: RSA with SHA-256, the form [method Crypto.verify] checks.
## A signature from any trusted key counts, so a key can be rotated by a release that
## trusts both the old and the new one.

# Direct preload, not core/modules.gd: the aggregator preloads this file.
const ContentHash := preload("res://addons/godot_mcp_toolkit/update/content_hash.gd")

## The largest signature read, in bytes: an RSA-4096 signature is 512.
const MAX_BYTES := 4096


## Whether [param signature] is a valid signature over [param message] by one of
## [param public_keys], each a PEM public key. A key that does not load counts as
## no key; an empty list accepts nothing.
static func is_valid(message: PackedByteArray, signature: PackedByteArray, public_keys: Array) -> bool:
	if signature.is_empty() or signature.size() > MAX_BYTES:
		return false
	var digest := ContentHash.digest(message)
	var crypto := Crypto.new()
	for pem in public_keys:
		var key := CryptoKey.new()
		if key.load_from_string(str(pem), true) != OK:
			continue
		if crypto.verify(HashingContext.HASH_SHA256, digest, signature, key):
			return true
	return false
