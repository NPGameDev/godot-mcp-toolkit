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
const EditorAccess := preload("res://addons/godot_mcp_toolkit/editor_access.gd")
