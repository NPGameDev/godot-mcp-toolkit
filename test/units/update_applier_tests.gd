@tool
extends RefCounted
## Unit tests for applying a staged update, on scratch addon and update folders: a
## full apply, a rollback after a write that cannot happen, each reason not to apply,
## and a record that is not staged. The editor-exit call itself runs in the update
## flow integration test (scripts/test_framework/update_flow.sh).

const UpdateApplier := preload("res://addons/godot_mcp_toolkit/update/update_applier.gd")
const PendingUpdate := preload("res://addons/godot_mcp_toolkit/update/pending_update.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/update/folder_files.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")
const LogBuffer := preload("res://addons/godot_mcp_toolkit/logging/log_buffer.gd")


static func run(testing) -> void:
	_test_full_apply(testing)
	_test_rollback(testing)
	_test_not_applied(testing)
	_test_nothing_staged(testing)


# A scenario's folders and the apply options pointing at them.
static func _setup(purpose: String, installed_version: String, installed_files: Dictionary) -> Dictionary:
	var addon := UpdateFixtures.scratch(purpose + "_addon")
	var updates := UpdateFixtures.scratch(purpose + "_updates")
	UpdateFixtures.make_addon(addon, installed_version, installed_files)
	return {
		"addon": addon,
		"updates": updates,
		"options": {
			"addon_folder": addon,
			"update_folder": updates,
			"engine_version": "4.7",
			"public_keys": [UpdateFixtures.public_pem(UpdateFixtures.key())],
			"guard_facts": {},
		},
	}


static func _read(folder: String, path: String) -> String:
	return FileAccess.get_file_as_string(ProjectSettings.globalize_path(folder).path_join(path))


static func _version(folder: String) -> String:
	var config := ConfigFile.new()
	config.load(ProjectSettings.globalize_path(folder).path_join("plugin.cfg"))
	return str(config.get_value("plugin", "version", ""))


static func _cleanup(scenario: Dictionary) -> void:
	UpdateFixtures.remove(str(scenario["addon"]))
	UpdateFixtures.remove(str(scenario["updates"]))


static func _test_full_apply(testing) -> void:
	testing.begin("Update applier: a staged update is written")
	var scenario := _setup("apply_full", "1.1.0", {"core/a.gd": "old a", "old.gd": "dropped"})
	var addon: String = scenario["addon"]
	var updates: String = scenario["updates"]
	FolderFiles.write_checked(ProjectSettings.globalize_path(addon).path_join("mine.gd"), "my own".to_utf8_buffer())
	UpdateFixtures.stage(updates, "1.2.0", {"core/a.gd": "new a", "core/b.gd": "new b"}, "1.1.0", UpdateFixtures.key())
	var result := UpdateApplier.apply_pending(scenario["options"])
	var a := _read(addon, "core/a.gd")
	var b := _read(addon, "core/b.gd")
	var dropped_gone := not FileAccess.file_exists(ProjectSettings.globalize_path(addon).path_join("old.gd"))
	var mine := _read(addon, "mine.gd")
	var version := _version(addon)
	var backup_a := _read(PendingUpdate.backup_folder(updates), "core/a.gd")
	var record := PendingUpdate.read(updates)
	var logged := FileAccess.get_file_as_string(PendingUpdate.log_path(updates))
	_cleanup(scenario)
	testing.eq(result, {"state": "applied", "reason": ""}, "the apply reports applied")
	testing.eq(a, "new a", "a changed file → the release's content")
	testing.eq(b, "new b", "a new file → written")
	testing.ok(dropped_gone, "a listed file the release dropped → deleted")
	testing.eq(mine, "my own", "a file the list does not name → kept")
	testing.eq(version, "1.2.0", "plugin.cfg → the new version")
	testing.eq(backup_a, "old a", "the backup holds the old content")
	testing.eq(record["state"], "applied", "the record says applied")
	testing.ok(logged.contains("apply 1.2.0: applied"), "the install log says applied")
	print("")


static func _test_rollback(testing) -> void:
	testing.begin("Update applier: a failed write restores the backup")
	var scenario := _setup("apply_rollback", "1.1.0", {"core/a.gd": "old a"})
	var addon: String = scenario["addon"]
	var updates: String = scenario["updates"]
	# A folder where the release writes core/b.gd makes that write fail after
	# core/a.gd was already written.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(addon).path_join("core/b.gd"))
	UpdateFixtures.stage(updates, "1.2.0", {"core/a.gd": "new a", "core/b.gd": "new b"}, "1.1.0", UpdateFixtures.key())
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var result := UpdateApplier.apply_pending(scenario["options"])
	Engine.print_error_messages = printed
	var a := _read(addon, "core/a.gd")
	var version := _version(addon)
	var record := PendingUpdate.read(updates)
	_cleanup(scenario)
	testing.eq(result, {"state": "rolled_back", "reason": "could not write core/b.gd"}, "the apply reports the rollback and why")
	testing.eq(a, "old a", "a file the update had written → the old content again")
	testing.eq(version, "1.1.0", "plugin.cfg → still the old version")
	testing.eq(record["state"], "rolled_back", "the record says rolled back")
	print("")


static func _not_applied_reason(purpose: String, installed_version: String, prepare: Callable, extra_options: Dictionary = {}) -> Dictionary:
	var scenario := _setup(purpose, installed_version, {"core/a.gd": "old a"})
	prepare.call(scenario["updates"])
	var options: Dictionary = scenario["options"]
	options.merge(extra_options, true)
	var result := UpdateApplier.apply_pending(options)
	var untouched := _read(scenario["addon"], "core/a.gd") == "old a" and _version(scenario["addon"]) == installed_version
	_cleanup(scenario)
	return {"result": result, "untouched": untouched}


static func _test_not_applied(testing) -> void:
	testing.begin("Update applier: each reason not to apply")
	LogBuffer.setup()
	var cursor: int = LogBuffer.get_cursor() - 1
	var files := {"core/a.gd": "new a"}
	var untrusted := _not_applied_reason("apply_untrusted", "1.1.0",
			func(updates: String) -> void: UpdateFixtures.stage(updates, "1.2.0", files, "1.1.0", UpdateFixtures.other_key()))
	var above_floor := _not_applied_reason("apply_floor", "1.1.0",
			func(updates: String) -> void: UpdateFixtures.stage(updates, "1.2.0", files, "1.1.0", UpdateFixtures.key(), PendingUpdate.STAGED, "4.9"))
	var at_floor := _not_applied_reason("apply_at_floor", "1.1.0",
			func(updates: String) -> void: UpdateFixtures.stage(updates, "1.2.0", files, "1.1.0", UpdateFixtures.key(), PendingUpdate.STAGED, "4.7"))
	var same := _not_applied_reason("apply_same", "1.2.0",
			func(updates: String) -> void: UpdateFixtures.stage(updates, "1.2.0", files, "1.2.0", UpdateFixtures.key()))
	var guarded := _not_applied_reason("apply_guarded", "1.1.0",
			func(updates: String) -> void: UpdateFixtures.stage(updates, "1.2.0", files, "1.1.0", UpdateFixtures.key()),
			{"guard_facts": {"headless": true}})
	var tampered := _not_applied_reason("apply_tampered", "1.1.0",
			func(updates: String) -> void: UpdateFixtures.stage_tampered(updates, "1.2.0", files, "1.1.0", UpdateFixtures.key()))
	testing.eq(untrusted["result"], {"state": "not_applied", "reason": "the update's signature does not verify"},
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
	var all_untouched: bool = untrusted["untouched"] and above_floor["untouched"] and same["untouched"] and guarded["untouched"] and tampered["untouched"]
	testing.ok(all_untouched, "every refused apply leaves the addon folder as it was")
	if LogBuffer.uses_logger_api():
		var logged: Dictionary = LogBuffer.get_entries(100, ["error"], cursor)
		testing.eq(int(logged["returned"]), 0, "a refused apply prints no engine error")
	print("")


static func _test_nothing_staged(testing) -> void:
	testing.begin("Update applier: only a staged record is applied")
	var none := _not_applied_reason("apply_none", "1.1.0", func(_updates: String) -> void: pass)
	var verified := _not_applied_reason("apply_verified", "1.1.0",
			func(updates: String) -> void: UpdateFixtures.stage(updates, "1.2.0", {"core/a.gd": "new a"}, "1.1.0", UpdateFixtures.key(), PendingUpdate.VERIFIED))
	testing.eq(none["result"], {"state": "", "reason": ""}, "no record → nothing done")
	testing.eq(verified["result"], {"state": "", "reason": ""}, "a verified record → nothing done")
	testing.ok(none["untouched"] and verified["untouched"], "the addon folder stays as it was")
	print("")
