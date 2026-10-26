@tool
extends RefCounted
## Reads GDScript source text as the tokenizer does, skipping strings and
## comments: the identifiers it holds and the inner classes it declares.

const _CLASS_KEYWORD := "class"


## Returns the start and end (exclusive) of the first identifier at or after
## [param from] that sits outside strings and comments, or [code](-1, -1)[/code]
## when none is left.
static func next_identifier(source: String, from: int) -> Vector2i:
	var length := source.length()
	var index := from
	while index < length:
		var character := source[index]
		if character == "#":
			index = _line_end(source, index)
		elif character == "\"" or character == "'":
			index = _string_end(source, index)
		elif is_identifier_start(character):
			return Vector2i(index, identifier_end(source, index))
		else:
			index += 1
	return Vector2i(-1, -1)


## Returns the index of the first character at or after [param from] that is
## not a space, a tab or a [code]\[/code] line continuation.
static func skip_inline_space(source: String, from: int) -> int:
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


## Returns the index just past the identifier that starts at [param start].
static func identifier_end(source: String, start: int) -> int:
	var length := source.length()
	var index := start
	while index < length and _is_identifier_char(source[index]):
		index += 1
	return index


## Returns whether [param character] can open an identifier. GDScript
## identifiers allow any non-ASCII letter, so every code point above ASCII
## counts.
static func is_identifier_start(character: String) -> bool:
	var code := character.unicode_at(0)
	return character == "_" or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) \
			or code >= 128


## Returns the inner classes [param source] declares with [code]class[/code],
## nested as declared: each name maps to the same shape for the classes
## declared in its body, in declaration order.
##
## [code]class[/code] is a keyword, so outside strings and comments it only
## opens a declaration, and its line's indentation places the class: under the
## nearest class above it that is indented less.
static func declared_classes(source: String) -> Dictionary:
	var declared := {}
	var open_bodies: Array[Dictionary] = [declared]
	var open_indents: Array[int] = [-1]
	var token := next_identifier(source, 0)
	while token.x >= 0:
		if source.substr(token.x, token.y - token.x) == _CLASS_KEYWORD:
			var name_start := skip_inline_space(source, token.y)
			if name_start < source.length() and is_identifier_start(source[name_start]):
				var name_end := identifier_end(source, name_start)
				var indent := _line_indent(source, token.x)
				while open_indents.back() >= indent:
					open_indents.pop_back()
					open_bodies.pop_back()
				var enclosing_body: Dictionary = open_bodies.back()
				var body := {}
				enclosing_body[source.substr(name_start, name_end - name_start)] = body
				open_bodies.append(body)
				open_indents.append(indent)
				token.y = name_end
		token = next_identifier(source, token.y)
	return declared


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


static func _is_identifier_char(character: String) -> bool:
	var code := character.unicode_at(0)
	return is_identifier_start(character) or (code >= 48 and code <= 57)


# Tabs and spaces before the first character of the line that holds index.
static func _line_indent(source: String, index: int) -> int:
	# rfind() reads a negative start as "from the end", so the first line is
	# handled apart.
	var line_start := 0 if index == 0 else source.rfind("\n", index - 1) + 1
	var indent := 0
	while line_start + indent < index:
		var character := source[line_start + indent]
		if character != " " and character != "\t":
			break
		indent += 1
	return indent
