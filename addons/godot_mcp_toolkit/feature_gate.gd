@tool
extends RefCounted
## FeatureGate — gate check for unsafe features.
##
## Runtime gate state lives in the sidecar
## (user://…/project_instance_<hash>/mcp_toolkit_state.json)
## with .mcp.json env vars as a migration fallback.
## Profile mode (Minimal/Standard/Power User) and admin deny keys
## (deny_<feature>) remain in ProjectSettings as overrides.
##
## Check order: deny (PS) → profile (PS) → sidecar gate.

# Direct preloads (not via _Hub) to avoid circular dependency —
# _hub.gd preloads this file.
const MCPFeatureRegistry := preload("res://addons/godot_mcp_toolkit/feature_registry.gd")
const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")
const MCPStateFile := preload("res://addons/godot_mcp_toolkit/mcp_state_file.gd")


static func is_enabled(feature: String) -> bool:
	var entry = MCPFeatureRegistry.get_entry(feature)
	if entry == null:
		return false
	# Explicit deny (PS-only safety override) always wins.
	if ProjectSettings.get_setting("mcp_toolkit/feature_gates/deny_" + feature, false):
		return false
	var profile: int = ProjectSettings.get_setting("mcp_toolkit/feature_gates/profile", 1)
	if profile == 0:  # Minimal — all gates disabled.
		return false
	if profile == 2:  # Power User — all gates enabled.
		return true
	# Standard — sidecar is the runtime source of truth, .mcp.json as fallback.
	var env_var: String = str(entry["env_var"])
	var sidecar_gates := MCPStateFile.get_current_gates()
	if sidecar_gates.has(env_var):
		return sidecar_gates[env_var] == true
	return MCPJsonSync.is_gate_enabled(env_var)


## File-backed cache for Standard-profile feature states.
const MCPProjectPaths := preload("res://addons/godot_mcp_toolkit/project_paths.gd")
const _CACHE_FILENAME := "mcp_standard_gates_cache.json"


static func _get_cache_path() -> String:
	return MCPProjectPaths.instance_dir() + _CACHE_FILENAME


## Migrate legacy cache file (renamed in 41d-quater).
## Checks both the old flat paths and the legacy name.
static func _migrate_cache() -> void:
	var cache_path := _get_cache_path()
	if FileAccess.file_exists(cache_path):
		return
	# Check legacy name in new location.
	var legacy_new := MCPProjectPaths.instance_dir() + "mcp_power_user_cache.json"
	if FileAccess.file_exists(legacy_new):
		var dir := DirAccess.open(MCPProjectPaths.instance_dir())
		if dir != null:
			dir.rename("mcp_power_user_cache.json", _CACHE_FILENAME)
		return
	# Check old flat paths (pre-instance-dir migration).
	var old_path := "user://addons/godot_mcp_toolkit/mcp_standard_gates_cache.json"
	var old_legacy := "user://addons/godot_mcp_toolkit/mcp_power_user_cache.json"
	var source := ""
	if FileAccess.file_exists(old_path):
		source = old_path
	elif FileAccess.file_exists(old_legacy):
		source = old_legacy
	if not source.is_empty():
		MCPProjectPaths.ensure_dirs()
		var content := FileAccess.get_file_as_bytes(source)
		var out := FileAccess.open(cache_path, FileAccess.WRITE)
		if out != null:
			out.store_buffer(content)
			out.close()
			DirAccess.remove_absolute(source)


## Save current per-feature gate state before leaving Standard profile.
static func snapshot_standard_gates() -> void:
	_migrate_cache()
	var sidecar_gates := MCPStateFile.get_current_gates()
	var cache := {}
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		var env_var: String = str(entry["env_var"])
		if sidecar_gates.has(env_var):
			cache[feature] = sidecar_gates[env_var] == true
		elif MCPJsonSync.has_mcp_json():
			cache[feature] = MCPJsonSync.is_gate_enabled(env_var)
		else:
			cache[feature] = false
	# L3: don't overwrite valid cache with all-false.
	var any_on := false
	for v in cache.values():
		if v:
			any_on = true
			break
	if not any_on and has_standard_cache():
		return
	var f := FileAccess.open(_get_cache_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(cache))
		f.close()


## Restore per-feature gate state from the cache. Writes gates to the
## sidecar. Deletes the cache file. Returns the cache dict.
static func restore_standard_gates() -> Dictionary:
	_migrate_cache()
	var cache: Dictionary = {}
	if FileAccess.file_exists(_get_cache_path()):
		var f := FileAccess.open(_get_cache_path(), FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(parsed) == TYPE_DICTIONARY:
				cache = parsed
	# Build full gates dict from cache and write to sidecar in one pass.
	var gates := {}
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		var was_on: bool = bool(cache.get(feature, false))
		gates[str(entry["env_var"])] = was_on
	var err := MCPStateFile.write("standard", gates)
	if err != OK:
		push_warning("[MCPStateFile] restore_standard_gates: sidecar write failed (err %d)" % err)
	return cache


## Whether a gate-state cache exists (Standard gates were snapshotted).
static func has_standard_cache() -> bool:
	_migrate_cache()
	return FileAccess.file_exists(_get_cache_path())


# -- Dangerous-gate session tracking (H7) ------------------------------------

static var _session_warned: Dictionary = {}


static func needs_danger_warning(feature: String) -> bool:
	var entry = MCPFeatureRegistry.get_entry(feature)
	if entry == null:
		return false
	if not entry.get("warn_on_enable", false):
		return false
	return not _session_warned.has(feature)


static func mark_warned(feature: String) -> void:
	_session_warned[feature] = true


static func disabled_error(feature: String) -> Dictionary:
	var entry = MCPFeatureRegistry.get_entry(feature)
	if entry == null:
		return {
			"success": false,
			"error": "unknown feature: " + feature,
			"code": "FEATURE_DISABLED",
		}
	var how_to_enable: String = "Set %s=1 in .mcp.json env, or enable in the MCP Toolkit dock." % entry["env_var"]
	return {
		"success": false,
		"error": "%s is disabled" % feature,
		"code": "FEATURE_DISABLED",
		"risk": str(entry["risk"]),
		"how_to_enable": how_to_enable,
	}
