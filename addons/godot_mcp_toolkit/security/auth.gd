@tool
extends RefCounted
## Session-token authentication for the MCP WebSocket transport.
##
## On each server start a fresh 32-byte hex token is generated, written
## to user://addons/godot_mcp_toolkit/project_instance_<hash>/mcp_token
## (or GODOT_MCP_TOKEN_PATH), and required as the first WebSocket message
## from every connecting client.

const ProjectPaths := preload("res://addons/godot_mcp_toolkit/paths/project_paths.gd")


## Generate a fresh 64-char hex token (32 random bytes).
static func generate_token() -> String:
	return Crypto.new().generate_random_bytes(32).hex_encode()


## The token path — a user:// path per-instance under
## user://…/project_instance_<hash>/mcp_token (two worktrees of the same
## repo get distinct files), or the absolute GODOT_MCP_TOKEN_PATH override.
static func get_token_path() -> String:
	var env_path := OS.get_environment("GODOT_MCP_TOKEN_PATH")
	if not env_path.is_empty():
		return env_path
	return ProjectPaths.instance_dir() + "mcp_token"


## The token path in REGISTRY-PUBLISH form: an absolute, globalized path the
## out-of-engine server opens directly. globalize_path() reads use_custom_user_dir
## live, so a relocated user:// is honored and the server never re-derives the user
## dir. In-engine callers use get_token_path()'s user:// form; the registry publish
## sites use this absolute form.
static func get_published_token_path() -> String:
	return ProjectSettings.globalize_path(get_token_path())


## Write token to disk. Returns OK or an error code.
static func write_token(token: String) -> int:
	ProjectPaths.ensure_dirs()
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
