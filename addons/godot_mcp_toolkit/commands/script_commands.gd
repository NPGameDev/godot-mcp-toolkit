@tool
extends RefCounted
## script.* command handlers — read, write, delete for .gd/.cs/.gdshader/.gdshaderinc.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const McpError = _Hub.McpError
const FileGuard = _Hub.FileGuard
const Untrusted = _Hub.Untrusted
const Helpers = _Hub.Helpers

const ALLOWED_EXTENSIONS: Array[String] = ["gd", "cs", "gdshader", "gdshaderinc"]

static var _autoload_hint_re: RegEx = _compile_autoload_hint_re()
static var _preload_hint_re: RegEx = _compile_preload_hint_re()

static func _compile_autoload_hint_re() -> RegEx:
	var re := RegEx.new()
	re.compile('Identifier "(\\w+)" not declared')
	return re

static func _compile_preload_hint_re() -> RegEx:
	var re := RegEx.new()
	re.compile('(?:[Cc]ould not p|[Pp])reload (?:resource )?(?:file|script|scene) "([^"]+)"')
	return re


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
	var err = McpError.check_required(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return McpError.make("PATH_DENIED", str(guard["reason"]))
	if not FileAccess.file_exists(file_path):
		return McpError.make("NOT_FOUND", "file not found: %s" % file_path, McpError.HINT_FILE_PATH)
	var content := FileAccess.get_file_as_string(file_path)
	var open_error := FileAccess.get_open_error()
	if open_error != OK:
		return McpError.make("READ_FAILED",
			"FileAccess error %d reading %s" % [open_error, file_path])

	# Range read: if start_line is present, return a line slice.
	if parameters.has("start_line"):
		var start_line := int(parameters.get("start_line", 0))
		var end_line := int(parameters.get("end_line", start_line))
		if start_line < 1:
			return McpError.make("INVALID_PARAMS",
				"start_line must be >= 1 (got %d)" % start_line)
		if end_line < start_line:
			return McpError.make("INVALID_PARAMS",
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
			return McpError.make("FILE_TOO_LARGE",
				"slice exceeds %d KB response cap; narrow the line range" % cap_kb)
		return {
			"content": Untrusted.wrap("script", file_path, result_text),
			"start_line": clamped_start,
			"end_line": clamped_end,
			"total_lines": total_lines,
		}

	# Full read with size cap.
	var content_bytes := content.to_utf8_buffer().size()
	var cap_kb: int = ProjectSettings.get_setting("mcp_toolkit/limits/script_read_cap_kb", 256)
	if content_bytes > cap_kb * 1024:
		var size_err := McpError.make("FILE_TOO_LARGE",
			"file exceeds %d KB response cap" % cap_kb)
		size_err["total_bytes"] = content_bytes
		size_err["hint"] = "re-call script_read with start_line / end_line"
		return size_err
	return {"content": Untrusted.wrap("script", file_path, content)}



static func _cmd_script_write(server: Node, parameters: Dictionary) -> Dictionary:
	var err = McpError.check_required(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return McpError.make("PATH_DENIED", str(guard["reason"]))
	var write_extension := file_path.get_extension().to_lower()
	if not (write_extension in ALLOWED_EXTENSIONS):
		return McpError.make("INVALID_PATH",
			"script.write only writes .gd, .cs, .gdshader, or .gdshaderinc files (got %s); use scene.create for .tscn, resource.write for .tres/.res, or a different tool for other file types" % file_path)
	if not parameters.has("content"):
		return McpError.make("INVALID_PARAMS", "missing content")
	var content := str(parameters.get("content", ""))

	var dir_result := Helpers.ensure_parent_dir(file_path, "script.write")
	if dir_result.has("error"):
		return dir_result
	var dirs_created: bool = dir_result["dirs_created"]

	var existed := FileAccess.file_exists(file_path)
	var prior_content := ""
	if existed:
		prior_content = FileAccess.get_file_as_string(file_path)
		var read_error := FileAccess.get_open_error()
		if read_error != OK:
			return McpError.make("READ_FAILED",
				"could not read prior content of %s (err %d)" % [file_path, read_error])

	var write_error := _write_file_raw(file_path, content)
	if write_error != OK:
		return McpError.make("WRITE_FAILED",
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

	var index_result := Helpers.ensure_file_indexed(file_path)

	var bytes_written := content.to_utf8_buffer().size()
	var result := {"success": true, "bytes": bytes_written, "undoable": undo_redo != null,
		"indexed": index_result["indexed"]}
	if dirs_created:
		result["dirs_created"] = true

	# Inline GDScript diagnostics — same validation as script_check (FIX-1).
	if write_extension == "gd":
		var validation := _validate_gdscript(content)
		result["valid"] = validation["valid"]
		result["diagnostics"] = validation["diagnostics"]

	return result


static func _cmd_script_delete(parameters: Dictionary) -> Dictionary:
	var err = McpError.check_required(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return McpError.make("PATH_DENIED", str(guard["reason"]))
	var extension := file_path.get_extension().to_lower()
	if not (extension in ALLOWED_EXTENSIONS):
		return McpError.make("INVALID_PATH",
			"script.delete only removes .gd, .cs, .gdshader, or .gdshaderinc files (got %s); use scene.delete for .tscn, resource.delete for .tres/.res, or a different tool for other file types" % file_path)
	if not FileAccess.file_exists(file_path):
		return McpError.make("NOT_FOUND", "no file at %s" % file_path, McpError.HINT_FILE_PATH)
	var delete_result := Helpers.delete_res_file(file_path)
	if delete_result.get("success", false):
		var removal := Helpers.ensure_file_removed(file_path)
		delete_result["deindexed"] = removal["removed"]
	return delete_result


# -- File I/O helpers (referenced by UndoRedo via server node) ----------------


static func _cmd_script_check(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("file_path", ""))
	if file_path == "":
		return McpError.make("INVALID_PARAMS", "file_path is required")
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return McpError.make("PATH_DENIED", str(guard["reason"]))
	var extension := file_path.get_extension().to_lower()
	if extension != "gd":
		return McpError.make("INVALID_PARAMS",
			"script.check only supports .gd files (got .%s)" % extension)
	if not FileAccess.file_exists(file_path):
		return McpError.make("NOT_FOUND", "no file at %s" % file_path, McpError.HINT_FILE_PATH)

	var content := FileAccess.get_file_as_string(file_path)
	var read_error := FileAccess.get_open_error()
	if read_error != OK:
		return McpError.make("READ_FAILED",
			"FileAccess error %d reading %s" % [read_error, file_path])

	var validation := _validate_gdscript(content)
	return {
		"success": true,
		"file_path": file_path,
		"valid": validation["valid"],
		"diagnostics": validation["diagnostics"],
	}


## Validate GDScript source via GDScript.new().reload() — safe in-process parse.
## DO NOT use ResourceLoader.load() with CACHE_MODE_IGNORE here:
## it corrupts already-loaded scripts on ALL Godot versions (P-056).
## Shared by script_write (inline diagnostics) and script_check.
static func _validate_gdscript(source: String) -> Dictionary:
	# Strip class_name to prevent false-positive conflict (P-053).
	# GDScript.new().reload() registers a second copy of the name, colliding
	# with the already-registered global class. Blanking the line preserves
	# line numbers so any real errors still report correct positions.
	var lines := source.split("\n")
	for i in lines.size():
		if lines[i].strip_edges().begins_with("class_name "):
			lines[i] = ""
			break
	# Snapshot LogBuffer position so we can scan errors produced by reload().
	# _next_id is the ID the next pushed entry will receive; since_id uses
	# "entries with id > since_id", so subtract 1 to include that first entry.
	var pre_id: int = _Hub.LogBuffer._next_id - 1
	var script := GDScript.new()
	script.source_code = "\n".join(lines)
	var is_valid := script.reload(false) == OK

	var diagnostics: Array = []
	if not is_valid:
		diagnostics.append({
			"line": 0,
			"severity": "error",
			"message": "GDScript compile error. Call editor_get_console for detailed messages with line numbers.",
		})
		# Scan reload errors for unresolved identifiers that match autoloads.
		var hints := _check_autoload_hints(pre_id)
		hints.append_array(_check_preload_hints(pre_id))
		for hint in hints:
			diagnostics.append({
				"line": 0,
				"severity": "hint",
				"message": hint,
			})
	return {"valid": is_valid, "diagnostics": diagnostics}


## Scan LogBuffer errors emitted during reload() for unresolved identifiers
## that match registered autoloads, returning actionable hint strings.
static func _check_autoload_hints(pre_id: int) -> Array:
	var buf := _Hub.LogBuffer.get_entries(50, ["error"], pre_id)
	var entries: Array = buf.get("entries", [])
	var seen := {}
	var hints: Array = []
	for entry in entries:
		var msg: String = str(entry.get("message", ""))
		var m := _autoload_hint_re.search(msg)
		if m == null:
			continue
		var ident: String = m.get_string(1)
		if seen.has(ident):
			continue
		seen[ident] = true
		if ProjectSettings.has_setting("autoload/" + ident):
			hints.append(
				"Identifier '%s' is a registered autoload. The editor cache may be stale — call autoload_manage with action='register' to refresh it, or reference via get_node('/root/%s')." % [ident, ident])
		else:
			# Soft hint for PascalCase names that look like singletons.
			if ident.length() >= 2 and ident[0] == ident[0].to_upper() and ident[0] != ident[0].to_lower():
				hints.append(
					"Identifier '%s' not declared — if this is an autoload singleton, register it first with autoload_manage (action='register', name='%s', script_path='res://...')." % [ident, ident])
	return hints


## Scan LogBuffer errors for preload() failures referencing missing files.
static func _check_preload_hints(pre_id: int) -> Array:
	var buf := _Hub.LogBuffer.get_entries(50, ["error"], pre_id)
	var entries: Array = buf.get("entries", [])
	var seen := {}
	var hints: Array = []
	for entry in entries:
		var msg: String = str(entry.get("message", ""))
		var m := _preload_hint_re.search(msg)
		if m == null:
			continue
		var path: String = m.get_string(1)
		if seen.has(path):
			continue
		seen[path] = true
		if not FileAccess.file_exists(path):
			hints.append(
				"preload('%s') failed because the file doesn't exist yet. Use load() instead — it evaluates at runtime when the file will exist. Or create the file first, then use preload()." % path)
	return hints


static func _write_file_raw(file_path: String, content: String) -> int:
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(content)
	file.close()
	return OK
