@tool
extends RefCounted
## Machine-wide, version-keyed, first-writer-wins backup of the TRUE original
## value of the global EditorSetting
## `interface/editor/unfocused_low_processor_mode_sleep_usec`.
##
## The toolkit lowers that key to keep the editor responsive while it is
## unfocused and an MCP client is connected, then restores it on the last
## disconnect. Because the live restore is in-memory, a crash (after a settings
## `save()` flushed the boost to disk) or a concurrent second editor could
## otherwise strand the global key at the boosted value — and, worse, re-read
## that boosted value as the "original" on the next launch, losing the true
## default forever (the same root bug for both the crash and the concurrent
## case: reading a boosted value as the original).
##
## This helper persists `{original, boosted}` to a sibling file in the
## machine-wide registry dir so the true original survives both a crash and a
## concurrent instance. The decision logic (`resolve_restore`,
## `should_capture_boost`) is pure and headless-unit-testable; file I/O takes an
## explicit `dir` so tests use a temp dir. Cross-instance atomicity
## (first-writer-wins) is provided by the CALLER holding the registry file lock
## around `capture_if_absent` / `delete_backup` (see mcp_server.gd) — this script
## does no locking itself, keeping it pure.
##
## File name: `unfocused_sleep_backup_<major.minor>.json` — version-keyed so two
## Godot editor versions running at once never conflate their separate
## EditorSettings.

const _FILENAME_PREFIX := "unfocused_sleep_backup_"


## "<major>.<minor>" for the running engine, used to key the backup file.
## Pass a `{major, minor}` dict to override (unit tests).
static func version_key(version_info: Dictionary = {}) -> String:
	var vi := version_info if not version_info.is_empty() else Engine.get_version_info()
	return "%d.%d" % [int(vi.get("major", 0)), int(vi.get("minor", 0))]


static func backup_path(dir: String, ver: String) -> String:
	return dir.path_join(_FILENAME_PREFIX + ver + ".json")


static func has_backup(dir: String, ver: String) -> bool:
	return FileAccess.file_exists(backup_path(dir, ver))


## Reads the backup file. Returns {} if missing or malformed, else a dict with
## int "original" and int "boosted".
static func read_backup(dir: String, ver: String) -> Dictionary:
	var path := backup_path(dir, ver)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	if not parsed.has("original") or not parsed.has("boosted"):
		return {}
	return {"original": int(parsed["original"]), "boosted": int(parsed["boosted"])}


## First-writer-wins: writes `{original, boosted}` ONLY if no backup exists yet.
## Returns true if THIS call wrote the file, false if a backup already existed
## (this instance is not the owner — it must NOT overwrite the true original, and
## must NOT re-read a possibly-boosted live value as the original). The caller
## must hold the registry lock around this for cross-instance atomicity.
static func capture_if_absent(dir: String, original: int, boosted: int, ver: String) -> bool:
	if has_backup(dir, ver):
		return false
	var f := FileAccess.open(backup_path(dir, ver), FileAccess.WRITE)
	if f == null:
		push_warning("[MCPUnfocused] cannot write backup %s (err %d)" % [
			backup_path(dir, ver), FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify({"original": original, "boosted": boosted}))
	f.close()
	return true


static func delete_backup(dir: String, ver: String) -> void:
	var path := backup_path(dir, ver)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


## Pure conflict-aware restore decision. Given the live value `current` and the
## stored backup dict, decide whether to revert the key to the original:
##   - empty/malformed backup → don't touch the key (no info to act on).
##   - current == boosted     → nobody changed it during the boost → restore original.
##   - current != boosted     → a human / another tool changed it → KEEP current.
## Returns `{"restore": bool, "value": int}`. When restore is true, `value` is the
## original to write; when false, `value` echoes `current` (no write needed).
static func resolve_restore(current: int, backup: Dictionary) -> Dictionary:
	if backup.is_empty() or not backup.has("original") or not backup.has("boosted"):
		return {"restore": false, "value": current}
	if current == int(backup["boosted"]):
		return {"restore": true, "value": int(backup["original"])}
	return {"restore": false, "value": current}


## Pure gate for `unfocused_sleep_controller.lower()`: boost only when the user opted in AND
## this instance is not already boosting (idempotent). Folds the opt-out and the
## double-boost guard into one testable predicate.
static func should_capture_boost(enabled: bool, already_active: bool) -> bool:
	return enabled and not already_active
