@tool
extends RefCounted
## Unit tests for the stage stepper, on zips built in the run: the budget, what begin wipes
## and refuses, each entry held to the list, cancel, the applier taking what it wrote, and
## a release the size of this addon, whose longest steps it prints.

const Testing := preload("res://test/units/testing.gd")
const StageStepper := preload("res://addons/godot_mcp_toolkit/self_update/stage_stepper.gd")
const UpdateApplier := preload("res://addons/godot_mcp_toolkit/self_update/update_applier.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const UpdateJournal := preload("res://addons/godot_mcp_toolkit/self_update/update_journal.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const ReleaseFileList := preload("res://addons/godot_mcp_toolkit/self_update/release_file_list.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

const _VERSION := "1.2.0"
const _ADDON_ENTRY := "addons/godot_mcp_toolkit/"
# An empty file is the case a release really ships, in CompanionSkills.
const _FILES := {"core/a.gd": "new a", "core/b.gd": "new b", "CompanionSkills/.gdignore": ""}
const _FILE_COUNT := 5
# Far more steps than any zip here needs, so a stepper that never ends fails the case.
const _MAX_STEPS := 100000
# A budget no case here can spend: the whole run in one call.
const _WHOLE_RUN_MS := 600000


static func run(testing: Testing) -> void:
	_test_one_entry_per_empty_budget(testing)
	_test_budget(testing)
	_test_before_begin(testing)
	_test_ignore_files(testing)
	_test_old_stage(testing)
	_test_backups(testing)
	_test_refused_zips(testing)
	_test_entry_held_to_list(testing)
	_test_unreadable_entry(testing)
	_test_entry_that_cannot_be_written(testing)
	_test_cancel(testing)
	_test_begin_again(testing)
	_test_applier_takes_the_stage(testing)
	_test_release_sized(testing)


static func _write_release(folder: String, entries: Dictionary) -> void:
	var archive := UpdateFolder.version_folder(_VERSION, folder).path_join(ReleaseAssets.archive_name(_VERSION))
	UpdateFixtures.write_zip(archive, entries)


static func _stage_path(folder: String) -> String:
	return ProjectSettings.globalize_path(folder).path_join("stage")


static func _begin_quietly(stepper: StageStepper, folder: String) -> Dictionary:
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var outcome := stepper.begin(_VERSION, folder)
	Engine.print_error_messages = printed
	return outcome


static func _advance_quietly(stepper: StageStepper) -> Dictionary:
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var outcome := stepper.advance(_WHOLE_RUN_MS)
	Engine.print_error_messages = printed
	return outcome


static func _test_one_entry_per_empty_budget(testing: Testing) -> void:
	testing.begin("Stage stepper: an empty budget writes one entry a step")
	var folder := UpdateFixtures.scratch("stepper_steps")
	_write_release(folder, UpdateFixtures.release_entries(_VERSION, _FILES))
	var stepper := StageStepper.new()
	var begun := stepper.begin(_VERSION, folder)
	var stage_after_begin := DirAccess.dir_exists_absolute(_stage_path(folder))
	var last := begun
	var steps := 0
	while last["state"] == StageStepper.RUNNING and steps < _MAX_STEPS:
		last = stepper.advance(0)
		steps += 1
	var a := FileAccess.get_file_as_string(_stage_path(folder).path_join("core/a.gd"))
	var gdignore_there := FileAccess.file_exists(_stage_path(folder).path_join("CompanionSkills/.gdignore"))
	var plugin_config := FileAccess.get_file_as_string(_stage_path(folder).path_join("plugin.cfg"))
	var list := FileAccess.get_file_as_string(_stage_path(folder).path_join(ReleaseFileList.FILE_NAME))
	var files := FolderFiles.list(_stage_path(folder))
	UpdateFixtures.remove(folder)
	testing.eq(begun, {"state": "running", "reason": "", "written": 0, "total": _FILE_COUNT},
			"begin → running, nothing written, every file counted")
	testing.ok(not stage_after_begin, "begin writes no entry")
	testing.eq(steps, _FILE_COUNT, "one step per file")
	testing.eq(a, "new a", "a file → its bytes")
	testing.ok(gdignore_there, "an empty file → written")
	testing.eq(plugin_config, UpdateFixtures.plugin_config(_VERSION), "plugin.cfg → written")
	testing.eq(list, str(UpdateFixtures.release_entries(_VERSION, _FILES)[_ADDON_ENTRY + ReleaseFileList.FILE_NAME]),
			"the list → written with its own bytes")
	testing.eq(files.size(), _FILE_COUNT, "nothing else in the stage")
	testing.eq(last, {"state": "done", "reason": "", "written": _FILE_COUNT, "total": _FILE_COUNT},
			"the last step → done, every file written")
	print("")


static func _test_budget(testing: Testing) -> void:
	testing.begin("Stage stepper: the budget")
	testing.eq(StageStepper.BUDGET_MS, 8, "8 ms by default")
	var folder := UpdateFixtures.scratch("stepper_budget")
	_write_release(folder, UpdateFixtures.release_entries(_VERSION, _FILES))
	var one_step := StageStepper.new()
	one_step.begin(_VERSION, folder)
	var whole := one_step.advance(_WHOLE_RUN_MS)
	var counted := StageStepper.new()
	counted.begin(_VERSION, folder)
	var first := counted.advance(0)
	var second := counted.advance(0)
	UpdateFixtures.remove(folder)
	testing.eq(whole["state"], "done", "a budget that never runs out → the whole run in one step")
	testing.eq(whole["written"], _FILE_COUNT, "… with every file written")
	testing.eq(first["written"], 1, "a budget of nothing → still one entry")
	testing.eq(second["written"], 2, "each step → one more")
	testing.eq(second["state"], "running", "entries left → running")
	print("")


static func _test_before_begin(testing: Testing) -> void:
	testing.begin("Stage stepper: before begin")
	var stepper := StageStepper.new()
	testing.eq(stepper.advance(), {"state": "idle", "reason": "", "written": 0, "total": 0}, "advance → idle, nothing done")
	testing.ok(stepper.cancel(), "cancel → nothing to do")
	print("")


static func _test_ignore_files(testing: Testing) -> void:
	testing.begin("Stage stepper: the update folder's ignore files")
	var folder := UpdateFixtures.scratch("stepper_ignore")
	_write_release(folder, UpdateFixtures.release_entries(_VERSION, _FILES))
	var written := StageStepper.new().begin(_VERSION, folder)
	var gitignore := FileAccess.get_file_as_string(ProjectSettings.globalize_path(folder).path_join(".gitignore"))
	UpdateFixtures.remove(folder)
	testing.eq(written["state"], "running", "missing → written, and the run starts")
	testing.eq(gitignore, "*\n", "missing → .gitignore ignores everything")

	var blocked := UpdateFixtures.scratch("stepper_ignore_blocked")
	_write_release(blocked, UpdateFixtures.release_entries(_VERSION, _FILES))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(blocked).path_join(".gitignore"))
	var refused := _begin_quietly(StageStepper.new(), blocked)
	UpdateFixtures.remove(blocked)
	testing.eq(refused, {"state": "failed", "reason": "could not write the update folder's ignore files", "written": 0, "total": 0},
			"one that cannot be written → refused")
	print("")


static func _test_old_stage(testing: Testing) -> void:
	testing.begin("Stage stepper: begin wipes the stage first")
	var folder := UpdateFixtures.scratch("stepper_old_stage")
	_write_release(folder, UpdateFixtures.release_entries(_VERSION, _FILES))
	var stage := _stage_path(folder)
	FolderFiles.write_checked(stage.path_join("old/stale.gd"), "stale".to_utf8_buffer())
	var stepper := StageStepper.new()
	stepper.begin(_VERSION, folder)
	var stale_after_begin := FileAccess.file_exists(stage.path_join("old/stale.gd"))
	stepper.advance(_WHOLE_RUN_MS)
	var files := FolderFiles.list(stage)
	UpdateFixtures.remove(folder)
	testing.ok(not stale_after_begin, "a file of an earlier run → gone")
	testing.ok(not files.has("old/stale.gd"), "… and not back after the run")

	var held := UpdateFixtures.scratch("stepper_stage_held")
	_write_release(held, UpdateFixtures.release_entries(_VERSION, _FILES))
	var held_stage := _stage_path(held)
	FolderFiles.write_checked(held_stage.path_join("stale.gd"), "stale".to_utf8_buffer())
	UpdateFixtures.block_delete(held_stage, "stale.gd", true)
	var refused := _begin_quietly(StageStepper.new(), held)
	var kept := FileAccess.file_exists(held_stage.path_join("stale.gd"))
	UpdateFixtures.block_delete(held_stage, "stale.gd", false)
	UpdateFixtures.remove(held)
	testing.eq(refused, {"state": "failed", "reason": "could not delete the old stage", "written": 0, "total": 0},
			"a stage that will not go → refused")
	testing.ok(kept, "… with its file still there")
	print("")


static func _test_backups(testing: Testing) -> void:
	testing.begin("Stage stepper: begin deletes every update backup")
	var folder := UpdateFixtures.scratch("stepper_backups")
	var absolute := ProjectSettings.globalize_path(folder)
	_write_release(folder, UpdateFixtures.release_entries(_VERSION, _FILES))
	FolderFiles.write_checked(absolute.path_join("backup-1.0.0/a.gd"), "a".to_utf8_buffer())
	FolderFiles.write_checked(absolute.path_join("backup-1.1.0/core/a.gd"), "a".to_utf8_buffer())
	var outcome := StageStepper.new().begin(_VERSION, folder)
	var first_gone := not DirAccess.dir_exists_absolute(absolute.path_join("backup-1.0.0"))
	var second_gone := not DirAccess.dir_exists_absolute(absolute.path_join("backup-1.1.0"))
	UpdateFixtures.remove(folder)
	testing.eq(outcome["state"], "running", "the run starts")
	testing.ok(first_gone and second_gone, "every backup-* → gone")

	var held := UpdateFixtures.scratch("stepper_backup_held")
	var backup := ProjectSettings.globalize_path(held).path_join("backup-1.1.0")
	_write_release(held, UpdateFixtures.release_entries(_VERSION, _FILES))
	FolderFiles.write_checked(backup.path_join("a.gd"), "a".to_utf8_buffer())
	UpdateFixtures.block_delete(backup, "a.gd", true)
	var refused := _begin_quietly(StageStepper.new(), held)
	UpdateFixtures.block_delete(backup, "a.gd", false)
	UpdateFixtures.remove(held)
	testing.eq(refused, {"state": "failed", "reason": "could not delete an old update backup", "written": 0, "total": 0},
			"a backup that will not go → refused")

	var bad_zip := UpdateFixtures.scratch("stepper_backup_bad_zip")
	var kept_backup := ProjectSettings.globalize_path(bad_zip).path_join("backup-1.1.0")
	var entries := UpdateFixtures.release_entries(_VERSION, _FILES)
	entries.erase(_ADDON_ENTRY + ReleaseFileList.FILE_NAME)
	_write_release(bad_zip, entries)
	FolderFiles.write_checked(kept_backup.path_join("a.gd"), "a".to_utf8_buffer())
	var not_staged := StageStepper.new().begin(_VERSION, bad_zip)
	var backup_kept := FileAccess.file_exists(kept_backup.path_join("a.gd"))
	UpdateFixtures.remove(bad_zip)
	testing.eq(not_staged["state"], "failed", "a zip that will not stage → refused")
	testing.ok(backup_kept, "… and it costs no backup")
	print("")


static func _test_refused_zips(testing: Testing) -> void:
	testing.begin("Stage stepper: a zip that is refused before anything is written")
	var missing := UpdateFixtures.scratch("stepper_zip_missing")
	testing.eq(StageStepper.new().begin(_VERSION, missing)["reason"], "the update's zip is missing", "no zip → refused")
	UpdateFixtures.remove(missing)

	var not_zip := UpdateFixtures.scratch("stepper_zip_not_zip")
	var archive := ProjectSettings.globalize_path(UpdateFolder.version_folder(_VERSION, not_zip)).path_join(ReleaseAssets.archive_name(_VERSION))
	FolderFiles.write_checked(archive, "not a zip".to_utf8_buffer())
	var not_zip_outcome := _begin_quietly(StageStepper.new(), not_zip)
	UpdateFixtures.remove(not_zip)
	testing.eq(not_zip_outcome["reason"], "the archive is not a readable zip", "a file that is not a zip → refused")

	var no_list := UpdateFixtures.release_entries(_VERSION, _FILES)
	no_list.erase(_ADDON_ENTRY + ReleaseFileList.FILE_NAME)
	var damaged_list := UpdateFixtures.release_entries(_VERSION, _FILES)
	damaged_list[_ADDON_ENTRY + ReleaseFileList.FILE_NAME] = "not a list\n"
	var unlisted := UpdateFixtures.release_entries(_VERSION, _FILES)
	unlisted[_ADDON_ENTRY + "extra.gd"] = "extra"
	var other_version := UpdateFixtures.release_entries("1.2.1", _FILES)
	var cases := {
		"a zip with no list": [no_list, "the staged archive has no file list this version can read"],
		"a damaged list": [damaged_list, "the staged archive has no file list this version can read"],
		"a file the list does not name": [unlisted, "the archive holds extra.gd, which its file list does not name"],
		"another version": [other_version, "the archive's plugin.cfg names version 1.2.1, not 1.2.0"],
	}
	var index := 0
	for label: String in cases:
		var case_values: Array = cases[label]
		var folder := UpdateFixtures.scratch("stepper_zip_%d" % index)
		index += 1
		_write_release(folder, case_values[0])
		var outcome := StageStepper.new().begin(_VERSION, folder)
		var stage_made := DirAccess.dir_exists_absolute(_stage_path(folder))
		UpdateFixtures.remove(folder)
		testing.eq(outcome, {"state": "failed", "reason": case_values[1], "written": 0, "total": 0}, "%s → refused" % label)
		testing.ok(not stage_made, "%s → no stage" % label)
	print("")


static func _test_entry_held_to_list(testing: Testing) -> void:
	testing.begin("Stage stepper: an entry that does not match the list")
	var folder := UpdateFixtures.scratch("stepper_entry_changed")
	var entries := UpdateFixtures.release_entries(_VERSION, _FILES)
	entries[_ADDON_ENTRY + "core/b.gd"] = "changed after the list was made"
	_write_release(folder, entries)
	var stepper := StageStepper.new()
	stepper.begin(_VERSION, folder)
	var outcome := stepper.advance(_WHOLE_RUN_MS)
	var stage_left := DirAccess.dir_exists_absolute(_stage_path(folder))
	var after := stepper.advance(_WHOLE_RUN_MS)
	UpdateFixtures.remove(folder)
	testing.eq(outcome["state"], "failed", "→ failed")
	testing.eq(outcome["reason"], "the archive's core/b.gd does not match its file list", "the reason names the entry")
	testing.ok(not stage_left, "what the run wrote → gone")
	testing.eq(after, outcome, "a later step → the same result")
	print("")


# The stored bytes of one entry overwritten in the zip: the read fails or yields other
# bytes, whichever this engine does, and neither reaches the stage.
static func _test_unreadable_entry(testing: Testing) -> void:
	testing.begin("Stage stepper: an entry that does not read")
	var folder := UpdateFixtures.scratch("stepper_entry_unreadable")
	var files := {"core/big.gd": "not much like the rest of it ".repeat(200)}
	_write_release(folder, UpdateFixtures.release_entries(_VERSION, files))
	var archive := ProjectSettings.globalize_path(UpdateFolder.version_folder(_VERSION, folder)).path_join(ReleaseAssets.archive_name(_VERSION))
	var bytes := FileAccess.get_file_as_bytes(archive)
	var entry_end := _end_of_text(bytes, _ADDON_ENTRY + "core/big.gd")
	for offset: int in range(entry_end, entry_end + 8):
		bytes[offset] = bytes[offset] ^ 0xFF
	var file := FileAccess.open(archive, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()
	var stepper := StageStepper.new()
	stepper.begin(_VERSION, folder)
	var outcome := _advance_quietly(stepper)
	var stage_left := DirAccess.dir_exists_absolute(_stage_path(folder))
	UpdateFixtures.remove(folder)
	testing.ok(entry_end > 0, "the entry was found to damage")
	testing.eq(outcome["state"], "failed", "→ failed")
	testing.eq(outcome["reason"], "the archive's core/big.gd does not match its file list", "the reason names the entry")
	testing.ok(not stage_left, "the entry → not in the stage")
	print("")


# A file named `a` and a file under `a/` pass the zip's checks and cannot both exist.
static func _test_entry_that_cannot_be_written(testing: Testing) -> void:
	testing.begin("Stage stepper: an entry that cannot be written")
	var folder := UpdateFixtures.scratch("stepper_entry_blocked")
	_write_release(folder, UpdateFixtures.release_entries(_VERSION, {"a": "a file", "a/b.gd": "under it"}))
	var stepper := StageStepper.new()
	stepper.begin(_VERSION, folder)
	var outcome := _advance_quietly(stepper)
	var stage_left := DirAccess.dir_exists_absolute(_stage_path(folder))
	UpdateFixtures.remove(folder)
	testing.eq(outcome["state"], "failed", "→ failed")
	testing.eq(outcome["reason"], "could not write a/b.gd to the stage", "the reason names the entry")
	testing.ok(not stage_left, "what the run wrote → gone")
	print("")


static func _test_cancel(testing: Testing) -> void:
	testing.begin("Stage stepper: cancel")
	var folder := UpdateFixtures.scratch("stepper_cancel")
	_write_release(folder, UpdateFixtures.release_entries(_VERSION, _FILES))
	var archive := ProjectSettings.globalize_path(UpdateFolder.version_folder(_VERSION, folder)).path_join(ReleaseAssets.archive_name(_VERSION))
	var stepper := StageStepper.new()
	stepper.begin(_VERSION, folder)
	stepper.advance(0)
	var had_stage := DirAccess.dir_exists_absolute(_stage_path(folder))
	var cancelled := stepper.cancel()
	var stage_left := DirAccess.dir_exists_absolute(_stage_path(folder))
	var after := stepper.advance()
	# Windows refuses to delete a file something still has open.
	var zip_released := DirAccess.remove_absolute(archive) == OK
	UpdateFixtures.remove(folder)
	testing.ok(had_stage, "a run going → part of a stage")
	testing.ok(cancelled, "cancel → reports the stage gone")
	testing.ok(not stage_left, "… and it is")
	testing.eq(after["state"], "idle", "a later step → idle")
	testing.ok(zip_released, "the zip is let go")

	var finished := UpdateFixtures.scratch("stepper_cancel_finished")
	_write_release(finished, UpdateFixtures.release_entries(_VERSION, _FILES))
	var done := StageStepper.new()
	done.begin(_VERSION, finished)
	done.advance(_WHOLE_RUN_MS)
	var nothing_to_cancel := done.cancel()
	var files := FolderFiles.list(_stage_path(finished))
	var state_after: String = done.advance()["state"]
	UpdateFixtures.remove(finished)
	testing.ok(nothing_to_cancel, "a run that has ended → nothing to cancel")
	testing.eq(files.size(), _FILE_COUNT, "… and its stage stays")
	testing.eq(state_after, "done", "… and still done")
	print("")


static func _test_begin_again(testing: Testing) -> void:
	testing.begin("Stage stepper: begin during a run")
	var folder := UpdateFixtures.scratch("stepper_again")
	_write_release(folder, UpdateFixtures.release_entries(_VERSION, _FILES))
	var stepper := StageStepper.new()
	stepper.begin(_VERSION, folder)
	stepper.advance(0)
	var restarted := stepper.begin(_VERSION, folder)
	var finished := stepper.advance(_WHOLE_RUN_MS)
	UpdateFixtures.remove(folder)
	testing.eq(restarted["written"], 0, "→ starts over")
	testing.eq(finished["state"], "done", "→ finishes")
	testing.eq(finished["written"], _FILE_COUNT, "→ with every file")
	print("")


# The stage the stepper writes is the one thing the applier compares against what is signed.
static func _test_applier_takes_the_stage(testing: Testing) -> void:
	testing.begin("Stage stepper: the applier takes what it wrote")
	var addon := UpdateFixtures.scratch("stepper_apply_addon")
	var folder := UpdateFixtures.scratch("stepper_apply_updates")
	UpdateFixtures.make_addon(addon, "1.1.0", {"core/a.gd": "old a"})
	UpdateFixtures.stage(folder, _VERSION, _FILES, "1.1.0", UpdateFixtures.key(), UpdateJournal.VERIFIED)
	FolderFiles.remove_tree(_stage_path(folder))
	var stepper := StageStepper.new()
	stepper.begin(_VERSION, folder)
	var staged := stepper.advance(_WHOLE_RUN_MS)
	var journal := UpdateJournal.read(folder)
	var journal_while_staging := str(journal["state"])
	journal["state"] = UpdateJournal.STAGED
	UpdateJournal.write(journal, folder)
	var applied := UpdateApplier.apply_pending({
		"addon_folder": addon,
		"update_folder": folder,
		"engine_version": "4.7",
		"public_keys": [UpdateFixtures.public_pem(UpdateFixtures.key())],
		"guard_facts": {},
	})
	var live := FileAccess.get_file_as_string(ProjectSettings.globalize_path(addon).path_join("core/a.gd"))
	UpdateFixtures.remove(addon)
	UpdateFixtures.remove(folder)
	testing.eq(staged["state"], "done", "the stage → done")
	testing.eq(journal_while_staging, "verified", "the journal stays the caller's to write")
	testing.eq(applied, {"state": "applied", "reason": ""}, "the swap → applied")
	testing.eq(live, "new a", "the live folder → the new release")
	print("")


# A time depends on the machine, so it is printed and never asserted. This runner does not
# save through a temporary file the way an editor does, so an editor's steps can be longer.
static func _test_release_sized(testing: Testing) -> void:
	testing.begin("Stage stepper: a release the size of this addon")
	var addon := ProjectSettings.globalize_path("res://addons/godot_mcp_toolkit")
	var version := UpdateApplier.installed_version(addon)
	var folder := UpdateFixtures.scratch("stepper_release_sized")
	var absolute := ProjectSettings.globalize_path(folder)
	var hashes := FolderFiles.hashes(addon)
	hashes.erase(ReleaseFileList.FILE_NAME)
	var list_text := ReleaseFileList.format(hashes)
	var archive := UpdateFolder.version_folder(version, folder).path_join(ReleaseAssets.archive_name(version))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(archive.get_base_dir()))
	var packer := ZIPPacker.new()
	packer.open(archive)
	for path: String in hashes:
		var bytes := FileAccess.get_file_as_bytes(addon.path_join(path))
		packer.start_file(_ADDON_ENTRY + path)
		packer.write_file(bytes)
		packer.close_file()
		# The backup a release replaced is the size of a release, and begin deletes it.
		FolderFiles.write_checked(absolute.path_join("backup-1.0.0").path_join(path), bytes)
	packer.start_file(_ADDON_ENTRY + ReleaseFileList.FILE_NAME)
	packer.write_file(list_text.to_utf8_buffer())
	packer.close_file()
	packer.close()
	var zip_size := FileAccess.get_file_as_bytes(archive).size()

	var stepper := StageStepper.new()
	var begin_started := Time.get_ticks_usec()
	var outcome := stepper.begin(version, folder)
	var begin_usec := Time.get_ticks_usec() - begin_started
	var longest_usec := 0
	var steps := 0
	while outcome["state"] == StageStepper.RUNNING and steps < _MAX_STEPS:
		var step_started := Time.get_ticks_usec()
		outcome = stepper.advance()
		longest_usec = maxi(longest_usec, Time.get_ticks_usec() - step_started)
		steps += 1
	print("  longest step on %s: begin %.1f ms, advance %.1f ms, over %d steps, %d files, %d zip bytes" % [
			OS.get_name(), begin_usec / 1000.0, longest_usec / 1000.0, steps, hashes.size() + 1, zip_size])
	var staged := FolderFiles.hashes(_stage_path(folder))
	var backup_gone := not DirAccess.dir_exists_absolute(absolute.path_join("backup-1.0.0"))
	UpdateFixtures.remove(folder)
	testing.eq(outcome["state"], "done", "every file of the addon → staged, its names all legal")
	testing.eq(outcome["written"], hashes.size() + 1, "… the list included")
	testing.ok(backup_gone, "the backup → gone")
	testing.eq(staged, ReleaseFileList.release_tree(list_text.to_utf8_buffer()), "the stage → exactly what the list says")
	print("")


# The offset just past the first place `text` sits in `bytes`, or 0. A zip keeps an entry's
# name in the clear right before its data, and the first place is that one, since the
# directory that names it again comes last.
static func _end_of_text(bytes: PackedByteArray, text: String) -> int:
	var wanted := text.to_utf8_buffer()
	for start: int in bytes.size() - wanted.size():
		if bytes.slice(start, start + wanted.size()) == wanted:
			return start + wanted.size()
	return 0
