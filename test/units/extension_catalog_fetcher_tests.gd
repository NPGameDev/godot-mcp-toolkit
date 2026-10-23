@tool
extends RefCounted
## Unit tests for the extension catalog fetcher: the outcome each reply and cache state
## resolves to, what reaches the cache, and the one outcome a finished request emits.
## Each cache case runs against its own temporary registry folder. No suite sends the
## live request to the catalog Gist, which needs the network; its URL and headers are
## pinned in update_check_tests.gd.

const Testing := preload("res://test/units/testing.gd")
const ExtensionCatalog := preload("res://addons/godot_mcp_toolkit/ui/dock/ext/extension_catalog.gd")
const ExtensionCatalogFetcher := preload(
		"res://addons/godot_mcp_toolkit/ui/dock/ext/extension_catalog_fetcher.gd")

const _NO_CACHE_MESSAGE := "Catalog unavailable — check your internet connection and try again."
const _CACHED_AT := "2026-01-02T03:04:05"
const _CACHED_CATALOG := (
	'{"catalog_version": 1, "extensions": [{"name": "Cached Ext"}], '
	+ '"_cached_at": "2026-01-02T03:04:05"}')
const _CACHED_ENTRIES := [{"name": "Cached Ext"}]


## [param tree] is the runner itself; its root joins the tree only after a frame.
static func run(testing: Testing, tree: SceneTree) -> void:
	_test_good_reply_lists_entries(testing)
	_test_loaded_status_counts_entries(testing)
	_test_good_reply_is_cached(testing)
	_test_http_error_shows_cache(testing)
	_test_transport_failure_names_result(testing)
	_test_newer_format_is_flagged_not_cached(testing)
	_test_unparseable_reply_without_cache(testing)
	_test_invalid_cache_is_reported(testing)
	_test_no_cache_and_no_reason(testing)
	await _test_finished_request_emits_one_outcome(testing, tree)
	_test_fetch_outside_tree_does_nothing(testing)


static func _test_good_reply_lists_entries(testing: Testing) -> void:
	testing.begin("Catalog fetcher: a good reply lists its entries")
	var cache := _redirect_cache("good_reply")
	if not cache["redirected"]:
		_skip_unredirected(testing, cache)
		return
	var outcome := ExtensionCatalogFetcher.resolve_and_cache_reply(HTTPRequest.RESULT_SUCCESS, 200,
			'{"catalog_version": 1, "extensions": [{"name": "A"}, {"name": "B"}]}'.to_utf8_buffer(),
	)
	_restore_cache(cache)

	testing.eq(outcome["extensions"], [{"name": "A"}, {"name": "B"}],
			"the reply's entries are listed",
	)
	testing.eq(outcome["unavailable"], "", "no message replaces the list")
	testing.eq(outcome["status"], "Catalog loaded — 2 extensions", "the status counts the entries")
	testing.eq(outcome["is_warning"], false, "the status is not a warning")
	testing.eq(outcome["newer_format"], false, "no update notice")
	print("")


static func _test_loaded_status_counts_entries(testing: Testing) -> void:
	testing.begin("Catalog fetcher: the loaded status counts entries, singular and plural")
	var cache := _redirect_cache("status_count")
	if not cache["redirected"]:
		_skip_unredirected(testing, cache)
		return
	var none := ExtensionCatalogFetcher.resolve_and_cache_reply(HTTPRequest.RESULT_SUCCESS, 200,
			'{"catalog_version": 1, "extensions": []}'.to_utf8_buffer(),
	)
	var one := ExtensionCatalogFetcher.resolve_and_cache_reply(HTTPRequest.RESULT_SUCCESS, 200,
			'{"catalog_version": 1, "extensions": [{"name": "A"}]}'.to_utf8_buffer(),
	)
	_restore_cache(cache)

	testing.eq(none["status"], "Catalog loaded — 0 extensions", "zero entries read in the plural")
	testing.eq(one["status"], "Catalog loaded — 1 extension", "one entry reads in the singular")
	print("")


static func _test_good_reply_is_cached(testing: Testing) -> void:
	testing.begin("Catalog fetcher: a good reply is cached")
	var cache := _redirect_cache("good_cached")
	if not cache["redirected"]:
		_skip_unredirected(testing, cache)
		return
	# The outcome is discarded: this case checks only the cache write.
	ExtensionCatalogFetcher.resolve_and_cache_reply(HTTPRequest.RESULT_SUCCESS, 200,
			'{"catalog_version": 1, "extensions": [{"name": "A"}]}'.to_utf8_buffer(),
	)
	var cached := ExtensionCatalog.read_cache()
	_restore_cache(cache)

	testing.eq(cached.get("catalog_version"), 1.0, "the cache holds the reply's format version")
	testing.eq(cached.get("extensions"), [{"name": "A"}], "the cache holds the reply's entries")
	testing.ok(cached.has("_cached_at"), "the cache records when it was written")
	print("")


static func _test_http_error_shows_cache(testing: Testing) -> void:
	testing.begin("Catalog fetcher: an HTTP error status shows the cache and keeps it")
	var cache := _redirect_cache("http_error")
	if not cache["redirected"]:
		_skip_unredirected(testing, cache)
		return
	_seed_cache(_CACHED_CATALOG)
	var outcome := ExtensionCatalogFetcher.resolve_and_cache_reply(HTTPRequest.RESULT_SUCCESS, 404,
			'{"catalog_version": 1, "extensions": [{"name": "A"}]}'.to_utf8_buffer(),
	)
	var cached := ExtensionCatalog.read_cache()
	_restore_cache(cache)

	testing.eq(outcome["extensions"], _CACHED_ENTRIES, "the cached entries are listed")
	testing.eq(outcome["unavailable"], "", "no message replaces the list")
	testing.eq(outcome["status"],
			"Fetch failed (404) — showing cached catalog (cached %s)" % _CACHED_AT,
			"the status names the HTTP status and the cache time",
	)
	testing.eq(outcome["is_warning"], true, "the status is a warning")
	testing.eq(cached.get("extensions"), _CACHED_ENTRIES, "the cache is left as it was")
	print("")


static func _test_transport_failure_names_result(testing: Testing) -> void:
	testing.begin("Catalog fetcher: a failed connection with no cache shows the offline message")
	var cache := _redirect_cache("transport")
	if not cache["redirected"]:
		_skip_unredirected(testing, cache)
		return
	var outcome := ExtensionCatalogFetcher.resolve_and_cache_reply(
			HTTPRequest.RESULT_CANT_CONNECT, 0, PackedByteArray(),
	)
	_restore_cache(cache)

	testing.eq(outcome["extensions"], [], "nothing is listed")
	testing.eq(outcome["unavailable"], _NO_CACHE_MESSAGE, "the offline message replaces the list")
	testing.eq(outcome["status"], "Fetch failed (2) — showing cached catalog",
			"the status names the request result, not the HTTP status",
	)
	testing.eq(outcome["is_warning"], true, "the status is a warning")
	print("")


static func _test_newer_format_is_flagged_not_cached(testing: Testing) -> void:
	testing.begin("Catalog fetcher: a newer catalog format asks for an update and is not cached")
	var cache := _redirect_cache("newer_format")
	if not cache["redirected"]:
		_skip_unredirected(testing, cache)
		return
	_seed_cache(_CACHED_CATALOG)
	var outcome := ExtensionCatalogFetcher.resolve_and_cache_reply(HTTPRequest.RESULT_SUCCESS, 200,
			'{"catalog_version": 2, "extensions": [{"name": "New"}]}'.to_utf8_buffer(),
	)
	var cached := ExtensionCatalog.read_cache()
	_restore_cache(cache)

	testing.eq(outcome["newer_format"], true, "the update notice is raised")
	testing.eq(outcome["extensions"], _CACHED_ENTRIES, "the cached entries are listed")
	testing.eq(outcome["status"],
			"Catalog format newer than supported — showing cached catalog (cached %s)" % _CACHED_AT,
			"the status says the format is newer",
	)
	testing.eq(cached.get("extensions"), _CACHED_ENTRIES, "the newer reply is not cached")
	print("")


static func _test_unparseable_reply_without_cache(testing: Testing) -> void:
	testing.begin("Catalog fetcher: an unparseable reply with no cache shows the offline message")
	var cache := _redirect_cache("unparseable")
	if not cache["redirected"]:
		_skip_unredirected(testing, cache)
		return
	var outcome := ExtensionCatalogFetcher.resolve_and_cache_reply(
			HTTPRequest.RESULT_SUCCESS, 200, "not json".to_utf8_buffer(),
	)
	var cached := ExtensionCatalog.read_cache()
	_restore_cache(cache)

	testing.eq(outcome["unavailable"], _NO_CACHE_MESSAGE, "the offline message replaces the list")
	testing.eq(outcome["status"], "Parse error — showing cached catalog",
			"the status says the reply did not parse",
	)
	testing.eq(outcome["newer_format"], false, "no update notice")
	testing.eq(cached, {}, "nothing is cached")
	print("")


static func _test_invalid_cache_is_reported(testing: Testing) -> void:
	testing.begin("Catalog fetcher: a cache that does not parse as a catalog is reported")
	var cache := _redirect_cache("invalid_cache")
	if not cache["redirected"]:
		_skip_unredirected(testing, cache)
		return
	_seed_cache('{"catalog_version": 0, "extensions": [{"name": "Cached Ext"}]}')
	var outcome := ExtensionCatalogFetcher.resolve_from_cache(
			"Network error — showing cached catalog",
	)
	_restore_cache(cache)

	testing.eq(outcome["extensions"], [], "nothing is listed")
	testing.eq(outcome["unavailable"], "Catalog unavailable — cached data is invalid.",
			"the invalid-cache message replaces the list",
	)
	testing.eq(outcome["status"], "Cache error", "the status names the cache error")
	testing.eq(outcome["is_warning"], true, "the status is a warning")
	print("")


static func _test_no_cache_and_no_reason(testing: Testing) -> void:
	testing.begin("Catalog fetcher: no cache and no reason reads as no catalog")
	var cache := _redirect_cache("no_reason")
	if not cache["redirected"]:
		_skip_unredirected(testing, cache)
		return
	var outcome := ExtensionCatalogFetcher.resolve_from_cache("")
	_restore_cache(cache)

	testing.eq(outcome["unavailable"], _NO_CACHE_MESSAGE, "the offline message replaces the list")
	testing.eq(outcome["status"], "No catalog available", "the status says there is no catalog")
	print("")


static func _test_finished_request_emits_one_outcome(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Catalog fetcher: a finished request emits its outcome once")
	await tree.process_frame
	var cache := _redirect_cache("emits")
	if not cache["redirected"]:
		_skip_unredirected(testing, cache)
		return
	var fetcher := ExtensionCatalogFetcher.new()
	var emissions: Array[Dictionary] = []
	fetcher.catalog_resolved.connect(func(outcome: Dictionary) -> void: emissions.append(outcome))
	tree.root.add_child(fetcher)
	# The reply arrives through the fetcher's HTTPRequest, the network boundary this
	# headless run stands in for.
	var http: HTTPRequest = null
	for child: Node in fetcher.get_children():
		if child is HTTPRequest:
			http = child as HTTPRequest
	var has_http := http != null
	if has_http:
		http.request_completed.emit(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(),
				'{"catalog_version": 1, "extensions": [{"name": "A"}]}'.to_utf8_buffer(),
		)
	tree.root.remove_child(fetcher)
	fetcher.free()
	_restore_cache(cache)

	testing.ok(has_http, "the fetcher owns an HTTPRequest once in the tree")
	testing.eq(emissions.size(), 1, "one outcome is emitted")
	testing.eq(
			emissions[0] if emissions.size() == 1 else {},
			{
				"extensions": [{"name": "A"}],
				"unavailable": "",
				"status": "Catalog loaded — 1 extension",
				"is_warning": false,
				"newer_format": false,
			},
			"the emitted outcome is the reply's",
	)
	print("")


static func _test_fetch_outside_tree_does_nothing(testing: Testing) -> void:
	testing.begin("Catalog fetcher: a fetch before the fetcher enters the tree does nothing")
	var fetcher := ExtensionCatalogFetcher.new()
	var emissions: Array[Dictionary] = []
	fetcher.catalog_resolved.connect(func(outcome: Dictionary) -> void: emissions.append(outcome))
	fetcher.fetch()
	fetcher.free()

	testing.eq(emissions.size(), 0, "no outcome is emitted")
	print("")


# Points the registry folder, where the catalog cache lives, at a fresh temporary
# folder for one case. Returns what _restore_cache needs to undo it.
static func _redirect_cache(case_name: String) -> Dictionary:
	var env_name := _registry_env_name()
	var root := ProjectSettings.globalize_path(
			"user://_test_catalog_fetcher_%s_%d" % [case_name, OS.get_process_id()],
	)
	var state := {
		"env_name": env_name,
		"had_env": OS.has_environment(env_name),
		"prev_env": OS.get_environment(env_name),
		"root": root,
	}
	_remove_tree(root)
	DirAccess.make_dir_recursive_absolute(root)
	OS.set_environment(env_name, root)
	state["redirected"] = ExtensionCatalog.cache_path().begins_with(root)
	return state


static func _restore_cache(state: Dictionary) -> void:
	var env_name: String = state["env_name"]
	if bool(state["had_env"]):
		OS.set_environment(env_name, str(state["prev_env"]))
	else:
		OS.unset_environment(env_name)
	_remove_tree(str(state["root"]))


# Restores the environment and fails the group without touching the real cache.
static func _skip_unredirected(testing: Testing, state: Dictionary) -> void:
	_restore_cache(state)
	testing.ok(false, "the registry folder is the temporary folder; cache writes skipped")
	print("")


static func _seed_cache(text: String) -> void:
	var file := FileAccess.open(ExtensionCatalog.cache_path(), FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()


# The environment variable the registry folder builds on for this OS.
static func _registry_env_name() -> String:
	match OS.get_name():
		"Windows":
			return "APPDATA"
		"macOS":
			return "HOME"
		_:
			return "XDG_DATA_HOME"


# Deletes a folder and everything under it; a missing folder is a no-op.
static func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for sub: String in dir.get_directories():
		_remove_tree(path.path_join(sub))
	for file_name: String in dir.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	DirAccess.remove_absolute(path)
