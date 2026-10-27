@tool
extends RefCounted
## Lists, hashes, copies and writes the files of a folder, one file at a time.
##
## Every path here is absolute. A write goes through [FileAccess], which in the
## editor writes a temporary file and renames it over the target (retrying a while
## on Windows when an antivirus holds the file), and [method write_checked] reads
## the file back, because a failed rename only prints an error.

# Direct preload, not core/modules.gd: the aggregator preloads this file.
const ContentHash := preload("res://addons/godot_mcp_toolkit/update/content_hash.gd")


## Every file under [param folder], hidden ones included, as paths relative to it,
## sorted. Empty when the folder does not exist.
static func list(folder: String) -> PackedStringArray:
	var files := PackedStringArray()
	_collect(folder, "", files)
	files.sort()
	return files


## The SHA-256 of the file at [param path] as lowercase hex, or an empty string when
## the file cannot be read.
static func hash_of_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var bytes := file.get_buffer(file.get_length())
	file.close()
	return ContentHash.of_bytes(bytes)


## Each file under [param folder] mapped to its SHA-256.
static func hashes(folder: String) -> Dictionary:
	var result := {}
	for path in list(folder):
		result[path] = hash_of_file(folder.path_join(path))
	return result


## Writes [param bytes] to [param path], creating its folder, then reads it back.
## Returns whether the file now holds exactly [param bytes].
static func write_checked(path: String, bytes: PackedByteArray) -> bool:
	var folder := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(folder) and DirAccess.make_dir_recursive_absolute(folder) != OK:
		return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(bytes)
	file.close()
	return hash_of_file(path) == ContentHash.of_bytes(bytes)


## Copies every file of [param source] into [param target] with
## [method write_checked]; with [param skip_identical], a target file that already
## holds the same bytes is left alone. Returns the relative paths that failed,
## empty on success.
static func copy_tree(source: String, target: String, skip_identical: bool = false) -> PackedStringArray:
	var failed := PackedStringArray()
	for path in list(source):
		var bytes := FileAccess.get_file_as_bytes(source.path_join(path))
		if skip_identical and hash_of_file(target.path_join(path)) == ContentHash.of_bytes(bytes):
			continue
		if not write_checked(target.path_join(path), bytes):
			failed.append(path)
	return failed


## Deletes [param folder] and everything under it. Returns whether it is gone.
static func remove_tree(folder: String) -> bool:
	if not DirAccess.dir_exists_absolute(folder):
		return true
	var dir := DirAccess.open(folder)
	if dir == null:
		return false
	dir.include_hidden = true
	for name in dir.get_files():
		DirAccess.remove_absolute(folder.path_join(name))
	for name in dir.get_directories():
		remove_tree(folder.path_join(name))
	DirAccess.remove_absolute(folder)
	return not DirAccess.dir_exists_absolute(folder)


static func _collect(base: String, relative: String, files: PackedStringArray) -> void:
	var dir := DirAccess.open(base.path_join(relative) if not relative.is_empty() else base)
	if dir == null:
		return
	dir.include_hidden = true
	for name in dir.get_files():
		files.append(relative.path_join(name) if not relative.is_empty() else name)
	for name in dir.get_directories():
		_collect(base, relative.path_join(name) if not relative.is_empty() else name, files)
