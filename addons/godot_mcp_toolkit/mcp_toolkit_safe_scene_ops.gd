@tool
class_name MCPToolkitSafeSceneOps
extends RefCounted
## Editor-safe scene operations. Command handlers (toolkit OR extension) must
## call MCPToolkitSafeSceneOps.save_scene() — never EditorInterface.save_scene()
## / save_scene_as() directly. See docs/extending.md and docs/advanced_configuration.md.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const FileGuard = _Hub.FileGuard

# Set ONLY around the synchronous save call (C1). The dispatch loop checks
# is_dispatching() at every frame-driven entry point and skips that tick while a
# save's Main::iteration() re-entry is in flight. Held for microseconds (a
# synchronous call), so it can never stick true and brick polling.
static var _in_dispatch := false

# queue_save() result tracking: save_id -> {done, success, result}. Bounded
# (oldest dropped) so a caller that never polls with clear can't leak memory.
const _MAX_TRACKED_SAVES := 100
static var _save_counter := 0
static var _save_results: Dictionary = {}


## True while a save's synchronous EditorInterface.save_scene[_as] call is in
## flight. Frame-driven dispatch initiators (_poll_connections,
## _check_lease_expiry) early-return when this is true so no command dispatches
## during the ProgressDialog's Main::iteration() re-entry (C1, all versions).
static func is_dispatching() -> bool:
	return _in_dispatch


## Wait until the EditorFileSystem scan finishes. Returns true if idle was
## reached, false on timeout. timeout_ms < 0 → use the configured default
## (mcp_toolkit/concurrency/scan_idle_timeout_ms, default 5000). 0 = fail-fast.
static func wait_for_scan_idle(timeout_ms := -1) -> bool:
	var efs := EditorInterface.get_resource_filesystem()
	if efs == null or not efs.is_scanning():
		return true
	if timeout_ms < 0:
		timeout_ms = ProjectSettings.get_setting(
			"mcp_toolkit/concurrency/scan_idle_timeout_ms", 5000)
	var start := Time.get_ticks_msec()
	while efs.is_scanning() and Time.get_ticks_msec() - start < timeout_ms:
		await Engine.get_main_loop().create_timer(0.1).timeout
	return not efs.is_scanning()


## Safe scene save. C2 guard (scan-idle, abort-on-timeout) + C1 guard
## (_in_dispatch around the synchronous save). path == "" saves the active
## scene; non-empty does save_scene_as.
static func save_scene(path := "") -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return MCPToolkitError.fail("NO_SCENE", "no edited scene")
	if not path.is_empty():
		var guard := FileGuard.resolve_safe(path)
		if guard["error"] != null:
			return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	# C2: don't save into an active scan.
	if not await wait_for_scan_idle():
		return MCPToolkitError.fail("TIMEOUT",
			"EditorFileSystem still scanning; a recent import/refresh may still "
			+ "be indexing — call editor_wait_for_idle or retry")
	# Escape the call_deferred/flush context before the ProgressDialog.
	await (Engine.get_main_loop() as SceneTree).process_frame
	# --- C1 synchronous danger window: NO awaits between set and clear ---
	_in_dispatch = true
	var save_error := OK
	if path.is_empty():
		save_error = EditorInterface.save_scene()
	else:
		EditorInterface.save_scene_as(path)
	_in_dispatch = false
	# --- end danger window ---
	if path.is_empty():
		if save_error != OK:
			return MCPToolkitError.fail("SAVE_FAILED",
				"EditorInterface.save_scene returned %d" % save_error)
		return MCPToolkitSuccess.ok({"path": root.scene_file_path})
	if not FileAccess.file_exists(path):
		return MCPToolkitError.fail("SAVE_FAILED",
			"save_scene_as did not produce %s" % path)
	return MCPToolkitSuccess.ok({"path": path})


## Editor-safe save for SYNCHRONOUS callers — notably C# extension handlers,
## which can't await a GDScript coroutine. Schedules save_scene() as a detached
## coroutine (the C1 re-entrancy flag + C2 scan-idle guard still apply) and
## returns a **save id** immediately. Poll the id with check_save() to learn the
## outcome (the save completes after you return). From GDScript, prefer the
## awaited save_scene() directly when you need the result inline.
static func queue_save(path := "") -> String:
	_save_counter += 1
	var save_id := "save_%d" % _save_counter
	# Bound the tracker (drop the oldest) so a caller that never clears can't leak.
	if _save_results.size() >= _MAX_TRACKED_SAVES:
		_save_results.erase(_save_results.keys()[0])
	_save_results[save_id] = {"done": false}
	_run_queued_save(save_id, path)  # detached coroutine — intentionally not awaited
	return save_id


static func _run_queued_save(save_id: String, path: String) -> void:
	var result := await save_scene(path)
	var ok := bool(result.get("success", false))
	_save_results[save_id] = {"done": true, "success": ok, "result": result}
	if not ok:
		push_warning("[MCPToolkitSafeSceneOps] queued save '%s' failed: %s" % [
			save_id, str(result.get("error", result))])


## Poll a queued save by id. Returns `{done = false}` while still in flight,
## `{done = false, unknown = true}` for an unknown id, or
## `{done = true, success = bool, result = {...}}` once complete. A caller can
## yield a frame and poll until `done`. If `clear` is true AND the save is done,
## the record is removed (a later check_save returns `unknown`).
static func check_save(save_id: String, clear := false) -> Dictionary:
	if not _save_results.has(save_id):
		return {"done": false, "unknown": true}
	var status: Dictionary = _save_results[save_id]
	if clear and bool(status.get("done", false)):
		_save_results.erase(save_id)
	return status.duplicate(true)
