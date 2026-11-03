@tool
extends RefCounted
## Settles what an update left in the update folder, at the editor's next start.
##
## [method settle] compares the update journal with the installed version, finishes or
## clears what it finds, and returns what to report. It shows nothing itself.[br]
## [br]
## The applier runs from the version being replaced and nothing can patch it. This runs
## from the version the editor just started, so it can change from release to release, and
## it has to read every older journal.[br]
## [br]
## A journal it does not trust reads as none and stays, with its stage, until the next
## staging replaces them.

const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const ReleaseArchive := preload("res://addons/godot_mcp_toolkit/self_update/release_archive.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const StageStepper := preload("res://addons/godot_mcp_toolkit/self_update/stage_stepper.gd")
const UpdateApplier := preload("res://addons/godot_mcp_toolkit/self_update/update_applier.gd")
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const UpdateJournal := preload("res://addons/godot_mcp_toolkit/self_update/update_journal.gd")

## Off, a successful update takes the whole update folder with it, backup included. A
## missing key, or a value that is not a boolean, keeps the folder.
const KEEP_BACKUP_SETTING := "mcp_toolkit/updates/keep_backup"

## What [method settle] reports. [constant NOTHING]: nothing to show.
const NOTHING := ""
## A stage waits for the editor's next exit.
const WAITING := "waiting"
## The toolkit is now the version the update installed.
const UPDATED := "updated"
## The update did not install, and its [code]reason[/code] says why.
const FAILED := "failed"

const _STAGE_NOT_WHOLE := "the stage or its zip is not whole"


## Settles the update folder.
##
## [param options] replaces what this reads, for tests, under the names
## [method UpdateApplier.apply_pending] takes.[br]
## [br]
## Returns [code]{"report": String, "from": String, "to": String, "reason": String,
## "attempts": int, "compatible_server": String}[/code]: [constant NOTHING],
## [constant WAITING], [constant UPDATED] or [constant FAILED], then the journal's fields,
## since the journal may be gone by the time this returns. [code]reason[/code] is set on a
## failure, and on a wait that an exit has already postponed.[br]
## [br]
## The one re-stage runs to its end inside this call, one [StageStepper] step after
## another. It finishes once per update, while the editor is starting; a kill before it
## finishes leaves the journal as it was, so the next start runs it again.
static func settle(options: Dictionary = {}) -> Dictionary:
	var addon_folder := ProjectSettings.globalize_path(str(options.get("addon_folder", UpdateApplier.ADDON_FOLDER)))
	var update_folder := str(options.get("update_folder", UpdateFolder.FOLDER))
	var journal := UpdateJournal.read(update_folder)
	var state := str(journal["state"])
	if state.is_empty():
		return _report(NOTHING, journal, "")
	if state == UpdateJournal.VERIFIED:
		return _clear_quietly(journal, "a kill before staging finished", update_folder)
	if state == UpdateJournal.NOT_APPLIED:
		return _settle_not_applied(journal, addon_folder, update_folder, options)

	var installed := UpdateApplier.installed_version(addon_folder)
	# A folder with no readable version cannot run the toolkit: most likely a kill between
	# the renames or a failed undo, where the backup and the stage are the way back.
	if installed.is_empty():
		return _report(NOTHING, journal, "")
	if state == UpdateJournal.APPLYING:
		return _settle_applying(journal, installed, update_folder)
	if state == UpdateJournal.STAGED:
		return _settle_staged(journal, installed, update_folder)
	return _settle_applied(journal, installed, update_folder)


static func _settle_applying(journal: Dictionary, installed: String, update_folder: String) -> Dictionary:
	if installed == str(journal["to"]):
		journal["state"] = UpdateJournal.APPLIED
		_write(journal, update_folder)
		return _settle_updated(journal, update_folder)
	if installed != str(journal["from"]):
		return _clear_quietly(journal, "installed by hand at %s" % installed, update_folder)
	if not _stage_is_whole(journal, update_folder):
		return _clear_and_report(journal, _STAGE_NOT_WHOLE, update_folder)
	journal["state"] = UpdateJournal.STAGED
	_write(journal, update_folder)
	return _waiting(journal)


static func _settle_staged(journal: Dictionary, installed: String, update_folder: String) -> Dictionary:
	if not UpdateCheck.is_newer(installed, str(journal["to"])):
		return _clear_quietly(journal, "already at %s" % installed, update_folder)
	if not _stage_is_whole(journal, update_folder):
		return _clear_and_report(journal, _STAGE_NOT_WHOLE, update_folder)
	return _waiting(journal)


static func _settle_applied(journal: Dictionary, installed: String, update_folder: String) -> Dictionary:
	if installed == str(journal["to"]):
		return _settle_updated(journal, update_folder)
	return _clear_and_report(journal, "the editor started version %s" % installed, update_folder)


# A success is reported only from here. A journal that will not delete reports it again at
# the next start, which beats losing the report.
static func _settle_updated(journal: Dictionary, update_folder: String) -> Dictionary:
	_log(journal, "updated over %s" % journal["from"], update_folder)
	if _keeps_backup():
		UpdateJournal.clear(update_folder)
	else:
		FolderFiles.remove_tree(ProjectSettings.globalize_path(update_folder))
	return _report(UPDATED, journal, "")


# A stage that did not match heals from the zip once. Everything that ends that chance clears
# here and never re-stages, or a release that keeps failing would unpack at every start.
static func _settle_not_applied(
		journal: Dictionary, addon_folder: String, update_folder: String, options: Dictionary) -> Dictionary:
	var to_version := str(journal["to"])
	if bool(journal.get("restaged", false)) or not FileAccess.file_exists(_archive(journal, update_folder)):
		return _clear_and_report(journal, str(journal["reason"]), update_folder)
	var check := UpdateApplier.check_release(to_version, addon_folder, update_folder, options)
	if not str(check["error"]).is_empty():
		return _clear_and_report(journal, str(check["error"]), update_folder)
	var problem := _restage(to_version, update_folder)
	if not problem.is_empty():
		return _clear_and_report(journal, problem, update_folder)
	journal["state"] = UpdateJournal.STAGED
	journal["reason"] = ""
	journal["attempts"] = 0
	journal["restaged"] = true
	if not UpdateJournal.write(journal, update_folder):
		return _clear_and_report(journal, "could not write the journal", update_folder)
	_log(journal, "staged again from the zip", update_folder)
	return _waiting(journal)


# Why the stage could not be made again, or an empty string when it was. Staging deletes
# the update backups, as it always does; a release the check refused never gets this far.
static func _restage(version: String, update_folder: String) -> String:
	var stepper := StageStepper.new()
	var outcome := stepper.begin(version, update_folder)
	while str(outcome["state"]) == StageStepper.RUNNING:
		outcome = stepper.advance()
	return str(outcome["reason"])


# Whether the stage equals the list in the zip. The exit checks the signature behind that
# zip; this only tells a stage worth waiting for from one that is not.
static func _stage_is_whole(journal: Dictionary, update_folder: String) -> bool:
	var archive := _archive(journal, update_folder)
	if not FileAccess.file_exists(archive):
		return false
	var inspection := ReleaseArchive.inspect(archive, str(journal["to"]))
	if not str(inspection["error"]).is_empty():
		return false
	var stage := ProjectSettings.globalize_path(UpdateFolder.stage_folder(update_folder))
	return UpdateApplier.stage_matches(stage, inspection["list"])


static func _archive(journal: Dictionary, update_folder: String) -> String:
	var version := str(journal["to"])
	return UpdateFolder.version_folder(version, update_folder).path_join(ReleaseAssets.archive_name(version))


static func _keeps_backup() -> bool:
	var value: Variant = ProjectSettings.get_setting(KEEP_BACKUP_SETTING, true)
	return not value is bool or bool(value)


static func _waiting(journal: Dictionary) -> Dictionary:
	return _report(WAITING, journal, str(journal["reason"]) if int(journal["attempts"]) > 0 else "")


static func _clear_quietly(journal: Dictionary, why: String, update_folder: String) -> Dictionary:
	_log(journal, "cleared: %s" % why, update_folder)
	UpdateJournal.clear(update_folder)
	return _report(NOTHING, journal, "")


static func _clear_and_report(journal: Dictionary, reason: String, update_folder: String) -> Dictionary:
	_log(journal, "not installed: %s" % reason, update_folder)
	UpdateJournal.clear(update_folder)
	return _report(FAILED, journal, reason)


# A failed write leaves the last state on disk for the next start to settle again, so only
# the install log records it.
static func _write(journal: Dictionary, update_folder: String) -> void:
	var written := UpdateJournal.write(journal, update_folder)
	_log(journal, "journal says %s%s" % [journal["state"], "" if written else ", but it could not be written"], update_folder)


static func _log(journal: Dictionary, line: String, update_folder: String) -> void:
	UpdateFolder.log_line("settle %s: %s" % [journal["to"], line], update_folder)


static func _report(report: String, journal: Dictionary, reason: String) -> Dictionary:
	return {
		"report": report,
		"from": journal["from"],
		"to": journal["to"],
		"reason": reason,
		"attempts": journal["attempts"],
		"compatible_server": journal["compatible_server"],
	}
