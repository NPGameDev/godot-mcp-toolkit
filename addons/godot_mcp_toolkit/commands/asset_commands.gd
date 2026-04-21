@tool
extends RefCounted
## asset.* command handlers — list, get_dependencies, import binary assets.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPCommandRegistry = _Hub.MCPCommandRegistry
const MCPFileGuard = _Hub.MCPFileGuard

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


static func register(registry: MCPCommandRegistry, _server: Node) -> void:
	registry.add("asset.list", func(parameters: Dictionary) -> Dictionary:
		return _cmd_asset_list(parameters))
	registry.add("asset.get_dependencies", func(parameters: Dictionary) -> Dictionary:
		return _cmd_asset_get_dependencies(parameters))
	registry.add("asset.import", func(parameters: Dictionary) -> Dictionary:
		return _cmd_asset_import(parameters))


# -- Helpers ------------------------------------------------------------------


static func _walk_filesystem_directory(
	directory: EditorFileSystemDirectory,
	name_glob: String,
	class_filter: String,
	extension_filter: Array[String],
	entries: Array,
	max_count: int,
) -> bool:
	for index in range(directory.get_file_count()):
		if entries.size() >= max_count:
			return true
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
		entries.append({
			"path": file_path,
			"class": file_type,
			"size_bytes": null,
			"modified_unix": FileAccess.get_modified_time(file_path),
		})
	for subdir_index in range(directory.get_subdir_count()):
		if entries.size() >= max_count:
			return true
		if _walk_filesystem_directory(
				directory.get_subdir(subdir_index),
				name_glob, class_filter, extension_filter, entries, max_count):
			return true
	return false


# -- Commands -----------------------------------------------------------------


static func _cmd_asset_list(parameters: Dictionary) -> Dictionary:
	var path_prefix: String = str(parameters.get("path_prefix", "res://"))
	var name_glob: String = str(parameters.get("name_glob", ""))
	var class_filter: String = str(parameters.get("class_filter", ""))
	var extension_filter: Array = parameters.get("extension_filter", [])
	if typeof(extension_filter) != TYPE_ARRAY:
		extension_filter = []
	var max_results: int = int(parameters.get("max_results", 500))

	var guard := MCPFileGuard.resolve_safe(path_prefix)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	if max_results < 1 or max_results > 2000:
		return MCPError.make("INVALID_PARAMS",
			"max_results must be in [1, 2000] (got %d)" % max_results)
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem.is_scanning():
		return MCPError.make("FILESYSTEM_NOT_READY",
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
			return MCPError.make("INVALID_PARAMS",
				"unknown class_filter '%s'; checked ClassDB (engine classes) and ProjectSettings.get_global_class_list() (GDScript class_name / C# [GlobalClass])" % class_filter)

	var normalized_extension_filter: Array[String] = []
	for extension in extension_filter:
		normalized_extension_filter.append(str(extension).to_lower())

	var root_directory := filesystem.get_filesystem_path(path_prefix)
	if root_directory == null:
		return MCPError.make("NOT_FOUND",
			"no indexed directory at %s (path may exist on disk but not yet scanned — call editor.reload_scripts or wait for is_scanning to clear)" % path_prefix)

	var entries: Array = []
	var truncated := _walk_filesystem_directory(
		root_directory, name_glob, class_filter,
		normalized_extension_filter, entries, max_results)

	return {
		"success": true,
		"entries": entries,
		"count": entries.size(),
		"truncated": truncated,
		"path_prefix": path_prefix,
		"filters_applied": {
			"name_glob": name_glob,
			"class_filter": class_filter,
			"extension_filter": normalized_extension_filter,
		},
	}


static func _cmd_asset_get_dependencies(parameters: Dictionary) -> Dictionary:
	var file_path: String = str(parameters.get("file_path", ""))
	var include_transitive: bool = bool(parameters.get("include_transitive", false))
	var max_results: int = int(parameters.get("max_results", 200))

	var guard := MCPFileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	if not FileAccess.file_exists(file_path):
		return MCPError.make("NOT_FOUND", "no file at %s" % file_path)
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem.is_scanning():
		return MCPError.make("FILESYSTEM_NOT_READY",
			"Godot's EditorFileSystem is mid-scan; call editor.wait_for_idle to poll until ready, or retry in 500-2000ms")

	var dependencies: Array = []
	var visited: Dictionary = {}
	var queue: Array[String] = [file_path]
	visited[file_path] = true
	var truncated := false
	var depth := 0
	const MAX_TRANSITIVE_DEPTH := 50

	while queue.size() > 0 and not truncated:
		var current := queue.pop_front() as String
		var raw_dependencies := ResourceLoader.get_dependencies(current)
		for raw_dependency in raw_dependencies:
			if dependencies.size() >= max_results:
				truncated = true
				break
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
			dependencies.append({
				"path": stripped,
				"raw_path": raw_string,
				"class": dependency_class,
			})
			if include_transitive:
				if FileAccess.file_exists(stripped):
					queue.append(stripped)
		depth += 1
		if depth > MAX_TRANSITIVE_DEPTH:
			truncated = true

	var warnings: Array[String] = []
	if depth > MAX_TRANSITIVE_DEPTH:
		warnings.append(
			"transitive walk exceeded 50 levels — truncated to prevent unbounded recursion")

	return {
		"success": true,
		"path": file_path,
		"dependencies": dependencies,
		"count": dependencies.size(),
		"truncated": truncated,
		"include_transitive": include_transitive,
		"warnings": warnings,
	}


static func _cmd_asset_import(parameters: Dictionary) -> Dictionary:
	var source_path: String = str(parameters.get("source_path", ""))
	var base64_data: String = str(parameters.get("base64_data", ""))
	var dest_path: String = str(parameters.get("dest_path", ""))
	var if_exists: String = str(parameters.get("if_exists", "return"))
	var wait_for_scan_ms: int = int(parameters.get("wait_for_scan_ms", 5000))

	var guard := MCPFileGuard.resolve_safe(dest_path)
	if guard["error"] != null:
		return MCPError.make("PATH_DENIED", str(guard["reason"]))
	var extension := dest_path.get_extension().to_lower()
	if extension not in IMPORT_ALLOWED_EXTENSIONS:
		return MCPError.make("INVALID_PATH",
			"extension '%s' not in import allowlist: %s; use script.write for .gd/.cs, resource.write for .tres/.res, scene.create for .tscn" % [
				extension, ", ".join(PackedStringArray(IMPORT_ALLOWED_EXTENSIONS))])
	var has_source := source_path != ""
	var has_base64 := base64_data != ""
	if has_source and has_base64:
		return MCPError.make("INVALID_PARAMS",
			"provide exactly one of source_path or base64_data, not both")
	if not has_source and not has_base64:
		return MCPError.make("INVALID_PARAMS",
			"provide source_path (absolute filesystem path) or base64_data (base64-encoded file content)")
	if if_exists not in ["return", "fail", "replace"]:
		return MCPError.make("INVALID_PARAMS",
			"if_exists must be one of 'return', 'fail', 'replace' (got '%s')" % if_exists)
	if wait_for_scan_ms < 0 or wait_for_scan_ms > 30000:
		return MCPError.make("INVALID_PARAMS",
			"wait_for_scan_ms must be in [0, 30000] (got %d); 0 disables wait" % wait_for_scan_ms)

	# Source-path mode guards
	if has_source:
		if source_path.begins_with("res://") or source_path.begins_with("user://"):
			return MCPError.make("INVALID_PATH",
				"source_path must be an absolute filesystem path, not a Godot scheme (got %s)" % source_path)
		if not FileAccess.file_exists(source_path):
			return MCPError.make("NOT_FOUND",
				"source file not found: %s" % source_path)
		var source_file := FileAccess.open(source_path, FileAccess.READ)
		if source_file == null:
			return MCPError.make("READ_FAILED",
				"cannot read source file %s (err %d)" % [
					source_path, FileAccess.get_open_error()])
		var source_size := source_file.get_length()
		source_file.close()
		if source_size > IMPORT_MAX_FILE_BYTES:
			return MCPError.make("INVALID_PARAMS",
				"source file %d bytes exceeds 50 MB limit" % source_size)

	var decoded_bytes := PackedByteArray()
	if has_base64:
		decoded_bytes = Marshalls.base64_to_raw(base64_data)
		if decoded_bytes.is_empty() and base64_data.length() > 0:
			return MCPError.make("INVALID_PARAMS",
				"base64_data is not valid base64")
		if decoded_bytes.size() > IMPORT_MAX_BASE64_BYTES:
			return MCPError.make("INVALID_PARAMS",
				"decoded base64 data %d bytes exceeds 5 MB limit" % decoded_bytes.size())

	var file_existed := FileAccess.file_exists(dest_path)
	if file_existed:
		match if_exists:
			"return":
				return {"success": true, "status": "returned",
					"path": dest_path, "source": null}
			"fail":
				return MCPError.make("ALREADY_EXISTS",
					"file already exists at %s; use if_exists:'replace' to overwrite or if_exists:'return' for idempotent no-op" % dest_path)
			"replace":
				pass

	var parent_dir := dest_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(parent_dir):
		var mkdir_error := DirAccess.make_dir_recursive_absolute(parent_dir)
		if mkdir_error != OK:
			return MCPError.make("WRITE_FAILED",
				"cannot create parent directory for %s (err %d)" % [
					dest_path, mkdir_error])

	var bytes_to_write: PackedByteArray
	var source_label: String
	if has_source:
		bytes_to_write = FileAccess.get_file_as_bytes(source_path)
		if FileAccess.get_open_error() != OK:
			return MCPError.make("READ_FAILED",
				"cannot read source file %s (err %d)" % [
					source_path, FileAccess.get_open_error()])
		source_label = "filesystem"
	else:
		bytes_to_write = decoded_bytes
		source_label = "base64"

	var file_handle := FileAccess.open(dest_path, FileAccess.WRITE)
	if file_handle == null:
		return MCPError.make("WRITE_FAILED",
			"cannot open %s for writing (err %d)" % [
				dest_path, FileAccess.get_open_error()])
	file_handle.store_buffer(bytes_to_write)
	file_handle.close()

	var filesystem := EditorInterface.get_resource_filesystem()
	filesystem.scan()
	var warnings: Array[String] = []
	if wait_for_scan_ms > 0:
		var elapsed := 0
		while filesystem.is_scanning() and elapsed < wait_for_scan_ms:
			OS.delay_msec(100)
			elapsed += 100
		if filesystem.is_scanning():
			warnings.append(
				"EditorFileSystem still scanning after %dms — import may not be complete; call editor.wait_for_idle to finish" % wait_for_scan_ms)

	var file_class: Variant = null
	var filesystem_type := filesystem.get_file_type(dest_path)
	if filesystem_type != "":
		file_class = filesystem_type

	var status := "replaced" if file_existed else "created"

	return {
		"success": true,
		"status": status,
		"path": dest_path,
		"source": source_label,
		"size_bytes": bytes_to_write.size(),
		"class": file_class,
		"warnings": warnings,
	}
