@tool
extends RefCounted
## Moves the toolkit's own server pin in .mcp.json after a self-update, and undoes it.
##
## When an editor start finds that an update installed, [method follow_update] moves the
## entry to the version the running toolkit recommends, if the pin policy says the pin is
## the toolkit's to move (see [code]ServerPinPolicy.pin_move_target[/code]). The move
## needs no confirmation: the user started the update, and the update notice says what
## changed and offers [method undo] while the file's text is what the move wrote. A write
## that fails reports it, records nothing and does not count as a move; the notice says
## why.[br]
## [br]
## One instance lives for one editor start and holds that start's outcome. Built by the
## composer, which connects it to the installer's settle before the installer runs it.
## Editor-only: it reads editor settings and project metadata.

const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")
const MCPJsonWriteFlow := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_write_flow.gd")
const ServerPinPolicy := preload("res://addons/godot_mcp_toolkit/ui/mcp_json/server_pin_policy.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")
const UpdateSettler := preload("res://addons/godot_mcp_toolkit/self_update/update_settler.gd")

## [method outcome] states: nothing moved and nothing failed.
const NONE := ""
## The entry now runs [code]to_spec[/code].
const MOVED := "moved"
## The move's write failed, or the file is malformed; [code]error[/code] says why
## and nothing was recorded as written.
const WRITE_FAILED := "write_failed"
## The user undid the move.
const UNDONE := "undone"

const _UNDONE_TEXT := "MCP: .mcp.json runs server %s again."
const _UNDO_REFUSED_TEXT := "MCP: .mcp.json changed since the update, so it was left as it is."
const _PREVIEW_TEXT := "This also changes the MCP server in .mcp.json from %s to %s. Restart your AI client after the update."

# The Undo marker's key in editor project metadata, machine-local like the last-write
# record and in its section.
const _MARKER_KEY := "pin_move_undone_for"

var _state: String = NONE
var _from_spec: String = ""
var _to_spec: String = ""
var _error: String = ""
# The toolkit version the move belongs to, which an Undo marks.
var _update_version: String = ""
# The file's text right after the move, which an Undo needs unchanged.
var _moved_text: String = ""


## Moves the pin after the start's settle. [param settled] is what
## [code]UpdateSettler.settle[/code] returned; only an
## [code]UpdateSettler.UPDATED[/code] report can move the pin, and not one whose move
## the user already undid on this machine. A malformed file hides its pin,
## so when nothing but the entry would keep the pin it is a failed write: nothing is
## written and the user is asked to fix the file.
func follow_update(settled: Dictionary) -> void:
	if str(settled.get("report", "")) != UpdateSettler.UPDATED:
		return
	var update_version := str(settled.get("to", ""))
	if read_undone_for() == update_version:
		return
	var old_recommended := str(settled.get("compatible_server", ""))
	var new_recommended := VersionUtils.COMPATIBLE_SERVER_VERSION
	var version_setting := ServerPinPolicy.read_version_setting()
	var dev_path := local_server_path()
	var on_disk := MCPJsonSync.get_server_spec()
	if MCPJsonSync.is_malformed():
		if ServerPinPolicy.allows_pin_move(old_recommended, new_recommended, version_setting, dev_path):
			_hold_outcome(update_version, on_disk, ServerPinPolicy.SPEC_NPX_PREFIX + new_recommended,
					{"ok": false, "message": MCPJsonSync.MALFORMED_MESSAGE})
		return
	var target := ServerPinPolicy.pin_move_target(on_disk, read_last_written(),
			old_recommended, new_recommended, version_setting, dev_path)
	if target.is_empty():
		return
	_hold_outcome(update_version, on_disk, target, _write(_package_spec(target)))


## This start's outcome: [code]{state, from_spec, to_spec, from_version, to_version,
## error}[/code]. [code]state[/code] is one of [constant NONE], [constant MOVED],
## [constant WRITE_FAILED] and [constant UNDONE]; the specs are classifications (see
## [code]ServerPinPolicy.classify_server_entry[/code]) and the versions their version
## parts; [code]error[/code] is set for [constant WRITE_FAILED].
func outcome() -> Dictionary:
	return {
		"state": _state,
		"from_spec": _from_spec,
		"to_spec": _to_spec,
		"from_version": _version_of(_from_spec),
		"to_version": _version_of(_to_spec),
		"error": _error,
	}


## True while the pin is moved and the file's text is still what the move wrote, so an
## Undo, which rebuilds the entry, loses no later edit.
func can_undo() -> bool:
	return _state == MOVED and MCPJsonSync.read_text() == _moved_text


## True while the pin is moved and the file's entry still runs the server the move wrote,
## whatever else changed in the file.
func runs_moved_server() -> bool:
	return _state == MOVED and MCPJsonSync.get_server_spec() == _to_spec


## True while the move's write failed and writing the entry is still the fix: the entry
## is still the one the move found, or, when the file was malformed then, the entry does
## not run the target yet, so fixing the file keeps the retry its message promises.
func can_retry() -> bool:
	if _state != WRITE_FAILED:
		return false
	var on_disk := MCPJsonSync.get_server_spec()
	if _from_spec == ServerPinPolicy.SPEC_UNKNOWN:
		return on_disk != _to_spec
	return on_disk == _from_spec


## Writes the entry's server back to the one the move replaced, when [method can_undo].
## [param on_result] receives one (ok, message, severity, tooltip) report, like the
## write flow's; severity is the editor-toast scale (0 info / 1 warning / 2 error). A
## file changed since the move is left alone and reported as a warning. With no move to
## undo, nothing is written and nothing is reported.
func undo(on_result: Callable) -> void:
	if _state != MOVED:
		return
	if not can_undo():
		on_result.call(false, _UNDO_REFUSED_TEXT, 1, "")
		return
	var from_version := _version_of(_from_spec)
	var report := _write(_package_spec(_from_spec))
	if not bool(report["ok"]):
		on_result.call(false, str(report["message"]), int(report["severity"]), str(report["tooltip"]))
		return
	record_undone_for(_update_version)
	_state = UNDONE
	on_result.call(true, _UNDONE_TEXT % from_version, 0, str(report["tooltip"]))


## The versions a click on Update would move the pin between, as
## [code]{from, to}[/code], or an empty dictionary when it would stay.
## [param new_recommended] is the server version the offered release recommends.
func preview(new_recommended: String) -> Dictionary:
	var on_disk := MCPJsonSync.get_server_spec()
	var target := ServerPinPolicy.pin_move_target(on_disk, read_last_written(),
			VersionUtils.COMPATIBLE_SERVER_VERSION, new_recommended,
			ServerPinPolicy.read_version_setting(), local_server_path())
	if target.is_empty():
		return {}
	return {"from": _version_of(on_disk), "to": new_recommended}


## The sentence telling the user what a click on Update would do to the pin, for
## [param pin_preview], what [method preview] returned; an empty string when it is empty.
static func preview_line(pin_preview: Dictionary) -> String:
	if pin_preview.is_empty():
		return ""
	return _PREVIEW_TEXT % [str(pin_preview.get("from", "")), str(pin_preview.get("to", ""))]


## The server spec this machine last wrote into the project's .mcp.json, or "".
func read_last_written() -> String:
	return MCPJsonWriteFlow.read_last_written_spec()


## Records [param spec] as the server spec this machine last wrote.
func record_written(spec: String) -> void:
	MCPJsonWriteFlow.record_written_spec(spec)


## The local server path a write on this machine would use, or "" for the npm package.
func local_server_path() -> String:
	return MCPJsonSync.resolve_machine_dev_path(MCPJsonWriteFlow.read_local_path_setting())


## The toolkit version whose pin move the user undid on this machine, or "".
func read_undone_for() -> String:
	return str(EditorInterface.get_editor_settings().get_project_metadata(MCPJsonWriteFlow.METADATA_SECTION, _MARKER_KEY, ""))


## Marks the pin move of toolkit [param version] as undone on this machine, so a
## second report of the same update does not move the pin again.
func record_undone_for(version: String) -> void:
	EditorInterface.get_editor_settings().set_project_metadata(MCPJsonWriteFlow.METADATA_SECTION, _MARKER_KEY, version)


# Holds the move of update `update_version` from `from_spec` to `to_spec`, with the
# write's {ok, message} `report`.
func _hold_outcome(update_version: String, from_spec: String, to_spec: String, report: Dictionary) -> void:
	_update_version = update_version
	_from_spec = from_spec
	_to_spec = to_spec
	if bool(report["ok"]):
		_state = MOVED
		_moved_text = MCPJsonSync.read_text()
		return
	_state = WRITE_FAILED
	_error = str(report["message"])


# Writes the toolkit's entry at `package_spec`, recording the written spec.
# Returns the write's report as {ok, message, severity, tooltip}; the write is synchronous.
func _write(package_spec: String) -> Dictionary:
	var report := {"ok": false, "message": "", "severity": 2, "tooltip": ""}
	# The lambda captures only the local report: a member named inside a lambda looks up
	# on a Nil self on Godot 4.2.
	var sink := func(ok: bool, message: String, severity: int, tooltip: String) -> void:
		report["ok"] = ok
		report["message"] = message
		report["severity"] = severity
		report["tooltip"] = tooltip
	MCPJsonSync.write_from_template(true, sink, "", record_written, package_spec)
	return report


# The npm package spec for an npx classification such as "npx:1.2.0".
static func _package_spec(spec: String) -> String:
	return ServerPinPolicy.RELEASE_PACKAGE + "@" + _version_of(spec)


static func _version_of(spec: String) -> String:
	if not spec.begins_with(ServerPinPolicy.SPEC_NPX_PREFIX):
		return ""
	return spec.substr(ServerPinPolicy.SPEC_NPX_PREFIX.length())
