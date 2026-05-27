@tool
extends RefCounted
## Read-only access to .mcp.json env vars.
##
## Reads the .mcp.json at the Godot project root, finds the
## godot-mcp-toolkit server entry, and returns env var values.
## The plugin never writes to .mcp.json — it is a user-managed
## config file. Runtime config lives in the sidecar.


static func get_mcp_json_path() -> String:
	return ProjectSettings.globalize_path("res://") + ".mcp.json"


static func has_mcp_json() -> bool:
	return FileAccess.file_exists(get_mcp_json_path())


static func get_all_env_vars() -> Dictionary:
	var raw := _read_server_env()
	# Env vars are strings by definition. JSON may store them as integers
	# (e.g. "GODOT_MCP_READ_ONLY": 1 instead of "1"). Coerce all values
	# to String so consumers can safely compare with == "1" etc.
	var coerced: Dictionary = {}
	for key in raw:
		coerced[key] = str(raw[key])
	return coerced


static func _read_server_env() -> Dictionary:
	var path := get_mcp_json_path()
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		return {}
	var servers: Dictionary = parsed.get("mcpServers", {})
	var server_key := _find_server_key(servers)
	if server_key.is_empty():
		return {}
	if not servers[server_key] is Dictionary:
		return {}
	var server_entry: Dictionary = servers[server_key]
	var env = server_entry.get("env", {})
	return env if env is Dictionary else {}


static func _find_server_key(servers: Dictionary) -> String:
	if servers.has("godot-mcp-toolkit"):
		return "godot-mcp-toolkit"
	for key in servers:
		if "godot-mcp" in str(key).to_lower():
			return str(key)
	return ""
