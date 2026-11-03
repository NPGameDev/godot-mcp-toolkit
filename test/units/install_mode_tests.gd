@tool
extends RefCounted
## Unit tests for the install mode setting: its default, the values it accepts, the
## manual fallback for anything else, a stray automatic included, and saving only a change.

const Testing := preload("res://test/units/testing.gd")
const InstallMode := preload("res://addons/godot_mcp_toolkit/self_update/install_mode.gd")


static func run(testing: Testing) -> void:
	_test_values(testing)
	_test_read(testing)
	_test_stray_automatic(testing)
	_test_save(testing)


static func _test_values(testing: Testing) -> void:
	testing.begin("Install mode: the choices")
	testing.eq(InstallMode.VALUES, ["manual", "ask"], "manual and ask, nothing that installs unasked")
	print("")


static func _test_read(testing: Testing) -> void:
	testing.begin("Install mode: reading the setting")
	var store := _Store.new()
	testing.eq(InstallMode.read(null), "ask", "no ProjectSettings → ask")
	testing.eq(InstallMode.read(store), "ask", "no key → ask")
	for value: String in ["manual", "ask"]:
		store.values["mcp_toolkit/updates/install_mode"] = value
		testing.eq(InstallMode.read(store), value, "%s → %s" % [value, value])
	store.values["mcp_toolkit/updates/install_mode"] = " Ask "
	testing.eq(InstallMode.read(store), "ask", "case and spaces → ignored")
	store.values["mcp_toolkit/updates/install_mode"] = "always"
	testing.eq(InstallMode.read(store), "manual", "an unknown value → manual")
	store.values["mcp_toolkit/updates/install_mode"] = 1
	testing.eq(InstallMode.read(store), "manual", "a number → manual")
	print("")


static func _test_stray_automatic(testing: Testing) -> void:
	testing.begin("Install mode: a stray automatic never installs")
	var store := _Store.new()
	store.values["mcp_toolkit/updates/install_mode"] = "automatic"
	testing.eq(InstallMode.read(store), "manual", "automatic in project.godot → manual")
	store.values["mcp_toolkit/updates/install_mode"] = " Automatic "
	testing.eq(InstallMode.read(store), "manual", "automatic in any case, with spaces → manual")
	var saved := _Store.new()
	InstallMode.save(saved, "automatic")
	testing.ok(not saved.values.has("mcp_toolkit/updates/install_mode"), "saving automatic → the key stays unset")
	testing.eq(saved.saves, 0, "saving automatic → project.godot not saved")
	print("")


static func _test_save(testing: Testing) -> void:
	testing.begin("Install mode: saving a choice")
	var store := _Store.new()
	testing.eq(InstallMode.save(store, "manual"), OK, "a new mode → saved")
	testing.eq(store.values.get("mcp_toolkit/updates/install_mode"), "manual", "the key holds it")
	testing.eq(store.saves, 1, "project.godot saved once")
	InstallMode.save(store, "manual")
	testing.eq(store.saves, 1, "the same mode again → not saved")
	InstallMode.save(store, "sometimes")
	testing.eq(store.values.get("mcp_toolkit/updates/install_mode"), "manual", "an unknown mode → ignored")
	print("")


# Stands in for ProjectSettings: its real save() would rewrite this project's project.godot.
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
