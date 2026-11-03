@tool
extends RefCounted
## Unit tests for settling the update folder at the next start, on scratch addon and update
## folders: one group per journal state and live folder, what a whole stage means, the one
## re-stage, and the keep_backup setting.

const Testing := preload("res://test/units/testing.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateApplier := preload("res://addons/godot_mcp_toolkit/self_update/update_applier.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const UpdateJournal := preload("res://addons/godot_mcp_toolkit/self_update/update_journal.gd")
const UpdateSettler := preload("res://addons/godot_mcp_toolkit/self_update/update_settler.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

const _RELEASE := {"core/a.gd": "new a", "core/b.gd": "new b"}
# An older update's backup, which no row may touch.
const _OLD_BACKUP := "backup-1.0.0"
const _KEEP_BACKUP := "mcp_toolkit/updates/keep_backup"
const _NOT_WHOLE := "the stage or its zip is not whole"


static func run(testing: Testing) -> void:
	_test_no_journal(testing)
	_test_unknown_state(testing)
	_test_applying_at_to(testing)
	_test_applying_writes_applied_first(testing)
	_test_applying_write_fails(testing)
	_test_applying_at_from_stage_whole(testing)
	_test_applying_at_from_stage_not_whole(testing)
	_test_applying_at_another_version(testing)
	_test_applying_missing(testing)
	_test_verified(testing)
	_test_staged_at_to_or_later(testing)
	_test_staged_older_whole(testing)
	_test_staged_older_postponed(testing)
	_test_pinned_journal(testing)
	_test_staged_older_not_whole(testing)
	_test_staged_missing(testing)
	_test_applied_at_to(testing)
	_test_applied_at_another_version(testing)
	_test_applied_missing(testing)
	_test_not_applied_zip_gone(testing)
	_test_not_applied_restages(testing)
	_test_not_applied_check_fails(testing)
	_test_not_applied_only_once(testing)
	_test_second_mismatch_clears(testing)
	_test_restage_fails(testing)
	_test_restage_write_fails(testing)
	_test_keep_backup_off(testing)
	_test_keep_backup_unreadable(testing)
	_test_keep_backup_off_failures(testing)


# A scenario's folders, absolute forms and the options pointing at them, with an older
# update's backup in the update folder.
static func _setup(purpose: String, installed_version: String) -> Dictionary:
	var scenario := UpdateFixtures.make_scenario(purpose, installed_version, {"core/a.gd": "old a"})
	_place_old_backup(scenario["updates_path"])
	return scenario


static func _place_old_backup(updates_path: String) -> void:
	FolderFiles.write_checked(updates_path.path_join(_OLD_BACKUP).path_join("a.gd"), "old".to_utf8_buffer())


# A release staged over 1.1.0, the live folder at `installed_version`, the journal in `state`.
static func _staged(purpose: String, state: String, installed_version: String = "1.1.0") -> Dictionary:
	var scenario := _setup(purpose, installed_version)
	UpdateFixtures.stage(scenario["updates"], "1.2.0", _RELEASE, "1.1.0", UpdateFixtures.key())
	_set_state(scenario, state)
	return scenario


# What a real swap leaves, the journal then set to `state`.
static func _swapped(purpose: String, state: String) -> Dictionary:
	var scenario := _staged(purpose, UpdateJournal.STAGED)
	UpdateApplier.apply_pending(scenario["options"])
	_set_state(scenario, state)
	return scenario


# What a stage mismatch at the exit leaves: no stage, the zip kept, a reason.
static func _mismatched(purpose: String, installed_version: String = "1.1.0") -> Dictionary:
	var scenario := _staged(purpose, UpdateJournal.NOT_APPLIED, installed_version)
	_mark_mismatched(scenario)
	return scenario


static func _mark_mismatched(scenario: Dictionary) -> void:
	FolderFiles.remove_tree(_stage_path(scenario))
	var journal := UpdateJournal.read(scenario["updates"])
	journal["state"] = UpdateJournal.NOT_APPLIED
	journal["reason"] = "the stage does not match the release"
	UpdateJournal.write(journal, scenario["updates"])


static func _set_state(scenario: Dictionary, state: String) -> void:
	var journal := UpdateJournal.read(scenario["updates"])
	journal["state"] = state
	UpdateJournal.write(journal, scenario["updates"])


static func _stage_path(scenario: Dictionary) -> String:
	return str(scenario["updates_path"]).path_join("stage")


# What a row leaves on disk: the journal's state, the stage, the zip's folder, the older
# backup and the live version. Read before the cleanup, compared after.
static func _left(scenario: Dictionary) -> Dictionary:
	return {
		"journal": UpdateJournal.read(scenario["updates"])["state"],
		"stage": UpdateFixtures.scenario_has_folder(scenario, "stage"),
		"zip": UpdateFixtures.scenario_has_folder(scenario, "1.2.0"),
		"backup": FileAccess.file_exists(str(scenario["updates_path"]).path_join(_OLD_BACKUP).path_join("a.gd")),
		"live": UpdateApplier.installed_version(scenario["addon_path"]),
	}


static func _left_as(journal: String, stage: bool, zip: bool, live: String) -> Dictionary:
	return {"journal": journal, "stage": stage, "zip": zip, "backup": true, "live": live}


static func _settle_quietly(options: Dictionary) -> Dictionary:
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var result := UpdateSettler.settle(options)
	Engine.print_error_messages = printed
	return result


# The ways a stage stops being whole. Each takes a scenario.
static func _stage_breaks() -> Dictionary:
	return {
		"a file missing": func(scenario: Dictionary) -> void:
			DirAccess.remove_absolute(_stage_path(scenario).path_join("core/b.gd")),
		"a file changed": func(scenario: Dictionary) -> void:
			FolderFiles.write_checked(_stage_path(scenario).path_join("core/a.gd"), "evil".to_utf8_buffer()),
		"a file added": func(scenario: Dictionary) -> void:
			FolderFiles.write_checked(_stage_path(scenario).path_join("extra.gd"), "evil".to_utf8_buffer()),
		"no stage at all": func(scenario: Dictionary) -> void:
			FolderFiles.remove_tree(_stage_path(scenario)),
		"the zip gone": func(scenario: Dictionary) -> void:
			FolderFiles.remove_tree(str(scenario["updates_path"]).path_join("1.2.0")),
	}


static func _test_no_journal(testing: Testing) -> void:
	testing.begin("Update settler: no journal, any live folder")
	var folder := UpdateFixtures.scratch("settle_none_vanished")
	var addon := UpdateFixtures.scratch("settle_none_addon")
	var vanished := UpdateSettler.settle({"addon_folder": addon, "update_folder": folder})
	var recreated := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder))
	testing.eq(vanished["report"], UpdateSettler.NOTHING, "no folder, no live folder → nothing to report")
	testing.ok(not recreated, "the folder is not made")

	var scenario := _staged("settle_none", UpdateJournal.STAGED)
	DirAccess.remove_absolute(str(scenario["updates_path"]).path_join("journal.json"))
	var result := UpdateSettler.settle(scenario["options"])
	var left := _left(scenario)
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result, {"report": "", "from": "", "to": "", "reason": "", "attempts": 0, "compatible_server": ""},
			"a folder with no journal → nothing to report")
	testing.eq(left, _left_as("", true, true, "1.1.0"), "and nothing touched")
	print("")


static func _test_unknown_state(testing: Testing) -> void:
	testing.begin("Update settler: a journal in a state this version does not know")
	var scenario := _staged("settle_unknown", UpdateJournal.STAGED)
	var path := str(scenario["updates_path"]).path_join("journal.json")
	var text := JSON.stringify({"format": 1, "state": "a_later_state", "from": "1.1.0", "to": "1.2.0"})
	FolderFiles.write_checked(path, text.to_utf8_buffer())
	var result := UpdateSettler.settle(scenario["options"])
	var kept_text := FileAccess.get_file_as_string(path)
	var left := _left(scenario)
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["report"], UpdateSettler.NOTHING, "reads as none → nothing to report")
	testing.eq(kept_text, text, "the journal stays as it was")
	testing.eq(left, _left_as("", true, true, "1.1.0"), "its stage and zip stay until the next staging")
	print("")


# A kill after the swap took the journal's last write.
static func _test_applying_at_to(testing: Testing) -> void:
	testing.begin("Update settler: applying, the live folder at to")
	var scenario := _swapped("settle_k3", UpdateJournal.APPLYING)
	var result := UpdateSettler.settle(scenario["options"])
	var left := _left(scenario)
	var swap_backup := UpdateFixtures.scenario_has_folder(scenario, "backup-1.1.0")
	var again := UpdateSettler.settle(scenario["options"])
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result, {"report": "updated", "from": "1.1.0", "to": "1.2.0", "reason": "", "attempts": 0,
			"compatible_server": "1.1.0"}, "reports the update, naming both versions")
	testing.eq(left, _left_as("", false, false, "1.2.0"), "the journal and the zip go")
	testing.ok(swap_backup, "the swap's backup stays")
	testing.eq(again["report"], UpdateSettler.NOTHING, "the next start reports nothing")
	print("")


# The journal's delete has to fail for the write before it to show. A held file blocks the
# delete on Windows, a read-only parent elsewhere, and neither stops an in-place write.
static func _test_applying_writes_applied_first(testing: Testing) -> void:
	testing.begin("Update settler: applying at to writes applied before it clears")
	var scenario := _swapped("settle_k3_blocked", UpdateJournal.APPLYING)
	var updates_path := str(scenario["updates_path"])
	var held: FileAccess = null
	if OS.get_name() == "Windows":
		held = FileAccess.open(updates_path.path_join("journal.json"), FileAccess.READ)
	else:
		UpdateFixtures.block_delete(updates_path, "journal.json", true)
	var result := _settle_quietly(scenario["options"])
	if held != null:
		held.close()
	else:
		UpdateFixtures.block_delete(updates_path, "journal.json", false)
	var state := str(UpdateJournal.read(scenario["updates"])["state"])
	var again := UpdateSettler.settle(scenario["options"])
	var left := _left(scenario)
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["report"], UpdateSettler.UPDATED, "reports the update")
	testing.eq(state, "applied", "a journal that will not delete says applied")
	testing.eq(again["report"], UpdateSettler.UPDATED, "the next start settles that row, and reports again")
	testing.eq(left, _left_as("", false, false, "1.2.0"), "and clears")
	print("")


static func _test_applying_write_fails(testing: Testing) -> void:
	testing.begin("Update settler: applying at to, and the journal cannot be written")
	var scenario := _swapped("settle_k3_read_only", UpdateJournal.APPLYING)
	var journal_path := str(scenario["updates_path"]).path_join("journal.json")
	UpdateFixtures.set_read_only(journal_path, true)
	var result := _settle_quietly(scenario["options"])
	UpdateFixtures.set_read_only(journal_path, false)
	var zip_gone := not UpdateFixtures.scenario_has_folder(scenario, "1.2.0")
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["report"], UpdateSettler.UPDATED, "the swap happened, so it still reports the update")
	testing.ok(zip_gone, "and still clears the zip")
	print("")


# A kill after the journal said applying, before anything moved.
static func _test_applying_at_from_stage_whole(testing: Testing) -> void:
	testing.begin("Update settler: applying, the live folder at from, the stage whole")
	var scenario := _staged("settle_k1", UpdateJournal.APPLYING)
	var result := UpdateSettler.settle(scenario["options"])
	var left := _left(scenario)
	var retried := UpdateApplier.apply_pending(scenario["options"])
	var live_after := UpdateApplier.installed_version(scenario["addon_path"])
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["report"], UpdateSettler.WAITING, "waits for the exit")
	testing.eq(left, _left_as("staged", true, true, "1.1.0"), "back to staged, everything kept")
	testing.eq(retried["state"], "applied", "the next exit retries and applies")
	testing.eq(live_after, "1.2.0", "the live folder is the release")
	print("")


static func _test_applying_at_from_stage_not_whole(testing: Testing) -> void:
	testing.begin("Update settler: applying, the live folder at from, the stage not whole")
	var scenario := _staged("settle_k1_torn", UpdateJournal.APPLYING)
	DirAccess.remove_absolute(_stage_path(scenario).path_join("core/b.gd"))
	var result := UpdateSettler.settle(scenario["options"])
	var left := _left(scenario)
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["report"], UpdateSettler.FAILED, "reports it")
	testing.eq(result["reason"], _NOT_WHOLE, "with the reason")
	testing.eq(left, _left_as("", false, false, "1.1.0"), "the journal and the stage go, the backup stays")
	print("")


static func _test_applying_at_another_version(testing: Testing) -> void:
	testing.begin("Update settler: applying, the live folder at another version")
	for installed: String in ["1.1.5", "1.3.0"]:
		var scenario := _staged("settle_hand_install_" + installed, UpdateJournal.APPLYING, installed)
		var result := UpdateSettler.settle(scenario["options"])
		var left := _left(scenario)
		UpdateFixtures.remove_scenario(scenario)
		testing.eq(result["report"], UpdateSettler.NOTHING, "%s by hand → nothing to report" % installed)
		testing.eq(left, _left_as("", false, false, installed), "%s by hand → journal and stage go, the backup stays" % installed)
	print("")


# A kill between the renames, and a failed undo. No toolkit runs from such a folder, so
# settling leaves it be.
static func _test_applying_missing(testing: Testing) -> void:
	testing.begin("Update settler: applying, the live folder missing")
	var scenario := _staged("settle_k2", UpdateJournal.APPLYING)
	var backup := str(scenario["updates_path"]).path_join("backup-1.1.0")
	DirAccess.rename_absolute(str(scenario["addon_path"]), backup)
	var result := UpdateSettler.settle(scenario["options"])
	var left := _left(scenario)
	var backup_whole := FileAccess.get_file_as_string(backup.path_join("core/a.gd")) == "old a"
	var stage_whole := FileAccess.get_file_as_string(_stage_path(scenario).path_join("core/a.gd")) == "new a"
	var live_made := DirAccess.dir_exists_absolute(str(scenario["addon_path"]))
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["report"], UpdateSettler.NOTHING, "nothing to report")
	testing.eq(left, _left_as("applying", true, true, ""), "nothing touched")
	testing.ok(backup_whole, "the backup is whole")
	testing.ok(stage_whole, "the stage is whole")
	testing.ok(not live_made, "the live folder is not made")

	var undo_failed := _staged("settle_undo_failed", UpdateJournal.APPLYING)
	FolderFiles.remove_tree(str(undo_failed["addon_path"]))
	FolderFiles.write_checked(str(undo_failed["addon_path"]).path_join("in_the_way.gd"), "held".to_utf8_buffer())
	var undo_result := UpdateSettler.settle(undo_failed["options"])
	var undo_left := _left(undo_failed)
	UpdateFixtures.remove_scenario(undo_failed)
	testing.eq(undo_result["report"], UpdateSettler.NOTHING, "a folder with no plugin.cfg counts as missing")
	testing.eq(undo_left, _left_as("applying", true, true, ""), "and nothing is touched")
	print("")


static func _test_verified(testing: Testing) -> void:
	testing.begin("Update settler: verified, any live folder")
	for installed: String in ["1.1.0", "1.2.0"]:
		var scenario := _staged("settle_verified_" + installed, UpdateJournal.VERIFIED, installed)
		var result := UpdateSettler.settle(scenario["options"])
		var left := _left(scenario)
		UpdateFixtures.remove_scenario(scenario)
		testing.eq(result["report"], UpdateSettler.NOTHING, "at %s → nothing to report, the offer returns" % installed)
		testing.eq(left, _left_as("", false, false, installed), "at %s → journal and stage go, the backup stays" % installed)
	print("")


static func _test_staged_at_to_or_later(testing: Testing) -> void:
	testing.begin("Update settler: staged, the live folder at to or later")
	for installed: String in ["1.2.0", "1.3.0"]:
		var scenario := _staged("settle_pulled_" + installed, UpdateJournal.STAGED, installed)
		var result := UpdateSettler.settle(scenario["options"])
		var left := _left(scenario)
		UpdateFixtures.remove_scenario(scenario)
		testing.eq(result["report"], UpdateSettler.NOTHING, "%s → cleared quietly" % installed)
		testing.eq(left, _left_as("", false, false, installed), "%s → journal and stage go, the backup stays" % installed)
	print("")


static func _test_staged_older_whole(testing: Testing) -> void:
	testing.begin("Update settler: staged, the live folder older, the stage whole")
	var scenario := _staged("settle_waiting", UpdateJournal.STAGED)
	var result := UpdateSettler.settle(scenario["options"])
	var left := _left(scenario)
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["report"], UpdateSettler.WAITING, "waits for the exit")
	testing.eq(result["reason"], "", "no attempt yet → no reason")
	testing.eq(left, _left_as("staged", true, true, "1.1.0"), "everything stays")
	print("")


static func _test_staged_older_postponed(testing: Testing) -> void:
	testing.begin("Update settler: staged and waiting, after an exit postponed it")
	var scenario := _staged("settle_postponed", UpdateJournal.STAGED)
	var journal := UpdateJournal.read(scenario["updates"])
	journal["reason"] = "a stale reason"
	UpdateJournal.write(journal, scenario["updates"])
	var no_attempts := UpdateSettler.settle(scenario["options"])
	journal["attempts"] = 3
	journal["reason"] = "a held file"
	UpdateJournal.write(journal, scenario["updates"])
	var result := UpdateSettler.settle(scenario["options"])
	var state := str(UpdateJournal.read(scenario["updates"])["state"])
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(no_attempts["reason"], "", "a reason with no attempts → not returned")
	testing.eq(result["report"], UpdateSettler.WAITING, "attempts above zero → still waits")
	testing.eq(result["reason"], "a held file", "and returns the reason")
	testing.eq(result["attempts"], 3, "and the attempts")
	testing.eq(state, "staged", "the journal stays staged")
	print("")


# 1.2.0's own journal, read by whatever settles it.
static func _test_pinned_journal(testing: Testing) -> void:
	testing.begin("Update settler: the journal 1.2.0 writes, waiting for the exit")
	var scenario := _staged("settle_pinned", UpdateJournal.STAGED)
	var path := str(scenario["updates_path"]).path_join("journal.json")
	FolderFiles.write_checked(path, UpdateFixtures.PINNED_1_2_0_JOURNAL.to_utf8_buffer())
	var result := UpdateSettler.settle(scenario["options"])
	var left := _left(scenario)
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result, {"report": "waiting", "from": "1.1.0", "to": "1.2.0", "reason": "a held file", "attempts": 2,
			"compatible_server": "1.1.0"}, "the wait is reported with its reason, attempts and versions")
	testing.eq(left, _left_as("staged", true, true, "1.1.0"), "everything stays")
	print("")


static func _test_staged_older_not_whole(testing: Testing) -> void:
	testing.begin("Update settler: staged, the live folder older, the stage not whole")
	var breaks := _stage_breaks()
	var index := 0
	for label: String in breaks:
		var scenario := _staged("settle_torn_%d" % index, UpdateJournal.STAGED)
		index += 1
		var change: Callable = breaks[label]
		change.call(scenario)
		var result := UpdateSettler.settle(scenario["options"])
		var left := _left(scenario)
		UpdateFixtures.remove_scenario(scenario)
		testing.eq(result["report"], UpdateSettler.FAILED, "%s → reported" % label)
		testing.eq(result["reason"], _NOT_WHOLE, "%s → with the reason" % label)
		testing.eq(left, _left_as("", false, false, "1.1.0"), "%s → journal and stage go, the backup stays" % label)
	print("")


# With no live version to compare, no rule applies, so nothing moves.
static func _test_staged_missing(testing: Testing) -> void:
	testing.begin("Update settler: staged, the live folder missing")
	var scenario := _staged("settle_staged_missing", UpdateJournal.STAGED)
	FolderFiles.remove_tree(str(scenario["addon_path"]))
	var result := UpdateSettler.settle(scenario["options"])
	var left := _left(scenario)
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["report"], UpdateSettler.NOTHING, "nothing to report")
	testing.eq(left, _left_as("staged", true, true, ""), "nothing touched")
	print("")


static func _test_applied_at_to(testing: Testing) -> void:
	testing.begin("Update settler: applied, the live folder at to")
	var scenario := _swapped("settle_applied", UpdateJournal.APPLIED)
	var result := UpdateSettler.settle(scenario["options"])
	var left := _left(scenario)
	var swap_backup := UpdateFixtures.scenario_has_folder(scenario, "backup-1.1.0")
	var logged := FileAccess.get_file_as_string(UpdateFolder.log_path(scenario["updates"]))
	var again := UpdateSettler.settle(scenario["options"])
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result, {"report": "updated", "from": "1.1.0", "to": "1.2.0", "reason": "", "attempts": 0,
			"compatible_server": "1.1.0"}, "reports the update, naming both versions")
	testing.eq(left, _left_as("", false, false, "1.2.0"), "the journal and the zip go")
	testing.ok(swap_backup, "the swap's backup stays")
	testing.ok(logged.contains("settle 1.2.0: updated over 1.1.0"), "the install log says so")
	testing.eq(again["report"], UpdateSettler.NOTHING, "only once: the next start reports nothing")
	print("")


static func _test_applied_at_another_version(testing: Testing) -> void:
	testing.begin("Update settler: applied, the live folder at another version")
	var scenario := _staged("settle_applied_other", UpdateJournal.APPLIED)
	var result := UpdateSettler.settle(scenario["options"])
	var left := _left(scenario)
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["report"], UpdateSettler.FAILED, "reported as not installed")
	testing.eq(result["reason"], "the editor started version 1.1.0", "naming the version it started")
	testing.eq(left, _left_as("", false, false, "1.1.0"), "the journal goes, the backup stays")
	print("")


static func _test_applied_missing(testing: Testing) -> void:
	testing.begin("Update settler: applied, the live folder missing")
	var scenario := _staged("settle_applied_missing", UpdateJournal.APPLIED)
	FolderFiles.remove_tree(str(scenario["addon_path"]))
	var result := UpdateSettler.settle(scenario["options"])
	var left := _left(scenario)
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["report"], UpdateSettler.NOTHING, "nothing to report")
	testing.eq(left, _left_as("applied", true, true, ""), "nothing touched")
	print("")


static func _test_not_applied_zip_gone(testing: Testing) -> void:
	testing.begin("Update settler: not applied, the zip gone")
	var scenario := _mismatched("settle_no_zip")
	FolderFiles.remove_tree(str(scenario["updates_path"]).path_join("1.2.0"))
	var result := UpdateSettler.settle(scenario["options"])
	var left := _left(scenario)
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["report"], UpdateSettler.FAILED, "reported")
	testing.eq(result["reason"], "the stage does not match the release", "with the journal's reason")
	testing.eq(left, _left_as("", false, false, "1.1.0"), "the journal goes, the backup stays")
	print("")


static func _test_not_applied_restages(testing: Testing) -> void:
	testing.begin("Update settler: not applied, the zip there: the one re-stage")
	var scenario := _mismatched("settle_restage")
	var journal := UpdateJournal.read(scenario["updates"])
	journal["attempts"] = 2
	UpdateJournal.write(journal, scenario["updates"])
	var result := UpdateSettler.settle(scenario["options"])
	var after := UpdateJournal.read(scenario["updates"])
	var stage_a := FileAccess.get_file_as_string(_stage_path(scenario).path_join("core/a.gd"))
	var backup_gone := not UpdateFixtures.scenario_has_folder(scenario, _OLD_BACKUP)
	var zip_kept := UpdateFixtures.scenario_has_folder(scenario, "1.2.0")
	var applied := UpdateApplier.apply_pending(scenario["options"])
	var live_after := UpdateApplier.installed_version(scenario["addon_path"])
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["report"], UpdateSettler.WAITING, "the stage waits for the exit")
	testing.eq(result["reason"], "", "with nothing to show")
	testing.eq(after["state"], "staged", "the journal says staged")
	testing.eq(after.get("restaged", false), true, "and marks the re-stage")
	testing.eq(after["reason"], "", "the old reason goes")
	testing.eq(after["attempts"], 0, "and the old attempts")
	testing.eq(stage_a, "new a", "the stage is back from the zip")
	testing.ok(zip_kept, "the zip stays for the exit's check")
	testing.ok(backup_gone, "staging took the older backup, as any staging does")
	testing.eq(applied["state"], "applied", "the next exit applies it")
	testing.eq(live_after, "1.2.0", "the live folder is the release")
	print("")


# The whole check runs against the live folder, and its failure costs no backup.
static func _test_not_applied_check_fails(testing: Testing) -> void:
	testing.begin("Update settler: not applied, the zip there, a check that fails")
	var files := {"core/a.gd": "new a"}
	var cases := [
		["an untrusted signature", "1.1.0", "the update's signature does not verify",
				func(updates: String) -> void: UpdateFixtures.stage(updates, "1.2.0", files, "1.1.0", UpdateFixtures.other_key())],
		["a Godot floor above the engine", "1.1.0", "version 1.2.0 needs Godot 4.9 or newer",
				func(updates: String) -> void: UpdateFixtures.stage(updates, "1.2.0", files, "1.1.0", UpdateFixtures.key(), UpdateJournal.STAGED, "4.9")],
		["a zip changed after staging", "1.1.0", "the staged archive does not match its manifest",
				func(updates: String) -> void: UpdateFixtures.stage_tampered(updates, "1.2.0", files, "1.1.0", UpdateFixtures.key())],
		["a layout this version cannot read", "1.1.0", "the archive holds a project.godot: addons/godot_mcp_toolkit/project.godot",
				func(updates: String) -> void: UpdateFixtures.stage(updates, "1.2.0", {"project.godot": "x"}, "1.1.0", UpdateFixtures.key())],
		["the live folder pulled up to the release", "1.2.0", "version 1.2.0 is not newer than the installed 1.2.0",
				func(updates: String) -> void: UpdateFixtures.stage(updates, "1.2.0", files, "1.1.0", UpdateFixtures.key())],
	]
	var index := 0
	for test_case: Array in cases:
		var label := str(test_case[0])
		var installed := str(test_case[1])
		var scenario := _setup("settle_check_%d" % index, installed)
		index += 1
		var prepare: Callable = test_case[3]
		prepare.call(scenario["updates"])
		_mark_mismatched(scenario)
		var result := UpdateSettler.settle(scenario["options"])
		var left := _left(scenario)
		UpdateFixtures.remove_scenario(scenario)
		testing.eq(result["report"], UpdateSettler.FAILED, "%s → reported" % label)
		testing.eq(result["reason"], str(test_case[2]), "%s → with the check's reason" % label)
		testing.eq(left, _left_as("", false, false, installed), "%s → no re-stage, cleared, the backup stays" % label)

	var guarded := _mismatched("settle_check_guard")
	var guarded_options: Dictionary = guarded["options"]
	guarded_options["guard_facts"] = {"headless": true}
	var guarded_result := UpdateSettler.settle(guarded_options)
	var guarded_left := _left(guarded)
	UpdateFixtures.remove_scenario(guarded)
	testing.eq(guarded_result["reason"], "A headless editor never installs updates.", "a guard → with its sentence")
	testing.eq(guarded_left, _left_as("", false, false, "1.1.0"), "a guard → no re-stage, cleared, the backup stays")
	print("")


static func _test_not_applied_only_once(testing: Testing) -> void:
	testing.begin("Update settler: not applied, the zip there, the re-stage already used")
	var scenario := _mismatched("settle_once")
	var journal := UpdateJournal.read(scenario["updates"])
	journal["restaged"] = true
	UpdateJournal.write(journal, scenario["updates"])
	var result := UpdateSettler.settle(scenario["options"])
	var left := _left(scenario)
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["report"], UpdateSettler.FAILED, "reported")
	testing.eq(result["reason"], "the stage does not match the release", "with the journal's reason")
	testing.eq(left, _left_as("", false, false, "1.1.0"), "no second re-stage, cleared, the backup stays")
	print("")


# The whole path through the real applier: mismatch, re-stage, mismatch, clear.
static func _test_second_mismatch_clears(testing: Testing) -> void:
	testing.begin("Update settler: a second mismatch clears")
	var scenario := _staged("settle_second", UpdateJournal.STAGED)
	var stage_a := _stage_path(scenario).path_join("core/a.gd")
	FolderFiles.write_checked(stage_a, "evil".to_utf8_buffer())
	var first_exit := UpdateApplier.apply_pending(scenario["options"])
	var first_start := UpdateSettler.settle(scenario["options"])
	_place_old_backup(scenario["updates_path"])
	FolderFiles.write_checked(stage_a, "evil".to_utf8_buffer())
	var second_exit := UpdateApplier.apply_pending(scenario["options"])
	var second_start := UpdateSettler.settle(scenario["options"])
	var left := _left(scenario)
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(first_exit["state"], "not_applied", "the first mismatch → not applied")
	testing.eq(first_start["report"], UpdateSettler.WAITING, "the next start re-stages")
	testing.eq(second_exit["state"], "not_applied", "the second mismatch → not applied")
	testing.eq(second_start["report"], UpdateSettler.FAILED, "the next start reports")
	testing.eq(second_start["reason"], "the stage does not match the release", "with the mismatch")
	testing.eq(left, _left_as("", false, false, "1.1.0"), "no stage comes back, the backup stays")
	print("")


# A file where the stage goes stops every write under it, and clearing leaves a file alone.
static func _test_restage_fails(testing: Testing) -> void:
	testing.begin("Update settler: the re-stage itself fails")
	var scenario := _mismatched("settle_restage_fails")
	FolderFiles.write_checked(_stage_path(scenario), "in the way".to_utf8_buffer())
	var result := _settle_quietly(scenario["options"])
	DirAccess.remove_absolute(_stage_path(scenario))
	var left := _left(scenario)
	var again := _settle_quietly(scenario["options"])
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["report"], UpdateSettler.FAILED, "reported")
	testing.ok(str(result["reason"]).begins_with("could not write "), "with the stepper's reason")
	testing.eq(left["journal"], "", "the journal goes")
	testing.ok(not left["zip"], "the zip goes")
	testing.eq(again["report"], UpdateSettler.NOTHING, "and no later start tries again")
	print("")


# A read-only file stops the write on every platform; on Windows it stops the delete too.
static func _test_restage_write_fails(testing: Testing) -> void:
	testing.begin("Update settler: the re-stage's journal write fails")
	var scenario := _mismatched("settle_restage_write")
	var journal_path := str(scenario["updates_path"]).path_join("journal.json")
	UpdateFixtures.set_read_only(journal_path, true)
	var result := _settle_quietly(scenario["options"])
	var stage_gone := not UpdateFixtures.scenario_has_folder(scenario, "stage")
	var zip_gone := not UpdateFixtures.scenario_has_folder(scenario, "1.2.0")
	UpdateFixtures.set_read_only(journal_path, false)
	UpdateSettler.settle(scenario["options"])
	var left := _left(scenario)
	UpdateFixtures.remove_scenario(scenario)
	testing.eq(result["report"], UpdateSettler.FAILED, "reported")
	testing.eq(result["reason"], "could not write the journal", "with the reason")
	testing.ok(stage_gone and zip_gone, "the stage and the zip go, so nothing re-stages")
	testing.eq(left["journal"], "", "the journal is gone by the next start")
	testing.ok(not left["stage"], "and no stage came back")
	print("")


static func _with_keep_backup(value: Variant, settle_options: Dictionary) -> Dictionary:
	var had := ProjectSettings.has_setting(_KEEP_BACKUP)
	var before: Variant = ProjectSettings.get_setting(_KEEP_BACKUP) if had else null
	ProjectSettings.set_setting(_KEEP_BACKUP, value)
	var result := _settle_quietly(settle_options)
	ProjectSettings.set_setting(_KEEP_BACKUP, before)
	return result


static func _test_keep_backup_off(testing: Testing) -> void:
	testing.begin("Update settler: keep_backup off, after a success")
	testing.eq(UpdateSettler.KEEP_BACKUP_SETTING, _KEEP_BACKUP, "the setting's name")
	var applied := _swapped("settle_keep_off", UpdateJournal.APPLIED)
	var applied_result := _with_keep_backup(false, applied["options"])
	var applied_gone := not DirAccess.dir_exists_absolute(str(applied["updates_path"]))
	var applied_live := UpdateApplier.installed_version(applied["addon_path"])
	UpdateFixtures.remove_scenario(applied)
	testing.eq(applied_result["report"], UpdateSettler.UPDATED, "applied at to → reported first")
	testing.ok(applied_gone, "applied at to → the whole folder goes, nothing makes it again")
	testing.eq(applied_live, "1.2.0", "the live folder stays")

	var interrupted := _swapped("settle_keep_off_k3", UpdateJournal.APPLYING)
	var interrupted_result := _with_keep_backup(false, interrupted["options"])
	var interrupted_gone := not DirAccess.dir_exists_absolute(str(interrupted["updates_path"]))
	UpdateFixtures.remove_scenario(interrupted)
	testing.eq(interrupted_result["report"], UpdateSettler.UPDATED, "applying at to → reported first")
	testing.ok(interrupted_gone, "applying at to → the whole folder goes")
	print("")


static func _test_keep_backup_unreadable(testing: Testing) -> void:
	testing.begin("Update settler: keep_backup on, or not a boolean")
	for value: Variant in [true, "false", 0]:
		var scenario := _swapped("settle_keep_%s" % str(value), UpdateJournal.APPLIED)
		_with_keep_backup(value, scenario["options"])
		var swap_backup := UpdateFixtures.scenario_has_folder(scenario, "backup-1.1.0")
		UpdateFixtures.remove_scenario(scenario)
		testing.ok(swap_backup, "%s → the backup stays" % var_to_str(value))
	print("")


# A failure keeps the folder whatever the setting says.
static func _test_keep_backup_off_failures(testing: Testing) -> void:
	testing.begin("Update settler: keep_backup off, after a failure")
	var other := _staged("settle_keep_off_other", UpdateJournal.APPLIED)
	_with_keep_backup(false, other["options"])
	var other_left := _left(other)
	UpdateFixtures.remove_scenario(other)
	testing.eq(other_left, _left_as("", false, false, "1.1.0"), "applied at another version → the backup stays")

	var torn := _staged("settle_keep_off_torn", UpdateJournal.STAGED)
	DirAccess.remove_absolute(_stage_path(torn).path_join("core/b.gd"))
	_with_keep_backup(false, torn["options"])
	var torn_left := _left(torn)
	UpdateFixtures.remove_scenario(torn)
	testing.eq(torn_left, _left_as("", false, false, "1.1.0"), "a stage not whole → the backup stays")

	var refused := _mismatched("settle_keep_off_refused", "1.2.0")
	_with_keep_backup(false, refused["options"])
	var refused_left := _left(refused)
	UpdateFixtures.remove_scenario(refused)
	testing.eq(refused_left, _left_as("", false, false, "1.2.0"), "a failed check → the backup stays")
	print("")
