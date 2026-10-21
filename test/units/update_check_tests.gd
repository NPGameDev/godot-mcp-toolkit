@tool
extends RefCounted
## Unit tests for the update check's pure rules: which versions count as newer, the
## major bump, the badge's version, the GitHub and Asset Store reply parsing, the
## state file and its default, the silence on malformed input, the once-a-day due
## rule and the request builders. The network is never touched: every reply is a
## literal body.

const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")
const LogBuffer := preload("res://addons/godot_mcp_toolkit/logging/log_buffer.gd")


static func run(testing) -> void:
	_test_parse_version(testing)
	_test_parse_version_edges(testing)
	_test_is_newer(testing)
	_test_major_bump(testing)
	_test_version_to_show(testing)
	_test_parse_latest_tag(testing)
	_test_store_lists_version(testing)
	_test_parse_state(testing)
	_test_default_state(testing)
	_test_malformed_input_is_silent(testing)
	_test_due_state(testing)
	_test_requests(testing)
	_test_release_page_url(testing)


static func _test_parse_version(testing) -> void:
	testing.begin("Update check: strict version parse")
	testing.eq(UpdateCheck.parse_version("1.2.3"), [1, 2, 3], "X.Y.Z parses")
	testing.eq(UpdateCheck.parse_version("v1.2.3"), [1, 2, 3], "a v prefix is accepted")
	testing.eq(UpdateCheck.parse_version("10.0.12"), [10, 0, 12], "multi-digit parts parse")
	testing.eq(UpdateCheck.parse_version("1.2.3-beta.1"), [], "a prerelease suffix is rejected")
	testing.eq(UpdateCheck.parse_version("1.2.3+build.5"), [], "a build suffix is rejected")
	testing.eq(UpdateCheck.parse_version("1.2"), [], "two parts are rejected")
	testing.eq(UpdateCheck.parse_version("1.2.3.4"), [], "four parts are rejected")
	testing.eq(UpdateCheck.parse_version("01.2.3"), [], "a leading zero is rejected")
	testing.eq(UpdateCheck.parse_version("1.-2.3"), [], "a sign is rejected")
	testing.eq(UpdateCheck.parse_version("V1.2.3"), [], "an uppercase V is rejected")
	testing.eq(UpdateCheck.parse_version("Godot MCP Toolkit"), [], "free text is rejected")
	testing.eq(UpdateCheck.parse_version(""), [], "an empty string is rejected")
	testing.eq(UpdateCheck.parse_version("unknown"), [], "the unreadable plugin.cfg marker is rejected")
	print("")


# The edges of the release grammar: whitespace is trimmed before the v prefix is read,
# zero is a valid part, and nothing else gets past.
static func _test_parse_version_edges(testing) -> void:
	testing.begin("Update check: strict version parse edges")
	testing.eq(UpdateCheck.parse_version(" v1.2.3 "), [1, 2, 3], "whitespace is trimmed before the v")
	testing.eq(UpdateCheck.parse_version("0.0.0"), [0, 0, 0], "zero parts parse")
	testing.eq(UpdateCheck.parse_version("v0.10.0"), [0, 10, 0], "a zero beside a multi-digit part parses")
	testing.eq(UpdateCheck.parse_version("1.2.3."), [], "a trailing dot is rejected")
	testing.eq(UpdateCheck.parse_version("vv1.2.3"), [], "a doubled v is rejected")
	testing.eq(UpdateCheck.parse_version("v 1.2.3"), [], "a space after the v is rejected")
	testing.eq(UpdateCheck.parse_version("1. 2.3"), [], "a space inside is rejected")
	testing.eq(UpdateCheck.parse_version("1.2.03"), [], "a leading zero on the patch is rejected")
	testing.eq(UpdateCheck.parse_version("+1.2.3"), [], "a plus sign is rejected")
	testing.eq(UpdateCheck.parse_version("1..3"), [], "an empty part is rejected")
	print("")


static func _test_is_newer(testing) -> void:
	testing.begin("Update check: newer is a strictly newer stable version")
	testing.ok(UpdateCheck.is_newer("1.1.0", "1.1.1"), "a newer patch is newer")
	testing.ok(UpdateCheck.is_newer("1.1.0", "1.2.0"), "a newer minor is newer")
	testing.ok(UpdateCheck.is_newer("1.1.0", "2.0.0"), "a newer major is newer")
	testing.ok(UpdateCheck.is_newer("1.9.0", "1.10.0"), "parts compare as numbers, not text")
	testing.ok(UpdateCheck.is_newer("1.1.0", "v1.2.0"), "a v-prefixed remote is read")
	testing.ok(UpdateCheck.is_newer("v1.1.0", "1.2.0"), "a v-prefixed local is read")
	testing.ok(not UpdateCheck.is_newer("1.1.0", "1.1.0"), "an equal version is not newer")
	testing.ok(not UpdateCheck.is_newer("1.1.0", "v1.1.0"), "an equal v-prefixed version is not newer")
	testing.ok(not UpdateCheck.is_newer("1.2.0", "1.1.9"), "an older version is not newer")
	testing.ok(not UpdateCheck.is_newer("1.1.0", "1.2.0-rc.1"), "a prerelease is not newer")
	testing.ok(not UpdateCheck.is_newer("1.1.0", "1.2.0+build.1"), "a build suffix is not newer")
	testing.ok(not UpdateCheck.is_newer("1.1.0", "latest"), "an unparseable remote is not newer")
	testing.ok(not UpdateCheck.is_newer("unknown", "9.9.9"), "an unparseable local shows nothing")
	print("")


static func _test_major_bump(testing) -> void:
	testing.begin("Update check: major bump")
	testing.ok(UpdateCheck.is_major_bump("1.4.2", "2.0.0"), "a grown major is a major bump")
	testing.ok(UpdateCheck.is_major_bump("1.4.2", "v3.1.0"), "two majors ahead is a major bump")
	testing.ok(not UpdateCheck.is_major_bump("1.4.2", "1.5.0"), "a minor is not a major bump")
	testing.ok(not UpdateCheck.is_major_bump("1.4.2", "1.4.3"), "a patch is not a major bump")
	testing.ok(not UpdateCheck.is_major_bump("2.0.0", "1.9.9"), "an older major is not a bump")
	testing.ok(not UpdateCheck.is_major_bump("1.4.2", "2.0.0-beta"), "a major prerelease is not a bump")
	print("")


static func _test_version_to_show(testing) -> void:
	testing.begin("Update check: the version the badge shows")
	testing.eq(UpdateCheck.version_to_show("1.1.0", "1.2.0", ""), "1.2.0", "newer, nothing dismissed")
	testing.eq(UpdateCheck.version_to_show("1.1.0", "v1.2.0", ""), "1.2.0", "shown without the v prefix")
	testing.eq(UpdateCheck.version_to_show("1.1.0", "1.1.0", ""), "", "equal shows nothing")
	testing.eq(UpdateCheck.version_to_show("1.1.0", "", ""), "", "nothing found shows nothing")
	testing.eq(UpdateCheck.version_to_show("1.1.0", "1.2.0", "1.2.0"), "",
			"the dismissed version stays hidden")
	testing.eq(UpdateCheck.version_to_show("1.1.0", "1.3.0", "1.2.0"), "1.3.0",
			"a version newer than the dismissed one shows again")
	testing.eq(UpdateCheck.version_to_show("1.1.0", "1.2.0", "1.3.0"), "",
			"a version older than the dismissed one stays hidden")
	print("")


static func _test_parse_latest_tag(testing) -> void:
	testing.begin("Update check: GitHub releases/latest reply")
	testing.eq(UpdateCheck.parse_latest_tag("{\"tag_name\": \"v1.2.0\", \"html_url\": \"x\"}"), "1.2.0",
			"tag_name is read and normalized")
	testing.eq(UpdateCheck.parse_latest_tag("{\"tag_name\": \"1.2.0\"}"), "1.2.0", "an unprefixed tag is read")
	testing.eq(UpdateCheck.parse_latest_tag("{\"tag_name\": \"v1.2.0-rc.1\"}"), "", "a prerelease tag reads as none")
	testing.eq(UpdateCheck.parse_latest_tag("{\"tag_name\": 12}"), "", "a non-string tag reads as none")
	testing.eq(UpdateCheck.parse_latest_tag("{\"name\": \"v1.2.0\"}"), "", "a reply without tag_name reads as none")
	testing.eq(UpdateCheck.parse_latest_tag("[\"v1.2.0\"]"), "", "an array reads as none")
	testing.eq(UpdateCheck.parse_latest_tag("{\"tag_name\": "), "", "a malformed body reads as none")
	testing.eq(UpdateCheck.parse_latest_tag(""), "", "an empty body reads as none")
	print("")


static func _test_store_lists_version(testing) -> void:
	testing.begin("Update check: Asset Store releases reply")
	var listed := "[{\"version\": \"1.2.0\", \"stable\": true}, {\"version\": \"1.1.0\", \"stable\": true}]"
	testing.ok(UpdateCheck.store_lists_version(listed, "1.2.0"), "a stable entry with the version is listed")
	testing.ok(UpdateCheck.store_lists_version(listed, "v1.2.0"), "the version is compared as semver")
	testing.ok(not UpdateCheck.store_lists_version(listed, "1.3.0"), "an absent version is not listed")
	var unstable := "[{\"version\": \"1.3.0\", \"stable\": false}]"
	testing.ok(not UpdateCheck.store_lists_version(unstable, "1.3.0"), "stable: false is not listed")
	var stable_text := "[{\"version\": \"1.3.0\", \"stable\": \"true\"}]"
	testing.ok(not UpdateCheck.store_lists_version(stable_text, "1.3.0"), "a non-bool stable is not listed")
	var free_text := "[{\"version\": \"Godot MCP Toolkit\", \"stable\": true}, {\"version\": \"1.3.0\", \"stable\": true}]"
	testing.ok(UpdateCheck.store_lists_version(free_text, "1.3.0"), "a free-text version entry is skipped")
	testing.ok(not UpdateCheck.store_lists_version(
			"[{\"version\": \"Godot MCP Toolkit\", \"stable\": true}]", "1.0.0"),
			"a free-text version never matches")
	testing.ok(not UpdateCheck.store_lists_version("[{\"version\": ", "1.2.0"), "a malformed body is not listed")
	testing.ok(not UpdateCheck.store_lists_version("{\"version\": \"1.2.0\", \"stable\": true}", "1.2.0"),
			"an object instead of an array is not listed")
	testing.ok(not UpdateCheck.store_lists_version("[\"1.2.0\", 3, null]", "1.2.0"), "non-object entries are skipped")
	print("")


static func _test_parse_state(testing) -> void:
	testing.begin("Update check: state file")
	var full := UpdateCheck.parse_state(
			"{\"last_check\": 1760000000, \"latest_version\": \"1.2.0\", \"store_listed\": true, \"dismissed_version\": \"1.1.5\"}")
	testing.eq(full[UpdateCheck.STATE_LAST_CHECK], 1760000000, "the last check reads as an int")
	testing.eq(full[UpdateCheck.STATE_LATEST_VERSION], "1.2.0", "the latest version reads")
	testing.eq(full[UpdateCheck.STATE_STORE_LISTED], true, "the store flag reads")
	testing.eq(full[UpdateCheck.STATE_DISMISSED_VERSION], "1.1.5", "the dismissed version reads")
	var empty := UpdateCheck.parse_state("")
	testing.eq(empty[UpdateCheck.STATE_LAST_CHECK], 0, "a missing file means never checked")
	testing.eq(empty[UpdateCheck.STATE_LATEST_VERSION], "", "a missing file found nothing")
	testing.eq(empty[UpdateCheck.STATE_STORE_LISTED], false, "a missing file lists nothing")
	testing.eq(empty[UpdateCheck.STATE_DISMISSED_VERSION], "", "a missing file dismissed nothing")
	var wrong := UpdateCheck.parse_state("{\"last_check\": \"soon\", \"latest_version\": 5, \"store_listed\": 1}")
	testing.eq(wrong[UpdateCheck.STATE_LAST_CHECK], 0, "a wrong-typed field takes its default")
	testing.eq(wrong[UpdateCheck.STATE_LATEST_VERSION], "", "a wrong-typed version takes its default")
	testing.eq(wrong[UpdateCheck.STATE_STORE_LISTED], false, "a wrong-typed flag takes its default")
	var malformed := UpdateCheck.parse_state("{\"last_check\": ")
	testing.eq(malformed, UpdateCheck.default_state(), "a malformed state file gives the default state")
	testing.eq(UpdateCheck.parse_state("[1, 2]"), UpdateCheck.default_state(),
			"a state file that is not an object gives the default state")
	print("")


static func _test_default_state(testing) -> void:
	testing.begin("Update check: default state")
	var state := UpdateCheck.default_state()
	testing.eq(state.size(), 4, "the default state has the four state-file keys")
	testing.eq(state[UpdateCheck.STATE_LAST_CHECK], 0, "never checked")
	testing.eq(state[UpdateCheck.STATE_LATEST_VERSION], "", "nothing found")
	testing.eq(state[UpdateCheck.STATE_STORE_LISTED], false, "nothing listed")
	testing.eq(state[UpdateCheck.STATE_DISMISSED_VERSION], "", "nothing dismissed")
	state[UpdateCheck.STATE_LAST_CHECK] = 5
	testing.eq(UpdateCheck.default_state()[UpdateCheck.STATE_LAST_CHECK], 0,
			"each call returns a fresh dictionary")
	print("")


# The check fails silently, so bad input must not reach the console either. Only
# the 4.5+ Logger capture sees engine errors; older engines check the results alone.
static func _test_malformed_input_is_silent(testing) -> void:
	testing.begin("Update check: malformed input prints no engine error")
	LogBuffer.setup()
	var cursor: int = LogBuffer.get_cursor() - 1
	testing.eq(UpdateCheck.parse_latest_tag("{\"tag_name\": "), "", "a malformed GitHub body reads as none")
	testing.ok(not UpdateCheck.store_lists_version("[{\"version\": ", "1.2.0"),
			"a malformed store body is not listed")
	testing.eq(UpdateCheck.parse_state("{\"last_check\": "), UpdateCheck.default_state(),
			"a malformed state file gives the default state")
	testing.eq(UpdateCheck.parse_state(""), UpdateCheck.default_state(), "an empty state file gives the default state")
	if LogBuffer.uses_logger_api():
		var errors: Dictionary = LogBuffer.get_entries(100, ["error"], cursor, "JSON")
		testing.eq(int(errors["returned"]), 0, "no JSON parse error reached the console")
	print("")


static func _test_due_state(testing) -> void:
	testing.begin("Update check: at most once a day")
	var day := UpdateCheck.CHECK_INTERVAL_SEC
	var now := 1760000000
	testing.eq(UpdateCheck.due_state(now, 0), UpdateCheck.DUE, "never checked is due")
	testing.eq(UpdateCheck.due_state(now, now - day + 1), UpdateCheck.NOT_DUE, "under 24 h is not due")
	testing.eq(UpdateCheck.due_state(now, now), UpdateCheck.NOT_DUE, "just checked is not due")
	testing.eq(UpdateCheck.due_state(now, now - day), UpdateCheck.DUE, "exactly 24 h is due")
	testing.eq(UpdateCheck.due_state(now, now - day * 3), UpdateCheck.DUE, "over 24 h is due")
	testing.eq(UpdateCheck.due_state(now, now + 60), UpdateCheck.CLOCK_MOVED_BACK,
			"a future timestamp means the clock moved back")
	print("")


static func _test_requests(testing) -> void:
	testing.begin("Update check: request builder")
	var github := UpdateCheck.github_request("")
	testing.eq(github["url"], "https://api.github.com/repos/NPGameDev/godot-mcp-toolkit/releases/latest",
			"GitHub URL by default")
	testing.eq(github["headers"], PackedStringArray(["User-Agent: godot-mcp-toolkit"]),
			"the only header is the fixed User-Agent")
	var store := UpdateCheck.store_request("")
	testing.eq(store["url"], "https://store.godotengine.org/api/v1/releases/npgamedev/godot-mcp-toolkit/",
			"store URL by default, with its trailing slash")
	testing.eq(store["headers"], PackedStringArray(["User-Agent: godot-mcp-toolkit"]),
			"the store request sends the same header")
	testing.ok(not str(github["url"]).contains("?") and not str(store["url"]).contains("?"),
			"neither URL carries a query string")
	var local_github := UpdateCheck.github_request("http://127.0.0.1:8123")
	testing.eq(local_github["url"], "http://127.0.0.1:8123/repos/NPGameDev/godot-mcp-toolkit/releases/latest",
			"the env host replaces GitHub's scheme and host")
	var local_store := UpdateCheck.store_request("http://127.0.0.1:8123/")
	testing.eq(local_store["url"], "http://127.0.0.1:8123/api/v1/releases/npgamedev/godot-mcp-toolkit/",
			"the env host replaces the store's scheme and host, a trailing slash dropped")
	testing.eq(local_store["headers"], PackedStringArray(["User-Agent: godot-mcp-toolkit"]),
			"the env host leaves the headers alone")
	testing.eq(UpdateCheck.github_request("127.0.0.1:8123")["url"],
			"https://api.github.com/repos/NPGameDev/godot-mcp-toolkit/releases/latest",
			"an env host without an http(s) scheme is ignored")
	testing.eq(UpdateCheck.github_request("file:///tmp")["url"],
			"https://api.github.com/repos/NPGameDev/godot-mcp-toolkit/releases/latest",
			"a non-http scheme is ignored")
	print("")


static func _test_release_page_url(testing) -> void:
	testing.begin("Update check: links are built locally")
	testing.eq(UpdateCheck.release_page_url("1.2.0"),
			"https://github.com/NPGameDev/godot-mcp-toolkit/releases/tag/v1.2.0", "the release page of a version")
	testing.eq(UpdateCheck.release_page_url("v1.2.0"),
			"https://github.com/NPGameDev/godot-mcp-toolkit/releases/tag/v1.2.0", "a v-prefixed version is normalized")
	testing.eq(UpdateCheck.release_page_url("1.2.0/../../evil"), "", "a non-version gives no link")
	testing.eq(UpdateCheck.STORE_LISTING_URL, "https://store.godotengine.org/asset/npgamedev/godot-mcp-toolkit/",
			"the store listing")
	print("")
