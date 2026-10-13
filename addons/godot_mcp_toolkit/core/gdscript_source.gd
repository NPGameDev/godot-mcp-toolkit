@tool
extends RefCounted
## The compile probe: a [code]GDScript.new()[/code] copy of a [code].gd[/code]
## file, compiled in memory to judge the file without reloading the script the
## editor has loaded.
##
## A copy that kept its [code]class_name[/code] would clash with the global
## class the editor registered for the real file, and a copy without one is
## anonymous, so a script that types [code]self[/code] as its own class would
## fail. The probe therefore renames the declared class (adding
## [constant PROBE_SUFFIX]) and runs the analyzer's four class-name checks on
## the original name itself. Error lines still match the file, because the
## rename adds no line.

## Appended to the declared class name in the probe's source. Engine messages
## about the probe carry it; [method strip_probe_suffix] removes it from text an
## agent reads.
const PROBE_SUFFIX := "__McpProbe"

const _CLASS_NAME_KEYWORD := "class_name"
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


## Judges [param source] as the engine would judge the file at
## [param file_path], with every compile kept out of stderr and the 4.5+ Logger.
##
## The analyzer's class-name checks run first, on the original name. Then the
## source compiles with the class and every bare reference to it renamed; if
## that fails, it compiles again with only the declaration renamed. The script
## compiles when either compile passes, or when the first failed in codegen
## and the second in the analyzer: the full rename turns a value use of the
## script's own name, such as [code]Player.new()[/code], into a codegen error,
## and the declaration-only rename fails wherever the script types
## [code]self[/code] as its own class.
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

	var full_probe := _new_probe(str(all_renamed["source"]))
	var declaration_probe := _new_probe(str(declaration_renamed["source"]))
	var tries_declaration := declaration_probe.source_code != full_probe.source_code
	var printed_errors := Engine.print_error_messages
	# Only reload() runs while printing is off: GDScript has no `finally`, and a
	# runtime error here would leave the editor's error printing off.
	Engine.print_error_messages = false
	var full_result := full_probe.reload(false)
	var declaration_result := full_result
	if full_result != OK and tries_declaration:
		declaration_result = declaration_probe.reload(false)
	Engine.print_error_messages = printed_errors

	var compiles := full_result == OK or declaration_result == OK \
			or (full_result == ERR_COMPILATION_FAILED and declaration_result == ERR_PARSE_ERROR)
	var decisive_source := ""
	if not compiles:
		decisive_source = full_probe.source_code if full_result == ERR_PARSE_ERROR \
				else declaration_probe.source_code
	return {
		"valid": compiles and conflict == "",
		"compiles": compiles,
		"conflict": conflict,
		"conflict_line": int(declaration_renamed["line"]),
		"decisive_source": decisive_source,
	}


## Compiles [param probe_source] with error printing on, so its errors reach
## stderr, the editor log capture and the console readers, then restores the
## caller's [member Engine.print_error_messages] value.
static func print_compile_errors(probe_source: String) -> void:
	var probe := _new_probe(probe_source)
	var printed_errors := Engine.print_error_messages
	Engine.print_error_messages = true
	probe.reload(false)
	Engine.print_error_messages = printed_errors


## Returns [param text] with [constant PROBE_SUFFIX] removed, so a message
## about the probe names the script's real class.
##
## A plain replace rather than a pattern: the suffix is unique to the probe,
## and a regex word class would stop at a non-ASCII letter in a class name.
static func strip_probe_suffix(text: String) -> String:
	return text.replace(PROBE_SUFFIX, "")


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
	var name_start := _skip_inline_space(source, keyword_end)
	if name_start >= source.length() or not _is_identifier_start(source[name_start]):
		return unchanged
	var name_end := _identifier_end(source, name_start)
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
	var token := _next_identifier(source, 0)
	while token.x >= 0:
		if source.substr(token.x, token.y - token.x) == class_name_text \
				and not _follows_dot(source, token.x):
			renamed += source.substr(copied_up_to, token.y - copied_up_to) + PROBE_SUFFIX
			copied_up_to = token.y
		token = _next_identifier(source, token.y)
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
		return "Class \"%s\" hides a global script class." % class_name_text
	if _is_autoload_singleton(class_name_text):
		return "Class \"%s\" hides an autoload singleton." % class_name_text
	return ""


static func _new_probe(probe_source: String) -> GDScript:
	var probe := GDScript.new()
	probe.source_code = probe_source
	return probe


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
	var own_path := _canonical_path(file_path) if file_path != "" else ""
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) != class_name_text:
			continue
		return _canonical_path(str(entry.get("path", ""))) != own_path
	return false


static func _is_autoload_singleton(class_name_text: String) -> bool:
	var key := "autoload/" + class_name_text
	return ProjectSettings.has_setting(key) \
			and str(ProjectSettings.get_setting(key)).begins_with("*")


static func _canonical_path(path: String) -> String:
	return ProjectSettings.localize_path(path).simplify_path()


# Index just past the first `class_name` keyword outside strings and comments,
# or -1 when the source has none.
static func _find_class_name_keyword_end(source: String) -> int:
	var token := _next_identifier(source, 0)
	while token.x >= 0:
		if source.substr(token.x, token.y - token.x) == _CLASS_NAME_KEYWORD:
			return token.y
		token = _next_identifier(source, token.y)
	return -1


# Start and end (exclusive) of the first identifier at or after `from` that
# sits outside strings and comments, or (-1, -1) when none is left.
static func _next_identifier(source: String, from: int) -> Vector2i:
	var length := source.length()
	var index := from
	while index < length:
		var character := source[index]
		if character == "#":
			index = _line_end(source, index)
		elif character == "\"" or character == "'":
			index = _string_end(source, index)
		elif _is_identifier_start(character):
			return Vector2i(index, _identifier_end(source, index))
		else:
			index += 1
	return Vector2i(-1, -1)


# Skips spaces, tabs and `\` line continuations.
static func _skip_inline_space(source: String, from: int) -> int:
	var length := source.length()
	var index := from
	while index < length:
		var character := source[index]
		if character == " " or character == "\t":
			index += 1
		elif character == "\\" and source.substr(index + 1, 1) == "\n":
			index += 2
		elif character == "\\" and source.substr(index + 1, 2) == "\r\n":
			index += 3
		else:
			break
	return index


static func _follows_dot(source: String, identifier_start: int) -> bool:
	var index := identifier_start - 1
	while index >= 0 and (source[index] == " " or source[index] == "\t"):
		index -= 1
	return index >= 0 and source[index] == "."


static func _line_end(source: String, from: int) -> int:
	var newline := source.find("\n", from)
	return source.length() if newline < 0 else newline


# Index just past the string that opens at quote_index: single or
# triple quoted, with backslash escapes. An unterminated string runs to the end.
static func _string_end(source: String, quote_index: int) -> int:
	var quote := source[quote_index]
	var length := source.length()
	var triple := source.substr(quote_index, 3) == quote.repeat(3)
	var index := quote_index + (3 if triple else 1)
	while index < length:
		var character := source[index]
		if character == "\\":
			index += 2
		elif character != quote:
			index += 1
		elif not triple:
			return index + 1
		elif source.substr(index, 3) == quote.repeat(3):
			return index + 3
		else:
			index += 1
	return length


static func _identifier_end(source: String, start: int) -> int:
	var length := source.length()
	var index := start
	while index < length and _is_identifier_char(source[index]):
		index += 1
	return index


# GDScript identifiers allow any non-ASCII letter, so every code point above
# ASCII counts.
static func _is_identifier_start(character: String) -> bool:
	var code := character.unicode_at(0)
	return character == "_" or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) \
			or code >= 128


static func _is_identifier_char(character: String) -> bool:
	var code := character.unicode_at(0)
	return _is_identifier_start(character) or (code >= 48 and code <= 57)
