@tool
extends RefCounted
## The recovery plugin's file actions: it moves an interrupted update's folders into place,
## puts the backup back over a version that did not load, and edits the enabled plugins list.
##
## Like [code]recovery_journal.gd[/code], it runs from a copy outside the addon folder at a
## start where that folder may not load, so it loads nothing from it. It repeats the
## toolkit's paths, which a unit test pins, and [code]folder_files.gd[/code]'s link-guarded
## delete. Every function is static and takes its folders as parameters, so the editor
## plugin keeps only what needs the editor.

# Relative, so the copy decides where it lives and nothing loads from the addon folder.
const RecoveryJournal := preload("recovery_journal.gd")

## Where the self-update keeps its journal, stage and backups.
const UPDATE_FOLDER := "res://addons/.godot_mcp_toolkit_update"
## The toolkit's folder.
const TOOLKIT_FOLDER := "res://addons/godot_mcp_toolkit"
## The toolkit's entry in [constant ENABLED_SETTING].
const TOOLKIT_CFG := TOOLKIT_FOLDER + "/plugin.cfg"
## The recovery plugin's own entry: its copy runs only from this folder.
const PLUGIN_CFG := "res://addons/.godot_mcp_toolkit_recovery/plugin.cfg"
## The project setting that lists the enabled editor plugins.
const ENABLED_SETTING := "editor_plugins/enabled"

## What [method restore] returns: the backup is the toolkit's folder; nothing moved, since
## the journal or the live folder is not one a restore is for; a step failed.
const RESTORED := "restored"
const REFUSED := "refused"
const FAILED := "failed"

## The steps [method restore] names to its [code]on_step[/code]: the live folder is aside;
## the backup is now the live folder.
const STEP_RENAMED_OUT := "renamed_out"
const STEP_RENAMED_IN := "renamed_in"

const _JOURNAL_FILE := "journal.json"
const _STAGE_FOLDER := "stage"
const _BACKUP_PREFIX := "backup-"
const _BROKEN_PREFIX := "broken-"
const _APPLYING := "applying"
const _APPLIED := "applied"
const _NOT_APPLIED := "not_applied"
# JSON reads every number as a float, and the journal holds these as whole numbers.
const _WHOLE_NUMBER_FIELDS := ["format", "attempts", "applying_at"]

# The exit code of `test -L` on a path that is not a link.
const _TEST_NOT_A_LINK := 1
# On Godot 4.2 on Unix OS.execute hands its command to a shell with each argument in
# double quotes, where these characters still act. Escaping them would point `test` at
# another path if the engine ran no shell, and that reads as "not a link".
const _SHELL_ACTIVE := ["\"", "$", "`", "\\"]
# `fsutil reparsepoint query` on a folder that is no reparse point exits with this and
# prints this Windows error number. The match is on the number alone, since the words are
# the system language's. It prints no path, so a folder's name cannot supply the number.
const _FSUTIL_ANSWERED_NO := 1
const _FSUTIL_NOT_A_REPARSE_POINT := "4390"
# Given a bare name, OS.execute's CreateProcessW looks in the editor's folder and its working
# directory, the project, before System32, so a fsutil.exe at the project root could answer.
const _FSUTIL_UNDER_SYSTEM_ROOT := "\\System32\\fsutil.exe"


## What the files say about the update [param journal] (the shape
## [code]recovery_journal.gd[/code]'s [code]read[/code] returns) describes, with the
## toolkit's folder at [param addon_folder].
##
## Returns [code]{"addon_present", "live_version", "backup_present", "stage_whole",
## "broken_present"}[/code], the facts [code]decide[/code] reads about files. The stage is
## hashed only for an [code]applying[/code] journal with no toolkit folder, the one case
## that reads it.
static func file_facts(journal: Dictionary, update_folder: String, addon_folder: String) -> Dictionary:
	var addon := ProjectSettings.globalize_path(addon_folder)
	var addon_present := DirAccess.dir_exists_absolute(addon)
	var stage_whole := false
	if not addon_present and str(journal.get("state", "")) == _APPLYING:
		stage_whole = RecoveryJournal.stage_matches(_stage(update_folder), str(journal.get("expected_tree_hash", "")))
	return {
		"addon_present": addon_present,
		"live_version": RecoveryJournal.plugin_version(addon.path_join("plugin.cfg")) if addon_present else "",
		"backup_present": DirAccess.dir_exists_absolute(_backup(update_folder, journal)),
		"stage_whole": stage_whole,
		"broken_present": DirAccess.dir_exists_absolute(_broken(update_folder, journal)),
	}


## Moves the stage into the toolkit's empty place and records the journal
## [code]applied[/code], so the toolkit's settle reports the update and moves its pin.
## Whether the stage is the signed release is the caller's to ask first.[br]
## [br]
## Returns whether the stage moved: false, moving nothing, unless the journal still says
## [code]applying[/code] and no toolkit folder is there.
static func roll_forward(update_folder: String, addon_folder: String) -> bool:
	var addon := ProjectSettings.globalize_path(addon_folder)
	var stage := _stage(update_folder)
	if not _interrupted(RecoveryJournal.read(update_folder), addon) or not DirAccess.dir_exists_absolute(stage):
		return false
	if DirAccess.rename_absolute(stage, addon) != OK:
		return false
	_write_journal(update_folder, {"state": _APPLIED, "reason": ""})
	return true


## Moves the backup into the toolkit's empty place. The journal stays [code]applying[/code]:
## the restored toolkit's settle finds its own version live and takes it from there.[br]
## [br]
## Returns whether the backup moved: false, moving nothing, unless the journal still says
## [code]applying[/code], no toolkit folder is there and the backup is.
static func roll_back(update_folder: String, addon_folder: String) -> bool:
	var addon := ProjectSettings.globalize_path(addon_folder)
	var journal := RecoveryJournal.read(update_folder)
	var backup := _backup(update_folder, journal)
	if not _interrupted(journal, addon) or not DirAccess.dir_exists_absolute(backup):
		return false
	return DirAccess.rename_absolute(backup, addon) == OK


## Puts the backup back over the version the journal went [code]to[/code], which did not
## load in Godot [param engine_version] ([code]major.minor[/code]): the live folder goes
## aside as [code]broken-<to>[/code], the backup becomes the live folder, the broken folder
## is deleted, and the journal says [code]not_applied[/code] with [code]restored[/code].
## [param on_step], when valid, is called with each step's name as it is reached, so a test
## can act there.[br]
## [br]
## A start after a crash before the second rename runs it again. It re-reads the journal,
## which must say [code]applying[/code] or [code]applied[/code], and needs the backup; a
## live folder must read [code]to[/code] just before it moves, and with none there the first
## rename is skipped. A failed second rename puts the broken folder back. The broken folder
## is deleted only once the live folder reads [code]from[/code]; a stale one from an earlier
## restore is deleted before the first rename. Past the second rename the backup is gone
## and the live folder reads [code]from[/code], so a rerun refuses and
## [method finish_restore] ends it. A journal that cannot be written keeps the state it had
## over the old version, which the toolkit's own settle reads.[br]
## [br]
## Returns [constant RESTORED], [constant REFUSED] (nothing moved, written or deleted) or
## [constant FAILED].
static func restore(update_folder: String, addon_folder: String, engine_version: String,
		on_step: Callable = Callable()) -> String:
	var journal := RecoveryJournal.read(update_folder)
	var state := str(journal["state"])
	var backup := _backup(update_folder, journal)
	if (state != _APPLYING and state != _APPLIED) or not DirAccess.dir_exists_absolute(backup):
		return REFUSED
	var addon := ProjectSettings.globalize_path(addon_folder)
	var to_version := str(journal["to"])
	var broken := _broken(update_folder, journal)
	if DirAccess.dir_exists_absolute(addon):
		if RecoveryJournal.plugin_version(addon.path_join("plugin.cfg")) != to_version:
			return REFUSED
		if not remove_tree(broken) or DirAccess.rename_absolute(addon, broken) != OK:
			return FAILED
		_reach(on_step, STEP_RENAMED_OUT)

	if DirAccess.rename_absolute(backup, addon) != OK:
		if DirAccess.dir_exists_absolute(broken) and not DirAccess.dir_exists_absolute(addon):
			DirAccess.rename_absolute(broken, addon)
		return FAILED
	_reach(on_step, STEP_RENAMED_IN)
	if RecoveryJournal.plugin_version(addon.path_join("plugin.cfg")) != str(journal["from"]):
		return FAILED
	return _restored(update_folder, broken, to_version, engine_version)


## Ends a [method restore] that a crash stopped after the backup became the live folder:
## deletes [code]broken-<to>[/code] and records the journal [code]not_applied[/code] with
## [code]restored[/code], as the whole restore does. It acts only when the journal says
## [code]applying[/code] or [code]applied[/code], the live folder reads [code]from[/code]
## and [code]broken-<to>[/code] is there; it moves nothing. A broken folder that will not
## delete, or a journal that will not write, is left as it was, as [method restore] leaves
## them.[br]
## [br]
## Returns [constant RESTORED], or [constant REFUSED] with nothing deleted or written.
static func finish_restore(update_folder: String, addon_folder: String, engine_version: String) -> String:
	var journal := RecoveryJournal.read(update_folder)
	var state := str(journal["state"])
	var broken := _broken(update_folder, journal)
	if (state != _APPLYING and state != _APPLIED) or not DirAccess.dir_exists_absolute(broken):
		return REFUSED
	var addon := ProjectSettings.globalize_path(addon_folder)
	if RecoveryJournal.plugin_version(addon.path_join("plugin.cfg")) != str(journal["from"]):
		return REFUSED
	return _restored(update_folder, broken, str(journal["to"]), engine_version)


## Deletes [param folder] (absolute) and everything under it, and never what a link points
## at, as [code]folder_files.gd[/code]'s [code]remove_tree[/code] does.
##
## A link, at the top or at any depth, goes as a link when the engine can remove one, its
## target untouched. Where it cannot (Godot 4.2 on Unix, or a remove an ACL denies) the
## link and its target stay.[br]
## [br]
## Returns whether [param folder] is gone.
static func remove_tree(folder: String) -> bool:
	if not DirAccess.dir_exists_absolute(folder):
		return true
	# Takes an empty folder or a link, and fails on a real folder that holds anything.
	DirAccess.remove_absolute(folder)
	if not DirAccess.dir_exists_absolute(folder):
		return true
	if _is_link(folder):
		return false
	var dir := DirAccess.open(folder)
	if dir == null:
		return false
	dir.include_hidden = true
	for name in dir.get_files():
		DirAccess.remove_absolute(folder.path_join(name))
	for name in dir.get_directories():
		remove_tree(folder.path_join(name))
	DirAccess.remove_absolute(folder)
	return not DirAccess.dir_exists_absolute(folder)


## [param enabled] (an enabled plugins list) with the toolkit's entry appended when it is
## missing and [param addon_folder] holds the toolkit's [code]plugin.cfg[/code]. An entry
## for a folder that is not there would only be dropped again at the next start.
static func with_toolkit_entry(enabled: PackedStringArray, addon_folder: String) -> PackedStringArray:
	var kept := enabled.duplicate()
	var toolkit_cfg := ProjectSettings.globalize_path(addon_folder).path_join("plugin.cfg")
	if not kept.has(TOOLKIT_CFG) and FileAccess.file_exists(toolkit_cfg):
		kept.append(TOOLKIT_CFG)
	return kept


## [param enabled] without [param entry], the rest in order.
static func without_entry(enabled: PackedStringArray, entry: String) -> PackedStringArray:
	var kept := PackedStringArray()
	for listed: String in enabled:
		if listed != entry:
			kept.append(listed)
	return kept


## Whether the project file [param project_file] saves [param entry] in its enabled
## plugins: the read-back after a save, since a project file that cannot be written only
## makes the save return an error the editor also prints.
static func saved_list_holds(project_file: String, entry: String) -> bool:
	var config := ConfigFile.new()
	if config.load(project_file) != OK:
		return false
	var enabled: Variant = config.get_value("editor_plugins", "enabled", PackedStringArray())
	if not enabled is PackedStringArray:
		return false
	var listed: PackedStringArray = enabled
	return listed.has(entry)


static func _stage(update_folder: String) -> String:
	return ProjectSettings.globalize_path(update_folder).path_join(_STAGE_FOLDER)


# The backup is always named for the version it holds, which the journal's reader checks.
static func _backup(update_folder: String, journal: Dictionary) -> String:
	return ProjectSettings.globalize_path(update_folder).path_join(_BACKUP_PREFIX + str(journal.get("from", "")))


# Where a restore sets the version that did not load aside.
static func _broken(update_folder: String, journal: Dictionary) -> String:
	return ProjectSettings.globalize_path(update_folder).path_join(_BROKEN_PREFIX + str(journal.get("to", "")))


# The last steps of a restore, once the backup is the live folder.
static func _restored(update_folder: String, broken: String, to_version: String, engine_version: String) -> String:
	remove_tree(broken)
	_write_journal(update_folder, {
		"state": _NOT_APPLIED,
		"reason": "version %s did not load in Godot %s" % [to_version, engine_version],
		"restored": true,
	})
	return RESTORED


# An apply that a kill ended between its two renames: the journal says applying and the
# toolkit's folder is gone.
static func _interrupted(journal: Dictionary, addon: String) -> bool:
	return str(journal.get("state", "")) == _APPLYING and not DirAccess.dir_exists_absolute(addon)


static func _reach(on_step: Callable, step: String) -> void:
	if on_step.is_valid():
		on_step.call(step)


# Writes [param changes] over the journal and reads it back. Every other key stays as it
# is, those a later version adds included. Returns whether the file now holds it.
static func _write_journal(update_folder: String, changes: Dictionary) -> bool:
	var path := ProjectSettings.globalize_path(update_folder).path_join(_JOURNAL_FILE)
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		return false
	var stored: Dictionary = json.data
	stored.merge(changes, true)
	for field: String in _WHOLE_NUMBER_FIELDS:
		var value: Variant = stored.get(field, null)
		if value is float:
			stored[field] = int(value)
	var text := JSON.stringify(stored, "\t")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()
	return FileAccess.get_file_as_string(path) == text


# Whether [param folder] is a link, as far as this engine can tell: DirAccess.is_link from
# 4.3, else `test -L` on Unix and `fsutil reparsepoint query` on Windows, one process per
# call. Anything but a clear "not a link" counts as one, and so does a parent that does not
# open.
static func _is_link(folder: String) -> bool:
	var parent := DirAccess.open(folder.get_base_dir())
	if parent == null:
		return true
	if parent.has_method("is_link"):
		return bool(parent.call("is_link", folder.get_file()))
	if OS.get_name() == "Windows":
		var system_root := OS.get_environment("SystemRoot")
		if system_root.is_empty():
			return true
		var fsutil := system_root + _FSUTIL_UNDER_SYSTEM_ROOT
		var output: Array = []
		var exit_code := OS.execute(fsutil, ["reparsepoint", "query", folder.replace("/", "\\")], output)
		return exit_code != _FSUTIL_ANSWERED_NO or not str(output).contains(_FSUTIL_NOT_A_REPARSE_POINT)
	for character: String in _SHELL_ACTIVE:
		if folder.contains(character):
			return true
	return OS.execute("test", ["-L", folder]) != _TEST_NOT_A_LINK
