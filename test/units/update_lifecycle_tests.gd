@tool
extends RefCounted
## Unit tests for what the editor's start and exit do to an update: a headless editor leaves
## the update folder as it found it, a display editor and the override apply and settle, and
## the override's variable is read.

const Testing := preload("res://test/units/testing.gd")
const UpdateLifecycle := preload("res://addons/godot_mcp_toolkit/self_update/update_lifecycle.gd")
const InstallGuards := preload("res://addons/godot_mcp_toolkit/self_update/install_guards.gd")
const UpdateApplier := preload("res://addons/godot_mcp_toolkit/self_update/update_applier.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const UpdateJournal := preload("res://addons/godot_mcp_toolkit/self_update/update_journal.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

const _FROM := "1.1.0"
const _TO := "1.2.0"
const _HEADLESS := {"headless": true}
const _OVERRIDE := {"headless": true, "headless_allowed": true}
const _DISPLAY := {"headless": false}


static func run(testing: Testing) -> void:
	_test_headless_stays_out(testing, UpdateJournal.STAGED)
	_test_headless_stays_out(testing, UpdateJournal.VERIFIED)
	_test_editor_that_may_install(testing, _DISPLAY, "a display editor")
	_test_editor_that_may_install(testing, _OVERRIDE, "the override")
	_test_override_variable(testing)


static func _scenario(purpose: String, facts: Dictionary, journal_state: String) -> Dictionary:
	var scenario := UpdateFixtures.make_scenario(purpose, _FROM, {"core/a.gd": "old"})
	(scenario["options"] as Dictionary)["guard_facts"] = facts
	UpdateFixtures.stage(scenario["updates"], _TO, {"core/a.gd": "new"}, _FROM, UpdateFixtures.key(), journal_state)
	return scenario


# The settle clears a verified journal and the applier's refusal deletes a staged one, so each
# state shows a different call running where it must not.
static func _test_headless_stays_out(testing: Testing, journal_state: String) -> void:
	testing.begin("Update lifecycle: a headless editor leaves a %s update alone" % journal_state)
	var scenario := _scenario("lifecycle_headless_" + journal_state, _HEADLESS, journal_state)
	var options: Dictionary = scenario["options"]
	var updates := str(scenario["updates"])
	var journal_path := updates.path_join("journal.json")
	var journal_before := FileAccess.get_file_as_bytes(journal_path)
	var settled := UpdateLifecycle.settle_at_start(options)
	var journal_after_start := FileAccess.get_file_as_bytes(journal_path)
	var applied := UpdateLifecycle.apply_at_exit(options)
	var journal_after_exit := FileAccess.get_file_as_bytes(journal_path)
	var zip_left := FileAccess.file_exists(UpdateFolder.archive_path(_TO, updates))
	var stage_left := UpdateFixtures.scenario_has_folder(scenario, "stage")
	var installed := UpdateApplier.installed_version(str(scenario["addon_path"]))
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(settled, {}, "the start → nothing ran")
	testing.eq(applied, {}, "the exit → nothing ran")
	testing.ok(not journal_before.is_empty(), "there is a journal to keep")
	testing.eq(journal_after_start, journal_before, "the start → the journal's bytes unchanged")
	testing.eq(journal_after_exit, journal_before, "the exit → the journal's bytes unchanged")
	testing.ok(zip_left, "the zip stays")
	testing.ok(stage_left, "the stage stays")
	testing.eq(installed, _FROM, "and nothing is installed")
	print("")


static func _test_editor_that_may_install(testing: Testing, facts: Dictionary, editor: String) -> void:
	testing.begin("Update lifecycle: %s settles and applies" % editor)
	var scenario := _scenario("lifecycle_" + editor.replace(" ", "_"), facts, UpdateJournal.STAGED)
	var options: Dictionary = scenario["options"]
	var at_start := UpdateLifecycle.settle_at_start(options)
	var at_exit := UpdateLifecycle.apply_at_exit(options)
	var installed := UpdateApplier.installed_version(str(scenario["addon_path"]))
	var at_next_start := UpdateLifecycle.settle_at_start(options)
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(at_start.get("report", ""), "waiting", "the start → the staged update waits")
	testing.eq(at_exit.get("state", ""), "applied", "the exit → applied")
	testing.eq(installed, _TO, "the addon folder is the new version")
	testing.eq(at_next_start.get("report", ""), "updated", "the next start → reports it")
	print("")


# The unit suite's own editor decides what stays_out reads without the variable, so the rows
# compare against it: the override is what they pin, on a display run too.
static func _test_override_variable(testing: Testing) -> void:
	testing.begin("Update lifecycle: the override's variable lets a headless editor in")
	var previous := OS.get_environment(InstallGuards.HEADLESS_OVERRIDE_ENV)
	OS.unset_environment(InstallGuards.HEADLESS_OVERRIDE_ENV)
	var unset_out := UpdateLifecycle.stays_out()
	var empty_facts_out := UpdateLifecycle.stays_out({"guard_facts": {}})
	var unset_allowed: bool = InstallGuards.headless_facts()["headless_allowed"]
	OS.set_environment(InstallGuards.HEADLESS_OVERRIDE_ENV, "0")
	var other_value_out := UpdateLifecycle.stays_out()
	OS.set_environment(InstallGuards.HEADLESS_OVERRIDE_ENV, "1")
	var set_out := UpdateLifecycle.stays_out()
	var set_allowed: bool = InstallGuards.headless_facts()["headless_allowed"]
	if previous.is_empty():
		OS.unset_environment(InstallGuards.HEADLESS_OVERRIDE_ENV)
	else:
		OS.set_environment(InstallGuards.HEADLESS_OVERRIDE_ENV, previous)
	var headless := VersionUtils.is_headless()
	testing.eq(unset_out, headless, "unset → a headless editor stays out")
	testing.ok(not unset_allowed, "unset → not allowed")
	testing.eq(other_value_out, headless, "any value but 1 → still stays out")
	testing.ok(not set_out, "1 → no editor stays out")
	testing.ok(set_allowed, "1 → allowed")
	testing.eq(empty_facts_out, headless, "empty injected facts → this editor's own facts are read")
	print("")
