@tool
extends RefCounted
## Table-driven feature registry for the FeatureGate system.
##
## Each entry declares the env var name, ProjectSettings key, gate type
## (dual = env AND PS; single = env OR PS), and a human-readable risk
## string surfaced in FEATURE_DISABLED error payloads.
##
## To add a new gated feature, append an entry here. ProjectSettings
## registration (plugin.gd) and TS-side catalogue filtering
## (feature_gate.ts) read from this table — no secondary manifest.

const FEATURES := {
	"game_eval": {
		"env_var": "GODOT_MCP_ALLOW_GAME_EVAL",
		"ps_key": "mcp_toolkit/feature_gates/allow_game_eval",
		"dual_gate": true,
		"risk": "Arbitrary GDScript via Expression",
	},
	"os_execute": {
		"env_var": "GODOT_MCP_ALLOW_OS_EXECUTE",
		"ps_key": "mcp_toolkit/feature_gates/allow_os_execute",
		"dual_gate": true,
		"risk": "Host-OS shell execution",
	},
	"read_user_scope": {
		"env_var": "GODOT_MCP_ALLOW_USER_SCOPE",
		"ps_key": "mcp_toolkit/feature_gates/allow_user_scope",
		"dual_gate": true,
		"risk": "Read/write whitelisted user:// paths",
	},
	"outbound_http": {
		"env_var": "GODOT_MCP_ALLOW_OUTBOUND_HTTP",
		"ps_key": "mcp_toolkit/feature_gates/allow_outbound_http",
		"dual_gate": true,
		"risk": "Outbound HTTP requests",
	},
	"node_call_method": {
		"env_var": "GODOT_MCP_ALLOW_NODE_CALL_METHOD",
		"ps_key": "mcp_toolkit/feature_gates/allow_node_call_method",
		"dual_gate": false,
		"risk": "Method invocation on edited-scene nodes",
	},
	"project_set_setting": {
		"env_var": "GODOT_MCP_ALLOW_PROJECT_SET_SETTING",
		"ps_key": "mcp_toolkit/feature_gates/allow_project_set_setting",
		"dual_gate": true,
		"risk": "Write arbitrary ProjectSettings keys",
	},
	"input_map_write": {
		"env_var": "GODOT_MCP_ALLOW_INPUT_MAP_WRITE",
		"ps_key": "mcp_toolkit/feature_gates/allow_input_map_write",
		"dual_gate": false,
		"risk": "Modify persistent InputMap actions",
	},
}


static func get_entry(feature: String) -> Variant:
	return FEATURES.get(feature)


static func all_features() -> Array:
	return FEATURES.keys()


static func all_entries() -> Dictionary:
	return FEATURES
