@tool
extends RefCounted
class_name ScriptCommands
## script.* command handlers — read, write, delete for .gd/.cs/.gdshader/.gdshaderinc.

const ALLOWED_EXTENSIONS: Array[String] = ["gd", "cs", "gdshader", "gdshaderinc"]


static func register(registry: MCPCommandRegistry, server: Node) -> void:
	registry.add("script.read", func(parameters: Dictionary) -> Dictionary:
		return _cmd_script_read(parameters), "lite")
	registry.add("script.write", func(parameters: Dictionary) -> Dictionary:
		return _cmd_script_write(server, parameters), "lite")
	registry.add("script.delete", func(parameters: Dictionary) -> Dictionary:
		return _cmd_script_delete(parameters), "full")


# -- Commands -----------------------------------------------------------------


static func _cmd_script_read(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("path", ""))
	# TODO(iter-18): replace this prefix check with FileGuard.resolve_safe(path).
	if not file_path.begins_with("res://"):
		return MCPError.make("PATH_DENIED", "path must start with res://: %s" % file_path)
	if not FileAccess.file_exists(file_path):
		return MCPError.make("NOT_FOUND", "file not found: %s" % file_path)
	var content := FileAccess.get_file_as_string(file_path)
	var open_error := FileAccess.get_open_error()
	if open_error != OK:
		return MCPError.make("READ_FAILED",
			"FileAccess error %d reading %s" % [open_error, file_path])
	# TODO(iter-18): wrap content in <untrusted> envelope.
	return {"content": content}


static func _cmd_script_write(server: Node, parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("path", ""))
	# TODO(iter-18): replace this prefix check with FileGuard.resolve_safe(path).
	if not file_path.begins_with("res://"):
		return MCPError.make("PATH_DENIED", "path must start with res://: %s" % file_path)
	var write_extension := file_path.get_extension().to_lower()
	if not (write_extension in ALLOWED_EXTENSIONS):
		return MCPError.make("INVALID_PATH",
			"script.write only writes .gd, .cs, .gdshader, or .gdshaderinc files (got %s); use scene.create for .tscn, resource.create for .tres/.res, or a different tool for other file types" % file_path)
	if not parameters.has("content"):
		return MCPError.make("INVALID_PARAMS", "missing content")
	var content := str(parameters.get("content", ""))

	var existed := FileAccess.file_exists(file_path)
	var prior_content := ""
	if existed:
		prior_content = FileAccess.get_file_as_string(file_path)
		var read_error := FileAccess.get_open_error()
		if read_error != OK:
			return MCPError.make("READ_FAILED",
				"could not read prior content of %s (err %d)" % [file_path, read_error])

	var write_error := _write_file_raw(file_path, content)
	if write_error != OK:
		return MCPError.make("WRITE_FAILED",
			"could not open %s for write (err %d)" % [file_path, write_error])

	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("MCP script_write: %s" % file_path)
	undo_redo.add_do_method(server, "_write_file_silent", file_path, content)
	if existed:
		undo_redo.add_undo_method(server, "_write_file_silent", file_path, prior_content)
	else:
		undo_redo.add_undo_method(server, "_delete_file_silent", file_path)
	undo_redo.commit_action(false)

	var bytes_written := content.to_utf8_buffer().size()
	return {"ok": true, "bytes": bytes_written, "undoable": true}


static func _cmd_script_delete(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("path", ""))
	# TODO(iter-18): route file_path through FileGuard.resolve_safe.
	if not file_path.begins_with("res://"):
		return MCPError.make("INVALID_PATH", "path must start with res:// (got %s)" % file_path)
	var extension := file_path.get_extension().to_lower()
	if not (extension in ALLOWED_EXTENSIONS):
		return MCPError.make("INVALID_PATH",
			"script.delete only removes .gd, .cs, .gdshader, or .gdshaderinc files (got %s); use scene.delete for .tscn, resource.delete for .tres/.res, or a different tool for other file types" % file_path)
	if not FileAccess.file_exists(file_path):
		return MCPError.make("NOT_FOUND", "no file at %s" % file_path)
	var directory := DirAccess.open("res://")
	if directory == null:
		return MCPError.make("INTERNAL", "DirAccess.open(res://) returned null")
	var relative_path := file_path.substr("res://".length())
	var remove_error := directory.remove(relative_path)
	if remove_error != OK:
		return MCPError.make("DELETE_FAILED",
			"DirAccess.remove returned %d (path=%s)" % [remove_error, file_path])
	var uid_relative := relative_path + ".uid"
	if directory.file_exists(uid_relative):
		directory.remove(uid_relative)
	return {"success": true, "path": file_path}


# -- File I/O helpers (referenced by UndoRedo via server node) ----------------


static func _write_file_raw(file_path: String, content: String) -> int:
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(content)
	file.close()
	return OK
