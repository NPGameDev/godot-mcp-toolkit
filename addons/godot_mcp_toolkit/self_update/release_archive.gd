@tool
extends RefCounted
## Reads a release zip and checks its layout before any of it is written.
##
## A release zip holds [code]addons/[/code] and the addon folder under it, and nothing
## else. The checks run on the zip the manifest pinned, so they guard against a
## broken build rather than an attacker: an entry outside the folder, an absolute
## path or a [code]..[/code] segment, a missing [code]plugin.cfg[/code], or a
## [code]plugin.cfg[/code] that names another version.

# Direct preload, not core/modules.gd: the aggregator preloads this file.
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")

## The addon folder inside a release zip, with its trailing slash.
const ADDON_PREFIX := "addons/godot_mcp_toolkit/"

const _ADDONS_ENTRY := "addons/"
const _PLUGIN_CONFIG := "plugin.cfg"


## Checks the zip at [param archive_path] for the release [param expected_version].
##
## Returns a dictionary whose [code]error[/code] is empty when the zip holds, with
## [code]files[/code], the addon's files as paths relative to the addon folder in
## zip order. Otherwise [code]error[/code] names the first rule broken.
static func inspect(archive_path: String, expected_version: String) -> Dictionary:
	var reader := ZIPReader.new()
	if reader.open(archive_path) != OK:
		return {"error": "the archive is not a readable zip"}
	var result := inspect_open(reader, expected_version)
	reader.close()
	return result


## [method inspect] on a zip [param reader] the caller opened and closes.
static func inspect_open(reader: ZIPReader, expected_version: String) -> Dictionary:
	var files := PackedStringArray()
	for entry in reader.get_files():
		var reason := entry_problem(entry)
		if not reason.is_empty():
			return {"error": reason}
		if entry.ends_with("/"):
			continue
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
	return {"error": "", "files": files}


## Why the zip entry [param entry] may not be written, or an empty string when it may.
static func entry_problem(entry: String) -> String:
	if entry == _ADDONS_ENTRY or entry == ADDON_PREFIX:
		return ""
	if entry.is_empty() or entry.begins_with("/") or entry.contains("\\") or entry.contains(":"):
		return "the archive holds an absolute or malformed path: %s" % entry
	if not entry.begins_with(ADDON_PREFIX):
		return "the archive holds a path outside the addon folder: %s" % entry
	for segment in entry.trim_suffix("/").split("/"):
		if segment.is_empty() or segment == "." or segment == "..":
			return "the archive holds a path with an empty, . or .. segment: %s" % entry
	return ""


## The bytes of the addon file [param relative_path] in the open zip [param reader].
static func read_file(reader: ZIPReader, relative_path: String) -> PackedByteArray:
	return reader.read_file(ADDON_PREFIX + relative_path)
