@tool
extends RefCounted
## Version helpers: engine-version comparison plus the addon's own plugin version.
##
## Provides is_at_least / is_at_most / is_version_in_range checks against
## the running engine version, used to gate commands by their min/max Godot
## version requirements, plus read_plugin_version() which reads the toolkit's
## own plugin.cfg.

## Latest version tested. Versions above this still run but log a notice.
const GODOT_TESTED_MAX_VERSION := "4.7.0"


## True when running under `godot --headless` (no display server).
## Use to gate tools that require a viewport or running game.
static func is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


static func get_engine_version_pair() -> String:
	var info := Engine.get_version_info()
	return "%d.%d" % [info["major"], info["minor"]]


## True when the running engine's "major.minor" pair equals [param target]
## (e.g. "4.2" — matched exactly, so every 4.2.x patch release is caught and a
## future 5.2 is not). For the exact-one-minor case only; version ranges use
## [method is_at_least] / [method is_at_most].
static func is_engine_version_pair(target: String) -> bool:
	return get_engine_version_pair() == target


## The running engine's major/minor as an int pair — [code]Vector2i(major, minor)[/code]
## ([code].x[/code] = major, [code].y[/code] = minor). For decision predicates that take
## the version as plain data (e.g. the stale-live-instance hint feed); the same pair as a
## string is [method get_engine_version_pair].
static func get_engine_version_ints() -> Vector2i:
	var info := Engine.get_version_info()
	return Vector2i(int(info["major"]), int(info["minor"]))


## The toolkit's own version string, read from its plugin.cfg.
## Returns "unknown" if the config can't be loaded.
static func read_plugin_version() -> String:
	var cfg := ConfigFile.new()
	var err := cfg.load("res://addons/godot_mcp_toolkit/plugin.cfg")
	if err != OK:
		return "unknown"
	return cfg.get_value("plugin", "version", "unknown")


static func is_at_least(engine_ver: String, min_ver: String) -> bool:
	return _compare(_parse(engine_ver), _parse(min_ver)) >= 0


static func is_at_most(engine_ver: String, max_ver: String) -> bool:
	return _compare(_parse(engine_ver), _parse(max_ver)) <= 0


static func is_version_in_range(engine_ver: String, min_ver: String, max_ver: String) -> bool:
	var engine := _parse(engine_ver)
	if min_ver != "" and _compare(engine, _parse(min_ver)) < 0:
		return false
	if max_ver != "" and _compare(engine, _parse(max_ver)) > 0:
		return false
	return true


static func _parse(v: String) -> Array[int]:
	var parts := v.split(".")
	return [int(parts[0]) if parts.size() > 0 else 0,
			int(parts[1]) if parts.size() > 1 else 0]


static func _compare(a: Array[int], b: Array[int]) -> int:
	if a[0] != b[0]:
		return a[0] - b[0]
	return a[1] - b[1]
