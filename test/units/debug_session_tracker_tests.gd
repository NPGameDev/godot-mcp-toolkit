@tool
extends RefCounted
## Pins the debug-session tracker and the debugger.get_log reads it decides: whose game
## the latest debugger session is, its attach and pause state, and its error buffer.
## The cases drive the tracker with a stand-in editor port and read through
## cmd_debugger_get_log. The debugger plugin, the editor's build step and the deploy
## export that feed the tracker need a live editor: not covered by the sweep yet; GAP
## in SWEEP-COVERAGE-MANIFEST.md (`debugger.get_log`).

const Testing := preload("res://test/units/testing.gd")
const PlaytestLogReader := preload("res://addons/godot_mcp_toolkit/commands/playtest_log_reader.gd")

# Loaded rather than preloaded, and the reader's tracker seam called by name, so the
# file also loads against a reader that predates the tracker: its reads then show
# what that reader answers.
const _TRACKER_PATH := "res://addons/godot_mcp_toolkit/transport/debug_session_tracker.gd"
const _DETECTOR_PATH := "res://addons/godot_mcp_toolkit/core/remote_deploy_detector.gd"

const _LOG_PATH_KEY := "debug/file_logging/log_path"
const _DEFAULT_LOG_PATH := "user://logs/godot.log"
const _FIXTURE_LINES := "HEADLINE\nbeta\n"
const _NONE_NOTE := "No playtest has run from this editor session yet, so there is no local log to read. A game started outside this editor writes its log on its own machine."
const _ELSEWHERE_NOTE := "The latest debugger session is a game this editor did not run on this machine (a one-click deploy, or a game attached from outside); its log stays with that game. This machine's godot.log holds the last local playtest: read it with editor_get_console(source:\"file\")."
const _DEBUG_FLAG_REMOTE_DEBUG := 2
const _MANUAL_EXPORT_FLAGS := 0


static func run(testing: Testing) -> void:
	_test_read_before_any_session_gives_none_note(testing)
	_test_playtest_session_reads_its_log(testing)
	_test_stopped_playtest_session_still_reads_its_log(testing)
	_test_external_attach_gives_elsewhere_note(testing)
	_test_deploy_after_game_start_gives_elsewhere_note(testing)
	_test_manual_export_after_deploy_keeps_elsewhere(testing)
	_test_deploy_that_never_attaches_keeps_local_log(testing)
	_test_playtest_after_deploy_session_reads_its_log(testing)
	_test_build_clears_pending_deploy(testing)
	_test_build_after_blocked_session_keeps_elsewhere(testing)
	_test_reader_merges_debug_state_only_from_injected_tracker(testing)
	_test_session_state_follows_session_events(testing)
	_test_break_records_generic_entry_only_when_needed(testing)
	_test_debugger_error_payload_is_decoded(testing)
	_test_error_buffer_read_returns_a_copy(testing)
	_test_error_buffer_keeps_latest_fifty(testing)
	_test_session_start_clears_error_buffer(testing)


# -- Latest-session reads -------------------------------------------------------


static func _test_read_before_any_session_gives_none_note(testing: Testing) -> void:
	testing.begin("debugger.get_log before any playtest or debugger session")
	var saved_log := _redirect_log_to_fixture()
	_inject_tracker(false)
	var read: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})
	_reset_reader()
	_restore_log(saved_log)

	testing.eq(_reader_has_tracker_seam(), ResourceLoader.exists(_TRACKER_PATH),
			"the reader's tracker seam exists with the tracker")
	testing.eq(str(read.get("note", "")), _NONE_NOTE, "no session yet → the no-playtest note")
	testing.eq(read.get("lines", []), [], "no session yet → no lines")
	print("")


static func _test_playtest_session_reads_its_log(testing: Testing) -> void:
	testing.begin("debugger.get_log after a playtest's debugger session starts")
	var saved_log := _redirect_log_to_fixture()
	var tracker: RefCounted = _inject_tracker(true)
	if tracker != null:
		tracker.call("on_session_started")
	var read: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})
	_reset_reader()
	_restore_log(saved_log)

	testing.eq(read.get("lines", []), ["HEADLINE", "beta"],
			"a session that starts while the editor plays, no deploy pending → the playtest's log")
	print("")


static func _test_stopped_playtest_session_still_reads_its_log(testing: Testing) -> void:
	testing.begin("debugger.get_log after a playtest's debugger session stops")
	var saved_log := _redirect_log_to_fixture()
	var tracker: RefCounted = _inject_tracker(true)
	if tracker != null:
		tracker.call("on_session_started")
		tracker.call("on_session_stopped")
	var read: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})
	_reset_reader()
	_restore_log(saved_log)

	testing.eq(read.get("lines", []), ["HEADLINE", "beta"],
			"a playtest's session that has stopped → still the playtest's log")
	print("")


static func _test_external_attach_gives_elsewhere_note(testing: Testing) -> void:
	testing.begin("debugger.get_log after a game attaches from outside the editor")
	var saved_log := _redirect_log_to_fixture()
	var tracker: RefCounted = _inject_tracker(false)
	if tracker != null:
		tracker.call("on_session_started")
	var read: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})
	_reset_reader()
	_restore_log(saved_log)

	testing.eq(str(read.get("note", "")), _ELSEWHERE_NOTE,
			"a session that starts while the editor plays nothing → the elsewhere note")
	testing.eq(read.get("lines", []), [], "a session that starts while the editor plays nothing → no lines")
	print("")


static func _test_deploy_after_game_start_gives_elsewhere_note(testing: Testing) -> void:
	testing.begin("debugger.get_log after a one-click deploy that follows a game_start")
	var saved_log := _redirect_log_to_fixture()
	var tracker: RefCounted = _inject_tracker(true)
	PlaytestLogReader.mark_session_started()
	if tracker != null:
		tracker.call("note_editor_build")
		_export_project(tracker, _DEBUG_FLAG_REMOTE_DEBUG)
		tracker.call("on_session_started")
	var read: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})
	_reset_reader()
	_restore_log(saved_log)

	testing.eq(str(read.get("note", "")), _ELSEWHERE_NOTE,
			"the deployed game's session → the elsewhere note")
	testing.eq(read.get("lines", []), [],
			"the deployed game's session → no lines from the earlier playtest's log")
	print("")


static func _test_manual_export_after_deploy_keeps_elsewhere(testing: Testing) -> void:
	testing.begin("debugger.get_log after a manual export follows a deploy's session")
	var tracker: RefCounted = _inject_tracker(true)
	if tracker == null:
		return
	var saved_log := _redirect_log_to_fixture()
	tracker.call("note_editor_build")
	_export_project(tracker, _DEBUG_FLAG_REMOTE_DEBUG)
	tracker.call("on_session_started")
	_export_project(tracker, _MANUAL_EXPORT_FLAGS)
	var read: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})
	_reset_reader()
	_restore_log(saved_log)

	testing.eq(str(read.get("note", "")), _ELSEWHERE_NOTE,
			"a manual export (flags 0) after a deploy's session → still the elsewhere note")
	print("")


static func _test_deploy_that_never_attaches_keeps_local_log(testing: Testing) -> void:
	testing.begin("debugger.get_log after a deploy whose game never attaches")
	var tracker: RefCounted = _inject_tracker(true)
	if tracker == null:
		return
	var saved_log := _redirect_log_to_fixture()
	PlaytestLogReader.mark_session_started()
	tracker.call("note_editor_build")
	_export_project(tracker, _DEBUG_FLAG_REMOTE_DEBUG)
	var read: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})
	_reset_reader()
	_restore_log(saved_log)

	testing.eq(read.get("lines", []), ["HEADLINE", "beta"],
			"a deploy with no session after a game_start → the playtest's log, still the latest session's")
	print("")


static func _test_playtest_after_deploy_session_reads_its_log(testing: Testing) -> void:
	testing.begin("debugger.get_log after the next playtest follows a deploy's session")
	var tracker: RefCounted = _inject_tracker(true)
	if tracker == null:
		return
	var saved_log := _redirect_log_to_fixture()
	tracker.call("note_editor_build")
	_export_project(tracker, _DEBUG_FLAG_REMOTE_DEBUG)
	tracker.call("on_session_started")
	tracker.call("note_editor_build")
	tracker.call("on_session_started")
	var read: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})
	_reset_reader()
	_restore_log(saved_log)

	testing.eq(read.get("lines", []), ["HEADLINE", "beta"],
			"a deploy's session, then a build step and a playtest's session → the playtest's log")
	print("")


static func _test_build_clears_pending_deploy(testing: Testing) -> void:
	testing.begin("debugger.get_log after a build step clears a pending deploy")
	var tracker: RefCounted = _inject_tracker(true)
	if tracker == null:
		return
	var saved_log := _redirect_log_to_fixture()
	_export_project(tracker, _DEBUG_FLAG_REMOTE_DEBUG)
	tracker.call("note_editor_build")
	tracker.call("on_session_started")
	var read: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})
	_reset_reader()
	_restore_log(saved_log)

	testing.eq(read.get("lines", []), ["HEADLINE", "beta"],
			"deploy export, then a build step, then a playtest's session → the playtest's log")
	print("")


static func _test_build_after_blocked_session_keeps_elsewhere(testing: Testing) -> void:
	testing.begin("debugger.get_log after a build step follows a session a pending deploy claimed")
	var tracker: RefCounted = _inject_tracker(true)
	if tracker == null:
		return
	var saved_log := _redirect_log_to_fixture()
	_export_project(tracker, _DEBUG_FLAG_REMOTE_DEBUG)
	tracker.call("on_session_started")
	tracker.call("note_editor_build")
	var read: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})
	_reset_reader()
	_restore_log(saved_log)

	testing.eq(str(read.get("note", "")), _ELSEWHERE_NOTE,
			"no game_start, deploy export, a session while playing, then a build step → the elsewhere note")
	print("")


static func _test_reader_merges_debug_state_only_from_injected_tracker(testing: Testing) -> void:
	testing.begin("debugger.get_log carries debug_state only once a tracker is injected")
	var saved_log := _redirect_log_to_fixture()
	_reset_reader()
	var uninjected: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})
	var tracker: RefCounted = _inject_tracker(true)
	if tracker != null:
		tracker.call("on_session_started")
	var injected: Dictionary = PlaytestLogReader.cmd_debugger_get_log({})
	_reset_reader()
	_restore_log(saved_log)

	testing.ok(not uninjected.has("debug_state"), "no tracker injected → no debug_state")
	testing.ok(not uninjected.has("error_buffer"), "no tracker injected → no error_buffer")
	if tracker == null:
		print("")
		return
	testing.eq(injected.get("debug_state", {}), {"active": true, "breaked": false, "can_debug": false},
			"an injected tracker with a live session → its debug_state")
	print("")


# -- Session state and error buffer ----------------------------------------------


static func _test_session_state_follows_session_events(testing: Testing) -> void:
	testing.begin("debug-session tracker state through start, break, continue and stop")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	var before: Dictionary = tracker.call("get_debug_state")
	tracker.call("on_session_started")
	var started: Dictionary = tracker.call("get_debug_state")
	tracker.call("on_session_breaked", true)
	var breaked: Dictionary = tracker.call("get_debug_state")
	var breaked_flags: Array = [tracker.call("is_active"), tracker.call("is_breaked")]
	tracker.call("on_session_continued")
	var continued: Dictionary = tracker.call("get_debug_state")
	tracker.call("on_session_breaked", false)
	var breaked_undebuggable: Dictionary = tracker.call("get_debug_state")
	tracker.call("on_session_stopped")
	var stopped: Dictionary = tracker.call("get_debug_state")
	var stopped_flags: Array = [tracker.call("is_active"), tracker.call("is_breaked")]

	testing.eq(before, {"active": false, "breaked": false, "can_debug": false}, "no session → all false")
	testing.eq(started, {"active": true, "breaked": false, "can_debug": false}, "session started → active")
	testing.eq(breaked, {"active": true, "breaked": true, "can_debug": true},
			"a debuggable break → breaked and can_debug")
	testing.eq(breaked_flags, [true, true], "a break → is_active and is_breaked")
	testing.eq(continued, {"active": true, "breaked": false, "can_debug": false},
			"continued → no longer breaked")
	testing.eq(breaked_undebuggable, {"active": true, "breaked": true, "can_debug": false},
			"a break the debugger cannot step from → breaked, not can_debug")
	testing.eq(stopped, {"active": false, "breaked": false, "can_debug": false}, "session stopped → all false")
	testing.eq(stopped_flags, [false, false], "stopped → neither is_active nor is_breaked")
	print("")


static func _test_break_records_generic_entry_only_when_needed(testing: Testing) -> void:
	testing.begin("debug-session tracker break fallback entry")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	tracker.call("on_session_breaked", false)
	var after_undebuggable: Array = tracker.call("get_error_buffer")
	tracker.call("on_session_breaked", true)
	var after_debuggable: Array = tracker.call("get_error_buffer")
	tracker.call("on_session_breaked", true)
	var after_second: Array = tracker.call("get_error_buffer")

	testing.eq(after_undebuggable.size(), 0, "a break the debugger cannot step from → no entry")
	testing.eq(after_debuggable.size(), 1, "a debuggable break with an empty buffer → one entry")
	var entry: Dictionary = after_debuggable[0] if after_debuggable.size() == 1 else {}
	testing.eq(str(entry.get("message", "")), "Game paused at error (details in editor Errors tab or log)",
			"the break entry's message")
	testing.eq(str(entry.get("type", "")), "break", "the break entry's type")
	testing.eq(after_second.size(), 1, "a second debuggable break with an entry buffered → no new entry")
	print("")


static func _test_debugger_error_payload_is_decoded(testing: Testing) -> void:
	testing.begin("debug-session tracker decodes a debugger error payload")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	tracker.call("buffer_debugger_error", _error_payload("err", "descr", false))
	tracker.call("buffer_debugger_error", _error_payload("bare err", "", false))
	tracker.call("buffer_debugger_error", _error_payload("warn", "warn descr", true))
	tracker.call("buffer_debugger_error", ["too", "short"])
	var buffer: Array = tracker.call("get_error_buffer")

	testing.eq(buffer.size(), 2,
			"an error and a description-less error buffered; a warning and a short payload ignored")
	var described: Dictionary = buffer[0] if buffer.size() == 2 else {}
	var bare: Dictionary = buffer[1] if buffer.size() == 2 else {}
	testing.eq(str(described.get("message", "")), "descr", "a description → the entry's message")
	testing.eq(str(described.get("source", "")), "res://a.gd", "source_file → source")
	testing.eq(str(described.get("function", "")), "f", "source_func → function")
	testing.eq(int(described.get("line", -1)), 7, "source_line → line")
	testing.eq(str(described.get("type", "")), "error", "a debugger error → type error")
	testing.eq(str(bare.get("message", "")), "bare err", "no description → the error text")
	print("")


static func _test_error_buffer_read_returns_a_copy(testing: Testing) -> void:
	testing.begin("debug-session tracker hands out a copy of its error buffer")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	tracker.call("buffer_debugger_error", _error_payload("err", "", false))
	var handed_out: Array = tracker.call("get_error_buffer")
	handed_out.clear()
	var read_again: Array = tracker.call("get_error_buffer")

	testing.eq(read_again.size(), 1, "clearing a read buffer → the tracker's errors kept")
	print("")


static func _test_error_buffer_keeps_latest_fifty(testing: Testing) -> void:
	testing.begin("debug-session tracker error buffer cap")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	for index: int in range(50):
		tracker.call("buffer_debugger_error", _error_payload("e%d" % index, "", false))
	var at_cap: Array = tracker.call("get_error_buffer")
	tracker.call("buffer_debugger_error", _error_payload("e50", "", false))
	var past_cap: Array = tracker.call("get_error_buffer")

	testing.eq(at_cap.size(), 50, "50 errors → all 50 kept")
	testing.eq(str((at_cap[0] as Dictionary).get("message", "")) if at_cap.size() > 0 else "", "e0",
			"50 errors → the first is still the oldest")
	testing.eq(past_cap.size(), 50, "51 errors → 50 kept")
	testing.eq(str((past_cap[0] as Dictionary).get("message", "")) if past_cap.size() > 0 else "", "e1",
			"51 errors → the oldest dropped")
	testing.eq(str((past_cap[49] as Dictionary).get("message", "")) if past_cap.size() == 50 else "", "e50",
			"51 errors → the newest kept last")
	print("")


static func _test_session_start_clears_error_buffer(testing: Testing) -> void:
	testing.begin("debug-session tracker clears the buffer for a new session")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	tracker.call("buffer_debugger_error", _error_payload("err", "", false))
	tracker.call("on_session_stopped")
	var after_stop: Array = tracker.call("get_error_buffer")
	tracker.call("on_session_started")
	var after_restart: Array = tracker.call("get_error_buffer")

	testing.eq(after_stop.size(), 1, "a stopped session → its errors kept")
	testing.eq(after_restart.size(), 0, "the next session starts → an empty buffer")
	print("")


# -- Helpers ----------------------------------------------------------------------


## Returns a new tracker whose stand-in port answers [param playing], or null when the
## build has no tracker.
static func _new_tracker(playing: bool) -> RefCounted:
	if not ResourceLoader.exists(_TRACKER_PATH):
		return null
	var tracker_script: GDScript = load(_TRACKER_PATH)
	return tracker_script.new(_EditorPortStandIn.new(playing))


## Injects a new tracker into the reader and returns it, or returns null when the
## reader has no tracker seam. [param playing] is what its stand-in port answers.
static func _inject_tracker(playing: bool) -> RefCounted:
	if not _reader_has_tracker_seam():
		return null
	var tracker: RefCounted = _new_tracker(playing)
	_reader_script().call("set_session_tracker", tracker)
	return tracker


## Puts the reader back to its no-tracker state, where it reads as before any session.
static func _reset_reader() -> void:
	if _reader_has_tracker_seam():
		_reader_script().call("clear_session_tracker")


static func _reader_has_tracker_seam() -> bool:
	for method: Dictionary in _reader_script().get_script_method_list():
		if str(method["name"]) == "set_session_tracker":
			return true
	return false


## The reader as a script value, so its seams are looked up by name when called.
static func _reader_script() -> GDScript:
	return PlaytestLogReader


## Reports an export to [param tracker] the way the remote-deploy detector's
## _export_begin does, which the headless runner cannot reach (an EditorExportPlugin
## cannot be built there): only flags carrying remote debug count as a deploy.
static func _export_project(tracker: RefCounted, flags: int) -> void:
	var detector_script: GDScript = load(_DETECTOR_PATH)
	if bool(detector_script.call("is_remote_debug_deploy", flags)):
		tracker.call("note_remote_debug_deploy")


## An "error" debugger message's payload: the engine's fixed fields, then an empty
## call stack.
static func _error_payload(error: String, error_descr: String, is_warning: bool) -> Array:
	return [12, 0, 0, 0, "res://a.gd", "f", 7, error, error_descr, is_warning, 0]


## Points the debug-log path at a fixture holding two lines and returns what to
## restore: [code]had_setting[/code] and [code]original[/code].
static func _redirect_log_to_fixture() -> Dictionary:
	var saved := {
		"had_setting": ProjectSettings.has_setting(_LOG_PATH_KEY),
		"original": ProjectSettings.get_setting(_LOG_PATH_KEY, _DEFAULT_LOG_PATH),
	}
	var fixture_path := _fixture_path()
	ProjectSettings.set_setting(_LOG_PATH_KEY, fixture_path)
	var file := FileAccess.open(fixture_path, FileAccess.WRITE)
	if file != null:
		file.store_string(_FIXTURE_LINES)
		file.close()
	return saved


## Puts the debug-log path back from [param saved] and deletes the fixture.
static func _restore_log(saved: Dictionary) -> void:
	if bool(saved["had_setting"]):
		ProjectSettings.set_setting(_LOG_PATH_KEY, saved["original"])
	else:
		ProjectSettings.set_setting(_LOG_PATH_KEY, _DEFAULT_LOG_PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_fixture_path()))


static func _fixture_path() -> String:
	return "user://mcp_debug_session_fixture_%d.log" % OS.get_process_id()


# Answers the one editor fact the tracker reads, in place of the live editor.
class _EditorPortStandIn:
	extends RefCounted

	var _playing: bool = false

	func _init(playing: bool) -> void:
		_playing = playing

	func is_playing_scene() -> bool:
		return _playing
