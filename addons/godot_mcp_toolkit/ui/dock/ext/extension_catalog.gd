@tool
extends RefCounted
## Extension catalog data layer — fetch URL, parse logic, cache I/O, and version comparison.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const RegistryClient = Modules.RegistryClient

const CATALOG_URL := "https://gist.githubusercontent.com/NPGameDev/bca160bce1888bbb92082e13f9541bca/raw/catalog.json"
const _CACHE_FILENAME := "catalog_cache.json"
const SUPPORTED_CATALOG_VERSION := 1


## Path to the cache file in the system-level data directory.
static func cache_path() -> String:
	return RegistryClient.registry_dir().path_join(_CACHE_FILENAME)


## Read cached catalog JSON. Returns empty Dictionary on miss or error.
static func read_cache() -> Dictionary:
	var path := cache_path()
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		return {}
	return parsed


## Write catalog JSON to cache with a _cached_at timestamp.
static func write_cache(data: Dictionary) -> void:
	var path := cache_path()
	var enriched := data.duplicate(true)
	enriched["_cached_at"] = Time.get_datetime_string_from_system(true)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[MCPCatalog] cannot write cache to %s" % path)
		return
	f.store_string(JSON.stringify(enriched, "\t"))
	f.close()


## Parse catalog JSON text.
## Returns { "ok": bool, "extensions": Array, "error": String }.
## Special error "NEWER_VERSION" means the user should update the toolkit.
static func parse_catalog(json_text: String) -> Dictionary:
	var parsed = JSON.parse_string(json_text)
	if parsed == null or not parsed is Dictionary:
		return {"ok": false, "extensions": [], "error": "Invalid JSON"}

	var version = parsed.get("catalog_version", null)
	if version == null or not (version is int or version is float):
		return {"ok": false, "extensions": [], "error": "Missing or invalid catalog_version"}

	var ver_int := int(version)
	if ver_int == 0:
		return {"ok": false, "extensions": [], "error": "Invalid catalog_version (0)"}
	if ver_int > SUPPORTED_CATALOG_VERSION:
		return {"ok": false, "extensions": [], "error": "NEWER_VERSION"}

	var extensions = parsed.get("extensions", [])
	if not extensions is Array:
		return {"ok": false, "extensions": [], "error": "Invalid extensions field"}

	return {"ok": true, "extensions": extensions, "error": ""}


## Gate a catalog repo URL before it reaches OS.shell_open. The catalog is a
## remote, maintainer-edited Gist (untrusted input flowing into a shell sink), so
## only an https:// URL may be opened — this blocks file://, javascript:, and other
## scheme-based bypasses regardless of the entry's trust status. Scheme-only by
## design: a community extension on any host (GitLab, Codeberg, …) must still open.
static func is_allowed_repo_url(url: String) -> bool:
	var trimmed := url.strip_edges()
	if trimmed.is_empty():
		return false
	# Case-fold a copy for the check; callers open the ORIGINAL, unmutated URL.
	return trimmed.to_lower().begins_with("https://")


## Compare two semver strings ("1.2.3" vs "1.3.0").
## Returns -1 if a < b, 0 if equal, 1 if a > b.
## Assumes numeric dotted versions only ("1.2.3"); a pre-release/build tag on a
## segment ("1.0.0-beta") is not ordered against its release — the leading numeric
## run of each segment is compared and the suffix ignored. The catalog is
## author-controlled, so non-numeric versions are out of scope, not an error.
static func compare_versions(a: String, b: String) -> int:
	var pa := a.split(".")
	var pb := b.split(".")
	for i in maxi(pa.size(), pb.size()):
		var va := _leading_int(pa[i]) if i < pa.size() else 0
		var vb := _leading_int(pb[i]) if i < pb.size() else 0
		if va < vb:
			return -1
		if va > vb:
			return 1
	return 0


## Numeric lead of one dotted segment: the part before any "-"/"+" pre-release or
## build tag. For a plain numeric segment this is identical to int(part), so valid
## numeric-version ordering is unchanged.
static func _leading_int(part: String) -> int:
	var head := part
	var dash := head.find("-")
	if dash != -1:
		head = head.substr(0, dash)
	var plus := head.find("+")
	if plus != -1:
		head = head.substr(0, plus)
	return int(head)


## Check if the extension entry is compatible with current toolkit + Godot.
static func is_compatible(entry: Dictionary, toolkit_version: String, godot_version: String) -> bool:
	var min_tk: String = str(entry.get("min_toolkit_version", ""))
	if not min_tk.is_empty() and compare_versions(toolkit_version, min_tk) < 0:
		return false
	var max_tk = entry.get("max_toolkit_version", null)
	if max_tk != null and not str(max_tk).is_empty():
		if compare_versions(toolkit_version, str(max_tk)) > 0:
			return false
	var min_gd: String = str(entry.get("min_godot_version", ""))
	if not min_gd.is_empty() and compare_versions(godot_version, min_gd) < 0:
		return false
	var max_gd = entry.get("max_godot_version", null)
	if max_gd != null and not str(max_gd).is_empty():
		if compare_versions(godot_version, str(max_gd)) > 0:
			return false
	return true


## Read toolkit version from plugin.cfg.
static func get_toolkit_version() -> String:
	var cfg := ConfigFile.new()
	var err := cfg.load("res://addons/godot_mcp_toolkit/plugin.cfg")
	if err != OK:
		return "0.0.0"
	return cfg.get_value("plugin", "version", "0.0.0")


## Read Godot version as "major.minor" string.
static func get_godot_version() -> String:
	var vi := Engine.get_version_info()
	return "%d.%d" % [vi["major"], vi["minor"]]
