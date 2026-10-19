@tool
extends RefCounted
## Unit tests for the server pin in .mcp.json: the pure helpers in MCPJsonSync that
## turn the project's server-version setting and the machine's local server path
## into the entry a write emits (resolve_package_spec, resolve_dev_server_path,
## is_exact_spec, apply_owned_env), the classification of an entry already on disk
## (classify_server_entry, same_spec, desired_classification), the dock's nudge
## decision (nudge_state) and the row it paints from it, and the disable-time
## cleanup list carrying the local-path editor setting.

const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")
const DisableCleanupCoordinator := preload("res://addons/godot_mcp_toolkit/core/disable_cleanup_coordinator.gd")
const DockMcpJsonPanel := preload("res://addons/godot_mcp_toolkit/ui/dock/mcp/dock_mcp_json_panel.gd")

const _PKG := "@npgamedev/godot-mcp-server"
const _COMPATIBLE := "1.0.4"
const _LOCAL := "/Users/dev/godot-mcp-server/dist/index.js"
const _PREFER_OFFLINE := "npm_config_prefer_offline"


static func run(testing) -> void:
	_test_resolve_package_spec(testing)
	_test_resolve_dev_server_path(testing)
	_test_is_exact_spec(testing)
	_test_apply_owned_env(testing)
	_test_classify_server_entry(testing)
	_test_same_spec(testing)
	_test_desired_classification(testing)
	_test_nudge_state(testing)
	_test_dock_pin_row_state(testing)
	_test_cleanup_list_carries_local_path(testing)


# The setting picks the mode: empty pins the compatible version, "latest" (trimmed,
# any case) floats, anything else is passed through as the npm spec.
static func _test_resolve_package_spec(testing) -> void:
	testing.begin("resolve_package_spec — pinned, latest and custom")
	testing.eq(MCPJsonSync.resolve_package_spec("", _COMPATIBLE), _PKG + "@1.0.4", "empty = pinned to compatible")
	testing.eq(MCPJsonSync.resolve_package_spec("latest", _COMPATIBLE), _PKG + "@latest", "latest")
	testing.eq(MCPJsonSync.resolve_package_spec(" Latest ", _COMPATIBLE), _PKG + "@latest", "trimmed, any case")
	testing.eq(MCPJsonSync.resolve_package_spec("1.0.5", _COMPATIBLE), _PKG + "@1.0.5", "custom exact version")
	testing.eq(MCPJsonSync.resolve_package_spec("~1.1.0", _COMPATIBLE), _PKG + "@~1.1.0", "custom range")
	testing.eq(MCPJsonSync.resolve_package_spec("next", _COMPATIBLE), _PKG + "@next", "custom tag")
	testing.eq(MCPJsonSync.pin_mode(""), MCPJsonSync.MODE_PINNED, "empty setting = pinned mode")
	testing.eq(MCPJsonSync.pin_mode(" LATEST"), MCPJsonSync.MODE_LATEST, "latest setting = latest mode")
	testing.eq(MCPJsonSync.pin_mode("next"), MCPJsonSync.MODE_CUSTOM, "other setting = custom mode")
	print("")


# The machine's setting wins over the environment variable; neither means the npm package.
static func _test_resolve_dev_server_path(testing) -> void:
	testing.begin("resolve_dev_server_path — setting, env fallback, neither")
	testing.eq(MCPJsonSync.resolve_dev_server_path(_LOCAL, "/env/dist/index.js"), _LOCAL, "setting wins")
	testing.eq(MCPJsonSync.resolve_dev_server_path("", "/env/dist/index.js"), "/env/dist/index.js", "env fallback")
	testing.eq(MCPJsonSync.resolve_dev_server_path("", ""), "", "neither = npm package")
	print("")


static func _test_is_exact_spec(testing) -> void:
	testing.begin("is_exact_spec — only an exact version")
	testing.ok(MCPJsonSync.is_exact_spec(_PKG + "@1.0.4"), "1.0.4 is exact")
	testing.ok(MCPJsonSync.is_exact_spec(_PKG + "@1.1.0-beta.1"), "a prerelease is exact")
	testing.ok(not MCPJsonSync.is_exact_spec(_PKG + "@latest"), "latest is not")
	testing.ok(not MCPJsonSync.is_exact_spec(_PKG + "@~1.1.0"), "a range is not")
	testing.ok(not MCPJsonSync.is_exact_spec(_PKG + "@next"), "a tag is not")
	testing.ok(not MCPJsonSync.is_exact_spec(_PKG), "the bare package is not")
	print("")


# prefer-offline rides only with an exact version; any floating spec or a local
# build drops it, including a stale "true" an earlier pinned write left behind.
static func _test_apply_owned_env(testing) -> void:
	testing.begin("apply_owned_env — prefer-offline only for an exact version")
	var base := {"GODOT_MCP_CONFIG_VERSION": "1"}
	var pinned: Dictionary = MCPJsonSync.apply_owned_env(base, _PKG + "@1.0.4", "")
	testing.eq(str(pinned.get(_PREFER_OFFLINE, "")), "true", "pinned adds prefer-offline")
	testing.eq(str(pinned.get("GODOT_MCP_CONFIG_VERSION", "")), "1", "other keys kept")
	testing.ok(not base.has(_PREFER_OFFLINE), "input not mutated")
	var stale := {"GODOT_MCP_CONFIG_VERSION": "1", _PREFER_OFFLINE: "true"}
	var floating_specs := [_PKG + "@latest", _PKG + "@~1.1.0", _PKG + "@next"]
	for spec in floating_specs:
		var env: Dictionary = MCPJsonSync.apply_owned_env(stale, str(spec), "")
		testing.ok(not env.has(_PREFER_OFFLINE), "%s removes a stale prefer-offline" % spec)
	var local: Dictionary = MCPJsonSync.apply_owned_env(stale, _PKG + "@1.0.4", _LOCAL)
	testing.ok(not local.has(_PREFER_OFFLINE), "a local path removes it")
	print("")


static func _test_classify_server_entry(testing) -> void:
	testing.begin("classify_server_entry — npx, cmd, node and unknown shapes")
	testing.eq(MCPJsonSync.classify_server_entry({"command": "npx", "args": ["-y", _PKG]}), "npx-bare", "bare")
	testing.eq(MCPJsonSync.classify_server_entry({"command": "npx", "args": ["-y", _PKG + "@latest"]}),
			"npx:latest", "@latest")
	testing.eq(MCPJsonSync.classify_server_entry({"command": "npx", "args": ["-y", _PKG + "@1.0.4"]}),
			"npx:1.0.4", "@1.0.4")
	testing.eq(MCPJsonSync.classify_server_entry({"command": "npx", "args": ["-y", _PKG + "@~1.1.0"]}),
			"npx:~1.1.0", "@~1.1.0")
	testing.eq(MCPJsonSync.classify_server_entry({"command": "cmd", "args": ["/c", "npx", "-y", _PKG + "@1.0.4"]}),
			"npx:1.0.4", "Windows cmd /c npx classifies like npx")
	testing.eq(MCPJsonSync.classify_server_entry({"command": "cmd", "args": ["/c", "npx", "-y", _PKG]}),
			"npx-bare", "Windows bare")
	testing.eq(MCPJsonSync.classify_server_entry({"command": "node", "args": [_LOCAL]}), "local:" + _LOCAL, "node path")
	testing.eq(MCPJsonSync.classify_server_entry({"command": "node", "args": ["C:/x/dist/index.js"]}),
			"local:C:/x/dist/index.js", "node Windows path")
	testing.eq(MCPJsonSync.classify_server_entry({}), "unknown", "{} = unknown")
	testing.eq(MCPJsonSync.classify_server_entry({"command": "npx", "args": []}), "unknown", "no args = unknown")
	testing.eq(MCPJsonSync.classify_server_entry({"command": "godot-mcp-server", "args": ["--x"]}), "unknown",
			"another command = unknown")
	testing.eq(MCPJsonSync.classify_server_entry("not a dict"), "unknown", "not an object = unknown")
	print("")


static func _test_same_spec(testing) -> void:
	testing.begin("same_spec — equal, or bare and @latest alike")
	testing.ok(MCPJsonSync.same_spec("npx:1.0.4", "npx:1.0.4"), "equal")
	testing.ok(MCPJsonSync.same_spec("npx-bare", "npx:latest"), "bare ~ latest")
	testing.ok(MCPJsonSync.same_spec("npx:latest", "npx-bare"), "latest ~ bare")
	testing.ok(not MCPJsonSync.same_spec("npx-bare", "npx:1.0.4"), "bare != pinned")
	testing.ok(not MCPJsonSync.same_spec("npx:1.0.3", "npx:1.0.4"), "two versions differ")
	print("")


static func _test_desired_classification(testing) -> void:
	testing.begin("desired_classification — local path, else the resolved spec")
	testing.eq(MCPJsonSync.desired_classification("", _COMPATIBLE, ""), "npx:1.0.4", "pinned")
	testing.eq(MCPJsonSync.desired_classification("latest", _COMPATIBLE, ""), "npx:latest", "latest")
	testing.eq(MCPJsonSync.desired_classification("next", _COMPATIBLE, ""), "npx:next", "custom")
	testing.eq(MCPJsonSync.desired_classification("latest", _COMPATIBLE, _LOCAL), "local:" + _LOCAL,
			"a local path wins over any mode")
	print("")


# The nudge: toolkit-written files that drifted get an offer (amber), a hand-set
# spec gets a quiet one, and a match or an unreadable file gets nothing.
static func _test_nudge_state(testing) -> void:
	testing.begin("nudge_state — unpinned, differs, foreign and none")
	testing.eq(MCPJsonSync.nudge_state("npx-bare", "", "npx:1.0.4"), "unpinned",
			"bare on disk + no record + pinned desired = unpinned")
	testing.eq(MCPJsonSync.nudge_state("npx:latest", "npx:latest", "npx:1.0.4"), "unpinned",
			"recorded latest + pinned desired = unpinned")
	testing.eq(MCPJsonSync.nudge_state("npx:1.0.3", "npx:1.0.3", "npx:1.0.4"), "differs",
			"recorded 1.0.3 on disk + 1.0.4 desired = differs")
	testing.eq(MCPJsonSync.nudge_state("npx:1.0.0", "", "npx:1.0.4"), "foreign", "unrecorded 1.0.0 = foreign")
	testing.eq(MCPJsonSync.nudge_state("npx:1.0.0", "npx:1.0.4", "npx:1.0.4"), "foreign",
			"recorded elsewhere = foreign")
	testing.eq(MCPJsonSync.nudge_state("npx-bare", "", "npx:latest"), "none", "desired latest + bare on disk = none")
	testing.eq(MCPJsonSync.nudge_state("local:" + _LOCAL, "", "local:" + _LOCAL), "none",
			"desired local + same path = none")
	testing.eq(MCPJsonSync.nudge_state("npx:1.0.4", "npx:1.0.4", "npx:1.0.4"), "none", "on disk matches = none")
	testing.eq(MCPJsonSync.nudge_state("unknown", "npx:1.0.4", "npx:1.0.4"), "none", "unknown = none")
	print("")


# The dock row's text, button and colour per state; the button's action is what
# the harness presses by name.
static func _test_dock_pin_row_state(testing) -> void:
	testing.begin("dock pin row — one row per nudge and mode")
	var pinned: Dictionary = DockMcpJsonPanel.pin_row_state("npx:1.0.4", "npx:1.0.4", "npx:1.0.4", "", _COMPATIBLE)
	testing.eq(str(pinned["text"]), "Server: 1.0.4 (pinned)", "pinned text")
	testing.eq(str(pinned["button"]), "Use latest", "pinned offers latest")
	testing.ok(not bool(pinned["amber"]), "pinned is grey")
	var latest: Dictionary = DockMcpJsonPanel.pin_row_state("npx:latest", "npx:latest", "npx:latest", "latest", _COMPATIBLE)
	testing.eq(str(latest["button"]), "Pin to 1.0.4", "latest offers the pin")
	var custom: Dictionary = DockMcpJsonPanel.pin_row_state("npx:next", "npx:next", "npx:next", "next", _COMPATIBLE)
	testing.eq(str(custom["text"]), "Server: next (custom, Project Settings)", "custom names the setting")
	var unpinned: Dictionary = DockMcpJsonPanel.pin_row_state("npx-bare", "", "npx:1.0.4", "", _COMPATIBLE)
	testing.eq(str(unpinned["button"]), "Pin to 1.0.4", "unpinned offers the pin")
	testing.ok(bool(unpinned["amber"]), "unpinned is amber")
	var differs: Dictionary = DockMcpJsonPanel.pin_row_state("npx:1.0.3", "npx:1.0.3", "npx:1.0.4", "", _COMPATIBLE)
	testing.eq(str(differs["button"]), "Update to 1.0.4", "differs offers the update")
	testing.ok(bool(differs["amber"]), "differs is amber")
	var foreign: Dictionary = DockMcpJsonPanel.pin_row_state("npx:1.0.0", "", "npx:1.0.4", "", _COMPATIBLE)
	testing.eq(str(foreign["text"]), "Server spec set by hand (1.0.0).", "foreign names the spec")
	testing.eq(str(foreign["button"]), "Restore recommended (1.0.4)", "foreign offers the restore")
	testing.ok(not bool(foreign["amber"]), "foreign is grey")
	var local: Dictionary = DockMcpJsonPanel.pin_row_state("npx:1.0.4", "npx:1.0.4", "local:" + _LOCAL, "", _COMPATIBLE)
	testing.eq(str(local["button"]), "", "a local build hides the button")
	testing.ok(bool(local["amber"]) and str(local["text"]).contains("not in .mcp.json yet"),
			"a local build missing from the file is amber")
	print("")


static func _test_cleanup_list_carries_local_path(testing) -> void:
	testing.begin("disable cleanup — erases the local-path editor setting")
	testing.ok("mcp_toolkit/server/local_path" in DisableCleanupCoordinator._EDITOR_SETTING_KEYS,
			"mcp_toolkit/server/local_path is in the cleanup list")
	print("")
