@tool
extends RefCounted
## Unit tests for the dock update badge's status line: which line each installer state,
## ready view finding and install notice adds. The rows pin which lines appear, not their
## wording; the badge's own tests pin the wording the badge shows.

const Testing := preload("res://test/units/testing.gd")
const DockUpdateBadgeStatus := preload("res://addons/godot_mcp_toolkit/ui/dock/update/dock_update_badge_status.gd")
const UpdateApplier := preload("res://addons/godot_mcp_toolkit/self_update/update_applier.gd")
const UpdateInstaller := preload("res://addons/godot_mcp_toolkit/self_update/update_installer.gd")
const EditorRestartProbe := preload("res://addons/godot_mcp_toolkit/self_update/editor_restart_probe.gd")
const RestartGate := preload("res://addons/godot_mcp_toolkit/self_update/restart_gate.gd")
const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")

const _REASON := "could not rename the addon folder"


static func run(testing: Testing) -> void:
	_test_download_and_stage_lines_differ(testing)
	_test_postponed_reason(testing)
	_test_postponed_says_it_tries_again(testing)
	_test_ready_view_findings(testing)
	_test_untrusted_notice_adds_a_line(testing)
	_test_malformed_file_says_fix_once(testing)
	_test_pin_preview_adds_a_line_to_the_offer(testing)


# The malformed-file reason carries its own instruction, which the failed-write line
# would repeat.
static func _test_malformed_file_says_fix_once(testing: Testing) -> void:
	testing.begin("Badge status: a malformed .mcp.json is asked to be fixed once")
	var line := DockUpdateBadgeStatus.notice_line({"kind": UpdateInstaller.NOTICE_UPDATED}, "user://log.txt",
			{"state": "write_failed", "error": MCPJsonSync.MALFORMED_MESSAGE})
	testing.eq(line.to_lower().count("fix"), 1, "the line → says it once")
	testing.ok("valid JSON" in line, "and still says what is wrong")
	testing.ok(line.ends_with("Update .mcp.json."), "and names the button")
	print("")


static func _test_pin_preview_adds_a_line_to_the_offer(testing: Testing) -> void:
	testing.begin("Badge status: a pin that would move adds a line to the offer")
	var preview := {"from": "1.1.2", "to": "1.2.0"}
	var alone := DockUpdateBadgeStatus.install_line(UpdateInstaller.AVAILABLE, "1.9.0",
			{DockUpdateBadgeStatus.PIN_PREVIEW: preview})
	var with_changes := DockUpdateBadgeStatus.install_line(UpdateInstaller.AVAILABLE, "1.9.0",
			{DockUpdateBadgeStatus.CHANGED: 1, DockUpdateBadgeStatus.PIN_PREVIEW: preview})
	var changes_only := DockUpdateBadgeStatus.install_line(UpdateInstaller.AVAILABLE, "1.9.0",
			{DockUpdateBadgeStatus.CHANGED: 1})
	var stays := DockUpdateBadgeStatus.install_line(UpdateInstaller.AVAILABLE, "1.9.0",
			{DockUpdateBadgeStatus.PIN_PREVIEW: {}})
	var downloading := DockUpdateBadgeStatus.install_line(UpdateInstaller.DOWNLOADING, "1.9.0",
			{DockUpdateBadgeStatus.PIN_PREVIEW: preview})
	testing.eq(alone.split("\n").size(), 1, "a pin that would move → a line")
	testing.ok(not alone.is_empty(), "with text")
	testing.eq(with_changes.split("\n").size(), changes_only.split("\n").size() + 1, "beside changed files → one more line")
	testing.eq(stays, "", "a pin that stays → nothing")
	testing.ok(not "1.2.0" in downloading, "any state but the offer → no pin line")
	print("")


static func _test_download_and_stage_lines_differ(testing: Testing) -> void:
	testing.begin("Badge status: the download and the stage each have their own line")
	var downloading := DockUpdateBadgeStatus.install_line(UpdateInstaller.DOWNLOADING, "1.9.0", {})
	var preparing := DockUpdateBadgeStatus.install_line(UpdateInstaller.PREPARING, "1.9.0", {})
	testing.ok(not downloading.is_empty(), "downloading → a line")
	testing.ok(not preparing.is_empty(), "preparing → a line")
	testing.ok(downloading != preparing, "and the two differ")
	print("")


static func _test_postponed_reason(testing: Testing) -> void:
	testing.begin("Badge status: a staged update the last exit left says why")
	var view := {RestartGate.SCENES_ASKED: true}
	var staged := DockUpdateBadgeStatus.install_line(UpdateInstaller.READY, "1.9.0", {})
	var postponed := DockUpdateBadgeStatus.install_line(UpdateInstaller.READY, "1.9.0",
			{DockUpdateBadgeStatus.POSTPONED: _REASON})
	var in_view := DockUpdateBadgeStatus.install_line(UpdateInstaller.READY, "1.9.0",
			{DockUpdateBadgeStatus.VIEW: view})
	var postponed_in_view := DockUpdateBadgeStatus.install_line(UpdateInstaller.READY, "1.9.0",
			{DockUpdateBadgeStatus.VIEW: view, DockUpdateBadgeStatus.POSTPONED: _REASON})
	testing.ok(postponed.contains(_REASON), "a postponed update → the line names the reason")
	testing.eq(postponed.split("\n").size(), staged.split("\n").size() + 1, "on a line of its own")
	testing.ok(not staged.contains(_REASON), "no reason → no such line")
	testing.ok(postponed_in_view.contains(_REASON), "the ready view open → the reason still shows")
	testing.eq(postponed_in_view.split("\n").size(), in_view.split("\n").size() + 1, "under the view's lines")
	print("")


static func _test_postponed_says_it_tries_again(testing: Testing) -> void:
	testing.begin("Badge status: a postponed update's first line says the exit tries again")
	var view := {RestartGate.SCENES_ASKED: true}
	var postponed := DockUpdateBadgeStatus.install_line(UpdateInstaller.READY, "1.9.0",
			{DockUpdateBadgeStatus.POSTPONED: _REASON})
	var postponed_in_view := DockUpdateBadgeStatus.install_line(UpdateInstaller.READY, "1.9.0",
			{DockUpdateBadgeStatus.VIEW: view, DockUpdateBadgeStatus.POSTPONED: _REASON})
	var staged := DockUpdateBadgeStatus.install_line(UpdateInstaller.READY, "1.9.0", {})
	var in_view := DockUpdateBadgeStatus.install_line(UpdateInstaller.READY, "1.9.0",
			{DockUpdateBadgeStatus.VIEW: view})
	testing.eq(postponed.split("\n")[0],
			"1.9.0 tries to install again when you close the editor. Restart now to install it at once.",
			"the view closed → the line says the exit tries again")
	testing.eq(postponed_in_view.split("\n")[0], "1.9.0 is ready. It tries to install again when you close the editor.",
			"the ready view open → its first line says so too")
	testing.eq(staged.split("\n")[0], "1.9.0 installs when you close the editor. Restart now to install it at once.",
			"not postponed → the line says the exit installs it")
	testing.eq(in_view.split("\n")[0], "1.9.0 is ready. It installs when you close the editor.",
			"not postponed, the view open → so does the view")
	print("")


static func _test_ready_view_findings(testing: Testing) -> void:
	testing.begin("Badge status: each ready view finding adds its line")
	var asked := {RestartGate.SCENES_ASKED: true}
	var base := DockUpdateBadgeStatus.ready_view_text("1.9.0", asked)
	var game := DockUpdateBadgeStatus.ready_view_text("1.9.0",
			{RestartGate.SCENES_ASKED: true, EditorRestartProbe.RUNNING_GAME: true})
	var game_off := DockUpdateBadgeStatus.ready_view_text("1.9.0",
			{RestartGate.SCENES_ASKED: true, EditorRestartProbe.RUNNING_GAME: false})
	var unsaved := DockUpdateBadgeStatus.ready_view_text("1.9.0",
			{RestartGate.SCENES_ASKED: true, EditorRestartProbe.UNSAVED_SCRIPTS: PackedStringArray(["a.gd"])})
	var not_asked := DockUpdateBadgeStatus.ready_view_text("1.9.0", {RestartGate.SCENES_ASKED: false})
	testing.eq(game.split("\n").size(), base.split("\n").size() + 1, "a running game → one more line")
	testing.eq(game_off, base, "no running game → no such line")
	testing.eq(unsaved.split("\n").size(), base.split("\n").size() + 1, "an unsaved script → one more line")
	testing.ok(not_asked != base, "a restart that does not ask about scenes → a different line")
	print("")


static func _test_untrusted_notice_adds_a_line(testing: Testing) -> void:
	testing.begin("Badge status: a release signed by an untrusted key points at the next release")
	var untrusted := DockUpdateBadgeStatus.notice_line(
			{"kind": UpdateInstaller.NOTICE_FAILED, "reason": UpdateApplier.UNTRUSTED_SIGNATURE,
					"version": "1.9.0", "from_version": "1.1.0"},
			"user://log.txt", {})
	var other := DockUpdateBadgeStatus.notice_line(
			{"kind": UpdateInstaller.NOTICE_FAILED, "reason": _REASON, "version": "1.9.0", "from_version": "1.1.0"},
			"user://log.txt", {})
	testing.eq(untrusted.split("\n").size(), other.split("\n").size() + 1, "an untrusted signature → one more line")
	print("")
