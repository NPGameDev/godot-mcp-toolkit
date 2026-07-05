@tool
extends RefCounted
## editor.* filesystem rescan: drive and await the editor's resource-filesystem
## rescan — a full EditorFileSystem.scan() or a targeted update_file() per path —
## then await is_scanning() via a 0.1 s poll loop. After a full scan, reload only
## the open scripts the scan actually changed and that aren't the toolkit's own
## (the reload-filter). Serves both the refresh tool and the wait_for_idle tool
## (wait_for_idle is the idle-wait alone; refresh rescans then waits then reloads).
##
## Stateless — each handler takes (parameters) and returns the response Dictionary.
## The error-buffer flush (clear_level) is reached via the Modules alias; the rescan
## itself goes straight to EditorInterface.get_resource_filesystem() /
## get_script_editor(). An extracted submodule of the editor-command group,
## reached via a `preload` alias.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")


# -- Commands -----------------------------------------------------------------


static func cmd_refresh(parameters: Dictionary) -> Dictionary:
	# Flush stale errors before reload — fresh parse errors will be captured
	# with new IDs so editor_get_console returns only current-state errors.
	var errors_cleared := Modules.LogBuffer.clear_level("error")

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
		return MCPToolkitSuccess.ok({"mode": "targeted", "file_count": paths.size(),
			"reloaded": reloaded, "errors_cleared": errors_cleared})

	# Full mode: scan(), then reload ONLY the scripts the scan actually changed
	# (captured via the resources_reload signal — present in all of 4.2-4.6), and
	# only if they're open. NEVER reload an unchanged script: reload(true) cancels
	# any suspended coroutine in it, which would break the user's @tool plugins and
	# (for the toolkit's own scripts) leak the mutation dispatch lock.
	# The toolkit's own scripts are skipped even when changed.
	var changed := {}
	var collector := func(resources: PackedStringArray) -> void:
		for r in resources:
			changed[str(r)] = true
	if filesystem != null:
		filesystem.resources_reload.connect(collector)
		filesystem.scan()
		var scan_start := Time.get_ticks_msec()
		var scan_deadline := scan_start + 5000
		while filesystem.is_scanning() and Time.get_ticks_msec() < scan_deadline:
			await Engine.get_main_loop().create_timer(0.1).timeout
		scan_waited_ms = Time.get_ticks_msec() - scan_start
		if filesystem.resources_reload.is_connected(collector):
			filesystem.resources_reload.disconnect(collector)
	var reloaded := 0
	var script_editor := EditorInterface.get_script_editor()
	if script_editor != null:
		for open_script in script_editor.get_open_scripts():
			if not (open_script is Script):
				continue
			# Reload ONLY scan-changed, non-toolkit open scripts (see
			# should_reload_open_script — never cancel an unchanged/own coroutine).
			if not should_reload_open_script(str(open_script.resource_path), changed):
				continue
			open_script.reload(true)
			reloaded += 1
	return MCPToolkitSuccess.ok({"mode": "full", "reloaded": reloaded,
		"scan_waited_ms": scan_waited_ms, "errors_cleared": errors_cleared})


static func cmd_wait_for_idle(parameters: Dictionary) -> Dictionary:
	var timeout_ms: int = int(parameters.get("timeout_ms", 10000))
	if timeout_ms < 0 or timeout_ms > 30000:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"timeout_ms must be in [0, 30000] (got %d)" % timeout_ms)
	var filesystem := EditorInterface.get_resource_filesystem()
	if not filesystem.is_scanning():
		return MCPToolkitSuccess.ok({"was_scanning": false, "waited_ms": 0})
	var start := Time.get_ticks_msec()
	while filesystem.is_scanning() and Time.get_ticks_msec() - start < timeout_ms:
		await Engine.get_main_loop().create_timer(0.1).timeout
	var elapsed := Time.get_ticks_msec() - start
	if filesystem.is_scanning():
		return MCPToolkitError.fail("TIMEOUT",
			"EditorFileSystem still scanning after %dms; consider increasing timeout_ms or checking editor.get_console for import errors" % elapsed)
	return MCPToolkitSuccess.ok({"was_scanning": true, "waited_ms": elapsed})


# -- Helpers ------------------------------------------------------------------


## Whether an open script should be reloaded after a full editor.refresh scan:
## only scripts the scan actually changed, and NEVER the toolkit's own (reloading
## an unchanged or toolkit-own script would cancel a suspended coroutine —
## a wedged-dispatch-lock / editor-crash class). Pure logic so it can be unit-tested.
static func should_reload_open_script(resource_path: String, changed: Dictionary) -> bool:
	return changed.has(resource_path) and not resource_path.begins_with("res://addons/godot_mcp_toolkit/")
