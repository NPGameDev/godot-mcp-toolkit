@tool
extends RefCounted
## Unit tests for the update check runner's read of its state file: the newest version
## it knows, whether or not the badge shows that version. The network is never touched.

const Testing := preload("res://test/units/testing.gd")
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")
const UpdateCheckRunner := preload("res://addons/godot_mcp_toolkit/versioning/update_check_runner.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")

const _KNOWN := "9.9.9"


static func run(testing: Testing) -> void:
	_test_latest_known_version(testing)


# The runner reads this project's real state file and toggle, so both are put back
# before any check runs.
static func _test_latest_known_version(testing: Testing) -> void:
	testing.begin("Update check runner: the newest known version outlives a dismissal")
	var path: String = UpdateCheckRunner.STATE_PATH
	var saved_state: Variant = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else null
	var had_toggle: bool = ProjectSettings.has_setting(UpdateCheck.SETTING)
	var saved_toggle: Variant = ProjectSettings.get_setting(UpdateCheck.SETTING) if had_toggle else null
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())

	ProjectSettings.set_setting(UpdateCheck.SETTING, true)
	var shown := _read(path, _KNOWN, "")
	var dismissed := _read(path, _KNOWN, _KNOWN)
	var nothing_found := _read(path, "", "")
	var not_newer := _read(path, VersionUtils.read_plugin_version(), "")
	ProjectSettings.set_setting(UpdateCheck.SETTING, false)
	var toggle_off := _read(path, _KNOWN, "")

	ProjectSettings.set_setting(UpdateCheck.SETTING, saved_toggle)
	if saved_state == null:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	else:
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_buffer(saved_state)
		file.close()

	testing.eq(shown, {"badge": _KNOWN, "known": _KNOWN}, "a newer version → the badge and the known version")
	testing.eq(dismissed, {"badge": "", "known": _KNOWN}, "dismissed → the badge goes, the version stays known")
	testing.eq(nothing_found, {"badge": "", "known": ""}, "nothing found → neither")
	testing.eq(not_newer, {"badge": "", "known": ""}, "the installed version → not newer, so neither")
	testing.eq(toggle_off, {"badge": "", "known": ""}, "the toggle off → neither")
	print("")


# What a new runner makes of a state file holding `latest` and `dismissed`.
static func _read(path: String, latest: String, dismissed: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"last_check": int(Time.get_unix_time_from_system()),
			"latest_version": latest, "store_listed": false, "dismissed_version": dismissed}))
	file.close()
	var runner := UpdateCheckRunner.new()
	var read := {"badge": runner.badge_version(), "known": runner.latest_known_version()}
	runner.free()
	return read
