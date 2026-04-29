@tool
extends RefCounted
## Table-driven feature registry for the FeatureGate system.
##
## Each entry declares the .mcp.json env var name and a human-readable
## risk string surfaced in FEATURE_DISABLED error payloads.
##
## Gate state runtime source of truth is the sidecar state file (instance
## subdir). ProjectSettings bools (ps_key) are a mirror UI — the dock and
## the Inspector both reflect the sidecar, and changes from either side
## are synced bidirectionally by the poll loop in feature_gate_settings.gd.
## .mcp.json is auto-generated read-only. Profile mode and admin deny
## keys remain in PS as overrides.
##
## To add a new gated feature, append an entry here. TS-side catalogue
## filtering (feature_gate.ts) reads from this table — no secondary
## manifest.

const PROFILE_MINIMAL := 0
const PROFILE_STANDARD := 1
const PROFILE_POWER_USER := 2

const FEATURES := {
	"game_eval": {
		"env_var": "GODOT_MCP_ALLOW_GAME_EVAL",
		"ps_key": "mcp_toolkit/feature_gates/allow_game_eval",
		"risk": "Arbitrary GDScript via Expression",
		"warn_on_enable": true,
		"warn_text": "Allows the AI to evaluate arbitrary GDScript expressions in the running game via the Expression class.",
	},
	"read_user_scope": {
		"env_var": "GODOT_MCP_ALLOW_USER_SCOPE",
		"ps_key": "mcp_toolkit/feature_gates/allow_user_scope",
		"risk": "Read/write whitelisted user:// paths",
	},
	"node_call_method": {
		"env_var": "GODOT_MCP_ALLOW_NODE_CALL_METHOD",
		"ps_key": "mcp_toolkit/feature_gates/allow_node_call_method",
		"risk": "Method invocation on edited-scene nodes",
		"warn_on_enable": true,
		"warn_text": "Allows the AI to call arbitrary methods on nodes in the edited scene, which may have side effects.",
	},
}


static func get_entry(feature: String) -> Variant:
	return FEATURES.get(feature)


static func all_features() -> Array:
	return FEATURES.keys()


static func all_entries() -> Dictionary:
	return FEATURES
