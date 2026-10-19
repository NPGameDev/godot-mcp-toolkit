@tool
extends RefCounted
## The consent gate: what the toolkit may do on its own, from the user's settings and
## the setup steps they have seen.
##
## A setting alone is not consent when the user has never been told about it: the
## toolkit acts only once the setup step that explains the action has been seen,
## and then only while its setting is on. This is apart from tool permissions,
## which govern what an MCP client may ask for.

# Direct preloads, not core/modules.gd: the aggregator preloads the update check
# runner, which preloads this file.
const SetupSteps := preload("res://addons/godot_mcp_toolkit/core/setup_steps.gd")
const SetupStepTracker := preload("res://addons/godot_mcp_toolkit/core/setup_step_tracker.gd")
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")

# Injected readers for tests; an invalid Callable reads the real source.
# () -> bool: the project's update check toggle.
static var _toggle_reader: Callable = Callable()
# (step_id: StringName) -> bool: whether a setup step has been seen.
static var _seen_reader: Callable = Callable()


## Replace the update check toggle and seen-step readers with
## [param toggle_reader] ([code]() -> bool[/code]) and [param seen_reader]
## ([code](step_id: StringName) -> bool[/code]), for tests. [method reset_readers]
## undoes it.
static func set_readers(toggle_reader: Callable, seen_reader: Callable) -> void:
	_toggle_reader = toggle_reader
	_seen_reader = seen_reader


## Read the project setting and the setup step tracker again.
static func reset_readers() -> void:
	set_readers(Callable(), Callable())


## Whether the toolkit may ask GitHub and the Asset Store for a newer version:
## [code]mcp_toolkit/updates/check_for_updates[/code] is on and the setup step that
## explains the check has been seen.
static func may_check_for_updates() -> bool:
	return _update_toggle_on() and _has_seen(SetupSteps.UPDATES)


static func _update_toggle_on() -> bool:
	if _toggle_reader.is_valid():
		return bool(_toggle_reader.call())
	return UpdateCheck.is_check_enabled(ProjectSettings)


static func _has_seen(step_id: StringName) -> bool:
	if _seen_reader.is_valid():
		return bool(_seen_reader.call(step_id))
	return SetupStepTracker.has_seen(step_id)
