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

const Testing := preload("res://test/units/testing.gd")
const PlaytestControl := preload("res://addons/godot_mcp_toolkit/commands/playtest/playtest_control.gd")
const PlaytestLogReader := preload("res://addons/godot_mcp_toolkit/commands/playtest_log_reader.gd")

const _MAIN_SCENE_KEY := "application/run/main_scene"
const _LOG_PATH_KEY := "debug/file_logging/log_path"
const _LOG_FIXTURE := "user://mcp_debugger_log_fixture.log"
const _ENV_RUNTIME := "GODOT_MCP_RUNTIME"
const _NO_SESSION_NOTE := "No game session recorded yet (game_start was never called this editor session)"
const _REMOTE_DEPLOY_NOTE := "The latest run is a one-click deploy; its log is on the device, not in this machine's godot.log"


static func run(testing) -> void:
	_test_main_scene_missing_predicate(testing)
	_test_debugger_log_reads_from_zero(testing)
	_test_debugger_log_reads_playtest_the_editor_launched(testing)
	_test_debugger_log_never_reads_local_log_for_deploy(testing)
	_test_runtime_opt_out_hint(testing)
	_test_runtime_opt_out_hint_text(testing)


# game.start names the opt-out when the editor's own environment carries it: the
# game inherits that environment, so its runtime channel never opens. The variable
# is restored before asserting.
static func _test_runtime_opt_out_hint(testing) -> void:
	testing.begin("game.start hint for an editor environment that opts games out")
	var had_env := OS.has_environment(_ENV_RUNTIME)
	var saved_env := OS.get_environment(_ENV_RUNTIME)

	OS.set_environment(_ENV_RUNTIME, "0")
	var opted_out_hint := PlaytestControl._runtime_opt_out_hint()
	OS.set_environment(_ENV_RUNTIME, "1")
	var opted_in_hint := PlaytestControl._runtime_opt_out_hint()

	if had_env:
		OS.set_environment(_ENV_RUNTIME, saved_env)
	else:
		OS.unset_environment(_ENV_RUNTIME)

	testing.ok(opted_out_hint.contains("GODOT_MCP_RUNTIME=0"),
		"GODOT_MCP_RUNTIME=0 in the editor's environment → a hint naming it")
	testing.ok(opted_in_hint.is_empty(), "any other value → no hint")
	print("")


# The hint word for word, quoting the value as the environment holds it, and the
# values that count as off, read the way the game's runtime server reads them.
static func _test_runtime_opt_out_hint_text(testing) -> void:
	testing.begin("game.start opt-out hint, word for word")
	var had_env := OS.has_environment(_ENV_RUNTIME)
	var saved_env := OS.get_environment(_ENV_RUNTIME)

	OS.set_environment(_ENV_RUNTIME, "Off")
	var off_hint := PlaytestControl._runtime_opt_out_hint()
	var off_values := []
	for value: String in ["0", "false", "off", "FALSE", " 0 ", "", "1", "no", "00"]:
		OS.set_environment(_ENV_RUNTIME, value)
		if not PlaytestControl._runtime_opt_out_hint().is_empty():
			off_values.append(value)

	if had_env:
		OS.set_environment(_ENV_RUNTIME, saved_env)
	else:
		OS.unset_environment(_ENV_RUNTIME)

	testing.eq(off_hint, (
		"The game won't open the runtime channel: GODOT_MCP_RUNTIME=Off is set in the editor's "
		+ "environment, and games the editor launches inherit it. Unset it and restart the editor "
		+ "to use runtime tools."
	), "the hint quotes the variable and its value")
	testing.eq(off_values, ["0", "false", "off", "FALSE", " 0 "], "the values that turn games off")
	print("")


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


# A debugger session reads godot.log only when it starts for a playtest the editor
# launched. The debug bridge's call and plugin.gd's _build() need a live editor, so
# the interactive check in the editor covers them; this pins the reader's rule.
static func _test_debugger_log_reads_playtest_the_editor_launched(testing: Testing) -> void:
	testing.begin("debugger.get_log reads a playtest the editor launched")
	# Both statics are saved and restored. The session flag is seeded false because
	# no public path clears it, and an earlier group leaves it set.
	var saved_session_started: bool = PlaytestLogReader._game_session_started
	var saved_remote_deploy: bool = PlaytestLogReader._latest_run_is_remote_deploy
	var had_setting := ProjectSettings.has_setting(_LOG_PATH_KEY)
	var original: Variant = ProjectSettings.get_setting(_LOG_PATH_KEY, "user://logs/godot.log")
	ProjectSettings.set_setting(_LOG_PATH_KEY, _LOG_FIXTURE)
	_write_log_fixture("HEADLINE\nbeta\n")
	PlaytestLogReader._game_session_started = false

	PlaytestLogReader.note_editor_run()
	PlaytestLogReader.mark_debugger_session_started(false)
	var not_playing: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})
	PlaytestLogReader.mark_debugger_session_started(true)
	var playing: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})

	_restore_log_path(had_setting, original)
	PlaytestLogReader._game_session_started = saved_session_started
	PlaytestLogReader._latest_run_is_remote_deploy = saved_remote_deploy

	var not_playing_note: String = str(not_playing.get("note", ""))
	var playing_lines: Array = playing.get("lines", [])
	testing.eq(not_playing_note, _NO_SESSION_NOTE,
			"a session that starts while the editor runs no playtest → the no-session note")
	testing.eq(playing_lines, ["HEADLINE", "beta"],
			"a session that starts for the editor's playtest → that playtest's log, head line first")

	print("")


# A one-click deploy's game logs on the device, so its session never reads this
# machine's godot.log, even after an earlier game_start set the session flag. The
# next playtest reads its own log again.
static func _test_debugger_log_never_reads_local_log_for_deploy(testing: Testing) -> void:
	testing.begin("debugger.get_log never reads the local log for a one-click deploy")
	var saved_session_started: bool = PlaytestLogReader._game_session_started
	var saved_remote_deploy: bool = PlaytestLogReader._latest_run_is_remote_deploy
	var had_setting := ProjectSettings.has_setting(_LOG_PATH_KEY)
	var original: Variant = ProjectSettings.get_setting(_LOG_PATH_KEY, "user://logs/godot.log")
	ProjectSettings.set_setting(_LOG_PATH_KEY, _LOG_FIXTURE)
	_write_log_fixture("HEADLINE\nbeta\n")

	# As after a game_start earlier in the editor session.
	PlaytestLogReader.mark_session_started()
	PlaytestLogReader.note_editor_run()
	PlaytestLogReader.note_remote_debug_deploy()
	PlaytestLogReader.mark_debugger_session_started(true)
	var deployed: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})
	PlaytestLogReader.note_editor_run()
	PlaytestLogReader.mark_debugger_session_started(true)
	var next_playtest: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})

	_restore_log_path(had_setting, original)
	PlaytestLogReader._game_session_started = saved_session_started
	PlaytestLogReader._latest_run_is_remote_deploy = saved_remote_deploy

	var deployed_note: String = str(deployed.get("note", ""))
	var deployed_lines: Array = deployed.get("lines", [])
	var next_playtest_lines: Array = next_playtest.get("lines", [])
	testing.eq(deployed_note, _REMOTE_DEPLOY_NOTE,
			"a deploy's session after an earlier game_start → the deploy note")
	testing.eq(deployed_lines, [],
			"a deploy's session after an earlier game_start → no lines from the local log")
	testing.eq(next_playtest_lines, ["HEADLINE", "beta"],
			"the next playtest after a deploy → its log again")

	print("")


## Points the debug-log path back where it was and deletes the fixture.
## [param had_setting] and [param original] are what the case read before it moved
## the path to _LOG_FIXTURE.
static func _restore_log_path(had_setting: bool, original: Variant) -> void:
	if had_setting:
		ProjectSettings.set_setting(_LOG_PATH_KEY, original)
	else:
		ProjectSettings.set_setting(_LOG_PATH_KEY, "user://logs/godot.log")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_LOG_FIXTURE))


## Write [param content] to the debug-log fixture (the user:// path in _LOG_FIXTURE).
static func _write_log_fixture(content: String) -> void:
	var f := FileAccess.open(_LOG_FIXTURE, FileAccess.WRITE)
	if f != null:
		f.store_string(content)
		f.close()
