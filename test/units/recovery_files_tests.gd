@tool
extends RefCounted
## Unit tests for the recovery plugin's files (recovery_files.gd), driven through the update
## installer's start: a leftover recovery plugin goes, one an update on its way needs stays
## or is put back, copied from the shipped template, and a project file that refuses the
## saved entry shows in the installer's note.

const Testing := preload("res://test/units/testing.gd")
const UpdateInstaller := preload("res://addons/godot_mcp_toolkit/self_update/update_installer.gd")
const UpdateJournal := preload("res://addons/godot_mcp_toolkit/self_update/update_journal.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

const _TEMPLATE := "res://addons/godot_mcp_toolkit/self_update/recovery"
const _ONLY_THE_TOOLKIT := [UpdateFixtures.TOOLKIT_PLUGIN_ENTRY]
# The editor saves the list sorted, so the recovery plugin's dot folder comes first.
const _BOTH_PLUGINS := [UpdateFixtures.RECOVERY_PLUGIN_ENTRY, UpdateFixtures.TOOLKIT_PLUGIN_ENTRY]
# The order the world's project file starts with.
const _BOTH_AS_WRITTEN := [UpdateFixtures.TOOLKIT_PLUGIN_ENTRY, UpdateFixtures.RECOVERY_PLUGIN_ENTRY]


static func run(testing: Testing, tree: SceneTree) -> void:
	# The installer's _ready runs only once the tree's root is live.
	await tree.process_frame
	_test_leftover_goes(testing, tree)
	_test_stays_while_an_update_is_on_its_way(testing, tree)
	_test_missing_entry_is_installed_again(testing, tree)
	_test_project_file_that_will_not_save(testing, tree)
	_test_landed_update_keeps_no_recovery_plugin(testing, tree)


static func _test_leftover_goes(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Recovery files: a start with no update on its way removes a leftover recovery plugin")
	var seen := {}
	for state: String in ["", UpdateJournal.VERIFIED, UpdateJournal.NOT_APPLIED]:
		var world := _real_world("recovery_leftover_%s" % (state if not state.is_empty() else "none"))
		_leave_recovery_plugin(world)
		if not state.is_empty():
			_write_journal(world, state)
		var nodes := UpdateFixtures.start_world(world, tree)
		seen[state] = [_has_folder(world), _saved_entries(world)]
		_end(world, nodes)
	for state: String in seen:
		var label := state if not state.is_empty() else "no journal"
		var folder_left: bool = seen[state][0]
		testing.ok(not folder_left, "%s → the folder goes" % label)
		testing.eq(seen[state][1], PackedStringArray(_ONLY_THE_TOOLKIT), "%s → only the toolkit's entry stays saved" % label)
	print("")


# A staged update waits for the exit. For the other two the addon folder holds no readable
# version, as after an update that does not load, so the start's settle leaves the journal
# as it is.
static func _test_stays_while_an_update_is_on_its_way(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Recovery files: a start with an update on its way keeps the recovery plugin")
	var seen := {}
	for state: String in [UpdateJournal.STAGED, UpdateJournal.APPLYING, UpdateJournal.APPLIED]:
		var world := _real_world("recovery_stays_%s" % state)
		_leave_recovery_plugin(world)
		if state == UpdateJournal.STAGED:
			UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
		else:
			_write_journal(world, state)
			DirAccess.remove_absolute(ProjectSettings.globalize_path(str(world["addon"])).path_join("plugin.cfg"))
		var nodes := UpdateFixtures.start_world(world, tree)
		seen[state] = [_has_folder(world), _saved_entries(world), str(UpdateJournal.read(str(world["updates"]))["state"])]
		_end(world, nodes)
	for state: String in seen:
		var folder_left: bool = seen[state][0]
		testing.eq(seen[state][2], state, "%s → the settle leaves the journal %s" % [state, state])
		testing.ok(folder_left, "%s → the folder stays" % state)
		testing.eq(seen[state][1], PackedStringArray(_BOTH_AS_WRITTEN), "%s → its entry stays saved" % state)
	print("")


static func _test_missing_entry_is_installed_again(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Recovery files: a staged update whose recovery plugin is gone gets it back")
	var world := _real_world("recovery_again")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	UpdateFixtures.write_project_file(_project_file(world), PackedStringArray(_ONLY_THE_TOOLKIT))
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var state := installer.state()
	var note := installer.recovery_note()
	var entries := _saved_entries(world)
	var folder := ProjectSettings.globalize_path(_folder(world))
	var files := FolderFiles.list(folder)
	var template := ProjectSettings.globalize_path(_TEMPLATE)
	var copies_match := true
	for file_name: String in ["plugin.cfg", "recovery_actions.gd", "recovery_journal.gd", "recovery_plugin.gd"]:
		if FolderFiles.hash_of_file(folder.path_join(file_name)) != FolderFiles.hash_of_file(template.path_join(file_name)):
			copies_match = false
	var gitignore := FileAccess.get_file_as_string(folder.path_join(".gitignore"))
	var p4ignore := FileAccess.get_file_as_string(folder.path_join(".p4ignore"))
	_end(world, nodes)
	testing.eq(state, "ready", "the staged update → ready")
	testing.eq(entries, PackedStringArray(_BOTH_PLUGINS),
			"the recovery plugin's entry → saved in project.godot again, sorted before the toolkit's as the editor saves it")
	testing.eq(files, PackedStringArray([".gitignore", ".p4ignore", "plugin.cfg", "recovery_actions.gd",
			"recovery_journal.gd", "recovery_plugin.gd"]), "the folder → the template without .uid files, and two ignore files")
	testing.ok(copies_match, "each copied file → the template's bytes")
	testing.eq(gitignore, "*\n", ".gitignore → ignores everything")
	testing.eq(p4ignore, "*\n", ".p4ignore → ignores everything")
	testing.eq(note, "", "an install that worked → no note")
	print("")


# A read-only project.godot stands in for one a version control system locks. The editor
# never sees it: this save goes straight to the scratch file.
static func _test_project_file_that_will_not_save(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Recovery files: a project.godot that will not save leaves the staged update with a note")
	var world := _real_world("recovery_unsaved")
	UpdateFixtures.stage(world["updates"], "1.9.0", {"core/a.gd": "new"}, "1.1.0", UpdateFixtures.key())
	var project_file := ProjectSettings.globalize_path(_project_file(world))
	UpdateFixtures.write_project_file(project_file, PackedStringArray(_ONLY_THE_TOOLKIT))
	UpdateFixtures.set_read_only(project_file, true)
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var state := installer.state()
	var note := installer.recovery_note()
	var record := str(UpdateJournal.read(str(world["updates"]))["state"])
	var install_log := FileAccess.get_file_as_string(installer.log_path())
	UpdateFixtures.set_read_only(project_file, false)
	var entries := _saved_entries(world)
	_end(world, nodes)
	testing.eq(state, "ready", "the staged update → still ready")
	testing.eq(record, "staged", "its journal → still staged, for the exit's own check")
	testing.eq(entries, PackedStringArray(_ONLY_THE_TOOLKIT), "the project file → unchanged")
	testing.eq(note, "The update may not install when you close the editor: project.godot could not be saved.",
			"the note → project.godot could not be saved")
	testing.ok(install_log.contains("1.9.0: project.godot could not be saved"), "and the install log says it too")
	print("")


# An applied journal whose delete failed after the settle reported the update: the running
# toolkit is the version it names, so the recovery plugin has nothing to put back.
static func _test_landed_update_keeps_no_recovery_plugin(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Recovery files: an applied journal naming the running version keeps no recovery plugin")
	var world := _real_world("recovery_landed")
	_leave_recovery_plugin(world)
	UpdateJournal.write({"state": UpdateJournal.APPLIED, "to": "1.1.0", "from": "1.0.0", "compatible_server": "1.1.0",
			"reason": ""}, str(world["updates"]))
	var updates_path := ProjectSettings.globalize_path(str(world["updates"]))
	UpdateFixtures.block_delete(updates_path, "journal.json", true)
	var nodes := UpdateFixtures.start_world(world, tree)
	var folder_left := _has_folder(world)
	var entries := _saved_entries(world)
	var state := str(UpdateJournal.read(str(world["updates"]))["state"])
	UpdateFixtures.block_delete(updates_path, "journal.json", false)
	_end(world, nodes)
	testing.eq(state, "applied", "the journal will not delete, so it still says applied")
	testing.ok(not folder_left, "the folder goes")
	testing.eq(entries, PackedStringArray(_ONLY_THE_TOOLKIT), "only the toolkit's entry stays saved")
	print("")


# A world whose installer builds the real recovery files, in a scratch folder of their own.
static func _real_world(purpose: String) -> Dictionary:
	var world := UpdateFixtures.begin_world(purpose, "1.9.0", "ask", "1.1.0")
	var options: Dictionary = world["options"]
	options.erase("recovery")
	options["recovery_folder"] = UpdateFixtures.scratch(purpose + "_recovery")
	options["restart_probe"] = UpdateFixtures.RestartProbeStandIn.new()
	return world


static func _end(world: Dictionary, nodes: Dictionary) -> void:
	UpdateFixtures.end_world(world, nodes)
	UpdateFixtures.remove(_folder(world))


static func _folder(world: Dictionary) -> String:
	return str((world["options"] as Dictionary)["recovery_folder"])


static func _project_file(world: Dictionary) -> String:
	return str((world["options"] as Dictionary)["project_file"])


static func _has_folder(world: Dictionary) -> bool:
	return DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(_folder(world)))


# What an earlier update left: the folder, and the saved entry the world's project file
# already holds.
static func _leave_recovery_plugin(world: Dictionary) -> void:
	FolderFiles.write_checked(ProjectSettings.globalize_path(_folder(world)).path_join("plugin.cfg"),
			"[plugin]\n".to_utf8_buffer())


static func _write_journal(world: Dictionary, state: String) -> void:
	UpdateJournal.write({"state": state, "to": "1.9.0", "from": "1.1.0", "compatible_server": "1.1.0",
			"reason": "a held file"}, str(world["updates"]))


# The plugins the world's project file saves, empty when it does not load.
static func _saved_entries(world: Dictionary) -> PackedStringArray:
	var project := ConfigFile.new()
	if project.load(_project_file(world)) != OK:
		return PackedStringArray()
	return PackedStringArray(project.get_value("editor_plugins", "enabled", PackedStringArray()))
