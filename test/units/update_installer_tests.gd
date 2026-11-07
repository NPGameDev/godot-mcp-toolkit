@tool
extends RefCounted
## Unit tests for the update installer: the notice an apply leaves for the next start,
## picking up a kept or staged release, the gates that keep it idle and the ones a stage
## outlives, giving an update up, a download failed, killed or redirected, one that stages
## over frames and the restart or ready view after it, why the last exit postponed it, and a
## headless start. Its fetches go to loopback listeners.

const Testing := preload("res://test/units/testing.gd")
const UpdateInstaller := preload("res://addons/godot_mcp_toolkit/self_update/update_installer.gd")
const UpdateCheckRunner := preload("res://addons/godot_mcp_toolkit/versioning/update_check_runner.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const UpdateJournal := preload("res://addons/godot_mcp_toolkit/self_update/update_journal.gd")
const UpdateApplier := preload("res://addons/godot_mcp_toolkit/self_update/update_applier.gd")
const UpdateLifecycle := preload("res://addons/godot_mcp_toolkit/self_update/update_lifecycle.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const InstallMode := preload("res://addons/godot_mcp_toolkit/self_update/install_mode.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")
const Consent := preload("res://addons/godot_mcp_toolkit/core/consent.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

const _STAGED_FILES := {"core/a.gd": "new a", "core/b.gd": "new b", "core/c.gd": "new c"}
# Far more frames than a loopback download and a small stage need, so a stuck run fails the case.
const _MAX_FRAMES := 1200


static func run(testing: Testing, tree: SceneTree) -> void:
	# The installer's _ready runs only once the tree's root is live.
	await tree.process_frame
	_test_project_install_mode(testing)
	_test_notice_updated(testing, tree)
	_test_notice_failed(testing, tree)
	_test_verified_record(testing, tree)
	_test_staged_record(testing, tree)
	await _test_gates(testing, tree)
	_test_discard(testing, tree)
	await _test_cut_download_leaves_no_partial_zip(testing, tree)
	await _test_found_this_session(testing, tree)
	await _test_start_offers_kept_release_without_requests(testing, tree)
	_test_kept_release_above_this_editor(testing, tree)
	_test_killed_download(testing, tree)
	_test_verified_journal_found_after_start(testing, tree)
	_test_staged_zip_that_will_not_delete(testing, tree)
	await _test_staged_release_stands(testing, tree)
	await _test_stage_failing_its_check_gives_way(testing, tree)
	await _test_click_stages_and_the_exit_applies(testing, tree)
	_test_staged_at_start_opens_the_ready_view(testing, tree)
	await _test_click_and_stage_restarts(testing, tree)
	await _test_leaving_the_tree_during_a_scan(testing, tree)
	_test_restart_refused_while_a_script_is_unsaved(testing, tree)
	await _test_preparing_spans_frames(testing, tree)
	await _test_runner_signal_during_a_stage(testing, tree)
	await _test_zip_that_fails_its_list(testing, tree)
	await _test_discard_during_a_stage(testing, tree)
	await _test_discard_from_the_preparing_handler(testing, tree)
	await _test_leaving_the_tree_during_a_stage(testing, tree)
	_test_staged_outlives_no_newer_version(testing, tree)
	_test_staged_outlives_the_check_turned_off(testing, tree)
	_test_manual_mode_clears_a_staged_journal(testing, tree)
	await _test_manual_mode_during_a_stage(testing, tree)
	await _test_manual_mode_during_a_download(testing, tree)
	await _test_try_again_follows_the_gates(testing, tree)
	await _test_cancel_lets_the_journal_go(testing, tree)
	_test_settled(testing, tree)
	_test_postponed_reason(testing, tree)
	_test_headless_start_keeps_a_journal(testing, tree, "1.9.0")
	_test_headless_start_keeps_a_journal(testing, tree, "")
	_test_headless_start_keeps_a_kept_release(testing, tree)
	_test_headless_override_reads_ready(testing, tree)
	await _test_off_list_redirect_of_the_zip(testing, tree)
	await _test_off_list_redirect_during_a_verify(testing, tree)
	await _test_redirects_every_engine_must_follow(testing, tree)


# With no stand-in in its options, the installer reads the project setting. Restored
# before the assertions, so a failure never leaves the project settings changed.
static func _test_project_install_mode(testing: Testing) -> void:
	testing.begin("Update installer: the project's install mode")
	var installer := UpdateInstaller.new(null)
	var had_mode := ProjectSettings.has_setting(InstallMode.SETTING)
	var previous_mode: Variant = ProjectSettings.get_setting(InstallMode.SETTING) if had_mode else null
	ProjectSettings.set_setting(InstallMode.SETTING, "manual")
	var manual := installer.install_mode()
	ProjectSettings.set_setting(InstallMode.SETTING, "ask")
	var ask := installer.install_mode()
	ProjectSettings.set_setting(InstallMode.SETTING, previous_mode)
	installer.free()
	testing.eq(manual, "manual", "the project's manual mode → manual")
	testing.eq(ask, "ask", "the project's ask mode → ask")
	print("")


static func _test_notice_updated(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: the notice after an install")
	var world := UpdateFixtures.begin_world("installer_updated", "1.9.0", "ask", "1.9.0")
	UpdateJournal.write({"state": "applied", "to": "1.9.0", "from": "1.1.0",
			"compatible_server": "1.0.0"}, world["updates"])
	var nodes := UpdateFixtures.start_world(world, tree)
	var notice: Dictionary = (nodes["installer"] as UpdateInstaller).notice()
	var record_state: String = UpdateJournal.read(world["updates"])["state"]
	UpdateFixtures.end_world(world, nodes)
	testing.eq(notice, {"kind": "updated", "version": "1.9.0", "from_version": "1.1.0", "reason": "",
			"server_changed": true}, "an applied record the editor now runs → updated, with the server pin change")
	testing.eq(record_state, "", "the record → deleted once read")
	print("")


# Both starts begin a verify of 1.9.0. The listener is never polled, so it stays unanswered
# and nothing leaves the machine.
static func _test_notice_failed(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: the notice after a failed install")
	var server := UpdateFixtures.LoopbackReleaseServer.new({})
	var previous_host := UpdateFixtures.set_host(server.host())
	var world := UpdateFixtures.begin_world("installer_failed", "1.9.0", "ask", "1.1.0")
	UpdateJournal.write({"state": "not_applied", "to": "1.9.0", "from": "1.1.0",
			"reason": "could not write core/a.gd"}, world["updates"])
	var nodes := UpdateFixtures.start_world(world, tree)
	var not_applied: Dictionary = (nodes["installer"] as UpdateInstaller).notice()
	UpdateFixtures.end_world(world, nodes)
	world = UpdateFixtures.begin_world("installer_not_loaded", "1.9.0", "ask", "1.1.0")
	UpdateJournal.write({"state": "applied", "to": "1.9.0", "from": "1.1.0"}, world["updates"])
	nodes = UpdateFixtures.start_world(world, tree)
	var not_loaded: Dictionary = (nodes["installer"] as UpdateInstaller).notice()
	UpdateFixtures.end_world(world, nodes)
	server.stop()
	UpdateFixtures.restore_host(previous_host)
	testing.eq(not_applied, {"kind": "failed", "version": "1.9.0", "from_version": "1.1.0",
			"reason": "could not write core/a.gd", "server_changed": false}, "a not-applied record → failed, with its reason")
	testing.eq(not_loaded["reason"], "the editor started version 1.1.0",
			"an applied record the editor does not run → failed, naming the version it runs")
	print("")


static func _test_verified_record(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a verified release waits for the user")
	var world := UpdateFixtures.begin_world("installer_verified", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.keep_verified(world["updates"], "1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key())
	UpdateFixtures.edit_installed_file(world, "core/a.gd")
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var state := installer.state()
	var version := installer.version()
	var prompt := installer.prompt_due()
	var changed := installer.changed_files()
	UpdateFixtures.end_world(world, nodes)
	testing.eq(state, "available", "a kept manifest and signature of the runner's version → available")
	testing.eq(version, "1.9.0", "about that version")
	testing.ok(prompt, "the ask mode → the editor-start window is due")
	testing.eq(changed, PackedStringArray(["core/a.gd"]), "an installed file edited by hand → reported as changed")
	print("")


static func _test_staged_record(testing: Testing, tree: SceneTree) -> void:
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
	var tampered_record: String = UpdateJournal.read(world["updates"])["state"]
	var tampered_zip_left := UpdateFixtures.has_release_file(world, "1.9.0", ReleaseAssets.archive_name("1.9.0"))
	var tampered_manifest_left := UpdateFixtures.has_release_file(world, "1.9.0", ReleaseAssets.manifest_name("1.9.0"))
	UpdateFixtures.end_world(world, nodes)
	testing.eq(staged, "ready", "a staged record whose zip matches → ready")
	testing.eq(tampered, "available", "a staged zip that no longer matches → back to available")
	testing.eq(tampered_record, "", "and the record goes, as nothing is downloading")
	testing.ok(not tampered_zip_left, "the zip that no longer matches → deleted")
	testing.ok(tampered_manifest_left, "the manifest → kept for the next start")
	print("")


# The major release is kept verified, so with its gate open the start offers it at once and
# needs no request. Every world fetches from the listener, so a gate that let a verify through
# never reaches GitHub.
static func _test_gates(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: the gates keep it idle")
	var server := UpdateFixtures.LoopbackReleaseServer.new({})
	var previous_host := UpdateFixtures.set_host(server.host())
	var world := UpdateFixtures.begin_world("installer_manual", "1.9.0", "manual", "1.1.0")
	UpdateFixtures.keep_verified(world["updates"], "1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key())
	var manifest_name := ReleaseAssets.manifest_name("1.9.0")
	var manual_kept_before := UpdateFixtures.has_release_file(world, "1.9.0", manifest_name)
	var nodes := UpdateFixtures.start_world(world, tree)
	var manual := (nodes["installer"] as UpdateInstaller).state()
	var manual_kept_after := UpdateFixtures.has_release_file(world, "1.9.0", manifest_name)
	UpdateFixtures.end_world(world, nodes)

	world = UpdateFixtures.begin_world("installer_major", "2.0.0", "ask", "1.1.0")
	UpdateFixtures.keep_verified(world["updates"], "2.0.0", {"core/a.gd": "new"}, UpdateFixtures.key())
	nodes = UpdateFixtures.start_world(world, tree)
	var major := (nodes["installer"] as UpdateInstaller).state()
	for _frame: int in range(120):
		server.poll()
		await tree.process_frame
	var major_connections := server.connections()
	UpdateFixtures.end_world(world, nodes)

	world = UpdateFixtures.begin_world("installer_guarded", "1.9.0", "ask", "1.1.0")
	(world["options"] as Dictionary)["guard_facts"] = {"version_control_folder": true}
	nodes = UpdateFixtures.start_world(world, tree)
	var guarded: UpdateInstaller = nodes["installer"]
	var guarded_state := guarded.state()
	var guarded_note := guarded.note_text()
	UpdateFixtures.end_world(world, nodes)
	server.stop()
	UpdateFixtures.restore_host(previous_host)

	testing.eq(manual, "idle", "the manual mode → idle")
	testing.ok(manual_kept_before and not manual_kept_after, "and a kept release is given up")
	testing.eq(major, "idle", "a major release, kept verified → idle")
	testing.eq(major_connections, 0, "and nothing is requested for it")
	testing.eq(guarded_state, "idle", "a guard → idle")
	testing.eq(guarded_note, "The toolkit's folder is a git checkout or submodule; update it with git.",
			"and the guard's sentence is the note")
	print("")


static func _test_discard(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: giving an update up")
	var world := UpdateFixtures.begin_world("installer_discard", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var before := installer.state()
	installer.discard()
	var after := installer.state()
	var record_state: String = UpdateJournal.read(world["updates"])["state"]
	var badge := (nodes["runner"] as UpdateCheckRunner).badge_version()
	UpdateFixtures.end_world(world, nodes)
	testing.eq(before, "ready", "a staged release → ready")
	testing.eq(after, "idle", "discard → idle")
	testing.eq(record_state, "", "the record and its files → deleted")
	testing.eq(badge, "", "the version → dismissed until a newer one")
	print("")


# A loopback listener stands in for GitHub: it answers the zip request with the full
# length and half the body, then hangs up, as a dropped connection does. Godot 4.2 to
# 4.6 keep what HTTPRequest wrote by then; the installer deletes it, so a later start
# never finds a partial zip beside the verified manifest.
static func _test_cut_download_leaves_no_partial_zip(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a download cut short leaves no partial zip")
	var server := TCPServer.new()
	server.listen(0, "127.0.0.1")
	var previous_host := UpdateFixtures.set_host("http://127.0.0.1:%d" % server.get_local_port())
	var world := UpdateFixtures.begin_world("installer_cut", "1.9.0", "ask", "1.1.0")
	var archive_bytes := UpdateFixtures.keep_verified(world["updates"], "1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key())
	var archive := ProjectSettings.globalize_path(UpdateFolder.archive_path("1.9.0", world["updates"]))
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var record_before: String = UpdateJournal.read(world["updates"])["state"]
	installer.install()
	var record_during := ""
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
				# The click's walk asks for the next trust document first, and the chain ends there.
				if request.get_slice(" ", 1).ends_with(ReleaseAssets.trust_document_name(2)):
					peer.put_data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_utf8_buffer())
					peer.disconnect_from_host()
					peer = null
					request = ""
					continue
				# The journal is written once the walk is over, just before the zip's request.
				record_during = UpdateJournal.read(world["updates"])["state"]
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
	var record_after: String = UpdateJournal.read(world["updates"])["state"]
	var manifest_left := UpdateFixtures.has_release_file(world, "1.9.0", ReleaseAssets.manifest_name("1.9.0"))
	UpdateFixtures.end_world(world, nodes)
	if peer != null:
		peer.disconnect_from_host()
	server.stop()
	UpdateFixtures.restore_host(previous_host)
	testing.ok(frames_since_file >= 0, "the zip being downloaded → written to disk")
	testing.ok(frames < 600, "the cut download ends within 600 frames")
	testing.ok(not partial_left, "the download fails → the partial zip is deleted")
	testing.eq(record_before, "", "a release waiting for the word → no journal")
	testing.eq(record_during, "verified", "the download starts → the journal says verified")
	testing.eq(record_after, "", "the download fails → the journal goes")
	testing.ok(manifest_left, "and the manifest stays for the next start")
	print("")


# The badge announces only a release found during the session: one an earlier session
# kept is what the editor-start window shows instead.
static func _test_found_this_session(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: only a release it verifies itself is found this session")
	var world := UpdateFixtures.begin_world("installer_found_record", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.keep_verified(world["updates"], "1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key())
	var nodes := UpdateFixtures.start_world(world, tree)
	var restored := (nodes["installer"] as UpdateInstaller).found_this_session()
	UpdateFixtures.end_world(world, nodes)

	var server := UpdateFixtures.LoopbackReleaseServer.new(
			UpdateFixtures.release_assets("1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key()))
	var previous_host := UpdateFixtures.set_host(server.host())
	world = UpdateFixtures.begin_world("installer_found_verified", "1.9.0", "ask", "1.1.0")
	nodes = UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var frames := 0
	while installer.state() != "available" and frames < _MAX_FRAMES:
		server.poll()
		await tree.process_frame
		frames += 1
	var verified := installer.found_this_session()
	UpdateFixtures.end_world(world, nodes)
	server.stop()
	UpdateFixtures.restore_host(previous_host)
	testing.ok(not restored, "a release an earlier session kept → not found this session")
	testing.ok(frames < _MAX_FRAMES, "the release is verified within %d frames" % _MAX_FRAMES)
	testing.ok(verified, "a release verified during the session → found this session")
	print("")


# One start verifies the release over a loopback listener; the next finds what it kept.
# The first start's three connections show the listener sees requests, so the second's
# zero means none were sent.
static func _test_start_offers_kept_release_without_requests(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a start offers a kept release without fetching it again")
	var server := UpdateFixtures.LoopbackReleaseServer.new(
			UpdateFixtures.release_assets("1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key()))
	var previous_host := UpdateFixtures.set_host(server.host())
	var world := UpdateFixtures.begin_world("installer_kept", "1.9.0", "ask", "1.1.0")
	var first_start := UpdateFixtures.start_world(world, tree)
	var frames := 0
	while (first_start["installer"] as UpdateInstaller).state() != "available" and frames < _MAX_FRAMES:
		server.poll()
		await tree.process_frame
		frames += 1
	var first_connections := server.connections()
	var record: String = UpdateJournal.read(world["updates"])["state"]
	var ignored := FileAccess.file_exists(str(world["updates"]).path_join(".gitignore"))
	(first_start["installer"] as Node).free()
	(first_start["runner"] as Node).free()

	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var state := installer.state()
	var prompt := installer.prompt_due()
	for _frame: int in range(frames + 60):
		server.poll()
		await tree.process_frame
	var second_connections := server.connections() - first_connections
	var found := installer.found_this_session()
	UpdateFixtures.end_world(world, nodes)
	server.stop()
	UpdateFixtures.restore_host(previous_host)
	testing.ok(frames < _MAX_FRAMES, "the first start verifies within %d frames" % _MAX_FRAMES)
	testing.eq(first_connections, 3, "the first start → the chain's 404, the manifest and the signature fetched")
	testing.eq(record, "", "and no journal written")
	testing.ok(ignored, "the kept files sit under the folder's ignore files")
	testing.eq(state, "available", "the next start → available at once")
	testing.eq(second_connections, 0, "with no request at the listener")
	testing.ok(prompt, "the editor-start window is due")
	testing.ok(not found, "and it is not found this session")
	print("")


static func _test_kept_release_above_this_editor(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a kept release this editor is too old for")
	var world := UpdateFixtures.begin_world("installer_kept_floor", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.keep_verified(world["updates"], "1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key(), "99.0")
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var state := installer.state()
	var note := installer.note_text()
	UpdateFixtures.end_world(world, nodes)
	testing.eq(state, "idle", "a Godot floor above this editor → idle")
	testing.eq(note, "Version 1.9.0 needs Godot 99.0 or newer.", "and the floor is the note")
	print("")


# A kill during a download leaves the journal it wrote first and a partial zip. The start
# clears them, so what is offered next is only ever verified again. The listener is never
# polled: the verify this start begins stays unanswered.
static func _test_killed_download(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a start after a kill during a download")
	var server := UpdateFixtures.LoopbackReleaseServer.new({})
	var previous_host := UpdateFixtures.set_host(server.host())
	var world := UpdateFixtures.begin_world("installer_killed", "1.9.0", "ask", "1.1.0")
	var archive_bytes := UpdateFixtures.keep_verified(world["updates"], "1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key())
	var archive := ProjectSettings.globalize_path(UpdateFolder.archive_path("1.9.0", world["updates"]))
	var partial := FileAccess.open(archive, FileAccess.WRITE)
	partial.store_buffer(archive_bytes.slice(0, archive_bytes.size() / 2))
	partial.close()
	UpdateJournal.write({"state": UpdateJournal.VERIFIED, "to": "1.9.0", "from": "1.1.0"}, world["updates"])
	var nodes := UpdateFixtures.start_world(world, tree)
	var state := (nodes["installer"] as UpdateInstaller).state()
	var partial_left := FileAccess.file_exists(archive)
	var record: String = UpdateJournal.read(world["updates"])["state"]
	UpdateFixtures.end_world(world, nodes)
	server.stop()
	UpdateFixtures.restore_host(previous_host)
	testing.eq(state, "idle", "a verified journal and a partial zip → nothing offered from them")
	testing.ok(not partial_left, "the partial zip → deleted")
	testing.eq(record, "", "and the journal with it")
	print("")


# The settler clears a verified journal at a start, so this one appears after the start, to
# reach the installer's own reading of it. The listener is never polled: the verify that
# follows stays unanswered.
static func _test_verified_journal_found_after_start(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a verified journal is cleared, not offered")
	var server := UpdateFixtures.LoopbackReleaseServer.new({})
	var previous_host := UpdateFixtures.set_host(server.host())
	var world := UpdateFixtures.begin_world("installer_verified_journal", "1.9.0", "ask", "1.1.0")
	var archive_bytes := UpdateFixtures.keep_verified(world["updates"], "1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key())
	var archive := ProjectSettings.globalize_path(UpdateFolder.archive_path("1.9.0", world["updates"]))
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var before := installer.state()
	var partial := FileAccess.open(archive, FileAccess.WRITE)
	partial.store_buffer(archive_bytes.slice(0, archive_bytes.size() / 2))
	partial.close()
	UpdateJournal.write({"state": UpdateJournal.VERIFIED, "to": "1.9.0", "from": "1.1.0"}, world["updates"])
	(nodes["runner"] as UpdateCheckRunner).state_changed.emit()
	var state := installer.state()
	var partial_left := FileAccess.file_exists(archive)
	var record: String = UpdateJournal.read(world["updates"])["state"]
	UpdateFixtures.end_world(world, nodes)
	server.stop()
	UpdateFixtures.restore_host(previous_host)
	testing.eq(before, "available", "the kept release → available before the journal appears")
	testing.eq(state, "idle", "a verified journal and a partial zip → nothing offered from them")
	testing.ok(not partial_left, "the partial zip → deleted")
	testing.eq(record, "", "and the journal with it")
	print("")


static func _test_staged_zip_that_will_not_delete(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a staged zip that no longer matches and will not delete")
	var world := UpdateFixtures.begin_world("installer_held_zip", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage_tampered(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	var folder := ProjectSettings.globalize_path(UpdateFolder.version_folder("1.9.0", world["updates"]))
	var zip_name := ReleaseAssets.archive_name("1.9.0")
	UpdateFixtures.block_delete(folder, zip_name, true)
	var nodes := UpdateFixtures.start_world(world, tree)
	var state := (nodes["installer"] as UpdateInstaller).state()
	var record: String = UpdateJournal.read(world["updates"])["state"]
	var zip_left := UpdateFixtures.has_release_file(world, "1.9.0", zip_name)
	UpdateFixtures.block_delete(folder, zip_name, false)
	UpdateFixtures.end_world(world, nodes)
	testing.ok(zip_left, "the delete is refused")
	testing.eq(state, "idle", "nothing is offered beside it")
	testing.eq(record, "staged", "and the journal stays for the next start")
	print("")


# The exit installs what a staged journal names, so a newer release waits for the next
# start. The listener serves that release: a verify would reach it well inside these
# frames, as `_test_start_offers_kept_release_without_requests` measures.
static func _test_staged_release_stands(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a staged release stands while a newer one is out")
	var server := UpdateFixtures.LoopbackReleaseServer.new(
			UpdateFixtures.release_assets("1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key()))
	var host := server.host()
	var previous_host := UpdateFixtures.set_host(host)
	var world := UpdateFixtures.begin_world("installer_newer", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.8.0", {"core/a.gd": "older"}, "1.1.0", UpdateFixtures.key())
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var state_at_start := installer.state()
	for _frame: int in range(120):
		server.poll()
		await tree.process_frame
	(nodes["runner"] as UpdateCheckRunner).state_changed.emit()
	for _frame: int in range(120):
		server.poll()
		await tree.process_frame
	# A click runs no walk while an update is staged.
	installer.install()
	for _frame: int in range(120):
		server.poll()
		await tree.process_frame
	var state := installer.state()
	var version := installer.version()
	var connections := server.connections()
	var record: String = UpdateJournal.read(world["updates"])["state"]
	var record_to: String = UpdateJournal.read(world["updates"])["to"]
	var zip_left := UpdateFixtures.has_release_file(world, "1.8.0", ReleaseAssets.archive_name("1.8.0"))
	UpdateFixtures.end_world(world, nodes)
	server.stop()

	# The listener is gone, so the port refuses, as it would for a user offline at start.
	world = UpdateFixtures.begin_world("installer_newer_offline", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.8.0", {"core/a.gd": "older"}, "1.1.0", UpdateFixtures.key())
	nodes = UpdateFixtures.start_world(world, tree)
	# Read after the frames a refused request would need to come back and change the state.
	for _frame: int in range(120):
		await tree.process_frame
	var offline := (nodes["installer"] as UpdateInstaller).state()
	UpdateFixtures.end_world(world, nodes)

	world = UpdateFixtures.begin_world("installer_newer_major", "2.0.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.8.0", {"core/a.gd": "older"}, "1.1.0", UpdateFixtures.key())
	nodes = UpdateFixtures.start_world(world, tree)
	var major := (nodes["installer"] as UpdateInstaller).state()
	var major_version := (nodes["installer"] as UpdateInstaller).version()
	var major_record: String = UpdateJournal.read(world["updates"])["state"]
	UpdateFixtures.end_world(world, nodes)

	UpdateFixtures.restore_host(previous_host)
	testing.eq(state_at_start, "ready", "a stage older than the runner's version → ready at once")
	testing.eq(state, "ready", "and still ready after the runner reports again")
	testing.eq(version, "1.8.0", "about the staged version, not the runner's")
	testing.eq(connections, 0, "with no request at the listener")
	testing.eq(record, "staged", "the journal stays")
	testing.eq(record_to, "1.8.0", "naming the staged version")
	testing.ok(zip_left, "and the staged zip stays")
	testing.eq(offline, "ready", "offline at start → ready too")
	testing.eq(major, "ready", "a major release out → the stage still stands")
	testing.eq(major_version, "1.8.0", "about the staged version")
	testing.eq(major_record, "staged", "and its journal stays")
	print("")


# Both ways a stage fails its check: a signature that no longer verifies, and a zip that no
# longer matches its manifest. Neither may leave a journal the exit would act on.
static func _test_stage_failing_its_check_gives_way(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a stage that fails its check gives way to the newer release")
	var server := UpdateFixtures.LoopbackReleaseServer.new(
			UpdateFixtures.release_assets("1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key()))
	var previous_host := UpdateFixtures.set_host(server.host())

	var world := UpdateFixtures.begin_world("installer_stage_zip", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage_tampered(world["updates"], "1.8.0", {"core/a.gd": "older"}, "1.1.0", UpdateFixtures.key())
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var zip_state_at_start := installer.state()
	var frames := 0
	while installer.state() != "available" and frames < _MAX_FRAMES:
		server.poll()
		await tree.process_frame
		frames += 1
	var zip_state := installer.state()
	var zip_version := installer.version()
	var zip_record: String = UpdateJournal.read(world["updates"])["state"]
	var zip_left := UpdateFixtures.has_release_file(world, "1.8.0", ReleaseAssets.archive_name("1.8.0"))
	UpdateFixtures.end_world(world, nodes)

	world = UpdateFixtures.begin_world("installer_stage_signature", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.8.0", {"core/a.gd": "older"}, "1.1.0", UpdateFixtures.key())
	var signature_path := UpdateFolder.version_folder("1.8.0", world["updates"]).path_join(ReleaseAssets.signature_name("1.8.0"))
	var signature := FileAccess.open(signature_path, FileAccess.WRITE)
	signature.store_string("no longer a signature")
	signature.close()
	nodes = UpdateFixtures.start_world(world, tree)
	installer = nodes["installer"]
	var signature_state_at_start := installer.state()
	var signature_frames := 0
	while installer.state() != "available" and signature_frames < _MAX_FRAMES:
		server.poll()
		await tree.process_frame
		signature_frames += 1
	var signature_state := installer.state()
	var signature_version := installer.version()
	var signature_record: String = UpdateJournal.read(world["updates"])["state"]
	UpdateFixtures.end_world(world, nodes)

	server.stop()
	UpdateFixtures.restore_host(previous_host)
	testing.eq(zip_state_at_start, "idle", "a staged zip that no longer matches → not offered at start")
	testing.eq(zip_state, "available", "the newer release → verified and offered")
	testing.eq(zip_version, "1.9.0", "about the newer version")
	testing.eq(zip_record, "", "the staged journal goes")
	testing.ok(not zip_left, "with the zip that no longer matches")
	testing.eq(signature_state_at_start, "idle", "a stage whose signature fails → not offered at start")
	testing.eq(signature_state, "available", "the newer release → verified and offered")
	testing.eq(signature_version, "1.9.0", "about the newer version")
	testing.eq(signature_record, "", "the staged journal goes")
	print("")


# A world whose 1.9.0 waits for the word, its zip served by a listener. Each frame stages
# one file, so a case can act between them.
static func _begin_click(purpose: String, tree: SceneTree) -> Dictionary:
	var world := UpdateFixtures.begin_world(purpose, "1.9.0", "ask", "1.1.0")
	var archive := UpdateFixtures.keep_verified(world["updates"], "1.9.0", _STAGED_FILES, UpdateFixtures.key())
	return _serve(world, archive, tree)


static func _serve(world: Dictionary, archive: PackedByteArray, tree: SceneTree) -> Dictionary:
	(world["options"] as Dictionary)["stage_budget_ms"] = 0
	var server := UpdateFixtures.LoopbackReleaseServer.new({ReleaseAssets.archive_name("1.9.0"): archive})
	var previous_host := UpdateFixtures.set_host(server.host())
	var nodes := UpdateFixtures.start_world(world, tree)
	return {"world": world, "nodes": nodes, "server": server, "previous_host": previous_host}


static func _end_click(click: Dictionary) -> void:
	UpdateFixtures.end_world(click["world"], click["nodes"])
	(click["server"] as UpdateFixtures.LoopbackReleaseServer).stop()
	UpdateFixtures.restore_host(str(click["previous_host"]))


static func _installer_of(click: Dictionary) -> UpdateInstaller:
	return (click["nodes"] as Dictionary)["installer"]


# Clicks Update and serves the download until the state moves on from it.
static func _click_and_download(click: Dictionary, tree: SceneTree) -> void:
	var installer := _installer_of(click)
	var server: UpdateFixtures.LoopbackReleaseServer = click["server"]
	installer.install()
	var frames := 0
	while installer.state() == "downloading" and frames < _MAX_FRAMES:
		server.poll()
		await tree.process_frame
		frames += 1


static func _wait_past_preparing(installer: UpdateInstaller, tree: SceneTree) -> void:
	var frames := 0
	while installer.state() == "preparing" and frames < _MAX_FRAMES:
		await tree.process_frame
		frames += 1


static func _record_state(world: Dictionary) -> String:
	return UpdateJournal.read(str(world["updates"]))["state"]


static func _has_stage(world: Dictionary) -> bool:
	return DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(UpdateFolder.stage_folder(str(world["updates"]))))


static func _has_zip(world: Dictionary) -> bool:
	return UpdateFixtures.has_release_file(world, "1.9.0", ReleaseAssets.archive_name("1.9.0"))


static func _has_manifest(world: Dictionary) -> bool:
	return UpdateFixtures.has_release_file(world, "1.9.0", ReleaseAssets.manifest_name("1.9.0"))


static func _test_click_stages_and_the_exit_applies(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a click stages the release and the exit applies it")
	var world := UpdateFixtures.begin_world("installer_click", "1.9.0", "ask", "1.1.0")
	# The release names a server other than this toolkit's, so the journal shows which one it keeps.
	var assets := UpdateFixtures.release_assets("1.9.0", _STAGED_FILES, UpdateFixtures.key())
	var archive: PackedByteArray = assets[ReleaseAssets.archive_name("1.9.0")]
	var fields: Dictionary = JSON.parse_string(UpdateFixtures.manifest_text("1.9.0", archive))
	fields["compatible_server"] = "0.9.0"
	var manifest := JSON.stringify(fields).to_utf8_buffer()
	var kept := ProjectSettings.globalize_path(UpdateFolder.version_folder("1.9.0", str(world["updates"])))
	FolderFiles.write_checked(kept.path_join(ReleaseAssets.manifest_name("1.9.0")), manifest)
	FolderFiles.write_checked(kept.path_join(ReleaseAssets.signature_name("1.9.0")),
			UpdateFixtures.signature_of(manifest, UpdateFixtures.key()))
	var click := _serve(world, archive, tree)
	var installer := _installer_of(click)
	await _click_and_download(click, tree)
	var after_download := installer.state()
	await _wait_past_preparing(installer, tree)
	var after_stage := installer.state()
	var found := installer.found_this_session()
	var journal := UpdateJournal.read(str(world["updates"]))
	var applied := UpdateLifecycle.apply_at_exit(world["options"])
	var installed := UpdateApplier.installed_version(ProjectSettings.globalize_path(str(world["addon"])))
	_end_click(click)
	testing.eq(after_download, "preparing", "the zip arrives → preparing")
	testing.eq(after_stage, "ready", "the stage is whole → ready")
	testing.ok(found, "and found this session")
	testing.eq(journal["state"], "staged", "the journal says staged")
	testing.eq(journal["compatible_server"], VersionUtils.COMPATIBLE_SERVER_VERSION,
			"and keeps the server version of the toolkit doing the staging")
	testing.eq(applied.get("state", ""), "applied", "the exit → applied")
	testing.eq(installed, "1.9.0", "the addon folder is the new version")
	print("")


static func _test_staged_at_start_opens_the_ready_view(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a staged release found at start opens the ready view")
	var world := UpdateFixtures.begin_world("installer_ready_view", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	var probe := UpdateFixtures.RestartProbeStandIn.new()
	(world["options"] as Dictionary)["restart_probe"] = probe
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var state := installer.state()
	var view_open := not installer.ready_view().is_empty()
	installer.close_ready_view()
	var view_closed := installer.ready_view().is_empty()
	var state_after_close := installer.state()
	UpdateFixtures.end_world(world, nodes)
	testing.eq(state, "ready", "the staged release → ready")
	testing.ok(view_open, "with the ready view open")
	testing.eq(probe.restarts, 0, "4.5, nothing found → still no restart")
	testing.ok(view_closed, "Not now closes the view")
	testing.eq(state_after_close, "ready", "and the release stays ready")
	print("")


static func _test_click_and_stage_restarts(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a click that stages on a clear 4.5 editor restarts it")
	var world := UpdateFixtures.begin_world("installer_click_restart", "1.9.0", "ask", "1.1.0")
	var archive := UpdateFixtures.keep_verified(world["updates"], "1.9.0", _STAGED_FILES, UpdateFixtures.key())
	# A file the release does not list, which the install deletes and the prompt warns about.
	UpdateFixtures.edit_installed_file(world, "notes.txt")
	var probe := UpdateFixtures.RestartProbeStandIn.new()
	(world["options"] as Dictionary)["restart_probe"] = probe
	var click := _serve(world, archive, tree)
	var installer := _installer_of(click)
	await _click_and_download(click, tree)
	var before_stage := probe.restarts
	await _wait_past_preparing(installer, tree)
	var state := installer.state()
	var view_empty := installer.ready_view().is_empty()
	var discarded := installer.discarded_files()
	_end_click(click)
	testing.eq(discarded, PackedStringArray(["notes.txt"]), "a file the release does not list → reported as deleted")
	testing.eq(before_stage, 0, "no restart before the stage is whole")
	testing.eq(state, "ready", "the stage is whole → ready")
	testing.eq(probe.restarts, 1, "and the editor restarts once")
	testing.ok(view_empty, "with no ready view")
	print("")


static func _test_leaving_the_tree_during_a_scan(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: leaving the tree while a scan holds the restart calls it off")
	var world := UpdateFixtures.begin_world("installer_leave_scan", "1.9.0", "ask", "1.1.0")
	var archive := UpdateFixtures.keep_verified(world["updates"], "1.9.0", _STAGED_FILES, UpdateFixtures.key())
	var probe := UpdateFixtures.RestartProbeStandIn.new()
	probe.scanning = true
	(world["options"] as Dictionary)["restart_probe"] = probe
	var click := _serve(world, archive, tree)
	var installer := _installer_of(click)
	await _click_and_download(click, tree)
	await _wait_past_preparing(installer, tree)
	var state := installer.state()
	tree.root.remove_child(installer)
	probe.scanning = false
	for _frame: int in 3:
		await tree.process_frame
	_end_click(click)
	testing.eq(state, "ready", "staged while a scan runs → ready")
	testing.eq(probe.restarts, 0, "left the tree, then the scan ends → no restart")
	print("")


static func _test_restart_refused_while_a_script_is_unsaved(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: Restart is refused while a script is unsaved")
	var world := UpdateFixtures.begin_world("installer_restart_refused", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	var probe := UpdateFixtures.RestartProbeStandIn.new()
	probe.unsaved_scripts = PackedStringArray(["player.gd"])
	(world["options"] as Dictionary)["restart_probe"] = probe
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	installer.close_ready_view()
	installer.restart_now()
	var refused := probe.restarts
	var shown: PackedStringArray = installer.ready_view().get(probe.UNSAVED_SCRIPTS, PackedStringArray())
	probe.unsaved_scripts = PackedStringArray()
	installer.restart_now()
	var open_before_discard := not installer.ready_view().is_empty()
	installer.discard()
	var closed_by_discard := installer.ready_view().is_empty()
	UpdateFixtures.end_world(world, nodes)
	testing.eq(refused, 0, "an unsaved script → no restart")
	testing.eq(shown, PackedStringArray(["player.gd"]), "the ready view opens again and names it")
	testing.eq(probe.restarts, 1, "the script saved, Restart → one restart")
	testing.ok(open_before_discard and closed_by_discard, "Don't install leaves ready → the ready view closes")
	print("")


static func _test_preparing_spans_frames(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: staging takes frames, with a verified journal until it ends")
	var click := _begin_click("installer_frames", tree)
	var world: Dictionary = click["world"]
	var installer := _installer_of(click)
	await _click_and_download(click, tree)
	var journal_during := _record_state(world)
	var frames := 0
	while installer.state() == "preparing" and frames < _MAX_FRAMES:
		await tree.process_frame
		frames += 1
	var final_state := installer.state()
	_end_click(click)
	# Five files at one a frame; the frame the zip arrived on may already have written one.
	testing.ok(frames >= 4, "the state stays preparing over the frames the five files take")
	testing.eq(journal_during, "verified", "while it runs the journal says verified")
	testing.eq(final_state, "ready", "and it ends ready")
	print("")


static func _test_runner_signal_during_a_stage(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: the update check's signal does not interrupt a stage")
	var click := _begin_click("installer_signal", tree)
	var world: Dictionary = click["world"]
	var installer := _installer_of(click)
	await _click_and_download(click, tree)
	var before := installer.state()
	((click["nodes"] as Dictionary)["runner"] as UpdateCheckRunner).state_changed.emit()
	var after_signal := installer.state()
	var journal_after_signal := _record_state(world)
	await _wait_past_preparing(installer, tree)
	var final_state := installer.state()
	var final_journal := _record_state(world)
	_end_click(click)
	testing.eq(before, "preparing", "the signal comes while preparing")
	testing.eq(after_signal, "preparing", "the state does not move")
	testing.eq(journal_after_signal, "verified", "the journal stays")
	testing.eq(final_state, "ready", "and the stage still ends ready")
	testing.eq(final_journal, "staged", "with a staged journal")
	print("")


# The zip matches its signed manifest, so only the list inside it can refuse it.
static func _test_zip_that_fails_its_list(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a zip that fails its own list leaves only the manifest")
	var world := UpdateFixtures.begin_world("installer_list", "1.9.0", "ask", "1.1.0")
	var entries := UpdateFixtures.release_entries("1.9.0", _STAGED_FILES)
	entries["addons/godot_mcp_toolkit/core/b.gd"] = "not what the list says"
	var zip_path := UpdateFixtures.scratch("installer_list.zip")
	UpdateFixtures.write_zip(zip_path, entries)
	var archive := FileAccess.get_file_as_bytes(zip_path)
	UpdateFixtures.remove(zip_path)
	var manifest := UpdateFixtures.manifest_text("1.9.0", archive).to_utf8_buffer()
	var kept := ProjectSettings.globalize_path(UpdateFolder.version_folder("1.9.0", str(world["updates"])))
	FolderFiles.write_checked(kept.path_join(ReleaseAssets.manifest_name("1.9.0")), manifest)
	FolderFiles.write_checked(kept.path_join(ReleaseAssets.signature_name("1.9.0")),
			UpdateFixtures.signature_of(manifest, UpdateFixtures.key()))
	var click := _serve(world, archive, tree)
	var installer := _installer_of(click)
	await _click_and_download(click, tree)
	await _wait_past_preparing(installer, tree)
	var state := installer.state()
	var error := installer.error_text()
	var record := _record_state(world)
	var stage_left := _has_stage(world)
	var zip_left := _has_zip(world)
	var manifest_left := _has_manifest(world)
	_end_click(click)
	testing.eq(state, "failed", "the click's failure → failed")
	testing.eq(error, "the archive's core/b.gd does not match its file list", "and it says which file")
	testing.eq(record, "", "no journal")
	testing.ok(not stage_left, "no stage")
	testing.ok(not zip_left, "no zip")
	testing.ok(manifest_left, "the manifest stays for the next start")
	print("")


static func _test_discard_during_a_stage(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: giving an update up while it stages")
	var click := _begin_click("installer_discard_stage", tree)
	var world: Dictionary = click["world"]
	var installer := _installer_of(click)
	await _click_and_download(click, tree)
	await tree.process_frame
	await tree.process_frame
	var state_before := installer.state()
	var stage_before := _has_stage(world)
	installer.discard()
	var state_after := installer.state()
	for _frame: int in range(8):
		await tree.process_frame
	var state_later := installer.state()
	# The file itself: a record about no version reads as no journal, yet it is one.
	var journal_left := UpdateJournal.exists(str(world["updates"]))
	var stage_left := _has_stage(world)
	var zip_left := _has_zip(world)
	var badge := ((click["nodes"] as Dictionary)["runner"] as UpdateCheckRunner).badge_version()
	_end_click(click)
	testing.eq(state_before, "preparing", "the discard comes while preparing")
	testing.ok(stage_before, "with part of a stage written")
	testing.eq(state_after, "idle", "discard → idle")
	testing.eq(state_later, "idle", "and nothing finishes later")
	testing.ok(not journal_left, "no journal")
	testing.ok(not stage_left, "no stage")
	testing.ok(not zip_left, "no zip")
	testing.eq(badge, "", "the version → dismissed until a newer one")
	print("")


# The dock can react to the state by giving the update up, in the same call that starts the
# stage, so the run has to exist by then or it outlives the discard.
static func _test_discard_from_the_preparing_handler(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a handler of the preparing state can give the update up")
	var click := _begin_click("installer_discard_handler", tree)
	var world: Dictionary = click["world"]
	var installer := _installer_of(click)
	# Holds "discarded" once the handler's discard returns, then each state change after it.
	var after_discard := []
	installer.state_changed.connect(func() -> void:
		if not after_discard.is_empty():
			after_discard.append(installer.state())
		elif installer.state() == "preparing":
			installer.discard()
			after_discard.append("discarded"))
	await _click_and_download(click, tree)
	for _frame: int in range(8):
		await tree.process_frame
	var state := installer.state()
	var journal_left := UpdateJournal.exists(str(world["updates"]))
	var stage_left := _has_stage(world)
	_end_click(click)
	testing.eq(state, "idle", "the discard stands")
	testing.ok(not journal_left, "no journal")
	testing.ok(not stage_left, "and no stage appears afterwards")
	testing.eq(after_discard, ["discarded"], "and no run the discard missed changes the state later")
	print("")


# The installer leaves the tree as the editor closes, so its exit and the next start see what
# leaving left.
static func _test_leaving_the_tree_during_a_stage(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: leaving the tree during a stage installs nothing")
	var click := _begin_click("installer_leave", tree)
	var world: Dictionary = click["world"]
	var options: Dictionary = world["options"]
	var installer := _installer_of(click)
	await _click_and_download(click, tree)
	await tree.process_frame
	await tree.process_frame
	var state_before := installer.state()
	var stage_before := _has_stage(world)
	tree.root.remove_child(installer)
	var stage_after := _has_stage(world)
	var applied := UpdateLifecycle.apply_at_exit(options)
	var installed := UpdateApplier.installed_version(ProjectSettings.globalize_path(str(world["addon"])))
	var settled := UpdateLifecycle.settle_at_start(options)
	var record := _record_state(world)
	var zip_left := _has_zip(world)
	_end_click(click)
	testing.eq(state_before, "preparing", "it leaves while preparing")
	testing.ok(stage_before, "with part of a stage written")
	testing.ok(not stage_after, "leaving → no stage")
	testing.eq(applied, {"state": "", "reason": ""}, "the exit → applies nothing")
	testing.eq(installed, "1.1.0", "the addon folder stays as it was")
	testing.eq(settled.get("report", "none"), "", "the next start → nothing to show")
	testing.eq(record, "", "and it clears the journal")
	testing.ok(not zip_left, "and the zip")
	print("")


# The runner reports the installed version, so it offers nothing newer.
static func _test_staged_outlives_no_newer_version(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a staged journal outlives an empty newer version")
	var world := UpdateFixtures.begin_world("installer_staged_no_newer", "1.1.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	var nodes := UpdateFixtures.start_world(world, tree)
	var newer := (nodes["runner"] as UpdateCheckRunner).badge_version()
	var installer: UpdateInstaller = nodes["installer"]
	var state := installer.state()
	var version := installer.version()
	var record := _record_state(world)
	UpdateFixtures.end_world(world, nodes)
	testing.eq(newer, "", "the runner offers no newer version")
	testing.eq(state, "ready", "the staged release → still ready")
	testing.eq(version, "1.9.0", "about the staged version")
	testing.eq(record, "staged", "and its journal stays")
	print("")


static func _test_staged_outlives_the_check_turned_off(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a staged journal outlives the update check turned off")
	var world := UpdateFixtures.begin_world("installer_staged_check_off", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	Consent.set_readers(func() -> bool: return false, func(_step_id: StringName) -> bool: return true)
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var state := installer.state()
	var record := _record_state(world)
	UpdateFixtures.end_world(world, nodes)
	testing.eq(state, "ready", "the check off → the staged release is still ready")
	testing.eq(record, "staged", "and its journal stays")
	print("")


static func _test_manual_mode_clears_a_staged_journal(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: the manual mode clears a staged journal")
	var world := UpdateFixtures.begin_world("installer_staged_manual", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var before := installer.state()
	((world["options"] as Dictionary)["project_settings"] as UpdateFixtures.ModeSettings).set_mode("manual")
	installer.reevaluate()
	var after := installer.state()
	var journal_left := UpdateJournal.exists(str(world["updates"]))
	var stage_left := _has_stage(world)
	var badge := (nodes["runner"] as UpdateCheckRunner).badge_version()
	UpdateFixtures.end_world(world, nodes)
	testing.eq(before, "ready", "a staged release in the ask mode → ready")
	testing.eq(after, "idle", "the mode set to manual → idle")
	testing.ok(not journal_left, "no journal")
	testing.ok(not stage_left, "no stage")
	testing.eq(badge, "1.9.0", "the version is still offered as a link")
	print("")


static func _test_manual_mode_during_a_stage(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: the manual mode during a stage calls it off")
	var world := UpdateFixtures.begin_world("installer_manual_stage", "1.9.0", "ask", "1.1.0")
	var archive := UpdateFixtures.keep_verified(world["updates"], "1.9.0", _STAGED_FILES, UpdateFixtures.key())
	var probe := UpdateFixtures.RestartProbeStandIn.new()
	(world["options"] as Dictionary)["restart_probe"] = probe
	var click := _serve(world, archive, tree)
	var installer := _installer_of(click)
	await _click_and_download(click, tree)
	var before := installer.state()
	((world["options"] as Dictionary)["project_settings"] as UpdateFixtures.ModeSettings).set_mode("manual")
	installer.reevaluate()
	for _frame: int in range(8):
		await tree.process_frame
	var state := installer.state()
	var journal_left := UpdateJournal.exists(str(world["updates"]))
	var stage_left := _has_stage(world)
	var badge := ((click["nodes"] as Dictionary)["runner"] as UpdateCheckRunner).badge_version()
	_end_click(click)
	testing.eq(before, "preparing", "the mode changes while preparing")
	testing.eq(state, "idle", "→ idle, and nothing finishes later")
	testing.ok(not journal_left, "no journal")
	testing.ok(not stage_left, "no stage")
	testing.eq(probe.restarts, 0, "no restart")
	testing.eq(badge, "1.9.0", "the version is not dismissed")
	print("")


# The server is polled only after the mode changes, so the zip request is still open when
# it does; the frames served after it show that nothing the request brings back finishes.
static func _test_manual_mode_during_a_download(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: the manual mode during a download calls it off")
	var click := _begin_click("installer_manual_download", tree)
	var world: Dictionary = click["world"]
	var installer := _installer_of(click)
	var server: UpdateFixtures.LoopbackReleaseServer = click["server"]
	installer.install()
	var before := installer.state()
	((world["options"] as Dictionary)["project_settings"] as UpdateFixtures.ModeSettings).set_mode("manual")
	installer.reevaluate()
	for _frame: int in range(60):
		server.poll()
		await tree.process_frame
	var state := installer.state()
	var journal_left := UpdateJournal.exists(str(world["updates"]))
	var stage_left := _has_stage(world)
	var version_folder_left := DirAccess.dir_exists_absolute(
			ProjectSettings.globalize_path(UpdateFolder.version_folder("1.9.0", str(world["updates"]))))
	var badge := ((click["nodes"] as Dictionary)["runner"] as UpdateCheckRunner).badge_version()
	_end_click(click)
	testing.eq(before, "downloading", "the mode changes while downloading")
	testing.eq(state, "idle", "→ idle, and nothing finishes later")
	testing.ok(not journal_left, "no journal")
	testing.ok(not stage_left, "no stage")
	testing.ok(not version_folder_left, "no version folder")
	testing.eq(badge, "1.9.0", "the version is not dismissed")
	print("")


# Each leg leaves a click failed in the ask mode, then closes one gate. The real project
# setting is restored before the assertions, so a failure never leaves it changed.
static func _test_try_again_follows_the_gates(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: Try again follows the gates")
	var real_world := UpdateFixtures.begin_world("installer_retry_setting", "1.9.0", "ask", "1.1.0")
	(real_world["options"] as Dictionary).erase("project_settings")
	var had_mode := ProjectSettings.has_setting(InstallMode.SETTING)
	var previous_mode: Variant = ProjectSettings.get_setting(InstallMode.SETTING) if had_mode else null
	ProjectSettings.set_setting(InstallMode.SETTING, "ask")
	var real_click: Dictionary = await _begin_failed_click(real_world, tree)
	var real_failed := _installer_of(real_click).state()
	ProjectSettings.set_setting(InstallMode.SETTING, "manual")
	# The engine sends settings_changed deferred.
	for _frame: int in range(2):
		await tree.process_frame
	var real_after := _installer_of(real_click).state()
	ProjectSettings.set_setting(InstallMode.SETTING, previous_mode)
	_end_click(real_click)

	var manual_world := UpdateFixtures.begin_world("installer_retry_manual", "1.9.0", "ask", "1.1.0")
	var manual_click: Dictionary = await _begin_failed_click(manual_world, tree)
	((manual_world["options"] as Dictionary)["project_settings"] as UpdateFixtures.ModeSettings).set_mode("manual")
	var manual_requests: int = await _requests_on_retry(manual_click, tree)
	var manual_record := _record_state(manual_world)
	var manual_stage := _has_stage(manual_world)
	var manual_zip := _has_zip(manual_world)
	_end_click(manual_click)

	var unseen_world := UpdateFixtures.begin_world("installer_retry_unseen", "1.9.0", "ask", "1.1.0")
	var unseen_click: Dictionary = await _begin_failed_click(unseen_world, tree)
	Consent.set_readers(func() -> bool: return true, func(_step_id: StringName) -> bool: return false)
	var unseen_requests: int = await _requests_on_retry(unseen_click, tree)
	var unseen_record := _record_state(unseen_world)
	var unseen_stage := _has_stage(unseen_world)
	var unseen_zip := _has_zip(unseen_world)
	_end_click(unseen_click)

	var kept_world := UpdateFixtures.begin_world("installer_retry_kept", "1.9.0", "ask", "1.1.0")
	var kept_click: Dictionary = await _begin_failed_click(kept_world, tree)
	_installer_of(kept_click).reevaluate()
	var kept_state := _installer_of(kept_click).state()
	_end_click(kept_click)

	testing.eq(real_failed, "failed", "the project setting at ask → the click fails")
	testing.eq(real_after, "idle", "the project setting turned to manual → the failure clears to idle")
	testing.eq(manual_requests, 0, "the manual mode → Try again sends no request")
	testing.eq(manual_record, "", "the manual mode → Try again writes no journal")
	testing.ok(not manual_stage, "the manual mode → Try again stages nothing")
	testing.ok(not manual_zip, "the manual mode → Try again downloads no zip")
	testing.eq(unseen_requests, 0, "the setup step unseen → Try again sends no request")
	testing.eq(unseen_record, "", "the setup step unseen → Try again writes no journal")
	testing.ok(not unseen_stage, "the setup step unseen → Try again stages nothing")
	testing.ok(not unseen_zip, "the setup step unseen → Try again downloads no zip")
	testing.eq(kept_state, "failed", "the ask mode kept → the failure stays after a re-evaluation")
	print("")


# The server holds the zip's request, so the download is under way when cancel() runs. The
# held request gets no reply, so this row cannot show the Windows lock on a zip being written
# that the cancel exists for; it pins that the cancel ends the download and a journal clear
# then leaves nothing.
static func _test_cancel_lets_the_journal_go(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: cancel() calls off a download before the journal clears")
	var click := _begin_click("installer_cancel_download", tree)
	var world: Dictionary = click["world"]
	var installer := _installer_of(click)
	var server: UpdateFixtures.LoopbackReleaseServer = click["server"]
	var archive_name := ReleaseAssets.archive_name("1.9.0")
	server.hold("/" + archive_name)
	installer.install()
	var frames := 0
	while not _requested(server, archive_name) and frames < _MAX_FRAMES:
		server.poll()
		await tree.process_frame
		frames += 1
	var before := installer.state()
	var journal_before := UpdateJournal.exists(str(world["updates"]))
	installer.cancel()
	UpdateJournal.clear(str(world["updates"]))
	var connections_after_cancel := server.connections()
	for _frame: int in range(30):
		server.poll()
		await tree.process_frame
	var new_connections := server.connections() - connections_after_cancel
	var journal_left := UpdateJournal.exists(str(world["updates"]))
	var zip_left := _has_zip(world)
	_end_click(click)
	testing.eq(before, "downloading", "the zip's request is held while downloading")
	testing.ok(journal_before, "with a journal")
	testing.ok(not journal_left, "cancel(), then a journal clear → no journal")
	testing.ok(not zip_left, "and no zip")
	testing.eq(new_connections, 0, "and nothing is requested after the cancel")
	print("")


static func _requested(server: UpdateFixtures.LoopbackReleaseServer, path_end: String) -> bool:
	for path: String in server.paths():
		if path.ends_with(path_end):
			return true
	return false


# Clicks Update on a kept 1.9.0 whose zip the server 404s, and waits for the failure.
# Returns the click, for _end_click.
static func _begin_failed_click(world: Dictionary, tree: SceneTree) -> Dictionary:
	UpdateFixtures.keep_verified(world["updates"], "1.9.0", _STAGED_FILES, UpdateFixtures.key())
	var server := UpdateFixtures.LoopbackReleaseServer.new({})
	var previous_host := UpdateFixtures.set_host(server.host())
	var nodes := UpdateFixtures.start_world(world, tree)
	var click := {"world": world, "nodes": nodes, "server": server, "previous_host": previous_host}
	await _click_and_download(click, tree)
	return click


# Clicks Try again and serves 120 frames. Returns how many requests the click sent.
static func _requests_on_retry(click: Dictionary, tree: SceneTree) -> int:
	var server: UpdateFixtures.LoopbackReleaseServer = click["server"]
	var before := server.connections()
	_installer_of(click).install()
	for _frame: int in range(120):
		server.poll()
		await tree.process_frame
	return server.connections() - before


static func _test_settled(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: what the start's settle found")
	var world := UpdateFixtures.begin_world("installer_settled_waiting", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	var journal := UpdateJournal.read(str(world["updates"]))
	journal["reason"] = "could not rename the addon folder"
	journal["attempts"] = 1
	UpdateJournal.write(journal, str(world["updates"]))
	var nodes := UpdateFixtures.start_world(world, tree)
	var waiting := (nodes["installer"] as UpdateInstaller).settled()
	var waiting_notice := (nodes["installer"] as UpdateInstaller).notice()
	UpdateFixtures.end_world(world, nodes)
	world = UpdateFixtures.begin_world("installer_settled_updated", "1.9.0", "ask", "1.9.0")
	UpdateJournal.write({"state": "applied", "to": "1.9.0", "from": "1.1.0"}, world["updates"])
	nodes = UpdateFixtures.start_world(world, tree)
	var updated := (nodes["installer"] as UpdateInstaller).settled()
	UpdateFixtures.end_world(world, nodes)
	testing.eq(waiting.get("report", ""), "waiting", "a stage that waits → reported as waiting")
	testing.eq(waiting.get("reason", ""), "could not rename the addon folder", "with why the last exit postponed it")
	testing.eq(waiting_notice, {}, "which is no notice")
	testing.eq(updated.get("report", ""), "updated", "an applied record the editor now runs → reported as updated")
	testing.eq(updated.get("to", ""), "1.9.0", "about that version")
	print("")


static func _test_postponed_reason(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: why the last exit left the staged update waiting")
	var world := UpdateFixtures.begin_world("installer_postponed", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	var journal := UpdateJournal.read(str(world["updates"]))
	journal["reason"] = "could not rename the addon folder"
	journal["attempts"] = 1
	UpdateJournal.write(journal, str(world["updates"]))
	var nodes := UpdateFixtures.start_world(world, tree)
	var postponed := (nodes["installer"] as UpdateInstaller).postponed_reason()
	UpdateFixtures.end_world(world, nodes)

	world = UpdateFixtures.begin_world("installer_postponed_fresh", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	nodes = UpdateFixtures.start_world(world, tree)
	var fresh_state := (nodes["installer"] as UpdateInstaller).state()
	var fresh := (nodes["installer"] as UpdateInstaller).postponed_reason()
	UpdateFixtures.end_world(world, nodes)

	world = UpdateFixtures.begin_world("installer_postponed_headless", "1.9.0", "ask", "1.1.0")
	(world["options"] as Dictionary)["guard_facts"] = {"headless": true}
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	journal = UpdateJournal.read(str(world["updates"]))
	journal["reason"] = "could not rename the addon folder"
	journal["attempts"] = 1
	UpdateJournal.write(journal, str(world["updates"]))
	nodes = UpdateFixtures.start_world(world, tree)
	var headless_settled := (nodes["installer"] as UpdateInstaller).settled()
	var headless := (nodes["installer"] as UpdateInstaller).postponed_reason()
	UpdateFixtures.end_world(world, nodes)

	testing.eq(postponed, "could not rename the addon folder", "an exit that tried and failed → its reason")
	testing.eq(fresh_state, "ready", "a stage no exit has tried yet → ready")
	testing.eq(fresh, "", "with no reason")
	testing.eq(headless_settled, {}, "a headless start runs no settle")
	testing.eq(headless, "", "so there is no reason")
	print("")


# A staged release and either what the runner reports or nothing at all: both paths through
# the installer's gates clear a journal in an editor that may not install.
static func _test_headless_start_keeps_a_journal(testing: Testing, tree: SceneTree, latest: String) -> void:
	testing.begin("Update installer: a headless start keeps a journal, newer version '%s'" % latest)
	var world := UpdateFixtures.begin_world("installer_headless_" + latest.replace(".", "_"), latest, "ask", "1.1.0")
	(world["options"] as Dictionary)["guard_facts"] = {"headless": true}
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	var journal_path := str(world["updates"]).path_join("journal.json")
	var journal_before := FileAccess.get_file_as_bytes(journal_path)
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var state := installer.state()
	var version := installer.version()
	var note := installer.note_text()
	var settled := installer.settled()
	var journal_after := FileAccess.get_file_as_bytes(journal_path)
	var stage_left := _has_stage(world)
	var zip_left := _has_zip(world)
	var manifest_left := _has_manifest(world)
	UpdateFixtures.end_world(world, nodes)
	testing.eq(state, "idle", "the state is idle")
	testing.eq(version, latest, "about what the runner reports")
	testing.eq(note, "A headless editor never installs updates.", "and the guard's sentence is the note")
	testing.eq(settled, {}, "no settle ran")
	testing.ok(not journal_before.is_empty(), "there is a journal to keep")
	testing.eq(journal_after, journal_before, "the journal's bytes are unchanged")
	testing.ok(stage_left, "the stage stays")
	testing.ok(zip_left, "the zip stays")
	testing.ok(manifest_left, "the manifest stays")
	print("")


static func _test_headless_start_keeps_a_kept_release(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a headless start keeps a verified release with no journal")
	var world := UpdateFixtures.begin_world("installer_headless_kept", "1.9.0", "ask", "1.1.0")
	(world["options"] as Dictionary)["guard_facts"] = {"headless": true}
	UpdateFixtures.keep_verified(world["updates"], "1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key())
	var nodes := UpdateFixtures.start_world(world, tree)
	var state := (nodes["installer"] as UpdateInstaller).state()
	var manifest_left := _has_manifest(world)
	var signature_left := UpdateFixtures.has_release_file(world, "1.9.0", ReleaseAssets.signature_name("1.9.0"))
	UpdateFixtures.end_world(world, nodes)
	testing.eq(state, "idle", "the state is idle")
	testing.ok(manifest_left, "the manifest stays")
	testing.ok(signature_left, "the signature stays")
	print("")


static func _test_headless_override_reads_ready(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: the override lets a headless editor read a staged release")
	var world := UpdateFixtures.begin_world("installer_headless_override", "1.9.0", "ask", "1.1.0")
	(world["options"] as Dictionary)["guard_facts"] = {"headless": true, "headless_allowed": true}
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var state := installer.state()
	var note := installer.note_text()
	var report := str(installer.settled().get("report", "none"))
	UpdateFixtures.end_world(world, nodes)
	testing.eq(state, "ready", "a staged release → ready")
	testing.eq(note, "", "with no note")
	testing.eq(report, "waiting", "and the settle ran")
	print("")


# The first listener is the host variable's address. The second serves the zip on another
# port, so a request reaching it means the hop was followed: an unreachable host would also
# end in a failure, which alone proves nothing. The credentials form connects to the second
# listener wherever the engine reads the URL itself.
static func _test_off_list_redirect_of_the_zip(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a zip redirected off the list is refused")
	var zip_name := ReleaseAssets.archive_name("1.9.0")
	for form: String in ["http://127.0.0.1:%d/", "http://github.com@127.0.0.1:%d/"]:
		var world := UpdateFixtures.begin_world("installer_off_list_zip", "1.9.0", "ask", "1.1.0")
		var archive_bytes := UpdateFixtures.keep_verified(world["updates"], "1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key())
		var second := UpdateFixtures.LoopbackReleaseServer.new({zip_name: archive_bytes})
		var first := UpdateFixtures.LoopbackReleaseServer.new({})
		first.redirect("/" + zip_name, 302, (form % int(second.host().get_slice(":", 2))) + zip_name)
		var previous_host := UpdateFixtures.set_host(first.host())
		var nodes := UpdateFixtures.start_world(world, tree)
		var installer: UpdateInstaller = nodes["installer"]
		installer.install()
		var frames := 0
		while installer.state() == "downloading" and frames < _MAX_FRAMES:
			first.poll()
			second.poll()
			await tree.process_frame
			frames += 1
		second.poll()
		var state := installer.state()
		var second_hits := second.connections()
		var zip_left := UpdateFixtures.has_release_file(world, "1.9.0", zip_name)
		UpdateFixtures.end_world(world, nodes)
		first.stop()
		second.stop()
		UpdateFixtures.restore_host(previous_host)
		testing.eq(second_hits, 0, "%s → no request reaches it" % form)
		testing.eq(state, "failed", "%s → the click's download fails" % form)
		testing.ok(not zip_left, "%s → no zip stays" % form)
	print("")


static func _test_off_list_redirect_during_a_verify(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a manifest redirected off the list is refused")
	var assets := UpdateFixtures.release_assets("1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key())
	var second := UpdateFixtures.LoopbackReleaseServer.new(assets)
	var first := UpdateFixtures.LoopbackReleaseServer.new({})
	for asset_name: String in [ReleaseAssets.manifest_name("1.9.0"), ReleaseAssets.signature_name("1.9.0")]:
		first.redirect("/" + asset_name, 302, second.host() + "/" + asset_name)
	var previous_host := UpdateFixtures.set_host(first.host())
	var world := UpdateFixtures.begin_world("installer_off_list_verify", "1.9.0", "ask", "1.1.0")
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var changes := [0]
	installer.state_changed.connect(func() -> void: changes[0] += 1)
	var frames := 0
	while changes[0] == 0 and frames < _MAX_FRAMES:
		first.poll()
		second.poll()
		await tree.process_frame
		frames += 1
	second.poll()
	var state := installer.state()
	var security_failed := installer.security_check_failed()
	var second_hits := second.connections()
	var manifest_asked := _requested(first, ReleaseAssets.manifest_name("1.9.0"))
	UpdateFixtures.end_world(world, nodes)
	first.stop()
	second.stop()
	UpdateFixtures.restore_host(previous_host)
	testing.ok(frames < _MAX_FRAMES, "the verify ends within %d frames" % _MAX_FRAMES)
	testing.ok(manifest_asked, "the walk reaches the manifest at the first listener")
	testing.eq(second_hits, 0, "the second listener → no request reaches it")
	testing.ok(security_failed, "the hop off the list → a failed security check")
	testing.eq(state, "idle", "and with no click, the installer stays idle")
	print("")


# 303, 307 and 308 are plain replies to the engine up to 4.6, so only the toolkit's own
# following gets past them there.
static func _test_redirects_every_engine_must_follow(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a 303, 307 or 308 is followed")
	var assets := UpdateFixtures.release_assets("1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key())
	for code: int in [303, 307, 308]:
		var moved := {}
		for asset_name: String in assets:
			moved["moved-" + asset_name] = assets[asset_name]
		var server := UpdateFixtures.LoopbackReleaseServer.new(moved)
		for asset_name: String in assets:
			server.redirect("/" + asset_name, code, "%s/moved-%s" % [server.host(), asset_name])
		var previous_host := UpdateFixtures.set_host(server.host())
		var world := UpdateFixtures.begin_world("installer_redirect_%d" % code, "1.9.0", "ask", "1.1.0")
		var nodes := UpdateFixtures.start_world(world, tree)
		var installer: UpdateInstaller = nodes["installer"]
		var changes := [0]
		installer.state_changed.connect(func() -> void: changes[0] += 1)
		var frames := 0
		while changes[0] == 0 and frames < _MAX_FRAMES:
			server.poll()
			await tree.process_frame
			frames += 1
		var state := installer.state()
		var connections := server.connections()
		UpdateFixtures.end_world(world, nodes)
		server.stop()
		UpdateFixtures.restore_host(previous_host)
		testing.eq(state, "available", "%d on the manifest and signature → verified" % code)
		testing.eq(connections, 5, "%d → the chain's 404, then each file's redirect and the file" % code)
	print("")
