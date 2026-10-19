@tool
extends RefCounted
## The settings the setup wizard's two checkbox steps show and change.
##
## The updates step edits the project's [code]mcp_toolkit/updates/check_for_updates[/code],
## saved in project.godot for everyone who works on the project. The optional-steps
## step edits this machine's
## [code]mcp_toolkit/setup_wizard/show_optional_steps[/code] in EditorSettings. Both
## default to on.[br]
## [br]
## A box applies only when the user leaves its step with Next or Done, and only when
## its value changed: unticking writes [code]false[/code], and ticking it again
## writes the default, [code]true[/code], back. ProjectSettings leaves a value equal
## to its registered default out of project.godot, so a re-tick removes the updates
## key's line; EditorSettings does the same only from Godot 4.4, and on 4.2 and 4.3
## keeps the [code]true[/code] in its file. Closing the wizard with × applies nothing.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const SetupSteps = Modules.SetupSteps
const UpdateCheck = Modules.UpdateCheck

# ProjectSettings, or a stand-in with has_setting, get_setting, set_setting and save.
var _project_settings: Object = null
# () -> Object: EditorSettings, or a stand-in with has_setting, get_setting and
# set_setting. Read on use, so a wizard built without an editor never asks for it.
var _editor_settings_reader: Callable = Callable()


## [param project_settings] is [ProjectSettings] and [param editor_settings_reader]
## returns the [EditorSettings]; tests pass stand-ins with the same methods.
func _init(project_settings: Object, editor_settings_reader: Callable) -> void:
	_project_settings = project_settings
	_editor_settings_reader = editor_settings_reader


## Whether the box on [param step_id] shows ticked: its setting's current value,
## or on when the setting is missing. Returns [code]true[/code] for a step without
## a box.
func is_on(step_id: StringName) -> bool:
	if step_id == SetupSteps.UPDATES:
		return UpdateCheck.is_check_enabled(_project_settings)
	if step_id == SetupSteps.OPTIONAL_STEPS:
		return SetupSteps.shows_optional_steps(_store(step_id))
	return true


## Apply the box on [param step_id] as [param ticked], writing only a change. The
## project setting is saved to project.godot at once, as the .mcp.json step's
## server choice is.
func apply(step_id: StringName, ticked: bool) -> void:
	var store := _store(step_id)
	var key := _key(step_id)
	if store == null or key.is_empty() or ticked == is_on(step_id):
		return
	# Ticked is the registered default. ProjectSettings leaves a value equal to its
	# default out of project.godot, so writing it back removes the key there;
	# EditorSettings does so only from Godot 4.4.
	store.set_setting(key, ticked)
	if step_id == SetupSteps.UPDATES:
		var error: int = store.save()
		if error != OK:
			push_warning("[MCP] could not save project.godot (err %d): the update check setting applies to this session only" % error)


func _store(step_id: StringName) -> Object:
	if step_id == SetupSteps.UPDATES:
		return _project_settings
	if step_id == SetupSteps.OPTIONAL_STEPS and _editor_settings_reader.is_valid():
		return _editor_settings_reader.call()
	return null


static func _key(step_id: StringName) -> String:
	if step_id == SetupSteps.UPDATES:
		return UpdateCheck.SETTING
	if step_id == SetupSteps.OPTIONAL_STEPS:
		return SetupSteps.SHOW_OPTIONAL_STEPS_SETTING
	return ""
