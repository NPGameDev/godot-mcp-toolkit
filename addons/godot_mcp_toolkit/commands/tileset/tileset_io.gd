@tool
extends RefCounted
## Shared TileSet support leaf: load, validate, save-and-reindex a TileSet
## resource, plus the layer-node version hint and the full-tile polygon every
## tileset.* command group relies on.
##
## Stateless — every function takes its inputs (file path, TileSet, tile size) as
## parameters and returns its result (a TileSet-or-error Variant, an empty-or-error
## Dictionary, a hint String, or a polygon). No cross-call state; the file is all
## static, consumed by the tileset command children via a `preload` alias.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const FileGuard = Modules.FileGuard
const Helpers = Modules.CommandHelpers


## Load and validate a TileSet from file_path. Returns TileSet or error Dictionary.
static func load_tileset(file_path: String) -> Variant:
	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if not FileAccess.file_exists(file_path):
		return MCPToolkitError.fail("NOT_FOUND", "TileSet not found: %s" % file_path)
	var ts = ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if ts == null or not (ts is TileSet):
		return MCPToolkitError.fail("INVALID_CLASS",
			"Resource at %s is not a TileSet" % file_path)
	return ts


## Save a TileSet, reload cache, and index. Returns empty dict on success or error.
static func save_tileset(ts: TileSet, file_path: String) -> Dictionary:
	var save_err := ResourceSaver.save(ts, file_path)
	if save_err != OK:
		return MCPToolkitError.fail("SAVE_FAILED",
			"ResourceSaver.save returned %d (path=%s)" % [save_err, file_path])
	ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	await Helpers.ensure_file_indexed(file_path)
	return {}


## Build the response-tail hint that names the node a TileSet attaches to —
## TileMapLayer on 4.3+, TileMap on 4.2 — wrapped in the caller's prefix/suffix.
static func layer_node_hint(prefix: String, suffix: String) -> String:
	var ver := Modules.VersionUtils.get_engine_version_pair()
	var has_tilemaplayer := Modules.VersionUtils.is_at_least(ver, "4.3")
	var node_name := "TileMapLayer" if has_tilemaplayer else "TileMap"
	return prefix + node_name + suffix


## The unit rectangle spanning one tile (±w/2, ±h/2) — the default collision/nav/
## occlusion shape and the "full"/"one_way" collision shorthand.
static func build_full_tile_polygon(tile_size: Vector2i) -> PackedVector2Array:
	var hw := tile_size.x / 2.0
	var hh := tile_size.y / 2.0
	return PackedVector2Array([
		Vector2(-hw, -hh), Vector2(hw, -hh),
		Vector2(hw, hh), Vector2(-hw, hh)])
