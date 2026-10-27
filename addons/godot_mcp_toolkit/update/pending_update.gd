@tool
extends RefCounted
## The record of an update in progress, kept in [code]user://[/code] beside its files.
##
## One record per project and machine, at [code]<folder>/pending_update.json[/code],
## where [code]<folder>[/code] is [constant FOLDER] unless a test passes another. Its
## [code]state[/code] moves [constant VERIFIED] (the manifest and its signature are
## kept) → [constant STAGED] (the zip too; the editor's next exit applies it) → one
## of [constant APPLIED], [constant ROLLED_BACK] or [constant NOT_APPLIED], which the
## next start reports and then deletes with the files.[br]
## [br]
## Shape: [code]{"format": 1, "state": "…", "version": "X.Y.Z", "from_version": "X.Y.Z",
## "compatible_server": "X.Y.Z", "changed_files": [...], "reason": "…"}[/code]; a
## missing field reads as empty.

# Direct preloads, not core/modules.gd: the aggregator preloads this file.
const UserJsonStore := preload("res://addons/godot_mcp_toolkit/paths/user_json_store.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/update/folder_files.gd")

## Where updates are kept: the record, one subfolder per version, the backup and the
## install log.
const FOLDER := "user://addons/godot_mcp_toolkit/update"

const FORMAT := 1

const VERIFIED := "verified"
const STAGED := "staged"
const APPLIED := "applied"
const ROLLED_BACK := "rolled_back"
const NOT_APPLIED := "not_applied"

const _RECORD_FILE := "pending_update.json"
const _LOG_FILE := "install.log"
const _BACKUP_FOLDER := "backup"
const _STRING_FIELDS := ["state", "version", "from_version", "compatible_server", "reason"]


## The record in [param folder], every field present: an empty [code]state[/code]
## when there is no record, it does not read, or a newer toolkit wrote it in a newer
## [code]format[/code].
static func read(folder: String = FOLDER) -> Dictionary:
	var record := {"state": "", "version": "", "from_version": "", "compatible_server": "",
			"reason": "", "changed_files": PackedStringArray()}
	var path := folder.path_join(_RECORD_FILE)
	if not FileAccess.file_exists(path):
		return record
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		return record
	var stored: Dictionary = json.data
	var format: Variant = stored.get("format", null)
	if not (format is float or format is int) or int(format) != FORMAT:
		return record
	for field in _STRING_FIELDS:
		var value: Variant = stored.get(field, "")
		if value is String:
			record[field] = str(value)
	var changed := PackedStringArray()
	var stored_changed: Variant = stored.get("changed_files", [])
	if stored_changed is Array:
		for path_value in stored_changed:
			if path_value is String:
				changed.append(str(path_value))
	record["changed_files"] = changed
	return record


## Writes [param record] (the shape [method read] returns) into [param folder].
static func write(record: Dictionary, folder: String = FOLDER) -> Error:
	var stored := {"format": FORMAT}
	for field in _STRING_FIELDS:
		stored[field] = str(record.get(field, ""))
	stored["changed_files"] = Array(record.get("changed_files", PackedStringArray()))
	return UserJsonStore.write(folder.path_join(_RECORD_FILE), stored, "\t")


## Deletes the record and every update file in [param folder], the backup too unless
## [param keep_backup]. The install log stays.
static func clear(folder: String = FOLDER, keep_backup: bool = false) -> void:
	var absolute := ProjectSettings.globalize_path(folder)
	if not DirAccess.dir_exists_absolute(absolute):
		return
	var dir := DirAccess.open(absolute)
	if dir == null:
		return
	dir.include_hidden = true
	for name in dir.get_files():
		if name != _LOG_FILE:
			DirAccess.remove_absolute(absolute.path_join(name))
	for name in dir.get_directories():
		if not (keep_backup and name == _BACKUP_FOLDER):
			FolderFiles.remove_tree(absolute.path_join(name))


## The folder that holds the files of [param version] in [param folder].
static func version_folder(version: String, folder: String = FOLDER) -> String:
	return folder.path_join(version)


## The folder that holds the copy of the installed toolkit an apply makes first.
static func backup_folder(folder: String = FOLDER) -> String:
	return folder.path_join(_BACKUP_FOLDER)


## Appends [param line], stamped with the time, to the install log in [param folder].
static func log_line(line: String, folder: String = FOLDER) -> void:
	var path := folder.path_join(_LOG_FILE)
	var absolute_folder := ProjectSettings.globalize_path(folder)
	if not DirAccess.dir_exists_absolute(absolute_folder):
		DirAccess.make_dir_recursive_absolute(absolute_folder)
	var file := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	file.store_line("%s %s" % [Time.get_datetime_string_from_system(), line])
	file.close()


## The install log's path in [param folder], as the user would open it.
static func log_path(folder: String = FOLDER) -> String:
	return ProjectSettings.globalize_path(folder.path_join(_LOG_FILE))

