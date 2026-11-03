@tool
extends RefCounted
## Fixture builders the trust chain's tests share: documents and their files made in the run
## with keys made once per run, and one key's PEM in other layouts.

const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

static var _release_key: CryptoKey = null
static var _next_release_key: CryptoKey = null


## The root key most chains start from.
static func root_key() -> CryptoKey:
	return UpdateFixtures.key()


## A second root key.
static func second_root_key() -> CryptoKey:
	return UpdateFixtures.other_key()


## The release key the first document lists.
static func release_key() -> CryptoKey:
	if _release_key == null:
		_release_key = Crypto.new().generate_rsa(2048)
	return _release_key


## The release key a rotation moves to.
static func next_release_key() -> CryptoKey:
	if _next_release_key == null:
		_next_release_key = Crypto.new().generate_rsa(2048)
	return _next_release_key


## The decoded document of [param version]. [param root_keys] and [param release_keys] each
## hold [CryptoKey]s or PEM strings; the version and threshold go in as given, so a test can
## pass a bad one.
static func body(version: Variant, root_keys: Array, threshold: Variant, release_keys: Array) -> Dictionary:
	return {
		"format": 1,
		"version": version,
		"root_keys": pems(root_keys),
		"root_threshold": threshold,
		"release_keys": pems(release_keys),
	}


## The PEM strings of [param keys], which hold [CryptoKey]s or PEM strings already.
static func pems(keys: Array) -> Array:
	var result := []
	for entry: Variant in keys:
		result.append(UpdateFixtures.public_pem(entry) if entry is CryptoKey else entry)
	return result


## A document file holding [param document], signed by each of [param signers].
static func file_of(document: Dictionary, signers: Array) -> PackedByteArray:
	return signed_file(JSON.stringify(document).to_utf8_buffer(), signers)


## A document file holding the bytes [param decoded], signed by each of [param signers].
static func signed_file(decoded: PackedByteArray, signers: Array) -> PackedByteArray:
	return envelope(decoded, signatures_over(decoded, signers))


## A document file holding [param decoded] and the base64 strings in [param signatures].
static func envelope(decoded: PackedByteArray, signatures: Array) -> PackedByteArray:
	return JSON.stringify({"document": Marshalls.raw_to_base64(decoded), "signatures": signatures}).to_utf8_buffer()


## The base64 signature over [param decoded] by each of [param signers].
static func signatures_over(decoded: PackedByteArray, signers: Array) -> Array:
	var signatures := []
	for signer: CryptoKey in signers:
		signatures.append(Marshalls.raw_to_base64(UpdateFixtures.signature_of(decoded, signer)))
	return signatures


## The text of the file of version 1: [param release_keys] under one root, self-signed.
static func first_document(release_keys: Array) -> String:
	return file_of(body(1, [root_key()], 1, release_keys), [root_key()]).get_string_from_utf8()


## [param pem] with CRLF line ends.
static func crlf_layout(pem: String) -> String:
	return pem.strip_edges().replace("\n", "\r\n") + "\r\n"


## [param pem] with its base64 wrapped at 40 columns rather than 64.
static func rewrapped_layout(pem: String) -> String:
	var lines := pem.strip_edges().split("\n")
	var base64 := "".join(lines.slice(1, lines.size() - 1))
	var wrapped := PackedStringArray([lines[0]])
	for start in range(0, base64.length(), 40):
		wrapped.append(base64.substr(start, 40))
	wrapped.append(lines[lines.size() - 1])
	return "\n".join(wrapped) + "\n"
