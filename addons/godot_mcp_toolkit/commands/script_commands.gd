@tool
extends RefCounted
## script.* command handlers — read, write, delete for .gd/.cs/.gdshader/.gdshaderinc.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPCommandRegistry = _Hub.MCPCommandRegistry
const MCPFileGuard = _Hub.MCPFileGuard
const MCPUntrusted = _Hub.MCPUntrusted

const ALLOWED_EXTENSIONS: Array[String] = ["gd", "cs", "gdshader", "gdshaderinc"]


static func register(registry: MCPCommandRegistry, server: Node) -> void:
	registry.add("script.read", func(parameters: Dictionary) -> Dictionary:
		return _cmd_script_read(parameters), "lite")
	registry.add("script.read_range", func(parameters: Dictionary) -> Dictionary:
		return _cmd_script_read_range(parameters), "lite")
	registry.add("script.write", func(parameters: Dictionary) -> Dictionary:
		return _cmd_script_write(server, parameters), "lite")
	registry.add("script.delete", func(parameters: Dictionary) -> Dictionary:
		return _cmd_script_delete(parameters), "full")


# -- Commands -----------------------------------------------------------------


static func _cmd_script_read(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("file_path", ""))
	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	if not FileAccess.file_exists(file_path):
		return MCPError.make("NOT_FOUND", "file not found: %s" % file_path)
	var content := FileAccess.get_file_as_string(file_path)
	var open_error := FileAccess.get_open_error()
	if open_error != OK:
		return MCPError.make("READ_FAILED",
			"FileAccess error %d reading %s" % [open_error, file_path])
	var content_bytes := content.to_utf8_buffer().size()
	if content_bytes > 262144:
		var err := MCPError.make("FILE_TOO_LARGE",
			"file exceeds 256 KB response cap")
		err["total_bytes"] = content_bytes
		err["hint"] = "use script_read_range(path, start_line, end_line)"
		return err
	return {"content": MCPUntrusted.wrap("script", file_path, content)}


static func _cmd_script_read_range(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("file_path", ""))
	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	if not FileAccess.file_exists(file_path):
		return MCPError.make("NOT_FOUND", "file not found: %s" % file_path)
	if not parameters.has("start_line") or not parameters.has("end_line"):
		return MCPError.make("INVALID_PARAMS", "start_line and end_line are required")
	var start_line := int(parameters.get("start_line", 0))
	var end_line := int(parameters.get("end_line", 0))
	if start_line < 1:
		return MCPError.make("INVALID_PARAMS",
			"start_line must be >= 1 (got %d)" % start_line)
	if end_line < start_line:
		return MCPError.make("INVALID_PARAMS",
			"end_line must be >= start_line (got %d < %d)" % [end_line, start_line])
	var content := FileAccess.get_file_as_string(file_path)
	var read_error := FileAccess.get_open_error()
	if read_error != OK:
		return MCPError.make("READ_FAILED",
			"FileAccess error %d reading %s" % [read_error, file_path])
	var lines := content.split("\n")
	var total_lines := lines.size()
	var clamped_start := mini(start_line, total_lines)
	var clamped_end := mini(end_line, total_lines)
	var slice := lines.slice(clamped_start - 1, clamped_end)
	var result_text := "\n".join(slice)
	var result_bytes := result_text.to_utf8_buffer().size()
	if result_bytes > 262144:
		return MCPError.make("FILE_TOO_LARGE",
			"slice exceeds 256 KB response cap; narrow the line range")
	return {
		"content": MCPUntrusted.wrap("script", file_path, result_text),
		"start_line": clamped_start,
		"end_line": clamped_end,
		"total_lines": total_lines,
	}


static func _cmd_script_write(server: Node, parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("file_path", ""))
	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
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
	var file_path := str(parameters.get("file_path", ""))
	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
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
