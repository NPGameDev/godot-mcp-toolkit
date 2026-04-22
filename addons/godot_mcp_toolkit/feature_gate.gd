@tool
extends RefCounted
## FeatureGate — dual/single gate check for unsafe features.
##
## Dual-gate (RCE-class): requires BOTH env var AND ProjectSettings flag.
## Single-gate (lower risk): requires env var OR ProjectSettings flag.
## Explicit deny (mcp_toolkit/unsafe/deny_<feature>) always wins.

const MCPFeatureRegistry := preload("res://addons/godot_mcp_toolkit/feature_registry.gd")


static func is_enabled(feature: String) -> bool:
	var entry = MCPFeatureRegistry.get_entry(feature)
	if entry == null:
		return false
	# Explicit deny always wins.
	if ProjectSettings.get_setting("mcp_toolkit/unsafe/deny_" + feature, false):
		return false
	var allow_all: bool = ProjectSettings.get_setting("mcp_toolkit/power_user_mode", false)
	var ps_ok: bool = allow_all or ProjectSettings.get_setting(str(entry["ps_key"]), false)
	var env_ok := OS.get_environment(str(entry["env_var"])) == "1"
	return (env_ok and ps_ok) if entry["dual_gate"] else (env_ok or ps_ok)


## File-backed cache for pre-Power-User feature states.
const _CACHE_PATH := "user://mcp_power_user_cache.json"


## Save current per-feature PS state before Power User.
static func snapshot_pre_power_user() -> void:
	var cache := {}
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		cache[feature] = {
			"ps": ProjectSettings.get_setting(str(entry["ps_key"]), false),
		}
	var f := FileAccess.open(_CACHE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(cache))
		f.close()


## Restore per-feature PS state from the cache. Returns the cache dict
## so callers can also restore env vars if needed. Deletes the cache file.
static func restore_pre_power_user() -> Dictionary:
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
		var prev: Dictionary = cache.get(feature, {})
		ProjectSettings.set_setting(str(entry["ps_key"]), prev.get("ps", false))
	DirAccess.remove_absolute(_CACHE_PATH)
	return cache


## Whether a snapshot exists (i.e. Power User was enabled with cache).
static func has_power_user_cache() -> bool:
	return FileAccess.file_exists(_CACHE_PATH)


static func disabled_error(feature: String) -> Dictionary:
	var entry = MCPFeatureRegistry.get_entry(feature)
	if entry == null:
		return {
			"success": false,
			"error": "unknown feature: " + feature,
			"code": "FEATURE_DISABLED",
		}
	var how_to_enable: String
	if entry["dual_gate"]:
		how_to_enable = "Set env %s=1 AND enable Project Settings → Advanced → %s." % [
			entry["env_var"], entry["ps_key"]]
	else:
		how_to_enable = "Set env %s=1 OR enable Project Settings → Advanced → %s." % [
			entry["env_var"], entry["ps_key"]]
	return {
		"success": false,
		"error": "%s is disabled" % feature,
		"code": "FEATURE_DISABLED",
		"risk": str(entry["risk"]),
		"how_to_enable": how_to_enable,
	}
