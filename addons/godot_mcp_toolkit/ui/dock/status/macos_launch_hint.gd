@tool
extends RefCounted
## Pure guidance for the dock's macOS "listening, but no client connected" surface.
##
## macOS apps launched from Finder/Dock/Spotlight run under launchd with a minimal
## PATH and never source the user's shell rc files, so a version-manager Node
## (nvm/fnm/volta/Homebrew) is invisible to a GUI-launched MCP client — it can't
## spawn the server and silently fails to connect. This module owns WHEN the dock
## surfaces the guidance and its message text; the dock owns the session state
## (ever-connected, dismissed) and the persistent warning panel. Deliberately NOT
## coupled to NodejsCheck: that check reads green via its own login-shell fallback
## while a GUI client still can't find Node, so the trigger is no-peer-after-grace,
## never node-not-found.

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


## The guidance text: the launchd minimal-PATH cause plus the three recovery
## actions (write the config, re-write after a Node-version change, launch the
## client from a terminal to diagnose).
static func message() -> String:
	return (
		"MCP client hasn't connected. On macOS, apps launched from Finder/Dock run "
		+ "with a minimal PATH and may not find Node — click \"Write .mcp.json\" to "
		+ "embed your resolved Node path, re-write it after changing your Node "
		+ "version, or launch the client from a terminal to diagnose."
	)
