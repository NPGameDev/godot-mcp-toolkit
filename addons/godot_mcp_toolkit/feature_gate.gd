@tool
extends RefCounted
## FeatureGate — gate check for unsafe features.
##
## ProjectSettings is the single source of truth for gate state.
## Admin deny keys (deny_<feature>) remain as PS overrides.
##
## Check order: deny (PS) → PS gate bool.

# Direct preload (not via _Hub) to avoid circular dependency —
# _hub.gd preloads this file.
const FeatureRegistry := preload("res://addons/godot_mcp_toolkit/feature_registry.gd")


static func is_enabled(feature: String) -> bool:
	var entry = FeatureRegistry.get_entry(feature)
	if entry == null:
		return false
	# Explicit deny (PS-only safety override) always wins.
	if ProjectSettings.get_setting("mcp_toolkit/feature_gates/deny_" + feature, false):
		return false
	return ProjectSettings.get_setting(str(entry["ps_key"]), false)


## Returns {env_var_name: bool} for all registered features by reading PS.
## Used by gate_notifier.gd and mcp_server.gd for WebSocket payloads.
static func snapshot_gates() -> Dictionary:
	var gates := {}
	for feature in FeatureRegistry.all_features():
		var entry: Dictionary = FeatureRegistry.get_entry(feature)
		gates[str(entry["env_var"])] = bool(
				ProjectSettings.get_setting(str(entry["ps_key"]), false))
	return gates


# -- Dangerous-gate session tracking (H7) ------------------------------------

static var _session_warned: Dictionary = {}


static func needs_danger_warning(feature: String) -> bool:
	var entry = FeatureRegistry.get_entry(feature)
	if entry == null:
		return false
	if not entry.get("warn_on_enable", false):
		return false
	return not _session_warned.has(feature)


static func mark_warned(feature: String) -> void:
	_session_warned[feature] = true


static func disabled_error(feature: String) -> Dictionary:
	var entry = FeatureRegistry.get_entry(feature)
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
