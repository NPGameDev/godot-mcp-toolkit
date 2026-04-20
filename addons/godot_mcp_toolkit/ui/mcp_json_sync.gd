@tool
extends RefCounted
## Parse/modify .mcp.json env vars for feature-gate sync.
##
## Reads the .mcp.json at the Godot project root, finds the
## godot-mcp-toolkit server entry, and reads/writes env vars.

const MCPFeatureRegistry := preload("res://addons/godot_mcp_toolkit/feature_registry.gd")


static func get_mcp_json_path() -> String:
	return ProjectSettings.globalize_path("res://") + ".mcp.json"


static func has_mcp_json() -> bool:
	return FileAccess.file_exists(get_mcp_json_path())


static func has_env_var(env_var_name: String) -> bool:
	var data := _read_server_env()
	return data.get(env_var_name, "") == "1"


static func set_env_var(env_var_name: String, enabled: bool) -> Error:
	var path := get_mcp_json_path()
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		return ERR_PARSE_ERROR
	var servers: Dictionary = parsed.get("mcpServers", {})
	var server_key := _find_server_key(servers)
	if server_key.is_empty():
		return ERR_DOES_NOT_EXIST
	if not servers[server_key] is Dictionary:
		return ERR_PARSE_ERROR
	var server_entry: Dictionary = servers[server_key]
	var env: Dictionary = server_entry.get("env", {})
	if enabled:
		env[env_var_name] = "1"
	else:
		env.erase(env_var_name)
	server_entry["env"] = env
	servers[server_key] = server_entry
	parsed["mcpServers"] = servers
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(parsed, "\t"))
	f.close()
	return OK


static func get_all_env_vars() -> Dictionary:
	return _read_server_env()


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
