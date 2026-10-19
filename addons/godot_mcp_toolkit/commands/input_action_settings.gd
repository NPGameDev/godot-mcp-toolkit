@tool
extends RefCounted
## The project's input actions, read and written as their [code]input/<name>[/code] settings.
##
## These settings are the input actions' source of truth: the editor's own Input Map dialog
## reads and writes them alone, and the editor's InputMap holds only the built-in actions'
## keys and never reloads from them. Every input_map.* handler goes through this class, so
## the rule lives in one place.
##
## [code]ProjectSettings.clear()[/code] is never called on a built-in action: it drops the
## setting's default and order, and the engine then counts the action as a project action
## until the editor restarts.
##
## The methods are instance methods so that a test can override [method save] on a subclass
## and run a handler without writing project.godot.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")

## The engine's [code]ProjectSettings::NO_BUILTIN_ORDER_BASE[/code] ([code]1 << 16[/code] on
## 4.2–4.7): the engine orders each setting it registers itself below this value and each
## setting a project adds above it. Its [code]is_builtin_setting()[/code] makes the same
## comparison, but scripts cannot call it.
const NO_BUILTIN_ORDER_BASE := 1 << 16

const _SETTING_PREFIX := "input/"


## Returns whether [param action] has an [code]input/<name>[/code] setting. Every built-in
## action has one, whether or not project.godot saves a change to it.
func exists(action: String) -> bool:
	return ProjectSettings.has_setting(_SETTING_PREFIX + action)


## Returns whether [param action] is a built-in action: one the engine registers for every
## project, rather than a project action saved in project.godot. It asks the engine's
## registration order instead of matching a name list, so it stays exact on every engine
## version and never mistakes a project action named [code]ui_*[/code] for a built-in one.
func is_builtin(action: String) -> bool:
	var setting_name := _SETTING_PREFIX + action
	# get_order() logs an error for a setting that does not exist.
	return ProjectSettings.has_setting(setting_name) \
		and ProjectSettings.get_order(setting_name) < NO_BUILTIN_ORDER_BASE


## Returns [param action]'s deadzone. A setting with no [code]deadzone[/code] key reads as
## [method default_deadzone], as the engine reads it when it loads the project.
func get_deadzone(action: String) -> float:
	var setting := _read(action)
	if not setting.has("deadzone"):
		return default_deadzone()
	return float(setting["deadzone"])


## Returns a copy of [param action]'s events, in their saved order; empty when the action
## has none or no setting. A built-in action that project.godot does not change holds the
## engine's default Array itself, so a change made in place would change the default too.
func get_events(action: String) -> Array:
	var events: Variant = _read(action).get("events", [])
	if typeof(events) != TYPE_ARRAY:
		return []
	var copy: Array = events
	return copy.duplicate()


## Returns the deadzone the running engine gives an action when none is set: the default of
## [code]InputMap::add_action[/code]'s deadzone argument, 0.5 before 4.4 and 0.2 from 4.4.
func default_deadzone() -> float:
	for method in ClassDB.class_get_method_list("InputMap", true):
		if str(method.get("name", "")) != "add_action":
			continue
		var defaults: Array = method.get("default_args", [])
		if not defaults.is_empty():
			return float(defaults[0])
	# InputMap::DEFAULT_DEADZONE (core/input/input_map.h) is 0.2 from 4.4 and 0.5 before.
	var version := Modules.VersionUtils.get_engine_version_pair()
	return 0.2 if Modules.VersionUtils.is_at_least(version, "4.4") else 0.5


## Sets [param action]'s setting to [param deadzone] and [param events]. An existing setting
## keeps its order, a built-in action's included; a new one is ordered after every other.
## The value is always a new Dictionary, so a built-in action's default is never changed.
func write(action: String, deadzone: float, events: Array) -> void:
	ProjectSettings.set_setting(_SETTING_PREFIX + action, {
		"deadzone": deadzone,
		"events": events,
	})


## Moves the project action [param old_action]'s setting to [param new_action] and gives it
## the old setting's order, so a renamed action keeps its place in project.godot's
## [code][input][/code] section. A new setting is otherwise ordered after every other one.
func move(old_action: String, new_action: String) -> void:
	var old_name := _SETTING_PREFIX + old_action
	var new_name := _SETTING_PREFIX + new_action
	var order := ProjectSettings.get_order(old_name)
	var value: Variant = ProjectSettings.get_setting(old_name)
	erase(old_action)
	ProjectSettings.set_setting(new_name, value)
	ProjectSettings.set_order(new_name, order)


## Deletes the project action [param action]'s setting. A built-in action, or an action with
## no setting, is left as it is.
func erase(action: String) -> void:
	if not exists(action) or is_builtin(action):
		return
	ProjectSettings.clear(_SETTING_PREFIX + action)


## Saves project.godot. Every input_map.* change is saved through this method.
func save() -> Error:
	return ProjectSettings.save()


## Returns [param action]'s setting, or an empty Dictionary when it has none or the value
## is not an action's Dictionary.
func _read(action: String) -> Dictionary:
	var setting: Variant = ProjectSettings.get_setting(_SETTING_PREFIX + action, {})
	if typeof(setting) != TYPE_DICTIONARY:
		return {}
	return setting
