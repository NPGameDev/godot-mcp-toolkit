@tool
extends RefCounted
## FeatureGate — .mcp.json env-var gate check for unsafe features.
##
## Gate state lives solely in .mcp.json env vars (read via MCPJsonSync).
## Profile mode (Minimal/Standard/Power User) and admin deny keys
## (deny_<feature>) remain in ProjectSettings as overrides.
##
## Check order: deny (PS) → profile (PS) → env var (.mcp.json).

const MCPFeatureRegistry := preload("res://addons/godot_mcp_toolkit/feature_registry.gd")
const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")


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
	# Standard — .mcp.json env var is the sole gate check.
	return MCPJsonSync.has_env_var(str(entry["env_var"]))


## File-backed cache for Standard-profile feature states.
const _CACHE_PATH := "user://addons/godot_mcp_toolkit/mcp_power_user_cache.json"


## Save current per-feature env var state before leaving Standard profile.
static func snapshot_standard_gates() -> void:
	var cache := {}
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		cache[feature] = MCPJsonSync.has_env_var(str(entry["env_var"]))
	var f := FileAccess.open(_CACHE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(cache))
		f.close()


## Restore per-feature env var state from the cache. Writes env vars
## back to .mcp.json. Deletes the cache file. Returns the cache dict.
static func restore_standard_gates() -> Dictionary:
	var cache: Dictionary = {}
	if FileAccess.file_exists(_CACHE_PATH):
		var f := FileAccess.open(_CACHE_PATH, FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(parsed) == TYPE_DICTIONARY:
				cache = parsed
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		var was_on: bool = bool(cache.get(feature, false))
		MCPJsonSync.set_env_var(str(entry["env_var"]), was_on)
	DirAccess.remove_absolute(_CACHE_PATH)
	return cache


## Whether a gate-state cache exists (Standard gates were snapshotted).
static func has_standard_cache() -> bool:
	return FileAccess.file_exists(_CACHE_PATH)


static func disabled_error(feature: String) -> Dictionary:
	var entry = MCPFeatureRegistry.get_entry(feature)
	if entry == null:
		return {
			"success": false,
			"error": "unknown feature: " + feature,
			"code": "FEATURE_DISABLED",
		}
	var how_to_enable := "Set %s=1 in .mcp.json env, or enable in the MCP Toolkit dock." % entry["env_var"]
	return {
		"success": false,
		"error": "%s is disabled" % feature,
		"code": "FEATURE_DISABLED",
		"risk": str(entry["risk"]),
		"how_to_enable": how_to_enable,
	}
