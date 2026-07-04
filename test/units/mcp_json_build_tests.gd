@tool
extends RefCounted
## Unit tests for the pure per-OS .mcp.json server-entry builder
## (MCPJsonSync.build_server_entry): the macOS option-d shapes (resolved absolute
## node/npx + login-shell PATH backstop, dev vs release, and the graceful
## bare-npx/node fallback when resolution fails), the Windows cmd/c-npx + node-dev
## shapes, the Linux and unknown-OS bare shapes, and the env boundary — the builder
## owns only the macOS PATH backstop; GODOT_MCP_CONFIG_VERSION is the template's
## job. Also covers the env layering (MCPJsonSync.merge_server_env): an existing
## file's user GODOT_MCP_* keys are preserved through a rewrite, first-create uses
## the template base, and the merge never mutates its inputs.

const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")

const _PKG := "@npgamedev/godot-mcp-server"
const _DEV := "/Users/dev/godot-mcp-server/dist/index.js"


static func run(testing) -> void:
	_test_macos_release_resolved(testing)
	_test_macos_dev_resolved(testing)
	_test_macos_release_fallback(testing)
	_test_macos_dev_fallback(testing)
	_test_macos_path_gated_on_resolution(testing)
	_test_windows_release(testing)
	_test_windows_dev(testing)
	_test_linux_release(testing)
	_test_linux_dev(testing)
	_test_unknown_os_defaults_linux(testing)
	_test_refresh_preserves_user_env(testing)
	_test_env_first_create_uses_template(testing)
	_test_env_merge_is_pure(testing)


# macOS release with a resolved node: absolute npx derived beside node, resolved
# PATH backstop present, no config version (the template supplies that).
static func _test_macos_release_resolved(testing) -> void:
	testing.begin("build_server_entry — macOS release (resolved abs npx + PATH)")
	var entry: Dictionary = MCPJsonSync.build_server_entry(
		"macOS", "/opt/homebrew/bin/node", "/opt/homebrew/bin:/usr/bin:/bin", "")
	testing.eq(str(entry["command"]), "/opt/homebrew/bin/npx", "abs npx derived beside node")
	var args: Array = entry["args"]
	testing.eq(args.size(), 2, "release args length 2")
	testing.eq(str(args[0]), "-y", "release arg 0 = -y")
	testing.eq(str(args[1]), _PKG, "release arg 1 = package")
	var env: Dictionary = entry["env"]
	testing.eq(str(env.get("PATH", "")), "/opt/homebrew/bin:/usr/bin:/bin", "resolved PATH backstop")
	testing.ok(not env.has("GODOT_MCP_CONFIG_VERSION"), "builder env carries no config version")
	print("")


# macOS dev with a resolved node: absolute node runs the dist entry directly
# (strongest shape — dodges npx shebang re-resolution), PATH backstop present.
static func _test_macos_dev_resolved(testing) -> void:
	testing.begin("build_server_entry — macOS dev (resolved abs node + dist)")
	var entry: Dictionary = MCPJsonSync.build_server_entry(
		"macOS", "/opt/homebrew/bin/node", "/opt/homebrew/bin:/usr/bin", _DEV)
	testing.eq(str(entry["command"]), "/opt/homebrew/bin/node", "abs node as command")
	var args: Array = entry["args"]
	testing.eq(args.size(), 1, "dev args length 1")
	testing.eq(str(args[0]), _DEV, "dev arg = dist entry")
	var env: Dictionary = entry["env"]
	testing.eq(str(env.get("PATH", "")), "/opt/homebrew/bin:/usr/bin", "resolved PATH backstop")
	print("")


# macOS release with resolution FAILED (empty node/path): bare npx, no PATH.
static func _test_macos_release_fallback(testing) -> void:
	testing.begin("build_server_entry — macOS release fallback (unresolved)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("macOS", "", "", "")
	testing.eq(str(entry["command"]), "npx", "graceful bare npx")
	var args: Array = entry["args"]
	testing.eq(str(args[0]), "-y", "release arg 0 = -y")
	testing.eq(str(args[1]), _PKG, "release arg 1 = package")
	var env: Dictionary = entry["env"]
	testing.ok(not env.has("PATH"), "no PATH backstop when resolution failed")
	print("")


# macOS dev with resolution FAILED but a dev override: bare node + dist, no PATH.
static func _test_macos_dev_fallback(testing) -> void:
	testing.begin("build_server_entry — macOS dev fallback (unresolved)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("macOS", "", "", _DEV)
	testing.eq(str(entry["command"]), "node", "graceful bare node")
	var args: Array = entry["args"]
	testing.eq(str(args[0]), _DEV, "dev arg = dist entry")
	var env: Dictionary = entry["env"]
	testing.ok(not env.has("PATH"), "no PATH backstop when resolution failed")
	print("")


# The PATH backstop is gated on a resolved PATH, independent of node: node present
# but PATH empty ⇒ absolute npx command yet no PATH key.
static func _test_macos_path_gated_on_resolution(testing) -> void:
	testing.begin("build_server_entry — macOS PATH gated on resolved path")
	var entry: Dictionary = MCPJsonSync.build_server_entry("macOS", "/n/bin/node", "", "")
	testing.eq(str(entry["command"]), "/n/bin/npx", "abs npx still derived from node")
	var env: Dictionary = entry["env"]
	testing.ok(not env.has("PATH"), "no PATH key when resolved path empty")
	print("")


# Windows release: cmd /c npx (npx is a .cmd shim), no PATH backstop.
static func _test_windows_release(testing) -> void:
	testing.begin("build_server_entry — Windows release (cmd /c npx)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("Windows", "", "", "")
	testing.eq(str(entry["command"]), "cmd", "command = cmd")
	var args: Array = entry["args"]
	testing.eq(args.size(), 4, "cmd args length 4")
	testing.eq(str(args[0]), "/c", "arg 0 = /c")
	testing.eq(str(args[1]), "npx", "arg 1 = npx")
	testing.eq(str(args[2]), "-y", "arg 2 = -y")
	testing.eq(str(args[3]), _PKG, "arg 3 = package")
	var env: Dictionary = entry["env"]
	testing.ok(not env.has("PATH"), "no PATH backstop on Windows")
	print("")


# Windows dev: node runs the dist entry directly (node is a real exe on PATH).
static func _test_windows_dev(testing) -> void:
	testing.begin("build_server_entry — Windows dev (node dist)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("Windows", "", "", "C:/x/dist/index.js")
	testing.eq(str(entry["command"]), "node", "command = node")
	var args: Array = entry["args"]
	testing.eq(args.size(), 1, "dev args length 1")
	testing.eq(str(args[0]), "C:/x/dist/index.js", "dev arg = dist entry")
	print("")


# Linux release: bare npx (no launchd bug, no shim).
static func _test_linux_release(testing) -> void:
	testing.begin("build_server_entry — Linux release (bare npx)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("Linux", "", "", "")
	testing.eq(str(entry["command"]), "npx", "command = npx")
	var args: Array = entry["args"]
	testing.eq(str(args[0]), "-y", "arg 0 = -y")
	testing.eq(str(args[1]), _PKG, "arg 1 = package")
	var env: Dictionary = entry["env"]
	testing.ok(not env.has("PATH"), "no PATH backstop on Linux")
	print("")


# Linux dev: bare node + dist.
static func _test_linux_dev(testing) -> void:
	testing.begin("build_server_entry — Linux dev (node dist)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("Linux", "", "", _DEV)
	testing.eq(str(entry["command"]), "node", "command = node")
	var args: Array = entry["args"]
	testing.eq(str(args[0]), _DEV, "dev arg = dist entry")
	print("")


# An unknown OS falls through to the Linux-style bare command (safe default).
static func _test_unknown_os_defaults_linux(testing) -> void:
	testing.begin("build_server_entry — unknown OS defaults to Linux shape")
	var release: Dictionary = MCPJsonSync.build_server_entry("Haiku", "", "", "")
	testing.eq(str(release["command"]), "npx", "unknown OS release = bare npx")
	var dev: Dictionary = MCPJsonSync.build_server_entry("Haiku", "", "", _DEV)
	testing.eq(str(dev["command"]), "node", "unknown OS dev = bare node")
	print("")


# Refreshing an EXISTING config preserves the user's own GODOT_MCP_* env keys while
# command/args/PATH still reflect the builder — the composition _build_content does
# (existing-file env layered over the template base, builder keys on top).
static func _test_refresh_preserves_user_env(testing) -> void:
	testing.begin("merge_server_env — refresh preserves user keys, builder owns command/args/PATH")
	var entry: Dictionary = MCPJsonSync.build_server_entry(
		"macOS", "/opt/homebrew/bin/node", "/opt/homebrew/bin:/usr/bin", "")
	var template_env := {"GODOT_MCP_CONFIG_VERSION": "1"}
	var existing_env := {"GODOT_MCP_CONFIG_VERSION": "1", "GODOT_MCP_EDITOR_PORT": "6560"}
	var built_env: Dictionary = entry["env"]
	var env: Dictionary = MCPJsonSync.merge_server_env(template_env, existing_env, built_env)
	testing.eq(str(env.get("GODOT_MCP_EDITOR_PORT", "")), "6560", "user port pin preserved")
	testing.eq(str(env.get("GODOT_MCP_CONFIG_VERSION", "")), "1", "config version present")
	testing.eq(str(env.get("PATH", "")), "/opt/homebrew/bin:/usr/bin", "builder PATH overlaid")
	testing.eq(str(entry["command"]), "/opt/homebrew/bin/npx", "command reflects the builder")
	var args: Array = entry["args"]
	testing.eq(str(args[1]), _PKG, "args reflect the builder")
	print("")


# A first-time create (no existing file → {} existing env) uses the template base
# alone — GODOT_MCP_CONFIG_VERSION, no stray keys.
static func _test_env_first_create_uses_template(testing) -> void:
	testing.begin("merge_server_env — first create uses template base")
	var env: Dictionary = MCPJsonSync.merge_server_env({"GODOT_MCP_CONFIG_VERSION": "1"}, {}, {})
	testing.eq(str(env.get("GODOT_MCP_CONFIG_VERSION", "")), "1", "config version from template")
	testing.eq(env.size(), 1, "no extra keys on first create")
	print("")


# The merge is pure: none of its three inputs are mutated.
static func _test_env_merge_is_pure(testing) -> void:
	testing.begin("merge_server_env — does not mutate inputs")
	var base := {"GODOT_MCP_CONFIG_VERSION": "1"}
	var existing := {"GODOT_MCP_EDITOR_PORT": "6560"}
	var builder := {"PATH": "/x"}
	MCPJsonSync.merge_server_env(base, existing, builder)
	testing.eq(base.size(), 1, "base env not mutated")
	testing.eq(existing.size(), 1, "existing env not mutated")
	testing.ok(not builder.has("GODOT_MCP_CONFIG_VERSION"), "builder env not mutated")
	print("")
