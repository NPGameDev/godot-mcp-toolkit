@tool
extends RefCounted
## editor.* command handlers — errors, save, screenshot, reload, console, wait-for-idle.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPFileGuard = _Hub.MCPFileGuard
const MCPUntrusted = _Hub.MCPUntrusted
const MCPScrubber = _Hub.MCPScrubber
const MCPHelpers = _Hub.MCPHelpers
const MIN_SCREENSHOT_SIZE := 64
const MAX_SCREENSHOT_SIZE := 4096


static func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:
	registry.add("editor.get_errors", func(parameters: Dictionary) -> Dictionary:
		return _cmd_editor_get_errors(server, parameters))
	registry.add("editor.save_scene", func(parameters: Dictionary) -> Dictionary:
		return _cmd_editor_save_scene(parameters))
	registry.add("editor.screenshot", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_editor_screenshot(parameters))
	registry.add("editor.reload_scripts", func(parameters: Dictionary) -> Dictionary:
		return _cmd_editor_reload_scripts(parameters))
	registry.add("editor.get_console", func(parameters: Dictionary) -> Dictionary:
		return _cmd_editor_get_console(server, parameters))
	registry.add("editor.wait_for_idle", func(parameters: Dictionary) -> Dictionary:
		return _cmd_editor_wait_for_idle(parameters))


# -- Commands -----------------------------------------------------------------


static func _cmd_editor_get_errors(server: Node, parameters: Dictionary) -> Dictionary:
	var limit: int = int(parameters.get("limit", 50))
	var source: String = str(parameters.get("source", "buffer"))
	if not (source in ["buffer", "file"]):
		return MCPError.make("INVALID_PARAMS",
			"source must be 'buffer' or 'file' (got %s)" % source)

	if source == "file":
		var result := _read_console_log(server, limit, ["error"], -1)
		if result.get("success", false) == false:
			return result
		var entries = result.get("entries", [])
		return {
			"success": true,
			"errors": MCPUntrusted.wrap(
				"editor_errors", "godot", JSON.stringify(entries)),
			"count": result.get("count", 0),
		}

	var buf_result: Dictionary = _Hub.LogBuffer.get_entries(limit, ["error"], -1)
	var entries: Array = buf_result["entries"]
	for entry in entries:
		var scrubbed := MCPScrubber.scrub(str(entry["message"]), "console")
		entry["message"] = scrubbed["text"]
	var response := {
		"success": true,
		"errors": MCPUntrusted.wrap(
			"editor_errors", "buffer", JSON.stringify(entries)),
		"count": buf_result["count"],
	}
	if buf_result["count"] > 0:
		response["hint"] = "Use since_id parameter with the highest id from this response to get only new errors on next call."
	return response


static func _cmd_editor_save_scene(parameters: Dictionary) -> Dictionary:
	var root := MCPHelpers.get_edited_root()
	if root == null:
		return MCPError.make("NO_SCENE", "no edited scene")
	var save_path := str(parameters.get("file_path", ""))
	if save_path.is_empty():
		var save_error := EditorInterface.save_scene()
		if save_error != OK:
			return MCPError.make("SAVE_FAILED",
				"EditorInterface.save_scene returned %d" % save_error)
	else:
		var guard := MCPFileGuard.resolve_safe(save_path)
		if guard["error"] != null:
			return MCPError.make("PATH_DENIED", str(guard["reason"]))
		EditorInterface.save_scene_as(save_path)
		if not FileAccess.file_exists(save_path):
			return MCPError.make("SAVE_FAILED",
				"save_scene_as did not produce %s" % save_path)
	return {"success": true, "path": root.scene_file_path}


static func _cmd_editor_screenshot(parameters: Dictionary) -> Dictionary:
	if _Hub.is_headless():
		return MCPError.make("HEADLESS_UNSUPPORTED",
			"editor.screenshot requires a display server (no viewport in headless mode)")

	var node_path := str(parameters.get("node_path", ""))

	# Node-focused screenshot: select + capture a specific node, then restore.
	if not node_path.is_empty():
		var size_dict: Dictionary = parameters.get("size", {}) if typeof(parameters.get("size", {})) == TYPE_DICTIONARY else {}
		var width := int(size_dict.get("width", 1280))
		var height := int(size_dict.get("height", 720))
		if width < MIN_SCREENSHOT_SIZE or width > MAX_SCREENSHOT_SIZE \
				or height < MIN_SCREENSHOT_SIZE or height > MAX_SCREENSHOT_SIZE:
			return MCPError.make("INVALID_PARAMS",
				"size.width and size.height must be in [64, 4096] (got %dx%d)" % [width, height])
		var root := MCPHelpers.get_edited_root()
		if root == null:
			return MCPError.make("NO_SCENE", "no edited scene")
		var node: Variant = null
		if node_path == ".":
			node = root
		else:
			node = root.get_node_or_null(node_path)
		if node == null:
			return MCPError.make("NOT_FOUND", "no node at %s" % node_path, MCPError.HINT_NODE_PATH)

		var selection := EditorInterface.get_selection()
		var prior_selection: Array = []
		if selection != null:
			for selected_node in selection.get_selected_nodes():
				prior_selection.append(selected_node)
			selection.clear()
			selection.add_node(node)
		EditorInterface.edit_node(node)
		await RenderingServer.frame_post_draw

		var viewport: SubViewport = null
		if node is Node3D:
			viewport = EditorInterface.get_editor_viewport_3d(0)
		if viewport == null:
			viewport = EditorInterface.get_editor_viewport_2d()
		if viewport == null:
			return MCPError.make("INTERNAL", "no editor viewport available")
		var image := viewport.get_texture().get_image()
		if image == null:
			return MCPError.make("INTERNAL",
				"viewport texture unavailable (nothing rendered yet?)")
		if image.get_width() != width or image.get_height() != height:
			image.resize(width, height, Image.INTERPOLATE_LANCZOS)

		if selection != null:
			selection.clear()
			for selected_node in prior_selection:
				if is_instance_valid(selected_node):
					selection.add_node(selected_node)
		var png_bytes := image.save_png_to_buffer()
		if png_bytes.is_empty():
			return MCPError.make("EMPTY_CONTENT",
				"node '%s' produced no visible image. Node may lack visual content (no texture, no mesh). Use editor_screenshot without node_path for a full viewport capture instead." % node_path)
		return {
			"image_base64": Marshalls.raw_to_base64(png_bytes),
			"mime_type": "image/png",
			"width": image.get_width(),
			"height": image.get_height(),
			"bytes": png_bytes.size(),
			"path": node_path,
		}

	# Standard viewport screenshot.
	var save_path := str(parameters.get("save_path", ""))
	var viewport: SubViewport = EditorInterface.get_editor_viewport_2d()
	if viewport == null:
		viewport = EditorInterface.get_editor_viewport_3d(0)
	if viewport == null:
		return MCPError.make("INTERNAL", "no editor viewport available")
	var image := viewport.get_texture().get_image()
	if image == null:
		return MCPError.make("INTERNAL",
			"viewport texture unavailable (nothing rendered yet?)")

	var png_bytes := image.save_png_to_buffer()
	if png_bytes.is_empty():
		return MCPError.make("INTERNAL", "save_png_to_buffer returned empty")

	var persisted_path := ""
	if not save_path.is_empty():
		var guard := MCPFileGuard.resolve_safe(
			save_path, ["res://", "user://screenshots/"])
		if guard["error"] != null:
			return MCPError.make("PATH_DENIED", str(guard["reason"]))
		if not save_path.ends_with(".png"):
			return MCPError.make("INVALID_PARAMS",
				"save_path must end with .png: %s" % save_path)
		var directory_path := save_path.get_base_dir()
		if not directory_path.is_empty():
			var mkdir_error := DirAccess.make_dir_recursive_absolute(directory_path)
			if mkdir_error != OK and mkdir_error != ERR_ALREADY_EXISTS:
				return MCPError.make("INTERNAL",
					"could not create %s (err %d)" % [directory_path, mkdir_error])
		var save_error := image.save_png(save_path)
		if save_error != OK:
			return MCPError.make("INTERNAL",
				"save_png failed (err %d) for %s" % [save_error, save_path])
		persisted_path = save_path

	var response := {
		"image_base64": Marshalls.raw_to_base64(png_bytes),
		"mime_type": "image/png",
		"width": image.get_width(),
		"height": image.get_height(),
		"bytes": png_bytes.size(),
	}
	if image.get_width() < 16 or image.get_height() < 16:
		response["warning"] = "Screenshot captured only %dx%d — editor may be minimized or running headless. Use script_check and editor_get_console for non-visual verification." % [image.get_width(), image.get_height()]
	if not persisted_path.is_empty():
		response["path"] = persisted_path
	return response


static func _cmd_editor_reload_scripts(parameters: Dictionary) -> Dictionary:
	# Flush stale errors before reload — fresh parse errors will be captured
	# with new IDs so editor_get_errors returns only current-state errors.
	var errors_cleared := _Hub.LogBuffer.clear_level("error")

	var file_paths_raw = parameters.get("file_paths", null)
	var targeted := file_paths_raw != null and typeof(file_paths_raw) == TYPE_ARRAY \
		and (file_paths_raw as Array).size() > 0

	var filesystem := EditorInterface.get_resource_filesystem()
	var scan_waited_ms := 0

	if targeted:
		# Targeted mode: update_file() per path — O(1) per file.
		var paths: Array = file_paths_raw as Array
		if filesystem != null:
			for path in paths:
				filesystem.update_file(str(path))
		var reloaded := 0
		var script_editor := EditorInterface.get_script_editor()
		if script_editor != null:
			var target_set := {}
			for path in paths:
				target_set[str(path)] = true
			for open_script in script_editor.get_open_scripts():
				if open_script is Script:
					if target_set.has(open_script.resource_path):
						open_script.reload(true)
						reloaded += 1
		return {"success": true, "mode": "targeted", "file_count": paths.size(),
			"reloaded": reloaded, "errors_cleared": errors_cleared}

	# Full mode: scan() + reload all open scripts.
	if filesystem != null:
		filesystem.scan()
		var scan_deadline := Time.get_ticks_msec() + 5000
		while filesystem.is_scanning() and Time.get_ticks_msec() < scan_deadline:
			OS.delay_msec(100)
			scan_waited_ms += 100
	var reloaded := 0
	var script_editor := EditorInterface.get_script_editor()
	if script_editor != null:
		for open_script in script_editor.get_open_scripts():
			if open_script is Script:
				open_script.reload(true)
				reloaded += 1
	return {"success": true, "mode": "full", "reloaded": reloaded,
		"scan_waited_ms": scan_waited_ms, "errors_cleared": errors_cleared}



static func _cmd_editor_get_console(server: Node, parameters: Dictionary) -> Dictionary:
	var limit: int = int(parameters.get("limit", 200))
	var level_filter: Array = parameters.get("level_filter", [])
	if typeof(level_filter) != TYPE_ARRAY:
		level_filter = []
	var since_id: int = int(parameters.get("since_id", -1))
	var source: String = str(parameters.get("source", "buffer"))

	if limit < 1 or limit > 1000:
		return MCPError.make("INVALID_PARAMS",
			"limit must be in [1, 1000] (got %d)" % limit)
	if not (source in ["buffer", "file"]):
		return MCPError.make("INVALID_PARAMS",
			"source must be 'buffer' or 'file' (got %s)" % source)
	var valid_levels := ["info", "warning", "error"]
	for level_filter_entry in level_filter:
		if not str(level_filter_entry) in valid_levels:
			return MCPError.make("INVALID_PARAMS",
				"level_filter entries must be one of 'info' | 'warning' | 'error' (got %s)" % str(level_filter_entry))

	if source == "file":
		return _read_console_log(server, limit, level_filter, since_id)
	return _read_buffer_log(limit, level_filter, since_id)


static func _cmd_editor_wait_for_idle(parameters: Dictionary) -> Dictionary:
	var timeout_ms: int = int(parameters.get("timeout_ms", 10000))
	if timeout_ms < 0 or timeout_ms > 30000:
		return MCPError.make("INVALID_PARAMS",
			"timeout_ms must be in [0, 30000] (got %d)" % timeout_ms)
	var filesystem := EditorInterface.get_resource_filesystem()
	if not filesystem.is_scanning():
		return {"success": true, "was_scanning": false, "waited_ms": 0}
	var elapsed := 0
	while filesystem.is_scanning() and elapsed < timeout_ms:
		OS.delay_msec(100)
		elapsed += 100
	if filesystem.is_scanning():
		return MCPError.make("TIMEOUT",
			"EditorFileSystem still scanning after %dms; consider increasing timeout_ms or checking editor.get_console for import errors" % timeout_ms)
	return {"success": true, "was_scanning": true, "waited_ms": elapsed}


# -- Helpers ------------------------------------------------------------------


static func _godot_error_name(code: int) -> String:
	match code:
		0: return "OK"
		7: return "ERR_FILE_NOT_FOUND"
		12: return "ERR_CANT_OPEN"
		13: return "ERR_CANT_WRITE"
		31: return "ERR_FILE_CANT_WRITE"
		32: return "ERR_FILE_CANT_READ"
		_: return "Error(%d)" % code


# -- Buffer log reader --------------------------------------------------------


static func _read_buffer_log(limit: int, level_filter: Array, since_id: int) -> Dictionary:
	var buf_result: Dictionary = _Hub.LogBuffer.get_entries(limit, level_filter, since_id)
	var entries: Array = buf_result["entries"]
	for entry in entries:
		var scrubbed := MCPScrubber.scrub(str(entry["message"]), "console")
		entry["message"] = scrubbed["text"]
	var response := {
		"success": true,
		"entries": MCPUntrusted.wrap(
			"console", "buffer", JSON.stringify(entries)),
		"count": buf_result["count"],
		"next_id": buf_result["next_id"],
		"truncated": buf_result["truncated"],
		"source": "buffer",
	}
	# On 4.2-4.4, buffer uses file tailing — warn if empty and file logging is off
	# or the log file couldn't be read (locked by OS on Windows).
	if entries.is_empty() and not _Hub.LogBuffer.uses_logger_api():
		if not MCPHelpers.is_file_logging_enabled():
			response["warning"] = "On Godot 4.2-4.4 the log buffer captures output by tailing the log file. Enable debug/file_logging/enable_file_logging in ProjectSettings and restart the editor for output capture to work."
		elif _Hub.LogBuffer._tail_open_failures > 0:
			response["warning"] = "Log file could not be opened for reading (%d failed attempts) — the OS may be locking it. Use source=\"file\" as a fallback." % _Hub.LogBuffer._tail_open_failures
	return response


# -- Console log reader -------------------------------------------------------


static func _detect_log_level(line: String) -> String:
	return MCPHelpers.detect_log_level(line)


static func _read_console_log(
	server: Node, limit: int, level_filter: Array, since_id: int,
) -> Dictionary:
	# user://logs/ read is a narrow read-only exception to the res://-only rule.
	# Path is internally constructed (not user-supplied), so no FileGuard gate.
	var logs_dir := "user://logs"
	var file_logging_enabled: bool = MCPHelpers.is_file_logging_enabled()
	if not DirAccess.dir_exists_absolute(logs_dir):
		if not file_logging_enabled:
			var _hint := "file logging is disabled — enable it in ProjectSettings → Debug → File Logging → Enable File Logging, then restart the editor"
			if _Hub.LogBuffer.uses_logger_api():
				_hint += "; alternatively use source=\"buffer\" (default) which captures all output in real-time"
			else:
				_hint += ". On Godot 4.2-4.4 source=\"buffer\" also depends on file logging, so both sources require this setting"
			return MCPError.make("LOG_UNAVAILABLE", _hint)
		return MCPError.make("LOG_UNAVAILABLE",
			"no log directory at user://logs/ — verify file logging is enabled in ProjectSettings → Debug → File Logging → Enable File Logging")

	var all_files := DirAccess.get_files_at(logs_dir)
	var log_files: Array[String] = []
	for file_name in all_files:
		if String(file_name).ends_with(".log"):
			log_files.append(String(file_name))
	if log_files.is_empty():
		if not file_logging_enabled:
			var _hint := "file logging is disabled — enable it in ProjectSettings → Debug → File Logging → Enable File Logging, then restart the editor"
			if _Hub.LogBuffer.uses_logger_api():
				_hint += "; alternatively use source=\"buffer\" (default) which captures all output in real-time"
			else:
				_hint += ". On Godot 4.2-4.4 source=\"buffer\" also depends on file logging, so both sources require this setting"
			return MCPError.make("LOG_UNAVAILABLE", _hint)
		return MCPError.make("LOG_UNAVAILABLE",
			"no .log files under user://logs/ — verify file logging is enabled in ProjectSettings → Debug → File Logging → Enable File Logging")

	var plugin_boot_time: int = server.get("_plugin_boot_time") if server.get("_plugin_boot_time") != null else 0

	var chosen_file := ""
	var chosen_mtime: int = 0
	var warnings: Array[String] = []
	if not file_logging_enabled:
		if _Hub.LogBuffer.uses_logger_api():
			warnings.append("file logging is disabled — data may be stale from a previous session; use source=\"buffer\" for real-time output")
		else:
			warnings.append("file logging is disabled — data may be stale from a previous session. On Godot 4.2-4.4 source=\"buffer\" also depends on file logging, so both sources may be stale")

	var godot_log := logs_dir + "/godot.log"
	var godot_log_mtime: int = 0
	if FileAccess.file_exists(godot_log):
		godot_log_mtime = FileAccess.get_modified_time(godot_log)
	if godot_log_mtime > 0 and godot_log_mtime >= plugin_boot_time:
		chosen_file = godot_log
		chosen_mtime = godot_log_mtime
	else:
		var best_file := ""
		var best_mtime: int = 0
		for log_file_name in log_files:
			var full_path := logs_dir + "/" + log_file_name
			var mtime := FileAccess.get_modified_time(full_path)
			if mtime >= plugin_boot_time and mtime > best_mtime:
				best_file = full_path
				best_mtime = mtime
		if best_file != "":
			chosen_file = best_file
			chosen_mtime = best_mtime
		else:
			for log_file_name in log_files:
				var full_path := logs_dir + "/" + log_file_name
				var mtime := FileAccess.get_modified_time(full_path)
				if mtime > best_mtime:
					best_file = full_path
					best_mtime = mtime
			if best_file != "":
				chosen_file = best_file
				chosen_mtime = best_mtime
				warnings.append("fallback to stale log — no post-boot log found")

	if chosen_file == "":
		return MCPError.make("LOG_UNAVAILABLE",
			"no readable log file under user://logs/ — verify file logging is enabled in ProjectSettings → Debug → File Logging → Enable File Logging; playtest may have rotated the editor's log mid-session")

	var file_handle := FileAccess.open(chosen_file, FileAccess.READ)
	if file_handle == null:
		var open_err := FileAccess.get_open_error()
		if FileAccess.file_exists(chosen_file):
			var _busy_hint := "log file exists but cannot be read right now (%s) — transient lock during file flush, retry in 1-2 seconds" % _godot_error_name(open_err)
			if _Hub.LogBuffer.uses_logger_api():
				_busy_hint += "; consider using source=\"buffer\" instead"
			return MCPError.make("LOG_BUSY", _busy_hint)
		return MCPError.make("LOG_UNAVAILABLE",
			"cannot open %s (%s)" % [chosen_file, _godot_error_name(open_err)])
	var content := file_handle.get_as_text()
	file_handle.close()

	var lines := content.split("\n")
	var entries: Array = []
	var char_offset: int = 0

	for line_index in range(lines.size()):
		var line: String = MCPHelpers.strip_ansi(lines[line_index])
		if line.strip_edges().is_empty():
			char_offset += line.length() + 1
			continue
		var level := _detect_log_level(line)
		if level == "info" and entries.size() > 0 and line.length() > 0:
			var first_char := line[0]
			if first_char == " " or first_char == "\t" or line.begins_with("   at:"):
				var previous: Dictionary = entries[-1]
				if previous["level"] == "error" or previous["level"] == "warning":
					previous["message"] += "\n" + line
					char_offset += line.length() + 1
					continue
		entries.append({
			"id": char_offset,
			"level": level,
			"message": line,
			"timestamp_unix": null,
		})
		char_offset += line.length() + 1

	if level_filter.size() > 0:
		var level_set: Array[String] = []
		for filter_entry in level_filter:
			level_set.append(str(filter_entry))
		var filtered: Array = []
		for entry in entries:
			if entry["level"] in level_set:
				filtered.append(entry)
		entries = filtered

	if since_id >= 0:
		var filtered: Array = []
		for entry in entries:
			if entry["id"] > since_id:
				filtered.append(entry)
		entries = filtered

	var truncated := entries.size() > limit
	if truncated:
		entries = entries.slice(entries.size() - limit)

	var next_id: int = -1
	if entries.size() > 0:
		next_id = entries[-1]["id"]

	for entry in entries:
		var scrubbed := MCPScrubber.scrub(str(entry["message"]), "console")
		entry["message"] = scrubbed["text"]

	return {
		"success": true,
		"entries": MCPUntrusted.wrap(
			"console", str(chosen_file), JSON.stringify(entries)),
		"count": entries.size(),
		"next_id": next_id,
		"truncated": truncated,
		"log_file": chosen_file,
		"log_mtime": chosen_mtime,
		"warnings": warnings,
	}
