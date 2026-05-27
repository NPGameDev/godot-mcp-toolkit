@tool
extends RefCounted
## One-time settings migration from legacy namespaces and file paths.
## TODO(refactor): Delete this file — pre-release, no users to migrate from.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const ProjectPaths = _Hub.ProjectPaths


static func migrate_user_data_paths() -> void:
	# Ensure both the plugin dir and per-instance subdir exist.
	ProjectPaths.ensure_dirs()

	var inst := ProjectPaths.instance_dir()
	var project_path := ProjectSettings.globalize_path("res://").replace("\\", "/").rstrip("/")
	var suffix := project_path.sha256_text().substr(0, 12)

	# Phase 1: Move files from user:// root to user://addons/godot_mcp_toolkit/
	# (legacy pre-namespace migration — may still exist on very old installs).
	var phase1 := [
		["user://mcp_audit.log", "user://addons/godot_mcp_toolkit/mcp_audit.log"],
		["user://mcp_power_user_cache.json", "user://addons/godot_mcp_toolkit/mcp_power_user_cache.json"],
		["user://mcp_onboarding_v35_shown", "user://addons/godot_mcp_toolkit/mcp_onboarding_v35_shown"],
		["user://mcp_onboarding_v35b_shown", "user://addons/godot_mcp_toolkit/mcp_onboarding_v35b_shown"],
		["user://mcp_token_%s" % suffix, "user://addons/godot_mcp_toolkit/mcp_token_%s" % suffix],
	]

	# Phase 2: Move per-instance files from flat namespace into hash subdir.
	# Onboarding flags stay shared (NOT moved into instance dir).
	var phase2 := [
		["user://addons/godot_mcp_toolkit/mcp_audit.log", inst + "mcp_audit.log"],
		["user://addons/godot_mcp_toolkit/mcp_standard_gates_cache.json", inst + "mcp_standard_gates_cache.json"],
		["user://addons/godot_mcp_toolkit/mcp_power_user_cache.json", inst + "mcp_power_user_cache.json"],
		["user://addons/godot_mcp_toolkit/mcp_token_%s" % suffix, inst + "mcp_token"],
	]

	var moved := 0
	for phases in [phase1, phase2]:
		for pair in phases:
			var old_path: String = pair[0]
			var new_path: String = pair[1]
			if FileAccess.file_exists(old_path) and not FileAccess.file_exists(new_path):
				var content := FileAccess.get_file_as_bytes(old_path)
				var out := FileAccess.open(new_path, FileAccess.WRITE)
				if out != null:
					out.store_buffer(content)
					out.close()
					DirAccess.remove_absolute(old_path)
					moved += 1
	if moved > 0:
		print("[MCP] Migrated %d file(s) to user://addons/godot_mcp_toolkit/project_instance_*/" % moved)


static func migrate_stale_settings() -> void:
	# Remove leftover keys from previous namespace eras.
	var stale_keys := [
		"mcp/unsafe/allow_all",
		"mcp/unsafe/allow_game_eval",
		"mcp/unsafe/allow_os_execute",
		"mcp/unsafe/allow_user_scope",
		"mcp/unsafe/allow_outbound_http",
		"mcp/unsafe/allow_node_call_method",
		"mcp/unsafe/allow_project_set_setting",
		"mcp/unsafe/allow_input_map_write",
		"application/config/mcp_smoke_15d",
		# Feature gate subsystem removed entirely (41l-vicies-septies).
		# Clean up all legacy keys from every era:
		"mcp_toolkit/feature_gates/allow_execute_code",
		"mcp_toolkit/feature_gates/allow_node_call_method",
		"mcp_toolkit/feature_gates/allow_user_scope",
		"mcp_toolkit/feature_gates/allow_game_eval",
		"mcp_toolkit/feature_gates/allow_os_execute",
		"mcp_toolkit/feature_gates/allow_outbound_http",
		"mcp_toolkit/feature_gates/profile",
		"mcp_toolkit/feature_gates/power_user_mode",
		"mcp_toolkit/feature_gates/power_user_warning",
		"mcp_toolkit/feature_gates/profile_warning",
		"mcp_toolkit/unsafe/allow_all",
		"mcp_toolkit/unsafe/power_user_mode",
		"mcp_toolkit/unsafe/power_user_warning",
		"mcp_toolkit/power_user_mode",
		"mcp_toolkit/profile",
		"mcp_toolkit/internal/pre_power_user_cache",
	]
	var removed := 0
	for key in stale_keys:
		if ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, null)
			removed += 1
	if removed > 0:
		ProjectSettings.save()
		print("[MCP] Migrated %d stale settings" % removed)
