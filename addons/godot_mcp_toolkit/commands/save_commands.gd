@tool
extends RefCounted
## save.* command handlers — user:// file operations.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const FileGuard = Modules.FileGuard
const Untrusted = Modules.Untrusted
const Scrubber = Modules.Scrubber


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
	var guard := FileGuard.resolve_safe_user(path)
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
	return MCPToolkitSuccess.ok({"path": path, "bytes_written": content.length()})


static func _cmd_save_read(parameters: Dictionary) -> Dictionary:
	var path := str(parameters.get("path", ""))
	if path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing path")
	# Cap is configurable (mcp_toolkit/limits/save_read_cap_kb, default 256, min
	# 64) — mirrors script_read_cap_kb. Default 256 KB ⇒ 262144 ⇒ the former
	# hardcoded ceiling, so the default behaviour is unchanged.
	var cap_kb: int = ProjectSettings.get_setting("mcp_toolkit/limits/save_read_cap_kb", 256)
	var cap_bytes := maxi(64, cap_kb) * 1024
	var max_bytes := int(parameters.get("max_bytes", 65536))
	if max_bytes <= 0 or max_bytes > cap_bytes:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"max_bytes must be 1..%d (got %d); raise mcp_toolkit/limits/save_read_cap_kb to read a larger window"
			% [cap_bytes, max_bytes])
	# Byte offset for pagination (default 0) — parity with script.read's line
	# range. Lets a large file be read in successive ≤max_bytes windows under the
	# WebSocket frame ceiling, which is the only way the engine ships big files.
	var offset := int(parameters.get("offset", 0))
	if offset < 0:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"offset must be >= 0 (got %d)" % offset)
	var guard := FileGuard.resolve_safe_user(path)
	if not guard["ok"]:
		return MCPToolkitError.fail(str(guard["error_code"]), str(guard["error_message"]))
	var abs_path: String = guard["absolute_path"]
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return MCPToolkitError.fail("SAVE_READ_FAILED",
			"FileAccess.open for read failed (error=%d, path=%s)" % [FileAccess.get_open_error(), path])
	var total_bytes := int(f.get_length())
	# Bytes remaining after the offset. An offset at or past EOF yields 0 bytes
	# (not an error) so a paging caller can detect completion by next_offset.
	var remaining := maxi(0, total_bytes - offset)
	var bytes_to_read := mini(remaining, max_bytes)
	# Frame-size guard: the engine drops any WebSocket frame larger than the
	# per-peer outbound buffer wholesale (send_text's result is unchecked → silent
	# drop). Reject BEFORE reading so an oversized window never reaches the
	# transport. Sizing basis is the base64 worst case (1.33×), since the binary
	# fallback path inflates the payload by ~33%. At defaults this never fires
	# (256 KB × 1.33 ≈ 340 KB < 1 MB); it guards the footgun of raising
	# save_read_cap_kb above ws_buffer_kb.
	var ws_buffer_kb: int = ProjectSettings.get_setting("mcp_toolkit/limits/ws_buffer_kb", 1024)
	var projected_bytes := int(ceil(bytes_to_read * 1.33))
	if projected_bytes > ws_buffer_kb * 1024:
		f.close()
		var size_err := MCPToolkitError.fail("FILE_TOO_LARGE",
			"projected response (~%d KB base64) exceeds the %d KB WebSocket buffer"
			% [projected_bytes / 1024, ws_buffer_kb])
		size_err["total_bytes"] = total_bytes
		size_err["hint"] = "narrow the window: use offset + a smaller max_bytes"
		return size_err
	if offset > 0:
		f.seek(offset)
	var buffer := f.get_buffer(bytes_to_read)
	f.close()
	var next_offset := offset + buffer.size()
	# has_more means there is more file beyond what this window returned.
	var has_more := next_offset < total_bytes
	# Uniform pagination contract: on a read with more remaining, hand the LLM a prose
	# loop instruction — re-call with offset = next_offset until has_more is false.
	# Present ONLY when has_more; the field is absent on a complete read.
	var page_hint := ""
	if has_more:
		page_hint = "more bytes remain — re-call save.read with offset = next_offset (%d) until has_more is false" % next_offset
	# Binary-safe: try UTF-8 decode; fall back to base64.
	var text := buffer.get_string_from_utf8()
	if text.is_empty() and buffer.size() > 0:
		return MCPToolkitSuccess.ok(Modules.Pagination.byte_page(
			{
				"path": path,
				"content_base64": Marshalls.raw_to_base64(buffer),
				"encoding": "base64",
				"offset": offset,
			},
			offset, buffer.size(), total_bytes, page_hint))
	var scrubbed := Scrubber.scrub(text, "save.read")
	var wrapped := Untrusted.wrap("user-file", path, scrubbed["text"])
	return MCPToolkitSuccess.ok(Modules.Pagination.byte_page(
		{
			"path": path,
			"content": wrapped,
			"offset": offset,
		},
		offset, buffer.size(), total_bytes, page_hint))


static func _cmd_save_delete(parameters: Dictionary) -> Dictionary:
	var path := str(parameters.get("path", ""))
	if path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing path")
	var guard := FileGuard.resolve_safe_user(path)
	if not guard["ok"]:
		return MCPToolkitError.fail(str(guard["error_code"]), str(guard["error_message"]))
	var abs_path: String = guard["absolute_path"]
	if not FileAccess.file_exists(abs_path):
		return MCPToolkitError.fail("NOT_FOUND", "no file at %s" % path)
	var err := DirAccess.remove_absolute(abs_path)
	if err != OK:
		return MCPToolkitError.fail("SAVE_DELETE_FAILED",
			"DirAccess.remove_absolute returned %d (path=%s)" % [err, path])
	return MCPToolkitSuccess.ok({"path": path})


static func _cmd_save_list(parameters: Dictionary) -> Dictionary:
	var path := str(parameters.get("path", ""))
	if path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing path")
	if not path.ends_with("/"):
		return MCPToolkitError.fail("INVALID_PATH",
			"save.list requires a directory path ending with / (got %s); use save.read for a single file" % path)
	var guard := FileGuard.resolve_safe_user(path)
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
	return MCPToolkitSuccess.ok({
		"path": path,
		"files": files,
		"directories": dirs,
		"file_count": files.size(),
		"directory_count": dirs.size(),
	})
