@tool
extends RefCounted
## Unit tests for the playtest commands that run without an editor or a game: the
## game.start main-scene guard and opt-out hint, and the editor-side debugger.get_log
## reads of godot.log (whole file, locked file, missing file, a break entry against
## the log's errors). game.start itself returns early when headless, so the guard is
## pinned through the predicate it calls; a real main scene reaching play_main_scene
## is covered by the sweep's row 21.4.

const Testing := preload("res://test/units/testing.gd")
const PlaytestControl := preload("res://addons/godot_mcp_toolkit/commands/playtest/playtest_control.gd")
const PlaytestLogReader := preload("res://addons/godot_mcp_toolkit/commands/playtest_log_reader.gd")
const DebugSessionTracker := preload("res://addons/godot_mcp_toolkit/transport/debug_session_tracker.gd")

const _MAIN_SCENE_KEY := "application/run/main_scene"
const _LOG_PATH_KEY := "debug/file_logging/log_path"
const _DEFAULT_LOG_PATH := "user://logs/godot.log"
const _LOG_FIXTURE := "user://mcp_debugger_log_fixture.log"
const _LOCKED_LOG_FIXTURE := "user://mcp_debugger_log_locked.log"
const _ABSENT_LOG_FIXTURE := "user://mcp_debugger_log_absent.log"
const _ENV_RUNTIME := "GODOT_MCP_RUNTIME"
const _LOG_UNREADABLE_NOTE := "This machine's log file exists, but the editor cannot open it while the game has it open for writing, as on Windows at an error break or a breakpoint pause. debug_state, and error_buffer when errors were caught, still describe the game. At an error break, stop the game with game_stop and read again for the full log; at a breakpoint pause, debug_continue lets the running game answer with its own log. With no game running, retry shortly: a backup, antivirus or sync tool may be holding the file."
const _LOG_NOT_FOUND_NOTE := "Log file not found. Enable debug/file_logging/enable_file_logging in ProjectSettings and restart."


static func run(testing: Testing) -> void:
	_test_main_scene_missing_predicate(testing)
	_test_debugger_log_reads_from_zero(testing)
	_test_debugger_log_locked_file_keeps_session_state(testing)
	_test_debugger_log_absent_file_note(testing)
	_test_debugger_log_scans_past_break_entry(testing)
	_test_debugger_log_keeps_break_entry_without_log_errors(testing)
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
static func _test_debugger_log_reads_from_zero(testing: Testing) -> void:
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

	testing.ok(str(no_session.get("note", "")).contains("No playtest has run from this editor session yet"),
		"no playtest yet → the no-playtest note")
	testing.ok((full.get("lines", []) as Array).has("HEADLINE"),
		"session head line present (reads from byte 0 — no first-N-bytes drop)")
	testing.ok(int(full.get("returned", 0)) == 3, "all 3 session lines returned")
	testing.ok(int(short.get("returned", 0)) == 1 and not (short.get("lines", []) as Array).is_empty(),
		"session shorter than prior file returns output (no false-empty)")

	print("")


## debugger.get_log while the game holds godot.log open for writing, as on Windows at
## an error break or a breakpoint pause: the editor's safe-save makes its own read
## deny-write, so the open fails, and the reader answers with the session's state and
## a note instead of an error. On Windows the case holds a share-everything write
## handle and turns safe-save on, as the editor runs; elsewhere it takes the file's
## permissions away. A host that can still read the file skips the case.
static func _test_debugger_log_locked_file_keeps_session_state(testing: Testing) -> void:
	testing.begin("debugger.get_log on a log the game holds open: success, note, debug_state")
	var had_setting := ProjectSettings.has_setting(_LOG_PATH_KEY)
	var original: Variant = ProjectSettings.get_setting(_LOG_PATH_KEY, _DEFAULT_LOG_PATH)
	ProjectSettings.set_setting(_LOG_PATH_KEY, _LOCKED_LOG_FIXTURE)
	_write_log_fixture("line\n", _LOCKED_LOG_FIXTURE)
	# The reader's tracker is static state: saved here, put back before asserting.
	var saved_tracker: DebugSessionTracker = PlaytestLogReader._session_tracker
	var saved_injected: bool = PlaytestLogReader._session_tracker_injected
	var tracker := DebugSessionTracker.new(_EditorPortStandIn.new(true))
	PlaytestLogReader.set_session_tracker(tracker)
	tracker.on_session_started()
	tracker.on_session_breaked(false)

	var on_windows := OS.get_name() == "Windows"
	var game_writer: FileAccess = null
	if on_windows:
		# Opened while safe-save is still off, so it shares everything, as the game's does.
		game_writer = FileAccess.open(_LOCKED_LOG_FIXTURE, FileAccess.READ_WRITE)
		OS.set_use_file_access_save_and_swap(true)
	else:
		FileAccess.set_unix_permissions(_LOCKED_LOG_FIXTURE, 0)
	var locked := FileAccess.open(_LOCKED_LOG_FIXTURE, FileAccess.READ) == null
	var read: Dictionary = PlaytestLogReader.cmd_debugger_get_log({}) if locked else {}

	# The headless runner never turns safe-save on, so off is the value to put back.
	if on_windows:
		OS.set_use_file_access_save_and_swap(false)
		if game_writer != null:
			game_writer.close()
	else:
		FileAccess.set_unix_permissions(_LOCKED_LOG_FIXTURE,
				FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	PlaytestLogReader._session_tracker = saved_tracker
	PlaytestLogReader._session_tracker_injected = saved_injected
	_restore_log_path(had_setting, original)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_LOCKED_LOG_FIXTURE))

	if not locked:
		print("  SKIP: this host reads the file through a share-everything writer or with no permissions (POSIX root)")
		print("")
		return
	testing.eq(read.get("success", false), true, "a locked log → a success")
	testing.eq(read.get("code", null), null, "a locked log → no error code")
	testing.eq(str(read.get("note", "")), _LOG_UNREADABLE_NOTE, "a locked log → the unreadable-log note")
	testing.eq(read.get("lines", null), [], "a locked log → no lines")
	testing.eq(read.get("debug_state", {}), {"active": true, "breaked": true, "can_debug": false},
			"a locked log at an error break → the session's debug_state")
	testing.eq((read.get("error_buffer", []) as Array).size(), 1,
			"a locked log at an error break → the break's error_buffer entry")
	print("")


## debugger.get_log with no file at the log path: the not-found note, with the
## session's state still merged.
static func _test_debugger_log_absent_file_note(testing: Testing) -> void:
	testing.begin("debugger.get_log with no log file: the not-found note and debug_state")
	var had_setting := ProjectSettings.has_setting(_LOG_PATH_KEY)
	var original: Variant = ProjectSettings.get_setting(_LOG_PATH_KEY, _DEFAULT_LOG_PATH)
	ProjectSettings.set_setting(_LOG_PATH_KEY, _ABSENT_LOG_FIXTURE)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_ABSENT_LOG_FIXTURE))
	# The reader's tracker is static state: saved here, put back before asserting.
	var saved_tracker: DebugSessionTracker = PlaytestLogReader._session_tracker
	var saved_injected: bool = PlaytestLogReader._session_tracker_injected
	var tracker := DebugSessionTracker.new(_EditorPortStandIn.new(true))
	PlaytestLogReader.set_session_tracker(tracker)
	tracker.on_session_started()
	var read: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})

	PlaytestLogReader._session_tracker = saved_tracker
	PlaytestLogReader._session_tracker_injected = saved_injected
	_restore_log_path(had_setting, original)

	testing.eq(str(read.get("note", "")), _LOG_NOT_FOUND_NOTE, "no log file → the not-found note")
	testing.eq(read.get("debug_state", {}), {"active": true, "breaked": false, "can_debug": false},
			"no log file → the session's debug_state")
	print("")


## debugger.get_log when the only buffered entry is a break's: the log's error lines
## still get scanned, and the error they name, with its file and line, replaces the
## break entry.
static func _test_debugger_log_scans_past_break_entry(testing: Testing) -> void:
	testing.begin("debugger.get_log with only a break entry buffered: the log scan's entry")
	var read := _read_log_with_break_entry("SCRIPT ERROR: x\n   at: _ready (res://a.gd:8)\n")

	var buffer: Array = read.get("error_buffer", [])
	var entry: Dictionary = buffer[0] if buffer.size() == 1 else {}
	testing.eq(buffer.size(), 1, "an error in the log → one error_buffer entry")
	testing.eq(str(entry.get("type", "")), "log_scan", "an error in the log → the log scan's entry")
	testing.eq(str(entry.get("message", "")), "x", "the log scan's entry → the error's message")
	testing.eq(str(entry.get("source", "")), "res://a.gd", "the log scan's entry → the error's file")
	testing.eq(str(entry.get("function", "")), "_ready", "the log scan's entry → the error's function")
	testing.eq(int(entry.get("line", 0)), 8, "the log scan's entry → the error's line")
	print("")


## debugger.get_log when the only buffered entry is a break's and the log names no
## error: the break entry stays.
static func _test_debugger_log_keeps_break_entry_without_log_errors(testing: Testing) -> void:
	testing.begin("debugger.get_log with only a break entry buffered and a clean log: the break entry")
	var read := _read_log_with_break_entry("alpha\nbeta\n")

	var buffer: Array = read.get("error_buffer", [])
	var entry: Dictionary = buffer[0] if buffer.size() == 1 else {}
	testing.eq(buffer.size(), 1, "no error in the log → one error_buffer entry")
	testing.eq(str(entry.get("type", "")), "break", "no error in the log → the break entry")
	testing.eq(str(entry.get("message", "")),
			"Game paused at a script error it cannot continue from. Find the file and line with script_check or lsp_project_diagnostics, fix it, then game_stop and game_start.",
			"no error in the log → the break entry's message")
	print("")


## Reads debugger.get_log for a playtest whose log holds [param content] and whose
## game is at an error break, so its tracker has the break's entry buffered.
## Restores the log path and the reader's tracker, and deletes the fixture, before
## returning the read.
static func _read_log_with_break_entry(content: String) -> Dictionary:
	var had_setting := ProjectSettings.has_setting(_LOG_PATH_KEY)
	var original: Variant = ProjectSettings.get_setting(_LOG_PATH_KEY, _DEFAULT_LOG_PATH)
	ProjectSettings.set_setting(_LOG_PATH_KEY, _LOG_FIXTURE)
	_write_log_fixture(content)
	# The reader's tracker is static state: saved here, put back before returning.
	var saved_tracker: DebugSessionTracker = PlaytestLogReader._session_tracker
	var saved_injected: bool = PlaytestLogReader._session_tracker_injected
	var tracker := DebugSessionTracker.new(_EditorPortStandIn.new(true))
	PlaytestLogReader.set_session_tracker(tracker)
	tracker.on_session_started()
	tracker.on_session_breaked(false)
	var read: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})

	PlaytestLogReader._session_tracker = saved_tracker
	PlaytestLogReader._session_tracker_injected = saved_injected
	_restore_log_path(had_setting, original)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_LOG_FIXTURE))
	return read


## Write [param content] to the debug-log fixture at [param path].
static func _write_log_fixture(content: String, path: String = _LOG_FIXTURE) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(content)
		f.close()


## Puts the debug-log path setting back: [param original] when [param had_setting],
## else the engine default.
static func _restore_log_path(had_setting: bool, original: Variant) -> void:
	if had_setting:
		ProjectSettings.set_setting(_LOG_PATH_KEY, original)
	else:
		ProjectSettings.set_setting(_LOG_PATH_KEY, _DEFAULT_LOG_PATH)


# Answers the one editor fact the tracker reads, in place of the live editor.
class _EditorPortStandIn:
	extends RefCounted

	var _playing: bool = false

	func _init(playing: bool) -> void:
		_playing = playing

	func is_playing_scene() -> bool:
		return _playing
