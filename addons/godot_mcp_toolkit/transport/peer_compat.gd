@tool
extends RefCounted
## The connected MCP server's compatibility verdict: whether either side is below the
## other's declared major.minor floor (ADR 0024), the below-floor wording, and which
## below-floor errors have already printed.
##
## The editor server facade owns the trigger points (judge on auth, clear on the last
## disconnect), the compat_status_changed signal the dock binds, and the console output;
## this child owns the judgement and the verdict store. The product-version message for
## a server that passes the floors stays with the facade. Advisory only: nothing here
## refuses a connection.

const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")

## The verdict states get_verdict() reports in its "state" key: no authenticated peer;
## no floor check flagged a side (this includes an unparsable or missing version or
## floor, which leaves the product-version message to decide); a skipped check (local
## server build); and a side below the other's declared floor.
const STATE_NONE := ""
const STATE_OK := "ok"
const STATE_SKIPPED := "skipped"
const STATE_SERVER_BELOW_FLOOR := "server_below_floor"
const STATE_TOOLKIT_BELOW_FLOOR := "toolkit_below_floor"
## The info line for a skipped check, without its log prefix.
const SKIPPED_LINE := "Version check skipped (local server path)."

# The last authenticated MCP server's verdict, in the get_verdict() shape; back to
# STATE_NONE when the last peer disconnects.
var _verdict: Dictionary = make_verdict(STATE_NONE, "", "", "")
# The "<state>|<server version>" pairs whose below-floor error has already printed. Kept
# for the editor session, so a server that keeps reconnecting prints each one once.
var _warned: Dictionary = {}


## Judges a server that just authenticated, reporting [param server_ver] and declaring
## [param min_toolkit] ("" when it declares none), against this toolkit at
## [param toolkit_ver] with its own server floor [param min_server], and records the
## verdict get_verdict() returns. With [param skip] set (a local server build) it
## records STATE_SKIPPED without judging.
##
## Returns the line to print, without its log prefix: SKIPPED_LINE on every skipped
## check, the below-floor error the first time a (state, server version) pair is seen,
## else "". On STATE_OK the caller runs its product-version message instead.
func assess(server_ver: String, min_toolkit: String, toolkit_ver: String, min_server: String, skip: bool) -> String:
	if skip:
		_verdict = make_verdict(STATE_SKIPPED, server_ver, min_toolkit, "")
		return SKIPPED_LINE
	_verdict = judge_floors(server_ver, min_toolkit, toolkit_ver, min_server)
	var state := str(_verdict["state"])
	if state == STATE_OK:
		return ""
	var warned_key := "%s|%s" % [state, server_ver]
	if _warned.has(warned_key):
		return ""
	_warned[warned_key] = true
	return str(_verdict["message"])


## Drops the recorded verdict once no MCP server is connected. The once-per-session
## record of printed errors stays.
func clear() -> void:
	_verdict = make_verdict(STATE_NONE, "", "", "")


## The recorded verdict, for the dock. Returns { "state": String, "server_version":
## String, "min_toolkit": String, "message": String }: state is one of the STATE_*
## constants, and message is the below-floor error (without its log prefix) for a
## *_below_floor state, else "".
func get_verdict() -> Dictionary:
	return _verdict.duplicate()


## The recorded verdict's state, one of the STATE_* constants.
func get_state() -> String:
	return str(_verdict["state"])


## The floor verdict for a server at [param server_ver] declaring [param min_toolkit],
## seen from a toolkit at [param toolkit_ver] whose server floor is [param min_server].
## Own floor first: the server's version against [param min_server], then this
## toolkit's version against [param min_toolkit]; an empty [param min_toolkit] skips
## only that second check. Pure.
##
## Returns the get_verdict() shape, STATE_OK when neither check flags a side.
static func judge_floors(server_ver: String, min_toolkit: String, toolkit_ver: String, min_server: String) -> Dictionary:
	if VersionUtils.floor_verdict(server_ver, min_server) == "below":
		return make_verdict(STATE_SERVER_BELOW_FLOOR, server_ver, min_toolkit,
				("MCP server %s is below this toolkit's floor (server >= %s). Pin the recommended "
				+ "server from the dock's .mcp.json panel, or set the server version in your MCP "
				+ "client's config.") % [server_ver, min_server])
	if not min_toolkit.is_empty() and VersionUtils.floor_verdict(toolkit_ver, min_toolkit) == "below":
		return make_verdict(STATE_TOOLKIT_BELOW_FLOOR, server_ver, min_toolkit,
				("This toolkit (%s) is below the MCP server's floor (toolkit >= %s). Update the addon "
				+ "(Godot Asset Store / Asset Library), or pin an older server in .mcp.json: "
				+ "@npgamedev/godot-mcp-server@<version>.") % [toolkit_ver, min_toolkit])
	return make_verdict(STATE_OK, server_ver, min_toolkit, "")


## Builds a verdict in the get_verdict() shape.
static func make_verdict(state: String, server_ver: String, min_toolkit: String, message: String) -> Dictionary:
	return {"state": state, "server_version": server_ver, "min_toolkit": min_toolkit, "message": message}
