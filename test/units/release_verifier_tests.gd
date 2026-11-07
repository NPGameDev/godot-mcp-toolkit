@tool
extends RefCounted
## Unit tests for release_verifier.gd through its methods and signals, against a loopback
## listener: a walk that ends trusted and the verify after it, each step that fails and the kind
## it fails with, a walk that cannot start, and a cancelled fetch.

const Testing := preload("res://test/units/testing.gd")
const ReleaseVerifier := preload("res://addons/godot_mcp_toolkit/self_update/release_verifier.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")
const TrustFixtures := preload("res://test/units/trust_fixtures.gd")

const _VERSION := "1.9.0"
const _FRAME_LIMIT := 2400
# A request reaches the listener well inside these, as the rows that do make one show.
const _QUIET_FRAMES := 120
# Long enough that no row here ends in a timeout.
const _TIMEOUT_SEC := 30.0


static func run(testing: Testing, tree: SceneTree) -> void:
	# The verifier's _ready runs only once the tree's root is live.
	await tree.process_frame
	await _test_walk_then_verify(testing, tree)
	await _test_refused_document(testing, tree)
	await _test_walk_to_no_release_key(testing, tree)
	await _test_no_data_folder(testing, tree)
	await _test_signature_by_an_unlisted_key(testing, tree)
	await _test_manifest_not_published(testing, tree)
	await _test_cancel(testing, tree)


static func _document(version: int, release_keys: Array) -> PackedByteArray:
	return TrustFixtures.file_of(
			TrustFixtures.body(version, [TrustFixtures.root_key()], 1, release_keys),
			[TrustFixtures.root_key()])


static func _release(signing_key: CryptoKey) -> Dictionary:
	return UpdateFixtures.release_assets(_VERSION, {"core/a.gd": "new"}, signing_key)


static func _document_name(version: int) -> String:
	return ReleaseAssets.trust_document_name(version)


# A verifier on a chain whose embedded document lists UpdateFixtures.key() and whose store is
# a scratch folder, in `tree`.
static func _start(purpose: String, tree: SceneTree, store: String = "") -> ReleaseVerifier:
	var options := {
		"trust_document": TrustFixtures.first_document([UpdateFixtures.key()]),
		"trust_store": store if not store.is_empty()
				else UpdateFixtures.scratch("verifier_" + purpose + "_trust"),
	}
	var verifier := ReleaseVerifier.new(options, _TIMEOUT_SEC)
	tree.root.add_child(verifier)
	return verifier


# Records every signal `verifier` emits, in order, as [name, arguments...].
static func _record(verifier: ReleaseVerifier) -> Array:
	var events := []
	verifier.walked.connect(func() -> void: events.append(["walked"]))
	verifier.manifest_received.connect(
			func(bytes: PackedByteArray) -> void: events.append(["manifest_received", bytes]))
	verifier.verified.connect(
		func(manifest: Dictionary, signature: PackedByteArray) -> void:
			events.append(["verified", manifest, signature])
	)
	verifier.failed.connect(
			func(kind: String, reason: String) -> void: events.append(["failed", kind, reason]))
	return events


static func _names_of(events: Array) -> Array:
	var names := []
	for event: Array in events:
		names.append(event[0])
	return names


# The kind `events[at]` carries when it is a failed event, else an empty string.
static func _failed_kind(events: Array, at: int) -> String:
	if events.size() <= at or str(events[at][0]) != "failed":
		return ""
	return str(events[at][1])


# Whether an event past the first `already` recorded ends a step: walked, verified or failed.
static func _ended(events: Array, already: int) -> bool:
	if events.size() <= already:
		return false
	var last: Array = events[-1]
	return str(last[0]) != "manifest_received"


# Serves `server` each frame until an event past the first `already` in `events` ends a step.
# Returns whether one did in time.
static func _poll_until_ended(
		events: Array, server: UpdateFixtures.LoopbackReleaseServer, tree: SceneTree,
		already: int = 0) -> bool:
	var frames := 0
	while not _ended(events, already) and frames < _FRAME_LIMIT:
		server.poll()
		await tree.process_frame
		frames += 1
	return frames < _FRAME_LIMIT


static func _poll_frames(server: UpdateFixtures.LoopbackReleaseServer, tree: SceneTree) -> void:
	for _frame: int in range(_QUIET_FRAMES):
		server.poll()
		await tree.process_frame


# What `server` was asked for, by file name, in order.
static func _asked(server: UpdateFixtures.LoopbackReleaseServer) -> Array:
	var names := []
	for path: String in server.paths():
		names.append(path.get_file())
	return names


# Whether the one HTTPRequest under `verifier` has closed its connection, as a cancelled
# request does.
static func _connection_closed(verifier: ReleaseVerifier) -> bool:
	var requests := verifier.find_children("*", "HTTPRequest", true, false)
	if requests.size() != 1:
		return false
	var request: HTTPRequest = requests[0]
	return request.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED


static func _end(verifier: ReleaseVerifier, server: UpdateFixtures.LoopbackReleaseServer,
		previous_host: String, purpose: String) -> void:
	verifier.free()
	server.stop()
	UpdateFixtures.restore_host(previous_host)
	UpdateFixtures.remove(UpdateFixtures.scratch("verifier_" + purpose + "_trust"))


# Walks, then fetches `_VERSION` once the walk ends in walked. Returns the events recorded, what
# the listener was asked for, whether each step ended in time, and whether the walk stored
# trust document 2.
static func _measure_walk_and_fetch(
		purpose: String, assets: Dictionary, tree: SceneTree) -> Dictionary:
	var server := UpdateFixtures.LoopbackReleaseServer.new(assets)
	var previous_host := UpdateFixtures.set_host(server.host())
	var verifier := _start(purpose, tree)
	var events := _record(verifier)
	verifier.walk()
	var measured := {
		"walk_on_time": await _poll_until_ended(events, server, tree),
		"fetch_on_time": true,
	}
	if _names_of(events) == ["walked"]:
		verifier.fetch(_VERSION)
		measured["fetch_on_time"] = await _poll_until_ended(events, server, tree, 1)
	var store := UpdateFixtures.scratch("verifier_" + purpose + "_trust")
	measured["stored"] = FileAccess.file_exists(store.path_join(_document_name(2)))
	measured["asked"] = _asked(server)
	_end(verifier, server, previous_host, purpose)
	measured["events"] = events
	return measured


static func _test_walk_then_verify(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Release verifier: a walk takes documents until a 404, and the release they "
			+ "trust verifies")
	# Only the walk trusts this release's key, since the embedded document lists another.
	var assets := _release(UpdateFixtures.other_key())
	assets[_document_name(2)] = _document(2, [UpdateFixtures.other_key()])
	var measured: Dictionary = await _measure_walk_and_fetch("verifies", assets, tree)
	var events: Array = measured["events"]
	testing.ok(measured["walk_on_time"] and measured["fetch_on_time"],
			"the walk and the fetch end in time")
	testing.eq(_names_of(events), ["walked", "manifest_received", "verified"],
			"walked, then the manifest's bytes, then verified, once each")
	testing.eq(measured["asked"], [_document_name(2), _document_name(3),
			ReleaseAssets.manifest_name(_VERSION), ReleaseAssets.signature_name(_VERSION)],
			"the documents first, then the manifest and signature")
	testing.ok(measured["stored"], "the document the walk took reaches the store")
	if _names_of(events) == ["walked", "manifest_received", "verified"]:
		var manifest_bytes: PackedByteArray = assets[ReleaseAssets.manifest_name(_VERSION)]
		testing.eq(events[1][1], manifest_bytes, "manifest_received carries the manifest's bytes")
		var manifest: Dictionary = events[2][1]
		testing.eq(manifest.get("error"), "", "verified carries the manifest, parsed with no error")
		testing.eq(manifest.get("version"), "1.9.0", "for the version fetched")
		testing.eq(events[2][2], assets[ReleaseAssets.signature_name(_VERSION)],
				"and the signature's bytes")
	print("")


static func _test_refused_document(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Release verifier: a document the chain refuses fails the walk on the security "
			+ "check")
	var assets := _release(UpdateFixtures.key())
	assets[_document_name(2)] = "not a document".to_utf8_buffer()
	var measured: Dictionary = await _measure_walk_and_fetch("refused", assets, tree)
	var events: Array = measured["events"]
	testing.ok(measured["walk_on_time"], "the walk ends in time")
	testing.eq(_names_of(events), ["failed"], "failed once, and nothing else")
	testing.eq(_failed_kind(events, 0), "security", "with the security check's kind")
	testing.ok(_names_of(events) == ["failed"] and not str(events[0][2]).is_empty(),
			"and a reason for the log")
	testing.eq(measured["asked"], [_document_name(2)], "the walk stops at the refused document")
	testing.ok(not measured["stored"], "nothing reaches the store")
	print("")


static func _test_walk_to_no_release_key(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Release verifier: a walk ending on a document with no release key fails on the "
			+ "security check")
	var assets := _release(UpdateFixtures.key())
	assets[_document_name(2)] = _document(2, [])
	var measured: Dictionary = await _measure_walk_and_fetch("no_release_key", assets, tree)
	var events: Array = measured["events"]
	testing.ok(measured["walk_on_time"], "the walk ends in time")
	testing.eq(_names_of(events), ["failed"], "failed once, and never walked")
	testing.eq(_failed_kind(events, 0), "security", "with the security check's kind")
	testing.eq(measured["asked"], [_document_name(2), _document_name(3)],
			"only the chain is asked for")
	print("")


static func _test_no_data_folder(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Release verifier: a walk with no data folder fails before any request")
	var server := UpdateFixtures.LoopbackReleaseServer.new(
			{_document_name(2): _document(2, [UpdateFixtures.key()])})
	var previous_host := UpdateFixtures.set_host(server.host())
	var verifier := _start("no_store", tree, ".")
	var events := _record(verifier)
	verifier.walk()
	var at_call := _names_of(events)
	var kind := _failed_kind(events, 0)
	await _poll_frames(server, tree)
	var requests := server.connections()
	var total := _names_of(events)
	_end(verifier, server, previous_host, "no_store")
	testing.eq(at_call, ["failed"], "the call itself → failed once")
	testing.eq(kind, "no_data_folder", "with the no-data-folder kind")
	testing.eq(total, ["failed"], "and nothing after it")
	testing.eq(requests, 0, "no request at the listener")
	print("")


static func _test_signature_by_an_unlisted_key(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Release verifier: a release signed by a key the chain does not list fails on "
			+ "the security check")
	var measured: Dictionary = await _measure_walk_and_fetch(
			"unlisted", _release(UpdateFixtures.other_key()), tree)
	var events: Array = measured["events"]
	testing.ok(measured["walk_on_time"] and measured["fetch_on_time"],
			"the walk and the fetch end in time")
	testing.eq(_names_of(events), ["walked", "manifest_received", "failed"],
			"walked, then the manifest's bytes, then failed, and never verified")
	testing.eq(_failed_kind(events, 2), "security", "with the security check's kind")
	print("")


static func _test_manifest_not_published(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Release verifier: a release with no manifest yet fails as not ready")
	var assets := _release(UpdateFixtures.key())
	assets.erase(ReleaseAssets.manifest_name(_VERSION))
	var measured: Dictionary = await _measure_walk_and_fetch("not_ready", assets, tree)
	var events: Array = measured["events"]
	testing.ok(measured["walk_on_time"] and measured["fetch_on_time"],
			"the walk and the fetch end in time")
	testing.eq(_names_of(events), ["walked", "failed"],
			"walked, then failed, with no manifest received")
	testing.eq(_failed_kind(events, 1), "not_ready", "with the not-ready kind")
	testing.eq(measured["asked"], [_document_name(2), ReleaseAssets.manifest_name(_VERSION)],
			"and no signature is asked for")
	print("")


# The listener hangs up on the held request once it stops, which a fetch still running reports
# as failed. That report can come later than the quiet frames, so the closed connection is
# what shows the cancel reached the request.
static func _test_cancel(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Release verifier: a cancelled fetch emits nothing")
	var server := UpdateFixtures.LoopbackReleaseServer.new(_release(UpdateFixtures.key()))
	server.hold("/" + ReleaseAssets.manifest_name(_VERSION))
	var previous_host := UpdateFixtures.set_host(server.host())
	var verifier := _start("cancel", tree)
	var events := _record(verifier)
	verifier.fetch(_VERSION)
	var frames := 0
	while server.paths().is_empty() and frames < _FRAME_LIMIT:
		server.poll()
		await tree.process_frame
		frames += 1
	var held := not server.paths().is_empty()
	verifier.cancel()
	var closed := _connection_closed(verifier)
	server.stop()
	for _frame: int in range(_QUIET_FRAMES):
		await tree.process_frame
	var recorded := _names_of(events)
	verifier.free()
	UpdateFixtures.restore_host(previous_host)
	UpdateFixtures.remove(UpdateFixtures.scratch("verifier_cancel_trust"))
	testing.ok(held, "the manifest's request reaches the listener in time")
	testing.ok(closed, "cancel → the request's connection is closed")
	testing.eq(recorded, [], "cancel, then the listener hanging up → no signal")
	print("")
