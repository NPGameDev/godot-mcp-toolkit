@tool
extends RefCounted
## Unit tests for the update installer: the notice an apply leaves for the next start,
## picking up a verified or staged record, the gates that keep it idle, giving an update
## up, changed files in the automatic mode, and failed downloads, served by a loopback
## listener. A download that succeeds runs in the update flow integration test
## (scripts/test_framework/update_flow.sh).

const Testing := preload("res://test/units/testing.gd")
const UpdateInstaller := preload("res://addons/godot_mcp_toolkit/update/update_installer.gd")
const UpdateCheckRunner := preload("res://addons/godot_mcp_toolkit/versioning/update_check_runner.gd")
const PendingUpdate := preload("res://addons/godot_mcp_toolkit/update/pending_update.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/update/release_assets.gd")
const InstallMode := preload("res://addons/godot_mcp_toolkit/update/install_mode.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")


static func run(testing, tree: SceneTree) -> void:
	# The installer's _ready runs only once the tree's root is live.
	await tree.process_frame
	_test_project_install_mode(testing)
	_test_notice_updated(testing, tree)
	_test_notice_failed(testing, tree)
	_test_verified_record(testing, tree)
	_test_staged_record(testing, tree)
	_test_gates(testing, tree)
	_test_discard(testing, tree)
	_test_changed_files_in_automatic(testing, tree)
	await _test_failed_download_not_retried(testing, tree)
	await _test_cut_download_leaves_no_partial_zip(testing, tree)
	await _test_found_this_session(testing, tree)


# With no stand-in in its options, the installer reads the project setting. Restored
# before the assertions, so a failure never leaves the project settings changed.
static func _test_project_install_mode(testing) -> void:
	testing.begin("Update installer: the project's install mode")
	var installer := UpdateInstaller.new(null)
	var had_mode := ProjectSettings.has_setting(InstallMode.SETTING)
	var previous_mode: Variant = ProjectSettings.get_setting(InstallMode.SETTING) if had_mode else null
	ProjectSettings.set_setting(InstallMode.SETTING, "manual")
	var manual := installer.install_mode()
	ProjectSettings.set_setting(InstallMode.SETTING, "automatic")
	var automatic := installer.install_mode()
	ProjectSettings.set_setting(InstallMode.SETTING, previous_mode)
	installer.free()
	testing.eq(manual, "manual", "the project's manual mode → manual")
	testing.eq(automatic, "automatic", "the project's automatic mode → automatic")
	print("")


static func _test_notice_updated(testing, tree: SceneTree) -> void:
	testing.begin("Update installer: the notice after an install")
	var world := UpdateFixtures.begin_world("installer_updated", "1.9.0", "ask", "1.9.0")
	PendingUpdate.write({"state": "applied", "version": "1.9.0", "from_version": "1.1.0",
			"compatible_server": "1.0.0"}, world["updates"])
	var nodes := UpdateFixtures.start_world(world, tree)
	var notice: Dictionary = (nodes["installer"] as UpdateInstaller).notice()
	var record_state: String = PendingUpdate.read(world["updates"])["state"]
	UpdateFixtures.end_world(world, nodes)
	testing.eq(notice, {"kind": "updated", "version": "1.9.0", "from_version": "1.1.0", "reason": "",
			"server_changed": true}, "an applied record the editor now runs → updated, with the server pin change")
	testing.eq(record_state, "", "the record → deleted once read")
	print("")


static func _test_notice_failed(testing, tree: SceneTree) -> void:
	testing.begin("Update installer: the notice after a failed install")
	var world := UpdateFixtures.begin_world("installer_failed", "1.9.0", "ask", "1.1.0")
	PendingUpdate.write({"state": "rolled_back", "version": "1.9.0", "from_version": "1.1.0",
			"reason": "could not write core/a.gd"}, world["updates"])
	var nodes := UpdateFixtures.start_world(world, tree)
	var rolled_back: Dictionary = (nodes["installer"] as UpdateInstaller).notice()
	UpdateFixtures.end_world(world, nodes)
	world = UpdateFixtures.begin_world("installer_not_loaded", "1.9.0", "ask", "1.1.0")
	PendingUpdate.write({"state": "applied", "version": "1.9.0", "from_version": "1.1.0"}, world["updates"])
	nodes = UpdateFixtures.start_world(world, tree)
	var not_loaded: Dictionary = (nodes["installer"] as UpdateInstaller).notice()
	UpdateFixtures.end_world(world, nodes)
	testing.eq(rolled_back, {"kind": "failed", "version": "1.9.0", "from_version": "1.1.0",
			"reason": "could not write core/a.gd", "server_changed": false}, "a rolled-back record → failed, with its reason")
	testing.eq(not_loaded["reason"], "the editor started version 1.1.0",
			"an applied record the editor does not run → failed, naming the version it runs")
	print("")


static func _test_verified_record(testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a verified release waits for the user")
	var world := UpdateFixtures.begin_world("installer_verified", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key(), PendingUpdate.VERIFIED)
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var state := installer.state()
	var version := installer.version()
	var prompt := installer.prompt_due()
	UpdateFixtures.end_world(world, nodes)
	testing.eq(state, "available", "a verified record of the runner's version → available")
	testing.eq(version, "1.9.0", "about that version")
	testing.ok(prompt, "the ask mode → the editor-start window is due")
	print("")


static func _test_staged_record(testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a staged release waits for the editor's exit")
	var world := UpdateFixtures.begin_world("installer_staged", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	var nodes := UpdateFixtures.start_world(world, tree)
	var staged := (nodes["installer"] as UpdateInstaller).state()
	UpdateFixtures.end_world(world, nodes)
	world = UpdateFixtures.begin_world("installer_staged_changed", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage_tampered(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	nodes = UpdateFixtures.start_world(world, tree)
	var tampered := (nodes["installer"] as UpdateInstaller).state()
	var tampered_record: String = PendingUpdate.read(world["updates"])["state"]
	UpdateFixtures.end_world(world, nodes)
	testing.eq(staged, "ready", "a staged record whose zip matches → ready")
	testing.eq(tampered, "available", "a staged zip that no longer matches → back to available")
	testing.eq(tampered_record, "verified", "and the record goes back to verified")
	print("")


static func _test_gates(testing, tree: SceneTree) -> void:
	testing.begin("Update installer: the gates keep it idle")
	var world := UpdateFixtures.begin_world("installer_manual", "1.9.0", "manual", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key(), PendingUpdate.VERIFIED)
	var nodes := UpdateFixtures.start_world(world, tree)
	var manual := (nodes["installer"] as UpdateInstaller).state()
	var manual_record: String = PendingUpdate.read(world["updates"])["state"]
	UpdateFixtures.end_world(world, nodes)

	world = UpdateFixtures.begin_world("installer_no_keys", "1.9.0", "ask", "1.1.0")
	(world["options"] as Dictionary)["public_keys"] = []
	nodes = UpdateFixtures.start_world(world, tree)
	var no_keys := (nodes["installer"] as UpdateInstaller).state()
	UpdateFixtures.end_world(world, nodes)

	world = UpdateFixtures.begin_world("installer_major", "2.0.0", "ask", "1.1.0")
	nodes = UpdateFixtures.start_world(world, tree)
	var major := (nodes["installer"] as UpdateInstaller).state()
	UpdateFixtures.end_world(world, nodes)

	world = UpdateFixtures.begin_world("installer_guarded", "1.9.0", "ask", "1.1.0")
	(world["options"] as Dictionary)["guard_facts"] = {"version_control_folder": true}
	nodes = UpdateFixtures.start_world(world, tree)
	var guarded: UpdateInstaller = nodes["installer"]
	var guarded_state := guarded.state()
	var guarded_note := guarded.note_text()
	UpdateFixtures.end_world(world, nodes)

	testing.eq(manual, "idle", "the manual mode → idle")
	testing.eq(manual_record, "", "and a verified record is given up")
	testing.eq(no_keys, "idle", "no trusted key → idle")
	testing.eq(major, "idle", "a major release → idle")
	testing.eq(guarded_state, "idle", "a guard → idle")
	testing.eq(guarded_note, "The toolkit's folder is a git checkout or submodule; update it with git.",
			"and the guard's sentence is the note")
	print("")


static func _test_discard(testing, tree: SceneTree) -> void:
	testing.begin("Update installer: giving an update up")
	var world := UpdateFixtures.begin_world("installer_discard", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var before := installer.state()
	installer.discard()
	var after := installer.state()
	var record_state: String = PendingUpdate.read(world["updates"])["state"]
	var badge := (nodes["runner"] as UpdateCheckRunner).badge_version()
	UpdateFixtures.end_world(world, nodes)
	testing.eq(before, "ready", "a staged release → ready")
	testing.eq(after, "idle", "discard → idle")
	testing.eq(record_state, "", "the record and its files → deleted")
	testing.eq(badge, "", "the version → dismissed until a newer one")
	print("")


static func _test_changed_files_in_automatic(testing, tree: SceneTree) -> void:
	testing.begin("Update installer: changed files make the automatic mode ask")
	var world := UpdateFixtures.begin_world("installer_changed", "1.9.0", "automatic", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key(), PendingUpdate.VERIFIED)
	var record := PendingUpdate.read(world["updates"])
	record["changed_files"] = PackedStringArray(["core/a.gd"])
	PendingUpdate.write(record, world["updates"])
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var state := installer.state()
	var changed := installer.changed_files()
	var prompt := installer.prompt_due()
	UpdateFixtures.end_world(world, nodes)
	testing.eq(state, "available", "a verified release with changed files → available, not downloading")
	testing.eq(changed, PackedStringArray(["core/a.gd"]), "the changed files → reported")
	testing.ok(not prompt, "the automatic mode → no editor-start window")
	print("")


# A loopback port nothing listens on makes the automatic download fail at once,
# without the network.
static func _test_failed_download_not_retried(testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a failed automatic download is not retried on its own")
	var host_env := "GODOT_MCP_UPDATE_CHECK_HOST"
	var previous_host := OS.get_environment(host_env)
	OS.set_environment(host_env, "http://127.0.0.1:9")
	var world := UpdateFixtures.begin_world("installer_retry", "1.9.0", "automatic", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key(), PendingUpdate.VERIFIED)
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var first := installer.state()
	var frames := 0
	while installer.state() == "downloading" and frames < 600:
		await tree.process_frame
		frames += 1
	var after_failure := installer.state()
	(nodes["runner"] as UpdateCheckRunner).state_changed.emit()
	var after_reevaluation := installer.state()
	installer.install()
	var after_click := installer.state()
	UpdateFixtures.end_world(world, nodes)
	if previous_host.is_empty():
		OS.unset_environment(host_env)
	else:
		OS.set_environment(host_env, previous_host)
	testing.eq(first, "downloading", "a verified release in the automatic mode → downloading at once")
	testing.eq(after_failure, "idle", "the download fails → idle, silently")
	testing.ok(frames < 600, "the failure arrives within 600 frames")
	testing.eq(after_reevaluation, "available", "a later evaluation → available, without downloading again")
	testing.eq(after_click, "downloading", "a click on Update → downloads again")
	print("")


# A loopback listener stands in for GitHub: it answers the zip request with the full
# length and half the body, then hangs up, as a dropped connection does. Godot 4.2 to
# 4.6 keep what HTTPRequest wrote by then; the installer deletes it, so a later start
# never finds a partial zip beside the verified manifest.
static func _test_cut_download_leaves_no_partial_zip(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a download cut short leaves no partial zip")
	var server := TCPServer.new()
	server.listen(0, "127.0.0.1")
	var host_env := "GODOT_MCP_UPDATE_CHECK_HOST"
	var previous_host := OS.get_environment(host_env)
	OS.set_environment(host_env, "http://127.0.0.1:%d" % server.get_local_port())
	var world := UpdateFixtures.begin_world("installer_cut", "1.9.0", "automatic", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key(), PendingUpdate.VERIFIED)
	var archive := ProjectSettings.globalize_path(PendingUpdate.version_folder("1.9.0", world["updates"])).path_join(
			ReleaseAssets.archive_name("1.9.0"))
	var archive_bytes := FileAccess.get_file_as_bytes(archive)
	# A verified record has no zip yet; the fixture's copy only supplies the bytes served.
	DirAccess.remove_absolute(archive)
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var peer: StreamPeerTCP = null
	var request := ""
	var frames_since_file := -1
	var frames := 0
	while installer.state() == "downloading" and frames < 600:
		await tree.process_frame
		frames += 1
		if peer == null and server.is_connection_available():
			peer = server.take_connection()
		if peer == null:
			continue
		peer.poll()
		if not request.contains("\r\n\r\n"):
			request += peer.get_utf8_string(peer.get_available_bytes())
			if request.contains("\r\n\r\n"):
				peer.put_data(("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
						% archive_bytes.size()).to_utf8_buffer())
				peer.put_data(archive_bytes.slice(0, archive_bytes.size() / 2))
		elif frames_since_file < 0 and FileAccess.file_exists(archive):
			frames_since_file = 0
		elif frames_since_file >= 0:
			frames_since_file += 1
			# A few frames let HTTPRequest store the half body before the hang-up.
			if frames_since_file == 10:
				peer.disconnect_from_host()
	var partial_left := FileAccess.file_exists(archive)
	UpdateFixtures.end_world(world, nodes)
	if peer != null:
		peer.disconnect_from_host()
	server.stop()
	if previous_host.is_empty():
		OS.unset_environment(host_env)
	else:
		OS.set_environment(host_env, previous_host)
	testing.ok(frames_since_file >= 0, "the zip being downloaded → written to disk")
	testing.ok(frames < 600, "the cut download ends within 600 frames")
	testing.ok(not partial_left, "the download fails → the partial zip is deleted")
	print("")


# The badge announces only a release found during the session: one picked up from an
# earlier session's record is what the editor-start window shows instead.
static func _test_found_this_session(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: only a release it verifies itself is found this session")
	var world := UpdateFixtures.begin_world("installer_found_record", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key(), PendingUpdate.VERIFIED)
	var nodes := UpdateFixtures.start_world(world, tree)
	var restored := (nodes["installer"] as UpdateInstaller).found_this_session()
	UpdateFixtures.end_world(world, nodes)

	var server := UpdateFixtures.LoopbackReleaseServer.new(
			UpdateFixtures.release_assets("1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key()))
	var host_env := "GODOT_MCP_UPDATE_CHECK_HOST"
	var previous_host := OS.get_environment(host_env)
	OS.set_environment(host_env, server.host())
	world = UpdateFixtures.begin_world("installer_found_verified", "1.9.0", "ask", "1.1.0")
	nodes = UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var frames := 0
	while installer.state() != "available" and frames < 1200:
		server.poll()
		await tree.process_frame
		frames += 1
	var verified := installer.found_this_session()
	UpdateFixtures.end_world(world, nodes)
	server.stop()
	if previous_host.is_empty():
		OS.unset_environment(host_env)
	else:
		OS.set_environment(host_env, previous_host)
	testing.ok(not restored, "a release picked up from an earlier session's record → not found this session")
	testing.ok(frames < 1200, "the release is verified within 1200 frames")
	testing.ok(verified, "a release verified during the session → found this session")
	print("")
