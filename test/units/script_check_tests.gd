@tool
extends RefCounted
## script_check's compile probe and the script's class_name: the probe renames
## the declaration, so the one-line form "class_name X extends Y" keeps its base
## class, self typed as the script's own class compiles, and a name that clashes
## is reported as the engine reports it. The probe compiles under a path in the
## file's folder, so a relative preload and the folder's warning rules apply as
## they do to the file, and leaves nothing under that path once compiled.
## Covers _validate_gdscript, the script_check handler, the stale-instance
## hint's source_compiles and print_compile_errors, which share the probe. Cases
## marked with a minimum version use syntax older versions lack, and the
## documented limitations that differ by version expect each version's own
## result; every other assertion holds on every supported version.

const ScriptCommands := preload("res://addons/godot_mcp_toolkit/commands/script_commands.gd")
const StaleInstanceHint := preload("res://addons/godot_mcp_toolkit/versioning/stale_instance_hint.gd")
const LogBuffer := preload("res://addons/godot_mcp_toolkit/logging/log_buffer.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")
const GDScriptSource := preload("res://addons/godot_mcp_toolkit/core/gdscript_source.gd")
const EditorLogReader := preload("res://addons/godot_mcp_toolkit/commands/editor/editor_log_reader.gd")
const Testing := preload("res://test/units/testing.gd")

const ONE_LINE_FIXTURE := "res://test/fixtures/one_line_class_name_fixture.gd"
# Registered global classes the case table reuses: a case that declares one of
# these names under its fixture's path is an edited copy of that file.
const SINGLETON_FIXTURE := "res://test/fixtures/script_check_singleton_fixture.gd"
const SINGLETON := "MCPToolkitProbeSingleton"
const SELF_TYPED_FIXTURE := "res://test/fixtures/script_check_self_typed_fixture.gd"
const SELF_TYPED := "MCPToolkitProbeSelfTyped"
# Passes self to the parameter of script_check_cross_b_fixture.gd typed with
# this file's class_name.
const CROSS_A_FIXTURE := "res://test/fixtures/script_check_cross_a_fixture.gd"
const CROSS_A := "MCPToolkitProbeCrossA"
const CROSS_B := "MCPToolkitProbeCrossB"
# A name no script registers.
const FREE_NAME := "MCPToolkitProbeFree"
# The probe's class suffix, which no diagnostic may carry.
const PROBE_SUFFIX := "__McpProbe"
# What the probe adds to the file's path to make its own, which no console text
# editor_get_console returns may carry.
const PROBE_PATH_MARKER := ".__mcp_probe_"
# A body that compiles only on a Node base.
const NODE_BODY := "\n\nfunc attach_child() -> void:\n\tadd_child(Node.new())\n"

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
	_test_case_table(testing)
	_test_script_check_self_typed_files(testing)
	_test_source_compiles_self_typed(testing)
	_test_script_check_cross_script_self(testing)
	_test_probe_compiles_as_the_file(testing)
	_test_probe_errors_name_the_file(testing)
	_test_probe_leaves_no_copy_to_save(testing)


# --- _validate_gdscript, no file_path ---------------------------------------

static func _test_validate_one_line_form(testing) -> void:
	testing.begin("script_check probe keeps a one-line class_name's base class")
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


# --- the case table ---------------------------------------------------------
# One case per family of class_name placements, self typing and name clashes.
# "valid" is the real file's result under its real path; the cases marked
# "documented limitation" pin the probe's known residuals instead.

static func _test_case_table(testing) -> void:
	testing.begin("script_check case table: the probe matches the real file")
	LogBuffer.setup()
	var minor := VersionUtils.get_engine_version_ints().y
	for case: Dictionary in _cases(minor):
		var label := str(case["label"])
		if minor < int(case.get("min_minor", 2)):
			print("  SKIP: %s (needs 4.%d)" % [label, int(case["min_minor"])])
			continue
		var result := ScriptCommands._validate_gdscript(str(case["source"]), str(case["path"]))
		var expected_valid := bool(case["valid"])
		testing.eq(bool(result.get("valid", not expected_valid)), expected_valid,
				"%s → valid %s" % [label, expected_valid])
		var diagnostics: Array = result.get("diagnostics", [])
		testing.ok(not JSON.stringify(diagnostics).contains(PROBE_SUFFIX),
				"%s → no diagnostic names the probe's class" % label)
		if case.has("conflict"):
			_check_conflict(testing, label, diagnostics, str(case["conflict"]), int(case["line"]))
		if case.has("error_line") and LogBuffer.uses_logger_api():
			var error_diagnostic := _last_error(diagnostics)
			testing.eq(int(error_diagnostic.get("line", -1)), int(case["error_line"]),
					"%s → the compile error's real line" % label)
		if bool(case.get("compile_error_too", false)):
			var last_message := str(_last_error(diagnostics).get("message", ""))
			testing.ok(diagnostics.size() >= 2 and last_message != str(case["conflict"]),
					"%s → the compile error is reported beside the clash" % label)
	print("")


static func _check_conflict(testing, label: String, diagnostics: Array, message: String,
		line: int) -> void:
	var first: Dictionary = diagnostics[0] if diagnostics.size() > 0 else {}
	testing.eq(str(first.get("message", "")), message, "%s → the engine's clash message" % label)
	testing.eq(int(first.get("line", -1)), line, "%s → the clash's line" % label)


static func _last_error(diagnostics: Array) -> Dictionary:
	var found := {}
	for diagnostic: Dictionary in diagnostics:
		if str(diagnostic.get("severity", "")) == "error":
			found = diagnostic
	return found


static func _cases(minor: int) -> Array:
	var progress_dialog_known := ClassDB.class_exists("ProgressDialog")
	return [
		# --- valid: where the declaration sits -----------------------------
		{"label": "two-line header", "valid": true, "path": "",
			"source": "class_name %s\nextends Node\n%s" % [FREE_NAME, NODE_BODY]},
		{"label": "@tool class_name X extends Node on one line", "valid": true,
			"path": SELF_TYPED_FIXTURE,
			"source": "@tool class_name %s extends Node\n%s" % [SELF_TYPED, NODE_BODY]},
		{"label": "@abstract class_name X extends Node on one line", "valid": true,
			"min_minor": 5, "path": SELF_TYPED_FIXTURE,
			"source": "@abstract class_name %s extends Node\n%s" % [SELF_TYPED, NODE_BODY]},
		{"label": "@abstract above a class_name with no extends", "valid": true,
			"min_minor": 5, "path": SELF_TYPED_FIXTURE,
			"source": "@abstract\nclass_name %s\n\n\nvar sides := 0\n" % SELF_TYPED},
		{"label": "@warning_ignore above a class_name with no extends", "valid": true,
			"min_minor": 3, "path": "",
			"source": ("@warning_ignore(\"unused_signal\")\nclass_name %s\n\n\n"
				+ "enum State { IDLE, RUN }\n\nsignal changed\n") % FREE_NAME},
		{"label": "a docstring line that starts with class_name", "valid": true,
			"path": SELF_TYPED_FIXTURE,
			"source": "\"\"\"\nclass_name %s drives the player.\n\"\"\"\nclass_name %s\nextends Node\n%s" % [
				SELF_TYPED, SELF_TYPED, NODE_BODY]},
		{"label": "extends Node; class_name X", "valid": true, "path": SELF_TYPED_FIXTURE,
			"source": "extends Node; class_name %s\n%s" % [SELF_TYPED, NODE_BODY]},
		{"label": "a \\ continuation between class_name and the name", "valid": true,
			"path": SELF_TYPED_FIXTURE,
			"source": "class_name \\\n%s extends Node\n%s" % [SELF_TYPED, NODE_BODY]},
		{"label": "class_name X;;", "valid": true, "path": "",
			"source": "class_name %s;;\nextends Node\n%s" % [FREE_NAME, NODE_BODY]},
		# --- valid: self typed as the script's own class --------------------
		{"label": "-> X: return self", "valid": true, "path": SELF_TYPED_FIXTURE,
			"source": "class_name %s\nextends Node\n\n\nfunc with_speed() -> %s:\n\treturn self\n" % [
				SELF_TYPED, SELF_TYPED]},
		{"label": "var me: X = self", "valid": true, "path": SELF_TYPED_FIXTURE,
			"source": "class_name %s\nextends Node\n\n\nfunc own() -> Node:\n\tvar me: %s = self\n\treturn me\n" % [
				SELF_TYPED, SELF_TYPED]},
		{"label": "self as X", "valid": true, "path": SELF_TYPED_FIXTURE,
			"source": "class_name %s\nextends Node\n\n\nfunc own() -> Object:\n\treturn self as %s\n" % [
				SELF_TYPED, SELF_TYPED]},
		{"label": "take(self) to a parameter typed X", "valid": true, "path": SELF_TYPED_FIXTURE,
			"source": ("class_name %s\nextends Node\n\n\nfunc register_self() -> void:\n\ttake(self)\n\n\n"
				+ "func take(_other: %s) -> void:\n\tpass\n") % [SELF_TYPED, SELF_TYPED]},
		{"label": "X.CONST beside self typing", "valid": true, "path": SELF_TYPED_FIXTURE,
			"source": ("class_name %s\nextends Node\n\nconst MAX_HP := 3\n\n\n"
				+ "func own() -> int:\n\tvar me: %s = self\n\treturn %s.MAX_HP + me.get_child_count()\n") % [
					SELF_TYPED, SELF_TYPED, SELF_TYPED]},
		{"label": "an inner class extending X beside self typing", "valid": true,
			"path": SELF_TYPED_FIXTURE,
			"source": ("class_name %s\nextends Node\n\n\nclass Special extends %s:\n\tpass\n\n\n"
				+ "func own() -> Node:\n\tvar me: %s = self\n\treturn me\n") % [
					SELF_TYPED, SELF_TYPED, SELF_TYPED]},
		{"label": "instance = self beside an X.new() factory", "valid": true,
			"path": SINGLETON_FIXTURE,
			"source": ("class_name %s\nextends Node\n\nstatic var instance: %s\n\n\n"
				+ "static func create() -> %s:\n\treturn %s.new()\n\n\n"
				+ "func _enter_tree() -> void:\n\tinstance = self\n") % [
					SINGLETON, SINGLETON, SINGLETON, SINGLETON]},
		{"label": "a builder returning self beside X.new()", "valid": true,
			"path": SINGLETON_FIXTURE,
			"source": ("class_name %s\nextends Node\n\nvar speed := 0.0\n\n\n"
				+ "func with_speed(value: float) -> %s:\n\tspeed = value\n\treturn self\n\n\n"
				+ "static func make() -> %s:\n\treturn %s.new().with_speed(1.0)\n") % [
					SINGLETON, SINGLETON, SINGLETON, SINGLETON]},
		# --- valid: a name ClassDB knows but does not expose ----------------
		{"label": "class_name ProgressDialog (in ClassDB here: %s)" % progress_dialog_known,
			"valid": true, "path": "", "source": "class_name ProgressDialog\nextends Node\n"},
		# --- invalid: a malformed or misplaced declaration ------------------
		{"label": "class_name with no name", "valid": false, "path": "",
			"source": "class_name \nextends Node\n%s" % NODE_BODY},
		{"label": "Godot 3's icon form", "valid": false, "path": "",
			"source": "class_name %s, \"res://icon.svg\"\nextends Node\n%s" % [FREE_NAME, NODE_BODY]},
		{"label": "class_name X:", "valid": false, "path": "",
			"source": "class_name %s:\nextends Node\n%s" % [FREE_NAME, NODE_BODY]},
		{"label": "@tool below class_name", "valid": false, "path": "",
			"source": "class_name %s\n@tool\nextends Node\n%s" % [FREE_NAME, NODE_BODY]},
		{"label": "class_name after a member", "valid": false, "path": "",
			"source": "extends Node\n\n@export var speed := 2.0\nclass_name %s\n" % FREE_NAME},
		# --- invalid: a name that clashes, reported with its line ----------
		{"label": "another file's class_name", "valid": false,
			"path": "res://test/fixtures/not_the_owner.gd",
			"source": "class_name %s\nextends Node\n" % SELF_TYPED,
			"conflict": "Class \"%s\" hides a global script class." % SELF_TYPED, "line": 1},
		{"label": "the autoload's name MCPRuntimeServer", "valid": false,
			"path": "res://test/fixtures/not_the_autoload.gd",
			"source": "class_name MCPRuntimeServer\nextends Node\n",
			"conflict": "Class \"MCPRuntimeServer\" hides an autoload singleton.", "line": 1},
		{"label": "a clash below a header comment", "valid": false, "path": "",
			"source": "# Game state.\n## Holds the score.\n\nclass_name MCPRuntimeServer\nextends Node\n",
			"conflict": "Class \"MCPRuntimeServer\" hides an autoload singleton.", "line": 4},
		{"label": "a native class name", "valid": false, "path": "",
			"source": "class_name Sprite2D\nextends Node\n",
			"conflict": "Class \"Sprite2D\" hides a native class.", "line": 1},
		{"label": "a built-in type name", "valid": false, "path": "",
			"source": "class_name Plane\nextends Node\n",
			"conflict": "Class \"Plane\" hides a built-in type.", "line": 1},
		{"label": "a clash beside a syntax error", "valid": false, "path": "",
			"source": "class_name MCPRuntimeServer\nextends Node\n\nvar = = =\n",
			"conflict": "Class \"MCPRuntimeServer\" hides an autoload singleton.", "line": 1,
			"compile_error_too": true},
		# The analyzer counts an abstract engine class; 4.2-4.3 cannot tell it
		# from an unexposed one, a documented limitation there.
		_abstract_engine_class_case(minor),
		# --- invalid: the compile error's real line --------------------------
		{"label": "a missing extends path", "valid": false, "path": "",
			"source": "class_name %s\nextends \"res://test/fixtures/does_not_exist.gd\"\n" % FREE_NAME,
			"error_line": 1},
		# On 4.5+ the keep-name compile reports the clash and this error, and
		# only a single clash may pass the script.
		{"label": "an error after a self line", "valid": false, "path": SELF_TYPED_FIXTURE,
			"source": ("class_name %s\nextends Node\n\n\nfunc with_speed() -> %s:\n\treturn self\n\n\n"
				+ "func broken() -> int:\n\treturn \"text\"\n") % [SELF_TYPED, SELF_TYPED],
			"error_line": 10},
		# On 4.5+ the keep-name compile reports the clash and the missing base
		# on the same line: two errors, so the script stays invalid.
		{"label": "a second error on the declaration's line", "valid": false,
			"path": SELF_TYPED_FIXTURE,
			"source": "class_name %s extends MCPToolkitProbeMissingBase\n" % SELF_TYPED},
		# --- documented limitations, pinned ---------------------------------
		_preloaded_alias_case(minor),
		_cross_script_codegen_case(minor),
		{"label": "documented limitation: a codegen-only error beside self typing and X.new()",
			"valid": true, "path": SINGLETON_FIXTURE,
			"source": ("class_name %s\nextends Node\n\nstatic var instance: %s\n\n\n"
				+ "static func create() -> %s:\n\treturn %s.new()\n\n\n"
				+ "func _init() -> void:\n\tinstance = self\n\n\n"
				+ "var hp: int = 0:\n\tget:\n\t\treturn self.hp\n") % [
					SINGLETON, SINGLETON, SINGLETON, SINGLETON]},
		{"label": "documented limitation: a member named like the class, used dotted and as a type",
			"valid": false, "path": "",
			"source": ("class_name %s\nextends Node\n\nenum Team { %s, Enemy }\n"
				+ "var t := Team.%s\n\n\nfunc me() -> %s:\n\treturn self\n") % [
					FREE_NAME, FREE_NAME, FREE_NAME, FREE_NAME]},
	]


static func _abstract_engine_class_case(minor: int) -> Dictionary:
	var case := {"label": "class_name CanvasItem", "path": "",
		"source": "class_name CanvasItem\nextends Node\n"}
	if minor >= 4:
		case["valid"] = false
		case["conflict"] = "Class \"CanvasItem\" hides a native class."
		case["line"] = 1
	else:
		case["label"] = "documented limitation: class_name CanvasItem on 4.2-4.3"
		case["valid"] = true
	return case


# A self-typed variable whose type is a preload of the script's own file is
# the class other scripts name, which only the 4.5+ keep-name compile sees.
static func _preloaded_alias_case(minor: int) -> Dictionary:
	var case := {"label": "a preloaded alias of the script itself", "valid": true,
		"path": SELF_TYPED_FIXTURE,
		"source": ("class_name %s\nextends Node\n\nconst Self = preload(\"%s\")\n\n\n"
			+ "func own() -> Node:\n\tvar me: Self = self\n\treturn me\n") % [
				SELF_TYPED, SELF_TYPED_FIXTURE]}
	if minor < 5:
		case["label"] = "documented limitation on 4.2-4.4: a preloaded alias of the script itself"
		case["valid"] = false
	return case


# The real file fails in codegen (self.hp inside hp's own getter). On 4.5+ the
# keep-name compile stops at its class-name clash before codegen, so the
# script reads as valid there.
static func _cross_script_codegen_case(minor: int) -> Dictionary:
	var case := {"label": "a codegen-only error beside self passed to another script",
		"valid": false, "path": CROSS_A_FIXTURE,
		"source": ("class_name %s\nextends RefCounted\n\n"
			+ "var hp: int = 0:\n\tget:\n\t\treturn self.hp\n\n\n"
			+ "func register_with_partner() -> void:\n\t%s.new().take(self)\n") % [
				CROSS_A, CROSS_B]}
	if minor >= 5:
		case["label"] = "documented limitation on 4.5+: " + str(case["label"])
		case["valid"] = true
	return case


# --- self-typed fixtures through the handler, reading the file ---------------

static func _test_script_check_self_typed_files(testing) -> void:
	testing.begin("script_check handler: self typed as the script's own class")
	LogBuffer.setup()
	for fixture: String in [SINGLETON_FIXTURE, SELF_TYPED_FIXTURE]:
		var result := ScriptCommands._cmd_script_check({"file_path": fixture})
		testing.ok(bool(result.get("valid", false)), "%s → valid true" % fixture.get_file())
		testing.eq((result.get("diagnostics", []) as Array).size(), 0,
				"%s → no diagnostics" % fixture.get_file())
	print("")


static func _test_source_compiles_self_typed(testing) -> void:
	testing.begin("source_compiles: self typed as the script's own class")
	var source := FileAccess.get_file_as_string(SINGLETON_FIXTURE)
	testing.ok(StaleInstanceHint.source_compiles(source, SINGLETON_FIXTURE),
			"singleton with a factory, under its own path → compiles")
	testing.ok(not StaleInstanceHint.source_compiles(source, "res://test/fixtures/not_the_owner.gd"),
			"the same source under another path → its class_name clashes")
	print("")


# --- self passed to another script's typed parameter -------------------------
# The analyzer matches class types by class_name, so only a compile that keeps
# the name can type self as the other script expects. Below 4.5 the toolkit
# cannot read that compile's errors back, a documented limitation there.

static func _test_script_check_cross_script_self(testing) -> void:
	testing.begin("script_check handler: self passed to another script's typed parameter")
	LogBuffer.setup()
	var since_id := LogBuffer.get_cursor() - 1
	var result := ScriptCommands._cmd_script_check({"file_path": CROSS_A_FIXTURE})
	testing.ok(bool(result.get("success", false)), "handler succeeds")
	if VersionUtils.is_at_least(VersionUtils.get_engine_version_pair(), "4.5"):
		testing.ok(bool(result.get("valid", false)), "4.5+ → valid true")
		testing.eq((result.get("diagnostics", []) as Array).size(), 0, "4.5+ → no diagnostics")
		var clashes := LogBuffer.get_entries(500, [], since_id, "hides a global script class.")
		testing.eq(int(clashes["total_lines"]), 0,
				"4.5+ → the console buffer keeps no clash from the check")
	else:
		testing.ok(not bool(result.get("valid", true)),
				"documented limitation on 4.2-4.4 → valid false")
	print("")


# --- the file's path decides what the engine decides by it -------------------
# The engine resolves a relative preload against the script's folder and
# applies the project's warning rules by the script's path; the default rule
# skips warnings under res://addons. The paths name no file: only their folder
# matters.

static func _test_probe_compiles_as_the_file(testing: Testing) -> void:
	testing.begin("script_check probe compiles as the file at its path")
	LogBuffer.setup()
	var relative_preload := (
		"extends RefCounted\n\n"
		+ "const Element := preload(\"typed_array_element.gd\")\n"
	)
	var beside_target := ScriptCommands._validate_gdscript(relative_preload,
			"res://test/fixtures/uses_relative_preload.gd")
	testing.ok(bool(beside_target.get("valid", false)),
			"a relative preload of a file in the script's folder → valid true")
	testing.eq((beside_target.get("diagnostics", []) as Array).size(), 0,
			"a relative preload of a file in the script's folder → no diagnostics")
	var away_from_target := ScriptCommands._validate_gdscript(relative_preload,
			"res://test/units/uses_relative_preload.gd")
	testing.ok(not bool(away_from_target.get("valid", true)),
			"a relative preload of a file missing from the script's folder → valid false")
	if LogBuffer.uses_logger_api():
		testing.ok(JSON.stringify(away_from_target.get("diagnostics", [])).contains(
					"preload('res://test/units/typed_array_element.gd') failed"),
				"a relative preload of a missing file → the hint names it in the script's folder")
	var node_read_too_early := "extends Node\n\nvar target: Node = get_node(\"Target\")\n"
	testing.ok(bool(ScriptCommands._validate_gdscript(node_read_too_early,
					"res://addons/mcp_toolkit_unit_probe/held_node.gd").get("valid", false)),
			"a warning the project treats as an error, under res://addons → valid true")
	testing.ok(not bool(ScriptCommands._validate_gdscript(node_read_too_early,
					"res://test/fixtures/held_node.gd").get("valid", true)),
			"the same warning outside res://addons → valid false")
	print("")


# The engine reports a compile error under the compiling script's path, and
# only the 4.7+ capture keeps that path in the console text, which
# editor_get_console reads from the buffer.
static func _test_probe_errors_name_the_file(testing: Testing) -> void:
	testing.begin("script_check probe's console errors name the file, not the copy")
	LogBuffer.setup()
	var since_id := LogBuffer.get_cursor() - 1
	var result := ScriptCommands._validate_gdscript(
			"extends Node\n\n\nfunc broken() -> int:\n\treturn \"text\"\n",
			"res://test/fixtures/returns_text_as_int.gd")
	testing.ok(not bool(result.get("valid", true)), "a type error → valid false")
	if LogBuffer.uses_logger_api() \
			and VersionUtils.is_at_least(VersionUtils.get_engine_version_pair(), "4.7"):
		var console := JSON.stringify(EditorLogReader.cmd_get_console(null,
				{"since_id": since_id, "level_filter": ["error"]}))
		testing.ok(console.contains(
					"at: GDScript::reload (res://test/fixtures/returns_text_as_int.gd:5)"),
				"4.7+ → editor_get_console names the file and the error's line")
		testing.ok(not console.contains(PROBE_PATH_MARKER),
				"4.7+ → editor_get_console names no copy's path")
	print("")


# The engine keeps a compiled copy alive, and the editor saves to disk every
# edited resource the resource cache holds under a res:// path at each scene
# save. Every compile of the probe takes the same step off that path;
# print_compile_errors is the one that names the copy's path.
static func _test_probe_leaves_no_copy_to_save(testing: Testing) -> void:
	testing.begin("script_check probe leaves no copy under a res:// path")
	var copy_path := GDScriptSource.print_compile_errors("extends RefCounted\n",
			"res://test/fixtures/compiled_copy.gd")
	testing.ok(copy_path.begins_with("res://test/fixtures/compiled_copy.gd"),
			"a copy of a file → compiles under a path that begins with the file's")
	testing.ok(not ResourceLoader.has_cached(copy_path),
			"after the compile → no resource is cached under the copy's path")
	print("")
