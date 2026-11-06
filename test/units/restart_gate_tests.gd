@tool
extends RefCounted
## Unit tests for the restart gate: which view each finding picks on each Godot version,
## when Restart refuses, and how a staging end, a file scan, a cancel and an editor start
## lead to a restart or to the ready view. A stand-in probe plays the editor.

const Testing := preload("res://test/units/testing.gd")
const RestartGate := preload("res://addons/godot_mcp_toolkit/self_update/restart_gate.gd")
const EditorRestartProbe := preload("res://addons/godot_mcp_toolkit/self_update/editor_restart_probe.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

# More frames than a restart held by a scan needs once the scan ends.
const _SETTLE_FRAMES := 3


static func run(testing: Testing, tree: SceneTree) -> void:
	_test_view_for_by_version(testing)
	_test_view_for_each_finding(testing)
	_test_refuses(testing)
	_test_after_staging(testing)
	await _test_scan_holds_the_restart(testing, tree)
	await _test_cancel_during_a_scan(testing, tree)
	_test_scan_past_the_cap(testing)
	_test_restart_refuses_then_restarts(testing)
	_test_show_view_never_restarts(testing)


static func _clear() -> Dictionary:
	return {
		EditorRestartProbe.UNSAVED_SCRIPTS: PackedStringArray(),
		EditorRestartProbe.RUNNING_GAME: false,
		EditorRestartProbe.UNTITLED_SCENES: 0,
	}


static func _with(key: String, value: Variant) -> Dictionary:
	var found := _clear()
	found[key] = value
	return found


static func _await_frames(tree: SceneTree, count: int) -> void:
	for _frame: int in count:
		await tree.process_frame


static func _test_view_for_by_version(testing: Testing) -> void:
	testing.begin("Restart gate: with nothing found, the version picks the view")
	testing.eq(RestartGate.view_for(_clear(), "4.2"), RestartGate.READY_VIEW, "4.2 → ready view")
	testing.eq(RestartGate.view_for(_clear(), "4.3"), RestartGate.READY_VIEW, "4.3 → ready view")
	testing.eq(RestartGate.view_for(_clear(), "4.4"), RestartGate.RESTART, "4.4 → restart")
	testing.eq(RestartGate.view_for(_clear(), "4.5"), RestartGate.RESTART, "4.5 → restart")
	testing.eq(RestartGate.view_for(_clear(), "4.7"), RestartGate.RESTART, "4.7 → restart")
	print("")


static func _test_view_for_each_finding(testing: Testing) -> void:
	testing.begin("Restart gate: any finding opens the ready view, on 4.5 and on 4.2")
	var unsaved := _with(EditorRestartProbe.UNSAVED_SCRIPTS, PackedStringArray(["player.gd"]))
	var running := _with(EditorRestartProbe.RUNNING_GAME, true)
	var untitled := _with(EditorRestartProbe.UNTITLED_SCENES, 1)
	for version: String in ["4.5", "4.2"]:
		testing.eq(RestartGate.view_for(unsaved, version), RestartGate.READY_VIEW,
				"%s, an unsaved script → ready view" % version)
		testing.eq(RestartGate.view_for(running, version), RestartGate.READY_VIEW,
				"%s, a running game → ready view" % version)
		testing.eq(RestartGate.view_for(untitled, version), RestartGate.READY_VIEW,
				"%s, an untitled scene → ready view" % version)
	print("")


static func _test_refuses(testing: Testing) -> void:
	testing.begin("Restart gate: Restart refuses only while a script is unsaved")
	testing.ok(RestartGate.refuses(_with(EditorRestartProbe.UNSAVED_SCRIPTS, PackedStringArray(["player.gd"]))),
			"an unsaved script → refused")
	testing.ok(RestartGate.refuses(_with(EditorRestartProbe.UNSAVED_SCRIPTS, PackedStringArray([""]))),
			"an unsaved script whose name is unknown → refused")
	testing.ok(not RestartGate.refuses(_with(EditorRestartProbe.RUNNING_GAME, true)), "a running game → not refused")
	testing.ok(not RestartGate.refuses(_with(EditorRestartProbe.UNTITLED_SCENES, 2)), "untitled scenes → not refused")
	testing.ok(not RestartGate.refuses(_clear()), "nothing found → not refused")
	print("")


static func _test_after_staging(testing: Testing) -> void:
	testing.begin("Restart gate: a staging end restarts only a clear 4.4+ editor")
	var clear := UpdateFixtures.RestartProbeStandIn.new()
	var clear_gate := RestartGate.new(clear)
	clear_gate.after_staging()
	var running := UpdateFixtures.RestartProbeStandIn.new()
	running.running_game = true
	var running_gate := RestartGate.new(running)
	var opened: Array[bool] = []
	running_gate.view_changed.connect(func() -> void: opened.append(true))
	running_gate.after_staging()
	var old := UpdateFixtures.RestartProbeStandIn.new()
	old.version = "4.3"
	var old_gate := RestartGate.new(old)
	old_gate.after_staging()
	testing.eq(clear.restarts, 1, "4.5, nothing found → one restart")
	testing.ok(clear_gate.view().is_empty(), "and no ready view")
	testing.eq(running.restarts, 0, "4.5, a running game → no restart")
	testing.eq(opened.size(), 1, "the ready view opens once")
	testing.ok(bool(running_gate.view().get(EditorRestartProbe.RUNNING_GAME, false)), "and names the running game")
	testing.eq(running_gate.view().get(RestartGate.SCENES_ASKED, null), true, "and says 4.5 asks about scenes")
	testing.eq(old.restarts, 0, "4.3, nothing found → no restart")
	testing.eq(old_gate.view().get(RestartGate.SCENES_ASKED, null), false, "and the view says 4.3 does not ask")
	print("")


static func _test_scan_holds_the_restart(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Restart gate: a running scan holds the restart until it ends")
	var probe := UpdateFixtures.RestartProbeStandIn.new()
	probe.scanning = true
	var gate := RestartGate.new(probe)
	gate.after_staging()
	await _await_frames(tree, _SETTLE_FRAMES)
	var during := probe.restarts
	gate.after_staging()
	probe.scanning = false
	await _await_frames(tree, _SETTLE_FRAMES)
	testing.eq(during, 0, "while the scan runs → no restart")
	testing.eq(probe.restarts, 1, "the scan ends → one restart, though staging ended twice")
	testing.ok(gate.view().is_empty(), "and no ready view")
	print("")


static func _test_cancel_during_a_scan(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Restart gate: a cancel during a scan calls the restart off")
	var probe := UpdateFixtures.RestartProbeStandIn.new()
	probe.scanning = true
	var gate := RestartGate.new(probe)
	gate.after_staging()
	await tree.process_frame
	gate.cancel()
	probe.scanning = false
	await _await_frames(tree, _SETTLE_FRAMES)
	testing.eq(probe.restarts, 0, "cancelled, then the scan ends → no restart")
	testing.ok(gate.view().is_empty(), "and no ready view")
	print("")


static func _test_scan_past_the_cap(testing: Testing) -> void:
	testing.begin("Restart gate: a scan that outlasts the wait opens the ready view")
	var probe := UpdateFixtures.RestartProbeStandIn.new()
	probe.scanning = true
	var gate := RestartGate.new(probe, 0)
	gate.after_staging()
	testing.eq(probe.restarts, 0, "a wait of 0 ms with a scan running → no restart")
	testing.ok(not gate.view().is_empty(), "the ready view opens")
	print("")


static func _test_restart_refuses_then_restarts(testing: Testing) -> void:
	testing.begin("Restart gate: Restart checks again and refuses while a script is unsaved")
	var probe := UpdateFixtures.RestartProbeStandIn.new()
	probe.unsaved_scripts = PackedStringArray(["player.gd"])
	var gate := RestartGate.new(probe)
	gate.restart()
	var refused := probe.restarts
	var shown: PackedStringArray = gate.view().get(EditorRestartProbe.UNSAVED_SCRIPTS, PackedStringArray())
	probe.unsaved_scripts = PackedStringArray()
	gate.restart()
	testing.eq(refused, 0, "an unsaved script → no restart")
	testing.eq(shown, PackedStringArray(["player.gd"]), "the ready view names the script")
	testing.eq(probe.restarts, 1, "the script saved, Restart → one restart")
	print("")


static func _test_show_view_never_restarts(testing: Testing) -> void:
	testing.begin("Restart gate: a staged update found at an editor start never restarts")
	var probe := UpdateFixtures.RestartProbeStandIn.new()
	var gate := RestartGate.new(probe)
	gate.show_view()
	testing.eq(probe.restarts, 0, "4.5, nothing found → no restart")
	testing.ok(not gate.view().is_empty(), "the ready view opens")
	gate.close_view()
	testing.ok(gate.view().is_empty(), "Not now closes it")
	print("")
