@tool
extends RefCounted
## Decides whether a staged update restarts the editor at once or waits in the dock's
## ready view, and runs the restart.
##
## Godot 4.4 and later ask about unsaved scenes when the editor restarts; 4.2 and 4.3 do
## not, and no version asks about every unsaved file. So when staging ends, the editor
## restarts on its own only on 4.4 or later, and only when the probe finds nothing a
## restart would lose: no script with unsaved edits, no running game and no scene that
## was never saved. Anything else opens the ready view, where Restart checks again and
## refuses while a script is unsaved. A staged update found at an editor start opens the
## ready view and never restarts.[br]
## [br]
## Every restart first waits for the editor's file scan to end: on Windows the swap's
## first rename has failed under a running scan. A scan that outlasts the wait opens the
## ready view instead.

## Emitted when [method view] changes.
signal view_changed

# Direct preload: core/modules.gd does not list this folder's scripts.
const EditorRestartProbe := preload("res://addons/godot_mcp_toolkit/self_update/editor_restart_probe.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")

## [method view_for] results: restart the editor now, or show the ready view.
const RESTART := "restart"
const READY_VIEW := "ready_view"

## The first Godot whose restart asks about unsaved scenes.
const SCENES_ASKED_FROM := "4.4"

## [method view] key beside the probe's findings: whether this editor's restart asks
## about unsaved scenes.
const SCENES_ASKED := "scenes_asked"

const _SCAN_WAIT_MSEC := 60000

var _probe: EditorRestartProbe = null
var _scan_wait_msec: int = _SCAN_WAIT_MSEC
var _view := {}
# Bumped by every cancel, so a restart still waiting for a scan knows it was called off.
var _generation: int = 0
var _waiting_for_scan: bool = false


## [param probe] answers for the editor. [param scan_wait_msec] caps the wait for a
## running scan.
func _init(probe: EditorRestartProbe, scan_wait_msec: int = _SCAN_WAIT_MSEC) -> void:
	_probe = probe
	_scan_wait_msec = scan_wait_msec


## Which of [constant RESTART] or [constant READY_VIEW] staging that just ended leads to,
## from the probe's [param found] and the [param engine_version] ([code]major.minor[/code]).
static func view_for(found: Dictionary, engine_version: String) -> String:
	if not asks_about_scenes(engine_version):
		return READY_VIEW
	var unsaved: PackedStringArray = found.get(EditorRestartProbe.UNSAVED_SCRIPTS, PackedStringArray())
	if not unsaved.is_empty() or bool(found.get(EditorRestartProbe.RUNNING_GAME, false)):
		return READY_VIEW
	return RESTART if int(found.get(EditorRestartProbe.UNTITLED_SCENES, 0)) == 0 else READY_VIEW


## Whether Restart refuses with what the probe [param found]: a script has unsaved edits.
## The user was told about the running game and the scenes, so those do not stop it.
static func refuses(found: Dictionary) -> bool:
	var unsaved: PackedStringArray = found.get(EditorRestartProbe.UNSAVED_SCRIPTS, PackedStringArray())
	return not unsaved.is_empty()


## Whether the restart of Godot [param engine_version] asks about unsaved scenes.
static func asks_about_scenes(engine_version: String) -> bool:
	return VersionUtils.is_at_least(engine_version, SCENES_ASKED_FROM)


## The ready view while it is open: the probe's last findings plus [constant SCENES_ASKED],
## or an empty dictionary.
func view() -> Dictionary:
	return _view


## Opens the ready view with what the editor holds now, and never restarts. For a staged
## update found at an editor start.
func show_view() -> void:
	_open(_probe.findings())


## Closes the ready view; the update still installs when the editor closes.
func close_view() -> void:
	if _view.is_empty():
		return
	_view = {}
	view_changed.emit()


## Calls off a restart waiting for a scan and closes the ready view.
func cancel() -> void:
	_generation += 1
	_waiting_for_scan = false
	close_view()


## Restarts the editor or opens the ready view, once staging has ended in this session.
func after_staging() -> void:
	if _waiting_for_scan or not await _scan_ended():
		return
	var found := _probe.findings()
	if _probe.can_restart() and view_for(found, _probe.engine_version()) == RESTART:
		_probe.restart()
		return
	_open(found)


## Restart's click: checks again, and restarts unless a script has unsaved edits, in which
## case the ready view shows what was found. A click while a scan is awaited does nothing,
## since the pending wait already ends in a restart or the ready view.
func restart() -> void:
	if _waiting_for_scan:
		return
	var found := _probe.findings()
	if refuses(found) or not _probe.can_restart():
		_open(found)
		return
	if not await _scan_ended():
		return
	# Edits made while the scan ran count too.
	found = _probe.findings()
	if refuses(found):
		_open(found)
		return
	_probe.restart()


func _open(found: Dictionary) -> void:
	var opened := found.duplicate()
	opened[SCENES_ASKED] = asks_about_scenes(_probe.engine_version())
	_view = opened
	view_changed.emit()


# Waits a frame at a time while the probe reports a scan. Returns whether the caller goes
# on: false when a cancel came, or when the scan outlasted the wait, which opens the view.
func _scan_ended() -> bool:
	if not _probe.is_scanning():
		return true
	var generation := _generation
	var deadline := Time.get_ticks_msec() + _scan_wait_msec
	_waiting_for_scan = true
	var tree := Engine.get_main_loop() as SceneTree
	while _probe.is_scanning() and Time.get_ticks_msec() < deadline:
		await tree.process_frame
		if generation != _generation:
			return false
	_waiting_for_scan = false
	if _probe.is_scanning():
		_open(_probe.findings())
		return false
	return true
