@tool
extends RefCounted
## Unit tests for the install mode setting: its default, the values it accepts, the
## manual fallback for anything else, and saving only a change.

const InstallMode := preload("res://addons/godot_mcp_toolkit/update/install_mode.gd")


class _Store extends RefCounted:
	var values := {}
	var saves := 0

	func has_setting(key: String) -> bool:
		return values.has(key)

	func get_setting(key: String) -> Variant:
		return values.get(key)

	func set_setting(key: String, value: Variant) -> void:
		values[key] = value

	func save() -> Error:
		saves += 1
		return OK


static func run(testing) -> void:
	_test_read(testing)
	_test_save(testing)


static func _test_read(testing) -> void:
	testing.begin("Install mode: reading the setting")
	var store := _Store.new()
	testing.eq(InstallMode.read(null), "ask", "no ProjectSettings → ask")
	testing.eq(InstallMode.read(store), "ask", "no key → ask")
	for value: String in ["manual", "ask", "automatic"]:
		store.values["mcp_toolkit/updates/install_mode"] = value
		testing.eq(InstallMode.read(store), value, "%s → %s" % [value, value])
	store.values["mcp_toolkit/updates/install_mode"] = " Automatic "
	testing.eq(InstallMode.read(store), "automatic", "case and spaces → ignored")
	store.values["mcp_toolkit/updates/install_mode"] = "always"
	testing.eq(InstallMode.read(store), "manual", "an unknown value → manual")
	store.values["mcp_toolkit/updates/install_mode"] = 1
	testing.eq(InstallMode.read(store), "manual", "a number → manual")
	print("")


static func _test_save(testing) -> void:
	testing.begin("Install mode: saving a choice")
	var store := _Store.new()
	testing.eq(InstallMode.save(store, "automatic"), OK, "a new mode → saved")
	testing.eq(store.values.get("mcp_toolkit/updates/install_mode"), "automatic", "the key holds it")
	testing.eq(store.saves, 1, "project.godot saved once")
	InstallMode.save(store, "automatic")
	testing.eq(store.saves, 1, "the same mode again → not saved")
	InstallMode.save(store, "sometimes")
	testing.eq(store.values.get("mcp_toolkit/updates/install_mode"), "automatic", "an unknown mode → ignored")
	print("")
