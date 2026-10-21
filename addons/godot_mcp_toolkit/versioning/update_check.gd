@tool
extends RefCounted
## Pure rules of the update check: version comparison, response parsing, the due rule
## and the request and link builders.
##
## The update check asks GitHub at most once a day for the toolkit's latest release
## and, when that release is newer than the installed one, asks the Asset Store
## whether it lists it. Everything here is static and touches no network or file,
## and reads a setting only from the settings object it is given, so the runner
## node that does the I/O stays thin and these rules are unit tested directly. A
## version counts only when it is a plain stable [code]X.Y.Z[/code] (optionally
## [code]v[/code]-prefixed); anything else makes the check show nothing, so a
## release the toolkit cannot read never raises a badge.

# Direct preload, not core/modules.gd: the aggregator preloads this file.
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")
const HttpIdentity := preload("res://addons/godot_mcp_toolkit/core/http_identity.gd")

## The Project Settings toggle. Off means no request at all.
const SETTING := "mcp_toolkit/updates/check_for_updates"

## Contributor-only environment variable. Set to [code]http://host:port[/code] (or
## [code]https://…[/code]), it replaces the scheme and host of both request URLs,
## never the links the badge opens.
const HOST_ENV := "GODOT_MCP_UPDATE_CHECK_HOST"

## The shortest gap between two checks of one project, in seconds.
const CHECK_INTERVAL_SEC := 24 * 60 * 60

## Each request's timeout, in seconds.
const REQUEST_TIMEOUT_SEC := 10.0

## The Asset Store listing the badge opens.
const STORE_LISTING_URL := "https://store.godotengine.org/asset/npgamedev/godot-mcp-toolkit/"

## The state file's keys: the last check (unix seconds), the latest version found,
## whether the Asset Store lists it, and the version the user dismissed.
const STATE_LAST_CHECK := "last_check"
const STATE_LATEST_VERSION := "latest_version"
const STATE_STORE_LISTED := "store_listed"
const STATE_DISMISSED_VERSION := "dismissed_version"

## [method due_state] results.
const DUE := 0
const NOT_DUE := 1
const CLOCK_MOVED_BACK := 2

const _GITHUB_HOST := "https://api.github.com"
const _GITHUB_PATH := "/repos/NPGameDev/godot-mcp-toolkit/releases/latest"
const _STORE_HOST := "https://store.godotengine.org"
# The trailing slash is required: without it the store answers with a redirect.
const _STORE_PATH := "/api/v1/releases/npgamedev/godot-mcp-toolkit/"
const _RELEASE_PAGE_PREFIX := "https://github.com/NPGameDev/godot-mcp-toolkit/releases/tag/v"


## Whether the [constant SETTING] toggle is on in [param project_settings]. Returns
## its value, or [code]true[/code] when the key is missing or [param project_settings]
## is [code]null[/code]. [param project_settings] is [ProjectSettings] or a stand-in
## with [code]has_setting[/code] and [code]get_setting[/code]; this reads only the
## object it is given.
static func is_check_enabled(project_settings: Object) -> bool:
	if project_settings == null or not project_settings.has_setting(SETTING):
		return true
	return bool(project_settings.get_setting(SETTING))


## Parses [param version] as a strict stable semver.
##
## Accepts exactly [code]X.Y.Z[/code] or [code]vX.Y.Z[/code], each part a decimal
## number without a leading zero. A prerelease or build suffix, a missing or extra
## part, a sign or any other character is rejected.
##
## Returns [code][major, minor, patch][/code], or an empty array when
## [param version] is not such a version.
static func parse_version(version: String) -> Array[int]:
	return VersionUtils.parse_strict(version, VersionUtils.STABLE_RELEASE_PATTERN)


## The state of a project that has never checked: never checked, nothing found or
## dismissed.
##
## Returns [code]{"last_check": 0, "latest_version": "", "store_listed": false,
## "dismissed_version": ""}[/code], a new dictionary on each call.
static func default_state() -> Dictionary:
	return {
		STATE_LAST_CHECK: 0,
		STATE_LATEST_VERSION: "",
		STATE_STORE_LISTED: false,
		STATE_DISMISSED_VERSION: "",
	}


## Reads the state file's text into its four fields, each with its default when
## missing or of the wrong type.
##
## Returns a dictionary in the shape of [method default_state]; [param text] that is
## not a JSON object gives [method default_state] itself.
static func parse_state(text: String) -> Dictionary:
	var state := default_state()
	var parsed: Variant = _parse_json(text)
	if not parsed is Dictionary:
		return state
	var stored: Dictionary = parsed
	var last_check: Variant = stored.get(STATE_LAST_CHECK, 0)
	# JSON numbers arrive as floats.
	if last_check is float or last_check is int:
		state[STATE_LAST_CHECK] = int(last_check)
	var latest: Variant = stored.get(STATE_LATEST_VERSION, "")
	if latest is String:
		state[STATE_LATEST_VERSION] = str(latest)
	var listed: Variant = stored.get(STATE_STORE_LISTED, false)
	if listed is bool:
		state[STATE_STORE_LISTED] = bool(listed)
	var dismissed: Variant = stored.get(STATE_DISMISSED_VERSION, "")
	if dismissed is String:
		state[STATE_DISMISSED_VERSION] = str(dismissed)
	return state


## Whether [param remote] is a strictly newer stable version than [param local].
##
## Returns [code]false[/code] when the two are equal, when [param remote] is older,
## or when either side does not parse with [method parse_version].
static func is_newer(local: String, remote: String) -> bool:
	var a := parse_version(local)
	var b := parse_version(remote)
	if a.is_empty() or b.is_empty():
		return false
	return VersionUtils.compare_parts(a, b) < 0


## Whether [param remote] is newer than [param local] by its major number.
##
## Returns [code]true[/code] only when [method is_newer] holds and the major number
## grew.
static func is_major_bump(local: String, remote: String) -> bool:
	if not is_newer(local, remote):
		return false
	return parse_version(remote)[0] > parse_version(local)[0]


## The version the badge shows, given the [param installed] version, the
## [param latest] one the last check found and the [param dismissed] one.
##
## Returns [param latest] in [code]X.Y.Z[/code] form when it is newer than
## [param installed] and, if a version was dismissed, newer than [param dismissed];
## else an empty string (no badge).
static func version_to_show(installed: String, latest: String, dismissed: String) -> String:
	if not is_newer(installed, latest):
		return ""
	if not dismissed.is_empty() and not is_newer(dismissed, latest):
		return ""
	return _normalize(latest)


## Reads the release tag from the body of a GitHub [code]releases/latest[/code]
## reply.
##
## Only [code]tag_name[/code] is read. Returns the tag as [code]X.Y.Z[/code], or an
## empty string when [param body] is not a JSON object, has no string
## [code]tag_name[/code], or the tag is not a stable version.
static func parse_latest_tag(body: String) -> String:
	var parsed: Variant = _parse_json(body)
	if not parsed is Dictionary:
		return ""
	var reply: Dictionary = parsed
	var tag: Variant = reply.get("tag_name", null)
	if not tag is String:
		return ""
	return _normalize(str(tag))


## Whether the body of an Asset Store releases reply lists [param version] as a
## stable release.
##
## The reply is a JSON array of releases. An entry counts when its
## [code]stable[/code] is [code]true[/code] and its [code]version[/code] parses to
## the same version; an entry whose free-text [code]version[/code] does not parse
## is skipped. Returns [code]false[/code] for a body that is not a JSON array.
static func store_lists_version(body: String, version: String) -> bool:
	var wanted := parse_version(version)
	if wanted.is_empty():
		return false
	var parsed: Variant = _parse_json(body)
	if not parsed is Array:
		return false
	var releases: Array = parsed
	for entry in releases:
		if not entry is Dictionary:
			continue
		var release: Dictionary = entry
		var stable: Variant = release.get("stable", false)
		if not (stable is bool and bool(stable)):
			continue
		var entry_version: Variant = release.get("version", null)
		if not entry_version is String:
			continue
		if parse_version(str(entry_version)) == wanted:
			return true
	return false


## Whether a check is due at [param now] (unix seconds) after the last one at
## [param last_check] (unix seconds, 0 for never).
##
## Returns [constant DUE] when at least [constant CHECK_INTERVAL_SEC] has passed,
## [constant NOT_DUE] when less has, and [constant CLOCK_MOVED_BACK] when
## [param last_check] lies in the future, which the caller resets to now without a
## request.
static func due_state(now: int, last_check: int) -> int:
	if last_check > now:
		return CLOCK_MOVED_BACK
	if now - last_check >= CHECK_INTERVAL_SEC:
		return DUE
	return NOT_DUE


## The GitHub request: [code]{"url": String, "headers": PackedStringArray}[/code].
##
## [param env_host] is the value of [constant HOST_ENV]; see [method resolve_host].
static func github_request(env_host: String) -> Dictionary:
	return _request(resolve_host(env_host, _GITHUB_HOST) + _GITHUB_PATH)


## The Asset Store request, in the shape of [method github_request].
static func store_request(env_host: String) -> Dictionary:
	return _request(resolve_host(env_host, _STORE_HOST) + _STORE_PATH)


## The scheme and host a request goes to: [param env_host] without a trailing slash
## when it starts with [code]http://[/code] or [code]https://[/code], else
## [param default_host].
static func resolve_host(env_host: String, default_host: String) -> String:
	var host := env_host.strip_edges()
	if not (host.begins_with("http://") or host.begins_with("https://")):
		return default_host
	return host.rstrip("/")


## The GitHub release page of [param version], built locally from the version alone.
##
## Returns an empty string when [param version] is not a stable version, so the
## caller never opens a URL derived from unvalidated text.
static func release_page_url(version: String) -> String:
	var normalized := _normalize(version)
	if normalized.is_empty():
		return ""
	return _RELEASE_PAGE_PREFIX + normalized


# The parsed value of text, or null when it is not valid JSON. A JSON instance
# reports bad input through its return value, where the static parse helper prints
# an engine error, and a malformed reply must stay silent.
static func _parse_json(text: String) -> Variant:
	var json := JSON.new()
	return json.data if json.parse(text) == OK else null


static func _request(url: String) -> Dictionary:
	return {"url": url, "headers": HttpIdentity.request_headers()}


# The version as X.Y.Z (a v prefix dropped), or "" when it does not parse.
static func _normalize(version: String) -> String:
	var parts := parse_version(version)
	if parts.is_empty():
		return ""
	return "%d.%d.%d" % [parts[0], parts[1], parts[2]]
