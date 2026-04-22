@tool
extends RefCounted
## Session-token authentication for the MCP WebSocket transport.
##
## On each server start a fresh 32-byte hex token is generated, written
## to user://addons/godot_mcp_toolkit/mcp_token_<hash> (or
## GODOT_MCP_TOKEN_PATH), and required as the first WebSocket message
## from every connecting client.


## Generate a fresh 64-char hex token (32 random bytes).
static func generate_token() -> String:
	return Crypto.new().generate_random_bytes(32).hex_encode()


## Absolute OS path where the token is written / read.
## Per-worktree: hashes the canonical project path so two worktrees of the
## same repo (same config/name → same user://) get distinct token files.
## Env override: GODOT_MCP_TOKEN_PATH bypasses the hash.
static func get_token_path() -> String:
	var env_path := OS.get_environment("GODOT_MCP_TOKEN_PATH")
	if not env_path.is_empty():
		return env_path
	var project_path := ProjectSettings.globalize_path("res://").replace("\\", "/").rstrip("/")
	var suffix := project_path.sha256_text().substr(0, 12)
	return "user://addons/godot_mcp_toolkit/mcp_token_%s" % suffix


## Write token to disk. Returns OK or an error code.
static func write_token(token: String) -> int:
	var path := get_token_path()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(token)
	file.close()
	# File permissions: Godot 4.x has no cross-platform chmod API.
	# On Unix the user-data directory (~/.local/share/godot/...) is
	# already owner-restricted; on Windows %APPDATA% is user-scoped.
	# Documented as a known limitation — no sensitive data leaks beyond
	# the current OS user boundary.
	return OK


## Validate a parsed auth message. Returns true if the token matches.
static func validate(message: Dictionary, expected_token: String) -> bool:
	return str(message.get("auth", "")) == expected_token
