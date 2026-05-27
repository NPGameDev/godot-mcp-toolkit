@tool
extends Node
## WebSocket JSON-RPC framing and peer lifecycle.
##
## All command logic lives in per-domain modules under commands/.
## This file handles: TCP listener, WS peer accept/poll, JSON-RPC parse,
## and dispatch via MCPToolkitCommandRegistry.

signal client_connected(peer_count: int)
signal client_disconnected(peer_count: int)
signal command_received(method: String)

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const RegistryClient = _Hub.RegistryClient
const MCPAuth := preload("res://addons/godot_mcp_toolkit/auth.gd")
const UndoRedoHelpers := preload("res://addons/godot_mcp_toolkit/undo_redo_helpers.gd")

const PORT_BASE := 6550
const PORT_RANGE := 11  # 6550..6560 inclusive
const BIND := "127.0.0.1"
const JSONRPC_VERSION := "2.0"
# Throttle re-listen retries to avoid log spam when the port is
# briefly held by another process (e.g. a second editor instance, a stale
# debugger). 60 frames ~= 1s at 60fps; the bridge's reconnect backoff sits
# on the same order so we don't pile retries on top of the bridge's.
const _RELISTEN_FRAME_INTERVAL := 60
# Poll TCPServer/WebSocket peers every Nth frame instead of every frame.
# Godot has a race between plugin _process work and the main-loop work
# triggered by FileSystem-dock interactions (reentrancy through
# Main::iteration — see godotengine/godot#46893, #54864, #110891).
# Two mitigations stack:
#   1. Frame-skip: poll at ~15Hz (4 frames) instead of 60Hz, shrinking
#      the collision window ~4x. Original F3 fix from iter 13c.
#   2. Deferred dispatch: _process schedules the poll body via
#      call_deferred instead of running it inline, moving our I/O out
#      of the _process call stack where reentrancy is most dangerous.
# Side-effect: commands run inside the deferred-call context, so Godot
# APIs that use the progress dialog (e.g. save_scene) log benign
# progress_dialog.cpp errors. This is acceptable — the alternative
# (inline _process poll) causes reproducible editor crashes.
# No upstream structural fix exists as of Godot 4.5/4.6-dev.
const _POLL_FRAME_INTERVAL := 4
# Auth timeout. Peers that don't send a valid auth message within this
# window are closed with WS close code 1008 (Policy Violation).
const _AUTH_TIMEOUT_MS := 2000

var _tcp_server: TCPServer = null
var _peers: Array[WebSocketPeer] = []
var _relisten_countdown := 0
# Tracks the current run of consecutive _try_listen() failures so we can log
# the first one (with a hint), stay silent during retries, and announce the
# recovery with the attempt count. Reset on every successful listen.
var _consecutive_failures := 0
var _poll_frame_counter := 0
# Captured at start() so editor.get_console's log-file selection heuristic
# can prefer post-boot logs over stale rotated ones.
var _plugin_boot_time: int = 0
var _registry: MCPToolkitCommandRegistry = null
## Tracks MCPToolkitToolContext per in-flight cancellable request, keyed by
## JSON-RPC id (string). Populated in _dispatch_rpc; erased after handler
## returns. Looked up by _cancel notifications to trigger cooperative cancel.
var _active_contexts: Dictionary = {}
var _session_token: String = ""
var _peer_authed: Dictionary = {}       # WebSocketPeer -> true (authed peers only)
var _peer_connect_ms: Dictionary = {}   # WebSocketPeer -> int (ticks_msec at accept)
# -1 = never bound.
var _bound_port: int = -1
# -1 = not yet saved (no active connections have triggered the override).
var _original_unfocused_sleep_usec: int = -1
## Set by plugin.gd so domain commands can call EditorPlugin API
## (e.g. add_autoload_singleton for immediate editor cache refresh).
var editor_plugin: EditorPlugin = null
const _ACTIVE_UNFOCUSED_SLEEP_USEC := 16666  # ~= 60 fps while MCP clients connected

## Node holding UndoRedo helper methods that domain commands reference by
## string name. Populated in start(); command closures access it via
## server.undo_helpers.
var undo_helpers: Node = null

# -- Mutation serialisation ---------------------------------------------------
# When multiple WebSocket peers are connected, mutation commands must not
# interleave at await boundaries. A single-flight flag + FIFO queue ensures
# that at most one mutation executes at any time. Read-only commands bypass
# the lock entirely. See iter 41l-decies for the full design.

class _MutationQueueEntry:
	var peer: WebSocketPeer
	var id  # int or null (JSON-RPC id)
	var method: String
	var params: Dictionary
	var cancelled: bool = false
	var scene_queued_ms: int = 0  # Non-zero when first queued in the scene queue.

var _mutation_in_flight := false
var _mutation_queue: Array = []  # of _MutationQueueEntry

# -- Scene lease ---------------------------------------------------------------
# When multiple peers target different scenes, a time-bounded lease prevents
# cross-scene contamination. Tab-dependent commands queue until the peer's
# affinity scene matches the active tab. See iter 41l-decies-bis for design.

class _SceneQueueEntry:
	var peer: WebSocketPeer
	var id  # int or null (JSON-RPC id)
	var method: String
	var params: Dictionary
	var queued_ms: int = 0
	var cancelled: bool = false

# Scene affinity per peer: peer → scene path (or "" if no affinity).
var _peer_scene_affinity: Dictionary = {}  # WebSocketPeer → String

# Scene lease state.
var _lease_holder: WebSocketPeer = null
var _lease_scene: String = ""
var _lease_renewed_ms: int = 0

# Pending tab-dependent commands waiting for lease.
var _scene_queue: Array = []  # of _SceneQueueEntry


func set_registry(registry: MCPToolkitCommandRegistry) -> void:
	_registry = registry


## Release the command registry and all its Callable references.
## Called during plugin teardown to break reference chains before node deletion.
func clear_registry() -> void:
	if _registry != null:
		_registry.clear()
		_registry = null


func get_plugin_boot_time() -> int:
	return _plugin_boot_time


func is_listening() -> bool:
	return _tcp_server != null and _tcp_server.is_listening()


func get_authed_peer_count() -> int:
	return _peer_authed.size()


func get_bound_port() -> int:
	return _bound_port


func get_command_methods() -> Array:
	if _registry == null:
		return []
	return _registry.get_all_methods()


## Send a notification to all authenticated WebSocket peers.
## Used by the dock to signal config changes (e.g. profile updates)
## so the MCP server can reload its tool list without a restart.
func broadcast_notification(notification_type: String, params: Dictionary = {}) -> void:
	var payload := {"notification": notification_type}
	if not params.is_empty():
		payload["params"] = params
	var message := JSON.stringify(payload)
	var count := 0
	for peer in _peer_authed:
		if peer is WebSocketPeer and peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			peer.send_text(message)
			count += 1
	print("[MCPServer] broadcasting %s to %d authed peer%s" % [
		notification_type, count, "" if count == 1 else "s"])


func bind_user_path_monitor(monitor: RefCounted) -> void:
	monitor.project_name_changed.connect(_on_project_name_changed)


func _on_project_name_changed(_old_name: String, _new_name: String) -> void:
	_rewrite_token_after_rename()


## Re-write the current in-memory token to the new user:// path after a
## config/name change. Does NOT generate a new token — existing connections
## stay authenticated. Also updates the system registry entry.
func _rewrite_token_after_rename() -> void:
	var write_err := MCPAuth.write_token(_session_token)
	if write_err != OK:
		push_warning("[MCPServer] failed to re-write token after rename (err %d)" % write_err)
	else:
		print("[MCPServer] token re-written to %s" % MCPAuth.get_token_path())
	# Update registry so the bridge finds the new token_path.
	if _bound_port > 0:
		RegistryClient.register(_bound_port, MCPAuth.get_token_path())


func regenerate_token() -> void:
	_session_token = MCPAuth.generate_token()
	var write_err := MCPAuth.write_token(_session_token)
	if write_err != OK:
		push_warning("[MCPServer] failed to write rotated token (err %d)" % write_err)
	else:
		print("[MCPServer] token rotated, written to %s" % MCPAuth.get_token_path())
	# Close all existing peers — they must re-auth with the new token.
	for peer in _peers:
		if peer != null:
			peer.close(1008, "token rotated")
	_peers.clear()
	_peer_authed.clear()
	_peer_connect_ms.clear()


func start() -> void:
	if undo_helpers == null:
		undo_helpers = UndoRedoHelpers.new()
		undo_helpers.name = "UndoRedoHelpers"
		add_child(undo_helpers)
	_plugin_boot_time = int(Time.get_unix_time_from_system())
	_relisten_countdown = 0
	_bound_port = -1
	_session_token = MCPAuth.generate_token()
	var write_err := MCPAuth.write_token(_session_token)
	if write_err != OK:
		push_warning("[MCPServer] failed to write token (err %d); auth will still be enforced but bridge may not find the file" % write_err)
	else:
		var token_path := MCPAuth.get_token_path()
		print("[MCPServer] session token written to %s" % token_path)
	_scan_and_listen()


func stop() -> void:
	set_process(false)
	for peer in _peers:
		if peer != null:
			peer.close(1000)
	_peers.clear()
	_peer_authed.clear()
	_peer_connect_ms.clear()
	_restore_unfocused_sleep()
	if _tcp_server != null:
		_tcp_server.stop()
		_tcp_server = null
	_relisten_countdown = 0
	_consecutive_failures = 0
	_bound_port = -1
	print("[MCPServer] stopped")


# -- Networking ----------------------------------------------------------------


# First-time port scan. Tries PORT_BASE..PORT_BASE+PORT_RANGE-1 and binds
# the first free port. Sets _bound_port on success. If no port is available,
# schedules a throttled retry.
func _scan_and_listen() -> void:
	for offset in range(PORT_RANGE):
		var candidate := PORT_BASE + offset
		var server := TCPServer.new()
		var err := server.listen(candidate, BIND)
		if err == OK:
			_tcp_server = server
			_bound_port = candidate
			_consecutive_failures = 0
			_relisten_countdown = 0
			print("[MCPServer] listening on %s:%d" % [BIND, _bound_port])
			return
		server.stop()
	# All ports in range exhausted.
	_consecutive_failures += 1
	if _consecutive_failures == 1:
		push_warning("[MCPServer] no free port in %d-%d; will retry every ~1s" % [PORT_BASE, PORT_BASE + PORT_RANGE - 1])
	_tcp_server = null
	_relisten_countdown = _RELISTEN_FRAME_INTERVAL


# Idempotent re-listen. Called from _process when the TCPServer falls out
# of the listening state. If we already found a port (_bound_port > 0),
# retry that specific port. Otherwise re-scan the range.
func _try_listen() -> void:
	if _relisten_countdown > 0:
		_relisten_countdown -= 1
		return
	if _bound_port < 0:
		_scan_and_listen()
		return
	if _tcp_server == null:
		_tcp_server = TCPServer.new()
	var error := _tcp_server.listen(_bound_port, BIND)
	if error == OK:
		if _consecutive_failures > 0:
			print("[MCPServer] listening on %s:%d (recovered after %d failed attempts)" % [BIND, _bound_port, _consecutive_failures])
		_consecutive_failures = 0
		_relisten_countdown = 0
		return
	_consecutive_failures += 1
	if _consecutive_failures == 1:
		var hint := ""
		if error == ERR_ALREADY_IN_USE:
			hint = " (ERR_ALREADY_IN_USE — will retry silently every ~1s)"
		push_warning("[MCPServer] rebind %s:%d failed (err %d)%s" % [BIND, _bound_port, error, hint])
	_tcp_server.stop()
	_tcp_server = null
	_relisten_countdown = _RELISTEN_FRAME_INTERVAL


# -- Frame loop ----------------------------------------------------------------


func _process(_delta: float) -> void:
	_Hub.LogBuffer.poll()
	_poll_frame_counter += 1
	if _poll_frame_counter < _POLL_FRAME_INTERVAL:
		return
	_poll_frame_counter = 0
	_check_lease_expiry()
	# Dispatch via call_deferred to move network I/O out of the _process
	# call stack, reducing the reentrancy collision surface with Godot's
	# EditorFileSystem scan/import work (see comment on _POLL_FRAME_INTERVAL).
	call_deferred("_poll_connections")


func _poll_connections() -> void:
	if _tcp_server == null or not _tcp_server.is_listening():
		_try_listen()
		return

	_accept_pending_peers()
	var closed := await _poll_connected_peers()
	_cleanup_closed_peers(closed)


func _accept_pending_peers() -> void:
	while _tcp_server.is_connection_available():
		var stream := _tcp_server.take_connection()
		var peer := WebSocketPeer.new()
		var buffer_kb: int = ProjectSettings.get_setting("mcp_toolkit/limits/ws_buffer_kb", 1024)
		peer.inbound_buffer_size = buffer_kb * 1024
		peer.outbound_buffer_size = buffer_kb * 1024
		var accept_error := peer.accept_stream(stream)
		if accept_error != OK:
			push_warning("[MCPServer] accept_stream failed (%d)" % accept_error)
			continue
		_peers.append(peer)
		_peer_connect_ms[peer] = Time.get_ticks_msec()


func _poll_connected_peers() -> Array[WebSocketPeer]:
	var closed: Array[WebSocketPeer] = []
	var now_ms := Time.get_ticks_msec()
	for peer in _peers:
		peer.poll()
		var state := peer.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			closed.append(peer)
			continue
		if state != WebSocketPeer.STATE_OPEN:
			continue
		# Auth timeout — close peers that haven't authed in time.
		if not _peer_authed.has(peer):
			if now_ms - int(_peer_connect_ms.get(peer, 0)) > _AUTH_TIMEOUT_MS:
				peer.close(1008, "auth timeout")
				closed.append(peer)
				continue
		while peer.get_available_packet_count() > 0:
			var text := peer.get_packet().get_string_from_utf8()
			await _handle_message(peer, text)
	return closed


func _cleanup_closed_peers(closed: Array[WebSocketPeer]) -> void:
	var had_authed_disconnect := false
	for peer in closed:
		if _peer_authed.has(peer):
			had_authed_disconnect = true
		_peers.erase(peer)
		_peer_authed.erase(peer)
		_peer_connect_ms.erase(peer)
		# Scene lease cleanup.
		_peer_scene_affinity.erase(peer)
		if _lease_holder == peer:
			_release_lease()  # Immediate release → drain queue.
		# Remove queued scene commands for this peer.
		_scene_queue = _scene_queue.filter(func(entry: _SceneQueueEntry):
			return entry.peer != peer)
	if had_authed_disconnect:
		if _peer_authed.size() == 0:
			_restore_unfocused_sleep()
		client_disconnected.emit(_peer_authed.size())


# -- Message handling ----------------------------------------------------------


func _handle_message(peer: WebSocketPeer, text: String) -> void:
	var parser := JSON.new()
	var parse_error := parser.parse(text)
	if parse_error != OK:
		_send_error(peer, null, -32700, "Parse error: %s" % parser.get_error_message())
		return

	var message = parser.data
	if typeof(message) != TYPE_DICTIONARY:
		_send_error(peer, null, -32600, "Invalid Request: top-level must be an object")
		return

	if not _peer_authed.has(peer):
		_handle_auth(peer, message)
		return

	await _dispatch_rpc(peer, message)


func _handle_auth(peer: WebSocketPeer, message: Dictionary) -> void:
	if MCPAuth.validate(message, _session_token):
		_peer_authed[peer] = true
		var vi := Engine.get_version_info()
		var plugin_ver := _get_plugin_version()
		peer.send_text(JSON.stringify({
			"authed": true,
			"godot_version": "%d.%d.%d" % [vi["major"], vi["minor"], vi["patch"]],
			"version": plugin_ver,
		}))
		# Version mismatch check — human-only (editor console), nothing on MCP wire.
		var server_ver: String = str(message.get("version", ""))
		if server_ver.is_empty():
			# Pre-handshake server — no version sent.
			pass
		else:
			_check_version_mismatch(plugin_ver, server_ver)
		if _peer_authed.size() == 1:
			_lower_unfocused_sleep()
		client_connected.emit(_peer_authed.size())
	else:
		peer.close(1008, "invalid token")


func _get_plugin_version() -> String:
	var cfg := ConfigFile.new()
	var err := cfg.load("res://addons/godot_mcp_toolkit/plugin.cfg")
	if err != OK:
		return "unknown"
	return cfg.get_value("plugin", "version", "unknown")


func _check_version_mismatch(local: String, remote: String) -> void:
	var local_parts := local.split(".")
	var remote_parts := remote.split(".")
	if local_parts.size() != 3 or remote_parts.size() != 3:
		return  # Non-semver — skip comparison.
	if not local_parts[0].is_valid_int() or not remote_parts[0].is_valid_int():
		return
	if int(local_parts[0]) != int(remote_parts[0]):
		push_error("[MCPServer] Major version mismatch — plugin %s, server %s. Update both to the same major version." % [local, remote])
	elif local != remote:
		push_warning("[MCPServer] Version mismatch — plugin %s, server %s. Consider updating." % [local, remote])


func _dispatch_rpc(peer: WebSocketPeer, message: Dictionary) -> void:
	var id = message.get("id", null)
	# Godot's JSON parser returns every number as float; coerce whole-float ids
	# back to int so {"id": 1} round-trips as {"id": 1}, not {"id": 1.0}.
	if typeof(id) == TYPE_FLOAT and int(id) == id:
		id = int(id)
	var method := str(message.get("method", ""))
	var parameters = message.get("params", null)

	if method.is_empty():
		_send_error(peer, id, -32600, "Invalid Request: missing method")
		return

	# _cancel is a fire-and-forget notification from the bridge — no response.
	# Triggers cooperative cancellation on the MCPToolkitToolContext for the target
	# request. Scans both mutation and scene queues for queued (not-yet-
	# executing) commands and flags them for skip-on-drain.
	if method == "_cancel":
		var safe_params: Dictionary = parameters \
			if typeof(parameters) == TYPE_DICTIONARY else {}
		var target_id := str(safe_params.get("request_id", ""))
		# In-flight: cancel via context.
		if _active_contexts.has(target_id):
			_active_contexts[target_id].cancel()
			return
		# Queued in mutation queue:
		for entry in _mutation_queue:
			if str(entry.id) == target_id:
				entry.cancelled = true
				return
		# Queued in scene queue:
		for entry in _scene_queue:
			if str(entry.id) == target_id:
				entry.cancelled = true
				break
		return

	# echo is a transport-level diagnostic, not a domain command.
	if method == "echo":
		_send_result(peer, id, parameters)
		return

	if _registry == null or not _registry.has_command(method):
		_send_error(peer, id, -32601, "Method not found: %s" % method)
		return

	var safe_parameters: Dictionary = parameters \
		if typeof(parameters) == TYPE_DICTIONARY else {}

	# -- Scene lease routing ---------------------------------------------------

	# scene.open: intercepted at dispatch level because under contention
	# we must NOT call open_scene_from_path — the tab switch would interfere
	# with the lease holder. Validation mirrors _cmd_scene_open.
	if method == "scene.open":
		await _handle_scene_open(peer, id, safe_parameters)
		return

	# Tab-dependent commands: route through scene lease when targeting a
	# different scene than the active tab.
	if _registry.is_active_scene_required(method):
		var peer_scene := str(_peer_scene_affinity.get(peer, ""))
		var active_scene := _get_active_scene_path()
		if not peer_scene.is_empty() and peer_scene != active_scene:
			# Target doesn't match active tab — queue for lease.
			var entry := _SceneQueueEntry.new()
			entry.peer = peer
			entry.id = id
			entry.method = method
			entry.params = safe_parameters
			entry.queued_ms = Time.get_ticks_msec()
			_scene_queue.append(entry)
			_send_notification(peer, "_queued", {"request_id": id})
			return
		# Target matches active tab (or no affinity) — execute normally.
		# Renew lease if this peer holds it.
		if _lease_holder == peer:
			_lease_renewed_ms = Time.get_ticks_msec()

	# -- Mutation lock routing (unchanged from 41l-decies) ---------------------

	if _registry.needs_serialization(method):
		if _mutation_in_flight:
			var entry := _MutationQueueEntry.new()
			entry.peer = peer
			entry.id = id
			entry.method = method
			entry.params = safe_parameters
			_mutation_queue.append(entry)
			_send_notification(peer, "_queued", {"request_id": id})
		else:
			await _execute_mutation(peer, id, method, safe_parameters)
	else:
		# Read-only: execute immediately, no lock needed.
		var ctx: MCPToolkitToolContext = null
		if _registry.is_cancellable(method):
			ctx = MCPToolkitToolContext.new()
			_active_contexts[str(id)] = ctx
		command_received.emit(method)
		var result: Dictionary = await _registry.call_command(
			method, safe_parameters, ctx)
		_active_contexts.erase(str(id))
		_send_result(peer, id, result)


func _execute_mutation(peer: WebSocketPeer, id, method: String,
		params: Dictionary, scene_queued_ms: int = 0) -> void:
	_mutation_in_flight = true
	_send_notification(peer, "_executing", {"request_id": id})
	var ctx: MCPToolkitToolContext = null
	if _registry.is_cancellable(method):
		ctx = MCPToolkitToolContext.new()
		_active_contexts[str(id)] = ctx
	command_received.emit(method)
	var result: Dictionary = await _registry.call_command(method, params, ctx)
	_active_contexts.erase(str(id))
	if scene_queued_ms > 0:
		_inject_concurrency_metadata(result, scene_queued_ms)
	_send_result(peer, id, result)
	_post_mutation_scene_cleanup(peer, method, params, result)
	_mutation_in_flight = false
	_drain_mutation_queue()


func _drain_mutation_queue() -> void:
	while not _mutation_queue.is_empty():
		var entry: _MutationQueueEntry = _mutation_queue.pop_front()
		# Skip cancelled entries.
		if entry.cancelled:
			continue
		# Skip disconnected peers.
		if entry.peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
			continue
		# Skip unregistered commands (hot-reload race).
		if not _registry.has_command(entry.method):
			_send_error(entry.peer, entry.id, -32601,
				"Method unregistered while queued: %s" % entry.method)
			continue
		# Found a valid entry — execute it.
		# _execute_mutation sets _mutation_in_flight = true synchronously
		# before its first await, so there is no race window.
		_execute_mutation(entry.peer, entry.id, entry.method, entry.params,
			entry.scene_queued_ms)
		return  # _execute_mutation will call _drain_mutation_queue on completion.
	# Mutation queue fully drained — check scene queue for same-lease entries.
	_drain_scene_queue()


# -- Scene lease ---------------------------------------------------------------


func _get_active_scene_path() -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return ""
	return root.scene_file_path


func _handle_scene_open(peer: WebSocketPeer, id, params: Dictionary) -> void:
	# Validate file_path — mirrors _cmd_scene_open checks. Intercepted here
	# because under contention we must NOT call open_scene_from_path (the tab
	# switch would interfere with the lease holder).
	var err = MCPToolkitError.require(params, ["file_path"])
	if err != null:
		_send_result(peer, id, err)
		return
	var file_path := str(params.get("file_path", ""))
	var guard := _Hub.FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		_send_result(peer, id, MCPToolkitError.fail("PATH_DENIED", str(guard["reason"])))
		return
	if not FileAccess.file_exists(file_path):
		_send_result(peer, id, MCPToolkitError.fail("NOT_FOUND",
			"scene not found: %s" % file_path, MCPToolkitError.HINT_FILE_PATH))
		return

	# Set affinity.
	_peer_scene_affinity[peer] = file_path

	# Attempt lease.
	var acquired := _try_acquire_lease(peer, file_path)
	command_received.emit("scene.open")
	if acquired:
		# Lease acquired — call the actual handler (opens the scene).
		var result: Dictionary = await _registry.call_command("scene.open", params)
		_send_result(peer, id, result)
	else:
		# Contended — don't open the scene, return success + contention hint.
		var hint := _build_contention_hint()
		var result := {"success": true, "path": file_path}
		if not hint.is_empty():
			result["hint"] = hint
		_send_result(peer, id, result)


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


func _try_acquire_lease(peer: WebSocketPeer, scene: String) -> bool:
	if _lease_holder == null:
		# No current holder — acquire.
		if not scene.is_empty() and not FileAccess.file_exists(scene):
			_peer_scene_affinity.erase(peer)
			return false  # Scene was deleted.
		_lease_holder = peer
		_lease_scene = scene
		_lease_renewed_ms = Time.get_ticks_msec()
		if _get_active_scene_path() != scene and not scene.is_empty():
			EditorInterface.open_scene_from_path(scene)
		return true
	if _lease_holder == peer:
		# Same peer — renew.
		_lease_renewed_ms = Time.get_ticks_msec()
		return true
	return false  # Lease held by another peer.


func _release_lease() -> void:
	_lease_holder = null
	_lease_scene = ""
	_lease_renewed_ms = 0
	_drain_scene_queue()


func _check_lease_expiry() -> void:
	if _lease_holder == null:
		return
	if _scene_queue.is_empty():
		return  # No waiters — don't expire the lease.
	var ttl_ms: int = ProjectSettings.get_setting(
		"mcp_toolkit/concurrency/scene_lease_ttl_ms", 8000)
	var elapsed := Time.get_ticks_msec() - _lease_renewed_ms
	if elapsed >= ttl_ms:
		# Steal: a peer has been waiting and the lease exceeded TTL.
		_release_lease()  # Triggers _drain_scene_queue → next waiter gets lease.


func _drain_scene_queue() -> void:
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
			_send_error(entry.peer, entry.id, -32601,
				"Method unregistered while queued: %s" % entry.method)
			continue

		# Acquire lease for this peer's affinity scene.
		var peer_scene := str(_peer_scene_affinity.get(entry.peer, ""))
		if peer_scene.is_empty():
			# Peer cleared affinity while queued — skip.
			continue
		if not _try_acquire_lease(entry.peer, peer_scene):
			# Lease held by another peer — put entry back and stop.
			_scene_queue.push_front(entry)
			return

		# Calculate how long this entry was queued.
		var queued_ms := Time.get_ticks_msec() - entry.queued_ms

		# Type-aware dispatch: mutations → _execute_mutation (respects mutation
		# lock); reads → execute directly (no lock needed).
		if _registry.needs_serialization(entry.method):
			_execute_scene_queued_mutation(entry, queued_ms)
		else:
			_execute_scene_queued_read(entry, queued_ms)
		return  # One at a time; next drain triggered on completion.
	# Scene queue fully drained — nothing left.


func _execute_scene_queued_mutation(entry: _SceneQueueEntry,
		queued_ms: int) -> void:
	# Route through mutation lock — the scene lease is already acquired.
	if _mutation_in_flight:
		# Re-queue into mutation queue (lease held; executes when lock frees).
		var m_entry := _MutationQueueEntry.new()
		m_entry.peer = entry.peer
		m_entry.id = entry.id
		m_entry.method = entry.method
		m_entry.params = entry.params
		m_entry.scene_queued_ms = queued_ms
		_mutation_queue.append(m_entry)
		_send_notification(entry.peer, "_queued", {"request_id": entry.id})
	else:
		_execute_mutation(entry.peer, entry.id, entry.method, entry.params,
			queued_ms)


func _execute_scene_queued_read(entry: _SceneQueueEntry,
		queued_ms: int) -> void:
	var ctx: MCPToolkitToolContext = null
	if _registry.is_cancellable(entry.method):
		ctx = MCPToolkitToolContext.new()
		_active_contexts[str(entry.id)] = ctx
	command_received.emit(entry.method)
	var result: Dictionary = await _registry.call_command(
		entry.method, entry.params, ctx)
	_active_contexts.erase(str(entry.id))
	if queued_ms > 0:
		_inject_concurrency_metadata(result, queued_ms)
	_send_result(entry.peer, entry.id, result)
	# Check for more entries from the same peer/scene.
	_drain_scene_queue()


func _post_mutation_scene_cleanup(peer: WebSocketPeer, method: String,
		params: Dictionary, result: Dictionary) -> void:
	if method != "scene.close":
		return
	if not result.get("success", false):
		return
	var file_path := str(params.get("file_path", ""))
	if _peer_scene_affinity.get(peer, "") == file_path:
		_peer_scene_affinity.erase(peer)
	if _lease_holder == peer and _lease_scene == file_path:
		_release_lease()


func _inject_concurrency_metadata(result: Dictionary, queued_ms: int) -> void:
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


func _send_notification(peer: WebSocketPeer, method: String,
		params: Dictionary) -> void:
	if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	peer.send_text(JSON.stringify({
		"jsonrpc": JSONRPC_VERSION,
		"method": method,
		"params": params,
	}))


func _send_result(peer: WebSocketPeer, id, result) -> void:
	var response := {
		"jsonrpc": JSONRPC_VERSION,
		"id": id,
		"result": result,
	}
	peer.send_text(JSON.stringify(response))


func _send_error(peer: WebSocketPeer, id, code: int, error_message: String) -> void:
	var response := {
		"jsonrpc": JSONRPC_VERSION,
		"id": id,
		"error": {
			"code": code,
			"message": error_message,
		},
	}
	peer.send_text(JSON.stringify(response))


# -- Unfocused sleep management -----------------------------------------------
# When the editor loses focus, Godot's unfocused_low_processor_mode_sleep_usec
# (default ~100ms) throttles _process to ~10fps. Since we poll WebSocket in
# _process, this slows MCP interactions to ~2-3Hz. While authenticated clients
# are connected, we lower the sleep to keep ~60fps even unfocused.

const _UNFOCUSED_SLEEP_KEY := "interface/editor/unfocused_low_processor_mode_sleep_usec"


func _lower_unfocused_sleep() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	_original_unfocused_sleep_usec = int(es.get_setting(_UNFOCUSED_SLEEP_KEY))
	es.set_setting(_UNFOCUSED_SLEEP_KEY, _ACTIVE_UNFOCUSED_SLEEP_USEC)


func _restore_unfocused_sleep() -> void:
	if _original_unfocused_sleep_usec < 0:
		return
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	es.set_setting(_UNFOCUSED_SLEEP_KEY, _original_unfocused_sleep_usec)
	_original_unfocused_sleep_usec = -1
