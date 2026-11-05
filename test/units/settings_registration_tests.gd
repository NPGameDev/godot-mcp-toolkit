@tool
extends RefCounted
## Unit tests for the Project Settings registration of the install mode: its type,
## the three values its inspector offers, its default, and its place among the basic
## settings. Read back through ProjectSettings after register_all(), which never saves.

const Testing := preload("res://test/units/testing.gd")
const SettingsRegistration := preload("res://addons/godot_mcp_toolkit/core/settings_registration.gd")

const _INSTALL_MODE_KEY := "mcp_toolkit/updates/install_mode"


static func run(testing: Testing) -> void:
	_test_install_mode_registration(testing)


# The inspector shows the mode as a three-way choice without the Advanced toggle,
# since it decides whether the toolkit may change its own files; a missing key
# reverts to ask.
static func _test_install_mode_registration(testing: Testing) -> void:
	testing.begin("Install mode registers as a basic three-value choice that defaults to ask")
	var had_key := ProjectSettings.has_setting(_INSTALL_MODE_KEY)
	var previous_value: Variant = ProjectSettings.get_setting(_INSTALL_MODE_KEY) if had_key else null
	SettingsRegistration.register_all()
	var info := _property_info(_INSTALL_MODE_KEY)
	var revert_value: Variant = ProjectSettings.property_get_revert(_INSTALL_MODE_KEY)
	ProjectSettings.set_setting(_INSTALL_MODE_KEY, previous_value)

	testing.eq(int(info.get("type", TYPE_NIL)), TYPE_STRING, "the mode is a String")
	testing.eq(int(info.get("hint", -1)), PROPERTY_HINT_ENUM, "the inspector offers a fixed choice")
	testing.eq(str(info.get("hint_string", "")), "manual,ask,automatic",
			"the choice is manual, ask and automatic, in that order")
	testing.eq(revert_value, "ask", "the default is ask")
	testing.ok((int(info.get("usage", 0)) & PROPERTY_USAGE_EDITOR_BASIC_SETTING) != 0,
			"the mode shows without the inspector's Advanced toggle")
	print("")


# Returns the ProjectSettings property-list entry for `key`, or {} if absent.
static func _property_info(key: String) -> Dictionary:
	for entry: Dictionary in ProjectSettings.get_property_list():
		if str(entry.get("name", "")) == key:
			return entry
	return {}
