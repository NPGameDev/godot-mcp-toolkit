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
	_test_break_records_entry_only_on_error_break(testing)
	_test_break_reason_after_break_completes_entry(testing)
	_test_break_reason_before_break_reaches_entry(testing)
	_test_break_reason_ends_with_the_break(testing)
	_test_break_reason_reaches_entry_in_either_signal_order(testing)
	_test_stack_dump_locates_error_break_entry(testing)
	_test_stack_dump_without_reason_locates_entry(testing)
	_test_stack_dump_before_break_reaches_entry(testing)
	_test_latest_stack_dump_wins(testing)
	_test_stack_dump_at_breakpoint_pause_is_ignored(testing)
	_test_stack_dump_ends_with_the_break(testing)
	_test_stack_dump_leaves_earlier_buffer_unchanged(testing)
	_test_stack_dump_without_frame_location_is_ignored(testing)
	_test_stack_dump_on_failed_preload_names_preloaded_script(testing)
	_test_failed_preload_without_stack_dump_keeps_unlocated_text(testing)
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


static func _test_break_records_entry_only_on_error_break(testing: Testing) -> void:
	testing.begin("debug-session tracker break entry: error break only")
	var paused_tracker: RefCounted = _new_tracker(true)
	if paused_tracker == null:
		return
	paused_tracker.call("on_session_started")
	paused_tracker.call("on_session_breaked", true)
	var after_breakpoint: Array = paused_tracker.call("get_error_buffer")
	var tracker: RefCounted = _new_tracker(true)
	tracker.call("on_session_started")
	tracker.call("on_session_breaked", false)
	var after_error_break: Array = tracker.call("get_error_buffer")
	tracker.call("on_session_breaked", false)
	var after_second: Array = tracker.call("get_error_buffer")

	testing.eq(after_breakpoint.size(), 0, "a breakpoint pause → no entry")
	testing.eq(after_error_break.size(), 1, "an error break with an empty buffer → one entry")
	var entry: Dictionary = after_error_break[0] if after_error_break.size() == 1 else {}
	testing.eq(str(entry.get("message", "")),
			"Game paused at a script error it cannot continue from. Find the file and line with script_check or lsp_project_diagnostics, fix it, then game_stop and game_start.",
			"an error break with no reason text → the break entry's message without the error clause")
	testing.eq(str(entry.get("type", "")), "break", "the break entry's type")
	testing.eq(str(entry.get("source", "?")), "", "the break entry names no file")
	testing.eq(int(entry.get("line", -1)), 0, "the break entry names no line")
	testing.eq(after_second.size(), 1, "a second error break with an entry buffered → no new entry")
	print("")


static func _test_break_reason_after_break_completes_entry(testing: Testing) -> void:
	testing.begin("debug-session tracker error break, then the editor's reason")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	tracker.call("on_session_breaked", false)
	tracker.call("on_debugger_node_breaked", true, false, "Parser Error: Unexpected \"Identifier\" in class body.", false)
	var buffer: Array = tracker.call("get_error_buffer")
	var reason: String = tracker.call("get_break_reason")

	testing.eq(buffer.size(), 1, "an error break, then its reason → one entry")
	var entry: Dictionary = buffer[0] if buffer.size() == 1 else {}
	testing.eq(str(entry.get("message", "")),
			"Game paused at a script error it cannot continue from: Parser Error: Unexpected \"Identifier\" in class body. Find the file and line with script_check or lsp_project_diagnostics, fix it, then game_stop and game_start.",
			"a reason after the break → the entry's message carries it")
	testing.eq(reason, "Parser Error: Unexpected \"Identifier\" in class body",
			"the reason, without its trailing period")
	print("")


static func _test_break_reason_before_break_reaches_entry(testing: Testing) -> void:
	testing.begin("debug-session tracker handlers called directly: the editor's reason, then the error break")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	tracker.call("on_debugger_node_breaked", true, false, "Parser Error: x", false)
	tracker.call("on_session_breaked", false)
	var buffer: Array = tracker.call("get_error_buffer")

	var entry: Dictionary = buffer[0] if buffer.size() == 1 else {}
	testing.eq(str(entry.get("message", "")),
			"Game paused at a script error it cannot continue from: Parser Error: x. Find the file and line with script_check or lsp_project_diagnostics, fix it, then game_stop and game_start.",
			"a reason before the break → the entry's message carries it")
	print("")


static func _test_break_reason_ends_with_the_break(testing: Testing) -> void:
	testing.begin("debug-session tracker forgets the reason once the game continues or stops")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	tracker.call("on_session_breaked", false)
	tracker.call("on_debugger_node_breaked", true, false, "Parser Error: x", false)
	tracker.call("on_session_continued")
	var after_continue: String = tracker.call("get_break_reason")
	tracker.call("on_debugger_node_breaked", true, false, "Parser Error: later", false)
	var buffer: Array = tracker.call("get_error_buffer")
	tracker.call("on_session_breaked", false)
	tracker.call("on_debugger_node_breaked", true, false, "Parser Error: y", false)
	tracker.call("on_session_stopped")
	var after_stop: String = tracker.call("get_break_reason")

	testing.eq(after_continue, "", "continued → no reason")
	var entry: Dictionary = buffer[0] if buffer.size() == 1 else {}
	testing.eq(str(entry.get("message", "")),
			"Game paused at a script error it cannot continue from: Parser Error: x. Find the file and line with script_check or lsp_project_diagnostics, fix it, then game_stop and game_start.",
			"a reason after the game continued → the earlier break's entry unchanged")
	testing.eq(after_stop, "", "stopped → no reason")
	print("")


## One emission of the debugger node's breaked reaches the tracker twice: through the
## session, which re-emits it as its own breaked(can_debug), and straight from the
## node with the reason. The editor connects the session first, so its breaked
## usually arrives before the reason; the entry carries the reason either way.
static func _test_break_reason_reaches_entry_in_either_signal_order(testing: Testing) -> void:
	testing.begin("debug-session tracker error break through the node's and session's signals")
	var session_first := _entry_message_after_node_break(true)
	var reason_first := _entry_message_after_node_break(false)

	var expected := "Game paused at a script error it cannot continue from: Parser Error: Unexpected token. Find the file and line with script_check or lsp_project_diagnostics, fix it, then game_stop and game_start."
	testing.eq(session_first, expected, "the session's breaked before the node's reason → the entry carries the reason")
	testing.eq(reason_first, expected, "the node's reason before the session's breaked → the entry carries the reason")
	print("")


# -- Error-break location from the debugger node's stack dump --------------------


static func _test_stack_dump_locates_error_break_entry(testing: Testing) -> void:
	testing.begin("debug-session tracker error break, its reason, then the node's stack dump")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	tracker.call("on_session_breaked", false)
	tracker.call("on_debugger_node_breaked", true, false, "Cannot call method 'get_name' on a null value.", false)
	tracker.call("on_debugger_node_stack_dump", [
		_frame("res://cases/runtime_null.gd", "_ready", 8),
		_frame("res://cases/main.gd", "_on_start", 3),
	])
	var buffer: Array = tracker.call("get_error_buffer")
	var location: Dictionary = tracker.call("get_break_location")

	testing.eq(buffer.size(), 1, "an error break with a stack dump → one entry")
	var entry: Dictionary = buffer[0] if buffer.size() == 1 else {}
	testing.eq(str(entry.get("message", "")),
			"Game paused at a script error it cannot continue from: Cannot call method 'get_name' on a null value, at res://cases/runtime_null.gd:8. Fix it, then game_stop and game_start.",
			"a stack dump → the entry's message names frame 0's file and line, without the find-the-file advice")
	testing.eq(str(entry.get("source", "")), "res://cases/runtime_null.gd", "frame 0's file → the entry's source")
	testing.eq(str(entry.get("function", "")), "_ready", "frame 0's function → the entry's function")
	testing.eq(int(entry.get("line", 0)), 8, "frame 0's line → the entry's line")
	testing.eq(str(entry.get("type", "")), "break", "a located break entry keeps type break")
	testing.eq(location, {"source": "res://cases/runtime_null.gd", "function": "_ready", "line": 8},
			"a stack dump at an error break → get_break_location returns frame 0")
	print("")


static func _test_stack_dump_without_reason_locates_entry(testing: Testing) -> void:
	testing.begin("debug-session tracker error break with a stack dump and no reason")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	tracker.call("on_session_breaked", false)
	tracker.call("on_debugger_node_stack_dump", [_frame("res://cases/parse_main.gd", "", 7)])
	var buffer: Array = tracker.call("get_error_buffer")

	var entry: Dictionary = buffer[0] if buffer.size() == 1 else {}
	testing.eq(str(entry.get("message", "")),
			"Game paused at a script error it cannot continue from, at res://cases/parse_main.gd:7. Fix it, then game_stop and game_start.",
			"a stack dump and no reason → the located message without the error clause")
	print("")


static func _test_stack_dump_before_break_reaches_entry(testing: Testing) -> void:
	testing.begin("debug-session tracker handlers called directly: the node's stack dump, then the error break")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	tracker.call("on_debugger_node_stack_dump", [_frame("res://cases/parse_main.gd", "", 7)])
	tracker.call("on_session_breaked", false)
	tracker.call("on_debugger_node_breaked", true, false, "Parser Error: x", false)
	var buffer: Array = tracker.call("get_error_buffer")

	var entry: Dictionary = buffer[0] if buffer.size() == 1 else {}
	testing.eq(str(entry.get("message", "")),
			"Game paused at a script error it cannot continue from: Parser Error: x, at res://cases/parse_main.gd:7. Fix it, then game_stop and game_start.",
			"a stack dump before the break → kept for the entry the break records")
	testing.eq(int(entry.get("line", 0)), 7, "a stack dump before the break → the entry's line")
	print("")


static func _test_latest_stack_dump_wins(testing: Testing) -> void:
	testing.begin("debug-session tracker takes the latest stack dump of an error break")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	tracker.call("on_session_breaked", false)
	tracker.call("on_debugger_node_stack_dump", [_frame("res://a.gd", "_ready", 3)])
	tracker.call("on_debugger_node_stack_dump", [_frame("res://b.gd", "_process", 9)])
	var buffer: Array = tracker.call("get_error_buffer")

	testing.eq(buffer.size(), 1, "two stack dumps → still one entry")
	var entry: Dictionary = buffer[0] if buffer.size() == 1 else {}
	testing.eq(str(entry.get("source", "")), "res://b.gd", "two stack dumps → the latest's file")
	testing.eq(str(entry.get("function", "")), "_process", "two stack dumps → the latest's function")
	testing.eq(int(entry.get("line", 0)), 9, "two stack dumps → the latest's line")
	print("")


static func _test_stack_dump_at_breakpoint_pause_is_ignored(testing: Testing) -> void:
	testing.begin("debug-session tracker ignores a stack dump at a breakpoint pause")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	tracker.call("on_session_breaked", true)
	tracker.call("on_debugger_node_stack_dump", [_frame("res://cases/breakpoint_pause.gd", "_ready", 7)])
	var buffer: Array = tracker.call("get_error_buffer")
	var location_after: Dictionary = tracker.call("get_break_location")
	var early_tracker: RefCounted = _new_tracker(true)
	if early_tracker == null:
		return
	early_tracker.call("on_session_started")
	early_tracker.call("on_debugger_node_stack_dump", [_frame("res://cases/breakpoint_pause.gd", "_ready", 7)])
	early_tracker.call("on_session_breaked", true)
	var location_before: Dictionary = early_tracker.call("get_break_location")

	testing.eq(buffer.size(), 0, "a stack dump at a breakpoint pause → no entry")
	testing.eq(location_after, {}, "a stack dump at a breakpoint pause → no break location")
	testing.eq(location_before, {}, "a stack dump, then a breakpoint pause → no break location")
	print("")


static func _test_stack_dump_ends_with_the_break(testing: Testing) -> void:
	testing.begin("debug-session tracker forgets the stack dump once the game continues, stops or starts")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	tracker.call("on_debugger_node_stack_dump", [_frame("res://a.gd", "_ready", 3)])
	tracker.call("on_session_continued")
	var after_continue: Dictionary = tracker.call("get_break_location")
	tracker.call("on_session_breaked", false)
	var buffer: Array = tracker.call("get_error_buffer")
	tracker.call("on_debugger_node_stack_dump", [_frame("res://a.gd", "_ready", 3)])
	tracker.call("on_session_stopped")
	var after_stop: Dictionary = tracker.call("get_break_location")
	tracker.call("on_debugger_node_stack_dump", [_frame("res://a.gd", "_ready", 3)])
	tracker.call("on_session_started")
	var after_start: Dictionary = tracker.call("get_break_location")

	testing.eq(after_continue, {}, "continued → no break location")
	var entry: Dictionary = buffer[0] if buffer.size() == 1 else {}
	testing.eq(str(entry.get("message", "")),
			"Game paused at a script error it cannot continue from. Find the file and line with script_check or lsp_project_diagnostics, fix it, then game_stop and game_start.",
			"a stack dump before the game continued → the next error break's entry has no location")
	testing.eq(int(entry.get("line", -1)), 0, "a stack dump before the game continued → the next entry's line 0")
	testing.eq(after_stop, {}, "stopped → no break location")
	testing.eq(after_start, {}, "a new session → no break location")
	print("")


static func _test_stack_dump_leaves_earlier_buffer_unchanged(testing: Testing) -> void:
	testing.begin("debug-session tracker stack dump leaves a buffer read earlier unchanged")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	tracker.call("on_session_breaked", false)
	tracker.call("on_debugger_node_breaked", true, false, "Parser Error: x", false)
	var read_before: Array = tracker.call("get_error_buffer")
	tracker.call("on_debugger_node_stack_dump", [_frame("res://a.gd", "", 3)])
	var read_after: Array = tracker.call("get_error_buffer")

	var before: Dictionary = read_before[0] if read_before.size() == 1 else {}
	var after: Dictionary = read_after[0] if read_after.size() == 1 else {}
	testing.eq(str(before.get("message", "")),
			"Game paused at a script error it cannot continue from: Parser Error: x. Find the file and line with script_check or lsp_project_diagnostics, fix it, then game_stop and game_start.",
			"a buffer read before the stack dump → its entry's message unchanged")
	testing.eq(int(before.get("line", -1)), 0, "a buffer read before the stack dump → its entry's line unchanged")
	testing.eq(int(after.get("line", 0)), 3, "a buffer read after the stack dump → the located entry")
	print("")


static func _test_stack_dump_without_frame_location_is_ignored(testing: Testing) -> void:
	testing.begin("debug-session tracker ignores a stack dump with no frame 0 file or line")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	tracker.call("on_session_breaked", false)
	tracker.call("on_debugger_node_stack_dump", [])
	var after_empty: Dictionary = tracker.call("get_break_location")
	tracker.call("on_debugger_node_stack_dump", [_frame("", "_ready", 3)])
	var after_no_file: Dictionary = tracker.call("get_break_location")
	tracker.call("on_debugger_node_stack_dump", [_frame("res://a.gd", "_ready", 0)])
	var after_no_line: Dictionary = tracker.call("get_break_location")
	var buffer: Array = tracker.call("get_error_buffer")

	testing.eq(after_empty, {}, "an empty stack → no break location")
	testing.eq(after_no_file, {}, "frame 0 without a file → no break location")
	testing.eq(after_no_line, {}, "frame 0 with line 0 → no break location")
	var entry: Dictionary = buffer[0] if buffer.size() == 1 else {}
	testing.eq(str(entry.get("message", "")),
			"Game paused at a script error it cannot continue from. Find the file and line with script_check or lsp_project_diagnostics, fix it, then game_stop and game_start.",
			"ignored stack dumps → the entry's unlocated message")
	testing.eq(str(entry.get("source", "?")), "", "ignored stack dumps → the entry names no file")
	print("")


## The engine reports a script whose preload failed on the preloading script's line,
## with a reason that ends in the quoted path and a period.
static func _test_stack_dump_on_failed_preload_names_preloaded_script(testing: Testing) -> void:
	testing.begin("debug-session tracker located failed-preload break names the preloaded script")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	tracker.call("on_session_breaked", false)
	tracker.call("on_debugger_node_breaked", true, false,
			"Parser Error: Could not preload resource script \"res://cases/preload_inner.gd\".", false)
	tracker.call("on_debugger_node_stack_dump", [_frame("res://cases/preload_outer.gd", "", 4)])
	var buffer: Array = tracker.call("get_error_buffer")

	var entry: Dictionary = buffer[0] if buffer.size() == 1 else {}
	testing.eq(str(entry.get("message", "")),
			"Game paused at a script error it cannot continue from: Parser Error: Could not preload resource script \"res://cases/preload_inner.gd\", at res://cases/preload_outer.gd:4. The preloaded script res://cases/preload_inner.gd holds the error: run script_check on it. Fix it, then game_stop and game_start.",
			"a failed preload with a stack dump → the reason without its period, the location, then the preloaded script")
	testing.eq(str(entry.get("source", "")), "res://cases/preload_outer.gd",
			"a failed preload → the entry's source is frame 0, the preloading script")
	testing.eq(int(entry.get("line", 0)), 4, "a failed preload → the entry's line is frame 0's")
	print("")


static func _test_failed_preload_without_stack_dump_keeps_unlocated_text(testing: Testing) -> void:
	testing.begin("debug-session tracker failed-preload break without a stack dump")
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return
	tracker.call("on_session_started")
	tracker.call("on_session_breaked", false)
	tracker.call("on_debugger_node_breaked", true, false,
			"Parser Error: Could not preload resource script \"res://cases/preload_inner.gd\".", false)
	var buffer: Array = tracker.call("get_error_buffer")

	var entry: Dictionary = buffer[0] if buffer.size() == 1 else {}
	testing.eq(str(entry.get("message", "")),
			"Game paused at a script error it cannot continue from: Parser Error: Could not preload resource script \"res://cases/preload_inner.gd\". Find the file and line with script_check or lsp_project_diagnostics, fix it, then game_stop and game_start.",
			"a failed preload without a stack dump → the unlocated message, with no preloaded-script sentence")
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


## Emits an error break on a stand-in debugger node wired to a new tracker as the
## debugger plugin wires the live node and session, and returns the message of the
## one entry the tracker then buffers, or an empty String when it buffers another
## count. [param session_heard_first] connects the session to the node before the
## tracker, as the editor does.
static func _entry_message_after_node_break(session_heard_first: bool) -> String:
	var tracker: RefCounted = _new_tracker(true)
	if tracker == null:
		return ""
	var node := _DebuggerNodeStandIn.new()
	var session := _DebuggerSessionStandIn.new()
	var node_handler := Callable(tracker, &"on_debugger_node_breaked")
	if session_heard_first:
		node.breaked.connect(session.on_node_breaked)
		node.breaked.connect(node_handler)
	else:
		node.breaked.connect(node_handler)
		node.breaked.connect(session.on_node_breaked)
	session.breaked.connect(Callable(tracker, &"on_session_breaked"))
	tracker.call("on_session_started")
	node.breaked.emit(true, false, "Parser Error: Unexpected token.", false)
	var buffer: Array = tracker.call("get_error_buffer")
	if buffer.size() != 1:
		return ""
	var entry: Dictionary = buffer[0]
	return str(entry.get("message", ""))


## One frame of the editor debugger node's stack_dump payload.
static func _frame(file: String, function: String, line: int) -> Dictionary:
	return {"frame": 0, "file": file, "function": function, "line": line}


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


# The editor's debugger node, as far as its breaked signal goes: the reason text
# rides with the break.
class _DebuggerNodeStandIn:
	extends RefCounted

	signal breaked(reallydid: bool, can_debug: bool, reason: String, has_stackdump: bool)


# The editor's debugger session: re-emits its node's break without the reason, as
# the engine's EditorDebuggerSession does.
class _DebuggerSessionStandIn:
	extends RefCounted

	signal breaked(can_debug: bool)
	signal continued

	func on_node_breaked(really_did: bool, can_debug: bool, _reason: String, _has_stackdump: bool) -> void:
		if really_did:
			breaked.emit(can_debug)
		else:
			continued.emit()
