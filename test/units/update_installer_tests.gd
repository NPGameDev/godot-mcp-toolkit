@tool
extends RefCounted
## Unit tests for the update installer: the notice an apply leaves for the next start,
## picking up a kept or staged release, the gates that keep it idle, giving an update up,
## and a failed, killed or redirected download, served by a loopback listener. A download
## that succeeds runs in the update flow integration test
## (scripts/test_framework/update_flow.sh).

const Testing := preload("res://test/units/testing.gd")
const UpdateInstaller := preload("res://addons/godot_mcp_toolkit/self_update/update_installer.gd")
const UpdateCheckRunner := preload("res://addons/godot_mcp_toolkit/versioning/update_check_runner.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const UpdateJournal := preload("res://addons/godot_mcp_toolkit/self_update/update_journal.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const InstallMode := preload("res://addons/godot_mcp_toolkit/self_update/install_mode.gd")
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
	await _test_cut_download_leaves_no_partial_zip(testing, tree)
	await _test_found_this_session(testing, tree)
	await _test_start_offers_kept_release_without_requests(testing, tree)
	_test_kept_release_above_this_editor(testing, tree)
	_test_killed_download(testing, tree)
	_test_verified_journal_found_after_start(testing, tree)
	_test_staged_zip_that_will_not_delete(testing, tree)
	await _test_staged_release_stands(testing, tree)
	await _test_stage_failing_its_check_gives_way(testing, tree)
	await _test_off_list_redirect_of_the_zip(testing, tree)
	await _test_off_list_redirect_during_a_verify(testing, tree)
	await _test_redirects_every_engine_must_follow(testing, tree)


# With no stand-in in its options, the installer reads the project setting. Restored
# before the assertions, so a failure never leaves the project settings changed.
static func _test_project_install_mode(testing) -> void:
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


static func _test_notice_updated(testing, tree: SceneTree) -> void:
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


static func _test_notice_failed(testing, tree: SceneTree) -> void:
	testing.begin("Update installer: the notice after a failed install")
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
	testing.eq(not_applied, {"kind": "failed", "version": "1.9.0", "from_version": "1.1.0",
			"reason": "could not write core/a.gd", "server_changed": false}, "a not-applied record → failed, with its reason")
	testing.eq(not_loaded["reason"], "the editor started version 1.1.0",
			"an applied record the editor does not run → failed, naming the version it runs")
	print("")


static func _test_verified_record(testing, tree: SceneTree) -> void:
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


static func _test_gates(testing, tree: SceneTree) -> void:
	testing.begin("Update installer: the gates keep it idle")
	var world := UpdateFixtures.begin_world("installer_manual", "1.9.0", "manual", "1.1.0")
	UpdateFixtures.keep_verified(world["updates"], "1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key())
	var manifest_name := ReleaseAssets.manifest_name("1.9.0")
	var manual_kept_before := UpdateFixtures.has_release_file(world, "1.9.0", manifest_name)
	var nodes := UpdateFixtures.start_world(world, tree)
	var manual := (nodes["installer"] as UpdateInstaller).state()
	var manual_kept_after := UpdateFixtures.has_release_file(world, "1.9.0", manifest_name)
	UpdateFixtures.end_world(world, nodes)

	world = UpdateFixtures.begin_world("installer_no_keys", "1.9.0", "ask", "1.1.0")
	(world["options"] as Dictionary)["trust_document"] = ""
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
	testing.ok(manual_kept_before and not manual_kept_after, "and a kept release is given up")
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
	var host_env := "GODOT_MCP_UPDATE_CHECK_HOST"
	var previous_host := OS.get_environment(host_env)
	OS.set_environment(host_env, "http://127.0.0.1:%d" % server.get_local_port())
	var world := UpdateFixtures.begin_world("installer_cut", "1.9.0", "ask", "1.1.0")
	var archive_bytes := UpdateFixtures.keep_verified(world["updates"], "1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key())
	var archive := ProjectSettings.globalize_path(UpdateFolder.archive_path("1.9.0", world["updates"]))
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var record_before: String = UpdateJournal.read(world["updates"])["state"]
	installer.install()
	var record_during: String = UpdateJournal.read(world["updates"])["state"]
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
	var record_after: String = UpdateJournal.read(world["updates"])["state"]
	var manifest_left := UpdateFixtures.has_release_file(world, "1.9.0", ReleaseAssets.manifest_name("1.9.0"))
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
	testing.ok(not restored, "a release an earlier session kept → not found this session")
	testing.ok(frames < 1200, "the release is verified within 1200 frames")
	testing.ok(verified, "a release verified during the session → found this session")
	print("")


# One start verifies the release over a loopback listener; the next finds what it kept.
# The first start's two connections show the listener sees requests, so the second's
# zero means none were sent.
static func _test_start_offers_kept_release_without_requests(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update installer: a start offers a kept release without fetching it again")
	var server := UpdateFixtures.LoopbackReleaseServer.new(
			UpdateFixtures.release_assets("1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key()))
	var previous_host := OS.get_environment(UpdateFixtures.HOST_ENV)
	OS.set_environment(UpdateFixtures.HOST_ENV, server.host())
	var world := UpdateFixtures.begin_world("installer_kept", "1.9.0", "ask", "1.1.0")
	var first_start := UpdateFixtures.start_world(world, tree)
	var frames := 0
	while (first_start["installer"] as UpdateInstaller).state() != "available" and frames < 1200:
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
	if previous_host.is_empty():
		OS.unset_environment(UpdateFixtures.HOST_ENV)
	else:
		OS.set_environment(UpdateFixtures.HOST_ENV, previous_host)
	testing.ok(frames < 1200, "the first start verifies within 1200 frames")
	testing.eq(first_connections, 2, "the first start → the manifest and the signature fetched")
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
	var previous_host := OS.get_environment(UpdateFixtures.HOST_ENV)
	OS.set_environment(UpdateFixtures.HOST_ENV, server.host())
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
	if previous_host.is_empty():
		OS.unset_environment(UpdateFixtures.HOST_ENV)
	else:
		OS.set_environment(UpdateFixtures.HOST_ENV, previous_host)
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
	var previous_host := OS.get_environment(UpdateFixtures.HOST_ENV)
	OS.set_environment(UpdateFixtures.HOST_ENV, server.host())
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
	if previous_host.is_empty():
		OS.unset_environment(UpdateFixtures.HOST_ENV)
	else:
		OS.set_environment(UpdateFixtures.HOST_ENV, previous_host)
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
	var previous_host := OS.get_environment(UpdateFixtures.HOST_ENV)
	OS.set_environment(UpdateFixtures.HOST_ENV, host)
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
	var offline := (nodes["installer"] as UpdateInstaller).state()
	UpdateFixtures.end_world(world, nodes)

	world = UpdateFixtures.begin_world("installer_newer_major", "2.0.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.8.0", {"core/a.gd": "older"}, "1.1.0", UpdateFixtures.key())
	nodes = UpdateFixtures.start_world(world, tree)
	var major := (nodes["installer"] as UpdateInstaller).state()
	var major_version := (nodes["installer"] as UpdateInstaller).version()
	var major_record: String = UpdateJournal.read(world["updates"])["state"]
	UpdateFixtures.end_world(world, nodes)

	if previous_host.is_empty():
		OS.unset_environment(UpdateFixtures.HOST_ENV)
	else:
		OS.set_environment(UpdateFixtures.HOST_ENV, previous_host)
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
	var previous_host := OS.get_environment(UpdateFixtures.HOST_ENV)
	OS.set_environment(UpdateFixtures.HOST_ENV, server.host())

	var world := UpdateFixtures.begin_world("installer_stage_zip", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage_tampered(world["updates"], "1.8.0", {"core/a.gd": "older"}, "1.1.0", UpdateFixtures.key())
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var zip_state_at_start := installer.state()
	var frames := 0
	while installer.state() != "available" and frames < 1200:
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
	while installer.state() != "available" and signature_frames < 1200:
		server.poll()
		await tree.process_frame
		signature_frames += 1
	var signature_state := installer.state()
	var signature_version := installer.version()
	var signature_record: String = UpdateJournal.read(world["updates"])["state"]
	UpdateFixtures.end_world(world, nodes)

	server.stop()
	if previous_host.is_empty():
		OS.unset_environment(UpdateFixtures.HOST_ENV)
	else:
		OS.set_environment(UpdateFixtures.HOST_ENV, previous_host)
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
		var previous_host := OS.get_environment(UpdateFixtures.HOST_ENV)
		OS.set_environment(UpdateFixtures.HOST_ENV, first.host())
		var nodes := UpdateFixtures.start_world(world, tree)
		var installer: UpdateInstaller = nodes["installer"]
		installer.install()
		var frames := 0
		while installer.state() == "downloading" and frames < 1200:
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
		if previous_host.is_empty():
			OS.unset_environment(UpdateFixtures.HOST_ENV)
		else:
			OS.set_environment(UpdateFixtures.HOST_ENV, previous_host)
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
	var previous_host := OS.get_environment(UpdateFixtures.HOST_ENV)
	OS.set_environment(UpdateFixtures.HOST_ENV, first.host())
	var world := UpdateFixtures.begin_world("installer_off_list_verify", "1.9.0", "ask", "1.1.0")
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var changes := [0]
	installer.state_changed.connect(func() -> void: changes[0] += 1)
	var frames := 0
	while changes[0] == 0 and frames < 1200:
		first.poll()
		second.poll()
		await tree.process_frame
		frames += 1
	second.poll()
	var state := installer.state()
	var second_hits := second.connections()
	UpdateFixtures.end_world(world, nodes)
	first.stop()
	second.stop()
	if previous_host.is_empty():
		OS.unset_environment(UpdateFixtures.HOST_ENV)
	else:
		OS.set_environment(UpdateFixtures.HOST_ENV, previous_host)
	testing.eq(second_hits, 0, "the second listener → no request reaches it")
	testing.eq(state, "idle", "and with no click, the badge stays links only")
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
		var previous_host := OS.get_environment(UpdateFixtures.HOST_ENV)
		OS.set_environment(UpdateFixtures.HOST_ENV, server.host())
		var world := UpdateFixtures.begin_world("installer_redirect_%d" % code, "1.9.0", "ask", "1.1.0")
		var nodes := UpdateFixtures.start_world(world, tree)
		var installer: UpdateInstaller = nodes["installer"]
		var changes := [0]
		installer.state_changed.connect(func() -> void: changes[0] += 1)
		var frames := 0
		while changes[0] == 0 and frames < 1200:
			server.poll()
			await tree.process_frame
			frames += 1
		var state := installer.state()
		var connections := server.connections()
		UpdateFixtures.end_world(world, nodes)
		server.stop()
		if previous_host.is_empty():
			OS.unset_environment(UpdateFixtures.HOST_ENV)
		else:
			OS.set_environment(UpdateFixtures.HOST_ENV, previous_host)
		testing.eq(state, "available", "%d on the manifest and signature → verified" % code)
		testing.eq(connections, 4, "%d → each file's redirect and the file" % code)
	print("")
