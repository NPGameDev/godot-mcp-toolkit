@tool
extends RefCounted
## Checks a release manifest's signature against the keys this toolkit trusts.
##
## A release is signed with [code]openssl dgst -sha256 -sign[/code] over the
## manifest's exact bytes: RSA with SHA-256, the form [method Crypto.verify] checks.
## A signature from any key the latest trust document lists counts; see
## [code]trust_chain.gd[/code].

# Direct preloads: core/modules.gd does not list this folder's scripts.
const ContentHash := preload("res://addons/godot_mcp_toolkit/self_update/content_hash.gd")
const EmbeddedTrustDocument := preload("res://addons/godot_mcp_toolkit/self_update/embedded_trust_document.gd")
const TrustChain := preload("res://addons/godot_mcp_toolkit/self_update/trust_chain.gd")

## The largest signature read, in bytes.
const MAX_BYTES := TrustChain.MAX_SIGNATURE_BYTES


## Whether a manifest's bytes and its signature are trusted. Every decision to trust a
## release goes through here, so what makes one trusted can change behind this function
## alone. It reads files and no network, since the exit has none and must not wait.[br]
## [br]
## [param test_keys], an array of PEM keys, replaces the chain; only tests pass it, and no
## input from outside the editor reaches it. [param chain_source] is what [method chain] takes.
static func is_trusted(
		manifest_bytes: PackedByteArray, signature: PackedByteArray,
		test_keys: Variant = null, chain_source: Dictionary = {}) -> bool:
	var keys: Array = test_keys if test_keys != null else chain(chain_source).release_keys()
	return is_valid(manifest_bytes, signature, keys)


## The trust chain as this machine holds it, freshly walked. [param source] replaces what the
## walk reads, for tests: [code]trust_document[/code] (the text of the embedded document) and
## [code]trust_store[/code] (the store folder).
static func chain(source: Dictionary = {}) -> TrustChain:
	return TrustChain.new(
			str(source.get("trust_document", EmbeddedTrustDocument.DOCUMENT)),
			str(source.get("trust_store", TrustChain.store_folder())))


## Whether [param signature] is a valid signature over [param message] by one of
## [param trusted_keys], each a PEM public key. A key that does not load counts as
## no key; an empty list accepts nothing.
static func is_valid(message: PackedByteArray, signature: PackedByteArray, trusted_keys: Array) -> bool:
	if signature.is_empty() or signature.size() > MAX_BYTES:
		return false
	var digest := ContentHash.digest(message)
	var crypto := Crypto.new()
	for pem in trusted_keys:
		var key := CryptoKey.new()
		if key.load_from_string(str(pem), true) != OK:
			continue
		if crypto.verify(HashingContext.HASH_SHA256, digest, signature, key):
			return true
	return false
