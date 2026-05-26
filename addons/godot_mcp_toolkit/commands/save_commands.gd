@tool
extends RefCounted
## save.* command handlers — whitelisted user:// file operations.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const FileGuard = _Hub.FileGuard
const Untrusted = _Hub.Untrusted
const Scrubber = _Hub.Scrubber


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("save.read", func(parameters: Dictionary) -> Dictionary:
		return _cmd_save_read(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
	registry.add("save.write", func(parameters: Dictionary) -> Dictionary:
		return _cmd_save_write(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("save.delete", func(parameters: Dictionary) -> Dictionary:
		return _cmd_save_delete(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("save.list", func(parameters: Dictionary) -> Dictionary:
		return _cmd_save_list(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())


# -- Commands -----------------------------------------------------------------


static func _cmd_save_write(parameters: Dictionary) -> Dictionary:
	var path := str(parameters.get("path", ""))
	var content := str(parameters.get("content", ""))
	if path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing path")
	var guard := FileGuard.resolve_safe_user(path, "write")
	if not guard["ok"]:
		return MCPToolkitError.fail(str(guard["error_code"]), str(guard["error_message"]))
	var abs_path: String = guard["absolute_path"]
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		return MCPToolkitError.fail("SAVE_WRITE_FAILED",
			"FileAccess.open for write failed (error=%d, path=%s)" % [FileAccess.get_open_error(), path])
	f.store_string(content)
	f.close()
	return {"success": true, "path": path, "bytes_written": content.length()}


static func _cmd_save_read(parameters: Dictionary) -> Dictionary:
	var path := str(parameters.get("path", ""))
	if path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing path")
	var max_bytes := int(parameters.get("max_bytes", 65536))
	if max_bytes <= 0 or max_bytes > 262144:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"max_bytes must be 1..262144 (got %d)" % max_bytes)
	var guard := FileGuard.resolve_safe_user(path, "read")
	if not guard["ok"]:
		return MCPToolkitError.fail(str(guard["error_code"]), str(guard["error_message"]))
	var abs_path: String = guard["absolute_path"]
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return MCPToolkitError.fail("SAVE_READ_FAILED",
			"FileAccess.open for read failed (error=%d, path=%s)" % [FileAccess.get_open_error(), path])
	var total_bytes := int(f.get_length())
	var bytes_to_read := mini(total_bytes, max_bytes)
	var truncated := total_bytes > max_bytes
	var buffer := f.get_buffer(bytes_to_read)
	f.close()
	# Binary-safe: try UTF-8 decode; fall back to base64.
	var text := buffer.get_string_from_utf8()
	if text.is_empty() and buffer.size() > 0:
		return {
			"success": true,
			"path": path,
			"content_base64": Marshalls.raw_to_base64(buffer),
			"encoding": "base64",
			"truncated": truncated,
			"total_bytes": total_bytes,
			"bytes_returned": buffer.size(),
		}
	var scrubbed := Scrubber.scrub(text, "save.read")
	var wrapped := Untrusted.wrap("user-file", path, scrubbed["text"])
	return {
		"success": true,
		"path": path,
		"content": wrapped,
		"truncated": truncated,
		"total_bytes": total_bytes,
		"bytes_returned": buffer.size(),
	}


static func _cmd_save_delete(parameters: Dictionary) -> Dictionary:
	var path := str(parameters.get("path", ""))
	if path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing path")
	var guard := FileGuard.resolve_safe_user(path, "delete")
	if not guard["ok"]:
		return MCPToolkitError.fail(str(guard["error_code"]), str(guard["error_message"]))
	var abs_path: String = guard["absolute_path"]
	if not FileAccess.file_exists(abs_path):
		return MCPToolkitError.fail("NOT_FOUND", "no file at %s" % path)
	var err := DirAccess.remove_absolute(abs_path)
	if err != OK:
		return MCPToolkitError.fail("SAVE_DELETE_FAILED",
			"DirAccess.remove_absolute returned %d (path=%s)" % [err, path])
	return {"success": true, "path": path}


static func _cmd_save_list(parameters: Dictionary) -> Dictionary:
	var path := str(parameters.get("path", ""))
	if path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing path")
	if not path.ends_with("/"):
		return MCPToolkitError.fail("INVALID_PATH",
			"save.list requires a directory path ending with / (got %s); use save.read for a single file" % path)
	var guard := FileGuard.resolve_safe_user(path, "read")
	if not guard["ok"]:
		return MCPToolkitError.fail(str(guard["error_code"]), str(guard["error_message"]))
	var abs_path: String = guard["absolute_path"]
	if not DirAccess.dir_exists_absolute(abs_path):
		return MCPToolkitError.fail("NOT_FOUND", "no directory at %s" % path)
	var d := DirAccess.open(abs_path)
	if d == null:
		return MCPToolkitError.fail("SAVE_READ_FAILED",
			"DirAccess.open failed (path=%s)" % path)
	var files := Array(d.get_files())
	var dirs := Array(d.get_directories())
	return {
		"success": true,
		"path": path,
		"files": files,
		"directories": dirs,
		"file_count": files.size(),
		"directory_count": dirs.size(),
	}
