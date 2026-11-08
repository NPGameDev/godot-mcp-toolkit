@tool
extends RefCounted
## Unit tests for the server pin move after a self-update, through the project's own
## .mcp.json: the move of a pin the toolkit owns, the cases that stay, a failed write,
## Undo and its guard, the Undo marker, and the preview for the update window.

const Testing := preload("res://test/units/testing.gd")
const ServerPinMove := preload("res://addons/godot_mcp_toolkit/ui/mcp_json/server_pin_move.gd")
const ServerPinPolicy := preload("res://addons/godot_mcp_toolkit/ui/mcp_json/server_pin_policy.gd")
const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

const _PKG := "@npgamedev/godot-mcp-server"
const _OLD := "0.0.1"
const _HAND_SET := "0.0.9"


# The machine facts live in the editor's settings and project metadata, which a
# headless run has not; this stand-in keeps them in memory and records the writes.
class PinMoveStandIn extends ServerPinMove:
	var last_written := ""
	var recorded: Array = []
	var local_path := ""
	var undone_for := ""

	func read_last_written() -> String:
		return last_written

	func record_written(spec: String) -> void:
		recorded.append(spec)
		last_written = spec

	func local_server_path() -> String:
		return local_path

	func read_undone_for() -> String:
		return undone_for

	func record_undone_for(version: String) -> void:
		undone_for = version


# Collects one (ok, message, severity, tooltip) report.
class _Report extends RefCounted:
	var calls := 0
	var ok := false
	var message := ""
	var severity := -1

	func take(report_ok: bool, report_message: String, report_severity: int, _tooltip: String) -> void:
		calls += 1
		ok = report_ok
		message = report_message
		severity = report_severity


static func run(testing: Testing) -> void:
	_test_moves_a_pin_it_owns(testing)
	_test_moves_the_last_write(testing)
	_test_only_an_installed_update_moves(testing)
	_test_hand_set_pin_stays(testing)
	_test_version_setting_keeps_the_pin(testing)
	_test_entry_at_the_target_stays(testing)
	_test_malformed_file_is_a_failed_write(testing)
	_test_malformed_file_stays_when_the_pin_would(testing)
	_test_failed_write_leaves_the_file(testing)
	_test_undo_puts_the_pin_back(testing)
	_test_undo_after_a_hand_edit_writes_nothing(testing)
	_test_undo_without_a_move_does_nothing(testing)
	_test_undone_update_does_not_move_again(testing)
	_test_preview(testing)


## The settle report of an installed update to toolkit [param to] from one that
## recommended server [param old_server].
static func updated(to: String = "1.9.0", old_server: String = _OLD) -> Dictionary:
	return {"report": "updated", "from": "1.1.0", "to": to, "reason": "", "attempts": 0,
			"compatible_server": old_server}


## A .mcp.json document whose toolkit entry runs the server at [param version], with a
## user env key and another server beside it.
static func document_at(version: String) -> String:
	return JSON.stringify({
		"mcpServers": {
			"godot-mcp-toolkit": {
				"command": "npx",
				"args": ["-y", _PKG + "@" + version],
				"env": {"GODOT_MCP_CONFIG_VERSION": "1", "GODOT_MCP_TEST_KEEP": "1"},
			},
			"other-server": {"command": "other"},
		},
	})


## Puts [param text] in the project's .mcp.json and empties the server version setting.
## Returns what [method restore_project] puts back.
static func install_project(text: String) -> Dictionary:
	var path := MCPJsonSync.get_mcp_json_path()
	var saved := {
		"file": FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else null,
		"had_setting": ProjectSettings.has_setting(ServerPinPolicy.SERVER_VERSION_SETTING),
		"setting": ProjectSettings.get_setting(ServerPinPolicy.SERVER_VERSION_SETTING, ""),
	}
	_store(path, text.to_utf8_buffer())
	ProjectSettings.set_setting(ServerPinPolicy.SERVER_VERSION_SETTING, "")
	return saved


## Puts back the .mcp.json and the setting [method install_project] replaced.
static func restore_project(saved: Dictionary) -> void:
	var path := MCPJsonSync.get_mcp_json_path()
	UpdateFixtures.set_read_only(path, false)
	if saved["file"] == null:
		DirAccess.remove_absolute(path)
	else:
		_store(path, saved["file"])
	ProjectSettings.set_setting(ServerPinPolicy.SERVER_VERSION_SETTING,
			saved["setting"] if bool(saved["had_setting"]) else null)


## The project's .mcp.json as text.
static func mcp_json_text() -> String:
	return FileAccess.get_file_as_string(MCPJsonSync.get_mcp_json_path())


## The parsed .mcp.json, or {} when it is not a JSON object.
static func mcp_json_document() -> Dictionary:
	var json := JSON.new()
	if json.parse(mcp_json_text()) != OK or not json.data is Dictionary:
		return {}
	return json.data


## The npm package spec the toolkit's entry in [param document] runs, its last arg.
static func entry_package(document: Dictionary) -> String:
	var servers: Dictionary = document.get("mcpServers", {})
	var entry: Dictionary = servers.get("godot-mcp-toolkit", {})
	var args: Array = entry.get("args", [])
	return str(args[args.size() - 1]) if not args.is_empty() else ""


## Whether [param document] still holds the user's env key and the other server.
static func keeps_the_rest(document: Dictionary) -> bool:
	var servers: Dictionary = document.get("mcpServers", {})
	var entry: Dictionary = servers.get("godot-mcp-toolkit", {})
	var env: Dictionary = entry.get("env", {})
	return str(env.get("GODOT_MCP_TEST_KEEP", "")) == "1" and servers.has("other-server")


static func _store(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()


static func _test_moves_a_pin_it_owns(testing: Testing) -> void:
	testing.begin("Server pin move: an installed update moves the old recommended pin")
	var saved := install_project(document_at(_OLD))
	var pin_move := PinMoveStandIn.new()
	pin_move.follow_update(updated())
	var document := mcp_json_document()
	var outcome := pin_move.outcome()
	var can_undo := pin_move.can_undo()
	restore_project(saved)
	var compatible := VersionUtils.COMPATIBLE_SERVER_VERSION
	testing.eq(entry_package(document), _PKG + "@" + compatible, "the entry → the recommended server")
	testing.ok(keeps_the_rest(document), "the user's env key and the other server → kept")
	testing.eq(pin_move.recorded, ["npx:" + compatible], "the write → recorded as this machine's")
	testing.eq(outcome, {"state": "moved", "from_spec": "npx:" + _OLD, "to_spec": "npx:" + compatible,
			"from_version": _OLD, "to_version": compatible, "error": ""}, "the outcome → moved, from and to")
	testing.ok(can_undo, "an unchanged entry → Undo allowed")
	print("")


static func _test_moves_the_last_write(testing: Testing) -> void:
	testing.begin("Server pin move: the entry this machine last wrote moves, whatever the old recommended version")
	var saved := install_project(document_at(_HAND_SET))
	var pin_move := PinMoveStandIn.new()
	pin_move.last_written = "npx:" + _HAND_SET
	pin_move.follow_update(updated("1.9.0", ""))
	var package := entry_package(mcp_json_document())
	restore_project(saved)
	testing.eq(package, _PKG + "@" + VersionUtils.COMPATIBLE_SERVER_VERSION, "the last write → moved")
	testing.eq(str(pin_move.outcome()["state"]), "moved", "the outcome → moved")
	print("")


static func _test_only_an_installed_update_moves(testing: Testing) -> void:
	testing.begin("Server pin move: a start that installed nothing leaves the file")
	var reports := {"failed": "failed", "waiting": "waiting", "nothing": ""}
	for label: String in reports:
		var saved := install_project(document_at(_OLD))
		var before := mcp_json_text()
		var settled := updated()
		settled["report"] = reports[label]
		var pin_move := PinMoveStandIn.new()
		pin_move.follow_update(settled)
		var after := mcp_json_text()
		restore_project(saved)
		testing.eq(after, before, "%s → file bytes unchanged" % label)
		testing.eq(str(pin_move.outcome()["state"]), "", "%s → no outcome" % label)
		testing.eq(pin_move.recorded, [], "%s → nothing recorded" % label)
	print("")


static func _test_hand_set_pin_stays(testing: Testing) -> void:
	testing.begin("Server pin move: a pin set by hand stays")
	var saved := install_project(document_at(_HAND_SET))
	var before := mcp_json_text()
	var pin_move := PinMoveStandIn.new()
	pin_move.last_written = "npx:" + _OLD
	pin_move.follow_update(updated())
	var after := mcp_json_text()
	restore_project(saved)
	testing.eq(after, before, "an entry neither recommended nor written here → file bytes unchanged")
	testing.eq(str(pin_move.outcome()["state"]), "", "no outcome")
	print("")


static func _test_version_setting_keeps_the_pin(testing: Testing) -> void:
	testing.begin("Server pin move: the server version setting and a local server keep the pin")
	var saved := install_project(document_at(_OLD))
	var before := mcp_json_text()
	ProjectSettings.set_setting(ServerPinPolicy.SERVER_VERSION_SETTING, _OLD)
	var by_setting := PinMoveStandIn.new()
	by_setting.follow_update(updated())
	var after_setting := mcp_json_text()
	ProjectSettings.set_setting(ServerPinPolicy.SERVER_VERSION_SETTING, "")
	var by_local := PinMoveStandIn.new()
	by_local.local_path = "/dev/godot-mcp-server/dist/index.js"
	by_local.follow_update(updated())
	var after_local := mcp_json_text()
	restore_project(saved)
	testing.eq(after_setting, before, "a version in the setting → file bytes unchanged")
	testing.eq(str(by_setting.outcome()["state"]), "", "and no outcome")
	testing.eq(after_local, before, "a local server path → file bytes unchanged")
	testing.eq(str(by_local.outcome()["state"]), "", "and no outcome")
	print("")


static func _test_entry_at_the_target_stays(testing: Testing) -> void:
	testing.begin("Server pin move: an entry another editor already moved, or an update that keeps the server, stays")
	var compatible := VersionUtils.COMPATIBLE_SERVER_VERSION
	var saved := install_project(document_at(compatible))
	var moved_before := mcp_json_text()
	var already := PinMoveStandIn.new()
	already.last_written = "npx:" + _OLD
	already.follow_update(updated())
	var moved_after := mcp_json_text()
	_store(MCPJsonSync.get_mcp_json_path(), document_at(_HAND_SET).to_utf8_buffer())
	var same_before := mcp_json_text()
	var same_server := PinMoveStandIn.new()
	same_server.last_written = "npx:" + _HAND_SET
	same_server.follow_update(updated("1.9.0", compatible))
	var same_after := mcp_json_text()
	restore_project(saved)
	testing.eq(moved_after, moved_before, "an entry already at the recommended server → file bytes unchanged")
	testing.eq(str(already.outcome()["state"]), "", "and no outcome")
	testing.eq(already.recorded, [], "and nothing recorded")
	testing.eq(same_after, same_before, "the same recommended server before and after → file bytes unchanged")
	testing.eq(str(same_server.outcome()["state"]), "", "and no outcome")
	testing.eq(same_server.recorded, [], "and nothing recorded")
	print("")


# A file that does not parse hides its pin, so when nothing but the entry would keep the
# pin, the move reports a failed write and the user fixes the file.
static func _test_malformed_file_is_a_failed_write(testing: Testing) -> void:
	testing.begin("Server pin move: a malformed .mcp.json is a failed write, and stays as it is")
	var malformed := "{ \"mcpServers\": { not json"
	var saved := install_project(malformed)
	var pin_move := PinMoveStandIn.new()
	pin_move.follow_update(updated())
	var after := mcp_json_text()
	var outcome := pin_move.outcome()
	var can_retry := pin_move.can_retry()
	var can_undo := pin_move.can_undo()
	restore_project(saved)
	var compatible := VersionUtils.COMPATIBLE_SERVER_VERSION
	testing.eq(after, malformed, "file bytes unchanged")
	testing.eq(outcome, {"state": "write_failed", "from_spec": "unknown", "to_spec": "npx:" + compatible,
			"from_version": "", "to_version": compatible,
			"error": ".mcp.json isn't valid JSON, or its mcpServers isn't an object — fix or delete it, then retry"},
			"the outcome → write failed, with the malformed-file reason")
	testing.eq(pin_move.recorded, [], "nothing recorded")
	testing.ok(can_retry, "a file still malformed → writing the entry is still the fix")
	testing.ok(not can_undo, "no Undo")
	print("")


static func _test_malformed_file_stays_when_the_pin_would(testing: Testing) -> void:
	testing.begin("Server pin move: a malformed .mcp.json has no outcome when the pin would stay anyway")
	var malformed := "{ \"mcpServers\": { not json"
	var saved := install_project(malformed)
	ProjectSettings.set_setting(ServerPinPolicy.SERVER_VERSION_SETTING, _OLD)
	var by_setting := PinMoveStandIn.new()
	by_setting.follow_update(updated())
	ProjectSettings.set_setting(ServerPinPolicy.SERVER_VERSION_SETTING, "")
	var by_local := PinMoveStandIn.new()
	by_local.local_path = "/dev/godot-mcp-server/dist/index.js"
	by_local.follow_update(updated())
	var same_server := PinMoveStandIn.new()
	same_server.follow_update(updated("1.9.0", VersionUtils.COMPATIBLE_SERVER_VERSION))
	var not_updated := PinMoveStandIn.new()
	var failed := updated()
	failed["report"] = "failed"
	not_updated.follow_update(failed)
	var after := mcp_json_text()
	restore_project(saved)
	testing.eq(after, malformed, "file bytes unchanged")
	testing.eq(str(by_setting.outcome()["state"]), "", "a version in the setting → no outcome")
	testing.eq(str(by_local.outcome()["state"]), "", "a local server path → no outcome")
	testing.eq(str(same_server.outcome()["state"]), "", "the same recommended server → no outcome")
	testing.eq(str(not_updated.outcome()["state"]), "", "a start that installed nothing → no outcome")
	print("")


static func _test_failed_write_leaves_the_file(testing: Testing) -> void:
	testing.begin("Server pin move: a write that fails leaves the file and reports why")
	var saved := install_project(document_at(_OLD))
	var before := mcp_json_text()
	UpdateFixtures.set_read_only(MCPJsonSync.get_mcp_json_path(), true)
	var pin_move := PinMoveStandIn.new()
	pin_move.follow_update(updated())
	var after := mcp_json_text()
	var outcome := pin_move.outcome()
	var can_retry := pin_move.can_retry()
	var can_undo := pin_move.can_undo()
	restore_project(saved)
	testing.eq(after, before, "a read-only file → bytes unchanged")
	testing.eq(str(outcome["state"]), "write_failed", "the outcome → write failed")
	testing.ok(str(outcome["error"]).begins_with("Failed to write .mcp.json"), "with the write's reason")
	testing.eq(pin_move.recorded, [], "nothing recorded")
	testing.ok(can_retry, "the entry the move found → writing it is still the fix")
	testing.ok(not can_undo, "no Undo")
	print("")


static func _test_undo_puts_the_pin_back(testing: Testing) -> void:
	testing.begin("Server pin move: Undo writes the old server back")
	var saved := install_project(document_at(_OLD))
	var pin_move := PinMoveStandIn.new()
	pin_move.follow_update(updated())
	var report := _Report.new()
	pin_move.undo(Callable(report, "take"))
	var document := mcp_json_document()
	var outcome := pin_move.outcome()
	var can_undo := pin_move.can_undo()
	restore_project(saved)
	testing.eq(entry_package(document), _PKG + "@" + _OLD, "the entry → the old server again")
	testing.ok(keeps_the_rest(document), "the user's env key and the other server → kept")
	testing.eq(pin_move.last_written, "npx:" + _OLD, "the record → the old server")
	testing.eq(pin_move.undone_for, "1.9.0", "the update → marked undone")
	testing.eq(str(outcome["state"]), "undone", "the outcome → undone")
	testing.ok(not can_undo, "Undo → no longer offered")
	testing.eq([report.calls, report.ok, report.message, report.severity],
			[1, true, "MCP: .mcp.json runs server %s again." % _OLD, 0], "one info report naming the server")
	print("")


static func _test_undo_after_a_hand_edit_writes_nothing(testing: Testing) -> void:
	testing.begin("Server pin move: Undo after a hand edit leaves the file alone")
	var saved := install_project(document_at(_OLD))
	var pin_move := PinMoveStandIn.new()
	pin_move.follow_update(updated())
	_store(MCPJsonSync.get_mcp_json_path(), document_at(_HAND_SET).to_utf8_buffer())
	var hand_edited := mcp_json_text()
	var can_undo := pin_move.can_undo()
	var report := _Report.new()
	pin_move.undo(Callable(report, "take"))
	var after := mcp_json_text()
	restore_project(saved)
	testing.ok(not can_undo, "an entry changed since the move → no Undo")
	testing.eq(after, hand_edited, "Undo → the hand edit kept")
	testing.eq(pin_move.recorded.size(), 1, "no write recorded after the move's")
	testing.eq(pin_move.undone_for, "", "the update → not marked undone")
	testing.eq([report.calls, report.ok, report.message, report.severity],
			[1, false, "MCP: .mcp.json changed since the update, so it was left as it is.", 1],
			"one warning saying the file was left")
	print("")


static func _test_undo_without_a_move_does_nothing(testing: Testing) -> void:
	testing.begin("Server pin move: Undo with no move to undo writes and reports nothing")
	var saved := install_project(document_at(_HAND_SET))
	var before := mcp_json_text()
	var pin_move := PinMoveStandIn.new()
	pin_move.follow_update(updated())
	var report := _Report.new()
	pin_move.undo(Callable(report, "take"))
	var after := mcp_json_text()
	restore_project(saved)
	testing.eq(after, before, "a pin that stayed → file bytes unchanged")
	testing.eq(report.calls, 0, "and no report")
	testing.eq(pin_move.undone_for, "", "and the update not marked undone")
	print("")


# A journal that would not delete reports the same update at the next start.
static func _test_undone_update_does_not_move_again(testing: Testing) -> void:
	testing.begin("Server pin move: an update whose move was undone does not move the pin again")
	var saved := install_project(document_at(_OLD))
	var before := mcp_json_text()
	var again := PinMoveStandIn.new()
	again.undone_for = "1.9.0"
	again.follow_update(updated("1.9.0"))
	var after_same := mcp_json_text()
	var later := PinMoveStandIn.new()
	later.undone_for = "1.9.0"
	later.follow_update(updated("1.10.0"))
	var later_package := entry_package(mcp_json_document())
	restore_project(saved)
	testing.eq(after_same, before, "the same update reported again → file bytes unchanged")
	testing.eq(str(again.outcome()["state"]), "", "and no outcome")
	testing.eq(later_package, _PKG + "@" + VersionUtils.COMPATIBLE_SERVER_VERSION, "a later update → moves")
	print("")


static func _test_preview(testing: Testing) -> void:
	testing.begin("Server pin move: the preview names the move a click on Update would make")
	var compatible := VersionUtils.COMPATIBLE_SERVER_VERSION
	var saved := install_project(document_at(compatible))
	var pin_move := PinMoveStandIn.new()
	var movable := pin_move.preview("9.9.9")
	var same := pin_move.preview(compatible)
	var by_local := PinMoveStandIn.new()
	by_local.local_path = "/dev/godot-mcp-server/dist/index.js"
	var local := by_local.preview("9.9.9")
	ProjectSettings.set_setting(ServerPinPolicy.SERVER_VERSION_SETTING, "latest")
	var by_setting := pin_move.preview("9.9.9")
	ProjectSettings.set_setting(ServerPinPolicy.SERVER_VERSION_SETTING, "")
	_store(MCPJsonSync.get_mcp_json_path(), document_at(_HAND_SET).to_utf8_buffer())
	var hand_set := pin_move.preview("9.9.9")
	var bare := document_at(compatible).replace(_PKG + "@" + compatible, _PKG)
	_store(MCPJsonSync.get_mcp_json_path(), bare.to_utf8_buffer())
	var unversioned := pin_move.preview("9.9.9")
	var after := mcp_json_text()
	restore_project(saved)
	testing.eq(movable, {"from": compatible, "to": "9.9.9"}, "the recommended pin → from and to")
	testing.eq(same, {}, "the same recommended version → none")
	testing.eq(local, {}, "a local server path → none")
	testing.eq(by_setting, {}, "a version setting → none")
	testing.eq(hand_set, {}, "a pin set by hand → none")
	testing.eq(unversioned, {}, "an entry with no version → none")
	testing.eq(after, bare, "a preview → writes nothing")
	print("")
