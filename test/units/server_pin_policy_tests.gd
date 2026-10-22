@tool
extends RefCounted
## Pinning tests for the server-pin policy: the setting key and the mode, spec and
## nudge words its callers compare against, the package spec each kind of setting
## value resolves to, the classification of every entry shape, the nudge for each
## drift case, and the setting read. Each row is the policy's observable output.

const ServerPinPolicy := preload("res://addons/godot_mcp_toolkit/ui/mcp_json/server_pin_policy.gd")

const _PKG := "@npgamedev/godot-mcp-server"
const _COMPATIBLE := "1.0.4"
const _LOCAL := "/Users/dev/godot-mcp-server/dist/index.js"


static func run(testing) -> void:
	_test_policy_words(testing)
	_test_package_spec_table(testing)
	_test_classification_table(testing)
	_test_nudge_table(testing)
	_test_read_version_setting(testing)


# The key lands in project.godot and callers store and compare the words, so each
# value is part of the policy's surface.
static func _test_policy_words(testing) -> void:
	testing.begin("Server pin policy: the setting key and its words")
	testing.eq(ServerPinPolicy.SERVER_VERSION_SETTING, "mcp_toolkit/server/version", "the setting key")
	testing.eq(ServerPinPolicy.LATEST_SETTING_VALUE, "latest", "the latest value")
	testing.eq([ServerPinPolicy.MODE_PINNED, ServerPinPolicy.MODE_LATEST, ServerPinPolicy.MODE_CUSTOM],
			["pinned", "latest", "custom"], "the pin modes")
	testing.eq([ServerPinPolicy.SPEC_NPX_BARE, ServerPinPolicy.SPEC_NPX_PREFIX,
			ServerPinPolicy.SPEC_LOCAL_PREFIX, ServerPinPolicy.SPEC_UNKNOWN],
			["npx-bare", "npx:", "local:", "unknown"], "the spec classifications")
	testing.eq([ServerPinPolicy.NUDGE_NONE, ServerPinPolicy.NUDGE_UNPINNED,
			ServerPinPolicy.NUDGE_DIFFERS, ServerPinPolicy.NUDGE_FOREIGN],
			["none", "unpinned", "differs", "foreign"], "the nudge states")
	print("")


# Each row: the setting value, its pin mode, the package spec it resolves to.
static func _test_package_spec_table(testing) -> void:
	testing.begin("Server pin policy: setting value → mode and package spec")
	var rows := [
		["", "pinned", _PKG + "@1.0.4"],
		["   ", "pinned", _PKG + "@1.0.4"],
		["latest", "latest", _PKG + "@latest"],
		["\tLATEST\n", "latest", _PKG + "@latest"],
		["1.0.5", "custom", _PKG + "@1.0.5"],
		["  1.1.0-beta.1  ", "custom", _PKG + "@1.1.0-beta.1"],
		["^1.0.0", "custom", _PKG + "@^1.0.0"],
		["next", "custom", _PKG + "@next"],
		["latest-ish", "custom", _PKG + "@latest-ish"],
	]
	for row in rows:
		var setting := str(row[0])
		var label := JSON.stringify(setting)
		testing.eq(ServerPinPolicy.pin_mode(setting), str(row[1]), "%s → mode %s" % [label, row[1]])
		testing.eq(ServerPinPolicy.resolve_package_spec(setting, _COMPATIBLE), str(row[2]),
				"%s → %s" % [label, row[2]])
	testing.ok(ServerPinPolicy.is_exact_spec(ServerPinPolicy.resolve_package_spec("", _COMPATIBLE)),
			"the pinned spec is exact")
	testing.ok(not ServerPinPolicy.is_exact_spec("@1.0.4"), "a spec with no package name is not exact")
	testing.ok(not ServerPinPolicy.is_exact_spec(_PKG + "@1.0"), "a two-part version is not exact")
	print("")


# Each row: an entry as .mcp.json holds it, its classification.
static func _test_classification_table(testing) -> void:
	testing.begin("Server pin policy: entry → classification")
	var rows := [
		[{"command": "npx", "args": ["-y", _PKG]}, "npx-bare"],
		[{"command": "npx", "args": [_PKG + "@1.0.4"]}, "npx:1.0.4"],
		[{"command": "npx", "args": ["-y", _PKG + "@^1.0.0"]}, "npx:^1.0.0"],
		[{"command": "cmd", "args": ["/c", "npx", "-y", _PKG + "@latest"]}, "npx:latest"],
		[{"command": "npx", "args": ["-y", _PKG + "@"]}, "npx:"],
		[{"command": "npx", "args": ["-y", "other-package@1.0.4"]}, "unknown"],
		[{"command": "npx", "args": [_PKG, "--flag"]}, "unknown"],
		[{"command": "node", "args": [_LOCAL]}, "local:" + _LOCAL],
		[{"command": "node", "args": [_LOCAL, "--x"]}, "unknown"],
		[{"command": "node", "args": "not an array"}, "unknown"],
		[{"command": "npx"}, "unknown"],
		[{"args": ["-y", _PKG]}, "unknown"],
		[[], "unknown"],
		[null, "unknown"],
	]
	for row in rows:
		testing.eq(ServerPinPolicy.classify_server_entry(row[0]), str(row[1]),
				"%s → %s" % [JSON.stringify(row[0]), row[1]])
	testing.eq(ServerPinPolicy.desired_classification(" Latest ", _COMPATIBLE, ""), "npx:latest",
			"desired: a trimmed latest")
	testing.eq(ServerPinPolicy.desired_classification("", _COMPATIBLE, _LOCAL), "local:" + _LOCAL,
			"desired: a local path wins over the pin")
	testing.ok(ServerPinPolicy.same_spec("local:" + _LOCAL, "local:" + _LOCAL), "same local path → same spec")
	testing.ok(not ServerPinPolicy.same_spec("npx:latest", "npx:next"), "two tags differ")
	testing.ok(not ServerPinPolicy.same_spec("unknown", "npx-bare"), "unknown is not the bare form")
	print("")


# Each row: the spec on disk, the last-written record, the desired spec, the nudge.
static func _test_nudge_table(testing) -> void:
	testing.begin("Server pin policy: on disk, record, desired → nudge")
	var rows := [
		["npx-bare", "", "npx:1.1.0-beta.1", "unpinned"],
		["npx-bare", "", "npx:~1.1.0", "differs"],
		["npx-bare", "npx-bare", "npx:1.0.4", "unpinned"],
		["npx:latest", "", "npx:1.0.4", "foreign"],
		["npx:latest", "npx:latest", "npx:next", "differs"],
		["npx:1.0.4", "npx:1.0.4", "local:" + _LOCAL, "differs"],
		["local:" + _LOCAL, "local:" + _LOCAL, "npx:1.0.4", "differs"],
		["local:/other/index.js", "local:" + _LOCAL, "local:" + _LOCAL, "foreign"],
		["npx:latest", "npx-bare", "npx-bare", "none"],
		["unknown", "", "npx:1.0.4", "none"],
	]
	for row in rows:
		testing.eq(ServerPinPolicy.nudge_state(str(row[0]), str(row[1]), str(row[2])), str(row[3]),
				"%s / record %s / desired %s → %s" % [row[0], JSON.stringify(str(row[1])), row[2], row[3]])
	print("")


# The read goes through ProjectSettings in memory only; the previous value is put
# back before any check runs, so a failure leaves the project settings as they were.
static func _test_read_version_setting(testing) -> void:
	testing.begin("Server pin policy: the setting read")
	var key: String = ServerPinPolicy.SERVER_VERSION_SETTING
	var had_value: bool = ProjectSettings.has_setting(key)
	var previous: Variant = ProjectSettings.get_setting(key) if had_value else null
	ProjectSettings.set_setting(key, " next ")
	var read_custom: String = ServerPinPolicy.read_version_setting()
	ProjectSettings.set_setting(key, null)
	var read_unset: String = ServerPinPolicy.read_version_setting()
	if had_value:
		ProjectSettings.set_setting(key, previous)
	testing.eq(read_custom, " next ", "a set value is read as stored, untrimmed")
	testing.eq(read_unset, "", "an unset key reads as \"\"")
	print("")
