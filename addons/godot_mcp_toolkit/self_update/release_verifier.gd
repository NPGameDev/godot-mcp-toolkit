@tool
extends Node
## Fetches what proves a release trusted: the trust documents this machine lacks, then the
## release's manifest and its signature.
##
## [method walk] fetches the trust documents one at a time from the release it is to verify,
## until a 404 or the chain's cap for one walk, and emits [signal walked] once the latest
## document lists a release key.
## [method fetch] then fetches the manifest and its signature, and emits [signal verified]
## when a key the walked chain lists signed it and the manifest parses. A step that fails
## emits [signal failed] and ends the run. One run goes at a time, and [method cancel] stops it
## with no signal.[br]
## [br]
## Every URL is built from the version, and a trust document's from its number too (see
## [code]release_assets.gd[/code]), and a reply can redirect it only to the hosts
## [code]update_downloader.gd[/code] allows.

## Emitted when a walk ends with a chain whose latest document lists a release key.
signal walked
## Emitted when the manifest's bytes arrive, before its signature is checked.
signal manifest_received(manifest_bytes: PackedByteArray)
## Emitted when the signature checks out and the manifest parses: [param manifest] is what
## [method ReleaseManifest.parse] returns and [param signature] the signature's bytes.
signal verified(manifest: Dictionary, signature: PackedByteArray)
## Emitted when a step fails: [param kind] is one of [code]update_check_failure.gd[/code]'s
## kinds, and [param reason] says what failed, for the install log.
signal failed(kind: String, reason: String)

# Direct preloads, not core/modules.gd: the aggregator preloads the installer,
# which reaches this file.
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")
const UpdateCheckFailure := preload("res://addons/godot_mcp_toolkit/self_update/update_check_failure.gd")
const UpdateDownloader := preload("res://addons/godot_mcp_toolkit/self_update/update_downloader.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const ReleaseManifest := preload("res://addons/godot_mcp_toolkit/self_update/release_manifest.gd")
const ReleaseSignature := preload("res://addons/godot_mcp_toolkit/self_update/release_signature.gd")
const TrustChain := preload("res://addons/godot_mcp_toolkit/self_update/trust_chain.gd")

# Which reply the downloader waits for.
const _WAITING_NONE := 0
const _WAITING_TRUST_DOCUMENT := 1
const _WAITING_MANIFEST := 2
const _WAITING_SIGNATURE := 3

# What ReleaseSignature.chain and ReleaseSignature.is_trusted read.
var _options: Dictionary = {}
var _timeout_sec: float = 0.0
var _downloader: UpdateDownloader = null
var _waiting: int = _WAITING_NONE
var _version: String = ""
var _manifest_bytes := PackedByteArray()
# The chain the running walk moves along; its cap counts per instance.
var _walk: TrustChain = null


## Why the fetch that ended with [param outcome] failed, for the install log:
## [param outcome] is what [signal UpdateDownloader.finished] carries.
static func fetch_problem(outcome: Dictionary) -> String:
	var refusal := str(outcome["refusal"])
	return refusal if not refusal.is_empty() else "the download failed (result %d, HTTP %d)" % [int(outcome["result"]), int(outcome["code"])]


## [param options] replaces what the trust chain reads, in the shape
## [method ReleaseSignature.chain] takes. [param timeout_sec] bounds each request.
func _init(options: Dictionary, timeout_sec: float) -> void:
	_options = options
	_timeout_sec = timeout_sec


func _ready() -> void:
	_downloader = UpdateDownloader.new()
	_downloader.finished.connect(_on_fetched)
	add_child(_downloader)


## The store folder of the walk that is running or failed last, which a
## [constant UpdateCheckFailure.STORE_WRITE] message names; an empty string once a walk has
## ended in [signal walked] or [method cancel] ran.
func store() -> String:
	return _walk.store() if _walk != null else ""


## Starts a walk of the trust chain from the documents this machine holds, fetching the
## ones it lacks from the release of [param version], the release to verify.
func walk(version: String) -> void:
	_version = version
	_walk = ReleaseSignature.chain(_options)
	if not _walk.has_store():
		failed.emit(UpdateCheckFailure.NO_DATA_FOLDER, "the data folder is not an absolute path")
		return
	_fetch_next_document()


## Starts fetching the manifest and the signature of [param version].
func fetch(version: String) -> void:
	_version = version
	_send(ReleaseAssets.manifest_name(_version), _WAITING_MANIFEST, ReleaseManifest.MAX_BYTES)


## Stops a walk or a fetch that is running.
func cancel() -> void:
	if _downloader != null:
		_downloader.cancel()
	_waiting = _WAITING_NONE
	_walk = null


func _fetch_next_document() -> void:
	var number := _walk.next_version()
	if number == 0:
		_end_walk()
		return
	var url := ReleaseAssets.trust_document_url(OS.get_environment(UpdateCheck.HOST_ENV), _version, number)
	if _downloader.fetch(url, TrustChain.MAX_FILE_BYTES, _timeout_sec) != OK:
		failed.emit(UpdateCheckFailure.UNREACHABLE, "the fetch of trust document %d could not start" % number)
		return
	_waiting = _WAITING_TRUST_DOCUMENT


func _on_trust_document(outcome: Dictionary) -> void:
	if bool(outcome["ok"]):
		var accepted := _walk.accept(outcome["body"])
		if str(accepted["outcome"]) == TrustChain.ACCEPTED:
			_fetch_next_document()
		else:
			failed.emit(UpdateCheckFailure.of_accept(str(accepted["outcome"])), str(accepted["reason"]))
	elif UpdateCheckFailure.is_missing(outcome):
		_end_walk()
	else:
		failed.emit(UpdateCheckFailure.of_fetch(outcome), fetch_problem(outcome))


func _end_walk() -> void:
	if _walk.release_keys().is_empty():
		failed.emit(UpdateCheckFailure.SECURITY, "the latest trust document lists no release key")
		return
	_walk = null
	walked.emit()


func _send(asset: String, waiting: int, size_limit: int) -> void:
	var url := ReleaseAssets.download_url(OS.get_environment(UpdateCheck.HOST_ENV), _version, asset)
	var error := _downloader.fetch(url, size_limit, _timeout_sec)
	_waiting = waiting if error == OK else _WAITING_NONE
	if error != OK:
		failed.emit(UpdateCheckFailure.UNREACHABLE, "the download could not start (error %d)" % error)


func _on_fetched(outcome: Dictionary) -> void:
	var waiting := _waiting
	_waiting = _WAITING_NONE
	if waiting == _WAITING_TRUST_DOCUMENT:
		_on_trust_document(outcome)
		return
	if not bool(outcome["ok"]):
		failed.emit(UpdateCheckFailure.of_release_file(outcome), fetch_problem(outcome))
		return
	match waiting:
		_WAITING_MANIFEST:
			_manifest_bytes = outcome["body"]
			manifest_received.emit(_manifest_bytes)
			_send(ReleaseAssets.signature_name(_version), _WAITING_SIGNATURE, ReleaseSignature.MAX_BYTES)
		_WAITING_SIGNATURE:
			_on_signature(outcome["body"])


func _on_signature(signature: PackedByteArray) -> void:
	if not ReleaseSignature.is_trusted(_manifest_bytes, signature, null, _options):
		failed.emit(UpdateCheckFailure.SECURITY, "version %s is not signed by a trusted key" % _version)
		return
	var manifest := ReleaseManifest.parse(_manifest_bytes.get_string_from_utf8(), _version)
	if not str(manifest["error"]).is_empty():
		failed.emit(UpdateCheckFailure.SECURITY, str(manifest["error"]))
		return
	verified.emit(manifest, signature)
