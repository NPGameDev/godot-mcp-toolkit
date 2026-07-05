@tool
class_name MCPToolkitSafeSceneOps
extends RefCounted
## Editor-safe scene saving for command handlers.
##
## Command handlers (toolkit OR extension) must save through this class — never by
## calling [code]EditorInterface.save_scene()[/code] / [code]save_scene_as()[/code]
## directly — so the dispatch-safety guards apply: a scan-idle wait (C2) and a
## re-entrancy guard around the synchronous save (C1) that together keep a save from
## corrupting an in-flight import or another save. From GDScript, [code]await[/code]
## [method save_scene] for the result inline; from a synchronous caller (notably a
## C# handler that cannot await), call [method queue_save] and poll
## [method check_save]. See [code]docs/extending.md[/code] and
## [code]docs/advanced_configuration.md[/code].[br]
## [br]
## Example (GDScript handler):
## [codeblock]
## var result := await MCPToolkitSafeSceneOps.save_scene()
## if not result.get("success", false):
##     return result
## [/codeblock]

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const FileGuard = Modules.FileGuard

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


## Returns [code]true[/code] while a save's synchronous
## [code]EditorInterface.save_scene[/code]/[code]save_scene_as[/code] call is in
## flight. Frame-driven dispatch initiators early-return when this is true so no
## command dispatches during the save's re-entrant main-loop pump (the C1 guard,
## all engine versions).
static func is_dispatching() -> bool:
	return _in_dispatch


## Awaits until the EditorFileSystem scan finishes (this is a coroutine — call it
## with [code]await[/code]). Returns [code]true[/code] if idle was reached,
## [code]false[/code] on timeout. A negative [param timeout_ms] (the default) uses
## the configured default ([code]mcp_toolkit/concurrency/scan_idle_timeout_ms[/code],
## default 5000); [code]0[/code] fails fast (returns immediately unless already
## idle).
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


## Saves a scene safely (this is a coroutine — call it with [code]await[/code]).
## An empty [param path] (the default) saves the active edited scene; a non-empty
## [param path] saves to that [code]res://[/code] location (a save-as, path-guarded).
## Applies the C2 guard (waits for scan idle, aborting on timeout) and the C1 guard
## (serializes the synchronous save against any other in-flight save). Returns a
## success dict carrying the saved [code]path[/code], or an error dict
## ([code]NO_SCENE[/code], [code]PATH_DENIED[/code], [code]TIMEOUT[/code],
## [code]BUSY[/code], or [code]SAVE_FAILED[/code]).
static func save_scene(path := "") -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return MCPToolkitError.fail("NO_SCENE", "no edited scene")
	if not path.is_empty():
		var guard := FileGuard.resolve_safe(path)
		if guard["error"] != null:
			return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	# Don't save into an active scan.
	if not await wait_for_scan_idle():
		return MCPToolkitError.fail("TIMEOUT",
			"EditorFileSystem still scanning; a recent import/refresh may still "
			+ "be indexing — call editor_wait_for_idle or retry")
	# Escape the call_deferred/flush context before the ProgressDialog.
	await (Engine.get_main_loop() as SceneTree).process_frame
	# Re-entrancy guard — checked HERE, after the frame yield: an
	# EditorInterface.save_scene() already in flight pumps Main::iteration(), whose
	# process_frame emission can RESUME this coroutine mid-pump. If another save
	# holds the synchronous window (_in_dispatch), opening a second
	# EditorProgress("save") would error ("Task 'save' already exists") + run a
	# redundant nested save — so bail cleanly. No await between this check and the
	# set below, so it stays atomic in single-threaded GDScript.
	if _in_dispatch:
		return MCPToolkitError.fail("BUSY",
			"a scene save is already in progress — retry once it completes")
	# --- Synchronous danger window: NO awaits between set and clear ---
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


## Editor-safe save for SYNCHRONOUS callers — notably C# extension handlers, which
## cannot await a GDScript coroutine. Schedules [method save_scene] (with
## [param path], same semantics) as a detached coroutine — the C1 and C2 guards still
## apply — and returns a save id immediately, before the save runs. Poll that id
## with [method check_save] to learn the outcome. Returns the save id. From
## GDScript, prefer awaiting [method save_scene] directly when you need the result
## inline.
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


## Polls a queued save by [param save_id] (the id returned from
## [method queue_save]). Returns [code]{done = false}[/code] while still in flight,
## [code]{done = false, unknown = true}[/code] for an unknown id, or
## [code]{done = true, success = bool, result = {...}}[/code] once complete, where
## [code]result[/code] is the [method save_scene] dict. Yield a frame and poll
## until [code]done[/code]. When [param clear] is [code]true[/code] and the save is
## done, the record is removed (a later [method check_save] returns
## [code]unknown[/code]).
static func check_save(save_id: String, clear := false) -> Dictionary:
	if not _save_results.has(save_id):
		return {"done": false, "unknown": true}
	var status: Dictionary = _save_results[save_id]
	if clear and bool(status.get("done", false)):
		_save_results.erase(save_id)
	return status.duplicate(true)
