@tool
extends RefCounted
## Prepares GDScript source for a compile probe: a [code]GDScript.new()[/code]
## copy compiled in memory to check the source without reloading the script the
## editor has loaded.

const _CLASS_NAME_KEYWORD := "class_name"
# Characters that end the class name: whitespace before `extends` or a comment,
# ";" ending the statement, "#" starting a comment, "\" continuing the line.
const _CLASS_NAME_END_CHARS := " \t;#\\"


## Returns [param source] with its [code]class_name <Name>[/code] declaration
## removed and the rest of that line kept.
##
## A probe that kept the declaration would hide the global class the editor
## registered under that name, a compile error the real script does not have.
## The rest of the line stays, so the one-line form
## [code]class_name Player extends Node[/code] still extends [code]Node[/code], and
## no line is added or removed, so error lines still match the file.
## Only the first line that starts with the declaration is edited; a declaration
## after an annotation on the same line, such as [code]@tool class_name Player[/code],
## is left in place.
static func strip_class_name(source: String) -> String:
	var lines := source.split("\n")
	for i in lines.size():
		var line := lines[i]
		var statement := line.strip_edges(true, false)
		if not _starts_with_class_name(statement):
			continue
		var indent := line.substr(0, line.length() - statement.length())
		var after_keyword := statement.substr(_CLASS_NAME_KEYWORD.length()).strip_edges(true, false)
		var name_end := 0
		while name_end < after_keyword.length() \
				and not _CLASS_NAME_END_CHARS.contains(after_keyword[name_end]):
			name_end += 1
		var rest := after_keyword.substr(name_end).strip_edges(true, false)
		# "class_name Player; extends Node": the ";" belonged to the removed statement.
		if rest.begins_with(";"):
			rest = rest.substr(1).strip_edges(true, false)
		lines[i] = indent + rest
		break
	return "\n".join(lines)


static func _starts_with_class_name(statement: String) -> bool:
	if not statement.begins_with(_CLASS_NAME_KEYWORD):
		return false
	var next_char := statement.substr(_CLASS_NAME_KEYWORD.length(), 1)
	return next_char == " " or next_char == "\t"
