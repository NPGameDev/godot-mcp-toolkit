@tool
extends RefCounted
## Which keys may sign a release today: the chain of trust documents from the one this
## release embeds to the latest one this machine holds.
##
## A document names its root keys, how many of them must sign the next document, and its
## release keys. Each later document is signed by a threshold of the roots before it and a
## threshold of its own, and a key is trusted only while the latest document lists it, so a
## rotation and a leak are the same act.[br]
## [br]
## A file is [code]{"document": "<base64>", "signatures": ["<base64>", ...]}[/code]. The
## signatures cover the decoded bytes, which hold [code]{"format": 1, "version": N,
## "root_keys": [pem, ...], "root_threshold": T, "release_keys": [pem, ...]}[/code]; a field
## this reader does not know is ignored.[br]
## [br]
## An instance walks from the embedded document through the store folder, verifying every
## file again, so a stored file can never add trust: the first one missing or invalid ends
## the walk, and a later fetch overwrites it. The folder is per machine, because a revocation
## is a fact about the keys, not a project. Nothing here reaches the network: the owner of the
## fetch asks [method next_version] and hands the reply to [method accept].[br]
## [br]
## A client that stays on a release keeps its copy of this script for good, so the format and
## the caps below can never change.

# Direct preloads: core/modules.gd does not list this folder's scripts.
const ContentHash := preload("res://addons/godot_mcp_toolkit/self_update/content_hash.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const ReleaseManifest := preload("res://addons/godot_mcp_toolkit/self_update/release_manifest.gd")

## The one format, never bumped: a bump would strand every client that stays on this
## release, so what is new goes in a field of its own. [code]root_keys[/code] and
## [code]release_keys[/code] stay lists of PEM strings for good: any other entry in
## [code]root_keys[/code] refuses the document, and one in [code]release_keys[/code] is no key.
const FORMAT := 1

## The largest document file read, in bytes. Permanent.
const MAX_FILE_BYTES := 1024 * 1024

## The most signatures a document file may hold. Permanent.
const MAX_SIGNATURES := 16

## The largest signature read, in bytes: an RSA-4096 signature is 512. Permanent.
const MAX_SIGNATURE_BYTES := 4096

## The most documents one instance accepts, so one check stays short. The next load reads
## them all and carries on, so there is no total limit. Permanent.
const MAX_DOCUMENTS_PER_WALK := 32

## The outcome of [method accept] when the chain moved on.
const ACCEPTED := "accepted"

## The outcome of [method accept] when the bytes are not the next document.
const INVALID := "invalid"

## The outcome of [method accept] when the bytes are the next document and did not reach the
## disk, or did not read back from it.
const WRITE_FAILED := "write_failed"

## The outcome of [method accept] when the data folder is no store.
const NO_STORE := "no_store"

## The outcome of [method accept] when no document can be taken now, since there is no chain
## or this walk is full.
const NOT_EXPECTED := "not_expected"

const _STORE_SUBFOLDER := "godot_mcp_toolkit/trust"
# What _read_body takes when the version has nothing to follow.
const _ANY_VERSION := 0

# The latest document: what the read_* functions return. Empty when there is no chain.
var _current := {}
var _store := ""
var _accepted_count := 0


## The folder this machine keeps its documents in, in the OS's data folder rather than
## [code]user://[/code], which follows the project's name, or EditorSettings, which follows
## Godot's minor version.
static func store_folder() -> String:
	return OS.get_data_dir().path_join(_STORE_SUBFOLDER)


## Reads a document file the way an embedded one is read: without verifying its signatures,
## which the release's own signature stands in for, and without a version to follow.
##
## Returns what [method read_next] returns.
static func read_embedded(file_text: String) -> Dictionary:
	if file_text.is_empty():
		return _failure("there is no document")
	var envelope := _read_envelope(file_text.to_utf8_buffer())
	if not str(envelope["error"]).is_empty():
		return envelope
	return _read_body(envelope["decoded"], _ANY_VERSION)


## Reads a document file with no document before it, holding it to its own roots: the first
## document of a chain, and a release's embedded one when a test checks what the run time
## forgives.
##
## Returns what [method read_next] returns.
static func read_self_signed(file_bytes: PackedByteArray) -> Dictionary:
	var envelope := _read_envelope(file_bytes)
	if not str(envelope["error"]).is_empty():
		return envelope
	return _held_to_own_roots(_read_body(envelope["decoded"], _ANY_VERSION), envelope)


## Reads [param file_bytes] as the document after [param previous], a result of one of the
## [code]read_*[/code] functions. Nothing inside the document is read before the previous
## roots have vouched for it.
##
## Returns a dictionary whose [code]error[/code] is empty when the document holds, with
## [code]version[/code] (int), [code]root_keys[/code] (one loaded [CryptoKey] per distinct
## key), [code]root_threshold[/code] (int) and [code]release_keys[/code] (the PEM strings as
## listed; one that does not load counts as no key where it is checked). When it does not
## hold, [code]error[/code] names the first rule broken and no other key is set.
static func read_next(previous: Dictionary, file_bytes: PackedByteArray) -> Dictionary:
	var envelope := _read_envelope(file_bytes)
	if not str(envelope["error"]).is_empty():
		return envelope
	if _count_signing_roots(previous["root_keys"], envelope) < int(previous["root_threshold"]):
		return _failure("too few of the previous document's root keys signed it")
	return _held_to_own_roots(_read_body(envelope["decoded"], int(previous["version"]) + 1), envelope)


# Two editors can reach the same document, and its content never changes, so each writes its
# own temporary file. The caller skips a target that verifies, since a Windows rename removes
# the target first.
static func _write(target: String, file_bytes: PackedByteArray) -> bool:
	var temporary := "%s.%d.tmp" % [target, OS.get_process_id()]
	var written := FolderFiles.write_checked(temporary, file_bytes) and DirAccess.rename_absolute(temporary, target) == OK
	if not written and FileAccess.file_exists(temporary):
		DirAccess.remove_absolute(temporary)
	return written


# Reads one byte past the limit at most, which the reader refuses, so a huge file costs no
# more than a refused one. Empty when the file cannot be read.
static func _read_file(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var bytes := file.get_buffer(mini(file.get_length(), MAX_FILE_BYTES + 1))
	file.close()
	return bytes


# The outer file: the decoded document's bytes and the decoded signatures, or a failure.
# base64_to_raw answers bad input with an empty array, so an empty decode refuses the file.
static func _read_envelope(file_bytes: PackedByteArray) -> Dictionary:
	if file_bytes.size() > MAX_FILE_BYTES:
		return _failure("the file is larger than %d bytes" % MAX_FILE_BYTES)
	var json := JSON.new()
	if json.parse(file_bytes.get_string_from_utf8()) != OK or not json.data is Dictionary:
		return _failure("the file is not a JSON object")
	var outer: Dictionary = json.data
	var encoded_document: Variant = outer.get("document", null)
	var encoded_signatures: Variant = outer.get("signatures", null)
	if not encoded_document is String or not encoded_signatures is Array:
		return _failure("the file does not hold a document and its signatures")
	var signature_list: Array = encoded_signatures
	if signature_list.size() > MAX_SIGNATURES:
		return _failure("the file holds more than %d signatures" % MAX_SIGNATURES)
	var decoded := Marshalls.base64_to_raw(str(encoded_document))
	if decoded.is_empty():
		return _failure("the document does not decode")
	var signatures: Array[PackedByteArray] = []
	for encoded: Variant in signature_list:
		if not encoded is String:
			return _failure("a signature is not a string")
		var signature := Marshalls.base64_to_raw(str(encoded))
		if signature.is_empty():
			return _failure("a signature does not decode")
		if signature.size() > MAX_SIGNATURE_BYTES:
			return _failure("a signature is larger than %d bytes" % MAX_SIGNATURE_BYTES)
		signatures.append(signature)
	return {"error": "", "decoded": decoded, "signatures": signatures}


# Reads the decoded bytes once: Godot's JSON keeps the last duplicate key, so every check and
# the result must read one dictionary. expected_version is the version the document must
# carry, or _ANY_VERSION.
static func _read_body(decoded: PackedByteArray, expected_version: int) -> Dictionary:
	var json := JSON.new()
	if json.parse(decoded.get_string_from_utf8()) != OK or not json.data is Dictionary:
		return _failure("the document is not a JSON object")
	var body: Dictionary = json.data
	var format: Variant = body.get("format", null)
	if not ReleaseManifest.is_whole_number(format) or int(format) != FORMAT:
		return _failure("the document's format is not %d" % FORMAT)
	var document_version: Variant = body.get("version", null)
	if not ReleaseManifest.is_whole_number(document_version):
		return _failure("the document's version is not a whole number")
	if expected_version == _ANY_VERSION:
		if int(document_version) < 1:
			return _failure("the document's version is below 1")
	elif int(document_version) != expected_version:
		return _failure("the document's version is not %d" % expected_version)

	var root_pems: Variant = body.get("root_keys", null)
	var roots: Array = _load_distinct_keys(root_pems) if root_pems is Array else []
	if roots.is_empty():
		return _failure("the document's root keys are empty or do not load")
	var threshold: Variant = body.get("root_threshold", null)
	if not ReleaseManifest.is_whole_number(threshold) or int(threshold) < 1 or int(threshold) > roots.size():
		return _failure("the document's root threshold is not between 1 and its distinct root keys")
	var listed_release_keys: Variant = body.get("release_keys", null)
	if not listed_release_keys is Array:
		return _failure("the document's release keys are not a list")
	return {
		"error": "",
		"version": int(document_version),
		"root_keys": roots,
		"root_threshold": int(threshold),
		"release_keys": listed_release_keys,
	}


static func _held_to_own_roots(document: Dictionary, envelope: Dictionary) -> Dictionary:
	if not str(document["error"]).is_empty():
		return document
	if _count_signing_roots(document["root_keys"], envelope) < int(document["root_threshold"]):
		return _failure("too few of the document's own root keys signed it")
	return document


# One loaded key per distinct key, or nothing when any does not load. Keys compare by their
# re-encoded form within a run and that form is never persisted, so a later engine's
# formatting cannot invalidate a store.
static func _load_distinct_keys(pems: Array) -> Array:
	var distinct := {}
	for pem: Variant in pems:
		if not pem is String:
			return []
		var key := CryptoKey.new()
		if key.load_from_string(str(pem), true) != OK:
			return []
		distinct[key.save_to_string(true)] = key
	return distinct.values()


static func _count_signing_roots(roots: Array, envelope: Dictionary) -> int:
	var digest := ContentHash.digest(envelope["decoded"])
	var signatures: Array[PackedByteArray] = envelope["signatures"]
	var crypto := Crypto.new()
	var count := 0
	for root: CryptoKey in roots:
		for signature: PackedByteArray in signatures:
			if crypto.verify(HashingContext.HASH_SHA256, digest, signature, root):
				count += 1
				break
	return count


static func _failure(reason: String) -> Dictionary:
	return {"error": reason}


static func _outcome(outcome: String, reason: String) -> Dictionary:
	return {"outcome": outcome, "reason": reason}


## Walks from [param embedded_document], the text of a document file, through the folder
## [param store]. An embedded document [method read_embedded] refuses means no chain, no walk
## and no trusted key. A folder that is not absolute is no store, and nothing reads or
## writes it.
func _init(embedded_document: String, store: String) -> void:
	# With no HOME or APPDATA the data folder is ".", the working directory, which could be
	# the project. This check is true for any string holding ":/", and "." is what it must
	# catch.
	if store.is_absolute_path():
		_store = ProjectSettings.globalize_path(store)
	var embedded := read_embedded(embedded_document)
	if not str(embedded["error"]).is_empty():
		return
	_current = embedded
	if has_store():
		_walk_store()


## Whether this machine has a usable store. Without one the chain ends at the embedded
## document, and the user needs to hear what to set.
func has_store() -> bool:
	return not _store.is_empty()


## The absolute folder documents are written to, empty without a store.
func store() -> String:
	return _store


## The version of the latest document, or 0 when there is no chain.
func version() -> int:
	return int(_current.get("version", 0))


## The version to fetch next, or 0 when none can be taken: no chain, no store, or this walk
## is full.
func next_version() -> int:
	if _current.is_empty() or not has_store() or _accepted_count >= MAX_DOCUMENTS_PER_WALK:
		return 0
	return version() + 1


## The PEM keys a release may be signed by today. Empty with no chain, and when the latest
## document lists none, which is the emergency stop on all updates.
func release_keys() -> Array:
	var keys: Array = _current.get("release_keys", [])
	return keys


## Takes [param file_bytes] as the next document. It counts only once it is on disk and has
## been read back and verified, or the exit, which has no network, could not verify from it.
## The chain then walks on through whatever the store already holds past it.
##
## Returns [code]{"outcome": String, "reason": String}[/code]. [code]outcome[/code] is
## [constant ACCEPTED] when the chain moved on; otherwise the chain stays where it was and
## [code]reason[/code] says why, for a log.
func accept(file_bytes: PackedByteArray) -> Dictionary:
	if _current.is_empty():
		return _outcome(NOT_EXPECTED, "there is no chain")
	if not has_store():
		return _outcome(NO_STORE, "the data folder is not an absolute path")
	if _accepted_count >= MAX_DOCUMENTS_PER_WALK:
		return _outcome(NOT_EXPECTED, "this walk took its %d documents" % MAX_DOCUMENTS_PER_WALK)
	var document := read_next(_current, file_bytes)
	if not str(document["error"]).is_empty():
		return _outcome(INVALID, str(document["error"]))
	var target := _store.path_join(ReleaseAssets.trust_document_name(int(document["version"])))
	var already_stored := str(read_next(_current, _read_file(target))["error"]).is_empty()
	if not already_stored and not _write(target, file_bytes):
		return _outcome(WRITE_FAILED, "could not write %s" % target.get_file())
	var stored := read_next(_current, _read_file(target))
	if not str(stored["error"]).is_empty():
		return _outcome(WRITE_FAILED, "%s did not read back: %s" % [target.get_file(), stored["error"]])
	_current = stored
	_accepted_count += 1
	# This document may have been the store's gap, and next_version must not ask for a file
	# that is already here. What the walk reads costs no fetch, so it does not count.
	_walk_store()
	return _outcome(ACCEPTED, "")


func _walk_store() -> void:
	while true:
		var path := _store.path_join(ReleaseAssets.trust_document_name(version() + 1))
		if not FileAccess.file_exists(path):
			return
		var document := read_next(_current, _read_file(path))
		if not str(document["error"]).is_empty():
			return
		_current = document
