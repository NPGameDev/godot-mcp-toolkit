@tool
extends RefCounted
## Unit tests for playtest-command pure predicates (no editor/game process needed).
##
## Currently pins the game.start "main" pre-guard predicate _main_scene_missing():
## when application/run/main_scene is unset/blank the guard must fire (→ NO_SCENE)
## instead of letting EditorInterface.play_main_scene() pop the engine's
## undismissable "No main scene has ever been defined" modal (which returns
## silently → a false success). The full handler short-circuits on is_headless()
## before the match, so it is NOT cleanly unit-reachable headless; this pins the
## exact predicate the guard calls. The happy path (a real main scene reaches
## play_main_scene) is validated interactively.

const PlaytestControl := preload("res://addons/godot_mcp_toolkit/commands/playtest/playtest_control.gd")

const _MAIN_SCENE_KEY := "application/run/main_scene"


static func run(testing) -> void:
	_test_main_scene_missing_predicate(testing)


static func _test_main_scene_missing_predicate(testing) -> void:
	testing.begin("game.start main-scene pre-guard")

	# Capture the original so the ProjectSettings mutation is never left behind.
	var had_setting := ProjectSettings.has_setting(_MAIN_SCENE_KEY)
	var original: Variant = ProjectSettings.get_setting(_MAIN_SCENE_KEY, "")

	# Probe each state and store the result, THEN restore before asserting — GDScript
	# has no try/finally, so this guarantees the setting is clean regardless of outcome.
	ProjectSettings.set_setting(_MAIN_SCENE_KEY, "")
	var empty_missing := PlaytestControl._main_scene_missing()

	ProjectSettings.set_setting(_MAIN_SCENE_KEY, "   ")
	var blank_missing := PlaytestControl._main_scene_missing()

	ProjectSettings.set_setting(_MAIN_SCENE_KEY, "res://Main.tscn")
	var set_missing := PlaytestControl._main_scene_missing()

	# Restore original state.
	if had_setting:
		ProjectSettings.set_setting(_MAIN_SCENE_KEY, original)
	else:
		ProjectSettings.set_setting(_MAIN_SCENE_KEY, "")

	testing.ok(empty_missing, "empty main_scene → missing (guard fires → NO_SCENE)")
	testing.ok(blank_missing, "whitespace-only main_scene → missing (strip_edges)")
	testing.ok(not set_missing, "a res:// main_scene → NOT missing (happy path reaches play_main_scene)")

	print("")
