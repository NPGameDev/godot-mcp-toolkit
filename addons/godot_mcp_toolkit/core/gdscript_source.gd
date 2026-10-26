@tool
extends RefCounted
## The compile probe: a [code]GDScript.new()[/code] copy of a [code].gd[/code]
## file, compiled in memory beside the file to judge it without reloading the
## script the editor has loaded. Each compile goes through
## [code]core/compile_probe.gd[/code].
##
## A copy that kept its [code]class_name[/code] would clash with the global
## class the editor registered for the real file, and a copy without one is
## anonymous, so a script that types [code]self[/code] as its own class would
## fail. The probe therefore renames the declared class (adding
## [constant PROBE_SUFFIX]) and runs the analyzer's four class-name checks on
## the original name itself. Error lines still match the file, because the
## rename adds no line. A renamed copy is not the type another script names,
## so on 4.5+ a script the renamed copies reject is compiled once more under
## its own name, and its errors are read back from the console capture.

# Direct preloads, not core/modules.gd: the aggregator preloads this file.
const CompileProbe := preload("res://addons/godot_mcp_toolkit/core/compile_probe.gd")
const GDScriptScanner := preload("res://addons/godot_mcp_toolkit/core/gdscript_scanner.gd")
const LogBuffer := preload("res://addons/godot_mcp_toolkit/logging/log_buffer.gd")

## Appended to the declared class name in the probe's source. Engine messages
## about the probe carry it; [method strip_probe_suffix] removes it from text an
## agent reads.
const PROBE_SUFFIX := "__McpProbe"

const _CLASS_NAME_KEYWORD := "class_name"
const _HIDES_GLOBAL_CLASS := "Class \"%s\" hides a global script class."
# Words the parser never takes as a class name. After `class_name` one of
# these means the name is missing, so the source is left for the engine to
# report.
const _RESERVED_WORDS: Array[String] = [
	"and", "as", "assert", "await", "break", "breakpoint", "class", "class_name",
	"const", "continue", "elif", "else", "enum", "extends", "false", "for", "func",
	"if", "in", "INF", "is", "match", "NAN", "namespace", "not", "null", "or", "pass",
	"PI", "preload", "return", "self", "signal", "static", "super", "TAU", "trait",
	"true", "var", "void", "when", "while", "yield",
]

# Built on first use, then shared by every message the console readers map.
static var _probe_path_suffix: RegEx


## Judges [param source] as the engine would judge the file at
## [param file_path], with no compile's script errors left in the console
## readers. Every compile runs beside [param file_path], so relative paths and
## the project's warning rules for that path apply as they do to the file.
##
## The analyzer's class-name checks run first, on the original name. Then the
## source compiles with the class and every bare reference to it renamed; if
## that fails, it compiles again with only the declaration renamed. The script
## compiles when either compile passes, or when the first failed in codegen
## and the second in the analyzer: the full rename turns a value use of the
## script's own name, such as [code]Player.new()[/code], into a codegen error,
## and the declaration-only rename fails wherever the script types
## [code]self[/code] as its own class.
## When both fail, the name is free and registered for [param file_path], and
## the 4.5+ Logger capture is live, the source compiles a third time with its
## name kept; it compiles when that compile's only error is the clash with its
## own registered class. That compile reaches stderr and the editor's Output
## panel, and its script errors are removed from the console buffer; any
## other error it causes, such as a dependency that fails to load, stays.
## An empty [param file_path] stands for source with no file, which clashes
## with every registered global class of its name.
##
## Returns [code]{valid, compiles, conflict, conflict_line, decisive_source}[/code]:
## [code]valid[/code] is [code]compiles[/code] with no [code]conflict[/code]
## (the engine's message, or ""); [code]conflict_line[/code] is the declared
## name's 1-based line, 0 when there is none; [code]decisive_source[/code] is
## the probe source whose errors are the script's real ones, "" when it
## compiles.
static func judge(source: String, file_path: String) -> Dictionary:
	var declaration_renamed := rename_declaration(source)
	var all_renamed := rename_references(source)
	var class_name_text := str(declaration_renamed["name"])
	var conflict := class_name_conflict(class_name_text, file_path)

	var full_source := str(all_renamed["source"])
	var declaration_source := str(declaration_renamed["source"])
	var full_result: int = CompileProbe.compile(full_source, file_path, false)["error"]
	var declaration_result := full_result
	if full_result != OK and declaration_source != full_source:
		declaration_result = CompileProbe.compile(declaration_source, file_path, false)["error"]

	var compiles := full_result == OK or declaration_result == OK \
			or (full_result == ERR_COMPILATION_FAILED and declaration_result == ERR_PARSE_ERROR)
	if not compiles and conflict == "" and _keep_name_probe_applies(class_name_text, file_path):
		compiles = _keep_name_probe_compiles(source, file_path, class_name_text,
				int(declaration_renamed["line"]))
	var decisive_source := ""
	if not compiles:
		decisive_source = full_source if full_result == ERR_PARSE_ERROR else declaration_source
	return {
		"valid": compiles and conflict == "",
		"compiles": compiles,
		"conflict": conflict,
		"conflict_line": int(declaration_renamed["line"]),
		"decisive_source": decisive_source,
	}


## Compiles [param probe_source] beside the file at [param file_path] with error
## printing on, so its errors reach stderr, the editor log capture and the
## console readers, then restores the caller's
## [member Engine.print_error_messages] value.
##
## Returns the path the compile ran under, which the captured errors name.
static func print_compile_errors(probe_source: String, file_path: String) -> String:
	return str(CompileProbe.compile(probe_source, file_path, true)["path"])


## Returns [param text] with [constant PROBE_SUFFIX] and the probe's path suffix
## removed, so a message about the probe names the script's real class and file.
##
## The class suffix is a plain replace rather than a pattern: it is unique to
## the probe, and a regex word class would stop at a non-ASCII letter in a
## class name.
static func strip_probe_suffix(text: String) -> String:
	if _probe_path_suffix == null:
		_probe_path_suffix = RegEx.create_from_string(CompileProbe.PATH_SUFFIX_PATTERN)
	return _probe_path_suffix.sub(text.replace(PROBE_SUFFIX, ""), "", true)


## Returns [code]{source, name, line}[/code]: [param source] with the
## identifier after its first [code]class_name[/code] keyword renamed, the
## original name and its 1-based line.
##
## The keyword is found outside strings and comments, wherever it sits in its
## line, and a [code]\[/code] continuation may separate it from the name. When
## no valid identifier follows the keyword, or there is no keyword, the source
## is returned unchanged with [code]name[/code] "" and [code]line[/code] 0, so
## the engine reports a malformed declaration itself.
static func rename_declaration(source: String) -> Dictionary:
	var unchanged := {"source": source, "name": "", "line": 0}
	var keyword_end := _find_class_name_keyword_end(source)
	if keyword_end < 0:
		return unchanged
	var name_start := GDScriptScanner.skip_inline_space(source, keyword_end)
	if name_start >= source.length() or not GDScriptScanner.is_identifier_start(source[name_start]):
		return unchanged
	var name_end := GDScriptScanner.identifier_end(source, name_start)
	var class_name_text := source.substr(name_start, name_end - name_start)
	if class_name_text in _RESERVED_WORDS:
		return unchanged
	return {
		"source": source.substr(0, name_end) + PROBE_SUFFIX + source.substr(name_end),
		"name": class_name_text,
		"line": source.substr(0, name_start).count("\n") + 1,
	}


## Returns [method rename_declaration]'s [code]{source, name, line}[/code], with
## every bare reference to the class renamed too: an identifier equal to the
## name, outside strings and comments, and not after a [code].[/code].
##
## The script's own name then resolves to the probe's class, as it resolves to
## the real class in the real file, instead of to the global class read from
## disk.
static func rename_references(source: String) -> Dictionary:
	var declaration_renamed := rename_declaration(source)
	var class_name_text := str(declaration_renamed["name"])
	if class_name_text == "":
		return declaration_renamed
	var renamed := ""
	var copied_up_to := 0
	var token := GDScriptScanner.next_identifier(source, 0)
	while token.x >= 0:
		if source.substr(token.x, token.y - token.x) == class_name_text \
				and not _follows_dot(source, token.x):
			renamed += source.substr(copied_up_to, token.y - copied_up_to) + PROBE_SUFFIX
			copied_up_to = token.y
		token = GDScriptScanner.next_identifier(source, token.y)
	renamed += source.substr(copied_up_to)
	return {
		"source": renamed,
		"name": class_name_text,
		"line": declaration_renamed["line"],
	}


## Returns the analyzer's error for a script at [param file_path] declaring
## [code]class_name [param class_name_text][/code], or "" when the name is free.
##
## The four checks run in the analyzer's order: a built-in type, an exposed
## native class, another script's global class, an autoload singleton. The
## messages are the engine's own.
static func class_name_conflict(class_name_text: String, file_path: String) -> String:
	if class_name_text == "":
		return ""
	if _is_builtin_type(class_name_text):
		return "Class \"%s\" hides a built-in type." % class_name_text
	if _is_exposed_native_class(class_name_text):
		return "Class \"%s\" hides a native class." % class_name_text
	if _is_other_global_class(class_name_text, file_path):
		return _HIDES_GLOBAL_CLASS % class_name_text
	if _is_autoload_singleton(class_name_text):
		return "Class \"%s\" hides an autoload singleton." % class_name_text
	return ""


# The keep-name probe needs a file that owns its registered class, since that
# clash is the one error it may discard, and needs the Logger to read the
# compile's errors back; the 4.2-4.4 log tail cannot list them.
static func _keep_name_probe_applies(class_name_text: String, file_path: String) -> bool:
	if file_path == "" or not LogBuffer.uses_logger_api():
		return false
	var entry := _global_class_entry(class_name_text)
	return not entry.is_empty() and _is_registered_for(entry, file_path)


# Compiles the source as written. Its name clashes with the class the editor
# registered for this very file, an error the real file never meets, so the
# analyzer reports that clash; it still analyses the body, with self typed as
# the class other scripts name, and the engine prints every analyzer error.
# The verdict holds only when the clash is the one error: any other entry,
# even on the same line, is a real error or one this probe cannot tell from
# one. The clash stops the compile before codegen, so a codegen-only error
# passes unseen. The probe's script errors leave the console buffer whatever
# the verdict, since they describe a copy, not the file.
static func _keep_name_probe_compiles(source: String, file_path: String,
		class_name_text: String, declaration_line: int) -> bool:
	var since_id := LogBuffer.get_cursor() - 1
	# Compiles with printing on: with it off the Logger receives nothing. The
	# Logger reports the probe's errors under the path it compiled under.
	var probe_path := str(CompileProbe.compile(source, file_path, true)["path"])
	var captured := LogBuffer.take_script_errors_since(since_id, probe_path)
	var errors: Array = captured["errors"]
	if not bool(captured["complete"]) or errors.size() != 1:
		return false
	var error: Dictionary = errors[0]
	return int(error["line"]) == declaration_line \
			and str(error["message"]).get_slice("\n", 0).ends_with(
				_HIDES_GLOBAL_CLASS % class_name_text)


# Variant type names, as the parser's built-in type lookup sees them: Nil is
# the null literal and Object is a class, so neither counts.
static func _is_builtin_type(class_name_text: String) -> bool:
	for variant_type in range(TYPE_NIL + 1, TYPE_MAX):
		if variant_type != TYPE_OBJECT and type_string(variant_type) == class_name_text:
			return true
	return false


# The analyzer counts only exposed classes, and the editor adds unexposed ones
# to ClassDB at their first instance (ProgressDialog, EditorLog), which
# class_exists() also reports. Such a class has no creator, so
# can_instantiate() is false; an abstract class is not instantiable either but
# is exposed, which from 4.4 its API type tells apart: a class added after
# startup takes API_NONE.
static func _is_exposed_native_class(class_name_text: String) -> bool:
	if not ClassDB.class_exists(class_name_text):
		return false
	if ClassDB.can_instantiate(class_name_text):
		return true
	# class_get_api_type() and API_NONE exist from 4.4; a static reference does
	# not parse on 4.2-4.3.
	if not ClassDB.has_method("class_get_api_type"):
		return false
	var api_none: int = ClassDB.class_get_integer_constant("ClassDB", "API_NONE")
	var api_type: int = ClassDB.call("class_get_api_type", class_name_text)
	return api_type != api_none


static func _is_other_global_class(class_name_text: String, file_path: String) -> bool:
	var entry := _global_class_entry(class_name_text)
	return not entry.is_empty() and not _is_registered_for(entry, file_path)


# The global class list's entry for the class, empty when no script registers
# it.
static func _global_class_entry(class_name_text: String) -> Dictionary:
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == class_name_text:
			return entry
	return {}


# Whether the global class list entry's script is the file at file_path; an
# empty file_path owns no entry with a path.
static func _is_registered_for(entry: Dictionary, file_path: String) -> bool:
	var own_path := CompileProbe.canonical_path(file_path) if file_path != "" else ""
	return CompileProbe.canonical_path(str(entry.get("path", ""))) == own_path


static func _is_autoload_singleton(class_name_text: String) -> bool:
	var key := "autoload/" + class_name_text
	return ProjectSettings.has_setting(key) \
			and str(ProjectSettings.get_setting(key)).begins_with("*")


# Index just past the first `class_name` keyword outside strings and comments,
# or -1 when the source has none.
static func _find_class_name_keyword_end(source: String) -> int:
	var token := GDScriptScanner.next_identifier(source, 0)
	while token.x >= 0:
		if source.substr(token.x, token.y - token.x) == _CLASS_NAME_KEYWORD:
			return token.y
		token = GDScriptScanner.next_identifier(source, token.y)
	return -1


static func _follows_dot(source: String, identifier_start: int) -> bool:
	var index := identifier_start - 1
	while index >= 0 and (source[index] == " " or source[index] == "\t"):
		index -= 1
	return index >= 0 and source[index] == "."
