@tool
extends RefCounted
## Unit tests for the log buffer's 4.5+ capture logger. Its capture script is built from
## source, so a project's own GDScript warning levels apply to it in full, and the logger
## is still built with every level at Error. Below Godot 4.5, which has no Logger class,
## each case asserts the file tail runs instead and prints its skip.

const Testing := preload("res://test/units/testing.gd")
const LogBuffer := preload("res://addons/godot_mcp_toolkit/logging/log_buffer.gd")

# Every warning's level is an int setting under this prefix; the other settings there
# (enable, directory_rules) are not ints.
const _WARNING_SETTING_PREFIX := "debug/gdscript/warnings/"
const _WARNING_LEVEL_ERROR := 2
# Engine Logger error_type of a script error, the one type whose location is latched.
const _ERROR_TYPE_SCRIPT := 2


## [param tree] is the runner itself: a warning level set at run time reaches the parser
## only after a frame passes.
static func run(testing: Testing, tree: SceneTree) -> void:
	await _test_logger_builds_with_warnings_as_errors(testing, tree)
	_test_logger_delivers_to_the_buffer(testing)


static func _test_logger_builds_with_warnings_as_errors(testing: Testing, tree: SceneTree) -> void:
	testing.begin("LogBuffer: the capture logger builds with every GDScript warning at Error")
	if _skipped_below_logger_floor(testing):
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


# The capture script reaches the buffer through call() by method name, which no parser
# checks, so a misspelt name would compile and drop every captured line.
static func _test_logger_delivers_to_the_buffer(testing: Testing) -> void:
	testing.begin("LogBuffer: the capture logger delivers messages and script errors to the buffer")
	if _skipped_below_logger_floor(testing):
		return
	var logger: Object = LogBuffer._create_logger()
	testing.ok(logger != null, "the logger is built")
	if logger == null:
		print("")
		return
	var since_id := LogBuffer.get_cursor() - 1
	# The engine calls these callbacks only on a logger it holds, and this one is not
	# registered, so the case calls them as the engine would.
	logger.call("_log_message", "unit probe message", false)
	logger.call("_log_error", "probe_function", "gdscript://1.gd", 3, "unit probe error", "",
			false, _ERROR_TYPE_SCRIPT, [])
	var entries: Array = LogBuffer.get_entries(10, [], since_id)["entries"]

	testing.ok(_has_entry(entries, "info", "unit probe message"),
			"a message reaches the buffer as an info entry")
	testing.ok(_has_entry(entries, "error", "ERROR: unit probe error"),
			"a script error reaches the buffer as an error entry")
	testing.eq(LogBuffer.find_script_error_line_since(since_id), 3,
			"the script error's line is latched")
	print("")


## Returns true, after asserting the file tail runs instead and printing the skip, when
## the engine has no Logger class (below Godot 4.5), so the capture logger is never built.
static func _skipped_below_logger_floor(testing: Testing) -> bool:
	if ClassDB.class_exists(&"Logger"):
		return false
	LogBuffer.setup()
	testing.ok(not LogBuffer.uses_logger_api(),
			"below Godot 4.5 the capture logger is never compiled and the file tail runs")
	print("  SKIP: no Logger class below Godot 4.5")
	print("")
	return true


## Returns the value of every GDScript warning level setting the running engine has,
## keyed by setting name.
static func _snapshot_warning_levels() -> Dictionary:
	var levels := {}
	for property: Dictionary in ProjectSettings.get_property_list():
		var setting_name: String = property["name"]
		if setting_name.begins_with(_WARNING_SETTING_PREFIX) and property["type"] == TYPE_INT:
			levels[setting_name] = ProjectSettings.get_setting(setting_name)
	return levels


## Returns true when [param entries] holds an entry at [param level] whose message
## starts with [param message_start]. A start, because 4.7+ appends a location line to
## a script error.
static func _has_entry(entries: Array, level: String, message_start: String) -> bool:
	for entry: Dictionary in entries:
		if str(entry["level"]) == level and str(entry["message"]).begins_with(message_start):
			return true
	return false
