@tool
extends RefCounted
## Monitors application/config/name changes that shift the user:// base path.
##
## Godot derives the user:// directory from config/name. When a tool or the
## user renames the project at runtime, every user:// path silently resolves
## to a new OS directory. Files written before the rename (sidecar, auth
## token, audit log, onboarding flags) become orphaned under the old path.
##
## This monitor listens to ProjectSettings.settings_changed (available 4.2+),
## detects config/name changes, ensures the addon directories exist at the
## new user:// path, then emits project_name_changed so that all consumers
## can react knowing the directory structure is already in place.
##
## Usage:
##   var monitor := UserPathMonitor.new()
##   monitor.start()
##   monitor.project_name_changed.connect(_on_project_name_changed)

const ProjectPaths := preload("res://addons/godot_mcp_toolkit/project_paths.gd")

signal project_name_changed(old_name: String, new_name: String)

var _cached_name: String = ""


## Begin monitoring. Call once after plugin initialization.
func start() -> void:
	_cached_name = ProjectSettings.get_setting("application/config/name", "")
	if not ProjectSettings.settings_changed.is_connected(_on_settings_changed):
		ProjectSettings.settings_changed.connect(_on_settings_changed)


## Stop monitoring. Call from _exit_tree() cleanup.
func stop() -> void:
	if ProjectSettings.settings_changed.is_connected(_on_settings_changed):
		ProjectSettings.settings_changed.disconnect(_on_settings_changed)


func _on_settings_changed() -> void:
	var current := ProjectSettings.get_setting("application/config/name", "")
	if current != _cached_name:
		var old := _cached_name
		_cached_name = current
		push_warning("[MCP] Project renamed '%s' -> '%s' — user:// path shifted. Re-creating addon state." % [old, current])
		# Ensure addon dirs exist at the new user:// path before notifying
		# consumers — they can write immediately without calling ensure_dirs().
		ProjectPaths.ensure_dirs()
		project_name_changed.emit(old, current)
