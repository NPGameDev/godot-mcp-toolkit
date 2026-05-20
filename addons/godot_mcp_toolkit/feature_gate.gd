@tool
extends RefCounted
## FeatureGate — gate check for unsafe features.
##
## Runtime gate state lives in the sidecar
## (user://…/project_instance_<hash>/mcp_toolkit_state.json)
## with .mcp.json env vars as a migration fallback.
## Admin deny keys (deny_<feature>) remain in ProjectSettings as overrides.
##
## Check order: deny (PS) → sidecar gate.

# Direct preloads (not via _Hub) to avoid circular dependency —
# _hub.gd preloads this file.
const FeatureRegistry := preload("res://addons/godot_mcp_toolkit/feature_registry.gd")
const McpJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")
const McpStateFile := preload("res://addons/godot_mcp_toolkit/mcp_state_file.gd")


static func is_enabled(feature: String) -> bool:
	var entry = FeatureRegistry.get_entry(feature)
	if entry == null:
		return false
	# Explicit deny (PS-only safety override) always wins.
	if ProjectSettings.get_setting("mcp_toolkit/feature_gates/deny_" + feature, false):
		return false
	# Sidecar is the runtime source of truth, .mcp.json as fallback.
	var env_var: String = str(entry["env_var"])
	var sidecar_gates := McpStateFile.get_current_gates()
	if sidecar_gates.has(env_var):
		return sidecar_gates[env_var] == true
	return McpJsonSync.is_gate_enabled(env_var)


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
