@tool
extends Node
## Fetches one release file, following each redirect by hand so every hop is checked first.
##
## [HTTPRequest] would follow a reply wherever it points, so its own following stays off. A
## hop must pass [method hop_refusal], and at most [constant MAX_REDIRECTS] are followed.
## What a redirect looks like from here depends on the engine: with its following off, 4.7
## ends any of them with [constant HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED], while up to
## 4.6 only 301 and 302 end that way and 303, 307 and 308 arrive as plain replies;
## [method is_redirect] takes both.[br]
## [br]
## This rule narrows where a request may go. What makes a file safe to use stays the
## caller's check of its signature or hash. One fetch runs at a time.

## Emitted when a fetch that [method fetch] started ends:
## [code]{"ok": bool, "result": int, "code": int, "refusal": String, "body": PackedByteArray}[/code].
## [code]ok[/code] means the last reply was a complete 200; a target file then holds its body,
## and otherwise the file is gone. [code]result[/code] is the last request's
## [enum HTTPRequest.Result] and [code]code[/code] its HTTP status, so a caller can tell a 404
## from any other failure. [code]refusal[/code] is why a redirect was not followed, or empty.
signal finished(outcome: Dictionary)

# Direct preloads, not core/modules.gd: the aggregator preloads the installer,
# which reaches this file.
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")
const HttpIdentity := preload("res://addons/godot_mcp_toolkit/core/http_identity.gd")

## The most redirects one fetch follows.
const MAX_REDIRECTS := 5

## The [code]refusal[/code] of a hop [method hop_refusal] turns down, and what it returns.
const REFUSED_HOST := "the download redirected to a host the toolkit does not trust"
## The [code]refusal[/code] of a redirect past [constant MAX_REDIRECTS].
const REFUSED_TOO_MANY := "the download redirected too many times"

const _RELEASE_HOST := "github.com"
const _ASSET_HOST_SUFFIX := ".githubusercontent.com"
# Anyone can publish a file here, in any repository.
const _USER_CONTENT_HOST := "raw.githubusercontent.com"
const _REDIRECT_CODES := [301, 302, 303, 307, 308]
# The whole URL, with nothing allowed between the host and the path. The engine reads a URL
# differently from a browser ("https://github.com?@evil.com/" connects to evil.com), so
# anything that is not plainly a lowercase host goes, port and credentials included.
const _HTTPS_URL_PATTERN := "^https://([a-z0-9-]+(?:\\.[a-z0-9-]+)*)(?:/[\\x21-\\x7e]*)?\\z"

var _http: HTTPRequest = null
var _target_file: String = ""
var _env_host: String = ""
var _current_url: String = ""
var _redirects: int = 0


## Why a request to [param url] must not be sent, or an empty string when it may be: it must
## be HTTPS on [code]github.com[/code] or on a subdomain of
## [code]githubusercontent.com[/code] other than [code]raw.githubusercontent.com[/code],
## comparing whole lowercase host names, or sit under the loopback address that
## [param env_host], the update check's host variable, names (see
## [method UpdateCheck.resolve_host]).
static func hop_refusal(url: String, env_host: String = "") -> String:
	var test_origin := UpdateCheck.resolve_host(env_host, "")
	if not test_origin.is_empty() and url.begins_with(test_origin + "/"):
		return ""
	var pattern := RegEx.new()
	pattern.compile(_HTTPS_URL_PATTERN)
	var found := pattern.search(url)
	if found == null:
		return REFUSED_HOST
	var host := found.get_string(1)
	if host == _RELEASE_HOST:
		return ""
	if host == _USER_CONTENT_HOST or host.ends_with("." + _USER_CONTENT_HOST):
		return REFUSED_HOST
	return "" if host.ends_with(_ASSET_HOST_SUFFIX) else REFUSED_HOST


## Whether a request that ended with [param result] and the HTTP status [param code] is a
## redirect to follow, in either shape the supported engines report one.
static func is_redirect(result: int, code: int) -> bool:
	var answered := result == HTTPRequest.RESULT_SUCCESS or result == HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED
	return answered and _REDIRECT_CODES.has(code)


# The URL a redirect's headers point at, resolved against the URL that answered, or an
# empty string when there is no Location. Only a path starting at the root counts as
# relative: anything else, "//host/" included, goes to hop_refusal as it stands and fails.
static func _next_url(current_url: String, headers: PackedStringArray) -> String:
	for header: String in headers:
		if not header.to_lower().begins_with("location:"):
			continue
		var location := header.substr(header.find(":") + 1).strip_edges()
		if location.begins_with("/") and not location.begins_with("//"):
			return current_url.substr(0, current_url.find("/", current_url.find("://") + 3)) + location
		return location
	return ""


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.max_redirects = 0
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)


## Starts fetching [param url], keeping the body in memory or, when [param target_file] is
## set, writing it to that absolute path. [param size_limit] is the largest reply body in
## bytes and [param timeout_sec] applies to each request of the chain. Returns [constant OK]
## when [signal finished] will report the end. Any other value means nothing was sent:
## [constant ERR_UNAUTHORIZED] when [method hop_refusal] refuses [param url], else the
## error from [method HTTPRequest.request].
func fetch(url: String, size_limit: int, timeout_sec: float, target_file: String = "") -> int:
	_env_host = OS.get_environment(UpdateCheck.HOST_ENV)
	if not hop_refusal(url, _env_host).is_empty():
		return ERR_UNAUTHORIZED
	_http.body_size_limit = size_limit
	_http.timeout = timeout_sec
	_http.download_file = target_file
	_target_file = target_file
	_current_url = url
	_redirects = 0
	return _http.request(url, HttpIdentity.request_headers(), HTTPClient.METHOD_GET)


## Stops the running fetch, if any; [signal finished] does not follow.
func cancel() -> void:
	_http.cancel_request()
	_http.download_file = ""


func _on_request_completed(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if not is_redirect(result, code):
		_finish(result == HTTPRequest.RESULT_SUCCESS and code == 200, result, code, "", body)
		return
	var next_url := _next_url(_current_url, headers)
	if next_url.is_empty():
		_finish(false, result, code)
		return
	var refusal := REFUSED_TOO_MANY if _redirects >= MAX_REDIRECTS else hop_refusal(next_url, _env_host)
	if not refusal.is_empty():
		_finish(false, result, code, refusal)
		return
	# Up to 4.6 a 303, 307 or 308 is a plain reply, so its body went to the target file.
	_remove_target_file()
	_redirects += 1
	_current_url = next_url
	if _http.request(next_url, HttpIdentity.request_headers(), HTTPClient.METHOD_GET) != OK:
		_finish(false, result, code)


func _finish(succeeded: bool, result: int, code: int, refusal: String = "", body: PackedByteArray = PackedByteArray()) -> void:
	_http.download_file = ""
	if not succeeded:
		_remove_target_file()
	finished.emit({"ok": succeeded, "result": result, "code": code, "refusal": refusal, "body": body})


func _remove_target_file() -> void:
	if not _target_file.is_empty() and FileAccess.file_exists(_target_file):
		DirAccess.remove_absolute(_target_file)
