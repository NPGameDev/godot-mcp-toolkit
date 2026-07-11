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
const PlaytestLogReader := preload("res://addons/godot_mcp_toolkit/commands/playtest_log_reader.gd")

const _MAIN_SCENE_KEY := "application/run/main_scene"
const _LOG_PATH_KEY := "debug/file_logging/log_path"
const _LOG_FIXTURE := "user://mcp_debugger_log_fixture.log"


static func run(testing) -> void:
	_test_main_scene_missing_predicate(testing)
	_test_debugger_log_reads_from_zero(testing)


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


## debugger.get_log (Mode A) reads the whole truncated session from byte 0.
##
## The engine truncates godot.log fresh on every launch (RotatedFileLogger), so the
## file is always exactly the current session — the reader must read from byte 0, not
## from a snapshotted previous-session size. Pins both failure modes the old offset
## scheme had: a session LONGER than the prior file dropped its head; a session SHORTER
## than the prior file false-emptied. Redirects the log path to a user:// fixture so the
## real godot.log is never touched; restores + deletes before asserting (no try/finally).
static func _test_debugger_log_reads_from_zero(testing) -> void:
	testing.begin("debugger.get_log reads whole truncated session (byte 0)")

	# Capture originals so the ProjectSettings mutation is never left behind.
	var had_setting := ProjectSettings.has_setting(_LOG_PATH_KEY)
	var original: Variant = ProjectSettings.get_setting(_LOG_PATH_KEY, "user://logs/godot.log")
	ProjectSettings.set_setting(_LOG_PATH_KEY, _LOG_FIXTURE)

	# Probe each state and store the result, THEN restore before asserting.
	# 1. No session started yet → the renamed sentinel returns the "no session" note.
	var no_session: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})

	# 2. Session started + a fixture whose FIRST line is distinctive: the whole file is
	#    this session, so the head line must survive (no first-N-bytes drop).
	PlaytestLogReader.mark_session_started()
	_write_log_fixture("HEADLINE\nbeta\ngamma\n")
	var full: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})

	# 3. A session SHORTER than a hypothetical prior offset must not read as empty.
	_write_log_fixture("solo\n")
	var short: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})

	# Restore the setting + remove the fixture BEFORE asserting.
	if had_setting:
		ProjectSettings.set_setting(_LOG_PATH_KEY, original)
	else:
		ProjectSettings.set_setting(_LOG_PATH_KEY, "user://logs/godot.log")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_LOG_FIXTURE))

	testing.ok(str(no_session.get("note", "")).contains("No game session"),
		"no session yet → 'no game session' note (renamed _game_session_started sentinel)")
	testing.ok((full.get("lines", []) as Array).has("HEADLINE"),
		"session head line present (reads from byte 0 — no first-N-bytes drop)")
	testing.ok(int(full.get("returned", 0)) == 3, "all 3 session lines returned")
	testing.ok(int(short.get("returned", 0)) == 1 and not (short.get("lines", []) as Array).is_empty(),
		"session shorter than prior file returns output (no false-empty)")

	print("")


## Write [param content] to the debug-log fixture (the user:// path in _LOG_FIXTURE).
static func _write_log_fixture(content: String) -> void:
	var f := FileAccess.open(_LOG_FIXTURE, FileAccess.WRITE)
	if f != null:
		f.store_string(content)
		f.close()
