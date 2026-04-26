@tool
extends RefCounted
## Centralized preloads for plugin-internal scripts.
##
## Every file that needs MCPError, MCPCoerce, or MCPCommandRegistry preloads
## this hub and re-aliases the constants it needs. Script paths live here only
## — if a file moves, update this file and nothing else.

const MCPError := preload("res://addons/godot_mcp_toolkit/mcp_error.gd")
const MCPCoerce := preload("res://addons/godot_mcp_toolkit/_coerce.gd")
const MCPCommandRegistry := preload("res://addons/godot_mcp_toolkit/command_registry.gd")
const MCPFileGuard := preload("res://addons/godot_mcp_toolkit/file_guard.gd")
const MCPUntrusted := preload("res://addons/godot_mcp_toolkit/untrusted.gd")
const MCPFeatureRegistry := preload("res://addons/godot_mcp_toolkit/feature_registry.gd")
const MCPFeatureGate := preload("res://addons/godot_mcp_toolkit/feature_gate.gd")
const MCPScrubber := preload("res://addons/godot_mcp_toolkit/scrubber.gd")
const MCPAudit := preload("res://addons/godot_mcp_toolkit/audit.gd")
const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")
const MCPRegistryClient := preload("res://addons/godot_mcp_toolkit/registry_client.gd")
const MCPStateFile := preload("res://addons/godot_mcp_toolkit/mcp_state_file.gd")
const LogBuffer := preload("res://addons/godot_mcp_toolkit/log_buffer.gd")


# -- Version helpers (Godot 4.x cross-version compat) -----------------------

## Latest minor version tested. Versions above this still run but log a notice.
const GODOT_TESTED_MAX_MINOR := 6

static func godot_minor() -> int:
	return Engine.get_version_info().get("minor", 0)


## True when running under `godot --headless` (no display server).
## Use to gate tools that require a viewport or running game.
static func is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


## Safely get EditorUndoRedoManager via dynamic dispatch.
## Returns null on Godot < 4.4 (where the method doesn't exist).
## Callers must handle null by skipping undo registration.
static func get_undo_redo():
	if EditorInterface.has_method("get_editor_undo_redo"):
		return EditorInterface.call("get_editor_undo_redo")
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
