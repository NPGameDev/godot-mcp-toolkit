@tool
extends RefCounted
## Unit tests for the dock's update badge, driven through its named buttons and labels
## with a real update check runner and installer: the version notice and its install
## row in each installer state, closing it, the notice after an install, the offer to
## update .mcp.json, and the toast for a release that becomes installable mid-session.

const Testing := preload("res://test/units/testing.gd")
const DockUpdateBadge := preload("res://addons/godot_mcp_toolkit/ui/dock/update/dock_update_badge.gd")
const UpdateInstaller := preload("res://addons/godot_mcp_toolkit/update/update_installer.gd")
const UpdateCheckRunner := preload("res://addons/godot_mcp_toolkit/versioning/update_check_runner.gd")
const PendingUpdate := preload("res://addons/godot_mcp_toolkit/update/pending_update.gd")
const MCPJsonWriteFlow := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_write_flow.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

const _HOST_ENV := "GODOT_MCP_UPDATE_CHECK_HOST"
# A loopback port nothing listens on: a download fails at once, without the network.
const _UNREACHABLE_HOST := "http://127.0.0.1:9"


# Records the toasts the badge sends through the dock's sink.
class _ToastLog extends RefCounted:
	var messages: Array = []

	func add(message: String, _severity: int = 0, _tooltip: String = "") -> void:
		messages.append(message)


# The write flow reads the project's own .mcp.json and this machine's record of it,
# and confirms through editor dialogs, none of which a headless run has; this
# stand-in answers whether the written entry is outdated and records the writes.
class _WriteFlowStandIn extends MCPJsonWriteFlow:
	var other_server := true
	var confirm_bodies: Array = []

	func written_entry_outdated() -> bool:
		return other_server

	func write(_force_overwrite: bool = false, on_result: Callable = Callable(), confirm_body: String = "") -> void:
		confirm_bodies.append(confirm_body)
		other_server = false
		on_result.call(true, "MCP: .mcp.json written", 0, "")


static func run(testing: Testing, tree: SceneTree) -> void:
	# The installer's _ready runs only once the tree's root is live.
	await tree.process_frame
	_test_available(testing, tree)
	_test_available_with_changed_files(testing, tree)
	_test_close_hides_version(testing, tree)
	_test_update_shows_download(testing, tree)
	await _test_failed_download_offers_retry(testing, tree)
	_test_ready(testing, tree)
	_test_close_gives_up_staged(testing, tree)
	_test_notice_updated(testing, tree)
	_test_notice_offers_mcp_json_update(testing, tree)
	_test_notice_failed(testing, tree)
	await _test_toast_once_for_verified(testing, tree)
	await _test_toast_for_staged_in_automatic(testing, tree)
	await _test_no_toast_for_shown_release(testing, tree)
	await _test_no_toast_for_restored_release(testing, tree)


# A world with a running installer and a badge in the tree. Returns the nodes
# end_world frees, with the badge and its toast log added.
static func _start(world: Dictionary, tree: SceneTree, write_flow: MCPJsonWriteFlow = null) -> Dictionary:
	var nodes := UpdateFixtures.start_world(world, tree)
	var toasts := _ToastLog.new()
	var badge := DockUpdateBadge.new(nodes["runner"], nodes["installer"], write_flow, Callable(toasts, "add"))
	tree.root.add_child(badge)
	nodes["badge"] = badge
	nodes["toasts"] = toasts
	return nodes


# The badge enters the tree first and the installer after it, so whatever the
# installer finds reaches the badge as a change during the session.
static func _start_badge_first(world: Dictionary, tree: SceneTree) -> Dictionary:
	var runner := UpdateCheckRunner.new()
	var installer := UpdateInstaller.new(runner, world["options"])
	var toasts := _ToastLog.new()
	var badge := DockUpdateBadge.new(runner, installer, null, Callable(toasts, "add"))
	tree.root.add_child(badge)
	tree.root.add_child(installer)
	return {"runner": runner, "installer": installer, "badge": badge, "toasts": toasts}


static func _end(world: Dictionary, nodes: Dictionary) -> void:
	(nodes["badge"] as Node).free()
	UpdateFixtures.end_world(world, nodes)


static func _child(badge: Node, child_name: String) -> Control:
	return badge.find_child(child_name, true, false) as Control


static func _text(badge: Node, child_name: String) -> String:
	var child := _child(badge, child_name)
	if child is Label:
		return (child as Label).text
	return (child as Button).text


static func _shown(badge: Node, child_name: String) -> bool:
	return _child(badge, child_name).visible


static func _press(badge: Node, child_name: String) -> void:
	(_child(badge, child_name) as Button).pressed.emit()


static func _set_host(host: String) -> String:
	var previous := OS.get_environment(_HOST_ENV)
	OS.set_environment(_HOST_ENV, host)
	return previous


static func _restore_host(previous: String) -> void:
	if previous.is_empty():
		OS.unset_environment(_HOST_ENV)
	else:
		OS.set_environment(_HOST_ENV, previous)


static func _test_available(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update badge: a verified release offers Update")
	var world := UpdateFixtures.begin_world("badge_available", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key(), PendingUpdate.VERIFIED)
	var nodes := _start(world, tree)
	var badge: Node = nodes["badge"]
	var visible := (badge as Control).visible
	var title := _text(badge, "Title")
	var update_shown := _shown(badge, "UpdateButton")
	var restart_shown := _shown(badge, "RestartButton")
	var discard_shown := _shown(badge, "DiscardButton")
	var status_shown := _shown(badge, "Status")
	_end(world, nodes)
	testing.ok(visible, "a newer version → the badge shows")
	testing.eq(title, "Godot MCP Toolkit 1.9.0 is available.", "the title names the version")
	testing.ok(update_shown, "a verified release → Update")
	testing.ok(not restart_shown and not discard_shown, "nothing staged → no Restart now or Don't install")
	testing.ok(not status_shown, "no changed files → no status line")
	print("")


static func _test_available_with_changed_files(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update badge: changed files are named before installing")
	var world := UpdateFixtures.begin_world("badge_changed", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key(), PendingUpdate.VERIFIED)
	var record := PendingUpdate.read(world["updates"])
	record["changed_files"] = PackedStringArray(["core/a.gd"])
	PendingUpdate.write(record, world["updates"])
	var nodes := _start(world, tree)
	var status := _text(nodes["badge"], "Status")
	_end(world, nodes)
	testing.eq(status, "1 toolkit files were changed in this project; installing replaces them (a copy is kept until the new version starts).",
			"one changed file → the status line counts it")
	print("")


static func _test_close_hides_version(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update badge: closing the version notice hides it until a newer version")
	var world := UpdateFixtures.begin_world("badge_close", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key(), PendingUpdate.VERIFIED)
	var nodes := _start(world, tree)
	var badge: Node = nodes["badge"]
	_press(badge, "DismissButton")
	var visible := (badge as Control).visible
	var badge_version := (nodes["runner"] as UpdateCheckRunner).badge_version()
	_end(world, nodes)
	testing.ok(not visible, "close → the badge hides")
	testing.eq(badge_version, "", "and the runner hides 1.9.0 from now on")
	print("")


static func _test_update_shows_download(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update badge: pressing Update shows the download")
	var previous_host := _set_host(_UNREACHABLE_HOST)
	var world := UpdateFixtures.begin_world("badge_download", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key(), PendingUpdate.VERIFIED)
	var nodes := _start(world, tree)
	var badge: Node = nodes["badge"]
	_press(badge, "UpdateButton")
	var status := _text(badge, "Status")
	var update_shown := _shown(badge, "UpdateButton")
	_end(world, nodes)
	_restore_host(previous_host)
	testing.eq(status, "Downloading 1.9.0…", "Update → the status line shows the download")
	testing.ok(not update_shown, "while downloading → no Update")
	print("")


static func _test_failed_download_offers_retry(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update badge: a failed download offers Try again")
	var previous_host := _set_host(_UNREACHABLE_HOST)
	var world := UpdateFixtures.begin_world("badge_retry", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key(), PendingUpdate.VERIFIED)
	var nodes := _start(world, tree)
	var badge: Node = nodes["badge"]
	var installer: UpdateInstaller = nodes["installer"]
	_press(badge, "UpdateButton")
	var frames := 0
	while installer.state() == "downloading" and frames < 600:
		await tree.process_frame
		frames += 1
	var button_text := _text(badge, "UpdateButton")
	var update_shown := _shown(badge, "UpdateButton")
	var status := _text(badge, "Status")
	_end(world, nodes)
	_restore_host(previous_host)
	testing.ok(frames < 600, "the failure arrives within 600 frames")
	testing.ok(update_shown, "a failed download → the button shows again")
	testing.eq(button_text, "Try again", "and reads Try again")
	testing.ok(status.begins_with("Couldn't install: the download failed"), "the status line says the download failed")
	print("")


static func _test_ready(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update badge: a staged release offers Restart now and Don't install")
	var world := UpdateFixtures.begin_world("badge_ready", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	var nodes := _start(world, tree)
	var badge: Node = nodes["badge"]
	var status := _text(badge, "Status")
	var restart_shown := _shown(badge, "RestartButton")
	var discard_shown := _shown(badge, "DiscardButton")
	var update_shown := _shown(badge, "UpdateButton")
	_end(world, nodes)
	testing.eq(status, "1.9.0 installs when you close the editor. Restart now to install it at once.",
			"the status line says the editor's exit installs it")
	testing.ok(restart_shown and discard_shown, "a staged release → Restart now and Don't install")
	testing.ok(not update_shown, "and no Update")
	print("")


static func _test_close_gives_up_staged(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update badge: closing a staged release gives it up")
	var world := UpdateFixtures.begin_world("badge_close_staged", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	var nodes := _start(world, tree)
	var badge: Node = nodes["badge"]
	_press(badge, "DismissButton")
	var state := (nodes["installer"] as UpdateInstaller).state()
	var record_state: String = PendingUpdate.read(world["updates"])["state"]
	var visible := (badge as Control).visible
	_end(world, nodes)
	testing.eq(state, "idle", "close → the installer gives the release up")
	testing.eq(record_state, "", "the staged record → deleted")
	testing.ok(not visible, "and the badge hides")
	print("")


# The runner's newest version is the installed one, so closing the notice leaves
# nothing to show.
static func _test_notice_updated(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update badge: the notice after an install")
	var world := UpdateFixtures.begin_world("badge_updated", "1.1.0", "ask", "1.9.0")
	PendingUpdate.write({"state": "applied", "version": "1.9.0", "from_version": "1.1.0",
			"compatible_server": VersionUtils.COMPATIBLE_SERVER_VERSION}, world["updates"])
	var nodes := _start(world, tree)
	var badge: Node = nodes["badge"]
	var title := _text(badge, "Title")
	var link_text := _text(badge, "GitHubButton")
	var link_shown := _shown(badge, "GitHubButton")
	var store_shown := _shown(badge, "AssetStoreButton")
	var status_shown := _shown(badge, "Status")
	var mcp_json_shown := _shown(badge, "UpdateMcpJsonButton")
	_press(badge, "DismissButton")
	var visible_after_close := (badge as Control).visible
	_end(world, nodes)
	testing.eq(title, "Godot MCP Toolkit was updated to 1.9.0.", "the title names the installed version")
	testing.ok(link_shown, "the release notes link shows")
	testing.eq(link_text, "What's new", "and reads What's new")
	testing.ok(not store_shown, "no Asset Store link")
	testing.ok(not status_shown and not mcp_json_shown, "the same server → no .mcp.json line or button")
	testing.ok(not visible_after_close, "close → the notice goes")
	print("")


static func _test_notice_offers_mcp_json_update(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update badge: the notice offers to update .mcp.json while the entry it wrote is outdated")
	var world := UpdateFixtures.begin_world("badge_server", "1.1.0", "ask", "1.9.0")
	PendingUpdate.write({"state": "applied", "version": "1.9.0", "from_version": "1.1.0",
			"compatible_server": "0.0.1"}, world["updates"])
	var write_flow := _WriteFlowStandIn.new()
	var nodes := _start(world, tree, write_flow)
	var badge: Node = nodes["badge"]
	var status := _text(badge, "Status")
	var button_shown := _shown(badge, "UpdateMcpJsonButton")
	_press(badge, "UpdateMcpJsonButton")
	var toasts: Array = (nodes["toasts"] as _ToastLog).messages
	var shown_after_write := _shown(badge, "UpdateMcpJsonButton")
	_end(world, nodes)

	world = UpdateFixtures.begin_world("badge_server_current", "1.1.0", "ask", "1.9.0")
	PendingUpdate.write({"state": "applied", "version": "1.9.0", "from_version": "1.1.0",
			"compatible_server": "0.0.1"}, world["updates"])
	var current_flow := _WriteFlowStandIn.new()
	current_flow.other_server = false
	nodes = _start(world, tree, current_flow)
	var current_status_shown := _shown(nodes["badge"], "Status")
	var current_button_shown := _shown(nodes["badge"], "UpdateMcpJsonButton")
	_end(world, nodes)

	var compatible := VersionUtils.COMPATIBLE_SERVER_VERSION
	testing.eq(status, "It's tested with server %s, which .mcp.json doesn't run yet. Update .mcp.json, then restart your MCP client." % compatible,
			"a new server and an outdated written entry → the status line says so")
	testing.ok(button_shown, "and Update .mcp.json shows")
	testing.eq(write_flow.confirm_bodies.size(), 1, "pressing it → one write through the shared flow")
	testing.ok(str(write_flow.confirm_bodies[0]).begins_with("Update the server to %s in .mcp.json?" % compatible),
			"whose confirmation names the server")
	testing.eq(toasts, ["MCP: .mcp.json written"], "the write's report → a toast")
	testing.ok(not shown_after_write, "after the write → the button goes")
	testing.ok(not current_status_shown and not current_button_shown,
			"a new server and no outdated written entry → no line or button")
	print("")


static func _test_notice_failed(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update badge: the notice after a failed install")
	var world := UpdateFixtures.begin_world("badge_failed", "1.1.0", "ask", "1.1.0")
	PendingUpdate.write({"state": "rolled_back", "version": "1.9.0", "from_version": "1.1.0",
			"reason": "could not write core/a.gd"}, world["updates"])
	var nodes := _start(world, tree)
	var badge: Node = nodes["badge"]
	var title := _text(badge, "Title")
	var status := _text(badge, "Status")
	var link_shown := _shown(badge, "GitHubButton")
	_end(world, nodes)
	testing.eq(title, "Godot MCP Toolkit 1.9.0 was not installed.", "the title names the version")
	testing.eq(status, "Could not write core/a.gd. Version 1.1.0 is still installed. Install log: %s" % PendingUpdate.log_path(world["updates"]),
			"the status line gives the reason as a sentence, the version kept and the log")
	testing.ok(not link_shown, "no release notes link")
	print("")


# Serves the release from a loopback server until the installer reaches `state` or
# `frames` pass, then lets the badge's deferred check run. Returns the frames used.
static func _serve_until(server: UpdateFixtures.LoopbackReleaseServer, installer: UpdateInstaller,
		state: String, tree: SceneTree, frames: int = 1200) -> int:
	var used := 0
	while installer.state() != state and used < frames:
		server.poll()
		await tree.process_frame
		used += 1
	await tree.process_frame
	return used


static func _test_toast_once_for_verified(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update badge: a release verified during the session is announced once")
	var server := UpdateFixtures.LoopbackReleaseServer.new(
			UpdateFixtures.release_assets("1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key()))
	var previous_host := _set_host(server.host())
	var world := UpdateFixtures.begin_world("badge_toast_verified", "1.9.0", "ask", "1.1.0")
	var nodes := _start(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var frames := await _serve_until(server, installer, "available", tree)
	var first: Array = (nodes["toasts"] as _ToastLog).messages.duplicate()
	installer.state_changed.emit()
	await tree.process_frame
	var after_repeat: Array = (nodes["toasts"] as _ToastLog).messages.duplicate()
	_end(world, nodes)
	server.stop()
	_restore_host(previous_host)
	testing.ok(frames < 1200, "the release is verified within 1200 frames")
	testing.eq(first, ["Godot MCP Toolkit 1.9.0 is available. Update it from the MCP Toolkit dock."],
			"a release verified during the session → one toast naming it")
	testing.eq(after_repeat.size(), 1, "another change about the same release → no second toast")
	print("")


# The automatic mode downloads a verified release at once, so the toast says the
# editor's exit installs it, and the verified state it passed through gets none.
static func _test_toast_for_staged_in_automatic(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update badge: a release staged during the session is announced once staged")
	var server := UpdateFixtures.LoopbackReleaseServer.new(
			UpdateFixtures.release_assets("1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key()))
	var previous_host := _set_host(server.host())
	var world := UpdateFixtures.begin_world("badge_toast_staged", "1.9.0", "automatic", "1.1.0")
	var nodes := _start(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var frames := await _serve_until(server, installer, "ready", tree)
	var toasts: Array = (nodes["toasts"] as _ToastLog).messages.duplicate()
	_end(world, nodes)
	server.stop()
	_restore_host(previous_host)
	testing.ok(frames < 1200, "the release is staged within 1200 frames")
	testing.eq(toasts, ["Godot MCP Toolkit 1.9.0 installs when you close the editor."],
			"the automatic mode's download → one toast saying the editor's exit installs it")
	print("")


static func _test_no_toast_for_shown_release(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update badge: a release already installable when the badge appears gets no toast")
	var world := UpdateFixtures.begin_world("badge_toast_shown", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key(), PendingUpdate.VERIFIED)
	var nodes := _start(world, tree)
	await tree.process_frame
	(nodes["installer"] as UpdateInstaller).state_changed.emit()
	await tree.process_frame
	var toasts: Array = (nodes["toasts"] as _ToastLog).messages.duplicate()
	_end(world, nodes)
	testing.eq(toasts.size(), 0, "available before the badge entered → no toast, then or later")
	print("")


# At an editor start the dock is built before the installer's _ready picks up the
# record an earlier session left, so the badge sees the release arrive as a change;
# the editor-start window covers it, and a toast would repeat it.
static func _test_no_toast_for_restored_release(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update badge: a release an earlier session found gets no toast")
	var world := UpdateFixtures.begin_world("badge_toast_restored", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key(), PendingUpdate.VERIFIED)
	var nodes := _start_badge_first(world, tree)
	await tree.process_frame
	var state := (nodes["installer"] as UpdateInstaller).state()
	var toasts: Array = (nodes["toasts"] as _ToastLog).messages.duplicate()
	_end(world, nodes)
	testing.eq(state, "available", "the record → available after the badge entered")
	testing.eq(toasts.size(), 0, "and no toast")
	print("")
