@tool
extends RefCounted
## script.* command handlers — read, write, delete for .gd/.cs/.gdshader/.gdshaderinc.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPFileGuard = _Hub.MCPFileGuard
const MCPUntrusted = _Hub.MCPUntrusted
const MCPHelpers = _Hub.MCPHelpers

const ALLOWED_EXTENSIONS: Array[String] = ["gd", "cs", "gdshader", "gdshaderinc"]


static func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:
	registry.add("script.read", func(parameters: Dictionary) -> Dictionary:
		return _cmd_script_read(parameters))
	registry.add("script.write", func(parameters: Dictionary) -> Dictionary:
		return _cmd_script_write(server, parameters))
	registry.add("script.delete", func(parameters: Dictionary) -> Dictionary:
		return _cmd_script_delete(parameters))
	registry.add("script.check", func(parameters: Dictionary) -> Dictionary:
		return _cmd_script_check(parameters))


# -- Commands -----------------------------------------------------------------


static func _cmd_script_read(parameters: Dictionary) -> Dictionary:
	var err = MCPError.check_required(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	if not FileAccess.file_exists(file_path):
		return MCPError.make("NOT_FOUND", "file not found: %s" % file_path, MCPError.HINT_FILE_PATH)
	var content := FileAccess.get_file_as_string(file_path)
	var open_error := FileAccess.get_open_error()
	if open_error != OK:
		return MCPError.make("READ_FAILED",
			"FileAccess error %d reading %s" % [open_error, file_path])

	# Range read: if start_line is present, return a line slice.
	if parameters.has("start_line"):
		var start_line := int(parameters.get("start_line", 0))
		var end_line := int(parameters.get("end_line", start_line))
		if start_line < 1:
			return MCPError.make("INVALID_PARAMS",
				"start_line must be >= 1 (got %d)" % start_line)
		if end_line < start_line:
			return MCPError.make("INVALID_PARAMS",
				"end_line must be >= start_line (got %d < %d)" % [end_line, start_line])
		var lines := content.split("\n")
		var total_lines := lines.size()
		var clamped_start := mini(start_line, total_lines)
		var clamped_end := mini(end_line, total_lines)
		var slice := lines.slice(clamped_start - 1, clamped_end)
		var result_text := "\n".join(slice)
		var result_bytes := result_text.to_utf8_buffer().size()
		var cap_kb: int = ProjectSettings.get_setting("mcp_toolkit/limits/script_read_cap_kb", 256)
		if result_bytes > cap_kb * 1024:
			return MCPError.make("FILE_TOO_LARGE",
				"slice exceeds %d KB response cap; narrow the line range" % cap_kb)
		return {
			"content": MCPUntrusted.wrap("script", file_path, result_text),
			"start_line": clamped_start,
			"end_line": clamped_end,
			"total_lines": total_lines,
		}

	# Full read with size cap.
	var content_bytes := content.to_utf8_buffer().size()
	var cap_kb: int = ProjectSettings.get_setting("mcp_toolkit/limits/script_read_cap_kb", 256)
	if content_bytes > cap_kb * 1024:
		var size_err := MCPError.make("FILE_TOO_LARGE",
			"file exceeds %d KB response cap" % cap_kb)
		size_err["total_bytes"] = content_bytes
		size_err["hint"] = "re-call script_read with start_line / end_line"
		return size_err
	return {"content": MCPUntrusted.wrap("script", file_path, content)}



static func _cmd_script_write(server: Node, parameters: Dictionary) -> Dictionary:
	var err = MCPError.check_required(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	var write_extension := file_path.get_extension().to_lower()
	if not (write_extension in ALLOWED_EXTENSIONS):
		return MCPError.make("INVALID_PATH",
			"script.write only writes .gd, .cs, .gdshader, or .gdshaderinc files (got %s); use scene.create for .tscn, resource.write for .tres/.res, or a different tool for other file types" % file_path)
	if not parameters.has("content"):
		return MCPError.make("INVALID_PARAMS", "missing content")
	var content := str(parameters.get("content", ""))

	var dir_result := MCPHelpers.ensure_parent_dir(file_path, "script.write")
	if dir_result.has("error"):
		return dir_result
	var dirs_created: bool = dir_result["dirs_created"]

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

	var undo_redo = _Hub.get_undo_redo()
	if undo_redo != null:
		undo_redo.create_action("MCP script_write: %s" % file_path)
		undo_redo.add_do_method(server.undo_helpers, "_write_file_silent", file_path, content)
		if existed:
			undo_redo.add_undo_method(server.undo_helpers, "_write_file_silent", file_path, prior_content)
		else:
			undo_redo.add_undo_method(server.undo_helpers, "_delete_file_silent", file_path)
		undo_redo.commit_action(false)

	var index_result := MCPHelpers.ensure_file_indexed(file_path)

	var bytes_written := content.to_utf8_buffer().size()
	var result := {"success": true, "bytes": bytes_written, "undoable": undo_redo != null,
		"indexed": index_result["indexed"]}
	if dirs_created:
		result["dirs_created"] = true
	return result


static func _cmd_script_delete(parameters: Dictionary) -> Dictionary:
	var err = MCPError.check_required(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	var extension := file_path.get_extension().to_lower()
	if not (extension in ALLOWED_EXTENSIONS):
		return MCPError.make("INVALID_PATH",
			"script.delete only removes .gd, .cs, .gdshader, or .gdshaderinc files (got %s); use scene.delete for .tscn, resource.delete for .tres/.res, or a different tool for other file types" % file_path)
	if not FileAccess.file_exists(file_path):
		return MCPError.make("NOT_FOUND", "no file at %s" % file_path, MCPError.HINT_FILE_PATH)
	var delete_result := MCPHelpers.delete_res_file(file_path)
	if delete_result.get("success", false):
		var removal := MCPHelpers.ensure_file_removed(file_path)
		delete_result["deindexed"] = removal["removed"]
	return delete_result


# -- File I/O helpers (referenced by UndoRedo via server node) ----------------


static func _cmd_script_check(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("file_path", ""))
	if file_path == "":
		return MCPError.make("INVALID_PARAMS", "file_path is required")
	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	var extension := file_path.get_extension().to_lower()
	if extension != "gd":
		return MCPError.make("INVALID_PARAMS",
			"script.check only supports .gd files (got .%s)" % extension)
	if not FileAccess.file_exists(file_path):
		return MCPError.make("NOT_FOUND", "no file at %s" % file_path, MCPError.HINT_FILE_PATH)

	# Validate via GDScript.new().reload() — safe in-process parse.
	# DO NOT use ResourceLoader.load() with CACHE_MODE_IGNORE here:
	# it corrupts already-loaded scripts on ALL Godot versions (P-056),
	# crashing the editor when checking already-loaded scripts.
	# Remaining trade-off: error messages reference gdscript:// URIs
	# instead of real paths. Use editor_get_errors for accurate diagnostics.
	var content := FileAccess.get_file_as_string(file_path)
	var read_error := FileAccess.get_open_error()
	if read_error != OK:
		return MCPError.make("READ_FAILED",
			"FileAccess error %d reading %s" % [read_error, file_path])

	# Strip class_name declaration to prevent false-positive conflict (P-053).
	# GDScript.new().reload() registers a second copy of the name, colliding
	# with the already-registered global class. Blanking the line preserves
	# line numbers so any real errors still report correct positions.
	var lines := content.split("\n")
	for i in lines.size():
		if lines[i].strip_edges().begins_with("class_name "):
			lines[i] = ""
			break
	var script := GDScript.new()
	script.source_code = "\n".join(lines)
	var is_valid := script.reload(false) == OK

	var diagnostics: Array = []
	if not is_valid:
		diagnostics.append({
			"line": 0,
			"severity": "error",
			"message": "GDScript compile error. Call editor_get_errors for detailed messages with line numbers.",
		})

	return {
		"success": true,
		"file_path": file_path,
		"valid": is_valid,
		"diagnostics": diagnostics,
	}


static func _write_file_raw(file_path: String, content: String) -> int:
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(content)
	file.close()
	return OK
