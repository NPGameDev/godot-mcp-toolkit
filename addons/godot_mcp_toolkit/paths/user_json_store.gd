@tool
extends RefCounted
## Writes a toolkit [code]user://[/code] file as JSON, creating its folder first.
##
## The text goes out in one [method FileAccess.store_string], so a reader never
## sees half a file from this writer. The write prints nothing: each caller decides
## what a failure means for it.


## Write [param data] to [param path] as [method JSON.stringify] text with keys
## sorted, indented by [param indent] ("" gives compact JSON).
##
## Returns [constant OK], the error of a failed open, or, from Godot 4.4, the error
## of a failed write: 4.2 and 4.3 do not report a failed write through
## [method FileAccess.get_error], so there only a failed open is caught.
static func write(path: String, data: Dictionary, indent: String = "") -> Error:
	var dir := ProjectSettings.globalize_path(path.get_base_dir())
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(data, indent))
	var error := file.get_error()
	file.close()
	return error
