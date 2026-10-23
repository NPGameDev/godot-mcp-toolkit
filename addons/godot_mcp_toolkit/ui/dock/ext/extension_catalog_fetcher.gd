@tool
extends Node
## Fetches the extension catalog, falling back to the local cache when the fetch
## gives no usable catalog.
##
## A good reply is cached in full, stamped with the time it was written. A failed
## request, an unparseable reply or a catalog format newer than this toolkit reads
## leaves the cache as it was, and the outcome lists the cached entries instead, with
## a status line that says why. With no usable cache the outcome carries the message
## to show in place of the list.

## Emitted once per finished fetch, with an outcome in the shape
## [method resolve_and_cache_reply] documents.
signal catalog_resolved(outcome: Dictionary)

# Direct preloads, not core/modules.gd: the aggregator preloads this file.
const ExtensionCatalog := preload("res://addons/godot_mcp_toolkit/ui/dock/ext/extension_catalog.gd")
const HttpIdentity := preload("res://addons/godot_mcp_toolkit/core/http_identity.gd")

var _http: HTTPRequest = null


## The catalog fetch as [code]{"url": String, "headers": PackedStringArray}[/code]:
## the catalog URL and the toolkit's fixed HTTP identity.
static func catalog_request() -> Dictionary:
	return {"url": ExtensionCatalog.CATALOG_URL, "headers": HttpIdentity.request_headers()}


## Turns one catalog reply into an outcome, and writes the reply to the cache when
## it is a catalog this toolkit reads.
##
## Returns [code]{"extensions": Array, "unavailable": String, "status": String,
## "is_warning": bool, "newer_format": bool}[/code]. [code]extensions[/code] are the
## entries to list. A non-empty [code]unavailable[/code] is the message shown in
## place of the list, and [code]extensions[/code] is then empty. [code]status[/code]
## is the footer line, shown as a warning when [code]is_warning[/code].
## [code]newer_format[/code] means the reply's catalog format is newer than this
## toolkit reads, so the user should update the toolkit.
static func resolve_and_cache_reply(
		result: int, response_code: int, body: PackedByteArray) -> Dictionary:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		var code := response_code if result == HTTPRequest.RESULT_SUCCESS else result
		return resolve_from_cache("Fetch failed (%d) — showing cached catalog" % code)

	var json_text := body.get_string_from_utf8()
	var parsed := ExtensionCatalog.parse_catalog(json_text)

	if not parsed["ok"]:
		if str(parsed["error"]) == "NEWER_VERSION":
			# An incompatible reply is never cached.
			var outcome := resolve_from_cache(
					"Catalog format newer than supported — showing cached catalog",
			)
			outcome["newer_format"] = true
			return outcome
		return resolve_from_cache("Parse error — showing cached catalog")

	var raw: Variant = JSON.parse_string(json_text)
	if raw is Dictionary:
		ExtensionCatalog.write_cache(raw)
	var extensions: Array = parsed["extensions"]
	var status := "Catalog loaded — %d extension%s" % [
		extensions.size(), "" if extensions.size() == 1 else "s",
	]
	return _outcome(extensions, "", status, false)


## Builds the outcome for the cached catalog, with [param warning] as the reason
## the cache is shown. Returns the shape [method resolve_and_cache_reply]
## documents, with [code]newer_format[/code] false.
static func resolve_from_cache(warning: String) -> Dictionary:
	var cached := ExtensionCatalog.read_cache()
	if cached.is_empty():
		return _outcome(
				[],
				"Catalog unavailable — check your internet connection and try again.",
				warning if not warning.is_empty() else "No catalog available",
				true,
		)

	var parsed := ExtensionCatalog.parse_catalog(JSON.stringify(cached))
	if not parsed["ok"]:
		return _outcome([], "Catalog unavailable — cached data is invalid.", "Cache error", true)

	var cached_at: String = str(cached.get("_cached_at", "unknown"))
	return _outcome(parsed["extensions"], "", "%s (cached %s)" % [warning, cached_at], true)


static func _outcome(
		extensions: Array, unavailable: String, status: String, is_warning: bool) -> Dictionary:
	return {
		"extensions": extensions,
		"unavailable": unavailable,
		"status": status,
		"is_warning": is_warning,
		"newer_format": false,
	}


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)


func _exit_tree() -> void:
	if _http != null:
		_http.cancel_request()


## Starts a fetch, cancelling one still in flight. Does nothing until the node has
## entered the tree. A request that fails to start reports the cached catalog at
## once, through [signal catalog_resolved].
func fetch() -> void:
	if _http == null:
		return
	_http.cancel_request()
	var request := catalog_request()
	var err := _http.request(str(request["url"]), request["headers"])
	if err != OK:
		push_warning("[MCPCatalog] HTTP request failed to start (err %d)" % err)
		catalog_resolved.emit(resolve_from_cache("Network error — showing cached catalog"))


func _on_request_completed(
		result: int, response_code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	catalog_resolved.emit(resolve_and_cache_reply(result, response_code, body))
