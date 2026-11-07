@tool
extends RefCounted
## Unit tests for the stage runner, in a live tree: one file a frame on an empty budget, the
## one finished signal, a run that cannot begin, cancel, and an idle runner.

const Testing := preload("res://test/units/testing.gd")
const StageRunner := preload("res://addons/godot_mcp_toolkit/self_update/stage_runner.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

const _VERSION := "1.2.0"
const _FILES := {"core/a.gd": "new a", "core/b.gd": "new b", "core/c.gd": "new c"}
# The three files, plugin.cfg and the release file list.
const _FILE_COUNT := 5
# Far more frames than any zip here needs, so a run that never ends fails the case.
const _MAX_FRAMES := 600


static func run(testing: Testing, tree: SceneTree) -> void:
	# A node's _ready runs only once the tree's root is live.
	await tree.process_frame
	await _test_one_file_a_frame(testing, tree)
	await _test_missing_zip(testing, tree)
	await _test_cancel(testing, tree)
	await _test_idle(testing, tree)


# A folder holding the release's zip, and a runner in the tree that spends no budget. The
# outcomes the runner emits land in the returned "outcomes".
static func _begin_case(purpose: String, tree: SceneTree) -> Dictionary:
	var folder := UpdateFixtures.scratch(purpose)
	var archive := UpdateFolder.version_folder(_VERSION, folder).path_join(ReleaseAssets.archive_name(_VERSION))
	UpdateFixtures.write_zip(archive, UpdateFixtures.release_entries(_VERSION, _FILES))
	var outcomes: Array[Dictionary] = []
	var runner := StageRunner.new(0)
	runner.finished.connect(func(outcome: Dictionary) -> void: outcomes.append(outcome))
	tree.root.add_child(runner)
	return {"folder": folder, "runner": runner, "outcomes": outcomes}


static func _end_case(case: Dictionary) -> void:
	(case["runner"] as Node).free()
	UpdateFixtures.remove(str(case["folder"]))


static func _stage_count(folder: String) -> int:
	return FolderFiles.list(ProjectSettings.globalize_path(UpdateFolder.stage_folder(folder))).size()


static func _test_one_file_a_frame(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Stage runner: an empty budget stages one file a frame and finishes once")
	var case := _begin_case("runner_frames", tree)
	var runner: StageRunner = case["runner"]
	var folder := str(case["folder"])
	var outcomes: Array[Dictionary] = case["outcomes"]
	runner.start(_VERSION, folder)
	var outcomes_after_start := outcomes.size()
	var processing_during := runner.is_processing()
	var counts := []
	var frames := 0
	while outcomes.is_empty() and frames < _MAX_FRAMES:
		await tree.process_frame
		frames += 1
		var count := _stage_count(folder)
		# The frame that was already under way when the run started may write nothing yet.
		if count > 0:
			counts.append(count)
	for _frame: int in range(5):
		await tree.process_frame
	var processing_after := runner.is_processing()
	var last_outcome: Dictionary = outcomes[0] if outcomes.size() == 1 else {}
	var outcome_count := outcomes.size()
	_end_case(case)
	testing.eq(outcomes_after_start, 0, "start → no outcome yet")
	testing.ok(processing_during, "a run going → the runner processes")
	testing.eq(counts, [1, 2, 3, 4, 5], "the stage grows by one file a frame")
	testing.eq(outcome_count, 1, "finished fires once, and not again on later frames")
	testing.eq(last_outcome, {"state": "done", "reason": "", "written": _FILE_COUNT, "total": _FILE_COUNT},
			"with the stepper's done outcome")
	testing.ok(not processing_after, "a run over → the runner stops processing")
	print("")


static func _test_missing_zip(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Stage runner: a run that cannot begin says so on a later frame")
	var case := _begin_case("runner_missing", tree)
	var runner: StageRunner = case["runner"]
	var outcomes: Array[Dictionary] = case["outcomes"]
	runner.start("9.9.9", str(case["folder"]))
	var outcomes_after_start := outcomes.size()
	for _frame: int in range(5):
		await tree.process_frame
	var last_outcome: Dictionary = outcomes[0] if outcomes.size() == 1 else {}
	var outcome_count := outcomes.size()
	var processing_after := runner.is_processing()
	_end_case(case)
	testing.eq(outcomes_after_start, 0, "start → no outcome in the same call")
	testing.eq(outcome_count, 1, "finished fires once")
	testing.eq(last_outcome, {"state": "failed", "reason": "the update's zip is missing", "written": 0, "total": 0},
			"with the reason")
	testing.ok(not processing_after, "and the runner stops processing")
	print("")


static func _test_cancel(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Stage runner: cancel leaves no stage and no signal")
	var case := _begin_case("runner_cancel", tree)
	var runner: StageRunner = case["runner"]
	var folder := str(case["folder"])
	var outcomes: Array[Dictionary] = case["outcomes"]
	runner.start(_VERSION, folder)
	var frames := 0
	while _stage_count(folder) == 0 and frames < _MAX_FRAMES:
		await tree.process_frame
		frames += 1
	var count_before := _stage_count(folder)
	var gone := runner.cancel()
	var processing_after := runner.is_processing()
	for _frame: int in range(_FILE_COUNT + 2):
		await tree.process_frame
	var stage_left := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(UpdateFolder.stage_folder(folder)))
	var outcome_count := outcomes.size()
	var second_cancel := runner.cancel()
	_end_case(case)
	testing.ok(count_before > 0 and count_before < _FILE_COUNT, "the run is part way when it is cancelled")
	testing.ok(gone, "cancel → reports nothing left")
	testing.ok(not stage_left, "and the stage is gone")
	testing.eq(outcome_count, 0, "finished never fires")
	testing.ok(not processing_after, "the runner stops processing")
	testing.ok(second_cancel, "cancel with no run going → reports nothing left")
	print("")


static func _test_idle(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Stage runner: a runner with no run does not process")
	var runner := StageRunner.new()
	tree.root.add_child(runner)
	var processing_ready := runner.is_processing()
	await tree.process_frame
	var processing_later := runner.is_processing()
	runner.free()
	testing.ok(not processing_ready, "once ready → not processing")
	testing.ok(not processing_later, "nor on a later frame")
	print("")
