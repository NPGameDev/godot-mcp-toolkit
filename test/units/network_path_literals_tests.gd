@tool
extends RefCounted
## Pins that no script under res:// holds a network-path string literal. The language server
## looks up every plain string literal as a file path, and on Windows a value opening with two or
## more separators and then anything else is a network path whose lookup can block the editor;
## separators alone do not stall. StringName and NodePath literals are flagged too, to keep one
## rule. Godot gives scripts no tokenizer, so this file reads them with a small scanner of its
## own, pinned here against source text.

const Testing := preload("res://test/units/testing.gd")

const _THIS_SCRIPT := "res://test/units/network_path_literals_tests.gd"
const _MIN_SCRIPTS := 200
const _SEPARATORS := "/\\"
const _TOKEN_PATTERN := "#|(?:\\br)?[\"']"
const _ESCAPED := {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v", "\n": ""}

# The rule's case table: verdict | kind | text. A "value" row is a string's run-time value, fed to
# the scanner in every literal form; a "source" row is script text, fed as it stands. Each row
# reaches the scanner through a split at run time, so this block is one clean literal.
const _SHARED_CASES := r"""
flagged | value  | \\build\share\bin\
flagged | value  | //build/share/bin/node.exe
flagged | value  | \\server\share\x
flagged | value  | \\server\share\addons\.godot_mcp_toolkit_update\journal.json
flagged | value  | //host/path → refused
flagged | value  | /\h\x
flagged | value  | \/h/x
flagged | value  | \\a
clean   | value  | //
clean   | value  | \\
clean   | value  | \\\\
clean   | value  | /start
clean   | value  | res://a
clean   | value  | http://a
clean   | source | # "//host/share"
"""

# How source text reads: verdict | source holding one literal | that literal's value.
const _READING_CASES := r"""
flagged | "\\\\h"      | \\h
clean   | "\\\\"       | \\
clean   | "\\h"        | \h
flagged | '\\\\h'      | \\h
flagged | r"\\h"       | \\h
clean   | r"\h"        | \h
clean   | er"\\h"      | \h
clean   | r"\"//h"     | \"//h
clean   | "\"//h"      | "//h
clean   | "'//h"       | '//h
flagged | &"\\\\h"     | \\h
flagged | ^"\\\\h"     | \\h
flagged | "\u005c\\h"  | \\h
flagged | "\U00002F/h" | //h
clean   | "a//h"       | a//h
"""

const _ESCAPED_FORMS := ["\"%s\"", "'%s'", "\"\"\"%s\"\"\"", "'''%s'''", "&\"%s\"", "^\"%s\""]
const _RAW_FORMS := ["r\"%s\"", "r'%s'", "r\"\"\"%s\"\"\"", "r'''%s'''"]


static func run(testing: Testing) -> void:
	_test_shared_cases(testing)
	_test_source_reads_by_value(testing)
	_test_strings_and_comments_are_told_apart(testing)
	_test_every_project_script(testing)


static func _test_shared_cases(testing: Testing) -> void:
	testing.begin("Network-path literals: the rule's case table")
	for row: PackedStringArray in _table_rows(_SHARED_CASES):
		var flagged := row[0] == "flagged"
		var sources := _value_sources(row[2]) if row[1] == "value" else PackedStringArray([row[2]])
		var expected: Array[String] = []
		if flagged:
			expected.append("1: " + row[2])
		var misread: Array[String] = []
		for source: String in sources:
			if _network_path_literals(source) != expected:
				misread.append(source)
		testing.eq(misread, [], "%s as %s: %s" % [row[0], row[1], row[2]])
	print("")


static func _test_source_reads_by_value(testing: Testing) -> void:
	testing.begin("Network-path literals: source text is graded by its run-time value")
	for row: PackedStringArray in _table_rows(_READING_CASES):
		var values: Array[String] = []
		for literal: Dictionary in _string_literals(row[1]):
			values.append(str(literal["value"]))
		testing.eq(values, [row[2]], "%s has the value %s" % [row[1], row[2]])
		var expected: Array[String] = []
		if row[0] == "flagged":
			expected.append("1: " + row[2])
		testing.eq(_network_path_literals(row[1]), expected, "%s is %s" % [row[1], row[0]])
	print("")


static func _test_strings_and_comments_are_told_apart(testing: Testing) -> void:
	testing.begin("Network-path literals: strings and comments are told apart, lines counted")
	testing.eq(_network_path_literals("\"#\" + \"//h\""), ["1: //h"],
			"a # inside a string opens no comment")
	testing.eq(_network_path_literals("# it's a note\n\"//h\"\n"), ["2: //h"],
			"a quote inside a comment opens no string")
	testing.eq(_network_path_literals("# note\r\n\"//h\"\r\n"), ["2: //h"],
			"a comment on a CRLF line ends at that line")
	testing.eq(_network_path_literals("\"\" + \"//h\""), ["1: //h"],
			"an empty string opens no triple-quoted one")
	testing.eq(_network_path_literals("\"\"\"a\"//h\"\"\""), [],
			"a lone quote inside a triple-quoted string does not end it")
	testing.eq(_network_path_literals("\"\"\"x\ny\"\"\"\n\"//h\"\n"), ["3: //h"],
			"lines inside a triple-quoted string are counted")
	testing.eq(_network_path_literals("\"a\n//h\""), [],
			"a plain string that spans a line is one literal")
	testing.eq(_network_path_literals("\"\\\n//h\""), ["1: //h"],
			"an escaped newline adds nothing to the value")
	testing.eq(_network_path_literals("\"\\\r\n//h\""), ["1: //h"],
			"an escaped CRLF reads like an escaped LF, so line endings cannot change a verdict")
	print("")


static func _test_every_project_script(testing: Testing) -> void:
	testing.begin("Network-path literals: every script under res://")
	var paths: Array[String] = []
	_collect_scripts("res://", paths)
	testing.ok(paths.size() >= _MIN_SCRIPTS, "the walk reaches at least %d scripts" % _MIN_SCRIPTS)
	testing.ok(paths.has(_THIS_SCRIPT), "the walk reaches this file, whose bad values are built at run time")
	var offenders := 0
	for path: String in paths:
		for found: String in _network_path_literals(FileAccess.get_file_as_string(path)):
			offenders += 1
			testing.ok(false, "%s:%s" % [path, found])
	testing.eq(offenders, 0, "%d scripts scanned, none holds a network-path literal" % paths.size())
	print("")


# The hidden folders count: the language server's own walk reads them too.
static func _collect_scripts(folder: String, paths: Array[String]) -> void:
	var dir := DirAccess.open(folder)
	if dir == null:
		return
	dir.include_hidden = true
	for file_name: String in dir.get_files():
		if file_name.ends_with(".gd"):
			paths.append(folder.path_join(file_name))
	for child: String in dir.get_directories():
		var child_path := folder.path_join(child)
		if child_path != "res://.godot":
			_collect_scripts(child_path, paths)


static func _table_rows(table: String) -> Array[PackedStringArray]:
	var rows: Array[PackedStringArray] = []
	for line: String in table.strip_edges().split("\n"):
		var columns := PackedStringArray()
		for column: String in line.split(" | "):
			columns.append(column.strip_edges())
		rows.append(columns)
	return rows


# The source text of value in every literal form that can hold it. A raw string cannot end in an
# odd run of backslashes: the last one would shield the closing quote.
static func _value_sources(value: String) -> PackedStringArray:
	var sources := PackedStringArray()
	for form: String in _ESCAPED_FORMS:
		sources.append(form % value.replace("\\", "\\\\"))
	if (value.length() - value.rstrip("\\").length()) % 2 == 0:
		for form: String in _RAW_FORMS:
			sources.append(form % value)
	return sources


# Each network-path literal in source, as "<line>: <value>".
static func _network_path_literals(source: String) -> Array[String]:
	var found: Array[String] = []
	for literal: Dictionary in _string_literals(source):
		var value: String = literal["value"]
		if _is_network_path(value):
			var start: int = literal["start"]
			found.append("%d: %s" % [source.substr(0, start).count("\n") + 1, value])
	return found


static func _is_network_path(value: String) -> bool:
	var separators := 0
	while separators < value.length() and value[separators] in _SEPARATORS:
		separators += 1
	return separators >= 2 and separators < value.length()


# Every string literal in source, in order, as {"start", "value", "end"}: the index of its opening
# quote, its run-time value, and the index just past it. Comments are skipped.
static func _string_literals(source: String) -> Array[Dictionary]:
	var literals: Array[Dictionary] = []
	var finder := RegEx.create_from_string(_TOKEN_PATTERN)
	var token := finder.search(source)
	while token != null:
		var resume := 0
		if token.get_string() == "#":
			resume = source.find("\n", token.get_start())
			if resume < 0:
				break
		else:
			var literal := _read_literal(source, token.get_end() - 1, token.get_string().begins_with("r"))
			literals.append(literal)
			resume = literal["end"]
		token = finder.search(source, resume)
	return literals


# A plain string may span lines, as in the engine's tokenizer. An unterminated one, an error there,
# runs to the end of source here.
static func _read_literal(source: String, quote_index: int, is_raw: bool) -> Dictionary:
	var quote := source[quote_index]
	var closing := quote.repeat(3) if source.substr(quote_index, 3) == quote.repeat(3) else quote
	var length := source.length()
	var index := quote_index + closing.length()
	var value := ""
	while index < length:
		var character := source[index]
		if character == quote and source.substr(index, closing.length()) == closing:
			return {"start": quote_index, "value": value, "end": index + closing.length()}
		if character != "\\":
			value += character
			index += 1
		elif is_raw:
			# A raw backslash stays in the value, and shields a quote or backslash after it.
			var held := 2 if source.substr(index + 1, 1) in [quote, "\\"] else 1
			value += source.substr(index, held)
			index += held
		else:
			var escape := _read_escape(source, index)
			value += str(escape["text"])
			index = escape["end"]
	return {"start": quote_index, "value": value, "end": length}


# Reads the escape whose backslash sits at index, as {"text", "end"}.
static func _read_escape(source: String, index: int) -> Dictionary:
	var code := source.substr(index + 1, 1)
	if code == "u" or code == "U":
		var digits := 4 if code == "u" else 6
		return {"text": char(source.substr(index + 2, digits).hex_to_int()), "end": index + 2 + digits}
	# The engine keeps the LF of an escaped CRLF; reading both alike gives every checkout one verdict.
	if source.substr(index + 1, 2) == "\r\n":
		return {"text": "", "end": index + 3}
	return {"text": _ESCAPED.get(code, code), "end": index + 2}
