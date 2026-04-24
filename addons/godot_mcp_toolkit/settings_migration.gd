@tool
extends RefCounted
## One-time settings migration from legacy namespaces and file paths.
## Called once at plugin startup; safe to delete once legacy users have migrated.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPFeatureRegistry = _Hub.MCPFeatureRegistry


static func migrate_user_data_paths() -> void:
	# Ensure the namespaced user:// directory exists.
	var dir := DirAccess.open("user://")
	if dir != null and not dir.dir_exists("addons/godot_mcp_toolkit"):
		dir.make_dir_recursive("addons/godot_mcp_toolkit")

	# Move files from user:// root to user://addons/godot_mcp_toolkit/.
	var migrations := [
		["user://mcp_audit.log", "user://addons/godot_mcp_toolkit/mcp_audit.log"],
		["user://mcp_power_user_cache.json", "user://addons/godot_mcp_toolkit/mcp_power_user_cache.json"],
		["user://mcp_onboarding_v35_shown", "user://addons/godot_mcp_toolkit/mcp_onboarding_v35_shown"],
		["user://mcp_onboarding_v35b_shown", "user://addons/godot_mcp_toolkit/mcp_onboarding_v35b_shown"],
	]
	# Token files are per-worktree (user://mcp_token_<hash>).
	var project_path := ProjectSettings.globalize_path("res://").replace("\\", "/").rstrip("/")
	var suffix := project_path.sha256_text().substr(0, 12)
	migrations.append([
		"user://mcp_token_%s" % suffix,
		"user://addons/godot_mcp_toolkit/mcp_token_%s" % suffix,
	])

	var moved := 0
	for pair in migrations:
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
		print("[MCP] Migrated %d file(s) to user://addons/godot_mcp_toolkit/" % moved)


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
	# Migrate old power_user_mode paths -> current feature_gates/power_user_mode.
	for old_key in ["mcp_toolkit/unsafe/allow_all", "mcp_toolkit/unsafe/power_user_mode", "mcp_toolkit/power_user_mode"]:
		if ProjectSettings.has_setting(old_key):
			var val = ProjectSettings.get_setting(old_key, false)
			if val:
				ProjectSettings.set_setting("mcp_toolkit/feature_gates/power_user_mode", true)
			ProjectSettings.set_setting(old_key, null)
			removed += 1
	# Remove stale power_user_warning from old unsafe/ namespace.
	if ProjectSettings.has_setting("mcp_toolkit/unsafe/power_user_warning"):
		ProjectSettings.set_setting("mcp_toolkit/unsafe/power_user_warning", null)
		removed += 1
	# Remove internal cache from ProjectSettings — now stored in user:// file.
	if ProjectSettings.has_setting("mcp_toolkit/internal/pre_power_user_cache"):
		ProjectSettings.set_setting("mcp_toolkit/internal/pre_power_user_cache", null)
		removed += 1
	if removed > 0:
		ProjectSettings.save()
		print("[MCP] Migrated %d stale settings" % removed)
