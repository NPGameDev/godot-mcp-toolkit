@tool
extends RefCounted
## What a folder of committed trust documents must hold, with the folder as a parameter so a
## test can prove each check fails on a bad one. A bad document stops every client for good,
## so these run before a document is hosted.

const TrustChain := preload("res://addons/godot_mcp_toolkit/self_update/trust_chain.gd")


## Walks [param folder] with the real reader: the first document against its own roots, then
## each against the one before, and each [code]trust-N.json[/code] carrying version N, since a
## file named 7 holding 8 stops every client at 6. A folder with no document yet holds.
##
## Returns what is wrong, in order, stopping where the chain breaks. Empty when it holds.
static func folder_problems(folder: String) -> PackedStringArray:
	var problems := PackedStringArray()
	if not DirAccess.dir_exists_absolute(folder):
		problems.append("there is no folder %s" % folder)
		return problems
	var numbers: Array[int] = []
	for file_name: String in DirAccess.get_files_at(folder):
		if file_name.get_extension() != "json":
			continue
		var number := _number_in(file_name)
		if number == 0:
			problems.append("%s is not named trust-N.json" % file_name)
		else:
			numbers.append(number)
	numbers.sort()
	var previous := {}
	for position: int in numbers.size():
		var number: int = numbers[position]
		var file_name := _file_name(number)
		if number != position + 1:
			problems.append("the folder has %s and no %s" % [file_name, _file_name(position + 1)])
			return problems
		var file_bytes := FileAccess.get_file_as_bytes(folder.path_join(file_name))
		var carried := TrustChain.read_embedded(file_bytes.get_string_from_utf8())
		if not str(carried["error"]).is_empty():
			problems.append("%s: %s" % [file_name, carried["error"]])
			return problems
		if int(carried["version"]) != number:
			problems.append("%s carries version %d" % [file_name, int(carried["version"])])
			return problems
		var document := TrustChain.read_self_signed(file_bytes) if position == 0 else TrustChain.read_next(previous, file_bytes)
		if not str(document["error"]).is_empty():
			problems.append("%s: %s" % [file_name, document["error"]])
			return problems
		previous = document
	return problems


## Checks the embedded document [param embedded_text] against the highest document in
## [param folder]: empty when the folder has none, and otherwise the same [code]document[/code]
## and [code]signatures[/code]. Not the same bytes, since a Windows checkout could add CRLF. It
## also holds the embedded document to its own roots, which the run time forgives.
##
## Returns what is wrong. Empty when it holds.
static func embedded_problems(folder: String, embedded_text: String) -> PackedStringArray:
	var problems := PackedStringArray()
	var highest := 0
	if DirAccess.dir_exists_absolute(folder):
		for file_name: String in DirAccess.get_files_at(folder):
			highest = maxi(highest, _number_in(file_name))
	if highest == 0:
		if not embedded_text.is_empty():
			problems.append("the embedded document is set, and the folder has no document")
		return problems
	var highest_name := _file_name(highest)
	if embedded_text.is_empty():
		problems.append("the embedded document is empty, and the folder has %s" % highest_name)
		return problems
	var embedded := _outer_fields(embedded_text)
	var committed := _outer_fields(FileAccess.get_file_as_string(folder.path_join(highest_name)))
	if str(embedded["document"]) != str(committed["document"]) or str(embedded["signatures"]) != str(committed["signatures"]):
		problems.append("the embedded document differs from %s" % highest_name)
	var own_roots := TrustChain.read_self_signed(embedded_text.to_utf8_buffer())
	if not str(own_roots["error"]).is_empty():
		problems.append("the embedded document: %s" % own_roots["error"])
	return problems


# The number in a file named trust-N.json, or 0 for any other name, a leading zero included.
static func _number_in(file_name: String) -> int:
	var number := file_name.trim_prefix("trust-").trim_suffix(".json").to_int()
	return number if number >= 1 and file_name == _file_name(number) else 0


static func _file_name(number: int) -> String:
	return "trust-%d.json" % number


# The two outer fields of a document file, null where absent or the text is not an object.
static func _outer_fields(file_text: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(file_text) != OK or not json.data is Dictionary:
		return {"document": null, "signatures": null}
	var outer: Dictionary = json.data
	return {"document": outer.get("document", null), "signatures": outer.get("signatures", null)}
