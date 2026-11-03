@tool
extends RefCounted
## The update journal: the one source of truth for an update in progress.
##
## It lives at [code]journal.json[/code] in the update folder (see
## [code]update_folder.gd[/code]). Its [code]state[/code] moves [constant VERIFIED] (the
## manifest and its signature are kept) → [constant STAGED] (the release is unpacked; the
## editor's next exit swaps it in) → [constant APPLYING] (the swap has begun) → one of
## [constant APPLIED] or [constant NOT_APPLIED], which the next start settles.[br]
## [br]
## Shape: [code]{"format": 1, "state": "…", "from": "X.Y.Z", "to": "X.Y.Z",
## "backup": "backup-X.Y.Z", "expected_tree_hash": "…", "compatible_server": "X.Y.Z",
## "changed_files": [...], "reason": "…", "attempts": N}[/code]. [code]"restaged": true[/code]
## joins them only after the one re-stage a stage that did not match gets; a later mismatch
## then gives up.[br]
## [br]
## One version's code writes this file and the next version's reads it, so the keys only
## grow and [constant FORMAT] stays; raising it needs a bridge release first. Unknown keys
## are ignored. With the editor's safe save off, a kill mid-write leaves text that does
## not parse, which reads as no journal.

# Direct preloads, not core/modules.gd: the aggregator preloads this file.
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")

const FORMAT := 1

const VERIFIED := "verified"
const STAGED := "staged"
const APPLYING := "applying"
const APPLIED := "applied"
const NOT_APPLIED := "not_applied"

const _FILE_NAME := "journal.json"
const _STATES := [VERIFIED, STAGED, APPLYING, APPLIED, NOT_APPLIED]
# The fields no path is built from: a wrong type reads as empty and the journal stands.
const _PLAIN_TEXT_FIELDS := ["expected_tree_hash", "compatible_server", "reason"]
# Every field written as text.
const _TEXT_FIELDS := ["state", "from", "to", "backup", "expected_tree_hash", "compatible_server", "reason"]


## The journal in [param folder], every field present.
##
## Returns the shape in the class description without [code]format[/code], with an empty
## [code]state[/code] when there is no journal or it cannot be trusted: it does not parse,
## it has another [code]format[/code], its state is not one this version knows, or one of
## the fields paths are built from is off: [code]from[/code] or [code]to[/code] is not a
## version, or [code]backup[/code] is neither empty nor the backup name of
## [code]from[/code].
static func read(folder: String = UpdateFolder.FOLDER) -> Dictionary:
	var path := folder.path_join(_FILE_NAME)
	if not FileAccess.file_exists(path):
		return _no_journal()
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		return _no_journal()
	var stored: Dictionary = json.data
	var format: Variant = stored.get("format", null)
	if not (format is float or format is int) or int(format) != FORMAT:
		return _no_journal()
	if not _STATES.has(stored.get("state", null)):
		return _no_journal()
	var from_version: Variant = stored.get("from", null)
	var to_version: Variant = stored.get("to", null)
	var backup: Variant = stored.get("backup", "")
	if not _is_version(from_version) or not _is_version(to_version):
		return _no_journal()
	if not (backup is String and (str(backup).is_empty() or str(backup) == UpdateFolder.backup_name(str(from_version)))):
		return _no_journal()

	var record := _no_journal()
	record["state"] = str(stored["state"])
	record["from"] = str(from_version)
	record["to"] = str(to_version)
	record["backup"] = str(backup)
	for field: String in _PLAIN_TEXT_FIELDS:
		var value: Variant = stored.get(field, "")
		if value is String:
			record[field] = str(value)
	var attempts: Variant = stored.get("attempts", 0)
	if (attempts is float or attempts is int) and int(attempts) > 0:
		record["attempts"] = int(attempts)
	var restaged: Variant = stored.get("restaged", false)
	if restaged is bool and bool(restaged):
		record["restaged"] = true
	var changed := PackedStringArray()
	var stored_changed: Variant = stored.get("changed_files", [])
	if stored_changed is Array:
		for path_value: Variant in stored_changed:
			if path_value is String:
				changed.append(str(path_value))
	record["changed_files"] = changed
	return record


## Writes [param record] (the shape [method read] returns) into [param folder] and reads
## it back. Returns whether the file now holds it.
static func write(record: Dictionary, folder: String = UpdateFolder.FOLDER) -> bool:
	var stored := {"format": FORMAT}
	for field: String in _TEXT_FIELDS:
		stored[field] = str(record.get(field, ""))
	stored["changed_files"] = Array(record.get("changed_files", PackedStringArray()))
	stored["attempts"] = int(record.get("attempts", 0))
	if bool(record.get("restaged", false)):
		stored["restaged"] = true
	var path := ProjectSettings.globalize_path(folder).path_join(_FILE_NAME)
	return FolderFiles.write_checked(path, JSON.stringify(stored, "\t").to_utf8_buffer())


## Deletes the journal and every folder in [param folder] that is not an update backup.
## The backups, the ignore files and the install log stay.[br]
## [br]
## The journal goes last, so a kill in the middle leaves a journal the next start clears
## again rather than files nothing points at.
static func clear(folder: String = UpdateFolder.FOLDER) -> void:
	var absolute := ProjectSettings.globalize_path(folder)
	for folder_name in UpdateFolder.subfolders(folder):
		if not UpdateFolder.is_backup_name(folder_name):
			FolderFiles.remove_tree(absolute.path_join(folder_name))
	DirAccess.remove_absolute(absolute.path_join(_FILE_NAME))


static func _no_journal() -> Dictionary:
	return {"state": "", "from": "", "to": "", "backup": "", "expected_tree_hash": "",
			"compatible_server": "", "reason": "", "attempts": 0, "changed_files": PackedStringArray()}


static func _is_version(value: Variant) -> bool:
	return value is String and not UpdateCheck.parse_version(str(value)).is_empty()
