@tool
extends RefCounted
## The one folder the self-update keeps everything in, its layout and its ignore files.
##
## The folder sits in the project, beside the addon, so a project rename strands nothing.
## The engine's scanner, the exporter's folder walk and the Plugins list each skip a folder
## whose name starts with a dot, and the export strip covers the exporter's dependency walk;
## [code].gdignore[/code] is there for other tools.[br]
## [br]
## It holds the update journal, [code]install.log[/code], one [code]<version>/[/code]
## folder with the zip, manifest and signature, [code]stage/[/code] with the unpacked
## release, and [code]backup-<from>/[/code] with the toolkit an update replaced.[br]
## [br]
## Its own ignore files make everything in it ignored, so [code]git clean -fdX[/code] or
## [code]git stash -a[/code] can delete it at any moment: no code here assumes the folder
## survives from one call to the next.

# Direct preloads: core/modules.gd does not list this folder's scripts.
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")

## Where the self-update keeps everything.
const FOLDER := "res://addons/.godot_mcp_toolkit_update"

const _LOG_FILE := "install.log"
const _STAGE_FOLDER := "stage"
const _BACKUP_PREFIX := "backup-"

# `*` also matches the ignore file itself, so nothing in the folder is ever listed for
# adding, whatever a parent rule negates.
const _IGNORE_FILES := {".gitignore": "*\n", ".p4ignore": "*\n", ".gdignore": ""}


## Creates [param folder] when missing and writes each ignore file that is missing or
## holds anything else. Returns whether all of them now hold what they should; the
## caller refuses its step when not.
static func ensure_ignore_files(folder: String = FOLDER) -> bool:
	var absolute := ProjectSettings.globalize_path(folder)
	for file_name: String in _IGNORE_FILES:
		var path := absolute.path_join(file_name)
		var content := str(_IGNORE_FILES[file_name])
		if FileAccess.file_exists(path) and FileAccess.get_file_as_string(path) == content:
			continue
		if not FolderFiles.write_checked(path, content.to_utf8_buffer()):
			return false
	return true


## The folder that holds the zip, manifest and signature of [param version].
static func version_folder(version: String, folder: String = FOLDER) -> String:
	return folder.path_join(version)


## The path of the zip of [param version].
static func archive_path(version: String, folder: String = FOLDER) -> String:
	return version_folder(version, folder).path_join(ReleaseAssets.archive_name(version))


## The folder that holds the unpacked release until the swap.
static func stage_folder(folder: String = FOLDER) -> String:
	return folder.path_join(_STAGE_FOLDER)


## The folder name of the update backup taken over [param from_version].
static func backup_name(from_version: String) -> String:
	return _BACKUP_PREFIX + from_version


## The folder that holds the toolkit an update replaced at [param from_version].
static func backup_folder(from_version: String, folder: String = FOLDER) -> String:
	return folder.path_join(backup_name(from_version))


## Whether the folder name [param folder_name] is an update backup.
static func is_backup_name(folder_name: String) -> bool:
	return folder_name.begins_with(_BACKUP_PREFIX)


## The names of the folders directly under [param folder], empty when it does not exist.
static func subfolders(folder: String = FOLDER) -> PackedStringArray:
	var absolute := ProjectSettings.globalize_path(folder)
	if not DirAccess.dir_exists_absolute(absolute):
		return PackedStringArray()
	var dir := DirAccess.open(absolute)
	if dir == null:
		return PackedStringArray()
	dir.include_hidden = true
	return dir.get_directories()


## Deletes every update backup in [param folder]. Returns whether all of them are gone.
static func remove_backups(folder: String = FOLDER) -> bool:
	var absolute := ProjectSettings.globalize_path(folder)
	var all_gone := true
	for folder_name in subfolders(folder):
		if is_backup_name(folder_name) and not FolderFiles.remove_tree(absolute.path_join(folder_name)):
			all_gone = false
	return all_gone


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
