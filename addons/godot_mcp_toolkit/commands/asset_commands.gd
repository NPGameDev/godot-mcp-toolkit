@tool
extends RefCounted
## asset.* command handlers — list, get_dependencies, import binary assets.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const FileGuard = Modules.FileGuard
const Helpers = Modules.CommandHelpers

const IMPORT_ALLOWED_EXTENSIONS := [
	# Images
	"png", "jpg", "jpeg", "webp", "svg", "bmp", "tga", "hdr", "exr",
	# Audio
	"wav", "ogg", "mp3",
	# 3D models
	"glb", "gltf", "obj", "fbx", "blend", "dae",
	# Fonts
	"ttf", "otf", "woff", "woff2",
	# Translations
	"po", "csv",
	# Video
	"ogv",
]
const IMPORT_MAX_FILE_BYTES := 50 * 1024 * 1024
const IMPORT_MAX_BASE64_BYTES := 5 * 1024 * 1024


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("asset.list", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_asset_list(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
	registry.add("asset.get_dependencies", func(parameters: Dictionary) -> Dictionary:
		return _cmd_asset_get_dependencies(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
	registry.add("asset.import", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_asset_import(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())


# -- Helpers ------------------------------------------------------------------


static func _walk_filesystem_directory(
	directory: EditorFileSystemDirectory,
	name_glob: String,
	class_filter: String,
	extension_filter: Array[String],
	entries: Array,
	max_count: int,
) -> int:
	# Returns the FULL count of matching assets in this subtree (drives total_assets).
	# Collecting into `entries` stops once it hits max_count, but counting
	# continues past the cap — mirrors spatial_map's "keep counting total, stop
	# collecting". The walk is over the in-memory EditorFileSystem cache.
	var total := 0
	for index in range(directory.get_file_count()):
		var file_path := directory.get_file_path(index)
		var file_name := directory.get_file(index)
		var file_type := directory.get_file_type(index)
		if name_glob != "" and not file_name.matchn(name_glob):
			continue
		if extension_filter.size() > 0 \
				and not file_name.get_extension().to_lower() in extension_filter:
			continue
		if class_filter != "":
			if file_type != class_filter \
					and not ClassDB.is_parent_class(file_type, class_filter):
				continue
		var mtime := FileAccess.get_modified_time(file_path)
		# Ghost filter: EditorFileSystem may retain stale entries after
		# deletion (mtime 0 = file gone from disk but index not flushed).
		if mtime == 0 and not FileAccess.file_exists(file_path):
			continue
		total += 1
		if entries.size() < max_count:
			entries.append({
				"path": file_path,
				"class": file_type,
				"size_bytes": null,
				"modified_unix": mtime,
			})
	for subdir_index in range(directory.get_subdir_count()):
		total += _walk_filesystem_directory(
			directory.get_subdir(subdir_index),
			name_glob, class_filter, extension_filter, entries, max_count)
	return total


# -- Commands -----------------------------------------------------------------


static func _cmd_asset_list(parameters: Dictionary) -> Dictionary:
	var path_prefix: String = str(parameters.get("path_prefix", "res://"))
	var name_glob: String = str(parameters.get("name_glob", ""))
	var class_filter: String = str(parameters.get("class_filter", ""))
	var extension_filter: Array = parameters.get("extension_filter", [])
	if typeof(extension_filter) != TYPE_ARRAY:
		extension_filter = []
	var requested_limit: int = int(parameters.get("limit", 500))

	var guard := FileGuard.resolve_safe(path_prefix)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	# Validation split: a non-positive limit is a caller error (reject); an over-max
	# limit is clamped and disclosed, so a caller that asks for "everything" gets the
	# capped page plus limit_clamped rather than a hard failure.
	if requested_limit < 1:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"limit must be >= 1 (got %d)" % requested_limit)
	var max_results: int = mini(requested_limit, 2000)
	var limit_clamped := requested_limit > 2000
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem.is_scanning():
		return MCPToolkitError.fail("FILESYSTEM_NOT_READY",
			"Godot's EditorFileSystem is mid-scan; call editor.wait_for_idle to poll until ready, or retry in 500-2000ms")
	if class_filter != "":
		var found_in_classdb := ClassDB.class_exists(class_filter)
		var found_in_global := false
		if not found_in_classdb:
			for global_class_entry in ProjectSettings.get_global_class_list():
				if global_class_entry.get("class", "") == class_filter:
					found_in_global = true
					break
		if not found_in_classdb and not found_in_global:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"unknown class_filter '%s'; checked ClassDB (engine classes) and ProjectSettings.get_global_class_list() (GDScript class_name / C# [GlobalClass])" % class_filter)

	var normalized_extension_filter: Array[String] = []
	for extension in extension_filter:
		var ext := str(extension).to_lower()
		if ext.begins_with("."):
			ext = ext.substr(1)
		normalized_extension_filter.append(ext)

	var root_directory := filesystem.get_filesystem_path(path_prefix)
	if root_directory == null:
		# Intentional full scan(): update_file() is file-level only and does not
		# index directories. This path triggers when a directory exists on disk
		# but hasn't been indexed yet — rare, and scan() is the correct tool.
		var abs_path := ProjectSettings.globalize_path(path_prefix)
		if DirAccess.dir_exists_absolute(abs_path):
			filesystem.scan()
			# Wait up to 5s for scan to finish (matches editor_refresh timeout)
			var scan_start := Time.get_ticks_msec()
			while filesystem.is_scanning() and Time.get_ticks_msec() - scan_start < 5000:
				await Engine.get_main_loop().create_timer(0.1).timeout
			root_directory = filesystem.get_filesystem_path(path_prefix)
		if root_directory == null:
			return MCPToolkitError.fail("NOT_FOUND",
				"no indexed directory at %s (path may exist on disk but not yet scanned — call editor.refresh or wait for is_scanning to clear)" % path_prefix, MCPToolkitError.HINT_FILE_PATH)

	var entries: Array = []
	var total_assets := _walk_filesystem_directory(
		root_directory, name_glob, class_filter,
		normalized_extension_filter, entries, max_results)
	var has_more := total_assets > entries.size()

	# total_assets: the full match count (count-past-cap). Cursor-less — the depth-first
	# FS walk is not linearly resumable, so the hint advises narrowing filters / raising limit.
	var hint := ""
	if has_more:
		hint = "%d of %d assets returned (capped at limit) — narrow with path_prefix/name_glob/class_filter/extension_filter, or raise limit (<= 2000)." % [entries.size(), total_assets]
	var extras: Dictionary = {
		"path_prefix": path_prefix,
		"filters_applied": {
			"name_glob": name_glob,
			"class_filter": class_filter,
			"extension_filter": normalized_extension_filter,
		},
	}
	if limit_clamped:
		extras["limit_clamped"] = true
		var clamp_clause := "requested limit exceeds max 2000; clamped to 2000 — narrow filters to see the rest"
		hint = clamp_clause if hint.is_empty() else "%s %s" % [hint, clamp_clause]
	return MCPToolkitSuccess.ok(Modules.Pagination.build(
		{"entries": entries}, "assets", total_assets, entries.size(), has_more,
		"", 0, hint, extras))


static func _cmd_asset_get_dependencies(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path"])
	if err != null:
		return err
	var file_path: String = str(parameters.get("file_path", ""))
	var include_transitive: bool = bool(parameters.get("include_transitive", false))
	var max_results: int = int(parameters.get("limit", 200))

	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if not FileAccess.file_exists(file_path):
		return MCPToolkitError.fail("NOT_FOUND", "no file at %s" % file_path, MCPToolkitError.HINT_FILE_PATH)
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem.is_scanning():
		return MCPToolkitError.fail("FILESYSTEM_NOT_READY",
			"Godot's EditorFileSystem is mid-scan; call editor.wait_for_idle to poll until ready, or retry in 500-2000ms")

	var dependencies: Array = []
	var visited: Dictionary = {}
	var queue: Array[String] = [file_path]
	visited[file_path] = true
	var truncated := false
	var total_dependencies := 0
	var depth := 0
	const MAX_TRANSITIVE_DEPTH := 50

	# Count every unique dependency for total_dependencies, but stop COLLECTING rows
	# once the cap is hit (count-past-cap, still bounded by MAX_TRANSITIVE_DEPTH). The first limit
	# collected rows are byte-identical to before — only counting continues past it.
	while queue.size() > 0:
		var current := queue.pop_front() as String
		var raw_dependencies := ResourceLoader.get_dependencies(current)
		for raw_dependency in raw_dependencies:
			var raw_string := String(raw_dependency)
			var parts: PackedStringArray = raw_string.split("::")
			var stripped := parts[0]
			var dependency_class := ""
			if stripped.begins_with("uid://"):
				for part_index in range(1, parts.size()):
					if parts[part_index].begins_with("res://"):
						stripped = parts[part_index]
						break
			for part_index in range(parts.size()):
				var segment := parts[part_index]
				if segment != "" and not segment.begins_with("uid://") \
						and not segment.begins_with("res://"):
					dependency_class = segment
					break
			if stripped.is_empty():
				continue
			if visited.has(stripped):
				continue
			visited[stripped] = true
			total_dependencies += 1
			if dependencies.size() < max_results:
				dependencies.append({
					"path": stripped,
					"raw_path": raw_string,
					"class": dependency_class,
				})
			else:
				truncated = true
			if include_transitive:
				if FileAccess.file_exists(stripped):
					queue.append(stripped)
		depth += 1
		if depth > MAX_TRANSITIVE_DEPTH:
			truncated = true
			break

	var warnings: Array[String] = []
	if depth > MAX_TRANSITIVE_DEPTH:
		warnings.append(
			"transitive walk exceeded 50 levels — truncated to prevent unbounded recursion")

	var hint := ""
	if truncated:
		hint = "%d of %d dependencies returned (capped at limit) — raise limit (no cursor), or set include_transitive=false to reduce the set." % [dependencies.size(), total_dependencies]
	return MCPToolkitSuccess.ok(Modules.Pagination.build(
		{"path": file_path, "dependencies": dependencies},
		"dependencies", total_dependencies, dependencies.size(), truncated,
		"", 0, hint, {"include_transitive": include_transitive, "warnings": warnings}))


static func _cmd_asset_import(parameters: Dictionary) -> Dictionary:
	var source_path: String = str(parameters.get("source_path", ""))
	var base64_data: String = str(parameters.get("base64_data", ""))
	var dest_path: String = str(parameters.get("dest_path", ""))
	var if_exists: String = str(parameters.get("if_exists", "return"))
	var wait_for_scan_ms: int = int(parameters.get("wait_for_scan_ms", 5000))

	# Extension allowlist — rich asset.import hint kept here; the shared helper
	# re-checks generically for the other callers.
	var extension := dest_path.get_extension().to_lower()
	if extension not in IMPORT_ALLOWED_EXTENSIONS:
		return MCPToolkitError.fail("INVALID_PATH",
			"extension '%s' not in import allowlist: %s; use script.write for .gd/.cs, resource.write for .tres/.res, scene.create for .tscn" % [
				extension, ", ".join(PackedStringArray(IMPORT_ALLOWED_EXTENSIONS))])
	var has_source := source_path != ""
	var has_base64 := base64_data != ""
	if has_source and has_base64:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"provide exactly one of source_path or base64_data, not both")
	if not has_source and not has_base64:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"provide source_path (absolute filesystem path) or base64_data (base64-encoded file content)")

	# Source-path mode guards
	if has_source:
		if source_path.begins_with("res://") or source_path.begins_with("user://"):
			source_path = ProjectSettings.globalize_path(source_path)
		if not FileAccess.file_exists(source_path):
			return MCPToolkitError.fail("NOT_FOUND",
				"source file not found: %s" % source_path, MCPToolkitError.HINT_FILE_PATH)
		var source_file := FileAccess.open(source_path, FileAccess.READ)
		if source_file == null:
			return MCPToolkitError.fail("READ_FAILED",
				"cannot read source file %s (err %d)" % [
					source_path, FileAccess.get_open_error()])
		var source_size := source_file.get_length()
		source_file.close()
		if source_size > IMPORT_MAX_FILE_BYTES:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"source file %d bytes exceeds 50 MB limit" % source_size)

	var decoded_bytes := PackedByteArray()
	if has_base64:
		decoded_bytes = Marshalls.base64_to_raw(base64_data)
		if decoded_bytes.is_empty() and base64_data.length() > 0:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"base64_data is not valid base64")
		if decoded_bytes.size() > IMPORT_MAX_BASE64_BYTES:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"decoded base64 data %d bytes exceeds 5 MB limit" % decoded_bytes.size())

	var bytes_to_write: PackedByteArray
	var source_label: String
	if has_source:
		bytes_to_write = FileAccess.get_file_as_bytes(source_path)
		if FileAccess.get_open_error() != OK:
			return MCPToolkitError.fail("READ_FAILED",
				"cannot read source file %s (err %d)" % [
					source_path, FileAccess.get_open_error()])
		source_label = "filesystem"
	else:
		bytes_to_write = decoded_bytes
		source_label = "base64"

	# Shared write + import-settle bracket. The helper validates if_exists /
	# wait_for_scan_ms, guards the path, handles if_exists / parent-dir, runs the
	# write_fn below, and settles the import — identical to texture.generate /
	# sound.generate. Only the raw-bytes write differs, so it lives in write_fn.
	var write_fn := func(write_path: String) -> Dictionary:
		var file_handle := FileAccess.open(write_path, FileAccess.WRITE)
		if file_handle == null:
			return MCPToolkitError.fail("WRITE_FAILED",
				"cannot open %s for writing (err %d)" % [
					write_path, FileAccess.get_open_error()])
		file_handle.store_buffer(bytes_to_write)
		file_handle.close()
		return {}

	var result := await Helpers.write_asset_with_settle(
		dest_path, PackedStringArray(IMPORT_ALLOWED_EXTENSIONS),
		if_exists, wait_for_scan_ms, "asset.import", write_fn)
	if not result.get("success", false):
		return result

	# asset.import-specific payload fields.
	if result.get("status") == "returned":
		result["source"] = null
	else:
		result["source"] = source_label
		result["size_bytes"] = bytes_to_write.size()
	return result
