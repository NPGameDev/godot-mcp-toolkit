@tool
extends RefCounted
## script_check's class_name strip on the one-line form "class_name X extends Y":
## the strip keeps the rest of the line, so the probe keeps its base class.
## Covers _validate_gdscript, the script_check handler and the stale-instance
## hint's source_compiles, which share the strip. Every assertion holds on every
## supported version.

const ScriptCommands := preload("res://addons/godot_mcp_toolkit/commands/script_commands.gd")
const StaleInstanceHint := preload("res://addons/godot_mcp_toolkit/versioning/stale_instance_hint.gd")
const LogBuffer := preload("res://addons/godot_mcp_toolkit/logging/log_buffer.gd")

const ONE_LINE_FIXTURE := "res://test/fixtures/one_line_class_name_fixture.gd"

# The one-line form with a body that compiles only on a Node base: a probe that
# lost "extends Node" falls back to RefCounted, which has no add_child().
const ONE_LINE_SOURCE := (
	"class_name MCPToolkitUnitOneLineProbe extends Node\n\n\n"
	+ "func attach_child() -> void:\n\tadd_child(Node.new())\n"
)


static func run(testing) -> void:
	_test_validate_one_line_form(testing)
	_test_script_check_one_line_file(testing)
	_test_source_compiles_one_line_form(testing)


# --- _validate_gdscript, no file_path ---------------------------------------

static func _test_validate_one_line_form(testing) -> void:
	testing.begin("script_check strip keeps a one-line class_name's base class")
	LogBuffer.setup()
	var result := ScriptCommands._validate_gdscript(ONE_LINE_SOURCE)
	testing.ok(bool(result.get("valid", false)), "one-line class_name form → valid true")
	testing.eq((result.get("diagnostics", []) as Array).size(), 0,
			"one-line class_name form → no diagnostics")
	print("")


# --- the script_check handler, reading the file ------------------------------

static func _test_script_check_one_line_file(testing) -> void:
	testing.begin("script_check handler: one-line class_name form in a file")
	LogBuffer.setup()
	var result := ScriptCommands._cmd_script_check({"file_path": ONE_LINE_FIXTURE})
	testing.ok(bool(result.get("success", false)), "handler succeeds")
	testing.ok(bool(result.get("valid", false)), "one-line class_name file → valid true")
	testing.eq((result.get("diagnostics", []) as Array).size(), 0,
			"one-line class_name file → no diagnostics")
	print("")


# --- the stale-instance hint's compile check --------------------------------

static func _test_source_compiles_one_line_form(testing) -> void:
	testing.begin("source_compiles keeps a one-line class_name's base class")
	testing.ok(StaleInstanceHint.source_compiles(ONE_LINE_SOURCE),
			"one-line class_name form → compiles")
	print("")
