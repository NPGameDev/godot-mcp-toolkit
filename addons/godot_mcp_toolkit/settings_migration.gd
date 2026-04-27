@tool
extends RefCounted
## One-time settings migration from legacy namespaces and file paths.
## Called once at plugin startup; safe to delete once legacy users have migrated.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPFeatureRegistry = _Hub.MCPFeatureRegistry
const MCPProjectPaths = _Hub.MCPProjectPaths


static func migrate_user_data_paths() -> void:
	# Ensure both the plugin dir and per-instance subdir exist.
	MCPProjectPaths.ensure_dirs()

	var inst := MCPProjectPaths.instance_dir()
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

	# Phase 3: Move sidecar from .godot/ to instance dir.
	var old_sidecar := ProjectSettings.globalize_path("res://") + ".godot/mcp_toolkit_state.json"
	if FileAccess.file_exists(old_sidecar) and not FileAccess.file_exists(inst + "mcp_toolkit_state.json"):
		var content := FileAccess.get_file_as_bytes(old_sidecar)
		var out := FileAccess.open(inst + "mcp_toolkit_state.json", FileAccess.WRITE)
		if out != null:
			out.store_buffer(content)
			out.close()
			DirAccess.remove_absolute(old_sidecar)
			print("[MCP] Migrated sidecar from .godot/ to instance dir")

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
		# Gates removed in 41d-nonis (no tools used them):
		"mcp_toolkit/feature_gates/allow_os_execute",
		"mcp_toolkit/feature_gates/allow_outbound_http",
	]
	var removed := 0
	for key in stale_keys:
		if ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, null)
			removed += 1
	# Migrate unsafe/ -> feature_gates/ per-feature keys.
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		var new_key: String = entry["ps_key"]  # already feature_gates/
		var old_key := new_key.replace("feature_gates/", "unsafe/")
		if ProjectSettings.has_setting(old_key):
			var val = ProjectSettings.get_setting(old_key, false)
			if val:
				ProjectSettings.set_setting(new_key, true)
			ProjectSettings.set_setting(old_key, null)
			removed += 1
	# Migrate old power_user_mode paths -> mcp_toolkit/profile enum.
	for old_key in ["mcp_toolkit/unsafe/allow_all", "mcp_toolkit/unsafe/power_user_mode", "mcp_toolkit/power_user_mode"]:
		if ProjectSettings.has_setting(old_key):
			var val = ProjectSettings.get_setting(old_key, false)
			if val:
				ProjectSettings.set_setting("mcp_toolkit/feature_gates/profile", 2)  # Power User
			ProjectSettings.set_setting(old_key, null)
			removed += 1
	# Migrate feature_gates/power_user_mode boolean -> mcp_toolkit/profile enum.
	if ProjectSettings.has_setting("mcp_toolkit/feature_gates/power_user_mode"):
		var was_pu = ProjectSettings.get_setting("mcp_toolkit/feature_gates/power_user_mode", false)
		if was_pu:
			ProjectSettings.set_setting("mcp_toolkit/feature_gates/profile", 2)  # Power User
		ProjectSettings.set_setting("mcp_toolkit/feature_gates/power_user_mode", null)
		removed += 1
	# Clean up stale mcp_toolkit/profile (wrong path — should be feature_gates/profile).
	if ProjectSettings.has_setting("mcp_toolkit/profile"):
		var val = ProjectSettings.get_setting("mcp_toolkit/profile", 1)
		if val is int and val != 1 and not ProjectSettings.has_setting("mcp_toolkit/feature_gates/profile"):
			ProjectSettings.set_setting("mcp_toolkit/feature_gates/profile", val)
		ProjectSettings.set_setting("mcp_toolkit/profile", null)
		removed += 1
	# Remove stale warning keys (renamed to status).
	for old_warn in ["mcp_toolkit/unsafe/power_user_warning", "mcp_toolkit/feature_gates/power_user_warning", "mcp_toolkit/feature_gates/profile_warning"]:
		if ProjectSettings.has_setting(old_warn):
			ProjectSettings.set_setting(old_warn, null)
			removed += 1
	# Remove internal cache from ProjectSettings — now stored in user:// file.
	if ProjectSettings.has_setting("mcp_toolkit/internal/pre_power_user_cache"):
		ProjectSettings.set_setting("mcp_toolkit/internal/pre_power_user_cache", null)
		removed += 1
	if removed > 0:
		ProjectSettings.save()
		print("[MCP] Migrated %d stale settings" % removed)
