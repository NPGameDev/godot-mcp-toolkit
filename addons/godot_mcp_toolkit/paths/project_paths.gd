@tool
extends RefCounted
## Centralized per-project-instance user:// path computation.
##
## Per-instance files live under
##   user://addons/godot_mcp_toolkit/project_instance_<hash>/
## where <hash> is the first 12 chars of SHA-256(canonical project root).
## This isolates multi-instance and multi-worktree setups — two editors
## open on different worktrees of the same repo get separate directories.
##
## Shared files (e.g. onboarding marker) remain directly under
##   user://addons/godot_mcp_toolkit/


const _PLUGIN_DIR := "user://addons/godot_mcp_toolkit/"
const _ProjectKey := preload("res://addons/godot_mcp_toolkit/paths/project_key.gd")


## 12-char hex hash of the canonical project root path. Delegates to the single
## canonicalization SSOT so this hash can never drift from the registry's
## entry-file hash (they MUST match — same instance, one identity).
static func project_hash() -> String:
	return _ProjectKey.current_hash()


## Per-instance directory path (with trailing slash).
## e.g. "user://addons/godot_mcp_toolkit/project_instance_a1b2c3d4e5f6/"
static func instance_dir() -> String:
	return _PLUGIN_DIR + "project_instance_%s/" % project_hash()


## Ensure both the plugin dir and per-instance subdir exist.
## Safe to call multiple times (idempotent).
## Uses globalized (absolute OS) path so directory creation works even
## when user:// root doesn't exist yet (e.g. after a config/name rename
## shifts user:// to a path Godot hasn't materialized).
static func ensure_dirs() -> void:
	var inst := instance_dir()
	if not DirAccess.dir_exists_absolute(inst):
		var abs_path := ProjectSettings.globalize_path(inst).rstrip("/")
		var err := DirAccess.make_dir_recursive_absolute(abs_path)
		if err != OK:
			push_warning("[ProjectPaths] ensure_dirs failed for %s (err %d)" % [abs_path, err])
