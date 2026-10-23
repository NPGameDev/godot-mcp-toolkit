@tool
extends RefCounted
## Unit tests for the engine setting names leaf (versioning/engine_setting_names.gd)
## and for the unfocused-sleep controller (core/unfocused_sleep_controller.gd) when the
## editor holds the setting under none of those names. Each stub mirrors what an editor
## version defines; the real editor's answer is checked by the cross-version smoke.
## The cases are green-only: the resolver is new, and a script error aborted the old
## controller's write anyway, so the skip cases cannot be seen red.

const EngineSettingNames := preload("res://addons/godot_mcp_toolkit/versioning/engine_setting_names.gd")
const UnfocusedSleepController := preload("res://addons/godot_mcp_toolkit/core/unfocused_sleep_controller.gd")

const _NEW_SLEEP_NAME := "interface/editor/timers/unfocused_low_processor_mode_sleep_usec"
const _OLD_SLEEP_NAME := "interface/editor/unfocused_low_processor_mode_sleep_usec"
# A name a later Godot might give the setting, which no list knows yet.
const _FUTURE_SLEEP_NAME := "interface/editor/later/unfocused_low_processor_mode_sleep_usec"


static func run(testing) -> void:
	_test_resolve_unfocused_sleep(testing)
	_test_lower_skips_without_a_name(testing)
	_test_restore_skips_without_a_name(testing)


# Godot 4.2-4.6 define only the old name. 4.7 defines the new one, and answers the old
# one too only when it loaded saved settings (its compatibility map), so the new name
# must win when both answer.
static func _test_resolve_unfocused_sleep(testing) -> void:
	testing.begin("EngineSettingNames.resolve — the unfocused sleep's name on each editor")
	var candidates: Array = EngineSettingNames.UNFOCUSED_SLEEP_USEC
	testing.eq(EngineSettingNames.resolve(_Store.new({_OLD_SLEEP_NAME: 100000}), candidates),
			_OLD_SLEEP_NAME, "old name only (4.2-4.6): the old name")
	testing.eq(EngineSettingNames.resolve(_Store.new({_NEW_SLEEP_NAME: 100000}), candidates),
			_NEW_SLEEP_NAME, "new name only (4.7 without saved settings): the new name")
	testing.eq(EngineSettingNames.resolve(
			_Store.new({_NEW_SLEEP_NAME: 100000, _OLD_SLEEP_NAME: 100000}), candidates),
			_NEW_SLEEP_NAME, "both names answer (4.7 with saved settings): the new name")
	testing.eq(EngineSettingNames.resolve(_Store.new({_FUTURE_SLEEP_NAME: 100000}), candidates),
			"", "neither name (a later rename): empty")
	print("")


# With no name to write to, lower() writes nothing and does not record a boost, both
# when the editor defines neither name and when the name it defines holds no value.
static func _test_lower_skips_without_a_name(testing) -> void:
	testing.begin("UnfocusedSleepController.lower — no write without a defined name")
	var renamed_store := _Store.new({_FUTURE_SLEEP_NAME: 100000})
	var controller := _controller_over(renamed_store)
	controller.lower()
	testing.eq(renamed_store.writes, [], "neither name: no write")
	testing.ok(not controller.is_unfocused_boost_active(), "neither name: no boost recorded")
	controller.lower()
	testing.eq(renamed_store.writes, [], "a second connect: still no write")

	var empty_store := _Store.new({_NEW_SLEEP_NAME: null})
	var empty_controller := _controller_over(empty_store)
	empty_controller.lower()
	testing.eq(empty_store.writes, [], "the defined name holds no value: no write")
	testing.ok(not empty_controller.is_unfocused_boost_active(), "no value: no boost recorded")
	print("")


# A boost can be active when the name stops resolving (another tool erased it); restore()
# then writes nothing and clears the in-memory boost.
static func _test_restore_skips_without_a_name(testing) -> void:
	testing.begin("UnfocusedSleepController.restore — no write without a defined name")
	var store := _Store.new({_FUTURE_SLEEP_NAME: 100000})
	var controller := _controller_over(store)
	# Seeds an active boost: only lower() records one, and its write path holds the
	# machine-wide registry lock and backup file, which a unit must not touch.
	controller._original_unfocused_sleep_usec = 100000
	controller.restore()
	testing.eq(store.writes, [], "neither name: no write")
	testing.ok(not controller.is_unfocused_boost_active(), "neither name: the boost is cleared")
	print("")


static func _controller_over(store: _Store) -> UnfocusedSleepController:
	var controller := UnfocusedSleepController.new()
	controller.set_settings_accessor(func() -> Object:
		return store)
	return controller


# A stand-in for EditorSettings that records each write.
class _Store:
	extends RefCounted

	var values: Dictionary = {}
	var writes: Array = []

	func _init(initial_values: Dictionary) -> void:
		values = initial_values

	func has_setting(key: String) -> bool:
		return values.has(key)

	func get_setting(key: String) -> Variant:
		return values.get(key)

	func set_setting(key: String, value: Variant) -> void:
		values[key] = value
		writes.append([key, value])
