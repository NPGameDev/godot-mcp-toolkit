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


## Returns the feature tags of [param action]'s setting name: everything after its first
## dot, or an empty String when it has none. The engine reads
## [code]input/<name>.<tags>[/code] as a feature override of [code]input/<name>[/code],
## each later dot starting another tag, and applies it only where every tag holds.
func get_feature(action: String) -> String:
	var dot := action.find(".")
	return "" if dot == -1 else action.substr(dot + 1)


## Returns the name of every action with an [code]input/<name>[/code] setting, in the order
## project.godot's [code][input][/code] section saves them, which is the order the
## editor's Input Map shows.
func get_actions() -> Array[String]:
	var setting_names: Array[String] = []
	for property in ProjectSettings.get_property_list():
		var setting_name := str(property.get("name", ""))
		if setting_name.begins_with(_SETTING_PREFIX):
			setting_names.append(setting_name)
	setting_names.sort_custom(func(name_a: String, name_b: String) -> bool:
		return ProjectSettings.get_order(name_a) < ProjectSettings.get_order(name_b))
	var actions: Array[String] = []
	for setting_name in setting_names:
		actions.append(setting_name.trim_prefix(_SETTING_PREFIX))
	return actions


## Returns [param action]'s deadzone. A setting with no [code]deadzone[/code] key reads as
## [method default_deadzone], as the engine reads it when it loads the project.
func get_deadzone(action: String) -> float:
	return _deadzone_of(_read(action))


## Returns a copy of [param action]'s events, in their saved order; empty when the action
## has none or no setting. A built-in action that project.godot does not change holds the
## engine's default Array itself, so a change made in place would change the default too.
func get_events(action: String) -> Array:
	return _events_of(_read(action))


## Returns the built-in action [param action]'s default as
## [code]{"deadzone": float, "events": Array}[/code], the events a copy; an empty
## Dictionary for a project action, which has none.
func get_default(action: String) -> Dictionary:
	var default_setting := _read_default(action)
	if default_setting.is_empty():
		return {}
	return {"deadzone": _deadzone_of(default_setting), "events": _events_of(default_setting)}


## Returns whether the built-in action [param action] differs from its default by the
## rule the editor's Input Map uses for its revert button: another deadzone, another
## number of events, or an event that does not match the default's event at the same
## index. Order counts; which event objects the setting holds does not. A project action
## answers false.
func differs_from_default(action: String) -> bool:
	var default_setting := _read_default(action)
	if default_setting.is_empty():
		return false
	var setting := _read(action)
	if not is_equal_approx(_deadzone_of(setting), _deadzone_of(default_setting)):
		return true
	var events := _events_of(setting)
	var default_events := _events_of(default_setting)
	if events.size() != default_events.size():
		return true
	for index in events.size():
		var event: Variant = events[index]
		var default_event: Variant = default_events[index]
		if not (event is InputEvent and default_event is InputEvent):
			return true
		if not (default_event as InputEvent).is_match(event as InputEvent, true):
			return true
	return false


## Returns whether [param action]'s setting holds its default value itself, the test
## [code]ProjectSettings.save()[/code] makes before it leaves the line out of
## project.godot. Event objects compare by identity there, so a setting rebuilt with the
## default's content answers false and is still saved.
func holds_default(action: String) -> bool:
	var setting_name := _SETTING_PREFIX + action
	var default_value: Variant = ProjectSettings.property_get_revert(setting_name)
	if typeof(default_value) != TYPE_DICTIONARY:
		return false
	return ProjectSettings.get_setting(setting_name) == default_value


## Puts the built-in action [param action]'s setting back to its default, keeping its
## order. The setting takes the revert value exactly as the engine returns it: its events
## Array is the default's own, which is what lets [method save] leave the line out of
## project.godot. A project action is left as it is.
func revert(action: String) -> void:
	if not is_builtin(action):
		return
	var setting_name := _SETTING_PREFIX + action
	ProjectSettings.set_setting(setting_name, ProjectSettings.property_get_revert(setting_name))


## Returns the deadzone the running engine gives an action when none is set: the default of
## [code]InputMap::add_action[/code]'s deadzone argument, 0.5 before 4.4 and 0.2 from 4.4.
func default_deadzone() -> float:
	for method in ClassDB.class_get_method_list("InputMap", true):
		if str(method.get("name", "")) != "add_action":
			continue
		var defaults: Array = method.get("default_args", [])
		if not defaults.is_empty():
			return float(defaults[0])
	# The engine's default: InputMap::DEFAULT_DEADZONE (0.2) from 4.4, a literal 0.5 in
	# add_action's signature before.
	var version := Modules.VersionUtils.get_engine_version_pair()
	return 0.2 if Modules.VersionUtils.is_at_least(version, "4.4") else 0.5


## Sets [param action]'s setting to [param deadzone] and [param events]. An existing setting
## keeps its order, a built-in action's included; a new one is ordered after every other.
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


## Returns the built-in action [param action]'s default setting, the value the engine
## registered for it, or an empty Dictionary for a project action.
func _read_default(action: String) -> Dictionary:
	if not is_builtin(action):
		return {}
	var default_setting: Variant = ProjectSettings.property_get_revert(_SETTING_PREFIX + action)
	if typeof(default_setting) != TYPE_DICTIONARY:
		return {}
	return default_setting


## Returns the deadzone of an action's setting [param setting], or
## [method default_deadzone] when it sets none.
func _deadzone_of(setting: Dictionary) -> float:
	if not setting.has("deadzone"):
		return default_deadzone()
	return float(setting["deadzone"])


## Returns a copy of the events of an action's setting [param setting]; empty when it has
## none.
func _events_of(setting: Dictionary) -> Array:
	var events: Variant = setting.get("events", [])
	if typeof(events) != TYPE_ARRAY:
		return []
	var copy: Array = events
	return copy.duplicate()
