@tool
extends RefCounted
## Reads a release zip and checks its layout before any of it is written.
##
## A release zip's files sit in the addon folder, and are exactly the ones the file list
## inside it names. The checks run on the zip the manifest pinned, so they guard against a
## broken build rather than an attacker: an entry outside the folder, an absolute path or a
## [code]..[/code] segment, a name that would land elsewhere or nowhere on Windows, a name
## that hides the addon from the engine or from version control, a file twice, a missing
## [code]plugin.cfg[/code] or list, or a [code]plugin.cfg[/code] that names another
## version.[br]
## [br]
## Nothing is written from a folder entry, and a list that names one is refused. Tools
## differ in writing them: one per folder, none, or, with [ZIPPacker] from 4.7, one twice
## when the caller writes it too. So a folder entry may repeat or be absent, and the name
## rules and the cap still hold it.[br]
## [br]
## The entry count is capped because the checks read every name, a folder entry's included.
## Nothing caps an entry's size: [ZIPReader] shows no size before
## [method ZIPReader.read_file] allocates it, and only a signed zip gets this far.[br]
## [br]
## An installed copy of these rules reads every later release, so a release that breaks
## one is refused by every older toolkit, and breaking one on purpose needs a bridge
## release first.

# Direct preloads, not core/modules.gd: the aggregator preloads the installer,
# which reaches this file.
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")
const ReleaseFileList := preload("res://addons/godot_mcp_toolkit/self_update/release_file_list.gd")

## The addon folder inside a release zip, with its trailing slash.
const ADDON_PREFIX := "addons/godot_mcp_toolkit/"

## The most entries, folders included, a release zip may hold.
const MAX_ENTRIES := 5000

const _ADDONS_ENTRY := "addons/"
const _PLUGIN_CONFIG := "plugin.cfg"
# A .gdignore at the addon root makes the engine's scanner skip the whole addon, and the
# other two hide it from version control. Deeper down each only hides its own folder, so a
# release may ship one there.
const _ADDON_ROOT_REFUSED := [".gdignore", ".gitignore", ".p4ignore"]
# The scanner skips any folder that holds this file.
const _PROJECT_FILE := "project.godot"
# Windows opens these as devices, whatever follows the first dot, and in any letter case.
const _WINDOWS_DEVICE_NAMES := [
	"CON", "PRN", "AUX", "NUL",
	"COM0", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "COM¹", "COM²", "COM³",
	"LPT0", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "LPT¹", "LPT²", "LPT³",
]
const _DIGITS := "0123456789"


## Checks the zip at [param archive_path] for the release [param expected_version].
##
## Returns what [method inspect_open] returns, or its [code]error[/code] when the zip does
## not open.
static func inspect(archive_path: String, expected_version: String) -> Dictionary:
	var reader := ZIPReader.new()
	if reader.open(archive_path) != OK:
		return {"error": "the archive is not a readable zip"}
	var result := inspect_open(reader, expected_version)
	reader.close()
	return result


## [method inspect] on a zip [param reader] the caller opened and closes.
##
## Returns a dictionary whose [code]error[/code] is empty when the zip holds, with
## [code]files[/code], the addon's files as paths relative to the addon folder in zip
## order, and [code]list[/code], the bytes of the file list inside it. Otherwise
## [code]error[/code] names the first rule broken.
static func inspect_open(reader: ZIPReader, expected_version: String) -> Dictionary:
	var entries := reader.get_files()
	if entries.size() > MAX_ENTRIES:
		return {"error": "the archive holds %d entries, more than %d" % [entries.size(), MAX_ENTRIES]}
	var files := PackedStringArray()
	var seen := {}
	var spellings := {}
	for entry: String in entries:
		var reason := entry_problem(entry)
		var is_folder := entry.ends_with("/")
		if reason.is_empty() and not is_folder and seen.has(entry):
			reason = "the archive holds an entry twice: %s" % entry
		if reason.is_empty():
			reason = _case_collision(entry, spellings)
		if not reason.is_empty():
			return {"error": reason}
		if is_folder:
			continue
		seen[entry] = true
		files.append(entry.substr(ADDON_PREFIX.length()))
	if not files.has(_PLUGIN_CONFIG):
		return {"error": "the archive has no plugin.cfg"}
	var config := ConfigFile.new()
	if config.parse(reader.read_file(ADDON_PREFIX + _PLUGIN_CONFIG).get_string_from_utf8()) != OK:
		return {"error": "the archive's plugin.cfg does not read"}
	var version := str(config.get_value("plugin", "version", ""))
	var wanted := UpdateCheck.parse_version(expected_version)
	if wanted.is_empty() or UpdateCheck.parse_version(version) != wanted:
		return {"error": "the archive's plugin.cfg names version %s, not %s" % [version, expected_version]}
	return _with_list(reader, files)


## Why the zip entry [param entry] may not be written, or an empty string when it may.
static func entry_problem(entry: String) -> String:
	if entry == _ADDONS_ENTRY or entry == ADDON_PREFIX:
		return ""
	if entry.is_empty() or entry.begins_with("/") or entry.contains("\\") or entry.contains(":"):
		return "the archive holds an absolute or malformed path: %s" % entry
	if not entry.begins_with(ADDON_PREFIX):
		return "the archive holds a path outside the addon folder: %s" % entry
	for segment: String in entry.trim_suffix("/").split("/"):
		if segment.is_empty() or segment == "." or segment == "..":
			return "the archive holds a path with an empty, . or .. segment: %s" % entry
	var relative := entry.substr(ADDON_PREFIX.length()).trim_suffix("/")
	if _ADDON_ROOT_REFUSED.has(relative.to_lower()):
		return "the archive holds an ignore file at the addon root: %s" % entry
	for segment: String in relative.split("/"):
		if segment.to_lower() == _PROJECT_FILE:
			return "the archive holds a %s: %s" % [_PROJECT_FILE, entry]
		if _is_windows_alias(segment):
			return "the archive holds a name Windows would change or refuse: %s" % entry
	return ""


## The bytes of the addon file [param relative_path] in the open zip [param reader].
static func read_file(reader: ZIPReader, relative_path: String) -> PackedByteArray:
	return reader.read_file(ADDON_PREFIX + relative_path)


# Whether Windows opens something other than a file of this exact name: a trailing dot or
# space it drops, an 8.3 short name it expands, or a device.
static func _is_windows_alias(segment: String) -> bool:
	if segment.ends_with(".") or segment.ends_with(" "):
		return true
	var tilde := segment.find("~")
	while tilde != -1:
		if tilde + 1 < segment.length() and _DIGITS.contains(segment[tilde + 1]):
			return true
		tilde = segment.find("~", tilde + 1)
	var strip_left := false
	var strip_right := true
	return _WINDOWS_DEVICE_NAMES.has(segment.get_slice(".", 0).strip_edges(strip_left, strip_right).to_upper())


# Why `entry` differs only in case from a path in `spellings`, which it joins. A folder
# counts: Core/a.gd and core/b.gd are one folder on Windows and two on Linux, so the same
# zip would stage differently.
static func _case_collision(entry: String, spellings: Dictionary) -> String:
	var path := ""
	for segment: String in entry.trim_suffix("/").split("/"):
		path = path.path_join(segment) if not path.is_empty() else segment
		var folded := path.to_lower()
		if str(spellings.get(folded, path)) != path:
			return "the archive holds names that differ only in letter case: %s, %s" % [spellings[folded], path]
		spellings[folded] = path
	return ""


# The result for a zip whose names hold: the list's bytes when its lines name exactly
# `files`, the list itself left out; otherwise why not.
static func _with_list(reader: ZIPReader, files: PackedStringArray) -> Dictionary:
	if not files.has(ReleaseFileList.FILE_NAME):
		return {"error": "the staged archive has no file list this version can read"}
	var list_bytes := read_file(reader, ReleaseFileList.FILE_NAME)
	var listed := ReleaseFileList.parse(list_bytes.get_string_from_utf8())
	if listed.is_empty():
		return {"error": "the staged archive has no file list this version can read"}
	var held := {}
	for file: String in files:
		if file != ReleaseFileList.FILE_NAME:
			held[file] = true
			if not listed.has(file):
				return {"error": "the archive holds %s, which its file list does not name" % file}
	for path: String in listed:
		if not held.has(path):
			return {"error": "the archive's file list names %s, which it does not hold" % path}
	return {"error": "", "files": files, "list": list_bytes}
