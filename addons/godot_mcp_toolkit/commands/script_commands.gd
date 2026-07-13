@tool
extends RefCounted
## script.* command handlers — read, write, surgical edit, delete, and offline
## check for .gd/.cs/.gdshader/.gdshaderinc.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const FileGuard = Modules.FileGuard
const Untrusted = Modules.Untrusted
const Helpers = Modules.CommandHelpers

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
		return _cmd_script_read(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
	registry.add("script.write", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_script_write(server, parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("script.edit", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_script_edit(server, parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("script.delete", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_script_delete(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("script.check", func(parameters: Dictionary) -> Dictionary:
		return _cmd_script_check(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())


# -- Commands -----------------------------------------------------------------


static func _cmd_script_read(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if not FileAccess.file_exists(file_path):
		return MCPToolkitError.fail("NOT_FOUND", "file not found: %s" % file_path, MCPToolkitError.HINT_FILE_PATH)
	var content := FileAccess.get_file_as_string(file_path)
	var open_error := FileAccess.get_open_error()
	if open_error != OK:
		return MCPToolkitError.fail("READ_FAILED",
			"FileAccess error %d reading %s" % [open_error, file_path])

	# Range read: if start_line is present, return a line slice.
	if parameters.has("start_line"):
		var start_line := int(parameters.get("start_line", 0))
		var end_line := int(parameters.get("end_line", start_line))
		if start_line < 1:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"start_line must be >= 1 (got %d)" % start_line)
		if end_line < start_line:
			return MCPToolkitError.fail("INVALID_PARAMS",
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
			return MCPToolkitError.fail("FILE_TOO_LARGE",
				"slice exceeds %d KB response cap; narrow the line range" % cap_kb)
		# Uniform pagination contract in line units: has_more = the last returned line
		# precedes EOF; when so, the builder adds next_start_line (1-based resume line =
		# clamped_end + 1) beside the prose loop hint composed here.
		var range_has_more := clamped_end < total_lines
		var range_hint := ""
		if range_has_more:
			range_hint = "more lines remain — re-call script.read with start_line = next_start_line (%d) until has_more is false" % (clamped_end + 1)
		return MCPToolkitSuccess.ok(Modules.Pagination.line_page(
			{
				"content": Untrusted.wrap("script", file_path, result_text),
				"start_line": clamped_start,
				"end_line": clamped_end,
			},
			clamped_end, slice.size(), total_lines, range_hint))

	# Full read with size cap.
	var content_bytes := content.to_utf8_buffer().size()
	var cap_kb: int = ProjectSettings.get_setting("mcp_toolkit/limits/script_read_cap_kb", 256)
	if content_bytes > cap_kb * 1024:
		var size_err := MCPToolkitError.fail("FILE_TOO_LARGE",
			"file exceeds %d KB response cap" % cap_kb)
		size_err["total_bytes"] = content_bytes
		size_err["hint"] = "re-call script_read with start_line / end_line"
		return size_err
	# Full file returned ⇒ never has_more. returned == total_lines and has_more:false
	# complete the uniform pagination contract so both read shapes carry the same fields.
	var full_lines := content.split("\n")
	return MCPToolkitSuccess.ok(Modules.Pagination.build(
		{"content": Untrusted.wrap("script", file_path, content)},
		"lines", full_lines.size(), full_lines.size(), false, "", 0, ""))



static func _cmd_script_write(server: Node, parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	var write_extension := file_path.get_extension().to_lower()
	if not (write_extension in ALLOWED_EXTENSIONS):
		return MCPToolkitError.fail("INVALID_PATH",
			"script.write only writes .gd, .cs, .gdshader, or .gdshaderinc files (got %s); use scene.create for .tscn, resource.write for .tres/.res, or a different tool for other file types" % file_path)
	if not parameters.has("content"):
		return MCPToolkitError.fail("INVALID_PARAMS", "missing content")
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
			return MCPToolkitError.fail("READ_FAILED",
				"could not read prior content of %s (err %d)" % [file_path, read_error])

	var result := await _commit_content(server, file_path, content, prior_content, existed, write_extension)
	if result.has("error"):
		return result
	if dirs_created:
		result["dirs_created"] = true
	return result


static func _cmd_script_edit(server: Node, parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path", "old_string"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	var edit_extension := file_path.get_extension().to_lower()
	if not (edit_extension in ALLOWED_EXTENSIONS):
		return MCPToolkitError.fail("INVALID_PATH",
			"script.edit only edits .gd, .cs, .gdshader, or .gdshaderinc files (got %s); use scene.create for .tscn, resource.write for .tres/.res, or a different tool for other file types" % file_path)
	# new_string is required-present but "" is valid (an empty replacement deletes the
	# span) — so it can't go through require(), which rejects an empty string. Check
	# presence directly.
	if not parameters.has("new_string"):
		return MCPToolkitError.fail("INVALID_PARAMS", "missing new_string")
	var old_string := str(parameters.get("old_string", ""))
	var new_string := str(parameters.get("new_string", ""))
	# Fail fast on a no-op / malformed edit before touching the file: a substitution
	# that changes nothing would still churn undo/index/diagnostics for no effect.
	if old_string == new_string:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"old_string and new_string are identical — the edit would change nothing")
	var replace_all := bool(parameters.get("replace_all", false))

	if not FileAccess.file_exists(file_path):
		return MCPToolkitError.fail("NOT_FOUND", "no file at %s" % file_path, MCPToolkitError.HINT_FILE_PATH)
	var prior_content := FileAccess.get_file_as_string(file_path)
	var read_error := FileAccess.get_open_error()
	if read_error != OK:
		return MCPToolkitError.fail("READ_FAILED",
			"FileAccess error %d reading %s" % [read_error, file_path])

	var match_count := prior_content.count(old_string)
	if match_count == 0:
		return MCPToolkitError.fail("NOT_FOUND",
			"old_string not found in %s" % file_path,
			"Re-read the file (script.read) and copy old_string byte-for-byte; whitespace and indentation must match exactly.")
	if match_count > 1 and not replace_all:
		return MCPToolkitError.fail("NOT_UNIQUE",
			"old_string matches %d times in %s" % [match_count, file_path],
			"Add surrounding context so old_string identifies one location, or set replace_all:true to replace all %d." % match_count)

	var new_content: String
	var replacements: int
	if replace_all:
		new_content = prior_content.replace(old_string, new_string)
		replacements = match_count
	else:
		# Exactly one match: splice at the found offset rather than String.replace (which
		# would substitute every occurrence), leaving every other byte untouched.
		var at := prior_content.find(old_string)
		new_content = prior_content.substr(0, at) + new_string + prior_content.substr(at + old_string.length())
		replacements = 1

	# The file existed (checked above), so the undo restores prior_content.
	var result := await _commit_content(server, file_path, new_content, prior_content, true, edit_extension)
	if result.has("error"):
		return result
	result["replacements"] = replacements
	return result


## Writes [param content] to [param file_path], wrapping it in an editor UndoRedo
## action, reindexing the file, and — for a .gd file — attaching inline
## diagnostics plus the stale-live-instance hint. Shared by [method _cmd_script_write]
## (whole-file) and [method _cmd_script_edit] (surgical) so both take the identical
## write/undo/index/diagnose pipeline. [param prior_content] is the file's content
## before this write (empty when [param existed] is false) — the undo restores it,
## or deletes the file when it did not exist. [param extension] is the lowercased
## file extension, used to gate the .gd-only diagnostics.
## Returns the success envelope [code]{bytes, undoable, indexed, valid?, diagnostics?, hint?}[/code],
## or a [method MCPToolkitError.fail] envelope on a write failure.
static func _commit_content(server: Node, file_path: String, content: String,
		prior_content: String, existed: bool, extension: String) -> Dictionary:
	var write_error := _write_file_raw(file_path, content)
	if write_error != OK:
		return MCPToolkitError.fail("WRITE_FAILED",
			"could not open %s for write (err %d)" % [file_path, write_error])

	var _undo := MCPToolkitUndoRedoAction.begin("script_write: %s" % file_path) \
		.do_method(server.undo_helpers._write_file_silent.bind(file_path, content))
	var undoable := _undo.is_active()
	if existed:
		_undo.undo_method(server.undo_helpers._write_file_silent.bind(file_path, prior_content))
	else:
		_undo.undo_method(server.undo_helpers._delete_file_silent.bind(file_path))
	_undo.commit_recorded()

	var index_result := await Helpers.ensure_file_indexed(file_path)

	var bytes_written := content.to_utf8_buffer().size()
	var result := MCPToolkitSuccess.ok({"bytes": bytes_written, "undoable": undoable,
		"indexed": index_result["indexed"]})

	# Inline GDScript diagnostics — same validation as script_check.
	if extension == "gd":
		var validation := _validate_gdscript(content)
		result["valid"] = validation["valid"]
		result["diagnostics"] = validation["diagnostics"]

		# Proactive stale-live-instance hint. Editing an EXISTING .gd
		# that compiled OK on Godot < 4.4 won't reach a live instance until relaunch
		# (added members AND changed bodies; a fresh node doesn't help either —
		# empirically characterised, boundary 4.3->4.4). Append to the response hint
		# (validation guidance first, stale nudge in the recency slot).
		var version := Modules.VersionUtils.get_engine_version_ints()
		if Modules.StaleInstanceHint.should_warn_on_write(existed, validation["valid"], extension, version.x, version.y):
			result["hint"] = Modules.StaleInstanceHint.write_hint(Modules.VersionUtils.get_engine_version_pair())

	return result


static func _cmd_script_delete(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path"])
	if err != null:
		return err
	var file_path := str(parameters.get("file_path", ""))
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	var extension := file_path.get_extension().to_lower()
	if not (extension in ALLOWED_EXTENSIONS):
		return MCPToolkitError.fail("INVALID_PATH",
			"script.delete only removes .gd, .cs, .gdshader, or .gdshaderinc files (got %s); use scene.delete for .tscn, resource.delete for .tres/.res, or a different tool for other file types" % file_path)
	if not FileAccess.file_exists(file_path):
		return MCPToolkitError.fail("NOT_FOUND", "no file at %s" % file_path, MCPToolkitError.HINT_FILE_PATH)
	var delete_result: Dictionary = await Helpers.delete_res_file_and_deindex(file_path)
	return delete_result


# -- File I/O helpers (referenced by UndoRedo via server node) ----------------


static func _cmd_script_check(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("file_path", ""))
	if file_path == "":
		return MCPToolkitError.fail("INVALID_PARAMS", "file_path is required")
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	var extension := file_path.get_extension().to_lower()
	if extension != "gd":
		return MCPToolkitError.fail("INVALID_PARAMS",
			"script.check only supports .gd files (got .%s)" % extension)
	if not FileAccess.file_exists(file_path):
		return MCPToolkitError.fail("NOT_FOUND", "no file at %s" % file_path, MCPToolkitError.HINT_FILE_PATH)

	var content := FileAccess.get_file_as_string(file_path)
	var read_error := FileAccess.get_open_error()
	if read_error != OK:
		return MCPToolkitError.fail("READ_FAILED",
			"FileAccess error %d reading %s" % [read_error, file_path])

	var validation := _validate_gdscript(content)
	return MCPToolkitSuccess.ok({
		"file_path": file_path,
		"valid": validation["valid"],
		"diagnostics": validation["diagnostics"],
	})


## Validate GDScript source via GDScript.new().reload() — safe in-process parse.
## DO NOT use ResourceLoader.load() with CACHE_MODE_IGNORE here:
## it corrupts already-loaded scripts on ALL Godot versions (P-056).
## Shared by script_write (inline diagnostics) and script_check.
##
## Diagnostics carry only real fields: the error entry gains "line" (the actual
## parse/compile error line) when the 4.5+ Logger capture recovered it from the
## reload error; on 4.2-4.4 (file-tail capture — no structured line) the key is
## omitted, never a fabricated 0. "col" is never emitted — columns are
## lsp_diagnostics' domain.
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
	var pre_id: int = Modules.LogBuffer._next_id - 1
	var script := GDScript.new()
	script.source_code = "\n".join(lines)
	var is_valid := script.reload(false) == OK

	var diagnostics: Array = []
	if not is_valid:
		var error_diagnostic := {
			"severity": "error",
			"message": _compile_error_message(Modules.VersionUtils.get_engine_version_pair()),
		}
		# The real error line, recovered from the Logger capture of the reload
		# error this call just triggered (an in-memory script reports under a
		# synthetic "gdscript://…" path, so the latch match is ours — the
		# snapshot-to-scan window runs synchronously on the main thread). -1
		# (nothing recovered — 4.2-4.4, or a failed Logger hook) omits the key.
		var real_line: int = Modules.LogBuffer.find_script_error_line_since(pre_id)
		if real_line > 0:
			error_diagnostic["line"] = real_line
		diagnostics.append(error_diagnostic)
		# Scan reload errors for unresolved identifiers that match autoloads.
		# Hint entries carry no line — the hint is about an identifier, not a
		# source position.
		var hints := _check_autoload_hints(pre_id)
		hints.append_array(_check_preload_hints(pre_id))
		for hint in hints:
			diagnostics.append({
				"severity": "hint",
				"message": hint,
			})
	return MCPToolkitSuccess.ok({"valid": is_valid, "diagnostics": diagnostics})


## Version-aware compile-error diagnostic message. editor_get_console surfaces editor
## PARSE errors only on Godot 4.5+ (the Logger API hooks the editor's error stream); on
## 4.2-4.4 file logging captures running-game output, not editor parse errors, so steering
## the LLM to editor_get_console there is a dead end — point to lsp_diagnostics (works 4.2+)
## instead. Both strings also steer the "did this change break ANOTHER script" case: on 4.5+
## editor_refresh→console is a cheaper best-effort first pass (it reloads only changed+open
## scripts, so an unopened broken dependent can read falsely clean) and lsp_project_diagnostics
## is the guaranteed whole-project scan; on 4.2-4.4 lsp_project_diagnostics is the only
## project-wide compile signal (the console cannot surface project-wide parse errors pre-4.5).
## engine_ver is Modules.VersionUtils.get_engine_version_pair() (e.g. "4.5").
static func _compile_error_message(engine_ver: String) -> String:
	const CONSOLE := "GDScript compile error. Call editor_get_console for detailed messages with line numbers. To check whether the change broke another script, editor_refresh then editor_get_console(error) is a cheaper first pass (best-effort — misses unopened dependents); lsp_project_diagnostics is the guaranteed whole-project scan."
	const LSP := "GDScript compile error. On Godot <4.5 editor parse errors are not surfaced by editor_get_console — call lsp_diagnostics for line-level detail (or read the script). To check whether the change broke another script, use lsp_project_diagnostics (the only project-wide compile signal on 4.2-4.4)."
	return CONSOLE if Modules.VersionUtils.is_at_least(engine_ver, "4.5") else LSP


## Scan LogBuffer errors emitted during reload() for unresolved identifiers
## that match registered autoloads, returning actionable hint strings.
static func _check_autoload_hints(pre_id: int) -> Array:
	var buf := Modules.LogBuffer.get_entries(50, ["error"], pre_id)
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
	var buf := Modules.LogBuffer.get_entries(50, ["error"], pre_id)
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
