@tool
extends RefCounted
## Unit tests for the editor's connect-time floor verdict (transport/peer_compat.gd):
## which floor is judged first, the cases that leave the product-version message to
## decide, the exact below-floor wording, the once-per-(state, server version) guard,
## and the skipped check of a local server build.

const PeerCompat := preload("res://addons/godot_mcp_toolkit/transport/peer_compat.gd")

const _SERVER_BELOW_MESSAGE := ("MCP server 0.9.0 is below this toolkit's floor (server >= 1.0). "
		+ "Pin the recommended server from the dock's .mcp.json panel, or set the server version "
		+ "in your MCP client's config.")
const _TOOLKIT_BELOW_MESSAGE := ("This toolkit (1.0.4) is below the MCP server's floor "
		+ "(toolkit >= 1.1). Update the addon (Godot Asset Store / Asset Library), or pin an "
		+ "older server in .mcp.json: @npgamedev/godot-mcp-server@<version>.")


static func run(testing) -> void:
	_test_floor_order(testing)
	_test_falls_through_to_product_line(testing)
	_test_messages(testing)
	_test_once_guard(testing)
	_test_skip(testing)


# Own floor first: with both sides below, the toolkit reports the server below its
# floor, so the two consoles print different lines.
static func _test_floor_order(testing) -> void:
	testing.begin("PeerCompat.judge_floors — own floor first")
	var both := PeerCompat.judge_floors("0.9.0", "1.1", "1.0.4", "1.0")
	testing.eq(both["state"], PeerCompat.STATE_SERVER_BELOW_FLOOR, "both below: the server's floor check wins")
	var toolkit_only := PeerCompat.judge_floors("1.1.0", "1.1", "1.0.4", "1.0")
	testing.eq(toolkit_only["state"], PeerCompat.STATE_TOOLKIT_BELOW_FLOOR, "only the toolkit below")
	var neither := PeerCompat.judge_floors("1.1.0", "1.1", "1.1.0", "1.0")
	testing.eq(neither["state"], PeerCompat.STATE_OK, "neither below")
	testing.eq(neither["message"], "", "no message when neither is below")
	print("")


# An empty min_toolkit skips only the toolkit-floor check; an unparsable or missing
# version or floor is STATE_OK, which leaves the product-version message to the caller.
static func _test_falls_through_to_product_line(testing) -> void:
	testing.begin("PeerCompat.judge_floors — empty floor, unparsable or missing version")
	testing.eq(PeerCompat.judge_floors("1.1.0", "", "0.1.0", "1.0")["state"], PeerCompat.STATE_OK,
			"an empty min_toolkit skips the toolkit-floor check")
	testing.eq(PeerCompat.judge_floors("0.9.0", "", "1.0.4", "1.0")["state"], PeerCompat.STATE_SERVER_BELOW_FLOOR,
			"an empty min_toolkit still judges the server against MIN_SERVER_VERSION")
	testing.eq(PeerCompat.judge_floors("", "", "1.0.4", "1.0")["state"], PeerCompat.STATE_OK,
			"a missing server version")
	testing.eq(PeerCompat.judge_floors("dev", "", "1.0.4", "1.0")["state"], PeerCompat.STATE_OK,
			"an unparsable server version")
	testing.eq(PeerCompat.judge_floors("1.1.0", "x.y", "1.0.4", "1.0")["state"], PeerCompat.STATE_OK,
			"an unparsable min_toolkit")
	testing.eq(PeerCompat.judge_floors("1.1.0", "1.1", "unknown", "1.0")["state"], PeerCompat.STATE_OK,
			"an unparsable toolkit version")
	var compat := PeerCompat.new()
	testing.eq(compat.assess("dev", "", "1.0.4", "1.0", false), "", "assess prints nothing for STATE_OK")
	testing.eq(compat.get_state(), PeerCompat.STATE_OK, "the caller's product-version message decides")
	print("")


static func _test_messages(testing) -> void:
	testing.begin("PeerCompat.judge_floors — below-floor wording")
	var server_below := PeerCompat.judge_floors("0.9.0", "", "1.0.4", "1.0")
	testing.eq(server_below["message"], _SERVER_BELOW_MESSAGE, "the server below the toolkit's floor")
	var toolkit_below := PeerCompat.judge_floors("1.1.0", "1.1", "1.0.4", "1.0")
	testing.eq(toolkit_below["message"], _TOOLKIT_BELOW_MESSAGE, "the toolkit below the server's floor")
	testing.eq(toolkit_below["server_version"], "1.1.0", "the verdict carries the server version")
	testing.eq(toolkit_below["min_toolkit"], "1.1", "the verdict carries the declared floor")
	print("")


# A below-floor error prints once per (state, server version) for the editor session,
# across reconnects and a cleared verdict; a new server version prints again.
static func _test_once_guard(testing) -> void:
	testing.begin("PeerCompat.assess — once per (state, server version)")
	var compat := PeerCompat.new()
	testing.eq(compat.assess("0.9.0", "", "1.0.4", "1.0", false), _SERVER_BELOW_MESSAGE, "the first connection prints")
	testing.eq(compat.assess("0.9.0", "", "1.0.4", "1.0", false), "", "the same pair prints nothing new")
	testing.eq(compat.get_verdict()["message"], _SERVER_BELOW_MESSAGE, "the dock still reads the message")
	compat.clear()
	testing.eq(compat.get_state(), PeerCompat.STATE_NONE, "clear() drops the verdict")
	testing.eq(compat.assess("0.9.0", "", "1.0.4", "1.0", false), "", "the guard outlives a cleared verdict")
	testing.ok(not compat.assess("0.8.0", "", "1.0.4", "1.0", false).is_empty(), "a new server version prints")
	testing.ok(not compat.assess("0.9.0", "1.1", "0.5.0", "0.1", false).is_empty(),
			"a new state for the same server version prints")
	print("")


# A local server build skips the floors and prints its info line on every connection.
static func _test_skip(testing) -> void:
	testing.begin("PeerCompat.assess — skipped check")
	var compat := PeerCompat.new()
	testing.eq(compat.assess("0.9.0", "9.0", "1.0.4", "1.0", true), PeerCompat.SKIPPED_LINE, "the skip line prints")
	testing.eq(PeerCompat.SKIPPED_LINE, "Version check skipped (local server path).", "the skip line's text")
	testing.eq(compat.get_state(), PeerCompat.STATE_SKIPPED, "the verdict is skipped, not below a floor")
	testing.eq(compat.get_verdict()["message"], "", "no below-floor message for the dock")
	testing.eq(compat.assess("0.9.0", "9.0", "1.0.4", "1.0", true), PeerCompat.SKIPPED_LINE, "and again on the next connection")
	print("")
