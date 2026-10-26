@tool
extends EditorExportPlugin
## Tells the debug-session tracker when an export is a one-click deploy with remote
## debug, so the deployed game's session does not count as a local playtest.
##
## A deploy exports the project with the debug flags of its run, after the editor's
## build step and before the deployed game attaches to the debugger. A playtest exports
## nothing, and a manual export passes no flags. This is its own export plugin rather
## than part of the export-strip plugin, which removes runtime files from an export.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const DebugSessionTracker = Modules.DebugSessionTracker

# EditorExportPlatform.DEBUG_FLAG_REMOTE_DEBUG. Hard-coded as its value (2 on every
# version 4.2–4.7, verified in engine source) because the DebugFlags enum is
# GDScript-bound only on 4.4+, and a static reference would parse-error on 4.2/4.3.
const _DEBUG_FLAG_REMOTE_DEBUG := 2

var _session_tracker: DebugSessionTracker = null


## Whether an export whose debug flags are [param flags] is a one-click deploy with
## remote debug. [param flags] is the [code]EditorExportPlatform.DebugFlags[/code]
## bitfield the engine passes to [code]_export_begin[/code].
static func is_remote_debug_deploy(flags: int) -> bool:
	return (flags & _DEBUG_FLAG_REMOTE_DEBUG) != 0


## [param session_tracker] is the debug-session tracker a deploy is reported to.
func _init(session_tracker: DebugSessionTracker) -> void:
	_session_tracker = session_tracker


func _get_name() -> String:
	return "MCPRemoteDeployDetector"


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, flags: int) -> void:
	if is_remote_debug_deploy(flags):
		_session_tracker.note_remote_debug_deploy()
