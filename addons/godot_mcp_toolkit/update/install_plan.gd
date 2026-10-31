@tool
extends RefCounted
## Decides what an update writes and deletes in the addon folder, and which installed
## files were changed by hand.
##
## Pure: it compares the installed folder's release file list, the files the folder
## holds now and the files of the new release. A file the installed list does not
## name is someone's own and is never deleted; an engine-generated
## [code].import[/code] file is never deleted either. Without an installed list
## (a folder copied from a branch) nothing is deleted.

## The file written last, so an apply cut short leaves the old version's number.
const LAST_WRITTEN := "plugin.cfg"


## The plan for one update.
##
## [param installed_list] is the installed folder's list (path to SHA-256), empty
## when it has none. [param installed_files] is what the folder holds now (path to
## SHA-256). [param release_files] are the new release's files.[br]
## [br]
## Returns [code]{"write": PackedStringArray, "delete": PackedStringArray,
## "changed": PackedStringArray}[/code]: every release file, [constant LAST_WRITTEN]
## last; the listed files the release dropped that the folder still holds; and the
## listed files whose content differs from the list. All but [code]write[/code] are
## sorted.
static func plan(
		installed_list: Dictionary, installed_files: Dictionary,
		release_files: PackedStringArray) -> Dictionary:
	var write := PackedStringArray()
	for path in release_files:
		if path != LAST_WRITTEN:
			write.append(path)
	if release_files.has(LAST_WRITTEN):
		write.append(LAST_WRITTEN)

	var delete := PackedStringArray()
	var changed := PackedStringArray()
	var listed: Array = installed_list.keys()
	listed.sort()
	for path in listed:
		if not installed_files.has(path):
			continue
		if installed_files[path] != installed_list[path]:
			changed.append(path)
		if not release_files.has(path) and not str(path).ends_with(".import"):
			delete.append(path)
	return {"write": write, "delete": delete, "changed": changed}
