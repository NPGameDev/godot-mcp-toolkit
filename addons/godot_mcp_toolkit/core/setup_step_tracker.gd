@tool
extends RefCounted
## The setup step tracker: records which setup steps this project's user has seen.
##
## The only reader and writer of the seen-steps file,
## [code]user://addons/godot_mcp_toolkit/mcp_onboarding_shown_v001[/code]. The file
## keeps the name the 1.0 toolkit gave its "wizard done" flag, so a 1.0.x build,
## which only checks that the file exists, still treats the wizard as done after a
## downgrade.[br]
## [br]
## The content is a versioned JSON object, [code]{"format": 1, "seen": [...]}[/code].
## [code]format[/code] goes up only for a breaking change; new fields are added
## under the same number, and every rewrite keeps the top-level keys and step ids
## this build does not know. Reading never fails:[br]
## - the 1.0 content [code]1[/code] reads as the 1.0 steps (welcome, mcp_json, dock);[br]
## - a supported [code]format[/code] reads its [code]seen[/code] list, keeping only
##   ids made of [code]a-z[/code], [code]0-9[/code] and [code]_[/code];[br]
## - a newer [code]format[/code] (a downgraded toolkit) reads [code]seen[/code] when
##   it is still a list of strings and counts every step as seen when it is not, and
##   the file is never written, so newer data is never lost and a downgrade never
##   nags;[br]
## - an empty, corrupt, unreadable or oversized file reads as the 1.0 steps and is
##   rewritten in the current format at the next record.[br]
## Bad content prints nothing.[br]
## [br]
## With no file, a 1.0 progress file left by a wizard closed mid-run counts its
## steps before the saved index as seen. The first record folds it into the
## seen-steps file and deletes it; it is never written.

const SetupSteps := preload("res://addons/godot_mcp_toolkit/core/setup_steps.gd")
# Direct preload, not core/modules.gd: the aggregator preloads this file.
const UserJsonStore := preload("res://addons/godot_mcp_toolkit/paths/user_json_store.gd")

## The seen-steps file.
const FLAG_PATH := "user://addons/godot_mcp_toolkit/mcp_onboarding_shown_v001"
## The 1.0 wizard's resume file: the index of the step it was on.
const LEGACY_PROGRESS_PATH := "user://addons/godot_mcp_toolkit/mcp_onboarding_progress"
## The file format this build reads and writes.
const FORMAT := 1
## A larger file is treated as corrupt rather than read.
const MAX_FILE_BYTES := 64 * 1024

const _KEY_FORMAT := "format"
const _KEY_SEEN := "seen"
# The 1.0 wizard's steps, in its order; a "1" flag means all three were seen.
const _LEGACY_STEPS := [&"welcome", &"mcp_json", &"dock"]

# The files the tracker reads and writes. Units point them at scratch files.
static var _flag_path: String = FLAG_PATH
static var _progress_path: String = LEGACY_PROGRESS_PATH
static var _id_pattern: RegEx = _compile_id_pattern()
# The steps the last read or write found seen. A rename points user:// at the new
# path before the tracker hears of it, so this is the only record of the steps seen
# at the old one.
static var _last_seen: Array[String] = []


## Point the tracker at [param flag_path] and [param progress_path] instead of the
## project's files, for tests. [method reset_file_paths] undoes it.
static func set_file_paths(flag_path: String, progress_path: String) -> void:
	_flag_path = flag_path
	_progress_path = progress_path


## Point the tracker back at the project's files.
static func reset_file_paths() -> void:
	set_file_paths(FLAG_PATH, LEGACY_PROGRESS_PATH)


## Whether the step [param step_id] has been seen.
static func has_seen(step_id: StringName) -> bool:
	var state := _read()
	return bool(state["all_seen"]) or (state["seen"] as Array).has(str(step_id))


## The ids in [param ids] not seen yet, in the given order.
static func get_unseen(ids: Array[StringName]) -> Array[StringName]:
	var state := _read()
	var unseen: Array[StringName] = []
	if bool(state["all_seen"]):
		return unseen
	var seen: Array = state["seen"]
	for step_id in ids:
		if not seen.has(str(step_id)):
			unseen.append(step_id)
	return unseen


## Record the step [param step_id] as seen.
static func mark_seen(step_id: StringName) -> void:
	var ids: Array[StringName] = [step_id]
	mark_all_seen(ids)


## Record every step in [param ids] as seen, keeping the ids already recorded.
## Does nothing when the file holds a newer format.
static func mark_all_seen(ids: Array[StringName]) -> void:
	var state := _read()
	if not bool(state["writable"]):
		return
	var seen: Array = state["seen"]
	var changed := not bool(state["current"])
	for step_id in ids:
		if not seen.has(str(step_id)):
			seen.append(str(step_id))
			changed = true
	# A failed write keeps the 1.0 progress file, the only record of the steps it
	# holds.
	if changed and not _write(seen, state["extra"]):
		return
	if FileAccess.file_exists(_progress_path):
		DirAccess.remove_absolute(_progress_path)


## Record the steps seen at the old [code]user://[/code] path at the new one, after
## a project rename moved it, so the wizard resumes there instead of starting over.
## Steps not seen at the old path stay unseen, so the consent gate stays closed for
## them.
static func migrate_flag_after_rename() -> void:
	var seen_before: Array[StringName] = []
	for step_id: String in _last_seen:
		seen_before.append(StringName(step_id))
	if not seen_before.is_empty():
		mark_all_seen(seen_before)


# The file as { seen: Array[String], all_seen, writable, current, extra }: all_seen
# when a newer format's list is unreadable, writable unless the format is newer,
# current when the content is already this format, and extra the unknown top-level
# keys a rewrite keeps. Side effect: refreshes _last_seen with the steps read, the
# record migrate_flag_after_rename replays after a rename.
static func _read() -> Dictionary:
	var state := _read_state()
	if bool(state["all_seen"]):
		_last_seen.clear()
		for step_id in SetupSteps.all_ids():
			_last_seen.append(str(step_id))
	else:
		_last_seen.assign(state["seen"] as Array)
	return state


static func _read_state() -> Dictionary:
	var state := {"seen": [], "all_seen": false, "writable": true, "current": false, "extra": {}}
	if not FileAccess.file_exists(_flag_path):
		state["seen"] = _legacy_progress_steps()
		return state
	var text := _read_text(_flag_path)
	if text.strip_edges() == "1" or text.is_empty():
		state["seen"] = _legacy_seen()
		return state
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		state["seen"] = _legacy_seen()
		return state
	var data: Dictionary = json.data
	var format_value: Variant = data.get(_KEY_FORMAT)
	if not (format_value is float or format_value is int) or int(format_value) < 1:
		state["seen"] = _legacy_seen()
		return state
	var listed: Variant = data.get(_KEY_SEEN)
	if int(format_value) > FORMAT:
		state["writable"] = false
		if _is_string_list(listed):
			state["seen"] = _valid_ids(listed)
		else:
			state["all_seen"] = true
		return state
	if not listed is Array:
		state["seen"] = _legacy_seen()
		return state
	state["seen"] = _valid_ids(listed)
	state["current"] = int(format_value) == FORMAT
	var extra := data.duplicate()
	extra.erase(_KEY_FORMAT)
	extra.erase(_KEY_SEEN)
	state["extra"] = extra
	return state


# The file's text, or "" when it cannot be opened or is over MAX_FILE_BYTES.
static func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	if file.get_length() > MAX_FILE_BYTES:
		file.close()
		return ""
	var text := file.get_as_text()
	file.close()
	return text


# The 1.0 steps before the index a 1.0 progress file saved, or none without one.
static func _legacy_progress_steps() -> Array:
	if not FileAccess.file_exists(_progress_path):
		return []
	var index := clampi(_read_text(_progress_path).strip_edges().to_int(), 0, _LEGACY_STEPS.size())
	var seen := []
	for step_id in _LEGACY_STEPS.slice(0, index):
		seen.append(str(step_id))
	return seen


static func _legacy_seen() -> Array:
	var seen := []
	for step_id in _LEGACY_STEPS:
		seen.append(str(step_id))
	return seen


static func _is_string_list(value: Variant) -> bool:
	if not value is Array:
		return false
	for entry in value:
		if not entry is String:
			return false
	return true


static func _valid_ids(listed: Array) -> Array:
	var ids := []
	for entry in listed:
		if entry is String and _id_pattern.search(entry) != null and not ids.has(entry):
			ids.append(entry)
	return ids


# A failed write is silent: the steps show again at the next editor start. Returns
# whether the store reported the file written.
static func _write(seen: Array, extra: Dictionary) -> bool:
	var data := extra.duplicate()
	data[_KEY_FORMAT] = FORMAT
	data[_KEY_SEEN] = seen
	var written := UserJsonStore.write(_flag_path, data) == OK
	if written:
		_last_seen.assign(seen)
	return written


static func _compile_id_pattern() -> RegEx:
	var pattern := RegEx.new()
	pattern.compile("^[a-z0-9_]+$")
	return pattern
