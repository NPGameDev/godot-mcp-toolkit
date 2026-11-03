@tool
extends RefCounted
## The list of a release's files and their SHA-256, shipped inside the addon folder.
##
## The release build writes [constant FILE_NAME] into the addon folder: one
## [code]<sha256>  <path>[/code] line per file, paths relative to the folder, sorted,
## the list itself left out. It is the format [code]sha256sum[/code] writes, so
## [code]sha256sum -c[/code] checks an installed folder. The self-update reads the
## installed folder's list to know which files a release owns: it deletes only those
## a newer release dropped, and it notices the ones changed by hand.

## The list's file name inside the addon folder.
const FILE_NAME := "release_files.sha256"

# Direct preload, not core/modules.gd: the aggregator preloads this file.
const ContentHash := preload("res://addons/godot_mcp_toolkit/update/content_hash.gd")


## Reads the list [param text] into a dictionary of path to SHA-256.
##
## Blank lines are skipped. Returns an empty dictionary when any other line is not
## a lowercase SHA-256, two spaces and a relative path, so a damaged list is never
## half used.
static func parse(text: String) -> Dictionary:
	var entries := {}
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges(false, true)
		if line.is_empty():
			continue
		var digest := line.substr(0, 64)
		var path := line.substr(66)
		if line.length() < 67 or line.substr(64, 2) != "  " or not ContentHash.is_hex_digest(digest):
			return {}
		if path.begins_with("/") or path.contains("\\") or ".." in path.split("/"):
			return {}
		entries[path] = digest
	return entries


## The list text for [param entries], a dictionary of path to SHA-256, sorted by path.
static func format(entries: Dictionary) -> String:
	var paths: Array = entries.keys()
	paths.sort()
	var lines := PackedStringArray()
	for path in paths:
		lines.append("%s  %s" % [entries[path], path])
	return "\n".join(lines) + ("\n" if not lines.is_empty() else "")


## The list of the installed addon folder at [param addon_path] (an absolute or
## [code]res://[/code] path), or an empty dictionary when it has none.
static func read_installed(addon_path: String) -> Dictionary:
	var path := addon_path.path_join(FILE_NAME)
	if not FileAccess.file_exists(path):
		return {}
	return parse(FileAccess.get_file_as_string(path))
