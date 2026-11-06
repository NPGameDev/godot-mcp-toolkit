@tool
extends RefCounted
## Swaps a staged toolkit update in while the editor closes, by two renames under one
## journal.
##
## [method apply_pending] belongs in [code]_exit_tree[/code], on every exit that is not a
## disable, through [code]update_lifecycle.gd[/code]. Changing the files while the editor
## runs would let its focus-in rescan hot-reload new code onto state the old code built, and changing them before a restart
## could leave them swapped under a running editor when a save dialog holds the restart;
## at exit nothing reloads them. An editor ended by a signal or a crash skips the call,
## and the update waits for the next exit.[br]
## [br]
## What the stage must hold comes from what is signed: signature → manifest → the zip's
## hash → the file list inside the zip. Nothing stored beside the stage decides it, since
## anything that could change the stage could change that too. Then the journal says
## applying, the installed folder becomes the backup and the stage becomes the installed
## folder. Nothing is copied back: the addon folder belongs to the release. Each step goes
## to the install log, and the journal's state tells the next start what happened.[br]
## [br]
## Staging is the consent, so the apply asks nothing again, and a rule only staging
## applies, such as one on a major version bump, is not re-checked here.[br]
## [br]
## Once shipped, this code installs the next release on machines nothing can patch, so it
## stays this small: the journal, the checks, two renames and the undo.

# Direct preloads, not core/modules.gd: the aggregator preloads this file.
const ContentHash := preload("res://addons/godot_mcp_toolkit/self_update/content_hash.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const UpdateJournal := preload("res://addons/godot_mcp_toolkit/self_update/update_journal.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const ReleaseManifest := preload("res://addons/godot_mcp_toolkit/self_update/release_manifest.gd")
const ReleaseSignature := preload("res://addons/godot_mcp_toolkit/self_update/release_signature.gd")
const ReleaseArchive := preload("res://addons/godot_mcp_toolkit/self_update/release_archive.gd")
const ReleaseFileList := preload("res://addons/godot_mcp_toolkit/self_update/release_file_list.gd")
const InstallGuards := preload("res://addons/godot_mcp_toolkit/self_update/install_guards.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")

## The steps [method apply_pending] names to [code]on_step[/code], in order: every check
## passed; the journal says applying; the installed folder is now the backup; the stage is
## now the installed folder.
const STEP_CHECKED := "checked"
const STEP_APPLYING := "applying"
const STEP_LIVE_MOVED := "live_moved"
const STEP_STAGE_MOVED := "stage_moved"
## The reason a release whose signature the chain no longer trusts is not installed.
const UNTRUSTED_SIGNATURE := "the update is not signed by a key this toolkit trusts"


## Applies the staged update, if there is one.
##
## [param options] replaces what the apply reads, for tests: [code]addon_folder[/code],
## [code]update_folder[/code], [code]engine_version[/code] ([code]major.minor[/code]),
## [code]guard_facts[/code] (the shape [method InstallGuards.facts] returns), and what the
## signature is checked against: [code]trust_document[/code] and [code]trust_store[/code]
## (the shape [method ReleaseSignature.chain] takes), or [code]public_keys[/code], which skips
## the chain. [code]on_step[/code] is a [Callable] called with each step's name as it is
## reached, so a test can act or a driver can kill there.[br]
## [br]
## What cannot apply today leaves one of two states. Something that may pass by itself (a
## held file, a backup in the way) stays [code]staged[/code], with its [code]reason[/code]
## and one more of [code]attempts[/code], and every exit retries. A failed check writes
## [code]not_applied[/code]: a stage that does not match loses the stage and keeps the zip
## for one re-stage, and anything else, or a second mismatch, loses the zip too.[br]
## [br]
## Returns [code]{"state": String, "reason": String}[/code]: the state written to the
## journal, or an empty state when nothing was staged. [code]applying[/code] means the undo
## failed too, and the journal stays there with the backup and the stage whole.
static func apply_pending(options: Dictionary = {}) -> Dictionary:
	var addon_folder := ProjectSettings.globalize_path(str(options.get("addon_folder", InstallGuards.ADDON_FOLDER)))
	var update_folder := str(options.get("update_folder", UpdateFolder.FOLDER))
	var journal := UpdateJournal.read(update_folder)
	if journal["state"] != UpdateJournal.STAGED:
		return _nothing_staged()
	var stage := ProjectSettings.globalize_path(UpdateFolder.stage_folder(update_folder))
	UpdateFolder.log_line("apply %s over %s started" % [journal["to"], journal["from"]], update_folder)

	if not UpdateFolder.ensure_ignore_files(update_folder):
		return _postpone(journal, "could not write the update folder's ignore files", update_folder)

	var check := check_release(str(journal["to"]), addon_folder, update_folder, options)
	if not str(check["error"]).is_empty():
		return _refuse(journal, str(check["error"]), update_folder)
	var list_bytes: PackedByteArray = check["list"]
	if not stage_matches(stage, list_bytes):
		return _stage_mismatch(journal, stage, update_folder)

	# A pull between staging and this exit changes the installed version, and the backup
	# is named for what it really holds.
	var installed := str(check["installed"])
	journal["from"] = installed
	journal["backup"] = UpdateFolder.backup_name(installed)
	journal["expected_tree_hash"] = ContentHash.of_bytes(list_bytes)
	var backup := ProjectSettings.globalize_path(UpdateFolder.backup_folder(installed, update_folder))
	var backup_problem := _clear_backup_path(backup, addon_folder)
	if not backup_problem.is_empty():
		return _postpone(journal, backup_problem, update_folder)

	_reach_step(STEP_CHECKED, options, update_folder)
	# The folder can vanish at any moment, and no journal means nothing is in progress.
	if UpdateJournal.read(update_folder)["state"] != UpdateJournal.STAGED:
		return _nothing_staged()
	if not FileAccess.file_exists(stage.path_join("plugin.cfg")):
		return _stage_mismatch(journal, stage, update_folder)

	journal["state"] = UpdateJournal.APPLYING
	journal["reason"] = ""
	if not UpdateJournal.write(journal, update_folder):
		return _postpone(journal, "could not write the journal", update_folder)
	_reach_step(STEP_APPLYING, options, update_folder)

	if DirAccess.rename_absolute(addon_folder, backup) != OK:
		return _postpone(journal, "could not move the installed toolkit to %s" % journal["backup"], update_folder)
	_reach_step(STEP_LIVE_MOVED, options, update_folder)

	if DirAccess.rename_absolute(stage, addon_folder) != OK:
		var reason := "could not move the stage into place"
		if DirAccess.rename_absolute(backup, addon_folder) != OK:
			return _finish(journal, UpdateJournal.APPLYING,
					"%s, nor %s back" % [reason, journal["backup"]], update_folder)
		return _postpone(journal, reason, update_folder)
	_reach_step(STEP_STAGE_MOVED, options, update_folder)

	return _finish(journal, UpdateJournal.APPLIED, "", update_folder)


## The version in [param addon_folder]'s plugin.cfg, or an empty string when it cannot
## be read.
static func installed_version(addon_folder: String) -> String:
	var config := ConfigFile.new()
	if config.load(addon_folder.path_join("plugin.cfg")) != OK:
		return ""
	return str(config.get_value("plugin", "version", ""))


## Everything that must hold before the stage is looked at, on the files as they are now.
##
## [param options] is what [method apply_pending] takes, and [param addon_folder] is
## absolute. Returns an empty [code]error[/code], the [code]installed[/code] version and
## the zip's file [code]list[/code] as bytes when it all holds; otherwise
## [code]error[/code] names the first thing that does not.
static func check_release(
		version: String, addon_folder: String, update_folder: String, options: Dictionary) -> Dictionary:
	var guard_facts: Dictionary = options["guard_facts"] if options.has("guard_facts") else InstallGuards.facts()
	var refusal := InstallGuards.refusal(guard_facts)
	if not refusal.is_empty():
		return _problem(InstallGuards.describe(refusal))

	var release_folder := UpdateFolder.version_folder(version, update_folder)
	var manifest_bytes := FileAccess.get_file_as_bytes(release_folder.path_join(ReleaseAssets.manifest_name(version)))
	var signature := FileAccess.get_file_as_bytes(release_folder.path_join(ReleaseAssets.signature_name(version)))
	if not ReleaseSignature.is_trusted(manifest_bytes, signature, options.get("public_keys"), options):
		return _problem(UNTRUSTED_SIGNATURE)
	var manifest := ReleaseManifest.parse(manifest_bytes.get_string_from_utf8(), version)
	if not str(manifest["error"]).is_empty():
		return _problem(str(manifest["error"]))
	var engine_version := str(options.get("engine_version", VersionUtils.get_engine_version_pair()))
	if not ReleaseManifest.supports_engine(manifest, engine_version):
		return _problem("version %s needs Godot %s or newer" % [version, manifest["min_godot"]])

	var archive := UpdateFolder.archive_path(version, update_folder)
	if not FileAccess.file_exists(archive) or FolderFiles.hash_of_file(archive) != manifest["archive_sha256"]:
		return _problem("the staged archive does not match its manifest")
	var installed := installed_version(addon_folder)
	if not UpdateCheck.is_newer(installed, version):
		return _problem("version %s is not newer than the installed %s" % [version, installed])

	var inspection := ReleaseArchive.inspect(archive, version)
	if not str(inspection["error"]).is_empty():
		return inspection
	return {"error": "", "installed": installed, "list": inspection["list"]}


## Whether the folder [param stage] holds exactly what [param list_bytes] says: every
## listed file with its hash, the list's own bytes, and no other file.
static func stage_matches(stage: String, list_bytes: PackedByteArray) -> bool:
	return FolderFiles.hashes(stage) == ReleaseFileList.release_tree(list_bytes)


# Frees the path the backup moves to. A backup there that equals the installed folder is
# what a copy-restore leaves, and goes; any other is someone's and stays. Returns why the
# path is not free, or an empty string when it is.
static func _clear_backup_path(backup: String, addon_folder: String) -> String:
	if not DirAccess.dir_exists_absolute(backup):
		return ""
	var folder_name := backup.get_file()
	if FolderFiles.hashes(backup) != FolderFiles.hashes(addon_folder):
		return "%s holds something other than the installed toolkit" % folder_name
	if not FolderFiles.remove_tree(backup):
		return "could not delete %s" % folder_name
	return ""


static func _reach_step(step: String, options: Dictionary, update_folder: String) -> void:
	UpdateFolder.log_line("apply step: %s" % step, update_folder)
	var on_step: Callable = options.get("on_step", Callable())
	if on_step.is_valid():
		on_step.call(step)


static func _nothing_staged() -> Dictionary:
	return {"state": "", "reason": ""}


static func _problem(reason: String) -> Dictionary:
	return {"error": reason}


# Something that may pass by itself: the next exit tries again.
static func _postpone(journal: Dictionary, reason: String, update_folder: String) -> Dictionary:
	journal["attempts"] = int(journal["attempts"]) + 1
	return _finish(journal, UpdateJournal.STAGED, reason, update_folder)


# A stage that does not match heals from the zip once; the next start re-stages when the
# zip is still there, so a mismatch after that takes the zip too.
static func _stage_mismatch(journal: Dictionary, stage: String, update_folder: String) -> Dictionary:
	var reason := "the stage does not match the release"
	if bool(journal.get("restaged", false)):
		return _refuse(journal, reason, update_folder)
	FolderFiles.remove_tree(stage)
	return _finish(journal, UpdateJournal.NOT_APPLIED, reason, update_folder)


# A failed check that re-staging would only repeat at every start. The journal stays, so
# the next start can report it; the backup stays for the user. The deletes' results go
# unread: whatever stays, the next start re-runs the whole check before it re-stages.
static func _refuse(journal: Dictionary, reason: String, update_folder: String) -> Dictionary:
	FolderFiles.remove_tree(ProjectSettings.globalize_path(UpdateFolder.stage_folder(update_folder)))
	FolderFiles.remove_tree(ProjectSettings.globalize_path(UpdateFolder.version_folder(str(journal["to"]), update_folder)))
	return _finish(journal, UpdateJournal.NOT_APPLIED, reason, update_folder)


# A failed write leaves the last state on disk, which the next start or exit settles from
# the folders, so only the install log records it.
static func _finish(journal: Dictionary, state: String, reason: String, update_folder: String) -> Dictionary:
	journal["state"] = state
	journal["reason"] = reason
	var written := UpdateJournal.write(journal, update_folder)
	var log_parts := [
		journal["to"],
		state,
		"" if reason.is_empty() else " (%s)" % reason,
		"" if written else ", but the journal could not be written",
	]
	UpdateFolder.log_line("apply %s: %s%s%s" % log_parts, update_folder)
	return {"state": state, "reason": reason}
