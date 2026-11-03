@tool
extends RefCounted
## Unpacks a release's zip into the stage a few files at a time, so the editor keeps drawing.
##
## Call [method begin] once, then [method advance] once a frame from the main loop until
## it stops saying [constant RUNNING]. There is no thread and no wait, and the zip stays
## open between steps until the run ends or [method cancel] stops it.[br]
## [br]
## The zip is held to the file list inside it: each entry's bytes must hash to what the
## list says before they are written, which also catches an entry that does not read,
## since [method ZIPReader.read_file] then returns nothing. [method advance] always
## finishes the entry it starts, and [ZIPReader] shows no size to plan by, so one step can
## take the budget plus its largest file.[br]
## [br]
## The caller verifies the zip before staging and writes the journal when this is done:
## this reads no signature and writes no state. A kill leaves part of a stage, which the
## next [method begin] wipes. The folder can also vanish between frames, and the applier's
## check before the swap catches the stage that leaves.

const ContentHash := preload("res://addons/godot_mcp_toolkit/self_update/content_hash.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const ReleaseArchive := preload("res://addons/godot_mcp_toolkit/self_update/release_archive.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const ReleaseFileList := preload("res://addons/godot_mcp_toolkit/self_update/release_file_list.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")

## How long one [method advance] starts new entries for, in milliseconds.
const BUDGET_MS := 8

## No run has begun, or the last one was cancelled.
const IDLE := "idle"
## Entries remain: call [method advance] again.
const RUNNING := "running"
## The stage holds the whole release.
const DONE := "done"
## The run stopped, its reason says why, and what it wrote is gone.
const FAILED := "failed"

var _state := IDLE
var _reason := ""
var _reader: ZIPReader = null
var _files := PackedStringArray()
var _next_file := 0
var _tree := {}
var _stage := ""
var _update_folder := UpdateFolder.FOLDER


## Starts staging the release [param version] whose zip sits in [param update_folder],
## ending any run still going.[br]
## [br]
## The stage is wiped first, so nothing of an earlier run survives. The update backups go
## last, so a zip that will not stage costs no backup. Each step that cannot be done
## refuses the run: the ignore files, the wipe, the zip's layout and the backups.[br]
## [br]
## Returns the shape [method advance] returns.
func begin(version: String, update_folder: String = UpdateFolder.FOLDER) -> Dictionary:
	_close_reader()
	_state = IDLE
	_reason = ""
	_files = PackedStringArray()
	_next_file = 0
	_tree = {}
	_update_folder = update_folder
	_stage = ProjectSettings.globalize_path(UpdateFolder.stage_folder(update_folder))
	UpdateFolder.log_line("stage %s started" % version, update_folder)

	if not UpdateFolder.ensure_ignore_files(update_folder):
		return _fail("could not write the update folder's ignore files")
	if not FolderFiles.remove_tree(_stage):
		return _fail("could not delete the old stage")
	var archive := UpdateFolder.version_folder(version, update_folder).path_join(ReleaseAssets.archive_name(version))
	if not FileAccess.file_exists(archive):
		return _fail("the update's zip is missing")
	var reader := ZIPReader.new()
	if reader.open(archive) != OK:
		return _fail("the archive is not a readable zip")
	_reader = reader
	var inspection := ReleaseArchive.inspect_open(reader, version)
	if not str(inspection["error"]).is_empty():
		return _fail(str(inspection["error"]))
	if not UpdateFolder.remove_backups(update_folder):
		return _fail("could not delete an old update backup")

	_files = inspection["files"]
	var list_bytes: PackedByteArray = inspection["list"]
	_tree = ReleaseFileList.release_tree(list_bytes)
	_state = RUNNING
	return _outcome()


## Writes entries to the stage until [param budget_ms] has passed, at least one each call.
##
## Returns [code]{"state": String, "reason": String, "written": int, "total": int}[/code]:
## [constant IDLE], [constant RUNNING], [constant DONE] or [constant FAILED], why it
## failed, and how many of the release's files are written. Once a run has ended this only
## returns that result again.
func advance(budget_ms: int = BUDGET_MS) -> Dictionary:
	if _state != RUNNING:
		return _outcome()
	var deadline := Time.get_ticks_usec() + budget_ms * 1000
	while _next_file < _files.size():
		var problem := _write_entry(_files[_next_file])
		if not problem.is_empty():
			return _fail(problem)
		_next_file += 1
		if Time.get_ticks_usec() >= deadline:
			break
	if _next_file == _files.size():
		_close_reader()
		_state = DONE
		UpdateFolder.log_line("stage finished: %d files" % _files.size(), _update_folder)
	return _outcome()


## Stops a run that is going and deletes what it wrote. A run that has ended is left alone:
## the stage of a finished one may already be what the journal points at.
##
## Returns whether no part of a cancelled run is left; [code]true[/code] when no run was going.
func cancel() -> bool:
	if _state != RUNNING:
		return true
	_close_reader()
	_state = IDLE
	UpdateFolder.log_line("stage cancelled", _update_folder)
	return FolderFiles.remove_tree(_stage)


# Why the entry `relative_path` was not written, or an empty string when it was.
func _write_entry(relative_path: String) -> String:
	var bytes := ReleaseArchive.read_file(_reader, relative_path)
	if ContentHash.of_bytes(bytes) != str(_tree[relative_path]):
		return "the archive's %s does not match its file list" % relative_path
	if not FolderFiles.write_checked(_stage.path_join(relative_path), bytes):
		return "could not write %s to the stage" % relative_path
	return ""


# The delete's result goes unread: the next begin refuses when that stage still will not go.
func _fail(reason: String) -> Dictionary:
	_close_reader()
	_state = FAILED
	_reason = reason
	FolderFiles.remove_tree(_stage)
	UpdateFolder.log_line("stage failed: %s" % reason, _update_folder)
	return _outcome()


func _close_reader() -> void:
	if _reader != null:
		_reader.close()
		_reader = null


func _outcome() -> Dictionary:
	return {"state": _state, "reason": _reason, "written": _next_file, "total": _files.size()}
