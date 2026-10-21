@tool
extends Node
## Runs the update check: the toggle, the state file, the hourly timer and the two
## HTTP requests.
##
## The composer adds one runner under the plugin before it builds the dock, and the
## dock's update badge reads it; the check therefore runs whether or not the dock is
## shown. At enable and then every hour the runner re-reads the state file, and when
## a day has passed since the project's last check it writes the new check time
## [i]first[/i] and only then asks GitHub. A failed request still counts as that
## day's check, and a second editor on the same project reads the fresh time and
## sends nothing. When GitHub reports a newer version, one Asset Store request
## decides whether the store lists it.
##
## Nothing is sent until the consent gate allows it, which takes the toggle on and
## the setup wizard's update-check step seen. The first check after that step goes
## out on the next hourly tick or when the plugin next loads, at an editor start or
## an enable.
##
## Every failure is silent: the cache is kept, nothing is printed and the dock shows
## no error. Turning the [code]mcp_toolkit/updates/check_for_updates[/code] toggle
## off cancels a request in flight and hides the badge; turning it on checks at once
## if a check is due.
## The comparison, parsing and request rules live in [code]update_check.gd[/code].

## Emitted when what the badge should show may have changed: a new result, a
## dismissal, or the toggle switched.
signal state_changed

# Direct preloads, not core/modules.gd: the aggregator preloads this file, so
# preloading it back would be a cycle.
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")
const Consent := preload("res://addons/godot_mcp_toolkit/core/consent.gd")
const UserJsonStore := preload("res://addons/godot_mcp_toolkit/paths/user_json_store.gd")

## The state file: per project and per machine, beside the toolkit's other
## project-wide user:// files, never in project.godot. It survives a plugin disable.
const STATE_PATH := "user://addons/godot_mcp_toolkit/update_check_cache.json"

const _TIMER_INTERVAL_SEC := 60.0 * 60.0

# Which reply the HTTPRequest is waiting for.
const _PENDING_NONE := 0
const _PENDING_GITHUB := 1
const _PENDING_STORE := 2

var _http: HTTPRequest = null
var _timer: Timer = null
var _pending: int = _PENDING_NONE
# The newer version GitHub reported, held while the store request runs.
var _found_version: String = ""
var _enabled: bool = true
var _installed_version: String = ""
# The state file as last read or written; the badge renders from it.
var _state: Dictionary = {}


# The cached state is read here, not in _ready: the composer adds the runner while
# the plugin is still entering the tree, so its _ready waits for the plugin's while
# the dock's badge may already read the runner.
func _init() -> void:
	_installed_version = VersionUtils.read_plugin_version()
	_enabled = _read_toggle()
	_state = _read_state()


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = UpdateCheck.REQUEST_TIMEOUT_SEC
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)

	_timer = Timer.new()
	_timer.wait_time = _TIMER_INTERVAL_SEC
	_timer.timeout.connect(_check_if_due)
	add_child(_timer)
	_timer.start()

	ProjectSettings.settings_changed.connect(_on_settings_changed)
	_check_if_due()


func _exit_tree() -> void:
	if ProjectSettings.settings_changed.is_connected(_on_settings_changed):
		ProjectSettings.settings_changed.disconnect(_on_settings_changed)
	_cancel()


## The version the badge shows as [code]X.Y.Z[/code], or an empty string for no
## badge: the toggle is off, nothing newer than the installed version was found, or
## the user dismissed it.
func badge_version() -> String:
	if not _enabled:
		return ""
	return UpdateCheck.version_to_show(
			_installed_version,
			str(_state[UpdateCheck.STATE_LATEST_VERSION]),
			str(_state[UpdateCheck.STATE_DISMISSED_VERSION]))


## Whether [method badge_version] is a new major version.
func is_major() -> bool:
	return UpdateCheck.is_major_bump(_installed_version, badge_version())


## Whether the Asset Store listed [method badge_version] at the last check.
func is_store_listed() -> bool:
	return bool(_state[UpdateCheck.STATE_STORE_LISTED])


## When the project last checked, in unix seconds (0 when it never has).
func last_check_unix() -> int:
	return int(_state[UpdateCheck.STATE_LAST_CHECK])


## Hides the badge until a version newer than [param version] is found.
func dismiss(version: String) -> void:
	_state = _read_state()
	_state[UpdateCheck.STATE_DISMISSED_VERSION] = version
	_write_state(_state)
	state_changed.emit()


# Re-reads the state file and, when a day has passed since the project's last
# check, checks now. Does nothing without the consent gate's go (the toggle is off,
# or the user has not seen the setup step that explains the check) or while a
# request is running.
func _check_if_due() -> void:
	if not Consent.may_check_for_updates() or _pending != _PENDING_NONE:
		return
	# Re-read: another editor on this project may have checked since.
	var previous := _state
	_state = _read_state()
	if _state != previous:
		state_changed.emit()
	var now := int(Time.get_unix_time_from_system())
	var due := UpdateCheck.due_state(now, last_check_unix())
	if due == UpdateCheck.NOT_DUE:
		return
	# Both remaining cases store now: a clock moved back is reset without a request,
	# and a due check writes its time before the request goes out (see the class doc).
	_state[UpdateCheck.STATE_LAST_CHECK] = now
	_write_state(_state)
	# The badge's "last checked" date must move even when the request then fails.
	state_changed.emit()
	if due == UpdateCheck.DUE:
		_send(UpdateCheck.github_request(_env_host()), _PENDING_GITHUB)


func _on_settings_changed() -> void:
	var enabled := _read_toggle()
	if enabled == _enabled:
		return
	_enabled = enabled
	if not _enabled:
		_cancel()
	state_changed.emit()
	if _enabled:
		_check_if_due()


func _cancel() -> void:
	if _http != null:
		_http.cancel_request()
	_pending = _PENDING_NONE
	_found_version = ""


func _send(request: Dictionary, pending: int) -> void:
	var headers: PackedStringArray = request["headers"]
	var err := _http.request(str(request["url"]), headers, HTTPClient.METHOD_GET)
	_pending = pending if err == OK else _PENDING_NONE


func _on_request_completed(
		result: int, response_code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	var pending := _pending
	_pending = _PENDING_NONE
	var ok := result == HTTPRequest.RESULT_SUCCESS and response_code == 200
	match pending:
		_PENDING_GITHUB:
			if ok:
				_on_github_reply(body.get_string_from_utf8())
		_PENDING_STORE:
			_on_store_reply(ok, body.get_string_from_utf8())


func _on_github_reply(body: String) -> void:
	var latest := UpdateCheck.parse_latest_tag(body)
	if latest.is_empty():
		return
	if not UpdateCheck.is_newer(_installed_version, latest):
		_record(latest, false)
		return
	_found_version = latest
	_send(UpdateCheck.store_request(_env_host()), _PENDING_STORE)
	if _pending == _PENDING_NONE:
		_record(latest, _cached_listing(latest))


func _on_store_reply(ok: bool, body: String) -> void:
	var listed := _cached_listing(_found_version)
	if ok:
		listed = UpdateCheck.store_lists_version(body, _found_version)
	_record(_found_version, listed)
	_found_version = ""


# A failed store request keeps what the cache already knew about this version, and
# counts as not listed for a version the cache has not seen.
func _cached_listing(version: String) -> bool:
	var cached := _read_state()
	return (str(cached[UpdateCheck.STATE_LATEST_VERSION]) == version
			and bool(cached[UpdateCheck.STATE_STORE_LISTED]))


func _record(latest: String, listed: bool) -> void:
	_state = _read_state()
	_state[UpdateCheck.STATE_LATEST_VERSION] = latest
	_state[UpdateCheck.STATE_STORE_LISTED] = listed
	_write_state(_state)
	state_changed.emit()


func _read_toggle() -> bool:
	return UpdateCheck.is_check_enabled(ProjectSettings)


func _env_host() -> String:
	return OS.get_environment(UpdateCheck.HOST_ENV)


func _read_state() -> Dictionary:
	if not FileAccess.file_exists(STATE_PATH):
		return UpdateCheck.default_state()
	var file := FileAccess.open(STATE_PATH, FileAccess.READ)
	if file == null:
		return UpdateCheck.default_state()
	var text := file.get_as_text()
	file.close()
	return UpdateCheck.parse_state(text)


# A failed write is silent like every other failure, so the store's error is
# dropped: the next read finds the old state, and the worst case is one extra check.
func _write_state(state: Dictionary) -> void:
	UserJsonStore.write(STATE_PATH, state, "\t")
