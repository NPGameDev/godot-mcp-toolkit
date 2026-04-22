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
	var allow_all: bool = ProjectSettings.get_setting("mcp_toolkit/unsafe/allow_all", false)
	var ps_ok: bool = allow_all or ProjectSettings.get_setting(str(entry["ps_key"]), false)
	var env_ok := OS.get_environment(str(entry["env_var"])) == "1"
	return (env_ok and ps_ok) if entry["dual_gate"] else (env_ok or ps_ok)


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
