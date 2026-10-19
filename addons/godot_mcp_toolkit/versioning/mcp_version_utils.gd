@tool
extends RefCounted
## Version helpers: engine-version comparison plus the addon's own plugin version.
##
## Provides is_at_least / is_at_most / is_version_in_range checks against
## the running engine version, used to gate commands by their min/max Godot
## version requirements, in_place_reload_safe() which says whether a script can be
## reloaded in place on this engine, read_plugin_version() which reads the toolkit's
## own plugin.cfg, version_skew() which classifies how the plugin's version
## differs from the connected server's, floor_verdict() which judges a version against
## a declared major.minor floor, the server version the toolkit pins, and the lowest
## server version it works with.

## Latest version tested. Versions above this still run but log a notice.
const GODOT_TESTED_MAX_VERSION := "4.7.0"

## The server version this toolkit was tested with. "Write .mcp.json" pins the
## server to it unless the project's [code]mcp_toolkit/server/version[/code] setting
## asks for another. [code]scripts/release.sh --compatible-server[/code] checks that
## npm has the version before it rewrites this constant;
## [code]--keep-compatible-server[/code] keeps the current value (a hand edit skips
## the npm check). The CI launch job flags a pin that does not resolve.
const COMPATIBLE_SERVER_VERSION := "1.0.4"

## The lowest MCP server version (major.minor) this toolkit works with: its declared
## floor (ADR 0024), sent to the server as [code]min_server[/code] in the auth reply.
## Raise it only when the toolkit depends on a newer server wire contract; that raise
## is a MAJOR bump, since it drops older servers.
const MIN_SERVER_VERSION := "1.0"

# A strict major.minor[.patch] version with an optional -prerelease or +build suffix:
# the grammar the MCP server parses floors with, so both sides judge a version alike.
const _MAJOR_MINOR_PATTERN := "^(\\d+)\\.(\\d+)(?:\\.\\d+)?(?:[-+][0-9A-Za-z.-]+)?$"


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


## Whether the running engine can reload a script in place: every version but Godot 4.2.0
## and 4.2.1 (see [method reload_frees_held_lambdas]). Where it cannot, the toolkit's
## write, undo, redo and [code]node_set_script[/code] paths leave a changed script for an
## editor restart to load.
static func in_place_reload_safe() -> bool:
	return not reload_frees_held_lambdas(Engine.get_version_info())


## Whether the engine described by [param version_info] (the shape of
## [code]Engine.get_version_info()[/code]) is one where reloading a script in place is
## unsafe. On Godot 4.2.0 and 4.2.1 an in-place reload frees the code of the script's
## lambdas while a Callable held elsewhere (a signal connection, a command registry) still
## points at it, and the next call crashes the editor; 4.2.2 and 4.3 fixed it. Pure, so the
## version boundary can be unit-tested.
static func reload_frees_held_lambdas(version_info: Dictionary) -> bool:
	return (int(version_info.get("major", 0)) == 4 and int(version_info.get("minor", 0)) == 2
			and int(version_info.get("patch", 0)) < 2)


## The toolkit's own version string, read from its plugin.cfg.
## Returns "unknown" if the config can't be loaded.
static func read_plugin_version() -> String:
	var cfg := ConfigFile.new()
	var err := cfg.load("res://addons/godot_mcp_toolkit/plugin.cfg")
	if err != OK:
		return "unknown"
	return cfg.get_value("plugin", "version", "unknown")


## Classifies how the plugin's version differs from the connected server's.
##
## Compares [param local] with [param remote]. Pure — the caller decides what, if
## anything, to print. A patch difference is compatible by construction: compatibility
## floors are declared at major.minor (ADR 0024), so the patch segment carries no
## compatibility meaning. The returned names match the MCP server's own severity
## vocabulary, so both halves of the handshake speak one language.
## [br]
## Returns "ok", "patch", "minor" or "major", or "unknown" when either side is not
## exactly three dot-separated integers.
static func version_skew(local: String, remote: String) -> String:
	var a := _parse_strict(local)
	var b := _parse_strict(remote)
	if a.is_empty() or b.is_empty():
		return "unknown"
	if a[0] != b[0]:
		return "major"
	if a[1] != b[1]:
		return "minor"
	if a[2] != b[2]:
		return "patch"
	return "ok"


## Returns [param v]'s segments as [major, minor, patch], or an empty array when it is
## not exactly three integers. Distinct from _parse, which pads a two-segment engine
## version and is therefore too lenient for a plugin-versus-server comparison.
static func _parse_strict(v: String) -> Array[int]:
	var parts := v.strip_edges().split(".")
	if parts.size() != 3:
		return []
	var out: Array[int] = []
	for part in parts:
		if not part.is_valid_int():
			return []
		out.append(int(part))
	return out


## The major and minor of [param v] as [code]Vector2i(major, minor)[/code], when it is a
## strict [code]major.minor[/code] or [code]major.minor.patch[/code] version, optionally
## followed by a [code]-prerelease[/code] or [code]+build[/code] suffix.
## [br]
## Returns [code]Vector2i(-1, -1)[/code] for anything else: empty, non-numeric, a bare
## major, or more than three numeric parts. Unlike [method is_at_least], it never reads
## malformed text as 0, which would make it "below" every floor.
static func parse_major_minor(v: String) -> Vector2i:
	var regex := RegEx.new()
	regex.compile(_MAJOR_MINOR_PATTERN)
	var found := regex.search(v.strip_edges())
	if found == null:
		return Vector2i(-1, -1)
	return Vector2i(int(found.get_string(1)), int(found.get_string(2)))


## Judges [param peer] against the declared major.minor [param floor_version]; the
## patch segment is ignored. Pure and advisory: the caller decides what to print, and
## nothing refuses a connection.
## [br]
## Returns "ok" or "below", or "unknown" when either side does not parse (see
## [method parse_major_minor]), so the caller falls through to its product-version check.
static func floor_verdict(peer: String, floor_version: String) -> String:
	var peer_pair := parse_major_minor(peer)
	var floor_pair := parse_major_minor(floor_version)
	if peer_pair.x < 0 or floor_pair.x < 0:
		return "unknown"
	if peer_pair.x != floor_pair.x:
		return "ok" if peer_pair.x > floor_pair.x else "below"
	return "ok" if peer_pair.y >= floor_pair.y else "below"


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
