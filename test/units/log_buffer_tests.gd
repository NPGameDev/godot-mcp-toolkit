@tool
extends RefCounted
## Unit tests for the log buffer's 4.5+ capture logger. Its capture script is built from
## source, so a project's own GDScript warning levels apply to it in full, and the logger
## is still built with every level at Error. Skipped below Godot 4.5, which has no Logger
## class (the file tail runs there).

const Testing := preload("res://test/units/testing.gd")
const LogBuffer := preload("res://addons/godot_mcp_toolkit/logging/log_buffer.gd")

# Every warning's level is an int setting under this prefix; the other settings there
# (enable, directory_rules) are not ints.
const _WARNING_SETTING_PREFIX := "debug/gdscript/warnings/"
const _WARNING_LEVEL_ERROR := 2


## [param tree] is the runner itself: a warning level set at run time reaches the parser
## only after a frame passes.
static func run(testing: Testing, tree: SceneTree) -> void:
	await _test_logger_builds_with_warnings_as_errors(testing, tree)


static func _test_logger_builds_with_warnings_as_errors(testing: Testing, tree: SceneTree) -> void:
	testing.begin("LogBuffer: the capture logger builds with every GDScript warning at Error")
	if not ClassDB.class_exists(&"Logger"):
		print("  SKIP: no Logger class below Godot 4.5")
		print("")
		return
	var levels := _snapshot_warning_levels()
	for setting_name: String in levels:
		ProjectSettings.set_setting(setting_name, _WARNING_LEVEL_ERROR)
	await tree.process_frame
	# setup() builds its logger once per process and registers it with the engine, so the
	# case calls the builder setup() uses, which registers nothing.
	var logger: Object = LogBuffer._create_logger()
	for setting_name: String in levels:
		ProjectSettings.set_setting(setting_name, levels[setting_name])
	# The units after this one compile scripts, so the restored levels reach the parser
	# before any assertion can end the case.
	await tree.process_frame

	testing.ok(logger != null, "the logger is built")
	print("")


## Returns the value of every GDScript warning level setting the running engine has,
## keyed by setting name.
static func _snapshot_warning_levels() -> Dictionary:
	var levels := {}
	for property: Dictionary in ProjectSettings.get_property_list():
		var setting_name: String = property["name"]
		if setting_name.begins_with(_WARNING_SETTING_PREFIX) and property["type"] == TYPE_INT:
			levels[setting_name] = ProjectSettings.get_setting(setting_name)
	return levels
