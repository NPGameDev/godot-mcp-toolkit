@tool
extends RefCounted
## Unit tests for the recovery plugin's file actions: rolling an interrupted apply forward or
## back, putting the backup back over a version that did not load at each point a crash can
## leave it, deleting a tree without following a link, and keeping the toolkit's entry in the
## enabled plugins.

const Testing := preload("res://test/units/testing.gd")
const UpdateJournal := preload("res://addons/godot_mcp_toolkit/self_update/update_journal.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const InstallGuards := preload("res://addons/godot_mcp_toolkit/self_update/install_guards.gd")
const RecoveryFiles := preload("res://addons/godot_mcp_toolkit/self_update/recovery_files.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const ContentHash := preload("res://addons/godot_mcp_toolkit/self_update/content_hash.gd")
const ReleaseFileList := preload("res://addons/godot_mcp_toolkit/self_update/release_file_list.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

# The template has no class_name, so the tests load it by its path.
const RECOVERY_ACTIONS_PATH := "res://addons/godot_mcp_toolkit/self_update/recovery/recovery_actions.gd"
const RECOVERY_JOURNAL_PATH := "res://addons/godot_mcp_toolkit/self_update/recovery/recovery_journal.gd"
const APPLYING_AT := 1794300000
const ENGINE_VERSION := "4.5"


static func run(testing: Testing) -> void:
	var actions: GDScript = load(RECOVERY_ACTIONS_PATH)
	_test_paths(testing, actions)
	_test_file_facts(testing, actions)
	_test_roll_forward(testing, actions)
	_test_roll_back(testing, actions)
	_test_restore(testing, actions)
	_test_restore_guard(testing, actions)
	_test_restore_after_rename_out(testing, actions)
	_test_restore_crash_after_rename_in(testing, actions)
	_test_finish_restore_guard(testing, actions)
	_test_restore_failed_rename_in(testing, actions)
	_test_restore_keeps_broken_until_from_is_live(testing, actions)
	_test_remove_tree_link(testing, actions)
	_test_toolkit_entry(testing, actions)


# An update in flight in a scratch folder: the update folder with journal_text as its
# journal, and an addon folder beside it, not made yet.
static func _scenario(purpose: String, journal_text: String) -> Dictionary:
	var root := UpdateFixtures.scratch(purpose)
	var update_folder := root.path_join("update")
	var absolute := ProjectSettings.globalize_path(update_folder)
	FolderFiles.write_checked(absolute.path_join("journal.json"), journal_text.to_utf8_buffer())
	return {
		"root": root,
		"update": update_folder,
		"addon": ProjectSettings.globalize_path(root).path_join("addon"),
		"stage": absolute.path_join("stage"),
		"backup": absolute.path_join("backup-1.1.0"),
		"broken": absolute.path_join("broken-1.2.0"),
	}


# A toolkit folder whose plugin.cfg names the given version.
static func _write_toolkit(folder: String, version: String) -> void:
	FolderFiles.write_checked(folder.path_join("plugin.cfg"), UpdateFixtures.plugin_config(version).to_utf8_buffer())
	FolderFiles.write_checked(folder.path_join("core/a.gd"), ("# " + version).to_utf8_buffer())


static func _version_at(folder: String) -> String:
	var config := ConfigFile.new()
	if config.load(folder.path_join("plugin.cfg")) != OK:
		return ""
	return str(config.get_value("plugin", "version", ""))


static func _journal_text(scenario: Dictionary) -> String:
	return FileAccess.get_file_as_string(ProjectSettings.globalize_path(str(scenario["update"])).path_join("journal.json"))


static func _exists(path: Variant) -> bool:
	return DirAccess.dir_exists_absolute(str(path))


static func _restore(actions: GDScript, scenario: Dictionary, on_step: Callable = Callable()) -> String:
	var result: Variant = actions.call("restore", str(scenario["update"]), str(scenario["addon"]), ENGINE_VERSION, on_step)
	return str(result)


static func _test_paths(testing: Testing, actions: GDScript) -> void:
	testing.begin("Recovery actions: the paths it holds are the toolkit's own")
	var constants := actions.get_script_constant_map()
	testing.eq(constants.get("UPDATE_FOLDER"), UpdateFolder.FOLDER, "the update folder → update_folder.gd's")
	testing.eq(constants.get("TOOLKIT_FOLDER"), InstallGuards.ADDON_FOLDER, "the toolkit's folder → install_guards.gd's")
	testing.eq(constants.get("TOOLKIT_CFG"), UpdateFixtures.TOOLKIT_PLUGIN_ENTRY, "the toolkit's entry → its plugin.cfg")
	testing.eq(constants.get("PLUGIN_CFG"), RecoveryFiles.PLUGIN_CFG, "its own entry → recovery_files.gd's")
	print("")


static func _test_file_facts(testing: Testing, actions: GDScript) -> void:
	testing.begin("Recovery actions: what the files say about an update in flight")
	var scenario := _scenario("recovery_facts", UpdateFixtures.PINNED_1_2_0_APPLYING_JOURNAL)
	var journal := {"state": "applying", "from": "1.1.0", "to": "1.2.0", "expected_tree_hash": "0".repeat(64)}
	var gone: Dictionary = actions.call("file_facts", journal, str(scenario["update"]), str(scenario["addon"]))
	_write_toolkit(str(scenario["addon"]), "1.2.0")
	_write_toolkit(str(scenario["backup"]), "1.1.0")
	var present: Dictionary = actions.call("file_facts", journal, str(scenario["update"]), str(scenario["addon"]))
	UpdateFixtures.remove(str(scenario["root"]))
	testing.eq(gone, {"addon_present": false, "live_version": "", "backup_present": false, "stage_whole": false,
			"broken_present": false}, "no addon folder, no backup, no stage → all false")
	testing.eq(present, {"addon_present": true, "live_version": "1.2.0", "backup_present": true, "stage_whole": false,
			"broken_present": false}, "the addon folder at 1.2.0 and the backup → present, its version, the backup")

	var whole := _scenario("recovery_facts_whole", UpdateFixtures.PINNED_1_2_0_APPLYING_JOURNAL)
	var whole_journal := journal.duplicate()
	whole_journal["expected_tree_hash"] = _write_stage(str(whole["stage"]), {"plugin.cfg": UpdateFixtures.plugin_config("1.2.0")})
	var staged: Dictionary = actions.call("file_facts", whole_journal, str(whole["update"]), str(whole["addon"]))
	UpdateFixtures.remove(str(whole["root"]))
	testing.eq(staged, {"addon_present": false, "live_version": "", "backup_present": false, "stage_whole": true,
			"broken_present": false}, "applying, no addon folder, the whole stage → the stage whole")

	var crashed := _scenario("recovery_facts_broken", UpdateFixtures.PINNED_1_2_0_APPLIED_JOURNAL)
	_write_toolkit(str(crashed["addon"]), "1.1.0")
	_write_toolkit(str(crashed["broken"]), "1.2.0")
	var applied_journal := {"state": "applied", "from": "1.1.0", "to": "1.2.0", "expected_tree_hash": "0".repeat(64)}
	var broken: Dictionary = actions.call("file_facts", applied_journal, str(crashed["update"]), str(crashed["addon"]))
	UpdateFixtures.remove(str(crashed["root"]))
	testing.eq(broken, {"addon_present": true, "live_version": "1.1.0", "backup_present": false, "stage_whole": false,
			"broken_present": true}, "the old version live and broken-<to> aside → broken present")
	print("")


# Writes a stage holding files and the list of their hashes. Returns the list's hash.
static func _write_stage(stage: String, files: Dictionary) -> String:
	var listed := {}
	for path: String in files:
		var bytes := str(files[path]).to_utf8_buffer()
		FolderFiles.write_checked(stage.path_join(path), bytes)
		listed[path] = ContentHash.of_bytes(bytes)
	var list_bytes := ReleaseFileList.format(listed).to_utf8_buffer()
	FolderFiles.write_checked(stage.path_join(ReleaseFileList.FILE_NAME), list_bytes)
	return ContentHash.of_bytes(list_bytes)


static func _test_roll_forward(testing: Testing, actions: GDScript) -> void:
	testing.begin("Recovery actions: rolling an interrupted apply forward")
	var scenario := _scenario("recovery_roll_forward", UpdateFixtures.PINNED_1_2_0_APPLYING_JOURNAL)
	_write_toolkit(str(scenario["stage"]), "1.2.0")
	_write_toolkit(str(scenario["backup"]), "1.1.0")
	var rolled: Variant = actions.call("roll_forward", str(scenario["update"]), str(scenario["addon"]))
	var journal := UpdateJournal.read(str(scenario["update"]))
	var live := _version_at(str(scenario["addon"]))
	var stage_gone := not _exists(scenario["stage"])
	var backup_kept := _exists(scenario["backup"])
	UpdateFixtures.remove(str(scenario["root"]))
	testing.eq(rolled, true, "the stage moved → true")
	testing.eq(live, "1.2.0", "the stage is now the toolkit's folder")
	testing.ok(stage_gone, "the stage folder is gone")
	testing.ok(backup_kept, "the backup stays")
	testing.eq(journal["state"], "applied", "the journal says applied")
	testing.eq(journal.get("applying_at", -1), APPLYING_AT, "its applying time stays")
	testing.eq(journal["reason"], "", "with no reason")
	testing.eq(journal["attempts"], 1, "its attempts stay")
	testing.eq(journal["compatible_server"], "1.1.0", "its compatible server stays")
	testing.eq(journal["changed_files"], PackedStringArray(["core/a.gd"]), "its changed files stay")

	var present := _scenario("recovery_roll_forward_present", UpdateFixtures.PINNED_1_2_0_APPLYING_JOURNAL)
	_write_toolkit(str(present["stage"]), "1.2.0")
	_write_toolkit(str(present["addon"]), "1.1.0")
	var refused: Variant = actions.call("roll_forward", str(present["update"]), str(present["addon"]))
	var present_live := _version_at(str(present["addon"]))
	var present_stage := _exists(present["stage"])
	var present_text := _journal_text(present)
	UpdateFixtures.remove(str(present["root"]))
	testing.eq(refused, false, "the toolkit's folder present → false")
	testing.eq(present_live, "1.1.0", "and the live folder is untouched")
	testing.ok(present_stage, "and the stage stays")
	testing.eq(present_text, UpdateFixtures.PINNED_1_2_0_APPLYING_JOURNAL, "and the journal is unchanged")

	var applied := _scenario("recovery_roll_forward_applied", UpdateFixtures.PINNED_1_2_0_APPLIED_JOURNAL)
	_write_toolkit(str(applied["stage"]), "1.2.0")
	var not_applying: Variant = actions.call("roll_forward", str(applied["update"]), str(applied["addon"]))
	var applied_moved := _exists(applied["addon"])
	UpdateFixtures.remove(str(applied["root"]))
	testing.eq(not_applying, false, "a journal that does not say applying → false")
	testing.ok(not applied_moved, "and nothing moved")
	print("")


static func _test_roll_back(testing: Testing, actions: GDScript) -> void:
	testing.begin("Recovery actions: rolling an interrupted apply back")
	var scenario := _scenario("recovery_roll_back", UpdateFixtures.PINNED_1_2_0_APPLYING_JOURNAL)
	_write_toolkit(str(scenario["stage"]), "1.2.0")
	_write_toolkit(str(scenario["backup"]), "1.1.0")
	var rolled: Variant = actions.call("roll_back", str(scenario["update"]), str(scenario["addon"]))
	var live := _version_at(str(scenario["addon"]))
	var backup_gone := not _exists(scenario["backup"])
	var text := _journal_text(scenario)
	UpdateFixtures.remove(str(scenario["root"]))
	testing.eq(rolled, true, "the backup moved → true")
	testing.eq(live, "1.1.0", "the backup is now the toolkit's folder")
	testing.ok(backup_gone, "the backup folder is gone")
	testing.eq(text, UpdateFixtures.PINNED_1_2_0_APPLYING_JOURNAL, "the journal stays at applying for the toolkit's settle")

	var present := _scenario("recovery_roll_back_present", UpdateFixtures.PINNED_1_2_0_APPLYING_JOURNAL)
	_write_toolkit(str(present["backup"]), "1.1.0")
	_write_toolkit(str(present["addon"]), "1.2.0")
	var refused: Variant = actions.call("roll_back", str(present["update"]), str(present["addon"]))
	var present_live := _version_at(str(present["addon"]))
	var present_backup := _exists(present["backup"])
	UpdateFixtures.remove(str(present["root"]))
	testing.eq(refused, false, "the toolkit's folder present → false")
	testing.eq(present_live, "1.2.0", "and the live folder is untouched")
	testing.ok(present_backup, "and the backup stays")

	var no_backup := _scenario("recovery_roll_back_no_backup", UpdateFixtures.PINNED_1_2_0_APPLYING_JOURNAL)
	var missing: Variant = actions.call("roll_back", str(no_backup["update"]), str(no_backup["addon"]))
	var no_backup_moved := _exists(no_backup["addon"])
	UpdateFixtures.remove(str(no_backup["root"]))
	testing.eq(missing, false, "no backup → false")
	testing.ok(not no_backup_moved, "and no toolkit folder appears")
	print("")


static func _test_restore(testing: Testing, actions: GDScript) -> void:
	testing.begin("Recovery actions: putting the backup back over a version that did not load")
	var scenario := _scenario("recovery_restore", UpdateFixtures.PINNED_1_2_0_APPLIED_JOURNAL)
	_write_toolkit(str(scenario["addon"]), "1.2.0")
	_write_toolkit(str(scenario["backup"]), "1.1.0")
	var seen := {"steps": [], "broken_at_rename_in": false}
	var on_step := func(step: String) -> void:
		(seen["steps"] as Array).append(step)
		if step == "renamed_in":
			seen["broken_at_rename_in"] = DirAccess.dir_exists_absolute(str(scenario["broken"]))
	var result := _restore(actions, scenario, on_step)
	var live := _version_at(str(scenario["addon"]))
	var backup_gone := not _exists(scenario["backup"])
	var broken_gone := not _exists(scenario["broken"])
	var text := _journal_text(scenario)
	var journal := UpdateJournal.read(str(scenario["update"]))
	var again := _restore(actions, scenario)
	var live_again := _version_at(str(scenario["addon"]))
	var text_again := _journal_text(scenario)
	UpdateFixtures.remove(str(scenario["root"]))
	testing.eq(result, "restored", "the result → restored")
	testing.eq(live, "1.1.0", "the backup is now the toolkit's folder")
	testing.ok(backup_gone, "the backup folder is gone: nothing names it any more")
	testing.ok(broken_gone, "the version that did not load is deleted")
	testing.eq(seen["steps"], ["renamed_out", "renamed_in"], "the steps → out, then in")
	testing.eq(seen["broken_at_rename_in"], true, "the broken folder still there once the backup is in")
	# A Windows checkout gives the pinned text CRLF line ends; the journal is written with LF.
	testing.eq(text, UpdateFixtures.PINNED_1_2_0_RESTORED_JOURNAL.replace("\r\n", "\n"),
			"the journal → the pinned restored text")
	testing.eq(journal["state"], "not_applied", "UpdateJournal reads not applied")
	testing.eq(journal.get("restored", false), true, "and restored")
	testing.eq(journal["reason"], "version 1.2.0 did not load in Godot 4.5", "with the reason")
	testing.eq(again, "refused", "a second restore → refused")
	testing.eq(live_again, "1.1.0", "and the toolkit's folder stays")
	testing.eq(text_again, text, "and the journal stays")

	var applying := _scenario("recovery_restore_applying", UpdateFixtures.PINNED_1_2_0_APPLYING_JOURNAL)
	_write_toolkit(str(applying["addon"]), "1.2.0")
	_write_toolkit(str(applying["backup"]), "1.1.0")
	var applying_result := _restore(actions, applying)
	var applying_live := _version_at(str(applying["addon"]))
	var applying_journal := UpdateJournal.read(str(applying["update"]))
	UpdateFixtures.remove(str(applying["root"]))
	testing.eq(applying_result, "restored", "an aged applying journal over the new version → restored")
	testing.eq(applying_live, "1.1.0", "and the backup is in")
	testing.eq(applying_journal["state"], "not_applied", "and the journal says not applied")

	var stale := _scenario("recovery_restore_stale_broken", UpdateFixtures.PINNED_1_2_0_APPLIED_JOURNAL)
	_write_toolkit(str(stale["addon"]), "1.2.0")
	_write_toolkit(str(stale["backup"]), "1.1.0")
	_write_toolkit(str(stale["broken"]), "1.2.0")
	FolderFiles.write_checked(str(stale["broken"]).path_join("stale.txt"), "stale".to_utf8_buffer())
	var stale_result := _restore(actions, stale)
	var stale_live := _version_at(str(stale["addon"]))
	var stale_gone := not _exists(stale["broken"])
	UpdateFixtures.remove(str(stale["root"]))
	testing.eq(stale_result, "restored", "a broken folder left from before → restored")
	testing.eq(stale_live, "1.1.0", "the backup is in")
	testing.ok(stale_gone, "and no broken folder is left")
	print("")


static func _test_restore_guard(testing: Testing, actions: GDScript) -> void:
	testing.begin("Recovery actions: a restore moves nothing unless the live version is the one that did not load")
	var rows := [
		[UpdateFixtures.PINNED_1_2_0_APPLIED_JOURNAL, "1.3.0", true, false, "another version live"],
		[UpdateFixtures.PINNED_1_2_0_APPLIED_JOURNAL, "1.1.0", true, true,
				"the old version live and a broken folder (a second editor)"],
		[UpdateFixtures.PINNED_1_2_0_APPLIED_JOURNAL, "1.2.0", false, false, "no backup"],
		[UpdateFixtures.PINNED_1_2_0_JOURNAL, "1.2.0", true, false, "a staged journal"],
		[UpdateFixtures.PINNED_1_2_0_RESTORED_JOURNAL, "1.2.0", true, false, "a restored journal"],
	]
	for index: int in rows.size():
		var row: Array = rows[index]
		var scenario := _scenario("recovery_restore_guard_%d" % index, str(row[0]))
		_write_toolkit(str(scenario["addon"]), str(row[1]))
		if bool(row[2]):
			_write_toolkit(str(scenario["backup"]), "1.1.0")
		if bool(row[3]):
			_write_toolkit(str(scenario["broken"]), "1.2.0")
		var before := FolderFiles.hashes(ProjectSettings.globalize_path(str(scenario["root"])))
		var result := _restore(actions, scenario)
		var after := FolderFiles.hashes(ProjectSettings.globalize_path(str(scenario["root"])))
		UpdateFixtures.remove(str(scenario["root"]))
		testing.eq(result, "refused", "%s → refused" % str(row[4]))
		testing.eq(after, before, "%s → nothing moved, written or deleted" % str(row[4]))
	print("")


static func _test_restore_after_rename_out(testing: Testing, actions: GDScript) -> void:
	testing.begin("Recovery actions: a restore that a crash ended after the first rename finishes")
	var scenario := _scenario("recovery_restore_reentry", UpdateFixtures.PINNED_1_2_0_APPLIED_JOURNAL)
	_write_toolkit(str(scenario["broken"]), "1.2.0")
	_write_toolkit(str(scenario["backup"]), "1.1.0")
	var steps := []
	var on_step := func(step: String) -> void:
		steps.append(step)
	var result := _restore(actions, scenario, on_step)
	var live := _version_at(str(scenario["addon"]))
	var broken_gone := not _exists(scenario["broken"])
	var backup_gone := not _exists(scenario["backup"])
	var journal := UpdateJournal.read(str(scenario["update"]))
	UpdateFixtures.remove(str(scenario["root"]))
	testing.eq(result, "restored", "no toolkit folder, the broken one aside → restored")
	testing.eq(steps, ["renamed_in"], "the rename out is skipped")
	testing.eq(live, "1.1.0", "the backup is now the toolkit's folder")
	testing.ok(broken_gone, "the broken folder is deleted")
	testing.ok(backup_gone, "the backup folder is gone")
	testing.eq(journal.get("restored", false), true, "the journal says restored")
	print("")


# A copy of every file in one folder into another: the disk as a crash at that moment
# leaves it.
static func _copy_files(from: String, to: String) -> void:
	for path: String in FolderFiles.list(from):
		FolderFiles.write_checked(to.path_join(path), FileAccess.get_file_as_bytes(from.path_join(path)))


static func _test_restore_crash_after_rename_in(testing: Testing, actions: GDScript) -> void:
	testing.begin("Recovery actions: a restore that a crash ended after the backup moved in is finished")
	var journal_reader: GDScript = load(RECOVERY_JOURNAL_PATH)
	for journal_text: String in [UpdateFixtures.PINNED_1_2_0_APPLIED_JOURNAL, UpdateFixtures.PINNED_1_2_0_APPLYING_JOURNAL]:
		var running := _scenario("recovery_restore_crash_running", journal_text)
		var crashed := _scenario("recovery_restore_crash", journal_text)
		var label := str(UpdateJournal.read(str(running["update"]))["state"])
		_write_toolkit(str(running["addon"]), "1.2.0")
		_write_toolkit(str(running["backup"]), "1.1.0")
		var running_root := ProjectSettings.globalize_path(str(running["root"]))
		var crashed_root := ProjectSettings.globalize_path(str(crashed["root"]))
		var on_step := func(step: String) -> void:
			if step == "renamed_in":
				_copy_files(running_root, crashed_root)
		_restore(actions, running, on_step)
		UpdateFixtures.remove(str(running["root"]))

		var crashed_journal: Dictionary = journal_reader.call("read", str(crashed["update"]))
		var facts: Dictionary = actions.call("file_facts", crashed_journal, str(crashed["update"]), str(crashed["addon"]))
		facts["stays_out"] = false
		facts["toolkit_enabled"] = false
		var verdict: Dictionary = journal_reader.call("decide", crashed_journal, facts, APPLYING_AT + 1000)
		var rerun := _restore(actions, crashed)
		var finished: Variant = actions.call("finish_restore", str(crashed["update"]), str(crashed["addon"]), ENGINE_VERSION)
		var live := _version_at(str(crashed["addon"]))
		var broken_gone := not _exists(crashed["broken"])
		var backup_gone := not _exists(crashed["backup"])
		var journal := UpdateJournal.read(str(crashed["update"]))
		var text := _journal_text(crashed)
		var again: Variant = actions.call("finish_restore", str(crashed["update"]), str(crashed["addon"]), ENGINE_VERSION)
		var text_again := _journal_text(crashed)
		UpdateFixtures.remove(str(crashed["root"]))
		testing.eq(facts.get("broken_present", false), true, "%s: the crash leaves broken-<to> aside" % label)
		testing.eq(verdict, {"action": "finish_restore", "seconds": 0}, "%s: the next start decides to finish" % label)
		testing.eq(rerun, "refused", "%s: a restore over the old version → refused" % label)
		testing.eq(finished, "restored", "%s: finishing → restored" % label)
		testing.eq(live, "1.1.0", "%s: the old version stays the toolkit's folder" % label)
		testing.ok(broken_gone, "%s: broken-<to> is deleted" % label)
		testing.ok(backup_gone, "%s: the backup stays consumed" % label)
		testing.eq(journal["state"], "not_applied", "%s: the journal says not applied" % label)
		testing.eq(journal.get("restored", false), true, "%s: and restored" % label)
		testing.eq(journal["reason"], "version 1.2.0 did not load in Godot 4.5", "%s: with the reason" % label)
		testing.eq(again, "refused", "%s: finishing again → refused" % label)
		testing.eq(text_again, text, "%s: and the journal stays" % label)
	print("")


static func _test_finish_restore_guard(testing: Testing, actions: GDScript) -> void:
	testing.begin("Recovery actions: finishing a restore deletes and writes nothing unless the old version is live beside broken-<to>")
	var rows := [
		[UpdateFixtures.PINNED_1_2_0_APPLIED_JOURNAL, "1.2.0", true, "the new version live"],
		[UpdateFixtures.PINNED_1_2_0_APPLIED_JOURNAL, "1.3.0", true, "another version live"],
		[UpdateFixtures.PINNED_1_2_0_APPLIED_JOURNAL, "1.1.0", false, "no broken-<to>"],
		[UpdateFixtures.PINNED_1_2_0_JOURNAL, "1.1.0", true, "a staged journal"],
		[UpdateFixtures.PINNED_1_2_0_RESTORED_JOURNAL, "1.1.0", true, "a restored journal"],
	]
	for index: int in rows.size():
		var row: Array = rows[index]
		var scenario := _scenario("recovery_finish_guard_%d" % index, str(row[0]))
		_write_toolkit(str(scenario["addon"]), str(row[1]))
		if bool(row[2]):
			_write_toolkit(str(scenario["broken"]), "1.2.0")
		var before := FolderFiles.hashes(ProjectSettings.globalize_path(str(scenario["root"])))
		var result: Variant = actions.call("finish_restore", str(scenario["update"]), str(scenario["addon"]), ENGINE_VERSION)
		var after := FolderFiles.hashes(ProjectSettings.globalize_path(str(scenario["root"])))
		UpdateFixtures.remove(str(scenario["root"]))
		testing.eq(result, "refused", "%s → refused" % str(row[3]))
		testing.eq(after, before, "%s → nothing deleted or written" % str(row[3]))
	print("")


static func _test_restore_failed_rename_in(testing: Testing, actions: GDScript) -> void:
	testing.begin("Recovery actions: a failed rename in puts the broken folder back")
	var scenario := _scenario("recovery_restore_rename_in", UpdateFixtures.PINNED_1_2_0_APPLIED_JOURNAL)
	_write_toolkit(str(scenario["addon"]), "1.2.0")
	_write_toolkit(str(scenario["backup"]), "1.1.0")
	var moved_backup := str(scenario["backup"]) + "-away"
	# The backup leaves between the renames, so the second one has nothing to move.
	var on_step := func(step: String) -> void:
		if step == "renamed_out":
			DirAccess.rename_absolute(str(scenario["backup"]), moved_backup)
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var result := _restore(actions, scenario, on_step)
	Engine.print_error_messages = printed
	var live := _version_at(str(scenario["addon"]))
	var broken_gone := not _exists(scenario["broken"])
	var text := _journal_text(scenario)
	UpdateFixtures.remove(str(scenario["root"]))
	testing.eq(result, "failed", "the backup gone mid-restore → failed")
	testing.eq(live, "1.2.0", "the broken folder is the toolkit's folder again")
	testing.ok(broken_gone, "and not left aside")
	testing.eq(text, UpdateFixtures.PINNED_1_2_0_APPLIED_JOURNAL, "the journal is unchanged")
	print("")


static func _test_restore_keeps_broken_until_from_is_live(testing: Testing, actions: GDScript) -> void:
	testing.begin("Recovery actions: the broken folder is deleted only once the live folder reads the old version")
	var scenario := _scenario("recovery_restore_wrong_backup", UpdateFixtures.PINNED_1_2_0_APPLIED_JOURNAL)
	_write_toolkit(str(scenario["addon"]), "1.2.0")
	_write_toolkit(str(scenario["backup"]), "1.0.0")
	var result := _restore(actions, scenario)
	var broken_version := _version_at(str(scenario["broken"]))
	var text := _journal_text(scenario)
	UpdateFixtures.remove(str(scenario["root"]))
	testing.eq(result, "failed", "a backup that reads another version → failed")
	testing.eq(broken_version, "1.2.0", "the broken folder stays")
	testing.eq(text, UpdateFixtures.PINNED_1_2_0_APPLIED_JOURNAL, "the journal is unchanged")
	print("")


static func _test_remove_tree_link(testing: Testing, actions: GDScript) -> void:
	testing.begin("Recovery actions: deleting a tree never follows a link inside it")
	var root := ProjectSettings.globalize_path(UpdateFixtures.scratch("recovery_link"))
	var target := root.path_join("target")
	var tree := root.path_join("tree")
	FolderFiles.write_checked(target.path_join("kept.txt"), "abc".to_utf8_buffer())
	FolderFiles.write_checked(target.path_join("sub/kept.txt"), "abc".to_utf8_buffer())
	FolderFiles.write_checked(tree.path_join("mine.txt"), "abc".to_utf8_buffer())
	FolderFiles.write_checked(tree.path_join("sub/mine.txt"), "abc".to_utf8_buffer())
	if not UpdateFixtures.make_folder_link(tree.path_join("sub/link"), target):
		print("  SKIP: no folder link can be made here")
		FolderFiles.remove_tree(root)
		print("")
		return
	var removed: Variant = actions.call("remove_tree", tree)
	var kept := FolderFiles.list(target)
	var tree_gone := not DirAccess.dir_exists_absolute(tree)
	FolderFiles.remove_tree(tree.path_join("sub/link"))
	FolderFiles.remove_tree(root)
	testing.eq(kept, PackedStringArray(["kept.txt", "sub/kept.txt"]), "the link's target keeps every file")
	testing.eq(removed, tree_gone, "the result says whether the tree went")
	# Godot 4.2 on Unix removes a folder with rmdir, which fails on a symlink, so there the
	# link and the folder holding it stay.
	var engine_keeps_links := OS.get_name() != "Windows" and not DirAccess.open(root).has_method("is_link")
	testing.ok(tree_gone or engine_keeps_links, "the tree goes where the engine removes a link as a link")
	print("")


static func _test_toolkit_entry(testing: Testing, actions: GDScript) -> void:
	testing.begin("Recovery actions: the toolkit's entry in the enabled plugins")
	var toolkit := UpdateFixtures.TOOLKIT_PLUGIN_ENTRY
	var own := UpdateFixtures.RECOVERY_PLUGIN_ENTRY
	var other := "res://addons/other/plugin.cfg"
	var root := UpdateFixtures.scratch("recovery_entry")
	var addon := ProjectSettings.globalize_path(root).path_join("addon")
	var absent := ProjectSettings.globalize_path(root).path_join("absent")
	_write_toolkit(addon, "1.1.0")
	var present: Variant = actions.call("with_toolkit_entry", PackedStringArray([other, toolkit, own]), addon)
	var missing: Variant = actions.call("with_toolkit_entry", PackedStringArray([other, own]), addon)
	var empty: Variant = actions.call("with_toolkit_entry", PackedStringArray(), addon)
	var no_toolkit: Variant = actions.call("with_toolkit_entry", PackedStringArray([other, own]), absent)
	var without_own: Variant = actions.call("without_entry", PackedStringArray([other, own, toolkit]), own)
	var without_absent: Variant = actions.call("without_entry", PackedStringArray([other, toolkit]), own)
	var project := ProjectSettings.globalize_path(root).path_join("project.godot")
	var saved := ConfigFile.new()
	saved.set_value("editor_plugins", "enabled", PackedStringArray([other, toolkit]))
	saved.save(project)
	var holds: Variant = actions.call("saved_list_holds", project, toolkit)
	var lacks: Variant = actions.call("saved_list_holds", project, own)
	var no_file: Variant = actions.call("saved_list_holds", project + ".none", toolkit)
	UpdateFixtures.remove(root)
	testing.eq(present, PackedStringArray([other, toolkit, own]), "present → the list unchanged, no second entry")
	testing.eq(missing, PackedStringArray([other, own, toolkit]), "missing → appended")
	testing.eq(empty, PackedStringArray([toolkit]), "an empty list → the toolkit alone")
	testing.eq(no_toolkit, PackedStringArray([other, own]), "no toolkit plugin.cfg on disk → the list unchanged")
	testing.eq(without_own, PackedStringArray([other, toolkit]), "taking its own entry out → the rest in order")
	testing.eq(without_absent, PackedStringArray([other, toolkit]), "taking out an entry that is not there → unchanged")
	testing.eq(holds, true, "the saved list holds the toolkit → true")
	testing.eq(lacks, false, "the saved list lacks the entry → false")
	testing.eq(no_file, false, "no project file → false")
	print("")
