@tool
extends RefCounted
## Monitors the ProjectSettings that shift the user:// base path.
##
## Godot derives the user:// directory from THREE settings — config/name,
## use_custom_user_dir, and custom_user_dir_name (OS::get_user_data_dir reads
## all three live on every call). Renaming the project, toggling the custom
## user dir, or changing its name at runtime makes every user:// path silently
## resolve to a new OS directory. Files written before the shift (sidecar, auth
## token, audit log, onboarding flags) become orphaned under the old path.
##
## This monitor listens to ProjectSettings.settings_changed (available 4.2+),
## detects a change to any of the three user://-deriving settings, ensures the
## addon directories exist at the new user:// path, then emits user_path_changed
## so that all consumers can react knowing the directory structure is already in
## place. The signal carries no payload: the shift can come from any of the
## three settings (a custom-dir toggle leaves the name unchanged), so a "user
## path changed, re-resolve" notification is the only meaningful contract.
##
## Usage:
##   var monitor := UserPathMonitor.new()
##   monitor.start()
##   monitor.user_path_changed.connect(_on_user_path_changed)

const ProjectPaths := preload("res://addons/godot_mcp_toolkit/paths/project_paths.gd")

signal user_path_changed

var _cached_name: String = ""
var _cached_use_custom_dir: bool = false
var _cached_custom_dir_name: String = ""


## Begin monitoring. Call once after plugin initialization.
func start() -> void:
	_cache_settings()
	if not ProjectSettings.settings_changed.is_connected(_on_settings_changed):
		ProjectSettings.settings_changed.connect(_on_settings_changed)


## Stop monitoring. Call from _exit_tree() cleanup.
func stop() -> void:
	if ProjectSettings.settings_changed.is_connected(_on_settings_changed):
		ProjectSettings.settings_changed.disconnect(_on_settings_changed)


func _on_settings_changed() -> void:
	var name := ProjectSettings.get_setting("application/config/name", "")
	var use_custom := bool(ProjectSettings.get_setting("application/config/use_custom_user_dir", false))
	var custom_name := ProjectSettings.get_setting("application/config/custom_user_dir_name", "")
	if name == _cached_name and use_custom == _cached_use_custom_dir and custom_name == _cached_custom_dir_name:
		return
	_cached_name = name
	_cached_use_custom_dir = use_custom
	_cached_custom_dir_name = custom_name
	push_warning("[MCP] user:// path-deriving setting changed - user:// path shifted. Re-creating addon state.")
	# Ensure addon dirs exist at the new user:// path before notifying
	# consumers — they can write immediately without calling ensure_dirs().
	ProjectPaths.ensure_dirs()
	user_path_changed.emit()


func _cache_settings() -> void:
	_cached_name = ProjectSettings.get_setting("application/config/name", "")
	_cached_use_custom_dir = bool(ProjectSettings.get_setting("application/config/use_custom_user_dir", false))
	_cached_custom_dir_name = ProjectSettings.get_setting("application/config/custom_user_dir_name", "")
