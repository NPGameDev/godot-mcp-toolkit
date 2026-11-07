@tool
extends RefCounted
## Names what an update's swap would cost: the installed files changed by hand, and the
## files that are not the release's at all.
##
## It does no I/O of its own: it compares the installed folder's release file list with the
## files the folder holds now. The swap replaces the whole addon folder and copies nothing back, so a file
## the list does not name is someone's own and leaves with the old folder. Two files are
## never named as discarded: an engine-generated [code].import[/code] file, which the engine
## makes again, and the list itself, which leaves itself out and comes back with the release.

# Direct preload, not core/modules.gd: the aggregator preloads the installer,
# which reaches this file.
const ReleaseFileList := preload("res://addons/godot_mcp_toolkit/self_update/release_file_list.gd")

const _ENGINE_FILE_SUFFIX := ".import"


## The plan for one update.
##
## [param installed_list] is the installed folder's list (path to SHA-256), empty when it has
## none. [param installed_files] is what the folder holds now (path to SHA-256).[br]
## [br]
## Returns [code]{"changed": PackedStringArray, "discarded": PackedStringArray,
## "has_list": bool}[/code], both arrays sorted: the listed files whose content differs from
## the list; the files the list does not name; and whether there was a list. A folder with no
## list, copied from a branch say, has nothing to compare, so nothing reads as changed and
## every file reads as discarded.
static func plan(installed_list: Dictionary, installed_files: Dictionary) -> Dictionary:
	var changed := PackedStringArray()
	var discarded := PackedStringArray()
	var held: Array = installed_files.keys()
	held.sort()
	for path: String in held:
		if installed_list.has(path):
			if installed_files[path] != installed_list[path]:
				changed.append(path)
		elif path != ReleaseFileList.FILE_NAME and not path.ends_with(_ENGINE_FILE_SUFFIX):
			discarded.append(path)
	return {"changed": changed, "discarded": discarded, "has_list": not installed_list.is_empty()}
