@tool
extends RefCounted
## Unit tests for the Project Settings registration of the update keys: the install mode's
## type, the values its inspector offers, its default and its place among the basic settings,
## and the same for the backup switch. Read back through ProjectSettings after register_all(),
## which never saves.

const Testing := preload("res://test/units/testing.gd")
const SettingsRegistration := preload("res://addons/godot_mcp_toolkit/core/settings_registration.gd")

const _INSTALL_MODE_KEY := "mcp_toolkit/updates/install_mode"
const _KEEP_BACKUP_KEY := "mcp_toolkit/updates/keep_backup"


static func run(testing: Testing) -> void:
	_test_install_mode_registration(testing)
	_test_keep_backup_registration(testing)


# The inspector shows the mode as a two-way choice without the Advanced toggle,
# since it decides whether the toolkit may change its own files; a missing key
# reverts to ask.
static func _test_install_mode_registration(testing: Testing) -> void:
	testing.begin("Install mode registers as a basic choice that defaults to ask")
	var had_key := ProjectSettings.has_setting(_INSTALL_MODE_KEY)
	var previous_value: Variant = ProjectSettings.get_setting(_INSTALL_MODE_KEY) if had_key else null
	SettingsRegistration.register_all()
	var info := _property_info(_INSTALL_MODE_KEY)
	var revert_value: Variant = ProjectSettings.property_get_revert(_INSTALL_MODE_KEY)
	ProjectSettings.set_setting(_INSTALL_MODE_KEY, previous_value)

	testing.eq(int(info.get("type", TYPE_NIL)), TYPE_STRING, "the mode is a String")
	testing.eq(int(info.get("hint", -1)), PROPERTY_HINT_ENUM, "the inspector offers a fixed choice")
	testing.eq(str(info.get("hint_string", "")), "manual,ask",
			"the choice is manual and ask, in that order")
	testing.eq(revert_value, "ask", "the default is ask")
	testing.ok((int(info.get("usage", 0)) & PROPERTY_USAGE_EDITOR_BASIC_SETTING) != 0,
			"the mode shows without the inspector's Advanced toggle")
	print("")


# A user who turned the backup off keeps that choice across every later start.
static func _test_keep_backup_registration(testing: Testing) -> void:
	testing.begin("Keep backup registers as a basic switch that defaults to on")
	var had_key := ProjectSettings.has_setting(_KEEP_BACKUP_KEY)
	var previous_value: Variant = ProjectSettings.get_setting(_KEEP_BACKUP_KEY) if had_key else null
	ProjectSettings.set_setting(_KEEP_BACKUP_KEY, null)
	SettingsRegistration.register_all()
	var info := _property_info(_KEEP_BACKUP_KEY)
	var fresh_value: Variant = ProjectSettings.get_setting(_KEEP_BACKUP_KEY)
	var revert_value: Variant = ProjectSettings.property_get_revert(_KEEP_BACKUP_KEY)
	ProjectSettings.set_setting(_KEEP_BACKUP_KEY, false)
	SettingsRegistration.register_all()
	var kept_value: Variant = ProjectSettings.get_setting(_KEEP_BACKUP_KEY)
	ProjectSettings.set_setting(_KEEP_BACKUP_KEY, previous_value)

	testing.eq(int(info.get("type", TYPE_NIL)), TYPE_BOOL, "the switch is a bool")
	testing.eq(fresh_value, true, "a project without the key → on")
	testing.eq(revert_value, true, "the default is on")
	testing.ok((int(info.get("usage", 0)) & PROPERTY_USAGE_EDITOR_BASIC_SETTING) != 0,
			"the switch shows without the inspector's Advanced toggle")
	testing.eq(kept_value, false, "a project's off → not overwritten by a later registration")
	testing.eq(str(info.get("hint_string", "")), "", "no text in the hint string, where the inspector would misread it")
	print("")


# Returns the ProjectSettings property-list entry for `key`, or {} if absent.
static func _property_info(key: String) -> Dictionary:
	for entry: Dictionary in ProjectSettings.get_property_list():
		if str(entry.get("name", "")) == key:
			return entry
	return {}
