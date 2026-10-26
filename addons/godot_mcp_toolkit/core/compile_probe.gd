@tool
extends RefCounted
## Compiles the compile probe: an in-memory [code]GDScript.new()[/code] copy of a
## script's source, compiled as if it sat beside the file it stands for.
##
## The copy takes a path in the file's own folder, so a relative
## [code]preload()[/code] or [code]extends[/code] resolves as it does in the
## file, and the project's warning rules keyed on the file's path, such as the
## exemption for [code]res://addons/[/code], apply to it. After the compile the
## copy is emptied and its path cleared, so it can be released without touching
## the scripts its source loaded, and nothing is left under its path.

# A direct preload, not core/modules.gd: the aggregator preloads this file.
const GDScriptScanner := preload("res://addons/godot_mcp_toolkit/core/gdscript_scanner.gd")

## Appended to the file's path to name the copy, with the copy's instance id.
## Engine messages about the copy carry it.
const PATH_SUFFIX_FORMAT := ".__mcp_probe_%d.gd"
## Matches [constant PATH_SUFFIX_FORMAT] in text. A [RefCounted]'s instance id
## prints negative.
const PATH_SUFFIX_PATTERN := "\\.__mcp_probe_-?\\d+\\.gd"
# The source a copy is emptied to before it is released.
const _EMPTY_SOURCE := "extends RefCounted\n"

# Copies that could not be emptied. Releasing one would clear the scripts it
# loaded, so they stay alive here instead.
static var _unreleased_copies: Array[GDScript] = []


## Compiles [param source] as the file at [param file_path] would compile, with
## the engine's error printing set to [param prints_errors] for the compile only.
##
## With printing on, the 4.5+ Logger capture records the compile's script errors
## under the returned path while it runs, so they stay readable after the path is
## cleared. An empty [param file_path] stands for source with no file: the copy
## compiles under the path the engine gives a script without one.
##
## Returns [code]{error, path, script}[/code]: [code]error[/code] is the
## compile's [enum Error]; [code]path[/code] is the path the copy compiled under,
## which the engine's messages about it name; [code]script[/code] is the copy,
## emptied to a bare [RefCounted] script with its
## [member Resource.resource_path] cleared, unless its inner classes could not
## be emptied, when it keeps its compiled source and stays alive.
static func compile(source: String, file_path: String, prints_errors: bool) -> Dictionary:
	var probe := GDScript.new()
	probe.source_code = source
	# The engine names a script with no file gdscript://<instance id>.gd.
	var probe_path := "gdscript://%d.gd" % probe.get_instance_id()
	if file_path != "":
		probe_path = canonical_path(file_path) + PATH_SUFFIX_FORMAT % probe.get_instance_id()
		probe.resource_path = probe_path
	var printed_errors := Engine.print_error_messages
	# Only reload() runs with the caller's printing changed: GDScript has no
	# `finally`, and a runtime error here would leave the editor's setting changed.
	Engine.print_error_messages = prints_errors
	var error := probe.reload(false)
	Engine.print_error_messages = printed_errors
	_empty_for_release(probe, source)
	return {"error": error, "path": probe_path, "script": probe}


## Returns [param path] as a simplified [code]res://[/code] path, the form the
## global class list records a script's file in.
static func canonical_path(path: String) -> String:
	return ProjectSettings.localize_path(path).simplify_path()


# Up to 4.5 a script the engine frees clears every script it depends on that no
# other live script needs, so a held helper the copy preloaded would lose its
# code. A recompile empties the copy's constants and functions without that
# clear, so the copy is recompiled to a source with no dependencies first.
# A recompile drops the copy's inner classes, though, and each dropped inner class
# clears its own dependencies the same way: the first recompile keeps the state
# and declares the same inner classes, empty, so the engine reuses each one in
# place. An inner class resolves through its root's path, so that recompile
# runs before the path is cleared.
static func _empty_for_release(probe: GDScript, source: String) -> void:
	var inner_classes := _empty_inner_classes(probe, GDScriptScanner.declared_classes(source), 0)
	var emptied_inner_classes := OK
	if inner_classes != "":
		probe.source_code = _EMPTY_SOURCE + inner_classes
		var printed_errors := Engine.print_error_messages
		Engine.print_error_messages = false
		emptied_inner_classes = probe.reload(true)
		Engine.print_error_messages = printed_errors
	# Clearing re-keys the copy's script-cache entry to "" and drops it from the
	# resource cache, so the next copy replaces it there and nothing on disk is
	# ever looked up for it.
	probe.resource_path = ""
	if emptied_inner_classes != OK:
		# The inner classes still hold their dependencies: emptying the root now
		# would drop them and clear those.
		_unreleased_copies.append(probe)
		return
	probe.source_code = _EMPTY_SOURCE
	# A bare extends of a native class always compiles.
	probe.reload(false)


# Returns the inner classes of `script` that `declared` names, in the shape
# GDScriptScanner.declared_classes returns, each with an empty body, as source
# indented `depth` levels. Each class is looked up by name in
# its enclosing class's constants, so a constant naming another class, the
# copy's own or another file's, is never taken for a declaration, and a class
# the compile did not produce is left out.
static func _empty_inner_classes(script: GDScript, declared: Dictionary, depth: int) -> String:
	var text := ""
	var indent := "\t".repeat(depth)
	var constants := script.get_script_constant_map()
	for class_name_text: String in declared:
		var value: Variant = constants.get(class_name_text)
		if not value is GDScript:
			continue
		var inner: GDScript = value
		var nested: Dictionary = declared[class_name_text]
		text += "%sclass %s:\n%s\tpass\n" % [indent, class_name_text, indent]
		text += _empty_inner_classes(inner, nested, depth + 1)
	return text
