@tool
extends RefCounted
## The recovery plugin's reader of the update journal, and its decision on what to do.
##
## The recovery plugin runs from a copy outside the addon folder, at a start where that
## folder may not load, so this file loads nothing from it: it reads
## [code]journal.json[/code] (format 1), [code]plugin.cfg[/code] and the stage's file list
## with its own code. That repeats rules [code]update_journal.gd[/code],
## [code]update_applier.gd[/code] and [code]release_file_list.gd[/code] hold, and a unit
## test pins the reader to [code]update_journal.gd[/code]. Every function is static and
## changes nothing on disk.

## [method decide]'s [code]action[/code]: do nothing.
const NONE := "none"
## [method decide]'s [code]action[/code]: ask again after [code]seconds[/code].
const WAIT := "wait"
## [method decide]'s [code]action[/code]: move the stage into place.
const ROLL_FORWARD := "roll_forward"
## [method decide]'s [code]action[/code]: move the backup into place.
const ROLL_BACK := "roll_back"
## [method decide]'s [code]action[/code]: replace the live folder with the backup.
const RESTORE := "restore"
## [method decide]'s [code]action[/code]: end a restore whose backup is already the live
## folder, by deleting [code]broken-<to>[/code] and recording the journal restored.
const FINISH_RESTORE := "finish_restore"
## [method decide]'s [code]action[/code]: take the recovery plugin out.
const REMOVE_SELF := "remove_self"
## [method decide]'s [code]action[/code]: show the manual steps.
const MANUAL := "manual"

const _FORMAT := 1
const _JOURNAL_FILE := "journal.json"
const _FILE_LIST := "release_files.sha256"
const _BACKUP_PREFIX := "backup-"
const _APPLYING := "applying"
const _APPLIED := "applied"
const _STATES := ["verified", "staged", _APPLYING, _APPLIED, "not_applied"]
const _VERSION_PATTERN := "^v?(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)$"
# An applying journal younger than this, or up to this far in the future, may belong to an
# apply still running in an editor that is closing, so it is left alone until it ages past it.
const _APPLY_WINDOW_SEC := 60
# Runs that export, quit by themselves or run a script are no session a user watches: a
# move there would happen under the run, and its dialog would wait for nobody.
const _ONE_SHOT_ARGUMENTS := ["--quit", "--quit-after", "--script", "-s", "--import"]
const _ONE_SHOT_PREFIX := "--export"


## The journal in [param update_folder], read as [code]update_journal.gd[/code] reads it.
##
## Returns [code]{"state", "from", "to", "backup", "expected_tree_hash"}[/code], all
## strings, plus [code]applying_at[/code] (an int) and [code]restored[/code]
## ([code]true[/code]) only when the journal holds them. [code]state[/code] is empty when
## there is no journal or it cannot be trusted, by the same tests
## [code]update_journal.gd[/code] makes.
static func read(update_folder: String) -> Dictionary:
	var path := update_folder.path_join(_JOURNAL_FILE)
	if not FileAccess.file_exists(path):
		return _no_journal()
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		return _no_journal()
	var stored: Dictionary = json.data
	var format: Variant = stored.get("format", null)
	if not (format is float or format is int) or int(format) != _FORMAT:
		return _no_journal()
	if not _STATES.has(stored.get("state", null)):
		return _no_journal()
	var from_version: Variant = stored.get("from", null)
	var to_version: Variant = stored.get("to", null)
	var backup: Variant = stored.get("backup", "")
	if not _is_version(from_version) or not _is_version(to_version):
		return _no_journal()
	if not (backup is String and (str(backup).is_empty() or str(backup) == _BACKUP_PREFIX + str(from_version))):
		return _no_journal()

	var record := _no_journal()
	record["state"] = str(stored["state"])
	record["from"] = str(from_version)
	record["to"] = str(to_version)
	record["backup"] = str(backup)
	var tree_hash: Variant = stored.get("expected_tree_hash", "")
	if tree_hash is String:
		record["expected_tree_hash"] = str(tree_hash)
	var applying_at: Variant = stored.get("applying_at", null)
	if (applying_at is float or applying_at is int) and int(applying_at) >= 0:
		record["applying_at"] = int(applying_at)
	var restored: Variant = stored.get("restored", false)
	if restored is bool and bool(restored):
		record["restored"] = true
	return record


## The version the [code]plugin.cfg[/code] at [param cfg_path] names, or an empty string
## when it cannot be read.
static func plugin_version(cfg_path: String) -> String:
	var config := ConfigFile.new()
	if config.load(cfg_path) != OK:
		return ""
	return str(config.get_value("plugin", "version", ""))


## What the recovery plugin does about [param journal] (the shape [method read] returns)
## at the Unix time [param now].
##
## [param facts] describes the editor: [code]stays_out[/code] (what [method stays_out]
## says), [code]toolkit_enabled[/code], [code]addon_present[/code] (the toolkit's folder
## exists), [code]live_version[/code] (its [code]plugin.cfg[/code] version, empty when
## unreadable), [code]backup_present[/code] (the journal's backup folder exists),
## [code]stage_whole[/code] (what [method stage_matches] says) and
## [code]broken_present[/code] (the journal's [code]broken-<to>[/code] folder exists), all
## bools but the version. A missing [code]stays_out[/code] or [code]toolkit_enabled[/code]
## reads as true, so the answer is [constant NONE].[br]
## [br]
## It acts only on an [code]applying[/code] journal more than 60 s old or more than 60 s
## ahead, or an [code]applied[/code] one, in an editor it does not stay out of where the
## toolkit is not enabled. With the toolkit's folder gone, an [code]applying[/code] journal
## rolls the whole stage forward, else the backup back, and an [code]applied[/code] one
## restores from the backup. With the folder present, either state restores only over the
## version it was going [code]to[/code]. Over the version it came [code]from[/code] beside
## [code]broken-<to>[/code], either state finishes the restore; without that folder, an
## [code]applying[/code] journal is left to the toolkit's own settle and an
## [code]applied[/code] one gives the manual steps. Over anything else the answer is the
## manual steps. Any other journal, or none, takes the recovery plugin out once the
## toolkit's folder is gone. With nothing to move into place, the answer is the manual
## steps.[br]
## [br]
## Returns [code]{"action": String, "seconds": int}[/code]: one of the action constants,
## and for [constant WAIT] the seconds until the journal leaves the 60 s window, else 0.
static func decide(journal: Dictionary, facts: Dictionary, now: int) -> Dictionary:
	if bool(facts.get("stays_out", true)) or bool(facts.get("toolkit_enabled", true)):
		return _verdict(NONE)
	var state := str(journal.get("state", ""))
	var addon_present := bool(facts.get("addon_present", true))
	if state != _APPLYING and state != _APPLIED:
		return _verdict(NONE if addon_present else REMOVE_SELF)
	if state == _APPLYING:
		var seconds := _seconds_to_wait(journal, now)
		if seconds > 0:
			return {"action": WAIT, "seconds": seconds}
		if not addon_present and bool(facts.get("stage_whole", false)):
			return _verdict(ROLL_FORWARD)
		if not addon_present:
			return _verdict(ROLL_BACK if bool(facts.get("backup_present", false)) else MANUAL)
	return _verdict(_restore_or_not(journal, facts, addon_present))


## Whether the recovery plugin stays out of this editor: [param headless], or
## [param arguments] (the engine's command line) holding [code]--export…[/code],
## [code]--quit[/code], [code]--quit-after[/code], [code]--script[/code]
## ([code]-s[/code]) or [code]--import[/code]. Only the export flags come as a family, so
## only they match by prefix.
static func stays_out(headless: bool, arguments: PackedStringArray) -> bool:
	if headless:
		return true
	for argument: String in arguments:
		if argument.begins_with(_ONE_SHOT_PREFIX) or _ONE_SHOT_ARGUMENTS.has(argument):
			return true
	return false


## Whether the folder [param stage_folder] (absolute) is the release the journal's
## [param expected_tree_hash] names: its [code]release_files.sha256[/code] hashes to it,
## every file the list names hashes to its line, and no other file is there, hidden ones
## included. An empty hash or a damaged list never matches.
static func stage_matches(stage_folder: String, expected_tree_hash: String) -> bool:
	var list_path := stage_folder.path_join(_FILE_LIST)
	if expected_tree_hash.is_empty() or not FileAccess.file_exists(list_path):
		return false
	var list_bytes := FileAccess.get_file_as_bytes(list_path)
	if _sha256(list_bytes) != expected_tree_hash:
		return false
	var tree := _parse_list(list_bytes.get_string_from_utf8())
	if tree.is_empty():
		return false
	tree[_FILE_LIST] = expected_tree_hash
	return _hashes(stage_folder) == tree


static func _no_journal() -> Dictionary:
	return {"state": "", "from": "", "to": "", "backup": "", "expected_tree_hash": ""}


static func _verdict(action: String) -> Dictionary:
	return {"action": action, "seconds": 0}


static func _is_version(value: Variant) -> bool:
	if not value is String:
		return false
	var regex := RegEx.new()
	regex.compile(_VERSION_PATTERN)
	return regex.search(str(value).strip_edges()) != null


# A journal with no applying time comes from no 1.2.0 applier, so no apply is known to run.
static func _seconds_to_wait(journal: Dictionary, now: int) -> int:
	if not journal.has("applying_at"):
		return 0
	var age := now - int(journal["applying_at"])
	if age > _APPLY_WINDOW_SEC or age < -_APPLY_WINDOW_SEC:
		return 0
	return _APPLY_WINDOW_SEC + 1 - age


# The live folder is put back only over the version that did not load: over the version
# it came from there is at most a restore to finish, and over any other the journal is not
# about it.
static func _restore_or_not(journal: Dictionary, facts: Dictionary, addon_present: bool) -> String:
	var backup_present := bool(facts.get("backup_present", false))
	if not addon_present:
		return RESTORE if backup_present else MANUAL
	var live_version := str(facts.get("live_version", ""))
	if live_version == str(journal.get("from", "")):
		return _after_restore(journal, facts)
	if live_version == str(journal.get("to", "")) and backup_present:
		return RESTORE
	return MANUAL


# The version the journal came from is live. Beside broken-<to>, a restore stopped after its
# backup moved in. Without it, an applying journal is the toolkit's own settle's to read,
# and an applied one says the new version went in, which nothing here can square.
static func _after_restore(journal: Dictionary, facts: Dictionary) -> String:
	if bool(facts.get("broken_present", false)):
		return FINISH_RESTORE
	return NONE if str(journal.get("state", "")) == _APPLYING else MANUAL


static func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	# update() refuses an empty buffer with an engine error; finish() alone yields the
	# empty input's digest.
	if not bytes.is_empty():
		context.update(bytes)
	return context.finish().hex_encode()


# The list as path to SHA-256, or empty when any line is not a lowercase SHA-256, two
# spaces and a relative path with no ":" (an NTFS stream), so a damaged list is never
# half used.
static func _parse_list(text: String) -> Dictionary:
	var entries := {}
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges(false, true)
		if line.is_empty():
			continue
		var digest := line.substr(0, 64)
		var path := line.substr(66)
		if line.length() < 67 or line.substr(64, 2) != "  " or not _is_hex_digest(digest):
			return {}
		if path.begins_with("/") or path.contains("\\") or path.contains(":") or ".." in path.split("/"):
			return {}
		entries[path] = digest
	return entries


static func _is_hex_digest(text: String) -> bool:
	if text.length() != 64:
		return false
	for character in text:
		if "0123456789abcdef".find(character) < 0:
			return false
	return true


# Every file under [param folder], hidden ones included, mapped to its SHA-256; an
# unreadable file maps to an empty string.
static func _hashes(folder: String) -> Dictionary:
	var result := {}
	_collect_hashes(folder, "", result)
	return result


static func _collect_hashes(base: String, relative: String, result: Dictionary) -> void:
	var dir := DirAccess.open(base.path_join(relative) if not relative.is_empty() else base)
	if dir == null:
		return
	dir.include_hidden = true
	for file_name in dir.get_files():
		var path := relative.path_join(file_name) if not relative.is_empty() else file_name
		var file := FileAccess.open(base.path_join(path), FileAccess.READ)
		if file == null:
			result[path] = ""
			continue
		result[path] = _sha256(file.get_buffer(file.get_length()))
		file.close()
	for folder_name in dir.get_directories():
		_collect_hashes(base, relative.path_join(folder_name) if not relative.is_empty() else folder_name, result)
