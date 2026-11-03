@tool
extends RefCounted
## Unit tests for swapping a staged update in, on scratch addon and update folders: the
## swap and each step of it, a stage held to what is signed, what postpones, what refuses,
## and a journal that is not staged.

const Testing := preload("res://test/units/testing.gd")
const ContentHash := preload("res://addons/godot_mcp_toolkit/self_update/content_hash.gd")
const UpdateApplier := preload("res://addons/godot_mcp_toolkit/self_update/update_applier.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const UpdateJournal := preload("res://addons/godot_mcp_toolkit/self_update/update_journal.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const ReleaseFileList := preload("res://addons/godot_mcp_toolkit/self_update/release_file_list.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")
const TrustFixtures := preload("res://test/units/trust_fixtures.gd")
const TrustChain := preload("res://addons/godot_mcp_toolkit/self_update/trust_chain.gd")
const LogBuffer := preload("res://addons/godot_mcp_toolkit/logging/log_buffer.gd")

const _RELEASE := {"core/a.gd": "new a", "core/b.gd": "new b"}


static func run(testing: Testing) -> void:
	_test_full_apply(testing)
	_test_steps(testing)
	_test_ignore_files(testing)
	_test_from_refreshed(testing)
	_test_leftover_backup(testing)
	_test_failed_first_rename(testing)
	_test_failed_second_rename(testing)
	_test_failed_undo(testing)
	_test_failed_applying_write(testing)
	_test_stage_mismatches(testing)
	_test_second_mismatch(testing)
	_test_vanished(testing)
	_test_not_applied(testing)
	_test_shipped_keys(testing)
	_test_exit_reads_the_chain(testing)
	_test_nothing_staged(testing)


# A scenario with a release staged over 1.1.0.
static func _staged(purpose: String) -> Dictionary:
	var scenario := UpdateFixtures.make_scenario(purpose, "1.1.0", {"core/a.gd": "old a"})
	UpdateFixtures.stage(scenario["updates"], "1.2.0", _RELEASE, "1.1.0", UpdateFixtures.key())
	return scenario


static func _read(folder: String, path: String) -> String:
	return FileAccess.get_file_as_string(ProjectSettings.globalize_path(folder).path_join(path))


static func _version(folder: String) -> String:
	var config := ConfigFile.new()
	config.load(ProjectSettings.globalize_path(folder).path_join("plugin.cfg"))
	return str(config.get_value("plugin", "version", ""))


# Runs the apply with engine errors silenced, for a scenario that makes one on purpose.
static func _apply_quietly(options: Dictionary) -> Dictionary:
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var result := UpdateApplier.apply_pending(options)
	Engine.print_error_messages = printed
	return result


static func _test_full_apply(testing: Testing) -> void:
	testing.begin("Update applier: a staged update is swapped in")
	var scenario := UpdateFixtures.make_scenario("apply_full", "1.1.0", {"core/a.gd": "old a", "old.gd": "dropped"})
	var addon: String = scenario["addon"]
	var updates: String = scenario["updates"]
	FolderFiles.write_checked(str(scenario["addon_path"]).path_join("mine.gd"), "my own".to_utf8_buffer())
	UpdateFixtures.stage(updates, "1.2.0", _RELEASE, "1.1.0", UpdateFixtures.key())
	var list_text := str(UpdateFixtures.release_entries("1.2.0", _RELEASE)["addons/godot_mcp_toolkit/" + ReleaseFileList.FILE_NAME])
	var result := UpdateApplier.apply_pending(scenario["options"])
	var a := _read(addon, "core/a.gd")
	var b := _read(addon, "core/b.gd")
	var dropped_gone := not FileAccess.file_exists(str(scenario["addon_path"]).path_join("old.gd"))
	var mine_gone := not FileAccess.file_exists(str(scenario["addon_path"]).path_join("mine.gd"))
	var version := _version(addon)
	var backup := UpdateFolder.backup_folder("1.1.0", updates)
	var backup_a := _read(backup, "core/a.gd")
	var backup_dropped := _read(backup, "old.gd")
	var backup_mine := _read(backup, "mine.gd")
	var stage_gone := not UpdateFixtures.scenario_has_folder(scenario, "stage")
	var journal := UpdateJournal.read(updates)
	var logged := FileAccess.get_file_as_string(UpdateFolder.log_path(updates))
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result, {"state": "applied", "reason": ""}, "the apply reports applied")
	testing.eq(a, "new a", "a changed file → the release's content")
	testing.eq(b, "new b", "a new file → written")
	testing.ok(dropped_gone, "a listed file the release dropped → deleted")
	testing.ok(mine_gone, "a file the list does not name → not copied back")
	testing.eq(version, "1.2.0", "plugin.cfg → the new version")
	testing.eq(backup_a, "old a", "the backup holds the old content")
	testing.eq(backup_dropped, "dropped", "the backup holds the dropped file")
	testing.eq(backup_mine, "my own", "the backup holds the file the swap discarded")
	testing.ok(stage_gone, "the stage → it is the live folder now")
	testing.eq(journal["state"], "applied", "the journal says applied")
	testing.eq(journal["expected_tree_hash"], ContentHash.of_bytes(list_text.to_utf8_buffer()),
			"the journal keeps the hash of the signed list")
	testing.ok(logged.contains("apply 1.2.0: applied"), "the install log says applied")
	print("")


# What each step finds, which is what a kill at that step leaves.
static func _test_steps(testing: Testing) -> void:
	testing.begin("Update applier: the state at each step")
	var scenario := _staged("apply_steps")
	var addon: String = scenario["addon"]
	var updates: String = scenario["updates"]
	var seen := []
	var options: Dictionary = scenario["options"]
	options["on_step"] = func(step: String) -> void:
		seen.append([step, UpdateJournal.read(updates)["state"], _version(addon), UpdateFixtures.scenario_has_folder(scenario, "stage"), UpdateFixtures.scenario_has_folder(scenario, "backup-1.1.0")])
	var result := UpdateApplier.apply_pending(options)
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["state"], "applied", "the apply finishes")
	testing.eq(seen, [
		["checked", "staged", "1.1.0", true, false],
		["applying", "applying", "1.1.0", true, false],
		["live_moved", "applying", "", true, true],
		["stage_moved", "applying", "1.2.0", false, true],
	], "journal, live version, stage and backup at each step, in order")
	print("")


static func _test_ignore_files(testing: Testing) -> void:
	testing.begin("Update applier: the ignore files")
	var scenario := _staged("apply_ignore")
	var result := UpdateApplier.apply_pending(scenario["options"])
	var gitignore := _read(scenario["updates"], ".gitignore")
	var p4ignore := _read(scenario["updates"], ".p4ignore")
	var gdignore_there := FileAccess.file_exists(str(scenario["updates_path"]).path_join(".gdignore"))
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["state"], "applied", "missing ones → the apply goes on")
	testing.eq(gitignore, "*\n", "and .gitignore is back")
	testing.eq(p4ignore, "*\n", "and .p4ignore is back")
	testing.ok(gdignore_there, "and .gdignore is back")

	var blocked := _staged("apply_ignore_blocked")
	DirAccess.make_dir_recursive_absolute(str(blocked["updates_path"]).path_join(".gitignore"))
	var blocked_result := _apply_quietly(blocked["options"])
	var journal := UpdateJournal.read(blocked["updates"])
	var version := _version(blocked["addon"])
	var stage_kept := UpdateFixtures.scenario_has_folder(blocked, "stage")
	UpdateFixtures.remove_scenario(blocked)
	testing.eq(blocked_result, {"state": "staged", "reason": "could not write the update folder's ignore files"},
			"one that cannot be written → postponed")
	testing.eq(journal["attempts"], 1, "and one attempt counted")
	testing.eq(version, "1.1.0", "the live folder stays")
	testing.ok(stage_kept, "the stage stays")
	print("")


# A pull between staging and exit: the journal's `from` is stale.
static func _test_from_refreshed(testing: Testing) -> void:
	testing.begin("Update applier: from is read from the live folder")
	var scenario := UpdateFixtures.make_scenario("apply_refresh", "1.1.5", {"core/a.gd": "old a"})
	UpdateFixtures.stage(scenario["updates"], "1.2.0", _RELEASE, "1.1.0", UpdateFixtures.key())
	var result := UpdateApplier.apply_pending(scenario["options"])
	var journal := UpdateJournal.read(scenario["updates"])
	var right_backup := UpdateFixtures.scenario_has_folder(scenario, "backup-1.1.5")
	var wrong_backup := UpdateFixtures.scenario_has_folder(scenario, "backup-1.1.0")
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["state"], "applied", "the apply goes on")
	testing.eq(journal["from"], "1.1.5", "the journal says the live version")
	testing.eq(journal["backup"], "backup-1.1.5", "and the backup named with it, or it would read as no journal")
	testing.ok(right_backup and not wrong_backup, "the backup folder has that name")
	print("")


static func _test_leftover_backup(testing: Testing) -> void:
	testing.begin("Update applier: a backup already there")
	var equal := _staged("apply_backup_equal")
	var equal_files: Dictionary = UpdateFixtures.release_entries("1.1.0", {"core/a.gd": "old a"})
	for entry: String in equal_files:
		FolderFiles.write_checked(str(equal["updates_path"]).path_join("backup-1.1.0").path_join(entry.trim_prefix("addons/godot_mcp_toolkit/")),
				str(equal_files[entry]).to_utf8_buffer())
	var equal_result := UpdateApplier.apply_pending(equal["options"])
	var equal_version := _version(equal["addon"])
	UpdateFixtures.remove_scenario(equal)
	testing.eq(equal_result["state"], "applied", "equal to the live folder → deleted, and the apply goes on")
	testing.eq(equal_version, "1.2.0", "the live folder is the release")

	var other := _staged("apply_backup_other")
	var other_backup := str(other["updates_path"]).path_join("backup-1.1.0")
	FolderFiles.write_checked(other_backup.path_join("someone.gd"), "keep me".to_utf8_buffer())
	var reason := "backup-1.1.0 holds something other than the installed toolkit"
	var first := UpdateApplier.apply_pending(other["options"])
	var second := UpdateApplier.apply_pending(other["options"])
	var journal := UpdateJournal.read(other["updates"])
	var kept := FileAccess.get_file_as_string(other_backup.path_join("someone.gd"))
	var version := _version(other["addon"])
	var stage_kept := UpdateFixtures.scenario_has_folder(other, "stage")
	UpdateFixtures.remove_scenario(other)
	testing.eq(first, {"state": "staged", "reason": reason}, "different → postponed, naming the folder")
	testing.eq(second, first, "and again at the next exit")
	testing.eq(journal["attempts"], 2, "counting each attempt")
	testing.eq(journal["reason"], reason, "the journal keeps the reason")
	testing.eq(kept, "keep me", "the folder is left alone")
	testing.eq(version, "1.1.0", "the live folder stays")
	testing.ok(stage_kept, "the stage stays")
	print("")


# A folder with a file in it where the backup goes blocks a rename on every platform.
static func _test_failed_first_rename(testing: Testing) -> void:
	testing.begin("Update applier: the first rename fails")
	var scenario := _staged("apply_rename_one")
	var obstacle := str(scenario["updates_path"]).path_join("backup-1.1.0")
	var options: Dictionary = scenario["options"]
	options["on_step"] = func(step: String) -> void:
		if step == UpdateApplier.STEP_APPLYING:
			FolderFiles.write_checked(obstacle.path_join("held.gd"), "held".to_utf8_buffer())
	var result := _apply_quietly(options)
	var journal := UpdateJournal.read(scenario["updates"])
	var version := _version(scenario["addon"])
	var stage_kept := UpdateFixtures.scenario_has_folder(scenario, "stage")
	FolderFiles.remove_tree(obstacle)
	options.erase("on_step")
	var retried := UpdateApplier.apply_pending(options)
	var retried_version := _version(scenario["addon"])
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result, {"state": "staged", "reason": "could not move the installed toolkit to backup-1.1.0"}, "postponed, with the reason")
	testing.eq(journal["state"], "staged", "the journal goes back to staged")
	testing.eq(journal["attempts"], 1, "one attempt counted")
	testing.eq(version, "1.1.0", "the live folder stays")
	testing.ok(stage_kept, "the stage stays")
	testing.eq(retried["state"], "applied", "the next exit, nothing in the way → applied")
	testing.eq(retried_version, "1.2.0", "the live folder is the release")
	print("")


static func _test_failed_second_rename(testing: Testing) -> void:
	testing.begin("Update applier: the second rename fails, and the first is undone")
	var scenario := _staged("apply_rename_two")
	var stage := str(scenario["updates_path"]).path_join("stage")
	var options: Dictionary = scenario["options"]
	options["on_step"] = func(step: String) -> void:
		if step == UpdateApplier.STEP_LIVE_MOVED:
			FolderFiles.remove_tree(stage)
	var result := _apply_quietly(options)
	var journal := UpdateJournal.read(scenario["updates"])
	var a := _read(scenario["addon"], "core/a.gd")
	var version := _version(scenario["addon"])
	var backup_left := UpdateFixtures.scenario_has_folder(scenario, "backup-1.1.0")
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result, {"state": "staged", "reason": "could not move the stage into place"}, "postponed, with the reason")
	testing.eq(journal["state"], "staged", "the journal goes back to staged")
	testing.eq(a, "old a", "the live folder holds the old files again")
	testing.eq(version, "1.1.0", "at the old version")
	testing.ok(not backup_left, "by rename: no backup stays behind")
	print("")


static func _test_failed_undo(testing: Testing) -> void:
	testing.begin("Update applier: the undo fails too")
	var scenario := _staged("apply_undo")
	var addon_path := str(scenario["addon_path"])
	var options: Dictionary = scenario["options"]
	options["on_step"] = func(step: String) -> void:
		if step == UpdateApplier.STEP_LIVE_MOVED:
			FolderFiles.write_checked(addon_path.path_join("in_the_way.gd"), "held".to_utf8_buffer())
	var result := _apply_quietly(options)
	var journal := UpdateJournal.read(scenario["updates"])
	var backup_whole := _read(UpdateFolder.backup_folder("1.1.0", scenario["updates"]), "core/a.gd") == "old a"
	var stage_whole := _read(UpdateFolder.stage_folder(scenario["updates"]), "core/a.gd") == "new a"
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result, {"state": "applying", "reason": "could not move the stage into place, nor backup-1.1.0 back"},
			"reported as still applying")
	testing.eq(journal["state"], "applying", "the journal stays there for the next start")
	testing.ok(backup_whole, "the backup is whole")
	testing.ok(stage_whole, "the stage is whole")
	print("")


# A read-only journal is the injected failure: the headless runner writes in place, so
# writing over it fails.
static func _test_failed_applying_write(testing: Testing) -> void:
	testing.begin("Update applier: the applying write fails")
	var scenario := _staged("apply_write")
	var journal_path := str(scenario["updates_path"]).path_join("journal.json")
	var options: Dictionary = scenario["options"]
	options["on_step"] = func(step: String) -> void:
		if step == UpdateApplier.STEP_CHECKED:
			UpdateFixtures.set_read_only(journal_path, true)
	var result := _apply_quietly(options)
	UpdateFixtures.set_read_only(journal_path, false)
	var state := str(UpdateJournal.read(scenario["updates"])["state"])
	var version := _version(scenario["addon"])
	var stage_kept := UpdateFixtures.scenario_has_folder(scenario, "stage")
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result, {"state": "staged", "reason": "could not write the journal"}, "postponed")
	testing.eq(state, "staged", "the journal never said applying")
	testing.eq(version, "1.1.0", "nothing moved")
	testing.ok(stage_kept, "the stage stays")
	print("")


# Rewrites the stage's list so its hashes agree with a changed stage, and the journal's
# stored hash with that list: nothing an agent could rewrite may satisfy the check.
static func _forge_stage(scenario: Dictionary) -> void:
	var stage := str(scenario["updates_path"]).path_join("stage")
	FolderFiles.write_checked(stage.path_join("core/a.gd"), "evil".to_utf8_buffer())
	var hashes := FolderFiles.hashes(stage)
	hashes.erase(ReleaseFileList.FILE_NAME)
	var forged := ReleaseFileList.format(hashes).to_utf8_buffer()
	FolderFiles.write_checked(stage.path_join(ReleaseFileList.FILE_NAME), forged)
	var journal := UpdateJournal.read(scenario["updates"])
	journal["expected_tree_hash"] = ContentHash.of_bytes(forged)
	UpdateJournal.write(journal, scenario["updates"])


# The result of a stage changed by `change`, and what it left.
static func _mismatch_of(purpose: String, change: Callable) -> Dictionary:
	var scenario := _staged(purpose)
	change.call(scenario)
	var result := UpdateApplier.apply_pending(scenario["options"])
	var outcome := {
		"result": result,
		"journal": UpdateJournal.read(scenario["updates"])["state"],
		"stage": UpdateFixtures.scenario_has_folder(scenario, "stage"),
		"zip": UpdateFixtures.scenario_has_folder(scenario, "1.2.0"),
		"live": _read(scenario["addon"], "core/a.gd"),
	}
	UpdateFixtures.remove_scenario(scenario)
	return outcome


static func _test_stage_mismatches(testing: Testing) -> void:
	testing.begin("Update applier: a stage held to what is signed")
	var cases := {
		"a changed file, with the list and the stored hash rewritten": func(scenario: Dictionary) -> void:
			_forge_stage(scenario),
		"a changed file": func(scenario: Dictionary) -> void:
			FolderFiles.write_checked(str(scenario["updates_path"]).path_join("stage/core/a.gd"), "evil".to_utf8_buffer()),
		"an extra file": func(scenario: Dictionary) -> void:
			FolderFiles.write_checked(str(scenario["updates_path"]).path_join("stage/extra.gd"), "evil".to_utf8_buffer()),
		"a missing file": func(scenario: Dictionary) -> void:
			DirAccess.remove_absolute(str(scenario["updates_path"]).path_join("stage/core/b.gd")),
		"the list changed alone": func(scenario: Dictionary) -> void:
			FolderFiles.write_checked(str(scenario["updates_path"]).path_join("stage").path_join(ReleaseFileList.FILE_NAME), "\n".to_utf8_buffer()),
		"no stage at all": func(scenario: Dictionary) -> void:
			FolderFiles.remove_tree(str(scenario["updates_path"]).path_join("stage")),
	}
	var index := 0
	for label: String in cases:
		var change: Callable = cases[label]
		var outcome := _mismatch_of("apply_mismatch_%d" % index, change)
		index += 1
		testing.eq(outcome, {
			"result": {"state": "not_applied", "reason": "the stage does not match the release"},
			"journal": "not_applied",
			"stage": false,
			"zip": true,
			"live": "old a",
		}, "%s → not applied, the stage gone, the zip kept, the live folder as it was" % label)
	print("")


static func _test_second_mismatch(testing: Testing) -> void:
	testing.begin("Update applier: a mismatch after the one re-stage")
	var scenario := _staged("apply_mismatch_second")
	FolderFiles.write_checked(str(scenario["updates_path"]).path_join("backup-1.0.0/a.gd"), "old".to_utf8_buffer())
	var journal := UpdateJournal.read(scenario["updates"])
	journal["restaged"] = true
	UpdateJournal.write(journal, scenario["updates"])
	_forge_stage(scenario)
	var result := UpdateApplier.apply_pending(scenario["options"])
	var state := str(UpdateJournal.read(scenario["updates"])["state"])
	var stage_gone := not UpdateFixtures.scenario_has_folder(scenario, "stage")
	var zip_gone := not UpdateFixtures.scenario_has_folder(scenario, "1.2.0")
	var backup_kept := UpdateFixtures.scenario_has_folder(scenario, "backup-1.0.0")
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result, {"state": "not_applied", "reason": "the stage does not match the release"}, "not applied")
	testing.eq(state, "not_applied", "the journal stays, so the next start can report it")
	testing.ok(stage_gone and zip_gone, "the stage and the zip → gone, so nothing re-stages")
	testing.ok(backup_kept, "a backup → kept")
	print("")


static func _test_vanished(testing: Testing) -> void:
	testing.begin("Update applier: the folder vanishes before the first rename")
	var scenario := _staged("apply_vanished")
	var updates_path := str(scenario["updates_path"])
	var options: Dictionary = scenario["options"]
	options["on_step"] = func(step: String) -> void:
		if step == UpdateApplier.STEP_CHECKED:
			FolderFiles.remove_tree(updates_path)
	var result := UpdateApplier.apply_pending(options)
	var version := _version(scenario["addon"])
	var recreated := DirAccess.dir_exists_absolute(updates_path)
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result, {"state": "", "reason": ""}, "no journal → nothing in progress")
	testing.eq(version, "1.1.0", "the live folder stays")
	testing.ok(not recreated, "the folder is not made again")

	var no_stage := _staged("apply_vanished_stage")
	var stage := str(no_stage["updates_path"]).path_join("stage")
	var no_stage_options: Dictionary = no_stage["options"]
	no_stage_options["on_step"] = func(step: String) -> void:
		if step == UpdateApplier.STEP_CHECKED:
			FolderFiles.remove_tree(stage)
	var no_stage_result := UpdateApplier.apply_pending(no_stage_options)
	var no_stage_version := _version(no_stage["addon"])
	UpdateFixtures.remove_scenario(no_stage)
	testing.eq(no_stage_result, {"state": "not_applied", "reason": "the stage does not match the release"},
			"only the stage gone → a mismatch, before anything moves")
	testing.eq(no_stage_version, "1.1.0", "the live folder stays")
	print("")


static func _apply_outcome(purpose: String, installed_version: String, prepare: Callable, extra_options: Dictionary = {}) -> Dictionary:
	var scenario := UpdateFixtures.make_scenario(purpose, installed_version, {"core/a.gd": "old a"})
	FolderFiles.write_checked(str(scenario["updates_path"]).path_join("backup-1.0.0/a.gd"), "old".to_utf8_buffer())
	prepare.call(scenario["updates"])
	var options: Dictionary = scenario["options"]
	options.merge(extra_options, true)
	var result := UpdateApplier.apply_pending(options)
	var untouched := _read(scenario["addon"], "core/a.gd") == "old a" and _version(scenario["addon"]) == installed_version
	var cleared := not UpdateFixtures.scenario_has_folder(scenario, "stage") and not UpdateFixtures.scenario_has_folder(scenario, "1.2.0") and UpdateFixtures.scenario_has_folder(scenario, "backup-1.0.0")
	var journal_state := str(UpdateJournal.read(scenario["updates"])["state"])
	UpdateFixtures.remove_scenario(scenario)
	return {"result": result, "untouched": untouched, "cleared": cleared, "journal": journal_state}


# Staged normally, then the zip swapped for one without a file list, re-signed: a layout
# this version cannot read, in a release the key did sign.
static func _stage_without_list(updates: String) -> void:
	UpdateFixtures.stage(updates, "1.2.0", {"core/a.gd": "new a"}, "1.1.0", UpdateFixtures.key())
	var folder := UpdateFolder.version_folder("1.2.0", updates)
	var archive := folder.path_join(ReleaseAssets.archive_name("1.2.0"))
	var entries := UpdateFixtures.release_entries("1.2.0", {"core/a.gd": "new a"})
	entries.erase("addons/godot_mcp_toolkit/" + ReleaseFileList.FILE_NAME)
	UpdateFixtures.write_zip(archive, entries)
	var manifest := UpdateFixtures.manifest_text("1.2.0", FileAccess.get_file_as_bytes(archive)).to_utf8_buffer()
	var absolute := ProjectSettings.globalize_path(folder)
	FolderFiles.write_checked(absolute.path_join(ReleaseAssets.manifest_name("1.2.0")), manifest)
	FolderFiles.write_checked(absolute.path_join(ReleaseAssets.signature_name("1.2.0")),
			UpdateFixtures.signature_of(manifest, UpdateFixtures.key()))


static func _test_not_applied(testing: Testing) -> void:
	testing.begin("Update applier: each reason not to apply")
	LogBuffer.setup()
	var cursor: int = LogBuffer.get_cursor() - 1
	var files := {"core/a.gd": "new a"}
	var untrusted := _apply_outcome("apply_untrusted", "1.1.0",
			func(updates: String) -> void: UpdateFixtures.stage(updates, "1.2.0", files, "1.1.0", UpdateFixtures.other_key()))
	var above_floor := _apply_outcome("apply_floor", "1.1.0",
			func(updates: String) -> void: UpdateFixtures.stage(updates, "1.2.0", files, "1.1.0", UpdateFixtures.key(), UpdateJournal.STAGED, "4.9"))
	var at_floor := _apply_outcome("apply_at_floor", "1.1.0",
			func(updates: String) -> void: UpdateFixtures.stage(updates, "1.2.0", files, "1.1.0", UpdateFixtures.key(), UpdateJournal.STAGED, "4.7"))
	var same := _apply_outcome("apply_same", "1.2.0",
			func(updates: String) -> void: UpdateFixtures.stage(updates, "1.2.0", files, "1.2.0", UpdateFixtures.key()))
	var guarded := _apply_outcome("apply_guarded", "1.1.0",
			func(updates: String) -> void: UpdateFixtures.stage(updates, "1.2.0", files, "1.1.0", UpdateFixtures.key()),
			{"guard_facts": {"headless": true}})
	var tampered := _apply_outcome("apply_tampered", "1.1.0",
			func(updates: String) -> void: UpdateFixtures.stage_tampered(updates, "1.2.0", files, "1.1.0", UpdateFixtures.key()))
	var no_list := _apply_outcome("apply_no_list", "1.1.0",
			func(updates: String) -> void: _stage_without_list(updates))
	testing.eq(untrusted["result"], {"state": "not_applied", "reason": "the update is not signed by a key this toolkit trusts"},
			"a manifest signed by an untrusted key → not applied")
	testing.eq(above_floor["result"], {"state": "not_applied", "reason": "version 1.2.0 needs Godot 4.9 or newer"},
			"a Godot floor above the engine → not applied")
	testing.eq(at_floor["result"]["state"], "applied", "a Godot floor equal to the engine → applied")
	testing.eq(same["result"], {"state": "not_applied", "reason": "version 1.2.0 is not newer than the installed 1.2.0"},
			"the installed version → not applied")
	testing.eq(guarded["result"], {"state": "not_applied", "reason": "A headless editor never installs updates."},
			"a guard → not applied, with its sentence")
	testing.eq(tampered["result"], {"state": "not_applied", "reason": "the staged archive does not match its manifest"},
			"an archive changed after staging → not applied")
	testing.eq(no_list["result"], {"state": "not_applied", "reason": "the staged archive has no file list this version can read"},
			"a zip with no list → not applied")
	var refused := [untrusted, above_floor, same, guarded, tampered, no_list]
	var all_untouched := true
	var all_cleared := true
	var all_journals := true
	for outcome: Dictionary in refused:
		all_untouched = all_untouched and bool(outcome["untouched"])
		all_cleared = all_cleared and bool(outcome["cleared"])
		all_journals = all_journals and outcome["journal"] == "not_applied"
	testing.ok(all_untouched, "every refused apply leaves the addon folder as it was")
	testing.ok(all_cleared, "every refused apply deletes the stage and the zip and keeps the backup")
	testing.ok(all_journals, "every refused apply leaves a not_applied journal to report from")
	if LogBuffer.uses_logger_api():
		var logged: Dictionary = LogBuffer.get_entries(100, ["error"], cursor)
		testing.eq(int(logged["returned"]), 0, "a refused apply prints no engine error")
	print("")


# A run's key is never a shipped key, so this holds once real keys ship too.
static func _test_shipped_keys(testing: Testing) -> void:
	testing.begin("Update applier: no keys passed in means the shipped keys")
	var scenario := _staged("apply_shipped_keys")
	var options: Dictionary = scenario["options"]
	options.erase("public_keys")
	var result := UpdateApplier.apply_pending(options)
	var version := _version(scenario["addon"])
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result, {"state": "not_applied", "reason": "the update is not signed by a key this toolkit trusts"}, "not applied")
	testing.eq(version, "1.1.0", "the live folder stays")
	print("")


# A scenario with a release signed by `signing_key` staged over 1.1.0, whose apply reads the
# chain from the first document and `trust_store`, never public_keys, which would skip it.
static func _staged_on_chain(purpose: String, signing_key: CryptoKey, trust_store: String) -> Dictionary:
	var scenario := UpdateFixtures.make_scenario(purpose, "1.1.0", {"core/a.gd": "old a"})
	UpdateFixtures.stage(scenario["updates"], "1.2.0", _RELEASE, "1.1.0", signing_key)
	var options: Dictionary = scenario["options"]
	options.erase("public_keys")
	options["trust_document"] = TrustFixtures.first_document([TrustFixtures.release_key()])
	options["trust_store"] = trust_store
	return scenario


# Applies a stage made by _staged_on_chain and answers what a test reads, cleaning up first.
static func _apply_on_chain(scenario: Dictionary) -> Dictionary:
	var has_keys_option: bool = scenario["options"].has("public_keys")
	var result := UpdateApplier.apply_pending(scenario["options"])
	var version := _version(scenario["addon"])
	var zip_kept := UpdateFixtures.scenario_has_folder(scenario, "1.2.0")
	UpdateFixtures.remove_scenario(scenario)
	return {"result": result, "version": version, "zip_kept": zip_kept, "has_keys_option": has_keys_option}


# The second document, moving the release key to the next one, accepted into `trust_store`.
static func _store_rotation(trust_store: String) -> String:
	var root := TrustFixtures.root_key()
	var chain := TrustChain.new(TrustFixtures.first_document([TrustFixtures.release_key()]), trust_store)
	var document := TrustFixtures.file_of(TrustFixtures.body(2, [root], 1, [TrustFixtures.next_release_key()]), [root])
	return str(chain.accept(document)["outcome"])


static func _test_exit_reads_the_chain(testing: Testing) -> void:
	testing.begin("Update applier: the exit verifies from the store, with no network")
	var store := UpdateFixtures.scratch("apply_chain_store")
	UpdateFixtures.remove(store)
	var first_key := TrustFixtures.release_key()
	var next_key := TrustFixtures.next_release_key()

	var first_key_before := _apply_on_chain(_staged_on_chain("apply_chain_first_before", first_key, store))
	var next_key_before := _apply_on_chain(_staged_on_chain("apply_chain_next_before", next_key, store))
	var rotation := _store_rotation(store)
	var next_key_after := _apply_on_chain(_staged_on_chain("apply_chain_next_after", next_key, store))
	var dropped := _apply_on_chain(_staged_on_chain("apply_chain_dropped", first_key, store))
	UpdateFixtures.remove(store)

	var refusal := {"state": "not_applied", "reason": "the update is not signed by a key this toolkit trusts"}
	testing.ok(not first_key_before["has_keys_option"], "the drill runs without public_keys")
	testing.eq(first_key_before["result"]["state"], "applied", "before the rotation, the first key's release applies")
	testing.eq(next_key_before["result"], refusal, "before the rotation, the next key's release is refused")
	testing.eq(rotation, "accepted", "the document reaches the store")
	testing.eq(next_key_after["result"]["state"], "applied", "after it, the next key's release applies from the store")
	testing.eq(next_key_after["version"], "1.2.0", "and the live folder is the release")
	testing.eq(dropped["result"], refusal, "a release staged under the dropped key is refused, with the reason")
	testing.eq(dropped["version"], "1.1.0", "the live folder stays")
	testing.ok(not dropped["zip_kept"], "its zip is deleted")
	print("")


static func _test_nothing_staged(testing: Testing) -> void:
	testing.begin("Update applier: only a staged journal is applied")
	var none := _apply_outcome("apply_none", "1.1.0", func(_updates: String) -> void: pass)
	var verified := _apply_outcome("apply_verified", "1.1.0",
			func(updates: String) -> void: UpdateFixtures.stage(updates, "1.2.0", {"core/a.gd": "new a"}, "1.1.0", UpdateFixtures.key(), UpdateJournal.VERIFIED))
	testing.eq(none["result"], {"state": "", "reason": ""}, "no journal → nothing done")
	testing.eq(verified["result"], {"state": "", "reason": ""}, "a verified journal → nothing done")
	testing.ok(none["untouched"] and verified["untouched"], "the addon folder stays as it was")
	print("")
