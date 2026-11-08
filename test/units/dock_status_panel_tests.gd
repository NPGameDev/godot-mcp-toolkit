@tool
extends RefCounted
## Unit tests for the dock status panel's version line: which state it shows for the
## connected server's version, the update check's newest known version and the
## exemptions, and that a below-floor message takes its place. A stand-in server gives
## the verdict, since the live server needs a real peer; the runner and the setting are
## real. The rows pin the state; the gap's own tests pin what each line names.

const Testing := preload("res://test/units/testing.gd")
const DockStatusPanel := preload("res://addons/godot_mcp_toolkit/ui/dock/status/dock_status_panel.gd")
const ServerVersionGap := preload("res://addons/godot_mcp_toolkit/ui/dock/status/server_version_gap.gd")
const ServerPinPolicy := preload("res://addons/godot_mcp_toolkit/ui/mcp_json/server_pin_policy.gd")
const PeerCompat := preload("res://addons/godot_mcp_toolkit/transport/peer_compat.gd")
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")
const UpdateCheckRunner := preload("res://addons/godot_mcp_toolkit/versioning/update_check_runner.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")

const _NEWER_TOOLKIT := "99.0.0"
const _BELOW_FLOOR_MESSAGE := "The floor message."


# The live server's verdict needs an authenticated peer.
class _ServerStandIn extends Node:
	var verdict := {}

	func get_peer_compat() -> Dictionary:
		return verdict


static func run(testing: Testing) -> void:
	_test_version_line_table(testing)
	_test_below_floor_message_wins(testing)
	_test_without_a_runner(testing)


# Each row: what the case is, the verdict's state, the server version, the newest version
# the check found, the version it was dismissed at, whether the check is on, the version
# setting, and the state the panel shows. The panel reads the real state file, toggle and
# setting, so they go back before any check runs.
static func _test_version_line_table(testing: Testing) -> void:
	testing.begin("Status panel: the version line for each connected server")
	var recommended := VersionUtils.COMPATIBLE_SERVER_VERSION
	var below := _just_below(recommended)
	var above := _just_above(recommended)
	var rows := [
		["just below the recommended version", PeerCompat.STATE_OK, below, "", "", true, "", ServerVersionGap.SERVER_OLDER],
		["far below", PeerCompat.STATE_OK, "0.0.1", "", "", true, "", ServerVersionGap.SERVER_OLDER],
		["below, the check off", PeerCompat.STATE_OK, below, _NEWER_TOOLKIT, "", false, "", ServerVersionGap.SERVER_OLDER],
		["above, nothing newer known", PeerCompat.STATE_OK, above, "", "", true, "", ServerVersionGap.NONE],
		["above, a newer toolkit known", PeerCompat.STATE_OK, above, _NEWER_TOOLKIT, "", true, "", ServerVersionGap.SERVER_NEWER],
		["above, the newer toolkit dismissed", PeerCompat.STATE_OK, above, _NEWER_TOOLKIT, _NEWER_TOOLKIT, true, "", ServerVersionGap.SERVER_NEWER],
		["above, the check off", PeerCompat.STATE_OK, above, _NEWER_TOOLKIT, "", false, "", ServerVersionGap.NONE],
		["the same version", PeerCompat.STATE_OK, recommended, _NEWER_TOOLKIT, "", true, "", ServerVersionGap.NONE],
		["a prerelease", PeerCompat.STATE_OK, recommended + "-beta.1", _NEWER_TOOLKIT, "", true, "", ServerVersionGap.NONE],
		["no version", PeerCompat.STATE_OK, "", _NEWER_TOOLKIT, "", true, "", ServerVersionGap.NONE],
		["a skipped check (local server)", PeerCompat.STATE_SKIPPED, below, "", "", true, "", ServerVersionGap.NONE],
		["no peer", PeerCompat.STATE_NONE, "", "", "", true, "", ServerVersionGap.NONE],
		["setting latest", PeerCompat.STATE_OK, below, "", "", true, "latest", ServerVersionGap.NONE],
		["setting a version", PeerCompat.STATE_OK, below, "", "", true, below, ServerVersionGap.NONE],
	]
	var saved := _save_world()
	var results: Array[Dictionary] = []
	for row: Array in rows:
		results.append(_shown_by_panel(str(row[1]), str(row[2]), str(row[3]), str(row[4]), bool(row[5]), str(row[6])))
	_restore_world(saved)
	for index: int in rows.size():
		var row: Array = rows[index]
		var expected := str(row[7])
		var expected_text := ""
		if not expected.is_empty():
			expected_text = "⚠️ " + ServerVersionGap.line(expected, str(row[2]), recommended, _NEWER_TOOLKIT)
		testing.eq(results[index], {"visible": not expected.is_empty(), "text": expected_text},
				"%s → %s" % [row[0], expected if not expected.is_empty() else "nothing"])
	print("")


static func _test_below_floor_message_wins(testing: Testing) -> void:
	testing.begin("Status panel: a below-floor message takes the version line's place")
	var saved := _save_world()
	var shown := _shown_by_panel(PeerCompat.STATE_SERVER_BELOW_FLOOR, "0.0.1", "", "", true, "", _BELOW_FLOOR_MESSAGE)
	_restore_world(saved)
	testing.eq(shown, {"visible": true, "text": "⚠️ " + _BELOW_FLOOR_MESSAGE},
			"a server below the floor and the recommended version → its message alone")
	print("")


static func _test_without_a_runner(testing: Testing) -> void:
	testing.begin("Status panel: with no update check, a newer server shows nothing")
	var saved := _save_world()
	ProjectSettings.set_setting(ServerPinPolicy.SERVER_VERSION_SETTING, "")
	var recommended := VersionUtils.COMPATIBLE_SERVER_VERSION
	var older := _read_panel(_verdict(PeerCompat.STATE_OK, "0.0.1"), null)
	var newer := _read_panel(_verdict(PeerCompat.STATE_OK, _just_above(recommended)), null)
	_restore_world(saved)
	testing.ok(bool(older["visible"]), "an older server → still the line")
	testing.eq(newer, {"visible": false, "text": ""}, "a newer server → nothing")
	print("")


# The panel's version line after a refresh, with the check's state file, the toggle and
# the setting as the row says.
static func _shown_by_panel(verdict_state: String, server_version: String, latest: String, dismissed: String,
		check_on: bool, version_setting: String, message: String = "") -> Dictionary:
	var file := FileAccess.open(UpdateCheckRunner.STATE_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify({"last_check": int(Time.get_unix_time_from_system()),
			"latest_version": latest, "store_listed": false, "dismissed_version": dismissed}))
	file.close()
	ProjectSettings.set_setting(UpdateCheck.SETTING, check_on)
	ProjectSettings.set_setting(ServerPinPolicy.SERVER_VERSION_SETTING, version_setting)
	var runner := UpdateCheckRunner.new()
	var shown := _read_panel(_verdict(verdict_state, server_version, message), runner)
	runner.free()
	return shown


static func _read_panel(verdict: Dictionary, runner: UpdateCheckRunner) -> Dictionary:
	var server := _ServerStandIn.new()
	server.verdict = verdict
	var panel := DockStatusPanel.new(server, runner)
	panel.refresh_compat()
	var label := panel.get_node("CompatLabel") as Label
	var shown := {"visible": label.visible, "text": label.text}
	panel.free()
	server.free()
	return shown


static func _verdict(state: String, server_version: String, message: String = "") -> Dictionary:
	return PeerCompat.make_verdict(state, server_version, "", message)


# Takes one off the last part that isn't zero, zeroing the parts after it. A version
# whose patch is zero gives a wider gap, which the gap's own table covers row by row.
static func _just_below(version: String) -> String:
	var parts := version.split(".")
	for index: int in range(2, -1, -1):
		if int(parts[index]) > 0:
			parts[index] = str(int(parts[index]) - 1)
			break
		parts[index] = "0"
	return ".".join(parts)


static func _just_above(version: String) -> String:
	var parts := version.split(".")
	return "%s.%s.%d" % [parts[0], parts[1], int(parts[2]) + 1]


static func _save_world() -> Dictionary:
	var path: String = UpdateCheckRunner.STATE_PATH
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())
	return {
		"state": FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else null,
		"had_toggle": ProjectSettings.has_setting(UpdateCheck.SETTING),
		"toggle": ProjectSettings.get_setting(UpdateCheck.SETTING, null),
		"had_setting": ProjectSettings.has_setting(ServerPinPolicy.SERVER_VERSION_SETTING),
		"setting": ProjectSettings.get_setting(ServerPinPolicy.SERVER_VERSION_SETTING, null),
	}


static func _restore_world(saved: Dictionary) -> void:
	var path: String = UpdateCheckRunner.STATE_PATH
	if saved["state"] == null:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	else:
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_buffer(saved["state"])
		file.close()
	ProjectSettings.set_setting(UpdateCheck.SETTING, saved["toggle"] if bool(saved["had_toggle"]) else null)
	ProjectSettings.set_setting(ServerPinPolicy.SERVER_VERSION_SETTING,
			saved["setting"] if bool(saved["had_setting"]) else null)
