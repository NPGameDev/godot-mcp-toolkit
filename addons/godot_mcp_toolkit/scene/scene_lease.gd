@tool
extends RefCounted
## Coordinates the time-bounded per-scene editing lease + the scene-affinity queue
## that keep concurrent peers targeting different scenes from contaminating each
## other's edited tab. It owns the lease state (holder / scene / renewal stamp), the
## per-peer scene affinity, and the FIFO of tab-dependent commands waiting on the
## lease — plus the full mechanism over them: acquire / renew / release / steal
## (TTL expiry) / drain, scene.open contention handling, and the queued-command
## execution path. The dispatch layer ROUTES into this child's public API; the
## routing itself lives in the scene-lease lane (dispatch_lane.gd), not here.
##
## Editor-side ONLY — and TAINTED by design: it names EditorInterface (via the
## injected root-resolver) and reaches Modules.CommandHelpers.open_scene_deferred. That is
## allowed because the Mode-B runtime autoload has NO scene lease and must NEVER
## preload this file (it has no affinity/tab concept — a running game always owns
## its single SceneTree). #91713 therefore does not gate this child, but a runtime
## reference to it WOULD taint the autoload, so keep it strictly editor-only: only
## mcp_server.gd (the editor server) preloads it.
##
## Seams the dispatcher / mutation lane inject (so this child does not reach back
## into not-yet-extracted server internals, mirroring mutation_watchdog's
## force_clear hook): a root-resolver Callable (the testability seam — the editor
## injects EditorInterface.get_edited_scene_root, a unit test injects a stub), the
## command_received re-emit, the read-only execute core, the mutation busy-enqueue,
## and the mutation-lane entry. The registry is held directly (set_registry), like
## the server holds it, because the drain + scene.open paths query it and call
## commands. Notifier / FileGuard / MCPToolkitError / open_scene_deferred are
## reached directly (this child is tainted, so the clean-closure rule does not bind
## it) exactly as the server's _send_* wrappers did.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Notifier := preload("res://addons/godot_mcp_toolkit/transport/notifier.gd")

# Pending tab-dependent command waiting for the lease (one queued JSON-RPC request).
class _SceneQueueEntry:
	var peer: WebSocketPeer
	var id  # int or null (JSON-RPC id)
	var method: String
	var params: Dictionary
	var queued_ms: int = 0
	var cancelled: bool = false

# Late-bound collaborators. The registry is set by the server's set_registry (which
# runs before start() builds this child, then is re-pushed here at construction).
var _registry: MCPToolkitCommandRegistry = null

# Injected seams (see the class docstring). Wired once in mcp_server._init_scene_lease.
# _root_resolver: func() -> Node — the active edited-scene root (EditorInterface in
#   the editor; a stub in unit tests). The ONLY way this child learns the active tab.
var _root_resolver: Callable = Callable()
# _on_command: func(method: String) -> void — re-emit the server's command_received.
var _on_command: Callable = Callable()
# _run_read: func(peer, method: String, params: Dictionary, id) -> Dictionary (await)
#   — the dispatcher's read-only execute core (peer-scoped context bookkeeping +
#   call_command); stays in the dispatcher so _active_contexts is not shared across
#   the seam.
var _run_read: Callable = Callable()
# _enqueue_mutation_if_busy: func(peer, id, method, params, queued_ms) -> bool —
#   if a mutation is in flight, append to the mutation FIFO + send _queued and return
#   true; else false. The mutation-lane state (_mutation_in_flight / _mutation_queue)
#   stays in the dispatcher; this keeps it out of the lease child.
var _enqueue_mutation_if_busy: Callable = Callable()
# _execute_mutation: func(peer, id, method, params, scene_queued_ms) -> void — the
#   mutation-lane entry (it re-drains the mutation queue on completion).
var _execute_mutation: Callable = Callable()

# -- Lease state ---------------------------------------------------------------

# Scene affinity per peer: peer → scene path (or "" if no affinity).
var _peer_scene_affinity: Dictionary = {}  # WebSocketPeer → String

# Scene lease state.
var _lease_holder: WebSocketPeer = null
var _lease_scene: String = ""
var _lease_renewed_ms: int = 0

# Pending tab-dependent commands waiting for lease.
var _scene_queue: Array = []  # of _SceneQueueEntry


## Wire the late-bound collaborators. Call once at construction, before any dispatch.
## See the per-field docstrings above for each seam's contract.
func set_handlers(root_resolver: Callable, on_command: Callable,
		run_read: Callable, enqueue_mutation_if_busy: Callable,
		execute_mutation: Callable) -> void:
	_root_resolver = root_resolver
	_on_command = on_command
	_run_read = run_read
	_enqueue_mutation_if_busy = enqueue_mutation_if_busy
	_execute_mutation = execute_mutation


func set_registry(registry: MCPToolkitCommandRegistry) -> void:
	_registry = registry


## Release the registry + handler references during plugin teardown, so the
## Callable → GDScript chains this child holds (the registry's command handlers and
## the seams bound back to the server) are broken before the server node is freed.
func clear_registry() -> void:
	_registry = null
	_root_resolver = Callable()
	_on_command = Callable()
	_run_read = Callable()
	_enqueue_mutation_if_busy = Callable()
	_execute_mutation = Callable()


# -- Dispatch entry points (the dispatcher routes into these) -------------------


## scene.open: intercepted at dispatch level because under contention we must NOT
## call open_scene_from_path — the tab switch would interfere with the lease holder.
## Validation mirrors _cmd_scene_open.
func handle_scene_open(peer: WebSocketPeer, id, params: Dictionary) -> void:
	# Validate file_path — mirrors _cmd_scene_open checks. Intercepted here
	# because under contention we must NOT call open_scene_from_path (the tab
	# switch would interfere with the lease holder).
	var err = MCPToolkitError.require(params, ["file_path"])
	if err != null:
		Notifier.send_result(peer, id, err, "[MCPServer]")
		return
	var file_path := str(params.get("file_path", ""))
	var guard := Modules.FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		Notifier.send_result(peer, id,
			MCPToolkitError.fail("PATH_DENIED", str(guard["reason"])), "[MCPServer]")
		return
	if not FileAccess.file_exists(file_path):
		Notifier.send_result(peer, id, MCPToolkitError.fail("NOT_FOUND",
			"scene not found: %s" % file_path, MCPToolkitError.HINT_FILE_PATH), "[MCPServer]")
		return

	# Set affinity.
	_peer_scene_affinity[peer] = file_path

	# Attempt lease.
	var acquired := try_acquire(peer, file_path)
	_on_command.call("scene.open")
	if acquired:
		# Lease acquired — call the actual handler (opens the scene).
		var result: Dictionary = await _registry.call_command("scene.open", params)
		Notifier.send_result(peer, id, result, "[MCPServer]")
	else:
		# Contended — don't open the scene, return success + contention hint.
		var hint := _build_contention_hint()
		var result := {"success": true, "path": file_path}
		if not hint.is_empty():
			result["hint"] = hint
		Notifier.send_result(peer, id, result, "[MCPServer]")


## Route a tab-dependent command through the scene lease. Returns true when it was
## queued (the caller must then return — no response yet); false when the command
## should proceed to the mutation/read lanes now. Renews the lease if this peer
## holds it and is already on the active tab. Commands that don't require the active
## scene short-circuit to false.
func try_queue_for_lease(peer: WebSocketPeer, id, method: String,
		params: Dictionary) -> bool:
	if not _registry.is_active_scene_required(method):
		return false
	var peer_scene := str(_peer_scene_affinity.get(peer, ""))
	var active_scene := _active_scene_path()
	if not peer_scene.is_empty() and peer_scene != active_scene:
		# Target doesn't match active tab — queue for lease.
		var entry := _SceneQueueEntry.new()
		entry.peer = peer
		entry.id = id
		entry.method = method
		entry.params = params
		entry.queued_ms = Time.get_ticks_msec()
		_scene_queue.append(entry)
		Notifier.send_notification(peer, "_queued", {"request_id": id}, "[MCPServer]")
		return true
	# Target matches active tab (or no affinity) — execute normally.
	# Renew lease if this peer holds it.
	if _lease_holder == peer:
		_lease_renewed_ms = Time.get_ticks_msec()
	return false


## Flag a queued (not-yet-executing) scene-queue command for skip-on-drain — the
## scene-queue fallback of cancellation, for targets not found among the in-flight
## contexts or the mutation queue. Matches on the requesting [param peer] AND the id
## (ids are only unique per client, so an id-only match could cancel another peer's
## queued command). Returns true if a matching entry was found.
func cancel_queued(peer: WebSocketPeer, target_id: String) -> bool:
	for entry in _scene_queue:
		if entry.peer == peer and str(entry.id) == target_id:
			entry.cancelled = true
			return true
	return false


## Per-peer cleanup on disconnect: drop the affinity, release the lease if this peer
## held it (which drains the next waiter), and remove the peer's queued scene
## commands. The transport has already erased its own peer maps.
func on_peer_closed(peer: WebSocketPeer) -> void:
	_peer_scene_affinity.erase(peer)
	if _lease_holder == peer:
		release()  # Immediate release → drain queue.
	# Remove queued scene commands for this peer.
	_scene_queue = _scene_queue.filter(func(entry: _SceneQueueEntry):
		return entry.peer != peer)


# -- Lease mechanism -----------------------------------------------------------


# The active edited-scene path via the injected root-resolver (EditorInterface in
# the editor; a stub in tests). "" when there is no edited scene.
func _active_scene_path() -> String:
	var root: Node = _root_resolver.call()
	if root == null:
		return ""
	return root.scene_file_path


func _build_contention_hint() -> String:
	if _lease_holder == null or _lease_scene.is_empty():
		return ""
	return (
		"Note: another session is currently editing %s. "
		+ "Work that doesn't target this scene executes immediately "
		+ "without waiting — for example, reading or writing scripts "
		+ "for your own scenes, managing your files, or querying project "
		+ "info. Work that modifies nodes or reads scene trees will queue "
		+ "until the editor tab becomes available — wait times are variable."
	) % _lease_scene


## Acquire (or renew) the lease for this peer's affinity scene. Pure bookkeeping —
## deliberately NO raw open_scene_from_path here (a raw open violates the #75669
## deferred-open rule and is unguarded against scans); tab activation happens in
## the guarded _execute_scene_queued_* paths via _switch_to_affinity_scene. Returns
## true on acquire/renew, false when another peer holds it (or the scene was deleted).
func try_acquire(peer: WebSocketPeer, scene: String) -> bool:
	if _lease_holder == null:
		# No current holder — acquire.
		if not scene.is_empty() and not FileAccess.file_exists(scene):
			_peer_scene_affinity.erase(peer)
			return false  # Scene was deleted.
		_lease_holder = peer
		_lease_scene = scene
		_lease_renewed_ms = Time.get_ticks_msec()
		# Lease acquisition stays pure bookkeeping — no raw open_scene_from_path
		# (it would violate the #75669 deferred-open rule, unguarded against
		# scans). Tab activation belongs to the guarded _execute_scene_queued_*
		# paths via _switch_to_affinity_scene.
		return true
	if _lease_holder == peer:
		# Same peer — renew.
		_lease_renewed_ms = Time.get_ticks_msec()
		return true
	return false  # Lease held by another peer.


## Release the lease and drain the next waiter. Public so the unit test can exercise
## the release leg; in production it is reached via expiry / disconnect / scene.close.
func release() -> void:
	_lease_holder = null
	_lease_scene = ""
	_lease_renewed_ms = 0
	drain()


## TTL steal: if a waiter is queued and the holder has exceeded the lease TTL, release
## so the next waiter can acquire. Runs every poll tick from the server's _process.
func check_expiry() -> void:
	# Don't steal/drain during a save's re-entry (a lease-steal would drain a
	# scene-queued command mid-save).
	if MCPToolkitSafeSceneOps.is_dispatching():
		return
	if _lease_holder == null:
		return
	if _scene_queue.is_empty():
		return  # No waiters — don't expire the lease.
	var ttl_ms: int = ProjectSettings.get_setting(
		"mcp_toolkit/concurrency/scene_lease_ttl_ms", 8000)
	var elapsed := Time.get_ticks_msec() - _lease_renewed_ms
	if elapsed >= ttl_ms:
		# Steal: a peer has been waiting and the lease exceeded TTL.
		release()  # Triggers drain → next waiter gets lease.


## Hand the lease to the next eligible waiter and execute its command (one at a time;
## the next drain is triggered on completion). Skips cancelled / disconnected /
## unregistered / affinity-cleared entries. Called by the dispatcher after the
## mutation queue drains, and internally on release / read completion.
func drain() -> void:
	while not _scene_queue.is_empty():
		var entry: _SceneQueueEntry = _scene_queue.pop_front()
		# Skip cancelled entries.
		if entry.cancelled:
			continue
		# Skip disconnected peers.
		if entry.peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
			continue
		# Skip unregistered commands (hot-reload race).
		if not _registry.has_command(entry.method):
			Notifier.send_error(entry.peer, entry.id, -32601,
				"Method unregistered while queued: %s" % entry.method)
			continue

		# Acquire lease for this peer's affinity scene.
		var peer_scene := str(_peer_scene_affinity.get(entry.peer, ""))
		if peer_scene.is_empty():
			# Peer cleared affinity while queued — skip.
			continue
		if not try_acquire(entry.peer, peer_scene):
			# Lease held by another peer — put entry back and stop.
			_scene_queue.push_front(entry)
			return

		# Calculate how long this entry was queued.
		var queued_ms := Time.get_ticks_msec() - entry.queued_ms

		# Type-aware dispatch: mutations → mutation lane (respects mutation lock);
		# reads → execute directly (no lock needed).
		if _registry.needs_serialization(entry.method):
			_execute_scene_queued_mutation(entry, queued_ms)
		else:
			_execute_scene_queued_read(entry, queued_ms)
		return  # One at a time; next drain triggered on completion.
	# Scene queue fully drained — nothing left.


# Switch the editor to the peer's affinity scene before executing a
# scene-queued command (try_acquire deliberately does no open). Guarded against
# an active EditorFileSystem scan. Returns false — and sends the peer a TIMEOUT — if
# it can't switch, so the caller aborts this one entry (the rest of the queue stays
# for the next drain trigger).
func _switch_to_affinity_scene(peer: WebSocketPeer, id) -> bool:
	var scene := str(_peer_scene_affinity.get(peer, ""))
	if scene.is_empty() or _active_scene_path() == scene:
		return true
	if await Modules.CommandHelpers.open_scene_deferred(scene):
		return true
	Notifier.send_result(peer, id, MCPToolkitError.fail("TIMEOUT",
		"could not switch to %s — EditorFileSystem still scanning" % scene), "[MCPServer]")
	return false


func _execute_scene_queued_mutation(entry: _SceneQueueEntry,
		queued_ms: int) -> void:
	# Re-queue (no tab switch) BEFORE activating the tab, to avoid an unnecessary
	# switch when the mutation lock is busy.
	if _enqueue_mutation_if_busy.call(entry.peer, entry.id, entry.method,
			entry.params, queued_ms):
		return
	# Activate the peer's affinity scene here, guarded against a scan.
	if not await _switch_to_affinity_scene(entry.peer, entry.id):
		return
	_execute_mutation.call(entry.peer, entry.id, entry.method, entry.params, queued_ms)


func _execute_scene_queued_read(entry: _SceneQueueEntry,
		queued_ms: int) -> void:
	# Activate the peer's affinity scene (guarded) before the read.
	if not await _switch_to_affinity_scene(entry.peer, entry.id):
		return
	var result: Dictionary = await _run_read.call(entry.peer, entry.method, entry.params, entry.id)
	if queued_ms > 0:
		inject_concurrency_metadata(result, queued_ms)
	Notifier.send_result(entry.peer, entry.id, result, "[MCPServer]")
	# Check for more entries from the same peer/scene.
	drain()


## After a successful scene.close: drop the peer's affinity for that scene and
## release the lease if this peer held it on that scene. Called by the mutation lane
## once a scene.close mutation completes.
func post_mutation_cleanup(peer: WebSocketPeer, method: String,
		params: Dictionary, result: Dictionary) -> void:
	if method != "scene.close":
		return
	if not result.get("success", false):
		return
	var file_path := str(params.get("file_path", ""))
	if _peer_scene_affinity.get(peer, "") == file_path:
		_peer_scene_affinity.erase(peer)
	if _lease_holder == peer and _lease_scene == file_path:
		release()


## Annotate a result with how long it waited on the scene lease: a zero-token _meta
## block always, plus a content sentence past a 3 s threshold. Called by the mutation
## lane and the queued-read path for commands that waited. No-op for queued_ms <= 0.
func inject_concurrency_metadata(result: Dictionary, queued_ms: int) -> void:
	if queued_ms <= 0:
		return
	# Tier 1: _meta (zero LLM tokens — bridge can extract to MCP _meta).
	result["_meta"] = {
		"concurrency": {
			"queued_ms": queued_ms,
			"reason": "scene_lease_wait",
			"lease_holder_scene": _lease_scene,
		}
	}
	# Tier 3: threshold-gated content sentence (>3s only).
	if queued_ms > 3000:
		var note := (
			"(Scene access waited %.1fs — another session holds the "
			+ "active tab. Scene-independent tools execute without waiting.)"
		) % (queued_ms / 1000.0)
		var existing_hint := str(result.get("hint", ""))
		if not existing_hint.is_empty():
			result["hint"] = existing_hint + " " + note
		else:
			result["hint"] = note


## The current lease holder (or null). Read-only accessor for the unit test's
## acquire/release assertions; production callers route through the methods above.
func lease_holder() -> WebSocketPeer:
	return _lease_holder
