@tool
extends RefCounted
## Unit tests for the pure per-OS .mcp.json server-entry builder
## (MCPJsonSync.build_server_entry): the bare npx (release) / node (dev) shapes on
## macOS, Linux, and any unknown OS; the Windows cmd /c npx + node-dev shapes; and
## the entry boundary — the builder emits only {command, args}, never an env. Also
## covers the env layering (MCPJsonSync.merge_server_env): the template base plus an
## existing file's user GODOT_MCP_* keys, a first-create from the template alone, and
## the merge never mutating its inputs.

const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")

const _PKG := "@npgamedev/godot-mcp-server"
const _DEV := "/Users/dev/godot-mcp-server/dist/index.js"


static func run(testing) -> void:
	_test_macos_release(testing)
	_test_macos_dev(testing)
	_test_windows_release(testing)
	_test_windows_dev(testing)
	_test_linux_release(testing)
	_test_linux_dev(testing)
	_test_unknown_os_defaults_linux(testing)
	_test_refresh_preserves_user_env(testing)
	_test_env_first_create_uses_template(testing)
	_test_env_merge_is_pure(testing)


# macOS release: bare npx — same shape as Linux. A GUI-launched client resolves the
# bare npx to a version-manager node via its captured shell env; no env is emitted.
static func _test_macos_release(testing) -> void:
	testing.begin("build_server_entry — macOS release (bare npx)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("macOS", "")
	testing.eq(str(entry["command"]), "npx", "command = npx")
	var args: Array = entry["args"]
	testing.eq(args.size(), 2, "release args length 2")
	testing.eq(str(args[0]), "-y", "release arg 0 = -y")
	testing.eq(str(args[1]), _PKG, "release arg 1 = package")
	testing.ok(not entry.has("env"), "builder emits no env")
	print("")


# macOS dev: bare node runs the local dist entry (a GODOT_MCP_DEV_SERVER_PATH override).
static func _test_macos_dev(testing) -> void:
	testing.begin("build_server_entry — macOS dev (node dist)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("macOS", _DEV)
	testing.eq(str(entry["command"]), "node", "command = node")
	var args: Array = entry["args"]
	testing.eq(args.size(), 1, "dev args length 1")
	testing.eq(str(args[0]), _DEV, "dev arg = dist entry")
	testing.ok(not entry.has("env"), "builder emits no env")
	print("")


# Windows release: cmd /c npx (npx is a .cmd shim); no env emitted.
static func _test_windows_release(testing) -> void:
	testing.begin("build_server_entry — Windows release (cmd /c npx)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("Windows", "")
	testing.eq(str(entry["command"]), "cmd", "command = cmd")
	var args: Array = entry["args"]
	testing.eq(args.size(), 4, "cmd args length 4")
	testing.eq(str(args[0]), "/c", "arg 0 = /c")
	testing.eq(str(args[1]), "npx", "arg 1 = npx")
	testing.eq(str(args[2]), "-y", "arg 2 = -y")
	testing.eq(str(args[3]), _PKG, "arg 3 = package")
	testing.ok(not entry.has("env"), "builder emits no env")
	print("")


# Windows dev: node runs the dist entry directly (node is a real exe on PATH).
static func _test_windows_dev(testing) -> void:
	testing.begin("build_server_entry — Windows dev (node dist)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("Windows", "C:/x/dist/index.js")
	testing.eq(str(entry["command"]), "node", "command = node")
	var args: Array = entry["args"]
	testing.eq(args.size(), 1, "dev args length 1")
	testing.eq(str(args[0]), "C:/x/dist/index.js", "dev arg = dist entry")
	print("")


# Linux release: bare npx (no shim).
static func _test_linux_release(testing) -> void:
	testing.begin("build_server_entry — Linux release (bare npx)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("Linux", "")
	testing.eq(str(entry["command"]), "npx", "command = npx")
	var args: Array = entry["args"]
	testing.eq(str(args[0]), "-y", "arg 0 = -y")
	testing.eq(str(args[1]), _PKG, "arg 1 = package")
	testing.ok(not entry.has("env"), "builder emits no env")
	print("")


# Linux dev: bare node + dist.
static func _test_linux_dev(testing) -> void:
	testing.begin("build_server_entry — Linux dev (node dist)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("Linux", _DEV)
	testing.eq(str(entry["command"]), "node", "command = node")
	var args: Array = entry["args"]
	testing.eq(str(args[0]), _DEV, "dev arg = dist entry")
	print("")


# An unknown OS falls through to the Linux-style bare command (safe default).
static func _test_unknown_os_defaults_linux(testing) -> void:
	testing.begin("build_server_entry — unknown OS defaults to Linux shape")
	var release: Dictionary = MCPJsonSync.build_server_entry("Haiku", "")
	testing.eq(str(release["command"]), "npx", "unknown OS release = bare npx")
	var dev: Dictionary = MCPJsonSync.build_server_entry("Haiku", _DEV)
	testing.eq(str(dev["command"]), "node", "unknown OS dev = bare node")
	print("")


# Merging an existing file's env over the template base preserves the user's own
# GODOT_MCP_* keys (a port pin here) while keeping the template's config version —
# the layering _build_entry does on every rewrite.
static func _test_refresh_preserves_user_env(testing) -> void:
	testing.begin("merge_server_env — preserves user keys over the template base")
	var template_env := {"GODOT_MCP_CONFIG_VERSION": "1"}
	var existing_env := {"GODOT_MCP_CONFIG_VERSION": "1", "GODOT_MCP_EDITOR_PORT": "6560"}
	var env: Dictionary = MCPJsonSync.merge_server_env(template_env, existing_env)
	testing.eq(str(env.get("GODOT_MCP_EDITOR_PORT", "")), "6560", "user port pin preserved")
	testing.eq(str(env.get("GODOT_MCP_CONFIG_VERSION", "")), "1", "config version present")
	print("")


# A first-time create (no existing file → {} existing env) uses the template base
# alone — GODOT_MCP_CONFIG_VERSION, no stray keys.
static func _test_env_first_create_uses_template(testing) -> void:
	testing.begin("merge_server_env — first create uses template base")
	var env: Dictionary = MCPJsonSync.merge_server_env({"GODOT_MCP_CONFIG_VERSION": "1"}, {})
	testing.eq(str(env.get("GODOT_MCP_CONFIG_VERSION", "")), "1", "config version from template")
	testing.eq(env.size(), 1, "no extra keys on first create")
	print("")


# The merge is pure: neither input is mutated.
static func _test_env_merge_is_pure(testing) -> void:
	testing.begin("merge_server_env — does not mutate inputs")
	var base := {"GODOT_MCP_CONFIG_VERSION": "1"}
	var existing := {"GODOT_MCP_EDITOR_PORT": "6560"}
	MCPJsonSync.merge_server_env(base, existing)
	testing.eq(base.size(), 1, "base env not mutated")
	testing.eq(existing.size(), 1, "existing env not mutated")
	print("")
