@tool
extends RefCounted
## Centralized preloads for plugin-internal scripts.
##
## Centralized preloads for plugin-internal scripts.
## Script paths live here only — if a file moves, update this file and nothing else.
## MCPToolkitError has class_name and needs no preload.

const Coerce := preload("res://addons/godot_mcp_toolkit/_coerce.gd")
const FileGuard := preload("res://addons/godot_mcp_toolkit/file_guard.gd")
const Untrusted := preload("res://addons/godot_mcp_toolkit/untrusted.gd")
const Scrubber := preload("res://addons/godot_mcp_toolkit/scrubber.gd")
const Audit := preload("res://addons/godot_mcp_toolkit/audit.gd")
const McpJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")
const RegistryClient := preload("res://addons/godot_mcp_toolkit/registry_client.gd")
const ProjectPaths := preload("res://addons/godot_mcp_toolkit/project_paths.gd")
const UserPathMonitor := preload("res://addons/godot_mcp_toolkit/user_path_monitor.gd")
const LogBuffer := preload("res://addons/godot_mcp_toolkit/log_buffer.gd")
const Helpers := preload("res://addons/godot_mcp_toolkit/commands/editor_helpers.gd")
const LogHelpers := preload("res://addons/godot_mcp_toolkit/log_helpers.gd")
const NodejsCheck := preload("res://addons/godot_mcp_toolkit/nodejs_check.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/mcp_version_utils.gd")
const StaleInstanceHint := preload("res://addons/godot_mcp_toolkit/stale_instance_hint.gd")


# -- Plugin reference (set by plugin.gd _enter_tree / _exit_tree) -----------

## Stores the EditorPlugin instance so that EditorUndoRedoManager is accessible
## on ALL Godot 4.x versions via plugin.get_undo_redo() — not just 4.4+ where
## EditorInterface.get_editor_undo_redo() was added.
static var _plugin: EditorPlugin


# -- Version helpers (Godot 4.x cross-version compat) -----------------------

## Latest version tested. Versions above this still run but log a notice.
const GODOT_TESTED_MAX_VERSION := "4.6"


## True when running under `godot --headless` (no display server).
## Use to gate tools that require a viewport or running game.
static func is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


## Get EditorUndoRedoManager via the stored plugin reference.
## Returns the singleton on ALL Godot 4.x versions in editor context.
## Returns null only in headless mode (no plugin loaded).
static func get_undo_redo():
	if _plugin != null:
		return _plugin.get_undo_redo()
	return null


## Safely get EditorToaster via dynamic dispatch.
## Returns null on Godot < 4.4 (where the method doesn't exist).
static func get_toaster():
	if EditorInterface.has_method("get_editor_toaster"):
		return EditorInterface.call("get_editor_toaster")
	return null


## Safely get the editor Theme via dynamic dispatch.
## Returns null if unavailable (pre-4.6 or not yet exposed).
## Fallback: EditorInterface.get_base_control().get_theme().
static func get_editor_theme() -> Theme:
	if EditorInterface.has_method("get_editor_theme"):
		return EditorInterface.call("get_editor_theme")
	var base := EditorInterface.get_base_control()
	if base != null:
		return base.get_theme()
	return null
