@tool
extends RefCounted
## Lists, hashes, writes and deletes the files of a folder, one file at a time.
##
## Every path here is absolute. A write goes through [FileAccess], which in the
## editor writes a temporary file and renames it over the target (retrying a while
## on Windows when an antivirus holds the file), and [method write_checked] reads
## the file back, because a failed rename only prints an error.

# Direct preload: core/modules.gd does not list this folder's scripts.
const ContentHash := preload("res://addons/godot_mcp_toolkit/self_update/content_hash.gd")

# The exit code of `test -L` on a path that is not a link.
const _TEST_NOT_A_LINK := 1
# On Godot 4.2 on Unix OS.execute hands its command to a shell with each argument in
# double quotes, where these characters still act. Escaping them would point `test` at
# another path if the engine ran no shell, and that reads as "not a link".
const _SHELL_ACTIVE := ["\"", "$", "`", "\\"]
# `fsutil reparsepoint query` on a folder that is no reparse point exits with this and
# prints this Windows error number. The match is on the number alone, since the words are
# the system language's. It prints no path, so a folder's name cannot supply the number.
const _FSUTIL_ANSWERED_NO := 1
const _FSUTIL_NOT_A_REPARSE_POINT := "4390"
# Given a bare name, OS.execute's CreateProcessW looks in the editor's folder and its working
# directory, the project, before System32, so a fsutil.exe at the project root could answer.
const _FSUTIL_UNDER_SYSTEM_ROOT := "\\System32\\fsutil.exe"


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
## [method DirAccess.is_link] is Godot 4.3+. On 4.2 the engine shows no link, so this asks
## [code]test -L[/code] on Unix and [code]fsutil reparsepoint query[/code] on Windows, one
## process per call, and anything but a clear "not a link" counts as one: a missing tool,
## an empty [code]SystemRoot[/code] (no process runs then), an access error, a path that is
## not there on Windows, a parent that does not open, or a path the shell would expand. On
## Windows every reparse point counts, a cloud placeholder too, as it does for
## [method DirAccess.is_link].
static func is_link(folder: String) -> bool:
	var parent := DirAccess.open(folder.get_base_dir())
	if parent == null:
		return true
	if parent.has_method("is_link"):
		return bool(parent.call("is_link", folder.get_file()))
	if OS.get_name() == "Windows":
		var system_root := OS.get_environment("SystemRoot")
		if system_root.is_empty():
			return true
		var fsutil := system_root + _FSUTIL_UNDER_SYSTEM_ROOT
		var output: Array = []
		var exit_code := OS.execute(fsutil, ["reparsepoint", "query", folder.replace("/", "\\")], output)
		return exit_code != _FSUTIL_ANSWERED_NO or not str(output).contains(_FSUTIL_NOT_A_REPARSE_POINT)
	for character: String in _SHELL_ACTIVE:
		if folder.contains(character):
			return true
	return OS.execute("test", ["-L", folder]) != _TEST_NOT_A_LINK


## Deletes [param folder] and everything under it, and never what a link points at.
##
## A link, at the top or at any depth, goes as a link when the engine can remove one, its
## target untouched. Where it cannot (Godot 4.2 on Unix, or a remove an ACL denies) the
## link and its target stay. On 4.2 each real folder that holds anything costs one process,
## through [method is_link].[br]
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
