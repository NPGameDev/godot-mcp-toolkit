@tool
extends EditorPlugin
## One editor session of the apply kill driver: a real editor's start and exit around the
## self-update's classes, with nothing shipped.
##
## run_legs.sh copies this plugin into a scratch project and says what the session does in
## [code]res://.kill_driver/session.txt[/code], one [code]key=value[/code] per line. With
## no such file (the class-cache warm-up) the plugin does nothing.[br]
## [br]
## Each session appends what happened to [code]res://.kill_driver/<id>.txt[/code], closing
## the file after every line so a kill loses nothing, and the driver grades that file and
## the folders on disk.[br]
## [br]
## The toolkit is reached through [method @GDScript.load], never a preload: at one kill
## point its folder is gone, and this plugin still has to start and say so.

enum _Phase { WAIT_FOR_SCAN, STAGE, WAIT_FOR_TOOLKIT, CLOSING }

const _DRIVER_FOLDER := "res://.kill_driver"
# The release's assets as a download leaves them, moved into the update folder only once
# the toolkit has started: its start clears that folder when no journal names a release.
const _RELEASE_FOLDER := _DRIVER_FOLDER + "/release"
const _UPDATE_FOLDER := "res://addons/.godot_mcp_toolkit_update"
const _TOOLKIT_FOLDER := "res://addons/godot_mcp_toolkit"
const _SELF_UPDATE_FOLDER := _TOOLKIT_FOLDER + "/self_update"
const _ICON_PATH := _TOOLKIT_FOLDER + "/icon.svg"
const _RECOVERY_CFG := "res://addons/.godot_mcp_toolkit_recovery/plugin.cfg"
# The title the recovery plugin's dialogs share with the toolkit's update prompt; the legs
# that press Later run with the toolkit unloaded, so only the recovery dialog can match.
const _RECOVERY_DIALOG_TITLE := "Godot MCP Toolkit update"
const _STAGED := "staged"
const _STEPPER_DONE := "done"
const _STEPPER_RUNNING := "running"

# How long the first scan must have been over, and the session must have run, before it
# moves on: a scan can start again right after the first one ends.
const _SCAN_SETTLED_MS := 2000
const _MINIMUM_UP_MS := 3000
# Reaching a state the session waits for, or the close request's effect, gets this long.
const _WAIT_LIMIT_MS := 90000
const _CLOSE_LIMIT_MS := 30000
# Ends a hung session from inside, so the driver's own timeout never leaves an editor behind.
const _WATCHDOG_MS := 240000

var _session: Dictionary = {}
var _public_key := ""
var _phase := _Phase.WAIT_FOR_SCAN
var _started_ms := 0
var _phase_started_ms := 0
var _settled_since_ms := -1
var _stepper: RefCounted = null
var _longest_step_usec := 0
var _scan_called_usec := 0
var _settle_pending := false
var _later_pressed := false
# Held from the start: the swap moves the files these came from.
var _applier: GDScript = null


func _enter_tree() -> void:
	_session = _read_session()
	if _session.is_empty():
		set_process(false)
		return
	_started_ms = Time.get_ticks_msec()
	_public_key = FileAccess.get_file_as_string(_DRIVER_FOLDER.path_join("public_key.pem")).replace("\r", "")
	_note("session_started", "1")
	_note("recovery_enabled", str(EditorInterface.is_plugin_enabled(_RECOVERY_CFG)))
	_note("toolkit_folder_present", str(FileAccess.file_exists(_self_update_script("update_settler.gd"))))
	# Set even with the toolkit's folder gone, where the notes come out empty: a toolkit the
	# recovery plugin puts back starts only at the next session.
	_settle_pending = _flag("settle")
	if not FileAccess.file_exists(_self_update_script("update_settler.gd")):
		return
	if _flag("apply"):
		_applier = load(_self_update_script("update_applier.gd"))


func _process(_delta: float) -> void:
	# NOTIFICATION_READY turns processing back on for a script that defines _process, so
	# the set_process(false) in _enter_tree does not hold.
	if _session.is_empty():
		return
	var now := Time.get_ticks_msec()
	if now - _started_ms > _WATCHDOG_MS:
		_note("watchdog_kill", str(_phase))
		OS.kill(OS.get_process_id())
		return
	# The session moves on only once it holds what the toolkit's start settled.
	if _settle_pending:
		_note_settled_once_over(now)
		return
	match _phase:
		_Phase.WAIT_FOR_SCAN:
			if _scan_has_settled(now):
				_enter_phase(_Phase.STAGE if _flag("stage") else _Phase.WAIT_FOR_TOOLKIT, now)
				if _flag("stage"):
					_begin_stage()
		_Phase.STAGE:
			_advance_stage(now)
		_Phase.WAIT_FOR_TOOLKIT:
			if _toolkit_wait_is_over(now):
				_note_toolkit()
				_close(now)
		_Phase.CLOSING:
			if now - _phase_started_ms > _CLOSE_LIMIT_MS:
				_note("close_fallback", "1")
				_phase_started_ms = now
				get_tree().quit()


func _exit_tree() -> void:
	if _session.is_empty():
		return
	var entered_usec := Time.get_ticks_usec()
	_note("exit_tree_reached", "1")
	# The toolkit's exit comes after this one and would install the stage this session made;
	# the session that makes the legs' template has to leave it staged.
	if _flag("kill_at_exit"):
		_note("killed_at_exit", "1")
		OS.kill(OS.get_process_id())
		return
	if _applier == null:
		return
	if _flag("scan_at_close"):
		_note("exit_tree_after_scan_ms", str((entered_usec - _scan_called_usec) / 1000))
	var started_usec := Time.get_ticks_usec()
	var result: Dictionary = _applier.call("apply_pending", {"public_keys": [_public_key], "on_step": _on_step})
	var apply_usec := Time.get_ticks_usec() - started_usec
	if _flag("scan_at_close"):
		_note("scanning_after_apply", _scan_position())
	_note("apply_ms", str(apply_usec / 1000))
	_note("apply_state", str(result["state"]))
	_note("apply_reason", str(result["reason"]))
	_note("exit_tree_ms", str((Time.get_ticks_usec() - entered_usec) / 1000))


# Reached by every step of the swap. Each line is on disk before the next thing happens, so
# a kill that did not fire leaves a line a graded file cannot hide.
func _on_step(step: String) -> void:
	_note("step", step)
	if _flag("scan_at_close"):
		_note("scanning_at_step", "%s:%s" % [step, _scan_position()])
	if step == str(_session.get("kill_at", "")):
		_note("kill_fired", step)
		OS.kill(OS.get_process_id())
		_note("survived_kill", step)


# What the toolkit's own start settled; a second settle here would read only what the first
# left. Depending on the engine version this plugin starts before or after the toolkit, so
# the read waits for the toolkit's result. Past the wait limit the notes are written empty.
func _note_settled_once_over(now: int) -> void:
	var result: Dictionary = {}
	var installer := _toolkit_installer()
	if installer != null:
		result = installer.call("settled")
	if result.is_empty() and now - _started_ms <= _WAIT_LIMIT_MS:
		return
	_settle_pending = false
	_note("settle_report", str(result.get("report", "")))
	_note("settle_from", str(result.get("from", "")))
	_note("settle_to", str(result.get("to", "")))
	_note("settle_reason", str(result.get("reason", "")))
	_note("settle_restored", str(result.get("restored", false)))


func _scan_has_settled(now: int) -> bool:
	if EditorInterface.get_resource_filesystem().is_scanning():
		_settled_since_ms = -1
		return false
	if _settled_since_ms < 0:
		_settled_since_ms = now
	return now - _settled_since_ms >= _SCAN_SETTLED_MS and now - _started_ms >= _MINIMUM_UP_MS


func _begin_stage() -> void:
	_place_release(str(_session["to"]))
	var stepper_script: GDScript = load(_self_update_script("stage_stepper.gd"))
	_stepper = stepper_script.new()
	var started_usec := Time.get_ticks_usec()
	var outcome: Dictionary = _stepper.call("begin", str(_session["to"]))
	_note("stage_begin_ms", str((Time.get_ticks_usec() - started_usec) / 1000))
	_finish_stage_if_over(outcome, Time.get_ticks_msec())


# A copy the stepper finds incomplete fails the stage, which the driver grades.
func _place_release(version: String) -> void:
	var from := ProjectSettings.globalize_path(_RELEASE_FOLDER)
	var to := ProjectSettings.globalize_path(_UPDATE_FOLDER.path_join(version))
	DirAccess.make_dir_recursive_absolute(to)
	for file_name: String in DirAccess.get_files_at(from):
		DirAccess.copy_absolute(from.path_join(file_name), to.path_join(file_name))


func _advance_stage(now: int) -> void:
	var started_usec := Time.get_ticks_usec()
	var outcome: Dictionary = _stepper.call("advance")
	_longest_step_usec = maxi(_longest_step_usec, Time.get_ticks_usec() - started_usec)
	_finish_stage_if_over(outcome, now)


# Writes the journal the stepper's caller would once the stage is whole, and installs the
# recovery plugin as that caller does; the stepper does neither.
func _finish_stage_if_over(outcome: Dictionary, now: int) -> void:
	var state := str(outcome["state"])
	if state == _STEPPER_RUNNING:
		return
	_note("stage_state", state)
	_note("stage_reason", str(outcome["reason"]))
	_note("stage_written", str(outcome["written"]))
	_note("stage_total", str(outcome["total"]))
	_note("stage_longest_step_ms", str(_longest_step_usec / 1000))
	if state == _STEPPER_DONE:
		var journal_script: GDScript = load(_self_update_script("update_journal.gd"))
		var record := {"state": _STAGED, "from": str(_session["from"]), "to": str(_session["to"]), "backup": ""}
		_note("journal_written", str(journal_script.call("write", record)))
		_install_recovery()
	_enter_phase(_Phase.WAIT_FOR_TOOLKIT, now)


# The installer puts the recovery plugin in place once a stage is whole, and the apply at
# exit postpones without it.
func _install_recovery() -> void:
	var files_script: GDScript = load(_self_update_script("recovery_files.gd"))
	var files: RefCounted = files_script.new()
	var failure := str(files.call("install"))
	_note("recovery_failure", failure)
	_note("recovery_installed", str(failure.is_empty()))


func _toolkit_wait_is_over(now: int) -> bool:
	if now - _phase_started_ms > _WAIT_LIMIT_MS:
		return true
	if _flag("press_later") and not _press_later_once_shown():
		return false
	if _flag("wait_import") and not _icon_is_imported():
		return false
	return not _flag("wait_toolkit") or _toolkit_is_loaded()


# Answers the recovery plugin's dialog as a user who restarts later would: notes its
# text, its line breaks written as \n so the note stays one line, then presses Later.
# Returns whether Later has been pressed.
func _press_later_once_shown() -> bool:
	if _later_pressed:
		return true
	var dialog := _recovery_dialog()
	if dialog == null:
		return false
	_note("recovery_dialog_text", dialog.dialog_text.replace("\n", "\\n"))
	dialog.get_cancel_button().pressed.emit()
	_later_pressed = true
	_note("later_pressed", "1")
	return true


func _recovery_dialog() -> ConfirmationDialog:
	for child: Node in EditorInterface.get_base_control().get_children():
		if not child is ConfirmationDialog:
			continue
		var dialog: ConfirmationDialog = child
		if dialog.visible and dialog.title == _RECOVERY_DIALOG_TITLE:
			return dialog
	return null


func _note_toolkit() -> void:
	_note("toolkit_loaded", str(_toolkit_is_loaded()))
	_note("toolkit_enabled", str(EditorInterface.is_plugin_enabled("godot_mcp_toolkit")))
	var toolkit := _toolkit_plugin()
	if toolkit != null:
		_note("toolkit_version", str(toolkit.call("get_plugin_version")))
	_note("icon_imported", str(_icon_is_imported()))


# The toolkit's plugin past its _enter_tree: it holds the graph it composed there.
func _toolkit_is_loaded() -> bool:
	var toolkit := _toolkit_plugin()
	return toolkit != null and toolkit.get("_handle") != null


func _toolkit_plugin() -> EditorPlugin:
	for sibling: Node in get_parent().get_children():
		var script: Script = sibling.get_script()
		if script != null and script.resource_path == _TOOLKIT_FOLDER.path_join("plugin.gd"):
			return sibling as EditorPlugin
	return null


func _toolkit_installer() -> Object:
	var toolkit := _toolkit_plugin()
	if toolkit == null:
		return null
	var handle: Variant = toolkit.get("_handle")
	if not handle is Object:
		return null
	var installer: Variant = (handle as Object).call("update_installer")
	return installer as Object


func _icon_is_imported() -> bool:
	if not FileAccess.file_exists(_ICON_PATH + ".import"):
		return false
	return load(_ICON_PATH) is Texture2D


# A deferred close request sent to the editor node alone, where the editor acts on it. A
# real one reaches every node in the window.
func _close(now: int) -> void:
	_enter_phase(_Phase.CLOSING, now)
	_note("closing", "1")
	if _flag("scan_at_close"):
		_note("seed_revealed", str(DirAccess.remove_absolute(ProjectSettings.globalize_path(str(_session["reveal_at_close"]))) == OK))
		var filesystem := EditorInterface.get_resource_filesystem()
		_scan_called_usec = Time.get_ticks_usec()
		filesystem.scan()
		_note("scan_called", "1")
		_note("scanning_after_call", str(filesystem.is_scanning()))
	get_parent().call_deferred("notification", NOTIFICATION_WM_CLOSE_REQUEST)


# Whether a scan runs, and how far through its files it says it is.
func _scan_position() -> String:
	var filesystem := EditorInterface.get_resource_filesystem()
	return "%s:%.3f" % [filesystem.is_scanning(), filesystem.get_scanning_progress()]


func _enter_phase(phase: _Phase, now: int) -> void:
	_phase = phase
	_phase_started_ms = now


func _flag(key: String) -> bool:
	return str(_session.get(key, "0")) == "1"


func _self_update_script(file_name: String) -> String:
	return _SELF_UPDATE_FOLDER.path_join(file_name)


func _read_session() -> Dictionary:
	var path := _DRIVER_FOLDER.path_join("session.txt")
	if not FileAccess.file_exists(path):
		return {}
	var session := {}
	for line: String in FileAccess.get_file_as_string(path).split("\n"):
		var separator := line.find("=")
		if separator > 0:
			session[line.left(separator)] = line.substr(separator + 1).strip_edges()
	return session


func _note(key: String, value: String) -> void:
	var path := _DRIVER_FOLDER.path_join("%s.txt" % _session["id"])
	var file := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	file.store_line("%s=%s" % [key, value])
	file.close()
