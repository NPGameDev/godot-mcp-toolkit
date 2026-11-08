@tool
extends RefCounted
## Whether the connected MCP server differs from the version this toolkit recommends, and
## the dock's line about it.
##
## The floors in [code]transport/peer_compat.gd[/code] judge what works at all; this
## judges what is best, down to the patch number. An older server gets the line always,
## since npm already serves the recommended version. A newer one gets it only when the
## update check knows a newer toolkit, which is the toolkit the user should move to.
## Advisory only: nothing here refuses a connection.

const PeerCompat := preload("res://addons/godot_mcp_toolkit/transport/peer_compat.gd")
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")

## [method state] results: nothing to say.
const NONE := ""
## The connected server is older than the recommended version.
const SERVER_OLDER := "server_older"
## The connected server is newer than the recommended version, and a newer toolkit is known.
const SERVER_NEWER := "server_newer"

const _OLDER_TEXT := ("MCP server %s is older than %s, the version this toolkit is tested with. "
		+ "Restart your AI client if .mcp.json already runs %s. If it doesn't, update the pin in "
		+ "the dock's .mcp.json panel.")
# Restarting the client doesn't help here: the pin isn't behind.
const _NEWER_TEXT := ("MCP server %s is newer than %s, the version this toolkit is tested with. "
		+ "Update the toolkit to %s, or set the server version in .mcp.json.")


## The gap to report. [param verdict_state] is the floor verdict's state (see
## [code]PeerCompat.get_verdict[/code]), [param server_version] the connected server's
## version, [param recommended] the version this toolkit recommends,
## [param newer_toolkit] the newest toolkit the update check knows ("" for none) and
## [param version_setting] the project's server version setting.
##
## Returns [constant NONE] unless the floors pass with a peer connected and the setting
## is empty: a below-floor server has its own line, a local server is skipped, and a
## setting picks another version on purpose. A version either comparison can't read
## also returns [constant NONE].
static func state(verdict_state: String, server_version: String, recommended: String,
		newer_toolkit: String, version_setting: String) -> String:
	if verdict_state != PeerCompat.STATE_OK or not version_setting.strip_edges().is_empty():
		return NONE
	var skew := VersionUtils.version_skew(recommended, server_version)
	if skew == "ok" or skew == "unknown":
		return NONE
	# The skew has no direction, and it reads a sign or a leading zero the update check's
	# stricter parse rejects, so such a version is neither older nor newer here.
	if UpdateCheck.is_newer(server_version, recommended):
		return SERVER_OLDER
	if UpdateCheck.is_newer(recommended, server_version) and not newer_toolkit.is_empty():
		return SERVER_NEWER
	return NONE


## The dock's line for [param gap_state], one of the [method state] results, or an empty
## string for [constant NONE]. The other parameters are those of [method state].
static func line(gap_state: String, server_version: String, recommended: String, newer_toolkit: String) -> String:
	match gap_state:
		SERVER_OLDER:
			return _OLDER_TEXT % [server_version, recommended, recommended]
		SERVER_NEWER:
			return _NEWER_TEXT % [server_version, recommended, newer_toolkit]
	return ""
