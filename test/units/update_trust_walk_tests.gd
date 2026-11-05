@tool
extends RefCounted
## Unit tests for the installer's walk along the trust chain, through a loopback listener: what
## it asks for and in what order, when it asks for nothing, each way a check fails and how a
## click or a new start retries it, the cap on one walk, and a key dropped from under a release
## already kept or staged.

const Testing := preload("res://test/units/testing.gd")
const UpdateInstaller := preload("res://addons/godot_mcp_toolkit/self_update/update_installer.gd")
const UpdateCheckRunner := preload("res://addons/godot_mcp_toolkit/versioning/update_check_runner.gd")
const UpdateCheckFailure := preload("res://addons/godot_mcp_toolkit/self_update/update_check_failure.gd")
const UpdateApplier := preload("res://addons/godot_mcp_toolkit/self_update/update_applier.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const UpdateJournal := preload("res://addons/godot_mcp_toolkit/self_update/update_journal.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")
const TrustFixtures := preload("res://test/units/trust_fixtures.gd")

const _VERSION := "1.9.0"
const _FRAME_LIMIT := 2400
# A request reaches the listener well inside these, as the rows that do make one show.
const _QUIET_FRAMES := 120
const _UNTRUSTED := "the update is not signed by a key this toolkit trusts"
const _NOT_READY_OPENING := "This release isn't ready to install from the editor yet."
const _LOGGED_404 := "(result 0, HTTP 404)"


static func run(testing: Testing, tree: SceneTree) -> void:
	# The installer's _ready runs only once the tree's root is live.
	await tree.process_frame
	await _test_walk_accepts_until_a_404(testing, tree)
	await _test_no_request_when_nothing_is_newer(testing, tree)
	await _test_no_request_with_an_empty_embedded_document(testing, tree)
	await _test_timeout(testing, tree)
	await _test_server_error(testing, tree)
	await _test_rate_limit(testing, tree)
	await _test_tls_failure(testing, tree)
	await _test_off_list_redirect(testing, tree)
	await _test_invalid_document(testing, tree)
	await _test_store_write(testing, tree)
	await _test_no_store(testing, tree)
	await _test_manifest_server_error(testing, tree)
	await _test_manifest_404(testing, tree)
	await _test_signature_404(testing, tree)
	await _test_manifest_500_is_not_a_missing_release(testing, tree)
	await _test_signature_by_an_unlisted_key(testing, tree)
	await _test_emergency_stop_ends_the_check(testing, tree)
	await _test_emergency_stop_can_be_lifted(testing, tree)
	await _test_stale_note_goes_with_the_next_walk(testing, tree)
	await _test_cap_on_one_walk(testing, tree)
	await _test_click_drops_the_key_of_a_kept_release(testing, tree)
	await _test_click_moves_a_kept_release_to_a_new_key(testing, tree)
	_test_key_dropped_found_at_a_start(testing, tree)
	_test_missing_signature_is_no_key_notice(testing, tree)
	_test_key_dropped_found_at_the_exit(testing, tree)


static func _document(version: int, release_keys: Array) -> PackedByteArray:
	return TrustFixtures.file_of(
			TrustFixtures.body(version, [TrustFixtures.root_key()], 1, release_keys), [TrustFixtures.root_key()])


static func _release(signing_key: CryptoKey) -> Dictionary:
	return UpdateFixtures.release_assets(_VERSION, {"core/a.gd": "new"}, signing_key)


static func _document_name(version: int) -> String:
	return ReleaseAssets.trust_document_name(version)


# A world whose store _end can always delete, whatever a test points the installer at.
static func _world(purpose: String, installed: String = "1.1.0") -> Dictionary:
	var world := UpdateFixtures.begin_world("walk_" + purpose, _VERSION, "ask", installed)
	world["scratch_store"] = (world["options"] as Dictionary)["trust_store"]
	return world


static func _end(world: Dictionary, nodes: Dictionary) -> void:
	(world["options"] as Dictionary)["trust_store"] = world["scratch_store"]
	UpdateFixtures.end_world(world, nodes)


static func _store_document(world: Dictionary, version: int, bytes: PackedByteArray) -> void:
	var store := ProjectSettings.globalize_path(str(world["scratch_store"]))
	FolderFiles.write_checked(store.path_join(_document_name(version)), bytes)


static func _set_host(host: String) -> String:
	var previous := OS.get_environment(UpdateFixtures.HOST_ENV)
	OS.set_environment(UpdateFixtures.HOST_ENV, host)
	return previous


static func _restore_host(previous: String) -> void:
	if previous.is_empty():
		OS.unset_environment(UpdateFixtures.HOST_ENV)
	else:
		OS.set_environment(UpdateFixtures.HOST_ENV, previous)


# Serves `servers` each frame until `condition` holds. Returns whether it did in time.
static func _poll_until(condition: Callable, servers: Array, tree: SceneTree) -> bool:
	var frames := 0
	while not bool(condition.call()) and frames < _FRAME_LIMIT:
		for server: UpdateFixtures.LoopbackReleaseServer in servers:
			server.poll()
		await tree.process_frame
		frames += 1
	return frames < _FRAME_LIMIT


static func _poll_frames(servers: Array, tree: SceneTree) -> void:
	for _frame: int in range(_QUIET_FRAMES):
		for server: UpdateFixtures.LoopbackReleaseServer in servers:
			server.poll()
		await tree.process_frame


# What `server` was asked for, by file name, in order.
static func _names(server: UpdateFixtures.LoopbackReleaseServer) -> Array:
	var names := []
	for path: String in server.paths():
		names.append(path.get_file())
	return names


# Starts the installer on `world` and measures a check that fails against `servers`: what it
# leaves, that nothing retries on its own, a click, and a new start. Everything the test made
# is gone when this returns, so the assertions run on the measures.
static func _measure_failed_check(world: Dictionary, servers: Array, host: String, tree: SceneTree) -> Dictionary:
	var server: UpdateFixtures.LoopbackReleaseServer = servers[0]
	var previous_host := _set_host(host)
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var failed := func() -> bool: return installer.check_failed()
	var measured := {"on_time": await _poll_until(failed, servers, tree)}
	measured["state"] = installer.state()
	measured["note"] = installer.note_text()
	measured["can_retry"] = installer.can_retry_check()
	measured["log"] = FileAccess.get_file_as_string(installer.log_path())
	measured["stored"] = FileAccess.file_exists(str(world["scratch_store"]).path_join(_document_name(2)))
	measured["names"] = _names(server)

	var after_failure := server.connections()
	(nodes["runner"] as UpdateCheckRunner).state_changed.emit()
	await _poll_frames(servers, tree)
	measured["unasked_requests"] = server.connections() - after_failure

	var before_click := server.connections()
	installer.install()
	measured["state_on_click"] = installer.state()
	await _poll_until(failed, servers, tree)
	measured["click_requests"] = server.connections() - before_click
	measured["note_after_click"] = installer.note_text()

	(nodes["installer"] as Node).free()
	(nodes["runner"] as Node).free()
	var before_start := server.connections()
	nodes = UpdateFixtures.start_world(world, tree)
	installer = nodes["installer"]
	await _poll_until(func() -> bool: return installer.check_failed(), servers, tree)
	measured["start_requests"] = server.connections() - before_start
	_end(world, nodes)
	for each: UpdateFixtures.LoopbackReleaseServer in servers:
		each.stop()
	_restore_host(previous_host)
	return measured


static func _expect_failed_check(testing: Testing, measured: Dictionary, kind: String) -> void:
	var note := UpdateCheckFailure.message(kind)
	testing.ok(measured["on_time"], "the check fails in time")
	testing.eq(measured["state"], "idle", "and the installer goes idle")
	testing.eq(measured["note"], note, "with the kind's sentence as the note")
	testing.eq(measured["unasked_requests"], 0, "no timer and no report from the runner retries it")
	testing.ok(measured["can_retry"], "a click can retry")
	testing.eq(measured["state_on_click"], "downloading", "a click → the check runs again at once")
	testing.ok(int(measured["click_requests"]) > 0, "with a new request at the listener")
	testing.eq(measured["note_after_click"], note, "and the same sentence when it fails again")
	testing.ok(int(measured["start_requests"]) > 0, "a new start → a new request at the listener")


# How many 404s on a release's own files the install log holds; the chain's own 404 logs nothing.
static func _logged_404s(log_path: String) -> int:
	if not FileAccess.file_exists(log_path):
		return 0
	return FileAccess.get_file_as_string(log_path).count(_LOGGED_404)


# Starts the installer on `world` and measures a start that meets a 404 on the manifest or the
# signature: what it leaves, that nothing retries on its own, and a new start. Everything the test
# made is gone when this returns, so the assertions run on the measures.
static func _measure_unclicked_404(world: Dictionary, server: UpdateFixtures.LoopbackReleaseServer, tree: SceneTree) -> Dictionary:
	var previous_host := _set_host(server.host())
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var log_path := installer.log_path()
	var measured := {"logged": await _poll_until(func() -> bool: return _logged_404s(log_path) == 1, [server], tree)}
	measured["state"] = installer.state()
	measured["note"] = installer.note_text()
	measured["check_failed"] = installer.check_failed()
	measured["can_retry"] = installer.can_retry_check()
	measured["names"] = _names(server)

	var after_failure := server.connections()
	(nodes["runner"] as UpdateCheckRunner).state_changed.emit()
	await _poll_frames([server], tree)
	measured["unasked_requests"] = server.connections() - after_failure

	(nodes["installer"] as Node).free()
	(nodes["runner"] as Node).free()
	var before_start := server.connections()
	nodes = UpdateFixtures.start_world(world, tree)
	await _poll_until(func() -> bool: return _logged_404s(log_path) == 2, [server], tree)
	measured["start_requests"] = server.connections() - before_start
	_end(world, nodes)
	server.stop()
	_restore_host(previous_host)
	return measured


static func _expect_quiet_404(testing: Testing, measured: Dictionary) -> void:
	testing.ok(measured["logged"], "the 404 reaches the log in time")
	testing.eq(measured["state"], "idle", "and the installer goes idle")
	testing.eq(measured["note"], "", "with no note")
	testing.ok(not measured["check_failed"], "and no failed check")
	testing.ok(not measured["can_retry"], "so no click to offer")
	testing.eq(measured["unasked_requests"], 0, "no timer and no report from the runner retries it")


# A 503 on the first document gives the click a failure to retry; the click then meets a listener
# holding `assets`. Everything the test made is gone when this returns.
static func _measure_clicked_404(world: Dictionary, assets: Dictionary, tree: SceneTree) -> Dictionary:
	var failing := UpdateFixtures.LoopbackReleaseServer.new({})
	failing.redirect("/" + _document_name(2), 503, "")
	var missing := UpdateFixtures.LoopbackReleaseServer.new(assets)
	var previous_host := _set_host(failing.host())
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var failed := func() -> bool: return installer.check_failed()
	await _poll_until(failed, [failing], tree)
	_set_host(missing.host())
	installer.install()
	var measured := {"on_time": await _poll_until(failed, [missing], tree)}
	measured["state"] = installer.state()
	measured["note"] = installer.note_text()
	measured["can_retry"] = installer.can_retry_check()
	measured["names"] = _names(missing)
	_end(world, nodes)
	failing.stop()
	missing.stop()
	_restore_host(previous_host)
	return measured


static func _expect_clicked_404(testing: Testing, measured: Dictionary) -> void:
	testing.ok(measured["on_time"], "a click after another failure → the check fails in time")
	testing.eq(measured["state"], "idle", "and the installer goes idle")
	testing.ok(str(measured["note"]).begins_with(_NOT_READY_OPENING), "with the release's own sentence")
	testing.ok(measured["can_retry"], "and a click can retry")


static func _test_walk_accepts_until_a_404(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: documents are taken until a 404, and the release they trust verifies")
	# Only the walk trusts this release's key, since the embedded document lists another.
	var assets := _release(UpdateFixtures.other_key())
	assets[_document_name(2)] = _document(2, [UpdateFixtures.other_key()])
	var server := UpdateFixtures.LoopbackReleaseServer.new(assets)
	var previous_host := _set_host(server.host())
	var world := _world("accepts")
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var on_time: bool = await _poll_until(func() -> bool: return installer.state() == "available", [server], tree)
	var stored := FileAccess.file_exists(str(world["scratch_store"]).path_join(_document_name(2)))
	var note := installer.note_text()
	_end(world, nodes)
	server.stop()
	_restore_host(previous_host)
	testing.ok(on_time, "the rotated key's release verifies in time")
	testing.eq(_names(server), [_document_name(2), _document_name(3), ReleaseAssets.manifest_name(_VERSION),
			ReleaseAssets.signature_name(_VERSION)], "the documents first, then the manifest and signature")
	testing.ok(stored, "the document reaches the store")
	testing.eq(note, "", "and no note is left")
	print("")


static func _test_no_request_when_nothing_is_newer(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: an up-to-date client asks for nothing")
	var assets := _release(UpdateFixtures.key())
	assets[_document_name(2)] = _document(2, [UpdateFixtures.key()])
	var server := UpdateFixtures.LoopbackReleaseServer.new(assets)
	var previous_host := _set_host(server.host())
	var world := _world("current", _VERSION)
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	await _poll_frames([server], tree)
	var at_start := server.connections()
	installer.install()
	await _poll_frames([server], tree)
	var state := installer.state()
	var total := server.connections()
	_end(world, nodes)
	server.stop()
	_restore_host(previous_host)
	testing.eq(at_start, 0, "the start → no request at the listener")
	testing.eq(total, 0, "and a stray click → none either")
	testing.eq(state, "idle", "the installer stays idle")
	print("")


static func _test_no_request_with_an_empty_embedded_document(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: an empty embedded document means no walk")
	var assets := _release(UpdateFixtures.key())
	assets[_document_name(2)] = _document(2, [UpdateFixtures.key()])
	var server := UpdateFixtures.LoopbackReleaseServer.new(assets)
	var previous_host := _set_host(server.host())
	var world := _world("empty_embedded")
	(world["options"] as Dictionary)["trust_document"] = ""
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	await _poll_frames([server], tree)
	var at_start := server.connections()
	installer.install()
	await _poll_frames([server], tree)
	var state := installer.state()
	var note := installer.note_text()
	var total := server.connections()
	_end(world, nodes)
	server.stop()
	_restore_host(previous_host)
	testing.eq(at_start, 0, "the start → no request at the listener")
	testing.eq(total, 0, "and a click → none either")
	testing.eq(state, "idle", "the installer stays idle")
	testing.eq(note, "", "with no note, since nothing failed")
	print("")


static func _test_timeout(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a request nobody answers ends in Couldn't reach GitHub")
	var server := UpdateFixtures.LoopbackReleaseServer.new({})
	server.hold("/" + _document_name(2))
	var world := _world("timeout")
	(world["options"] as Dictionary)["check_timeout_sec"] = 0.2
	var measured: Dictionary = await _measure_failed_check(world, [server], server.host(), tree)
	_expect_failed_check(testing, measured, UpdateCheckFailure.UNREACHABLE)
	print("")


static func _test_server_error(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a 503 ends in GitHub isn't responding")
	var server := UpdateFixtures.LoopbackReleaseServer.new(_release(UpdateFixtures.key()))
	server.redirect("/" + _document_name(2), 503, "")
	var measured: Dictionary = await _measure_failed_check(_world("server_error"), [server], server.host(), tree)
	_expect_failed_check(testing, measured, UpdateCheckFailure.GITHUB_ERROR)
	testing.eq(measured["names"], [_document_name(2)], "and nothing is verified past the failure")
	print("")


static func _test_rate_limit(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a 429 ends in GitHub isn't responding")
	var server := UpdateFixtures.LoopbackReleaseServer.new({})
	server.redirect("/" + _document_name(2), 429, "")
	var measured: Dictionary = await _measure_failed_check(_world("rate_limit"), [server], server.host(), tree)
	_expect_failed_check(testing, measured, UpdateCheckFailure.GITHUB_ERROR)
	print("")


static func _test_tls_failure(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a failed TLS handshake ends in Couldn't reach GitHub")
	var server := UpdateFixtures.LoopbackReleaseServer.new({})
	server.break_handshakes()
	var measured: Dictionary = await _measure_failed_check(
			_world("tls"), [server], server.host().replace("http://", "https://"), tree)
	_expect_failed_check(testing, measured, UpdateCheckFailure.UNREACHABLE)
	testing.ok(str(measured["log"]).contains("(result %d," % HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR),
			"and the engine's result is the failed handshake, which a timeout or a refused connection is not")
	print("")


static func _test_off_list_redirect(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a document redirected off the list fails the security check")
	var second := UpdateFixtures.LoopbackReleaseServer.new({_document_name(2): _document(2, [UpdateFixtures.key()])})
	var first := UpdateFixtures.LoopbackReleaseServer.new({})
	first.redirect("/" + _document_name(2), 302, "%s/%s" % [second.host(), _document_name(2)])
	var measured: Dictionary = await _measure_failed_check(_world("off_list"), [first, second], first.host(), tree)
	_expect_failed_check(testing, measured, UpdateCheckFailure.SECURITY)
	testing.eq(second.connections(), 0, "the second listener → no request reaches it")
	testing.ok(not measured["stored"], "and nothing reaches the store")
	print("")


static func _test_invalid_document(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: an invalid document fails the security check and is not kept")
	var server := UpdateFixtures.LoopbackReleaseServer.new({_document_name(2): "not a document".to_utf8_buffer()})
	var measured: Dictionary = await _measure_failed_check(_world("invalid"), [server], server.host(), tree)
	_expect_failed_check(testing, measured, UpdateCheckFailure.SECURITY)
	testing.ok(not measured["stored"], "nothing reaches the store")
	print("")


# A file where the store's folder belongs makes every write fail, on every system.
static func _test_store_write(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a store that cannot be written names its folder")
	var server := UpdateFixtures.LoopbackReleaseServer.new({_document_name(2): _document(2, [UpdateFixtures.key()])})
	var previous_host := _set_host(server.host())
	var world := _world("store_write")
	var blocked_store := UpdateFixtures.scratch("walk_store_is_a_file")
	FolderFiles.write_checked(ProjectSettings.globalize_path(blocked_store), "a file".to_utf8_buffer())
	(world["options"] as Dictionary)["trust_store"] = blocked_store
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var failed := func() -> bool: return installer.check_failed()
	var on_time: bool = await _poll_until(failed, [server], tree)
	var note := installer.note_text()
	var before_click := server.connections()
	installer.install()
	await _poll_until(failed, [server], tree)
	var click_requests := server.connections() - before_click
	var can_retry := installer.can_retry_check()
	_end(world, nodes)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(blocked_store))
	server.stop()
	_restore_host(previous_host)
	testing.ok(on_time, "the check fails in time")
	testing.ok(note.begins_with("Couldn't save update security data to %s." % ProjectSettings.globalize_path(blocked_store)),
			"the note names the store's folder")
	testing.ok(can_retry, "a click can retry")
	testing.ok(click_requests > 0, "with a new request at the listener")
	print("")


# "." is what the data folder comes to with no HOME or APPDATA. _end points the world back at
# its scratch store first, since end_world deletes whatever folder the options name.
static func _test_no_store(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: no data folder asks for nothing and offers no retry")
	var server := UpdateFixtures.LoopbackReleaseServer.new({_document_name(2): _document(2, [UpdateFixtures.key()])})
	var previous_host := _set_host(server.host())
	var world := _world("no_store")
	(world["options"] as Dictionary)["trust_store"] = "."
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var state := installer.state()
	var note := installer.note_text()
	var can_retry := installer.can_retry_check()
	await _poll_frames([server], tree)
	installer.install()
	await _poll_frames([server], tree)
	var state_after_click := installer.state()
	var total := server.connections()
	_end(world, nodes)
	server.stop()
	_restore_host(previous_host)
	testing.eq(state, "idle", "the start → idle")
	testing.ok(note.begins_with("This update can't install here because your system doesn't set "), "with the data folder's sentence")
	testing.ok(not can_retry, "a click cannot help")
	testing.eq(state_after_click, "idle", "and a click changes nothing")
	testing.eq(total, 0, "no request reaches the listener")
	print("")


static func _test_manifest_server_error(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a 503 on the manifest ends the same way as one on a document")
	var server := UpdateFixtures.LoopbackReleaseServer.new({})
	server.redirect("/" + ReleaseAssets.manifest_name(_VERSION), 503, "")
	var measured: Dictionary = await _measure_failed_check(_world("manifest_error"), [server], server.host(), tree)
	_expect_failed_check(testing, measured, UpdateCheckFailure.GITHUB_ERROR)
	testing.eq(measured["names"], [_document_name(2), ReleaseAssets.manifest_name(_VERSION)], "after the chain's 404")
	print("")


static func _test_manifest_404(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a 404 on the manifest is quiet at a start, and a click that reaches it says the release isn't ready")
	var names := [_document_name(2), ReleaseAssets.manifest_name(_VERSION)]
	var server := UpdateFixtures.LoopbackReleaseServer.new({})
	var quiet: Dictionary = await _measure_unclicked_404(_world("manifest_404"), server, tree)
	_expect_quiet_404(testing, quiet)
	testing.eq(quiet["names"], names, "the chain's 404 ends the walk, not the check")
	testing.eq(quiet["start_requests"], 2, "a new start → the chain and the manifest asked for anew")
	var clicked: Dictionary = await _measure_clicked_404(_world("manifest_404_click"), {}, tree)
	_expect_clicked_404(testing, clicked)
	testing.eq(clicked["names"], names, "the click → the chain and the manifest asked for anew")
	print("")


static func _test_signature_404(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a 404 on the signature is quiet at a start, and a click that reaches it says the release isn't ready")
	var names := [_document_name(2), ReleaseAssets.manifest_name(_VERSION), ReleaseAssets.signature_name(_VERSION)]
	var assets := _release(UpdateFixtures.key())
	assets.erase(ReleaseAssets.signature_name(_VERSION))
	var server := UpdateFixtures.LoopbackReleaseServer.new(assets)
	var quiet: Dictionary = await _measure_unclicked_404(_world("signature_404"), server, tree)
	_expect_quiet_404(testing, quiet)
	testing.eq(quiet["names"], names, "after the manifest came")
	testing.eq(quiet["start_requests"], 3, "a new start → all three asked for anew")
	var clicked: Dictionary = await _measure_clicked_404(_world("signature_404_click"), assets, tree)
	_expect_clicked_404(testing, clicked)
	testing.eq(clicked["names"], names, "the click → all three asked for anew")
	print("")


static func _test_manifest_500_is_not_a_missing_release(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a 500 on the manifest still reads as GitHub's error")
	var server := UpdateFixtures.LoopbackReleaseServer.new({})
	server.redirect("/" + ReleaseAssets.manifest_name(_VERSION), 500, "")
	var measured: Dictionary = await _measure_failed_check(_world("manifest_500"), [server], server.host(), tree)
	_expect_failed_check(testing, measured, UpdateCheckFailure.GITHUB_ERROR)
	testing.ok(str(measured["note"]).begins_with("GitHub isn't responding."), "in GitHub's sentence")
	print("")


static func _test_signature_by_an_unlisted_key(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a release signed by an unlisted key fails the security check")
	var server := UpdateFixtures.LoopbackReleaseServer.new(_release(UpdateFixtures.other_key()))
	var measured: Dictionary = await _measure_failed_check(_world("unlisted"), [server], server.host(), tree)
	_expect_failed_check(testing, measured, UpdateCheckFailure.SECURITY)
	testing.ok(str(measured["log"]).contains("is not signed by a trusted key"), "and the log names the signature")
	print("")


static func _test_emergency_stop_ends_the_check(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a walk ending on a document with no release key fetches no manifest")
	var assets := _release(UpdateFixtures.key())
	assets[_document_name(2)] = _document(2, [])
	var server := UpdateFixtures.LoopbackReleaseServer.new(assets)
	var measured: Dictionary = await _measure_failed_check(_world("stop"), [server], server.host(), tree)
	_expect_failed_check(testing, measured, UpdateCheckFailure.SECURITY)
	testing.eq(measured["names"], [_document_name(2), _document_name(3)], "only the chain is asked for")
	print("")


static func _test_emergency_stop_can_be_lifted(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a client under an emergency stop still walks to the document that lifts it")
	for embedded: bool in [true, false]:
		var label := "embedded" if embedded else "stored"
		var lifting_version := 2 if embedded else 3
		var assets := _release(UpdateFixtures.key())
		assets[_document_name(lifting_version)] = _document(lifting_version, [UpdateFixtures.key()])
		var server := UpdateFixtures.LoopbackReleaseServer.new(assets)
		var previous_host := _set_host(server.host())
		var world := _world("lift_" + label)
		if embedded:
			(world["options"] as Dictionary)["trust_document"] = TrustFixtures.first_document([])
		else:
			_store_document(world, 2, _document(2, []))
		var nodes := UpdateFixtures.start_world(world, tree)
		var installer: UpdateInstaller = nodes["installer"]
		var on_time: bool = await _poll_until(func() -> bool: return installer.state() == "available", [server], tree)
		_end(world, nodes)
		server.stop()
		_restore_host(previous_host)
		testing.ok(on_time, "a stop %s → the release verifies once it is lifted" % label)
		testing.eq(_names(server).slice(0, 1), [_document_name(lifting_version)], "a stop %s → the walk asks for the next document" % label)
	print("")


static func _test_stale_note_goes_with_the_next_walk(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a new version's walk drops the last check's note")
	var server := UpdateFixtures.LoopbackReleaseServer.new({})
	server.redirect("/" + _document_name(2), 503, "")
	var previous_host := _set_host(server.host())
	var world := _world("stale_note")
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var runner: UpdateCheckRunner = nodes["runner"]
	await _poll_until(func() -> bool: return installer.check_failed(), [server], tree)
	var note_before := installer.note_text()
	# Stands in for a check of GitHub's latest release, which this suite does not drive.
	runner._record("1.10.0", false)
	var version := installer.version()
	var note_during := installer.note_text()
	var failed_during := installer.check_failed()
	_end(world, nodes)
	server.stop()
	_restore_host(previous_host)
	testing.ok(note_before.begins_with("GitHub isn't responding."), "1.9.0's check fails with a note")
	testing.eq(version, "1.10.0", "the runner reports 1.10.0 → the installer moves on")
	testing.eq(note_during, "", "and the note is gone while the new walk runs")
	testing.ok(not failed_during, "as is the failure")
	print("")


static func _test_cap_on_one_walk(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: one walk takes 32 documents, and a click takes the rest")
	var assets := _release(UpdateFixtures.key())
	for version: int in range(2, 35):
		assets[_document_name(version)] = _document(version, [UpdateFixtures.key()])
	var server := UpdateFixtures.LoopbackReleaseServer.new(assets)
	var previous_host := _set_host(server.host())
	var world := _world("cap")
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var verified: bool = await _poll_until(func() -> bool: return installer.state() == "available", [server], tree)
	var first_walk := _names(server)
	installer.install()
	var staged: bool = await _poll_until(func() -> bool: return installer.state() == "ready", [server], tree)
	var all_names := _names(server)
	_end(world, nodes)
	server.stop()
	_restore_host(previous_host)
	var expected_first := []
	for version: int in range(2, 34):
		expected_first.append(_document_name(version))
	expected_first.append_array([ReleaseAssets.manifest_name(_VERSION), ReleaseAssets.signature_name(_VERSION)])
	testing.ok(verified, "the first walk ends in a verified release, in time")
	testing.eq(first_walk, expected_first, "33 hosted → trust-2 to trust-33, then the manifest and signature")
	testing.ok(staged, "the click stages the release, in time")
	testing.eq(all_names.slice(first_walk.size()), [_document_name(34), _document_name(35), ReleaseAssets.archive_name(_VERSION)],
			"the click takes trust-34, meets the 404, then fetches the zip")
	print("")


static func _test_click_drops_the_key_of_a_kept_release(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a kept release whose key a click's walk drops is not downloaded")
	var assets := _release(UpdateFixtures.key())
	assets[_document_name(2)] = _document(2, [UpdateFixtures.other_key()])
	var server := UpdateFixtures.LoopbackReleaseServer.new(assets)
	var previous_host := _set_host(server.host())
	var world := _world("kept_dropped")
	UpdateFixtures.keep_verified(world["updates"], _VERSION, {"core/a.gd": "new"}, UpdateFixtures.key())
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var state_at_start := installer.state()
	await _poll_frames([server], tree)
	var requests_at_start := server.connections()
	installer.install()
	var failed: bool = await _poll_until(func() -> bool: return installer.check_failed(), [server], tree)
	var state := installer.state()
	var note := installer.note_text()
	var zip_left := UpdateFixtures.has_release_file(world, _VERSION, ReleaseAssets.archive_name(_VERSION))
	_end(world, nodes)
	server.stop()
	_restore_host(previous_host)
	testing.eq(state_at_start, "available", "the start offers the kept release")
	testing.eq(requests_at_start, 0, "with no request")
	testing.ok(failed, "the click's check fails in time")
	testing.eq(_names(server), [_document_name(2), _document_name(3), ReleaseAssets.manifest_name(_VERSION),
			ReleaseAssets.signature_name(_VERSION)], "the walk, then the release fetched anew, and no zip request")
	testing.eq(state, "idle", "the installer goes idle")
	testing.ok(note.begins_with("This update failed its security check, so it won't install."), "with the security sentence")
	testing.ok(not zip_left, "and no zip is on disk")
	print("")


static func _test_click_moves_a_kept_release_to_a_new_key(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a kept release re-signed by the walk's new key is downloaded")
	var assets := _release(UpdateFixtures.other_key())
	assets[_document_name(2)] = _document(2, [UpdateFixtures.other_key()])
	var server := UpdateFixtures.LoopbackReleaseServer.new(assets)
	var previous_host := _set_host(server.host())
	var world := _world("kept_moved")
	UpdateFixtures.keep_verified(world["updates"], _VERSION, {"core/a.gd": "new"}, UpdateFixtures.key())
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	installer.install()
	var staged: bool = await _poll_until(func() -> bool: return installer.state() == "ready", [server], tree)
	_end(world, nodes)
	server.stop()
	_restore_host(previous_host)
	testing.ok(staged, "the click stages the release, in time")
	testing.eq(_names(server), [_document_name(2), _document_name(3), ReleaseAssets.manifest_name(_VERSION),
			ReleaseAssets.signature_name(_VERSION), ReleaseAssets.archive_name(_VERSION)],
			"the walk, the release fetched anew, then the zip")
	print("")


static func _test_key_dropped_found_at_a_start(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a key dropped after staging shows at the next start, before any exit")
	var server := UpdateFixtures.LoopbackReleaseServer.new({})
	var previous_host := _set_host(server.host())
	var world := _world("staged_dropped")
	UpdateFixtures.stage(world["updates"], _VERSION, {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	_store_document(world, 2, _document(2, [UpdateFixtures.other_key()]))
	var nodes := UpdateFixtures.start_world(world, tree)
	var notice: Dictionary = (nodes["installer"] as UpdateInstaller).notice()
	var state := (nodes["installer"] as UpdateInstaller).state()
	var record: String = UpdateJournal.read(world["updates"])["state"]
	var logged := FileAccess.get_file_as_string((nodes["installer"] as UpdateInstaller).log_path())
	_end(world, nodes)
	server.stop()
	_restore_host(previous_host)
	testing.eq(notice.get("kind", ""), UpdateInstaller.NOTICE_FAILED, "the release → reported as not installed")
	testing.eq(notice.get("version", ""), _VERSION, "about the staged version")
	testing.eq(notice.get("from_version", ""), "1.1.0", "and the one still installed")
	testing.eq(notice.get("reason", ""), _UNTRUSTED, "with the reason in plain words")
	testing.ok(not bool(notice.get("server_changed", true)), "and no offer about the server")
	testing.ok(state != "ready", "nothing stays ready to install")
	testing.eq(record, "", "and the journal goes")
	testing.ok(logged.contains(_UNTRUSTED), "and the log says why")
	print("")


# The same silent clear serves a stage that lost its files; only a signature the chain refuses
# is news about trust.
static func _test_missing_signature_is_no_key_notice(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a stage missing its signature file reports no dropped key")
	var server := UpdateFixtures.LoopbackReleaseServer.new({})
	var previous_host := _set_host(server.host())
	var world := _world("staged_no_signature")
	UpdateFixtures.stage(world["updates"], _VERSION, {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	var folder := UpdateFolder.version_folder(_VERSION, str(world["updates"]))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(folder.path_join(ReleaseAssets.signature_name(_VERSION))))
	var nodes := UpdateFixtures.start_world(world, tree)
	var notice: Dictionary = (nodes["installer"] as UpdateInstaller).notice()
	_end(world, nodes)
	server.stop()
	_restore_host(previous_host)
	testing.eq(notice, {}, "no notice")
	print("")


static func _test_key_dropped_found_at_the_exit(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Trust walk: a key dropped before the exit shows at the next start")
	var server := UpdateFixtures.LoopbackReleaseServer.new({})
	var previous_host := _set_host(server.host())
	var world := _world("exit_dropped")
	UpdateFixtures.stage(world["updates"], _VERSION, {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	_store_document(world, 2, _document(2, [UpdateFixtures.other_key()]))
	var applied := UpdateApplier.apply_pending(world["options"])
	var nodes := UpdateFixtures.start_world(world, tree)
	var notice: Dictionary = (nodes["installer"] as UpdateInstaller).notice()
	_end(world, nodes)
	server.stop()
	_restore_host(previous_host)
	testing.eq(applied["state"], "not_applied", "the exit refuses the release")
	testing.eq(notice.get("kind", ""), UpdateInstaller.NOTICE_FAILED, "the next start → reported as not installed")
	testing.eq(notice.get("reason", ""), _UNTRUSTED, "with the exit's reason in plain words")
	print("")
