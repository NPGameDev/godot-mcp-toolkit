@tool
extends RefCounted
## Setup wizard unit tests: the step table, the setup step tracker against every
## file shape and format rule, the run planner's truth table, the consent gate and
## the readers of the two toggles it and the planner use, how
## a run ends (Next, ×, "Remind me later"), a second request meeting an open run,
## the run-level buttons and labels, the
## two checkbox steps' writes, the enable-time .mcp.json prompt's gate and the
## rename migration.
##
## The tracker reads and writes scratch files under user:// that this module
## removes; the checkbox steps write to stand-in settings, so project.godot and
## EditorSettings are never touched.[br]
## [br]
## run() is a coroutine: the run-ending groups open the wizard's dialog in the
## runner's tree and await a frame, so the runner must [code]await[/code] it.

const SetupSteps := preload("res://addons/godot_mcp_toolkit/core/setup_steps.gd")
const SetupStepTracker := preload("res://addons/godot_mcp_toolkit/core/setup_step_tracker.gd")
const Consent := preload("res://addons/godot_mcp_toolkit/core/consent.gd")
const OnboardingWizard := preload("res://addons/godot_mcp_toolkit/ui/onboarding_wizard.gd")
const StepSpecs := preload("res://addons/godot_mcp_toolkit/ui/setup_wizard/step_specs.gd")
const SetupStepSettings := preload("res://addons/godot_mcp_toolkit/ui/setup_step_settings.gd")
const MCPJsonEnablePrompt := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_enable_prompt.gd")
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")
const LogBuffer := preload("res://addons/godot_mcp_toolkit/logging/log_buffer.gd")

const _FLAG := "user://setup_wizard_tests_flag"
const _PROGRESS := "user://setup_wizard_tests_progress"
# The files at the path a project rename moves user:// to.
const _RENAMED_FLAG := "user://setup_wizard_tests_renamed_flag"
const _RENAMED_PROGRESS := "user://setup_wizard_tests_renamed_progress"
# A folder that does not exist until a record creates it.
const _NESTED_DIR := "user://setup_wizard_tests_nested"

const _OPTIONAL_STEPS_TEXT := (
	"Toolkit updates sometimes add steps to this wizard. When one does, the next time "
	+ "you start the editor you'll see only the new steps.\n\n"
	+ "Some steps are required because you lose something by skipping them: without "
	+ ".mcp.json your AI client won't find the toolkit on its own, and the update check "
	+ "only starts once you've seen the update-check step. Required steps come back at "
	+ "every editor start until you've seen them. \"Remind me later\" puts them off until "
	+ "the next start.\n\n"
	+ "The other steps are optional. Untick the box below and optional steps that future "
	+ "updates add won't show, in any project on this machine. Required steps still show.")
const _UPDATES_TEXT := (
	"At most once a day, the toolkit asks GitHub whether a newer version is out. If one "
	+ "is, it also asks the Asset Store whether it lists that version yet. When there's a "
	+ "newer version, a closable badge at the top of the MCP Toolkit dock links to it. The "
	+ "toolkit never installs anything by itself.\n\n"
	+ "These requests carry no identifier and nothing about your project. Untick the box "
	+ "below and the toolkit sends no requests at all.\n\n"
	+ "You can change this later in Project Settings under Mcp Toolkit > Updates. It's "
	+ "saved in project.godot, so it applies to everyone who works on this project.")


static func run(testing, tree: SceneTree) -> void:
	_test_step_table(testing)
	_test_tracker_file_shapes(testing)
	_test_tracker_format_rules(testing)
	_test_tracker_written_bytes(testing)
	_test_run_planner(testing)
	_test_seen_on_close(testing)
	_test_consent_gate(testing)
	_test_setting_readers(testing)
	_test_spec_in_run(testing)
	_test_new_step_specs(testing)
	await _test_run_endings(testing, tree)
	await _test_open_run_reused(testing, tree)
	await _test_check_box_writes(testing, tree)
	_test_enable_prompt_gate(testing)
	_test_rename_migration(testing)
	_test_rename_keeps_unseen_steps(testing)


# --- The step table ------------------------------------------------------------

static func _test_step_table(testing) -> void:
	testing.begin("Setup steps: the table")
	var ids := SetupSteps.all_ids()
	testing.eq(ids, _ids([&"welcome", &"mcp_json", &"optional_steps", &"updates", &"dock"]),
			"the ids, in display order")
	var unique := {}
	for step_id in ids:
		unique[step_id] = true
	testing.eq(unique.size(), ids.size(), "every id is unique")
	testing.ok(SetupSteps.is_required(&"welcome"), "welcome is required")
	testing.ok(SetupSteps.is_required(&"mcp_json"), "mcp_json is required")
	testing.ok(not SetupSteps.is_required(&"optional_steps"), "optional_steps is optional")
	testing.ok(SetupSteps.is_required(&"updates"), "updates is required")
	testing.ok(not SetupSteps.is_required(&"dock"), "dock is optional")
	testing.ok(not SetupSteps.is_required(&"no_such_step"), "an unknown id is not required")
	print("")


# --- The tracker -----------------------------------------------------------------

static func _test_tracker_file_shapes(testing) -> void:
	testing.begin("Setup step tracker: unseen steps per file shape")
	_use_scratch_files()
	var all_ids := SetupSteps.all_ids()

	testing.eq(SetupStepTracker.get_unseen(all_ids), all_ids, "no file → every step unseen")

	_write_file(_FLAG, "1")
	testing.eq(SetupStepTracker.get_unseen(all_ids), _ids([&"optional_steps", &"updates"]),
			"a 1.0 \"1\" flag → only the steps 1.0 never had")
	testing.ok(SetupStepTracker.has_seen(&"dock"), "a 1.0 \"1\" flag → dock seen")
	_remove_scratch_files()

	_write_file(_PROGRESS, "0")
	testing.eq(SetupStepTracker.get_unseen(all_ids), all_ids, "a 1.0 progress file at 0 → every step unseen")
	_write_file(_PROGRESS, "1")
	testing.eq(SetupStepTracker.get_unseen(all_ids),
			_ids([&"mcp_json", &"optional_steps", &"updates", &"dock"]),
			"a 1.0 progress file at 1 → welcome seen")
	_write_file(_PROGRESS, "2")
	testing.eq(SetupStepTracker.get_unseen(all_ids), _ids([&"optional_steps", &"updates", &"dock"]),
			"a 1.0 progress file at 2 → welcome and mcp_json seen")
	SetupStepTracker.mark_seen(&"updates")
	testing.ok(not FileAccess.file_exists(_PROGRESS), "the first record deletes the progress file")
	testing.eq(_read_seen(), ["welcome", "mcp_json", "updates"], "and folds its steps into the seen-steps file")
	_remove_scratch_files()

	# A flag path inside the progress file cannot be created, so the write fails.
	SetupStepTracker.set_file_paths(_PROGRESS.path_join("flag"), _PROGRESS)
	_write_file(_PROGRESS, "2")
	SetupStepTracker.mark_seen(&"updates")
	testing.ok(FileAccess.file_exists(_PROGRESS), "a failed write keeps the progress file")
	testing.eq(SetupStepTracker.get_unseen(all_ids), _ids([&"optional_steps", &"updates", &"dock"]),
			"and its steps still read as seen")
	SetupStepTracker.set_file_paths(_FLAG, _PROGRESS)
	_remove_scratch_files()

	_write_file(_FLAG, JSON.stringify({"format": 1, "seen": ["welcome", "mcp_json", "optional_steps", "updates", "dock"]}))
	testing.eq(SetupStepTracker.get_unseen(all_ids), _ids([]), "a full set → nothing unseen")
	_write_file(_FLAG, JSON.stringify({"format": 1, "seen": ["welcome", "updates"]}))
	testing.eq(SetupStepTracker.get_unseen(all_ids), _ids([&"mcp_json", &"optional_steps", &"dock"]),
			"a partial set → the rest, in the given order")
	testing.eq(SetupStepTracker.get_unseen(_ids([&"dock", &"welcome", &"mcp_json"])), _ids([&"dock", &"mcp_json"]),
			"get_unseen keeps the order it was given")

	_write_file(_FLAG, JSON.stringify({"format": 1, "seen": ["welcome", "future_step"], "note": "kept"}))
	testing.ok(SetupStepTracker.has_seen(&"future_step"), "an unknown id reads as seen")
	SetupStepTracker.mark_seen(&"updates")
	var data := _read_data()
	testing.eq(data.get("seen"), ["welcome", "future_step", "updates"], "a rewrite keeps unknown ids")
	testing.eq(data.get("note"), "kept", "a rewrite keeps unknown top-level keys")
	_end_scratch_files()
	print("")


static func _test_tracker_format_rules(testing) -> void:
	testing.begin("Setup step tracker: format rules")
	_use_scratch_files()
	var all_ids := SetupSteps.all_ids()
	var legacy_unseen := _ids([&"optional_steps", &"updates"])

	var newer := JSON.stringify({"format": 2, "seen": ["welcome", "updates"], "later": true})
	_write_file(_FLAG, newer)
	testing.eq(SetupStepTracker.get_unseen(all_ids), _ids([&"mcp_json", &"optional_steps", &"dock"]),
			"a newer format with a readable list → that list")
	SetupStepTracker.mark_seen(&"dock")
	testing.eq(_read_file(_FLAG), newer, "a newer format is never written")

	var newer_unreadable := JSON.stringify({"format": 3, "seen": "welcome"})
	_write_file(_FLAG, newer_unreadable)
	testing.eq(SetupStepTracker.get_unseen(all_ids), _ids([]), "a newer format without a list → every step seen")
	testing.ok(SetupStepTracker.has_seen(&"updates"), "and has_seen answers yes")
	SetupStepTracker.mark_all_seen(all_ids)
	testing.eq(_read_file(_FLAG), newer_unreadable, "and the file is never written")

	LogBuffer.setup()
	var cursor: int = LogBuffer.get_cursor() - 1
	for bad in ["", "{\"format\": ", "[1, 2]", "{\"seen\": [\"dock\"]}", "{\"format\": 1, \"seen\": \"dock\"}"]:
		_write_file(_FLAG, bad)
		testing.eq(SetupStepTracker.get_unseen(all_ids), legacy_unseen, "%s → the 1.0 steps" % JSON.stringify(bad))
	_write_file(_FLAG, JSON.stringify({"format": 1, "seen": []}) + " ".repeat(SetupStepTracker.MAX_FILE_BYTES))
	testing.eq(SetupStepTracker.get_unseen(all_ids), legacy_unseen, "a file over the size cap → the 1.0 steps")
	if LogBuffer.uses_logger_api():
		var errors: Dictionary = LogBuffer.get_entries(100, ["error"], cursor, "JSON")
		testing.eq(int(errors["returned"]), 0, "a bad file prints no JSON parse error")

	SetupStepTracker.mark_seen(&"updates")
	var rewritten := _read_data()
	testing.eq(rewritten.get("format"), 1.0, "a record rewrites a bad file as format 1")
	testing.eq(rewritten.get("seen"), ["welcome", "mcp_json", "dock", "updates"],
			"holding the 1.0 steps and the new one")

	_write_file(_FLAG, JSON.stringify({"format": 1, "seen": ["welcome", "Bad-Id", "", 5, "a b", "dock"]}))
	testing.ok(not SetupStepTracker.has_seen(&"Bad-Id"), "an id failing ^[a-z0-9_]+$ is not read")
	SetupStepTracker.mark_seen(&"updates")
	testing.eq(_read_seen(), ["welcome", "dock", "updates"], "and is dropped on rewrite")
	_end_scratch_files()
	print("")


# The exact bytes a record writes: compact JSON with sorted keys, created with its
# folder when missing. Every later reader parses this file; a 1.0.x build only
# checks it exists.
static func _test_tracker_written_bytes(testing) -> void:
	testing.begin("Setup step tracker: the bytes a record writes")
	_use_scratch_files()
	_write_file(_FLAG, JSON.stringify({"format": 1, "seen": ["welcome"], "note": "kept"}))
	SetupStepTracker.mark_seen(&"dock")
	testing.eq(_read_file(_FLAG), "{\"format\":1,\"note\":\"kept\",\"seen\":[\"welcome\",\"dock\"]}",
			"compact JSON, keys sorted, unknown keys kept")
	_end_scratch_files()

	var nested_flag := _NESTED_DIR.path_join("flag")
	_remove_nested_dir(nested_flag)
	SetupStepTracker.set_file_paths(nested_flag, _PROGRESS)
	SetupStepTracker.mark_seen(&"welcome")
	testing.eq(_read_file(nested_flag), "{\"format\":1,\"seen\":[\"welcome\"]}",
			"a missing folder is created and the file written")
	_remove_nested_dir(nested_flag)
	SetupStepTracker.reset_file_paths()
	print("")


# --- The run planner --------------------------------------------------------------

static func _test_run_planner(testing) -> void:
	testing.begin("Setup steps: the run planner")
	var all_ids := SetupSteps.all_ids()
	var missed := _ids([&"optional_steps", &"updates"])
	testing.eq(SetupSteps.plan_button_run(), all_ids,
			"a button run → every step, even mid-session with nothing unseen")
	testing.eq(SetupSteps.plan_run(all_ids, false, false, false, false), all_ids,
			"nothing seen, mid-session enable → every step")
	testing.eq(SetupSteps.plan_run(all_ids, false, false, true, false), all_ids,
			"nothing seen, editor start → every step, the setting off or not")
	testing.eq(SetupSteps.plan_run(missed, true, true, false, false), _ids([]),
			"something seen, mid-session enable → no run")
	testing.eq(SetupSteps.plan_run(missed, true, true, true, false), missed,
			"editor start, setting on → the unseen steps")
	testing.eq(SetupSteps.plan_run(missed, true, false, true, false), _ids([&"updates"]),
			"editor start, setting off → the unseen required steps only")
	testing.eq(SetupSteps.plan_run(_ids([&"dock", &"welcome"]), true, false, true, false), _ids([&"welcome"]),
			"setting off keeps a required step and drops an optional one")
	testing.eq(SetupSteps.plan_run(_ids([&"updates", &"optional_steps"]), true, true, true, false), missed,
			"the run follows the table's order")
	testing.eq(SetupSteps.plan_run(_ids([]), true, true, true, false), _ids([]),
			"editor start with nothing unseen → no run")
	print("")


static func _test_seen_on_close(testing) -> void:
	testing.begin("Setup steps: what × records")
	var all_ids := SetupSteps.all_ids()
	testing.eq(SetupSteps.seen_on_close(all_ids, 0, _ids([&"welcome"])),
			_ids([&"welcome", &"optional_steps", &"dock"]),
			"× on welcome in a first run → welcome and the optional steps; mcp_json and updates stay unseen")
	var visited := _ids([&"welcome", &"mcp_json", &"optional_steps", &"updates"])
	testing.eq(SetupSteps.seen_on_close(all_ids, 3, visited), _ids([&"updates", &"dock"]),
			"× on updates → updates and the unvisited dock")
	testing.eq(SetupSteps.seen_on_close(_ids([&"optional_steps", &"updates"]), 0, _ids([&"optional_steps"])),
			_ids([&"optional_steps"]), "× on a missed-steps run's first step leaves the required one unseen")
	testing.eq(SetupSteps.seen_on_close(_ids([]), 0, _ids([])), _ids([]), "× with no run records nothing")
	print("")


# --- The consent gate --------------------------------------------------------------

static func _test_consent_gate(testing) -> void:
	testing.begin("Consent gate: may check for updates")
	for toggle_on in [true, false]:
		for updates_seen in [true, false]:
			Consent.set_readers(
					func() -> bool: return toggle_on,
					func(step_id: StringName) -> bool: return updates_seen and step_id == &"updates")
			testing.eq(Consent.may_check_for_updates(), toggle_on and updates_seen,
					"toggle %s, updates step %s" % ["on" if toggle_on else "off", "seen" if updates_seen else "unseen"])
	Consent.reset_readers()
	print("")


static func _test_setting_readers(testing) -> void:
	testing.begin("Setup settings: the two toggles' readers")
	var store := _Store.new()
	testing.ok(SetupSteps.shows_optional_steps(null), "show optional steps: no EditorSettings → on")
	testing.ok(SetupSteps.shows_optional_steps(store), "show optional steps: no key → on")
	store.values[SetupSteps.SHOW_OPTIONAL_STEPS_SETTING] = false
	testing.ok(not SetupSteps.shows_optional_steps(store), "show optional steps: a stored false → off")
	testing.ok(UpdateCheck.is_check_enabled(null), "check for updates: no ProjectSettings → on")
	testing.ok(UpdateCheck.is_check_enabled(store), "check for updates: no key → on")
	store.values[UpdateCheck.SETTING] = false
	testing.ok(not UpdateCheck.is_check_enabled(store), "check for updates: a stored false → off")
	print("")


# --- Run-level buttons and labels ------------------------------------------------------

static func _test_spec_in_run(testing) -> void:
	testing.begin("Setup wizard: buttons and labels per place in a run")
	var wizard := OnboardingWizard.new(null, null, null, null)
	var updates_spec := StepSpecs.updates()

	var first := OnboardingWizard._spec_in_run(updates_spec, true, false)
	_assert_actions(testing, first, ["remind_later"], "first step: no Back, Remind me later")
	testing.eq(_labels(first), ["Remind me later"], "first step: the Remind me later label")
	testing.eq(str(first.get("ok_label")), "Next", "first step, not last: Next")

	var middle := OnboardingWizard._spec_in_run(updates_spec, false, false)
	_assert_actions(testing, middle, ["back"], "a middle step: Back, no Remind me later")

	var last := OnboardingWizard._spec_in_run(updates_spec, false, true)
	testing.eq(str(last.get("ok_label")), "Done", "the last step: Next reads Done")

	var only := OnboardingWizard._spec_in_run(updates_spec, true, true)
	_assert_actions(testing, only, ["remind_later"], "a one-step run: no Back, Remind me later")
	testing.eq(str(only.get("ok_label")), "Done", "a one-step run: Done")

	var dock_last := OnboardingWizard._spec_in_run(StepSpecs.dock_overview(wizard._reveal_dock), false, true)
	testing.eq(str(dock_last.get("ok_label")), "Close", "the dock's Close stays on the last step")
	_assert_actions(testing, dock_last, ["back", "open_info"], "the dock keeps Back and Open Info")

	var mcp_json_last := OnboardingWizard._spec_in_run(StepSpecs.mcp_json(false), false, true)
	testing.eq(str(mcp_json_last.get("ok_label")), "Create .mcp.json", "an action label stays on the last step")
	var mcp_json_first := OnboardingWizard._spec_in_run(StepSpecs.mcp_json(true), true, false)
	_assert_actions(testing, mcp_json_first, ["overwrite_mcp", "remind_later"],
			"the .mcp.json step keeps its own buttons")
	testing.eq(_labels(updates_spec), ["Back"], "fitting a spec leaves the step's own spec unchanged")
	print("")


static func _test_new_step_specs(testing) -> void:
	testing.begin("Setup wizard: the optional-steps and updates steps")
	var wizard := OnboardingWizard.new(null, null, null, null)
	var optional_spec := StepSpecs.optional_steps()
	testing.eq(str(optional_spec.get("text")), _OPTIONAL_STEPS_TEXT, "optional_steps → its text, verbatim")
	testing.eq(str(optional_spec.get("check_box")), "Show optional steps added by toolkit updates",
			"optional_steps → its checkbox label")
	testing.eq(str(optional_spec.get("ok_label")), "Next", "optional_steps → Next")
	var updates_spec := StepSpecs.updates()
	testing.eq(str(updates_spec.get("text")), _UPDATES_TEXT, "updates → its text, verbatim")
	testing.eq(str(updates_spec.get("check_box")), "Check for updates", "updates → its checkbox label")
	testing.eq(str(updates_spec.get("ok_label")), "Next", "updates → Next")
	testing.eq(str(wizard._spec_for_step(SetupSteps.OPTIONAL_STEPS).get("check_box")),
			"Show optional steps added by toolkit updates", "dispatch optional_steps → its spec")
	testing.eq(str(wizard._spec_for_step(SetupSteps.UPDATES).get("check_box")), "Check for updates",
			"dispatch updates → its spec")
	print("")


# --- How a run ends ---------------------------------------------------------------------

static func _test_run_endings(testing, tree: SceneTree) -> void:
	testing.begin("Setup wizard: how a run ends")
	var run := _ids([&"optional_steps", &"updates", &"dock"])

	var opened := _open(tree, run, _settings(_Store.new(), _Store.new()))
	var dialog: AcceptDialog = opened["dialog"]
	var seen: Array = opened["seen"]
	testing.eq(dialog.title, "MCP Toolkit — Setup Wizard (1 of 3)", "the title counts the run")
	dialog.get_ok_button().pressed.emit()
	testing.eq(seen, [&"optional_steps"], "Next records the step it leaves")
	testing.eq(dialog.title, "MCP Toolkit — Setup Wizard (2 of 3)", "and moves on")
	dialog.custom_action.emit(&"back")
	testing.eq(dialog.title, "MCP Toolkit — Setup Wizard (1 of 3)", "Back moves within the run")
	testing.eq(seen, [&"optional_steps"], "Back records nothing")
	dialog.get_ok_button().pressed.emit()
	dialog.get_ok_button().pressed.emit()
	testing.eq(dialog.ok_button_text, "Close", "the dock's Close on the last step")
	dialog.get_ok_button().pressed.emit()
	testing.eq(seen, [&"optional_steps", &"optional_steps", &"updates", &"dock"],
			"leaving each step records it, again after Back")
	testing.ok(opened["wizard"]._dialog == null, "the last step closes the wizard")
	await _settle(tree)

	opened = _open(tree, SetupSteps.all_ids(), _settings(_Store.new(), _Store.new()))
	dialog = opened["dialog"]
	dialog.canceled.emit()
	testing.eq(opened["seen"], [&"welcome", &"optional_steps", &"dock"],
			"× on welcome → welcome and the unvisited optional steps")
	testing.ok(opened["wizard"]._dialog == null, "× closes the wizard")
	await _settle(tree)

	opened = _open(tree, run, _settings(_Store.new(), _Store.new()))
	dialog = opened["dialog"]
	dialog.get_ok_button().pressed.emit()
	dialog.canceled.emit()
	testing.eq(opened["seen"], [&"optional_steps", &"updates", &"dock"],
			"× on updates → updates and the unvisited dock")
	await _settle(tree)

	opened = _open(tree, _ids([&"optional_steps", &"updates"]), _settings(_Store.new(), _Store.new()))
	dialog = opened["dialog"]
	dialog.canceled.emit()
	testing.eq(opened["seen"], [&"optional_steps"], "× before a required step leaves it unseen")
	await _settle(tree)

	opened = _open(tree, run, _settings(_Store.new(), _Store.new()))
	dialog = opened["dialog"]
	dialog.custom_action.emit(&"remind_later")
	testing.eq(opened["seen"], [], "Remind me later records nothing")
	testing.ok(opened["wizard"]._dialog == null, "Remind me later closes the wizard")
	await _settle(tree)
	testing.eq(opened["seen"], [], "and nothing is recorded as the dialog goes")

	opened = _open(tree, run, _settings(_Store.new(), _Store.new()))
	dialog = opened["dialog"]
	opened["wizard"].teardown()
	testing.eq(opened["seen"], [], "closing the editor mid-run records nothing")
	print("")


# The dock's button asks for a run of every step while one may already be open.
static func _test_open_run_reused(testing, tree: SceneTree) -> void:
	testing.begin("Setup wizard: a second request reuses the open run")
	var opened := _open(tree, _ids([&"optional_steps", &"updates", &"dock"]), _settings(_Store.new(), _Store.new()))
	var wizard: OnboardingWizard = opened["wizard"]
	var dialog: AcceptDialog = opened["dialog"]
	var seen: Array = opened["seen"]
	dialog.get_ok_button().pressed.emit()
	wizard.show_run(SetupSteps.all_ids())
	testing.ok(wizard._dialog == dialog, "the open dialog stays the wizard's dialog")
	testing.eq(dialog.title, "MCP Toolkit — Setup Wizard (2 of 3)", "the open run keeps its place")
	testing.eq(wizard._run, _ids([&"optional_steps", &"updates", &"dock"]), "the run is not replaced")
	testing.eq(seen, [&"optional_steps"], "and the request records nothing")
	dialog.canceled.emit()
	await _settle(tree)
	print("")


static func _test_check_box_writes(testing, tree: SceneTree) -> void:
	testing.begin("Setup wizard: the checkbox steps' writes")
	var project := _Store.new()
	var editor := _Store.new()
	project.values[UpdateCheck.SETTING] = false
	var opened := _open(tree, _ids([&"optional_steps", &"updates"]), _settings(project, editor))
	var wizard: OnboardingWizard = opened["wizard"]
	var dialog: AcceptDialog = opened["dialog"]
	testing.ok(wizard._check_box.button_pressed, "optional_steps shows the default, ticked")
	dialog.get_ok_button().pressed.emit()
	testing.eq(editor.writes, [], "Next with the box unchanged writes nothing")
	testing.ok(not wizard._check_box.button_pressed, "updates shows the project's false, unticked")
	testing.eq(dialog.ok_button_text, "Done", "the run's last step reads Done")
	wizard._check_box.button_pressed = true
	dialog.get_ok_button().pressed.emit()
	testing.eq(project.writes, [[UpdateCheck.SETTING, true]],
			"re-ticking writes the default back, which drops the key from project.godot")
	testing.eq(project.saves, 1, "and saves project.godot")
	await _settle(tree)

	project = _Store.new()
	editor = _Store.new()
	opened = _open(tree, _ids([&"optional_steps", &"updates"]), _settings(project, editor))
	wizard = opened["wizard"]
	dialog = opened["dialog"]
	wizard._check_box.button_pressed = false
	dialog.get_ok_button().pressed.emit()
	testing.eq(editor.writes, [[SetupSteps.SHOW_OPTIONAL_STEPS_SETTING, false]],
			"unticking optional_steps writes false to EditorSettings")
	testing.eq(project.saves, 0, "an EditorSettings write saves no project.godot")
	wizard._check_box.button_pressed = false
	dialog.canceled.emit()
	testing.eq(project.writes, [], "× applies nothing")
	await _settle(tree)

	var settings := _settings(project, editor)
	project.values[UpdateCheck.SETTING] = true
	testing.ok(settings.is_on(SetupSteps.UPDATES), "a stored true shows ticked")
	settings.apply(SetupSteps.UPDATES, false)
	testing.eq(project.writes, [[UpdateCheck.SETTING, false]], "unticking updates writes false")
	settings.apply(SetupSteps.UPDATES, false)
	testing.eq(project.writes.size(), 1, "applying the same value again writes nothing")
	print("")


# --- The rest --------------------------------------------------------------------------

static func _test_enable_prompt_gate(testing) -> void:
	testing.begin("Enable-time .mcp.json prompt: waits for the mcp_json step")
	testing.ok(not MCPJsonEnablePrompt.should_offer(false, false), "no file, step unseen → no offer")
	testing.ok(MCPJsonEnablePrompt.should_offer(false, true), "no file, step seen → offer")
	testing.ok(not MCPJsonEnablePrompt.should_offer(true, true), "a file → no offer")
	_use_scratch_files()
	_write_file(_FLAG, JSON.stringify({"format": 1, "seen": ["welcome"]}))
	testing.ok(not SetupStepTracker.has_seen(&"mcp_json"), "the gate's input: mcp_json unseen")
	_write_file(_FLAG, "1")
	testing.ok(SetupStepTracker.has_seen(&"mcp_json"), "the gate's input: a 1.0 flag counts mcp_json seen")
	_end_scratch_files()
	print("")


static func _test_rename_migration(testing) -> void:
	testing.begin("Setup step tracker: the rename migration")
	# Each case reads the old path first, which sets what the migration carries.
	_use_scratch_files()
	_remove_renamed_files()
	_write_file(_FLAG, JSON.stringify({"format": 1, "seen": ["welcome", "mcp_json"]}))
	SetupStepTracker.has_seen(&"welcome")
	SetupStepTracker.set_file_paths(_RENAMED_FLAG, _RENAMED_PROGRESS)
	SetupStepTracker.migrate_flag_after_rename()
	testing.eq(_read_seen(_RENAMED_FLAG), ["welcome", "mcp_json"],
			"the steps seen at the old path → seen at the new path, and no others")

	_use_scratch_files()
	_remove_renamed_files()
	_write_file(_FLAG, JSON.stringify({"format": 1, "seen": ["future_step"]}))
	SetupStepTracker.has_seen(&"welcome")
	SetupStepTracker.set_file_paths(_RENAMED_FLAG, _RENAMED_PROGRESS)
	SetupStepTracker.migrate_flag_after_rename()
	testing.eq(_read_seen(_RENAMED_FLAG), ["future_step"], "keeping an unknown id")
	_remove_renamed_files()
	_end_scratch_files()
	print("")


# A rename moves user:// before the tracker hears of it: the tracker reads the old
# path, then the migration runs against the new one.
static func _test_rename_keeps_unseen_steps(testing) -> void:
	testing.begin("Setup step tracker: a rename keeps unseen steps unseen")
	Consent.set_readers(
			func() -> bool: return true,
			func(step_id: StringName) -> bool: return SetupStepTracker.has_seen(step_id))

	_use_scratch_files()
	_remove_renamed_files()
	testing.ok(not SetupStepTracker.has_seen(&"welcome"), "no file at the old path → nothing seen")
	SetupStepTracker.set_file_paths(_RENAMED_FLAG, _RENAMED_PROGRESS)
	SetupStepTracker.migrate_flag_after_rename()
	testing.ok(not SetupStepTracker.has_seen(&"updates"), "nothing seen → updates unseen at the new path")
	testing.ok(not Consent.may_check_for_updates(), "and the update check stays off")

	_use_scratch_files()
	_remove_renamed_files()
	SetupStepTracker.mark_seen(&"welcome")
	SetupStepTracker.set_file_paths(_RENAMED_FLAG, _RENAMED_PROGRESS)
	SetupStepTracker.migrate_flag_after_rename()
	testing.ok(SetupStepTracker.has_seen(&"welcome"), "welcome seen → welcome seen at the new path")
	testing.ok(not SetupStepTracker.has_seen(&"updates"), "and updates unseen there")
	testing.ok(not Consent.may_check_for_updates(), "and the update check stays off")

	Consent.reset_readers()
	_remove_renamed_files()
	_end_scratch_files()
	print("")


# --- Helpers -----------------------------------------------------------------------------

static func _ids(values: Array) -> Array[StringName]:
	var ids: Array[StringName] = []
	for value in values:
		ids.append(StringName(value))
	return ids


static func _use_scratch_files() -> void:
	SetupStepTracker.set_file_paths(_FLAG, _PROGRESS)
	_remove_scratch_files()


static func _end_scratch_files() -> void:
	_remove_scratch_files()
	SetupStepTracker.reset_file_paths()


static func _remove_scratch_files() -> void:
	for path in [_FLAG, _PROGRESS]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


static func _remove_nested_dir(nested_flag: String) -> void:
	if FileAccess.file_exists(nested_flag):
		DirAccess.remove_absolute(nested_flag)
	if DirAccess.dir_exists_absolute(_NESTED_DIR):
		DirAccess.remove_absolute(_NESTED_DIR)


static func _remove_renamed_files() -> void:
	for path in [_RENAMED_FLAG, _RENAMED_PROGRESS]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


static func _write_file(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


static func _read_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


static func _read_data(path: String = _FLAG) -> Dictionary:
	var json := JSON.new()
	if json.parse(_read_file(path)) != OK or not json.data is Dictionary:
		return {}
	return json.data


static func _read_seen(path: String = _FLAG) -> Array:
	var seen: Variant = _read_data(path).get("seen", [])
	return seen if seen is Array else []


static func _settings(project: _Store, editor: _Store) -> SetupStepSettings:
	return SetupStepSettings.new(project, func() -> Object: return editor)


# Open a run's dialog in the runner's tree, recording every step_seen.
static func _open(tree: SceneTree, steps: Array[StringName], settings: SetupStepSettings) -> Dictionary:
	var wizard := OnboardingWizard.new(null, null, null, null)
	wizard.set_settings(settings)
	var seen: Array = []
	wizard.step_seen.connect(func(step_id: StringName) -> void: seen.append(step_id))
	var dialog := wizard._open_run(steps)
	tree.root.add_child(dialog)
	dialog.popup_centered()
	return {"wizard": wizard, "dialog": dialog, "seen": seen}


# Let the closed dialog's queued free run before the next group opens one.
static func _settle(tree: SceneTree) -> void:
	await tree.process_frame


static func _labels(spec: Dictionary) -> Array:
	var labels := []
	for entry in spec.get("buttons", []):
		var button: Dictionary = entry
		labels.append(str(button.get("label", "")))
	return labels


static func _assert_actions(testing, spec: Dictionary, expected: Array, label: String) -> void:
	var actions := []
	for entry in spec.get("buttons", []):
		var button: Dictionary = entry
		actions.append(str(button.get("action", "")))
	testing.eq(actions, expected, label)


# A stand-in for ProjectSettings or EditorSettings that records each write.
class _Store:
	extends RefCounted

	var values: Dictionary = {}
	var writes: Array = []
	var saves: int = 0

	func has_setting(key: String) -> bool:
		return values.has(key)

	func get_setting(key: String, default_value: Variant = null) -> Variant:
		return values.get(key, default_value)

	func set_setting(key: String, value: Variant) -> void:
		values[key] = value
		writes.append([key, value])

	func save() -> int:
		saves += 1
		return OK
