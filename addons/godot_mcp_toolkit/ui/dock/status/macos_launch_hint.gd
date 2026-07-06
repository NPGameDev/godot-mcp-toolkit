@tool
extends RefCounted
## Pure guidance for the dock's macOS "listening, but no client connected" surface.
##
## When the toolkit is listening and a valid .mcp.json is present but no MCP client
## has connected after a grace period, the dock surfaces a calm macOS nudge naming
## the things to check — a diagnosis prompt, not a diagnosis. This module owns WHEN
## the dock surfaces the guidance and its message text; the dock owns the session
## state (ever-connected, dismissed) and the persistent warning panel. Deliberately
## NOT coupled to NodejsCheck: the trigger is a connection fact (no peer after the
## grace), never a node-not-found result.

# Grace a client is given to connect before the no-peer guidance shows (~20s) —
# covers a normal client launch + WebSocket handshake. Distinct from the status
# panel's runtime-port reach grace (a different 10s window for a different
# signal); there is no shared grace constant.
const NO_PEER_GRACE_MS := 20000


## True iff the dock should surface the macOS no-peer launch guidance now. The
## all-AND gate: [param os_name] is macOS AND [param is_listening] AND
## [param mcp_json_valid] (a valid .mcp.json exists, so a client IS configured —
## the anti-nag gate: no config means the user hasn't set up a client, so stay
## silent) AND NOT [param ever_connected] (no peer has connected this session —
## also excludes a peer that connected then dropped) AND [param grace_elapsed] AND
## NOT [param dismissed] (the user closed the panel this session). Any single
## false → silent, so the dock hides the panel again.
static func should_show(
	os_name: String,
	is_listening: bool,
	mcp_json_valid: bool,
	ever_connected: bool,
	grace_elapsed: bool,
	dismissed: bool,
) -> bool:
	return (
		os_name == "macOS"
		and is_listening
		and mcp_json_valid
		and not ever_connected
		and grace_elapsed
		and not dismissed
	)


## The guidance text: a calm "no client connected" nudge naming the three things to
## check — the client is running, .mcp.json is present at the project root, and a
## terminal launch surfaces the client's real startup error. No cause is asserted.
static func message() -> String:
	return (
		"MCP client hasn't connected. Check that your MCP client is running, that "
		+ ".mcp.json is present at your project root, then launch the client from a "
		+ "terminal to see its startup error."
	)
