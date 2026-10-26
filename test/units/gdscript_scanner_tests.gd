@tool
extends RefCounted
## Pins GDScriptScanner (core/gdscript_scanner.gd): identifiers are read outside
## strings and comments, and the inner classes a source declares come back nested
## by indentation. The class_name rename's cases in paths_versioning_tests.gd pin
## the same identifier scan through GDScriptSource.

const Testing := preload("res://test/units/testing.gd")
const GDScriptScanner := preload("res://addons/godot_mcp_toolkit/core/gdscript_scanner.gd")

const _NESTED_SOURCE := (
	"extends RefCounted\n\n\nclass Outer:\n\tclass Deep extends Node:\n\t\tpass\n\n"
	+ "\tfunc answer() -> int:\n\t\treturn 42\n\n\nfunc run() -> void:\n\tpass\n\n\n"
	+ "class Second:\n\tpass\n"
)
const _QUOTED_SOURCE := (
	"extends RefCounted\n\n# class Commented:\nconst SINGLE := \"class Single\"\n"
	+ "const RAW := r'class Raw'\nconst TRIPLE := \"\"\"\nclass Triple:\n\"\"\"\n"
)


static func run(testing: Testing) -> void:
	_test_next_identifier_skips_strings_and_comments(testing)
	_test_declared_classes_nest_by_indentation(testing)
	_test_declared_classes_skip_strings_and_comments(testing)


static func _test_next_identifier_skips_strings_and_comments(testing: Testing) -> void:
	testing.begin("GDScriptScanner.next_identifier: strings and comments hold no identifier")
	var source := "# note\n\"text\" 'more' \"\"\"\nblock\n\"\"\" name"
	testing.eq(GDScriptScanner.next_identifier(source, 0), Vector2i(35, 39),
			"a comment, then three strings, then name → name's start and end")
	testing.eq(GDScriptScanner.next_identifier(source, 39), Vector2i(-1, -1),
			"past the last identifier → (-1, -1)")
	print("")


static func _test_declared_classes_nest_by_indentation(testing: Testing) -> void:
	testing.begin("GDScriptScanner.declared_classes: a class sits under the class it is indented in")
	var declared := GDScriptScanner.declared_classes(_NESTED_SOURCE)
	testing.eq(declared, {"Outer": {"Deep": {}}, "Second": {}},
			"a nested class, then a function, then a root class → Outer.Deep and Second")
	print("")


static func _test_declared_classes_skip_strings_and_comments(testing: Testing) -> void:
	testing.begin("GDScriptScanner.declared_classes: class in a string or comment declares nothing")
	testing.eq(GDScriptScanner.declared_classes(_QUOTED_SOURCE), {},
			"class in a comment and in plain, raw and triple-quoted strings → no class")
	print("")
