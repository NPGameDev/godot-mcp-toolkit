@tool
extends RefCounted
## Pins the compile probe: CompileProbe compiles a copy of a script beside its file,
## so relative paths and the project's warning rules apply as they do to the file,
## or with no path under the project's script-templates folder, and leaves no
## path, cache entry or live copy behind, nor a script it loaded damaged. The
## verdicts are read through GDScriptSource.judge, and the error line through
## script_check's diagnostics.

const Testing := preload("res://test/units/testing.gd")
const CompileProbe := preload("res://addons/godot_mcp_toolkit/core/compile_probe.gd")
const GDScriptSource := preload("res://addons/godot_mcp_toolkit/core/gdscript_source.gd")
const ScriptCommands := preload("res://addons/godot_mcp_toolkit/commands/script_commands.gd")
const LogBuffer := preload("res://addons/godot_mcp_toolkit/logging/log_buffer.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")

# A file beside compile_probe_sibling.gd; no file exists at this path.
const _USER_PATH := "res://test/fixtures/compile_probe_user.gd"
const _SIBLING_FIXTURE := "res://test/fixtures/compile_probe_sibling.gd"
# No case before the held-dependency one preloads these helpers, so no copy an
# earlier case left alive depends on them.
const _PRELOAD_HELPER_FIXTURE := "res://test/fixtures/compile_probe_preload_helper.gd"
const _INNER_HELPER_FIXTURE := "res://test/fixtures/compile_probe_inner_helper.gd"
const _NESTED_HELPER_FIXTURE := "res://test/fixtures/compile_probe_nested_helper.gd"
const _ALIAS_HELPER_FIXTURE := "res://test/fixtures/compile_probe_alias_helper.gd"
const _PRELOAD_SOURCE := (
	"extends RefCounted\n\nconst Helper := preload(\"compile_probe_preload_helper.gd\")\n"
)
const _INNER_PRELOAD_SOURCE := (
	"extends RefCounted\n\n\nclass Inner:\n"
	+ "\tconst Helper := preload(\"compile_probe_inner_helper.gd\")\n"
)
const _NESTED_PRELOAD_SOURCE := (
	"extends RefCounted\n\n\nclass Outer:\n\tclass Deep:\n"
	+ "\t\tconst Helper := preload(\"compile_probe_nested_helper.gd\")\n"
)
# A class's constants enter its constant map before its inner classes, so the
# root constant comes first there, under the nested class's own name.
const _NESTED_ALIAS_SOURCE := (
	"extends RefCounted\n\nconst Deep := Inner.Deep\n\n\nclass Inner:\n\tclass Deep:\n"
	+ "\t\tconst Helper := preload(\"compile_probe_alias_helper.gd\")\n"
)
# MCPToolkitError is a global class: a copy emptied with an inner class of that
# name does not compile, so it would be kept rather than released.
const _FOREIGN_ALIAS_SOURCE := (
	"extends RefCounted\n\n"
	+ "const MCPToolkitError := preload(\"res://test/fixtures/compile_probe_holder.gd\").Held\n"
)
const _COMMENTED_CLASS_SOURCE := _FOREIGN_ALIAS_SOURCE + "\n# class MCPToolkitError:\n"
const _QUOTED_CLASS_SOURCE := (
	_FOREIGN_ALIAS_SOURCE + "\nconst NOTE := \"\"\"\nclass MCPToolkitError:\n\"\"\"\n"
)
# With no file, a relative path has no folder to resolve against.
const _INNER_RES_PRELOAD_SOURCE := (
	"extends RefCounted\n\n\nclass Inner:\n"
	+ "\tconst Helper := preload(\"res://test/fixtures/compile_probe_inner_helper.gd\")\n"
)
# A preload and an inner class, the two ways a copy holds other scripts. A
# source with a static var is left out: the engine keeps every script with
# static variables in a cache of its own, so each such copy stays alive.
const _LEAK_SOURCE := (
	"extends RefCounted\n\nconst Sibling := preload(\"compile_probe_sibling.gd\")\n\n\n"
	+ "class Inner:\n\tconst Helper := preload(\"compile_probe_sibling.gd\")\n"
)
const _CROSS_A_FIXTURE := "res://test/fixtures/script_check_cross_a_fixture.gd"
const _RELATIVE_PRELOAD_SOURCE := (
	"extends RefCounted\n\nconst Sibling := preload(\"compile_probe_sibling.gd\")\n\n\n"
	+ "func answer() -> int:\n\treturn Sibling.ANSWER\n"
)
const _RELATIVE_EXTENDS_SOURCE := (
	"extends \"compile_probe_sibling.gd\"\n\n\nfunc answer() -> int:\n\treturn ANSWER\n"
)
# The default warning level makes this an error, which the project's addons
# rule silences for a script under res://addons/.
const _GET_NODE_DEFAULT_SOURCE := "extends Node\n\nvar target: Node = get_node(\"Target\")\n"
const _COMPILING_SOURCE := "extends RefCounted\n\n\nfunc answer() -> int:\n\treturn 42\n"
const _TEMPLATES_SETTING := "editor/script/templates_search_path"
const _DEFAULT_TEMPLATES_FOLDER := "res://script_templates"
# No folder exists at this path.
const _OTHER_TEMPLATES_FOLDER := "res://test/fixtures/compile_probe_templates"
const _LEAK_COMPILES := 50
const _LEAK_BOUND := 10


static func run(testing: Testing) -> void:
	_test_relative_preload_resolves_beside_the_file(testing)
	_test_relative_extends_resolves_beside_the_file(testing)
	_test_addons_warning_rule_applies(testing)
	_test_keep_name_probe_meets_only_its_clash(testing)
	_test_repeated_checks_keep_no_copies_alive(testing)
	_test_checks_leave_a_held_dependency_intact(testing)
	_test_only_declared_inner_classes_are_emptied(testing)
	_test_compile_leaves_no_path_behind(testing)
	_test_compile_leaves_a_loaded_script_alone(testing)
	_test_compile_without_a_file(testing)
	_test_compile_without_a_file_releases_the_copy(testing)
	_test_compile_in_the_templates_folder(testing)
	_test_compile_in_a_folder_the_templates_folder_prefixes(testing)
	_test_compile_follows_the_templates_folder_setting(testing)
	_test_errors_are_captured_under_the_path(testing)
	_test_error_line_beside_the_file(testing)


static func _test_relative_preload_resolves_beside_the_file(testing: Testing) -> void:
	testing.begin("compile probe: a relative preload resolves beside the checked file")
	var verdict := GDScriptSource.judge(_RELATIVE_PRELOAD_SOURCE, _USER_PATH)
	testing.ok(bool(verdict["valid"]), "a preload of a sibling by a relative path → valid true")
	print("")


static func _test_relative_extends_resolves_beside_the_file(testing: Testing) -> void:
	testing.begin("compile probe: a relative extends resolves beside the checked file")
	var verdict := GDScriptSource.judge(_RELATIVE_EXTENDS_SOURCE, _USER_PATH)
	testing.ok(bool(verdict["valid"]), "extends a sibling by a relative path → valid true")
	print("")


static func _test_addons_warning_rule_applies(testing: Testing) -> void:
	testing.begin("compile probe: the project's addons warning rule applies to a file under res://addons/")
	var under_addons := GDScriptSource.judge(_GET_NODE_DEFAULT_SOURCE,
			"res://addons/godot_mcp_toolkit/probe_under_addons.gd")
	testing.ok(bool(under_addons["valid"]),
			"get_node() in a default under res://addons/ → valid true")
	var outside_addons := GDScriptSource.judge(_GET_NODE_DEFAULT_SOURCE,
			"res://test/fixtures/probe_outside_addons.gd")
	testing.ok(not bool(outside_addons["valid"]),
			"the same source outside res://addons/ → valid false")
	print("")


# The class_name check passes self to another script's parameter typed with
# this class, so only the keep-name compile can pass it, and the relative
# preload must resolve there too, leaving the clash its one error.
static func _test_keep_name_probe_meets_only_its_clash(testing: Testing) -> void:
	testing.begin("compile probe: the keep-name compile beside the file meets only its own clash")
	if not VersionUtils.is_at_least(VersionUtils.get_engine_version_pair(), "4.5"):
		print("  SKIP: the keep-name compile runs on 4.5+")
		return
	LogBuffer.setup()
	var source := ("class_name MCPToolkitProbeCrossA\nextends RefCounted\n\n"
		+ "const Sibling := preload(\"compile_probe_sibling.gd\")\n\n\n"
		+ "func register_with_partner() -> void:\n\tMCPToolkitProbeCrossB.new().take(self)\n")
	var verdict := GDScriptSource.judge(source, _CROSS_A_FIXTURE)
	testing.ok(bool(verdict["valid"]),
			"self passed to a typed parameter beside a relative preload → valid true")
	print("")


static func _test_repeated_checks_keep_no_copies_alive(testing: Testing) -> void:
	testing.begin("compile probe: repeated checks keep no compiled copies alive")
	var objects_before := Performance.get_monitor(Performance.OBJECT_COUNT)
	for _compile: int in _LEAK_COMPILES:
		# The verdict is not under test here, only what the checks leave alive.
		GDScriptSource.judge(_LEAK_SOURCE, _USER_PATH)
	var objects_grown := int(Performance.get_monitor(Performance.OBJECT_COUNT) - objects_before)
	testing.ok(objects_grown < _LEAK_BOUND,
			"%d checks → fewer than %d objects left alive (grew by %d)" % [
				_LEAK_COMPILES, _LEAK_BOUND, objects_grown])
	print("")


static func _test_checks_leave_a_held_dependency_intact(testing: Testing) -> void:
	testing.begin("compile probe: a script the checked file preloads keeps its code after later checks")
	_expect_held_helper_intact(testing, _PRELOAD_HELPER_FIXTURE, _PRELOAD_SOURCE, "a preload")
	_expect_held_helper_intact(testing, _INNER_HELPER_FIXTURE, _INNER_PRELOAD_SOURCE,
			"a preload in an inner class")
	_expect_held_helper_intact(testing, _NESTED_HELPER_FIXTURE, _NESTED_PRELOAD_SOURCE,
			"a preload in a nested inner class")
	_expect_held_helper_intact(testing, _ALIAS_HELPER_FIXTURE, _NESTED_ALIAS_SOURCE,
			"a preload in a nested inner class a root constant names")
	print("")


static func _test_only_declared_inner_classes_are_emptied(testing: Testing) -> void:
	testing.begin("CompileProbe.compile: only the inner classes the source declares are emptied")
	_expect_copy_released(testing, _FOREIGN_ALIAS_SOURCE, "a root constant naming another file's inner class")
	_expect_copy_released(testing, _COMMENTED_CLASS_SOURCE, "that constant's name after class in a comment")
	_expect_copy_released(testing, _QUOTED_CLASS_SOURCE, "that constant's name after class in a string")
	print("")


static func _test_compile_leaves_no_path_behind(testing: Testing) -> void:
	testing.begin("CompileProbe.compile: the copy compiles beside the file, then holds no path")
	var compiled := CompileProbe.compile(_COMPILING_SOURCE, _USER_PATH, false)
	var probe: GDScript = compiled["script"]
	var probe_path := str(compiled["path"])
	testing.eq(int(compiled["error"]), OK, "a source that compiles → OK")
	testing.eq(probe_path,
			"res://test/fixtures/compile_probe_user.gd.__mcp_probe_%d.gd" % probe.get_instance_id(),
			"the path → the file's path, the suffix and the copy's instance id")
	testing.eq(probe.resource_path, "", "after the compile → the copy's resource_path is empty")
	testing.ok(not ResourceLoader.has_cached(probe_path),
			"after the compile → nothing is cached under the copy's path")
	testing.ok(not ResourceLoader.exists(probe_path),
			"after the compile → no resource exists at the copy's path")
	print("")


static func _test_compile_leaves_a_loaded_script_alone(testing: Testing) -> void:
	testing.begin("CompileProbe.compile: a script loaded from the file keeps its instance and source")
	var loaded: GDScript = load(_SIBLING_FIXTURE)
	var loaded_id := loaded.get_instance_id()
	var loaded_source := loaded.source_code
	# The compile's outcome is not under test here, only the loaded script.
	CompileProbe.compile("extends RefCounted\n\nconst ANSWER := 7\n", _SIBLING_FIXTURE, false)
	var loaded_again: GDScript = load(_SIBLING_FIXTURE)
	testing.eq(loaded_again.get_instance_id(), loaded_id,
			"a load after the compile → the same script instance")
	testing.eq(loaded_again.source_code, loaded_source,
			"a load after the compile → the same source")
	testing.eq(int(loaded_again.get_script_constant_map().get("ANSWER", -1)), 42,
			"a load after the compile → the file's own constant")
	print("")


static func _test_compile_without_a_file(testing: Testing) -> void:
	testing.begin("CompileProbe.compile: source with no file compiles under the engine's own path")
	var compiled := CompileProbe.compile(_COMPILING_SOURCE, "", false)
	var probe: GDScript = compiled["script"]
	testing.eq(int(compiled["error"]), OK, "a source that compiles → OK")
	testing.eq(str(compiled["path"]), "gdscript://%d.gd" % probe.get_instance_id(),
			"an empty file_path → gdscript://<instance id>.gd")
	testing.eq(probe.resource_path, "", "after the compile → the copy's resource_path is empty")
	print("")


static func _test_compile_without_a_file_releases_the_copy(testing: Testing) -> void:
	testing.begin("CompileProbe.compile: source with no file is emptied and released, its preloads intact")
	var helper: GDScript = load(_INNER_HELPER_FIXTURE)
	var compiled := CompileProbe.compile(_INNER_RES_PRELOAD_SOURCE, "", false)
	var kept: WeakRef = weakref(compiled["script"])
	testing.eq(int(compiled["error"]), OK, "an inner class preloading a res:// path → OK")
	compiled.clear()
	# A later copy takes the earlier one's place in the engine's script cache.
	CompileProbe.compile(_COMPILING_SOURCE, "", false)
	testing.ok(kept.get_ref() == null, "dropped, then a later compile → the copy is freed")
	testing.eq(int(helper.get_script_constant_map().get("ANSWER", -1)), 42,
			"the copy freed → the held script its inner class preloads keeps its constant")
	print("")


# The editor loads a script in the templates folder without parsing it, so a
# copy there must compile with no path. The unit runner has no editor, so these
# cases pin the path the copy compiles under, not the skip.
static func _test_compile_in_the_templates_folder(testing: Testing) -> void:
	testing.begin("CompileProbe.compile: a file in the script-templates folder compiles with no path")
	var compiled := CompileProbe.compile(_COMPILING_SOURCE, "res://script_templates/Node/x.gd", false)
	var probe: GDScript = compiled["script"]
	testing.eq(int(compiled["error"]), OK, "a source that compiles → OK")
	testing.eq(str(compiled["path"]), "gdscript://%d.gd" % probe.get_instance_id(),
			"a file under res://script_templates/ → gdscript://<instance id>.gd")
	testing.eq(probe.resource_path, "", "after the compile → the copy's resource_path is empty")
	print("")


# The engine's test is a prefix test on the folder, so it also takes a sibling
# folder whose name starts with the templates folder's.
static func _test_compile_in_a_folder_the_templates_folder_prefixes(testing: Testing) -> void:
	testing.begin("CompileProbe.compile: a folder named after the templates folder compiles with no path")
	var compiled := CompileProbe.compile(_COMPILING_SOURCE, "res://script_templates_v2/x.gd", false)
	var probe: GDScript = compiled["script"]
	testing.eq(str(compiled["path"]), "gdscript://%d.gd" % probe.get_instance_id(),
			"a file under res://script_templates_v2/ → gdscript://<instance id>.gd")
	print("")


static func _test_compile_follows_the_templates_folder_setting(testing: Testing) -> void:
	testing.begin("CompileProbe.compile: the templates folder is the one the project setting names")
	var had_setting := ProjectSettings.has_setting(_TEMPLATES_SETTING)
	var original: Variant = ProjectSettings.get_setting(_TEMPLATES_SETTING, _DEFAULT_TEMPLATES_FOLDER)
	ProjectSettings.set_setting(_TEMPLATES_SETTING, _OTHER_TEMPLATES_FOLDER)
	var in_setting := CompileProbe.compile(_COMPILING_SOURCE, _OTHER_TEMPLATES_FOLDER + "/x.gd", false)
	var in_default := CompileProbe.compile(_COMPILING_SOURCE, "res://script_templates/x.gd", false)
	# Restored before any assertion, so a failing one leaves the setting as it was.
	ProjectSettings.set_setting(_TEMPLATES_SETTING, original if had_setting else null)
	var in_setting_probe: GDScript = in_setting["script"]
	var in_default_probe: GDScript = in_default["script"]
	testing.eq(str(in_setting["path"]), "gdscript://%d.gd" % in_setting_probe.get_instance_id(),
			"a file under the folder the setting names → gdscript://<instance id>.gd")
	testing.eq(str(in_default["path"]),
			"res://script_templates/x.gd.__mcp_probe_%d.gd" % in_default_probe.get_instance_id(),
			"a file under res://script_templates/ with the setting elsewhere → beside the file")
	print("")


static func _test_errors_are_captured_under_the_path(testing: Testing) -> void:
	testing.begin("CompileProbe.compile: the compile's errors are captured under its path")
	LogBuffer.setup()
	if not LogBuffer.uses_logger_api():
		print("  SKIP: the Logger capture runs on 4.5+")
		return
	var since_id := LogBuffer.get_cursor() - 1
	var compiled := CompileProbe.compile("extends RefCounted\n\nvar = 1\n", _USER_PATH, true)
	# Takes the errors so no later case reads them.
	var captured := LogBuffer.take_script_errors_since(since_id, str(compiled["path"]))
	var errors: Array = captured["errors"]
	testing.eq(int(compiled["error"]), ERR_PARSE_ERROR, "a syntax error → ERR_PARSE_ERROR")
	testing.ok(errors.size() >= 1, "printing on → the error is captured under the copy's path")
	var first: Dictionary = errors[0] if errors.size() > 0 else {}
	testing.eq(int(first.get("line", -1)), 3, "the captured error → the source's line 3")
	print("")


static func _test_error_line_beside_the_file(testing: Testing) -> void:
	testing.begin("script_check diagnostics: a compile error beside the file keeps its line")
	LogBuffer.setup()
	if not LogBuffer.uses_logger_api():
		print("  SKIP: the Logger capture runs on 4.5+")
		return
	var result := ScriptCommands._validate_gdscript("extends Node\n\nvar = 1\n", _USER_PATH)
	var diagnostics: Array = result.get("diagnostics", [])
	var first: Dictionary = diagnostics[0] if diagnostics.size() > 0 else {}
	testing.ok(not bool(result.get("valid", true)), "a syntax error → valid false")
	testing.eq(int(first.get("line", -1)), 3, "a syntax error on line 3 → line 3")
	print("")


# Holds the helper at helper_path, as an open script or a node's script holds
# it, while a check of source preloads it and later checks run. No loaded
# script preloads the helper, so only the check's copy depends on it.
static func _expect_held_helper_intact(testing: Testing, helper_path: String, source: String,
		shape: String) -> void:
	var helper: GDScript = load(helper_path)
	# The verdicts are not under test here, only the helper afterwards.
	GDScriptSource.judge(source, _USER_PATH)
	GDScriptSource.judge(_COMPILING_SOURCE, _USER_PATH)
	GDScriptSource.judge(_COMPILING_SOURCE, _SIBLING_FIXTURE)
	testing.eq(int(helper.get_script_constant_map().get("ANSWER", -1)), 42,
			"%s, then later checks → the helper keeps its constant" % shape)
	var methods: Array = helper.get_script_method_list().map(
			func(method: Dictionary) -> String: return str(method["name"]))
	var doubled: Variant = helper.call("doubled", 21) if methods.has("doubled") else null
	testing.eq(doubled, 42, "%s, then later checks → the helper's function still runs" % shape)


# A copy is kept rather than released only when it cannot be emptied, so a
# freed copy shows the emptied source compiled.
static func _expect_copy_released(testing: Testing, source: String, shape: String) -> void:
	var compiled := CompileProbe.compile(source, _USER_PATH, false)
	var kept: WeakRef = weakref(compiled["script"])
	testing.eq(int(compiled["error"]), OK, "%s → OK" % shape)
	compiled.clear()
	# A later copy takes the earlier one's place in the engine's script cache.
	CompileProbe.compile(_COMPILING_SOURCE, _USER_PATH, false)
	testing.ok(kept.get_ref() == null, "%s, dropped, then a later compile → the copy is freed" % shape)
