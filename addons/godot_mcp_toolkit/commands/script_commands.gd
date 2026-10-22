@tool
extends RefCounted
## script.* command handlers — read, write, surgical edit, delete, and offline
## check for .gd/.cs/.gdshader/.gdshaderinc.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const FileGuard = Modules.FileGuard
const Untrusted = Modules.Untrusted
const Helpers = Modules.CommandHelpers
const ResponseLimits = Modules.ResponseLimits

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
		var cap_kb: int = ResponseLimits.effective_value(ResponseLimits.SCRIPT_READ_CAP_KB)
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
	var cap_kb: int = ResponseLimits.effective_value(ResponseLimits.SCRIPT_READ_CAP_KB)
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
	# With an edits array the top-level old_string is absent, so only the single form
	# requires it.
	var uses_edits := parameters.has("edits")
	var required := ["file_path"] if uses_edits else ["file_path", "old_string"]
	var err = MCPToolkitError.require(parameters, required)
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

	var edits: Array = []
	if uses_edits:
		# A top-level replace_all:false changes nothing, and clients that fill in
		# optional defaults send it, so only a true one conflicts with edits.
		var replace_all_set := bool(parameters.get("replace_all", false))
		if parameters.has("old_string") or parameters.has("new_string") or replace_all_set:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"pass either edits or old_string/new_string/replace_all, not both")
		var edits_param = parameters.get("edits")
		if not (edits_param is Array) or edits_param.is_empty():
			return MCPToolkitError.fail("INVALID_PARAMS",
				"edits must be a non-empty array of {old_string, new_string, replace_all?}")
		edits = edits_param
	else:
		edits.append(parameters)
	# Fail fast on a malformed or no-op edit before touching the file: a substitution
	# that changes nothing would still churn undo/index/diagnostics for no effect.
	for index in edits.size():
		var shape_error := _check_edit_shape(edits[index], _edit_prefix(uses_edits, index))
		if not shape_error.is_empty():
			return shape_error

	if not FileAccess.file_exists(file_path):
		return MCPToolkitError.fail("NOT_FOUND", "no file at %s" % file_path, MCPToolkitError.HINT_FILE_PATH)
	var prior_content := FileAccess.get_file_as_string(file_path)
	var read_error := FileAccess.get_open_error()
	if read_error != OK:
		return MCPToolkitError.fail("READ_FAILED",
			"FileAccess error %d reading %s" % [read_error, file_path])

	var applied := _apply_edits(prior_content, edits, file_path, uses_edits)
	if applied.has("error"):
		return applied

	# The file existed (checked above), so the undo restores prior_content.
	var result := await _commit_content(server, file_path, str(applied["content"]), prior_content, true, edit_extension)
	if result.has("error"):
		return result
	result["replacements"] = applied["replacements"]
	return result


## Checks one edit's keys before the file is read. [param edit] is an element of
## script.edit's edits array, or the top-level parameters for the single form;
## [param prefix] names the element in the message ("" for the single form).
## Returns an empty Dictionary when the edit is well formed, else an
## [code]INVALID_PARAMS[/code] failure envelope.
static func _check_edit_shape(edit: Variant, prefix: String) -> Dictionary:
	if not (edit is Dictionary):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"%smust be an object {old_string, new_string, replace_all?}" % prefix)
	var old_string := str(edit.get("old_string", ""))
	if old_string.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "%sold_string is required" % prefix)
	# new_string is required-present but "" is valid (an empty replacement deletes the
	# span) — so it can't go through require(), which rejects an empty string. Check
	# presence directly.
	if not edit.has("new_string"):
		return MCPToolkitError.fail("INVALID_PARAMS", "%smissing new_string" % prefix)
	if old_string == str(edit.get("new_string", "")):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"%sold_string and new_string are identical — the edit would change nothing" % prefix)
	return {}


## Applies [param edits] to [param content] in order, each against the text the
## earlier ones leave. Nothing is written here: the caller commits the result once,
## so a failing edit leaves the file untouched. Each edit is a Dictionary already
## checked by [method _check_edit_shape]; [param uses_edits] prefixes each failure with
## the edit's index (the edits form). Returns
## [code]{content, replacements}[/code], or a [code]NOT_FOUND[/code] /
## [code]NOT_UNIQUE[/code] failure envelope for the first edit that doesn't match once.
static func _apply_edits(content: String, edits: Array, file_path: String, uses_edits: bool) -> Dictionary:
	var edited := content
	var replacements := 0
	for index in edits.size():
		var edit: Dictionary = edits[index]
		var prefix := _edit_prefix(uses_edits, index)
		var order_hint := " Edits apply in order, so match the text the earlier edits leave." if uses_edits else ""
		# A top-level replace_all beside edits is rejected, so the edits form points at the element.
		var replace_all_target := "on edits[%d] " % index if uses_edits else ""
		var old_string := str(edit.get("old_string", ""))
		var new_string := str(edit.get("new_string", ""))
		var replace_all := bool(edit.get("replace_all", false))

		var match_count := edited.count(old_string)
		if match_count == 0:
			return MCPToolkitError.fail("NOT_FOUND",
				"%sold_string not found in %s" % [prefix, file_path],
				"Re-read the file (script.read) and copy old_string byte-for-byte; whitespace and indentation must match exactly." + order_hint)
		if match_count > 1 and not replace_all:
			return MCPToolkitError.fail("NOT_UNIQUE",
				"%sold_string matches %d times in %s" % [prefix, match_count, file_path],
				"Add surrounding context so old_string identifies one location, or set replace_all:true %sto replace all %d." % [replace_all_target, match_count] + order_hint)

		if replace_all:
			edited = edited.replace(old_string, new_string)
			replacements += match_count
		else:
			# Exactly one match: splice at the found offset rather than String.replace (which
			# would substitute every occurrence), leaving every other byte untouched.
			var at := edited.find(old_string)
			edited = edited.substr(0, at) + new_string + edited.substr(at + old_string.length())
			replacements += 1
	return {"content": edited, "replacements": replacements}


## The message prefix naming edit [param index] of an edits array, or "" when
## [param uses_edits] is false (the single old_string/new_string form).
static func _edit_prefix(uses_edits: bool, index: int) -> String:
	return "edits[%d]: " % index if uses_edits else ""


## Writes [param content] to [param file_path], wrapping it in an editor UndoRedo
## action, reindexing the file, and — for a .gd file — attaching inline
## diagnostics and, when it compiles, reloading the script the editor has cached, so
## the nodes running it run the new code. The undo and redo reload it the same way. On
## Godot 4.2.0 and 4.2.1, where an in-place reload is unsafe, none of them reloads, and a
## compiling edit of an existing file gets a stale-instance hint instead. Shared by
## [method _cmd_script_write] (whole-file) and [method _cmd_script_edit] (surgical) so
## both take the identical write/undo/index/diagnose pipeline. [param prior_content] is
## the file's content before this write (empty when [param existed] is false) — the undo
## restores it, or deletes the file when it did not exist. [param extension] is the
## lowercased file extension, used to gate the .gd-only diagnostics.
## Returns the success envelope [code]{bytes, undoable, indexed, valid?, diagnostics?, hint?}[/code],
## or a [method MCPToolkitError.fail] envelope on a write failure.
static func _commit_content(server: Node, file_path: String, content: String,
		prior_content: String, existed: bool, extension: String) -> Dictionary:
	var write_error := _write_file_raw(file_path, content)
	if write_error != OK:
		return MCPToolkitError.fail("WRITE_FAILED",
			"could not open %s for write (err %d)" % [file_path, write_error])

	var reload_safe := Modules.VersionUtils.in_place_reload_safe()
	var _undo := MCPToolkitUndoRedoAction.begin("script_write: %s" % file_path) \
		.do_method(server.undo_helpers._write_file_silent.bind(file_path, content, reload_safe))
	var undoable := _undo.is_active()
	if existed:
		_undo.undo_method(server.undo_helpers._write_file_silent.bind(file_path, prior_content, reload_safe))
	else:
		_undo.undo_method(server.undo_helpers._delete_file_silent.bind(file_path))
	_undo.commit_recorded()

	var index_result := await Helpers.ensure_file_indexed(file_path)

	var bytes_written := content.to_utf8_buffer().size()
	var result := MCPToolkitSuccess.ok({"bytes": bytes_written, "undoable": undoable,
		"indexed": index_result["indexed"]})

	# Inline GDScript diagnostics — same validation as script_check.
	if extension == "gd":
		var validation := _validate_gdscript(content, file_path)
		result["valid"] = validation["valid"]
		result["diagnostics"] = validation["diagnostics"]
		# Godot < 4.4 never reloads a cached script after a write, and 4.4+ only on a
		# later scan, so the nodes already running it would keep the old code. The
		# toolkit never applies a source that failed the check above. Where an in-place
		# reload is unsafe, an edit that compiles stays for an editor restart, and the
		# hint says so.
		if reload_safe:
			if bool(validation["valid"]):
				# The outcome goes unread: the response reports the check this source passed.
				Modules.ScriptReload.reload_cached_script(file_path, content)
		elif existed and bool(validation["valid"]):
			result["hint"] = Modules.StaleInstanceHint.write_hint(
					Modules.VersionUtils.get_engine_version_pair())

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

	var validation := _validate_gdscript(content, file_path)
	return MCPToolkitSuccess.ok({
		"file_path": file_path,
		"valid": validation["valid"],
		"diagnostics": validation["diagnostics"],
	})


## Validate GDScript source via GDScript.new().reload() — safe in-process parse.
## DO NOT use ResourceLoader.load() with CACHE_MODE_IGNORE here:
## it corrupts already-loaded scripts on ALL Godot versions.
##
## The compile probe (see [code]core/gdscript_source.gd[/code]) renames the
## script's [code]class_name[/code], so the copy neither clashes with the global
## class the editor registered for [param file_path] nor loses its own type, and
## checks the original name the way the engine does: a name that hides a
## built-in type, a native class, another script's global class or an autoload
## singleton is an error on the declaration's line. An empty
## [param file_path] stands for source with no file.
##
## Diagnostics carry only real fields. A class-name clash carries "line" on
## every version. A compile error carries "line" (the actual parse/compile error
## line) when the 4.5+ Logger capture recovered it from the reload error; on
## 4.2-4.4 (file-tail capture — no structured line) the key is omitted, never a
## fabricated 0. "col" is never emitted — columns are lsp_diagnostics' domain.
static func _validate_gdscript(source: String, file_path: String = "") -> Dictionary:
	var verdict := Modules.GDScriptSource.judge(source, file_path)
	var diagnostics: Array = []
	var conflict := str(verdict["conflict"])
	if conflict != "":
		diagnostics.append({
			"severity": "error",
			"message": conflict,
			"line": int(verdict["conflict_line"]),
		})
	# A clash does not hide a compile error elsewhere in the file.
	if not bool(verdict["compiles"]):
		diagnostics.append_array(_compile_error_diagnostics(str(verdict["decisive_source"])))
	return MCPToolkitSuccess.ok({"valid": bool(verdict["valid"]), "diagnostics": diagnostics})


## Re-runs the probe compile that failed with its errors printed, then reads
## them back: the error entry and any autoload or preload hints.
## [param probe_source] is the probe's decisive source from
## [code]GDScriptSource.judge()[/code]. Returns the diagnostics as
## [code][{severity, message, line?}][/code].
static func _compile_error_diagnostics(probe_source: String) -> Array:
	# The first entry the re-run pushes gets the cursor's id; since_id reads
	# "entries with id > since_id", so subtract 1 to include it.
	var pre_id: int = Modules.LogBuffer.get_cursor() - 1
	Modules.GDScriptSource.print_compile_errors(probe_source)

	var diagnostics: Array = []
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
	return diagnostics


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
		var msg := Modules.GDScriptSource.strip_probe_suffix(str(entry.get("message", "")))
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
		var msg := Modules.GDScriptSource.strip_probe_suffix(str(entry.get("message", "")))
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
