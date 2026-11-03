@tool
extends RefCounted
## Lists, hashes, writes and deletes the files of a folder, one file at a time.
##
## Every path here is absolute. A write goes through [FileAccess], which in the
## editor writes a temporary file and renames it over the target (retrying a while
## on Windows when an antivirus holds the file), and [method write_checked] reads
## the file back, because a failed rename only prints an error.

# Direct preload, not core/modules.gd: the aggregator preloads this file.
const ContentHash := preload("res://addons/godot_mcp_toolkit/self_update/content_hash.gd")

# The exit code of `test -L` on a path that is not a link.
const _TEST_NOT_A_LINK := 1
# On Godot 4.2 on Unix OS.execute hands its command to a shell with each argument in
# double quotes, where these characters still act. Escaping them would point `test` at
# another path if the engine ran no shell, and that reads as "not a link".
const _SHELL_ACTIVE := ["\"", "$", "`", "\\"]


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


## Whether the folder [param folder] is a link, as far as this engine can tell.
##
## [method DirAccess.is_link] is Godot 4.3+. On 4.2 on Unix the engine shows no link, so
## this asks [code]test -L[/code], one process per call, and anything but a clear "not a
## link" counts as one: a missing [code]test[/code], a parent that does not open, or a
## path the shell would expand. On 4.2 on Windows nothing shows a link and this returns
## false; [method remove_tree] says what a delete does there.
static func is_link(folder: String) -> bool:
	var parent := DirAccess.open(folder.get_base_dir())
	if parent == null:
		return true
	if parent.has_method("is_link"):
		return bool(parent.call("is_link", folder.get_file()))
	if OS.get_name() == "Windows":
		return false
	for character: String in _SHELL_ACTIVE:
		if folder.contains(character):
			return true
	return OS.execute("test", ["-L", folder]) != _TEST_NOT_A_LINK


## Deletes [param folder] and everything under it, and never what a link points at.
##
## A link, at the top or at any depth, goes as a link when the engine can remove one, its
## target untouched. Where it cannot (Godot 4.2 on Unix) the link and its target stay.
## On 4.2 on Windows no link shows, but the plain remove tried first takes a junction or
## a directory symlink as a link. One whose remove fails there (an ACL, say) looks like a
## real folder, and its target's files go.[br]
## [br]
## Returns whether [param folder] is gone.
static func remove_tree(folder: String) -> bool:
	if not DirAccess.dir_exists_absolute(folder):
		return true
	# Takes an empty folder or a link, and fails on a real folder that holds anything.
	DirAccess.remove_absolute(folder)
	if not DirAccess.dir_exists_absolute(folder):
		return true
	if is_link(folder):
		return false
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
