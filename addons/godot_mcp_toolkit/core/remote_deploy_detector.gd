@tool
extends EditorExportPlugin
## Tells the debugger log reader when a run is a one-click deploy with remote debug.
##
## A deploy exports the project with the debug flags of its run, after the editor
## has called every plugin's [code]_build()[/code] and before the deployed game
## connects to the debugger. A playtest exports nothing, and a manual export passes
## no flags, so an export with the remote-debug flag marks the run as a deploy.

const PlaytestLogReader := preload("res://addons/godot_mcp_toolkit/commands/playtest_log_reader.gd")

# EditorExportPlatform.DEBUG_FLAG_REMOTE_DEBUG. Hard-coded as its value (2 on every
# version 4.2–4.7, verified in engine source) because the DebugFlags enum is
# GDScript-bound only on 4.4+, and a static reference would parse-error on 4.2/4.3.
const _DEBUG_FLAG_REMOTE_DEBUG := 2


## Whether an export whose debug flags are [param flags] is a one-click deploy with
## remote debug. [param flags] is the [code]EditorExportPlatform.DebugFlags[/code]
## bitfield the engine passes to [code]_export_begin[/code].
static func is_remote_debug_deploy(flags: int) -> bool:
	return (flags & _DEBUG_FLAG_REMOTE_DEBUG) != 0


func _get_name() -> String:
	return "MCPRemoteDeployDetector"


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, flags: int) -> void:
	if is_remote_debug_deploy(flags):
		PlaytestLogReader.note_remote_debug_deploy()
