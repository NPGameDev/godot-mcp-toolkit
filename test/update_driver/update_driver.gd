@tool
extends EditorPlugin
## Test-only editor plugin for scripts/test_framework/update_flow.sh, copied into the
## flow's scratch projects. It waits until the toolkit's update journal reaches
## the state UPDATE_DRIVER_WAIT_FOR names, then closes the editor so the toolkit's exit
## applies the update; with UPDATE_DRIVER_DISABLE=1 it disables the toolkit first. It
## gives up after UPDATE_DRIVER_TIMEOUT seconds (60 by default), printing the installer's
## state and note. Without UPDATE_DRIVER_WAIT_FOR it does nothing.[br]
## [br]
## UPDATE_DRIVER_CLICK=1 clicks Update for the user: once the installer offers a version, it
## asks for the install. UPDATE_DRIVER_CLOSE=window closes the editor the way its window's
## close button does; by default it quits the scene tree.

const _RECORD := "res://addons/.godot_mcp_toolkit_update/journal.json"
const _TOOLKIT_PLUGIN := "res://addons/godot_mcp_toolkit/plugin.gd"
# The installer's state while it offers a version (UpdateInstaller.AVAILABLE).
const _OFFERED := "available"

var _wait_for: String = ""
var _deadline_msec: int = 0
var _done: bool = false
var _click: bool = false
var _clicked: bool = false
var _close_by_window: bool = false


func _enter_tree() -> void:
	_wait_for = OS.get_environment("UPDATE_DRIVER_WAIT_FOR")
	var timeout := OS.get_environment("UPDATE_DRIVER_TIMEOUT")
	_deadline_msec = Time.get_ticks_msec() + int(float(timeout) * 1000.0 if timeout.is_valid_float() else 60000.0)
	_click = OS.get_environment("UPDATE_DRIVER_CLICK") == "1"
	_close_by_window = OS.get_environment("UPDATE_DRIVER_CLOSE") == "window"


func _process(_delta: float) -> void:
	if _wait_for.is_empty() or _done:
		return
	if _click and not _clicked:
		_click_update()
	var state := _record_state()
	if state == _wait_for:
		_done = true
		print("[UPDATE-DRIVER] reached %s" % state)
		if OS.get_environment("UPDATE_DRIVER_DISABLE") == "1":
			EditorInterface.set_plugin_enabled("godot_mcp_toolkit", false)
			print("[UPDATE-DRIVER] disabled the toolkit")
		_close()
	elif Time.get_ticks_msec() > _deadline_msec:
		_done = true
		print("[UPDATE-DRIVER] timeout waiting for %s (state: '%s')" % [_wait_for, state])
		var installer := _installer()
		if installer != null:
			print("[UPDATE-DRIVER] installer state: '%s', note: '%s'" % [installer.call("state"), installer.call("note_text")])
		_close()


func _click_update() -> void:
	var installer := _installer()
	if installer == null or str(installer.call("state")) != _OFFERED:
		return
	_clicked = true
	print("[UPDATE-DRIVER] clicked Update for %s" % installer.call("version"))
	installer.call("install")


# A close request sent to the editor node alone and deferred, the way a real one arrives.
func _close() -> void:
	if _close_by_window:
		print("[UPDATE-DRIVER] closing through the window")
		get_parent().call_deferred("notification", NOTIFICATION_WM_CLOSE_REQUEST)
		return
	get_tree().quit()


# The toolkit's installer, reached through the graph its plugin composed, or null before
# the plugin has composed it.
func _installer() -> Object:
	for sibling: Node in get_parent().get_children():
		var script: Script = sibling.get_script()
		if script == null or script.resource_path != _TOOLKIT_PLUGIN:
			continue
		var handle: Variant = sibling.get("_handle")
		if handle is Object:
			var installer: Variant = (handle as Object).call("update_installer")
			return installer as Object
	return null


static func _record_state() -> String:
	if not FileAccess.file_exists(_RECORD):
		return ""
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_RECORD))
	if parsed is Dictionary:
		return str((parsed as Dictionary).get("state", ""))
	return ""
