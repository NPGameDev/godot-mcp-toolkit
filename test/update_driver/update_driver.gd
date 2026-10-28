@tool
extends EditorPlugin
## Test-only editor plugin for scripts/test_framework/update_flow.sh, copied into the
## flow's scratch projects. It waits until the toolkit's pending update record reaches
## the state UPDATE_DRIVER_WAIT_FOR names, then quits the editor so the toolkit's exit
## applies the update; with UPDATE_DRIVER_DISABLE=1 it disables the toolkit first. It
## gives up after UPDATE_DRIVER_TIMEOUT seconds (60 by default). Without
## UPDATE_DRIVER_WAIT_FOR it does nothing.

const _RECORD := "user://addons/godot_mcp_toolkit/update/pending_update.json"

var _wait_for: String = ""
var _deadline_msec: int = 0
var _done: bool = false


func _enter_tree() -> void:
	_wait_for = OS.get_environment("UPDATE_DRIVER_WAIT_FOR")
	var timeout := OS.get_environment("UPDATE_DRIVER_TIMEOUT")
	_deadline_msec = Time.get_ticks_msec() + int(float(timeout) * 1000.0 if timeout.is_valid_float() else 60000.0)


func _process(_delta: float) -> void:
	if _wait_for.is_empty() or _done:
		return
	var state := _record_state()
	if state == _wait_for:
		_done = true
		print("[UPDATE-DRIVER] reached %s" % state)
		if OS.get_environment("UPDATE_DRIVER_DISABLE") == "1":
			EditorInterface.set_plugin_enabled("godot_mcp_toolkit", false)
			print("[UPDATE-DRIVER] disabled the toolkit")
		get_tree().quit()
	elif Time.get_ticks_msec() > _deadline_msec:
		_done = true
		print("[UPDATE-DRIVER] timeout waiting for %s (state: '%s')" % [_wait_for, state])
		get_tree().quit()


static func _record_state() -> String:
	if not FileAccess.file_exists(_RECORD):
		return ""
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_RECORD))
	if parsed is Dictionary:
		return str((parsed as Dictionary).get("state", ""))
	return ""
