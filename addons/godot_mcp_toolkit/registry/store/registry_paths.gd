@tool
extends RefCounted
## On-disk layout authority for the multi-instance registry.
##
## Resolves the machine-wide registry directory (per-OS: %APPDATA% on Windows,
## ~/Library/Application Support on macOS, $XDG_DATA_HOME on Linux/BSD) and every
## canonical file path within it — the aggregated projects.json, this instance's
## editor/runtime entry files, and the registry lock file. The per-instance entry
## filenames are keyed by ProjectKey.current_hash() — one canonicalization recipe,
## so the entry file and the user:// instance dir share an identity.
##
## All methods are static — no instance state. Editor-clean: this file is in the
## runtime autoload's preload closure (via registry_client.gd), so it names no
## editor-only class (godot#91713).

# Direct preload (NOT via core/modules.gd): this file is in the runtime autoload's
# preload closure (registry_client.gd → mcp_runtime_server.gd), so it must stay
# editor-clean — core/modules.gd names EditorInterface and would taint the autoload in
# exports (godot#91713).
const _ProjectKey := preload("res://addons/godot_mcp_toolkit/paths/project_key.gd")

const _REGISTRY_FILENAME := "projects.json"
const _ENTRIES_DIR := "entries"


# -- Registry directory + projects.json ---------------------------------------


## The machine-wide registry directory, created on first miss. Side-effecting by
## design (a path query that ensures the dir): callers rely on it existing.
static func registry_dir() -> String:
	var dir: String
	match OS.get_name():
		"Windows":
			var appdata := OS.get_environment("APPDATA")
			if appdata.is_empty():
				appdata = OS.get_environment("USERPROFILE").path_join("AppData/Roaming")
			dir = appdata.path_join("godot-mcp-toolkit")
		"macOS":
			dir = OS.get_environment("HOME").path_join(
				"Library/Application Support/godot-mcp-toolkit")
		_:  # Linux / BSD
			var data_home := OS.get_environment("XDG_DATA_HOME")
			if data_home.is_empty():
				data_home = OS.get_environment("HOME").path_join(".local/share")
			dir = data_home.path_join("godot-mcp-toolkit")
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	return dir


static func registry_path() -> String:
	return registry_dir().path_join(_REGISTRY_FILENAME)


# -- Per-instance entry files --------------------------------------------------


## The entries/ subdir, created on first miss (same CQS-exception as registry_dir).
static func entry_dir() -> String:
	var d := registry_dir().path_join(_ENTRIES_DIR)
	if not DirAccess.dir_exists_absolute(d):
		DirAccess.make_dir_recursive_absolute(d)
	return d


## This editor instance's entry file: entries/<hash>.json.
static func entry_file_path() -> String:
	return entry_dir().path_join(_ProjectKey.current_hash() + ".json")


## The runtime child's own entry file: entries/<hash>.runtime.json. The running
## game writes here; the editor writes <hash>.json — two distinct files, one
## writer each, so editor and runtime never read-modify-write the same file.
static func runtime_entry_file_path() -> String:
	return entry_dir().path_join(_ProjectKey.current_hash() + ".runtime.json")


# -- Lock file -----------------------------------------------------------------


## The registry lock file: projects.json + ".lock". Serialises machine-wide
## read-modify-writes (the registry's own rebuilds and the sibling unfocused-sleep
## backup) across concurrent editor instances.
static func lock_path() -> String:
	return registry_path() + ".lock"
