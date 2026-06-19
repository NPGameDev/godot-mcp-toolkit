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
## Emitted when the MCP server reports a new GDScript LSP verdict
## (set_reported_lsp_status) so the dock refreshes exactly on change — no polling,
## no stale label even if the status is re-assessed later (e.g. on an LSP call).
signal lsp_status_changed
## Emitted after the session token is re-written to a new user:// path following a
## user-path change, carrying that new token path. The plugin (registry lifecycle
## owner) re-publishes the entry via ensure_registered, which preserves any active
## runtime_port/runtime_pid — register would null them and break Mode-B discovery
## for a game running across the rename.
signal token_rewritten(token_path: String)

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const RegistryClient = _Hub.RegistryClient
const MCPAuth := preload("res://addons/godot_mcp_toolkit/auth.gd")
const UndoRedoHelpers := preload("res://addons/godot_mcp_toolkit/undo_redo_helpers.gd")
const _UnfocusedBackup := preload("res://addons/godot_mcp_toolkit/unfocused_backup.gd")
const Notifier := preload("res://addons/godot_mcp_toolkit/notifier.gd")
const WsTransport := preload("res://addons/godot_mcp_toolkit/ws_transport.gd")

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
# Cold/hot sleep mode (set_process(false) with no client) was assessed in iter 41m
# and rejected: no TCPServer accept signal exists to wake on, and gating the loop
# fights this deferral + the always-run _check_mutation_watchdog() for a tiny gain.
const _POLL_FRAME_INTERVAL := 4
# Auth timeout. Peers that don't send a valid auth message within this
# window are closed with WS close code 1008 (Policy Violation).
const _AUTH_TIMEOUT_MS := 2000

# Owns the TCP listener + WS peers + auth-handshake framing + the bound port +
# the session token. This file injects the editor-side decisions/side-effects as
# Callables (auth-ack payload, boost-on-authed, lease cleanup on close) and drives
# it via _poll_connections → transport.pump().
var _transport: WsTransport = null
var _poll_frame_counter := 0
# Captured at start() so editor.get_console's log-file selection heuristic
# can prefer post-boot logs over stale rotated ones.
var _plugin_boot_time: int = 0
var _registry: MCPToolkitCommandRegistry = null
## Tracks MCPToolkitToolContext per in-flight cancellable request, keyed by
## JSON-RPC id (string). Populated in _dispatch_rpc; erased after handler
## returns. Looked up by _cancel notifications to trigger cooperative cancel.
var _active_contexts: Dictionary = {}
# Last LSP endpoint published to the registry — the Q4 re-publish baseline.
var _last_lsp_host: String = ""
var _last_lsp_port: int = -1
# Authoritative LSP verdict the MCP server last reported (editor.set_lsp_status).
# The editor can't read its own LSP bind status, so the server tells us and the
# dock renders it. {} until a server connects. See ADR 0008.
var _reported_lsp_status: Dictionary = {}
# Best-effort in-memory mirror: >= 0 while THIS instance is holding the boost
# active, -1 otherwise. The machine-wide backup FILE is the source of truth for
# restore (this only gates whether the disconnect/stop path runs). See the
# "Unfocused sleep management" section below.
var _original_unfocused_sleep_usec: int = -1
## Set by plugin.gd so domain commands can call EditorPlugin API
## (e.g. add_autoload_singleton for immediate editor cache refresh).
var editor_plugin: EditorPlugin = null
# Default for the tunable EditorSetting unfocused_responsive_sleep_usec.
const _ACTIVE_UNFOCUSED_SLEEP_USEC := 16666  # ~= 60 fps while a client is connected

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
# C3 mutation watchdog — recover the lock if an in-flight mutation's coroutine
# aborts or never resolves (it would otherwise wedge ALL mutations permanently).
# The deadline is adaptive (the in-flight command's own timeout + grace) and
# stamped at execution-start, so a slow extension mutation never false-trips it.
var _mutation_started_ms := 0
var _mutation_deadline_ms := 0
var _mutation_peer: WebSocketPeer = null
var _mutation_id  # int or null — the in-flight mutation's JSON-RPC id
var _mutation_method := ""
var _mutation_ctx: MCPToolkitToolContext = null  # cancellable cmd's ctx, for watchdog cooperative-cancel
var _mutation_generation := 0

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
	return _transport != null and _transport.is_listening()


func get_authed_peer_count() -> int:
	return _transport.get_authed_count() if _transport != null else 0


func get_bound_port() -> int:
	return _transport.get_bound_port() if _transport != null else -1


## The GDScript LSP endpoint THIS editor's setting points at (default
## 127.0.0.1:6005). A --lsp-port override is invisible here — the engine consumes
## it before OS.get_cmdline_args() and never writes it to the setting — so that
## case rides GODOT_MCP_LSP_PORT on the server (see docs/multi-instance.md).
## Static + editor-only (names EditorInterface); the registry callers pass the
## result into register()/ensure_registered() so registry_client.gd stays
## editor-clean for the Mode-B runtime autoload.
static func resolve_lsp_endpoint() -> Dictionary:
	var host := "127.0.0.1"
	var port := 6005
	var es := EditorInterface.get_editor_settings()
	if es != null:
		if es.has_setting("network/language_server/remote_host"):
			host = str(es.get_setting("network/language_server/remote_host"))
		if es.has_setting("network/language_server/remote_port"):
			port = int(es.get_setting("network/language_server/remote_port"))
	return {"host": host, "port": port}


## The MCP server reports the authoritative LSP verdict here — it can do reliable
## cross-process liveness (process.kill) and the real connection/root-verify,
## which the editor cannot (no engine API for its own LSP bind status). The dock
## renders whatever was last reported. Keys: state ("active"/"conflict"/
## "unavailable"), host, port, detail. Empty until an MCP server connects.
func set_reported_lsp_status(status: Dictionary) -> void:
	_reported_lsp_status = status.duplicate()
	lsp_status_changed.emit()


func get_reported_lsp_status() -> Dictionary:
	return _reported_lsp_status


func get_command_methods() -> Array:
	if _registry == null:
		return []
	return _registry.get_all_methods()


## Send a notification to all authenticated WebSocket peers.
## Used by the dock to signal config changes (e.g. profile updates)
## so the MCP server can reload its tool list without a restart.
func broadcast_notification(notification_type: String, params: Dictionary = {}) -> void:
	var authed: Array = _transport.get_authed_peers() if _transport != null else []
	var count := Notifier.broadcast(authed, notification_type, params, "[MCPServer]")
	print("[MCPServer] broadcasting %s to %d authed peer%s" % [
		notification_type, count, "" if count == 1 else "s"])


func bind_user_path_monitor(monitor: RefCounted) -> void:
	monitor.user_path_changed.connect(_on_user_path_changed)


func _on_user_path_changed() -> void:
	_rewrite_token_after_rename()


## Re-write the current in-memory token to the new user:// path after a
## config/name change. Does NOT generate a new token — existing connections
## stay authenticated. Announces the new token path so the registry owner
## (plugin.gd) re-publishes the entry runtime-preservingly.
func _rewrite_token_after_rename() -> void:
	if _transport == null:
		return  # No running transport → no token to re-write, nothing bound.
	var write_err := MCPAuth.write_token(_transport.get_token())
	if write_err != OK:
		push_warning("[MCPServer] failed to re-write token after rename (err %d)" % write_err)
	else:
		print("[MCPServer] token re-written to %s" % MCPAuth.get_token_path())
	# Announce the new token path; the plugin re-publishes via ensure_registered so
	# an active game's runtime_port/runtime_pid survive the rename (register nulls
	# them). The server doesn't reach into the registry from the rename path.
	if _transport.get_bound_port() > 0:
		token_rewritten.emit(MCPAuth.get_token_path())


func regenerate_token() -> void:
	var token := MCPAuth.generate_token()
	if _transport != null:
		_transport.set_token(token)
	var write_err := MCPAuth.write_token(token)
	if write_err != OK:
		push_warning("[MCPServer] failed to write rotated token (err %d)" % write_err)
	else:
		print("[MCPServer] token rotated, written to %s" % MCPAuth.get_token_path())
	# Close all existing peers — they must re-auth with the new token.
	if _transport != null:
		_transport.close_all(1008, "token rotated")


func start() -> void:
	# Self-heal a leftover boost (from a crash or a concurrent instance) before
	# listening, so the global key can never persist without a live connection.
	_self_heal_unfocused_sleep()
	if undo_helpers == null:
		undo_helpers = UndoRedoHelpers.new()
		undo_helpers.name = "UndoRedoHelpers"
		add_child(undo_helpers)
	_plugin_boot_time = int(Time.get_unix_time_from_system())
	_init_transport()
	var token := MCPAuth.generate_token()
	_transport.set_token(token)
	var write_err := MCPAuth.write_token(token)
	if write_err != OK:
		push_warning("[MCPServer] failed to write token (err %d); auth will still be enforced but bridge may not find the file" % write_err)
	else:
		var token_path := MCPAuth.get_token_path()
		print("[MCPServer] session token written to %s" % token_path)
	_transport.ensure_listening()
	_connect_lsp_settings_watch()


# Build the WS transport and inject the editor-side seams: the auth-vs-dispatch
# router, the auth-ack payload (Mode A adds godot_version + version), the
# boost-on-first-authed callback, and the lease/unfocused/signal cleanup on close.
func _init_transport() -> void:
	_transport = WsTransport.new()
	# await_messages = true: the editor dispatches sequentially within a poll tick
	# (its mutation serialisation depends on this).
	_transport.configure("[MCPServer]", PORT_BASE, PORT_RANGE, BIND,
		_RELISTEN_FRAME_INTERVAL, _AUTH_TIMEOUT_MS, true,
		"no free port in %d-%d; will retry every ~1s")
	_transport.set_handlers(_handle_message, _build_auth_ack, _on_peer_authed,
		_on_peer_closed)


func stop() -> void:
	set_process(false)
	_disconnect_lsp_settings_watch()
	if _transport != null:
		_transport.close_all(1000, "")
	_restore_unfocused_sleep()
	if _transport != null:
		_transport.shutdown_listener()
	print("[MCPServer] stopped")


## Q4 — re-publish the registry entry when the editor's GDScript LSP port/host
## setting changes mid-session, so the published endpoint never goes stale.
## EditorSettings.settings_changed fires globally; we debounce by comparing the
## re-resolved endpoint against the last published one. Connected in start(),
## disconnected in stop() (I12 symmetry).
func _connect_lsp_settings_watch() -> void:
	var lsp := resolve_lsp_endpoint()
	_last_lsp_host = lsp["host"]
	_last_lsp_port = lsp["port"]
	var es := EditorInterface.get_editor_settings()
	if es != null and es.has_signal("settings_changed") \
			and not es.settings_changed.is_connected(_on_editor_settings_changed):
		es.settings_changed.connect(_on_editor_settings_changed)


func _disconnect_lsp_settings_watch() -> void:
	var es := EditorInterface.get_editor_settings()
	if es != null and es.has_signal("settings_changed") \
			and es.settings_changed.is_connected(_on_editor_settings_changed):
		es.settings_changed.disconnect(_on_editor_settings_changed)


func _on_editor_settings_changed() -> void:
	var bound_port := _transport.get_bound_port() if _transport != null else -1
	if bound_port <= 0:
		return
	var lsp := resolve_lsp_endpoint()
	if lsp["host"] == _last_lsp_host and lsp["port"] == _last_lsp_port:
		return  # LSP endpoint unchanged — ignore unrelated editor-setting churn.
	_last_lsp_host = lsp["host"]
	_last_lsp_port = lsp["port"]
	RegistryClient.ensure_registered(bound_port, MCPAuth.get_token_path(), lsp["host"], lsp["port"])
	print("[MCPServer] LSP endpoint changed → re-published %s:%d" % [lsp["host"], lsp["port"]])


# -- Frame loop ----------------------------------------------------------------


func _process(_delta: float) -> void:
	# C3: the mutation watchdog must always run, independent of the poll cadence
	# and lease state — it is the sole recovery for a wedged mutation lock.
	_check_mutation_watchdog()
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
	# Defensive: _process can only fire after start() built the transport (both run
	# in plugin _enter_tree, synchronously), but guard anyway so a stray pre-start
	# tick is a no-op rather than a null deref (the pre-extraction loop tolerated a
	# null listener the same way).
	if _transport == null:
		return
	# C1: skip this re-entrant tick while a save's Main::iteration() re-entry is
	# in flight — no command may dispatch mid-save.
	if MCPToolkitSafeSceneOps.is_dispatching():
		return
	# pump() returns whether an authed peer closed this pass. Aggregate the
	# disconnect ONCE per tick with the FINAL authed count (the pre-extraction
	# shape), using a local so reentrant deferred polls during a mutation await
	# can't clobber each other.
	var had_authed_disconnect: bool = await _transport.pump()
	if had_authed_disconnect:
		var authed_now := _transport.get_authed_count()
		if authed_now == 0:
			_restore_unfocused_sleep()
		client_disconnected.emit(authed_now)


# -- Message handling ----------------------------------------------------------


# The transport delivers each raw frame here. We parse, then route: unauthenticated
# peers go through the transport's auth handshake (we additionally run the
# human-only version-mismatch check); authenticated peers go to dispatch. The
# transport awaits this, so dispatch stays sequential within a poll tick.
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

	if not _transport.is_authed(peer):
		if _transport.validate_auth(peer, message):
			# Version mismatch check — human-only (editor console), nothing on the
			# MCP wire. Runs only after a successful auth, like the pre-extraction
			# handshake. A pre-handshake server sends no version → skip.
			var server_ver: String = str(message.get("version", ""))
			if not server_ver.is_empty():
				_check_version_mismatch(_get_plugin_version(), server_ver)
		return

	await _dispatch_rpc(peer, message)


# Supplies the Mode-A auth-ack payload to the transport: the bare {authed:true}
# plus this editor's Godot + plugin versions (the runtime sends {authed:true}
# only). Pure — no side effects; the boost/signal happen in _on_peer_authed.
func _build_auth_ack(_message: Dictionary) -> Dictionary:
	var vi := Engine.get_version_info()
	return {
		"authed": true,
		"godot_version": "%d.%d.%d" % [vi["major"], vi["minor"], vi["patch"]],
		"version": _get_plugin_version(),
	}


# Fired by the transport after a peer authenticates. On the FIRST authed peer,
# boost the unfocused responsiveness; always re-emit client_connected for the dock.
func _on_peer_authed(count: int) -> void:
	if count == 1:
		_lower_unfocused_sleep()
	client_connected.emit(count)


# Fired by the transport once per closed peer (the transport has already erased
# its peer maps). Does the editor-only PER-PEER cleanup: drop the scene affinity,
# release the lease if this peer held it, drop the peer's queued scene commands.
# The aggregate client_disconnected emit + unfocused restore happen ONCE per tick
# in _poll_connections, keyed off pump()'s return — not here. was_authed is unused
# here (the aggregate uses the transport's batch result).
func _on_peer_closed(peer: WebSocketPeer, _was_authed: bool) -> void:
	_peer_scene_affinity.erase(peer)
	if _lease_holder == peer:
		_release_lease()  # Immediate release → drain queue.
	# Remove queued scene commands for this peer.
	_scene_queue = _scene_queue.filter(func(entry: _SceneQueueEntry):
		return entry.peer != peer)


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
	# C3: stamp the watchdog deadline synchronously with the flag, BEFORE any
	# await — so it tracks only in-flight time (never the queued wait) and can't
	# race. Deadline = this command's own timeout + grace.
	_mutation_in_flight = true
	_mutation_started_ms = Time.get_ticks_msec()
	var grace_ms: int = ProjectSettings.get_setting(
		"mcp_toolkit/concurrency/mutation_watchdog_grace_ms", 60000)
	# Deadline basis: the command's DECLARED timeout if it set one (trust the
	# author's contract — built-ins + careful extensions get tight, appropriate
	# recovery), else _MAX_TIMEOUT_MS for undeclared methods (the 30 s default
	# isn't a deliberate duration statement, so don't force-clear them early).
	# Grace is added either way; the deadline is stamped at execution-start.
	_mutation_deadline_ms = _mutation_started_ms + _registry.get_watchdog_timeout_ms(method) + grace_ms
	_mutation_peer = peer
	_mutation_id = id
	_mutation_method = method
	var my_generation := _mutation_generation
	_send_notification(peer, "_executing", {"request_id": id})
	var ctx: MCPToolkitToolContext = null
	if _registry.is_cancellable(method):
		ctx = MCPToolkitToolContext.new()
		_active_contexts[str(id)] = ctx
	_mutation_ctx = ctx  # tracked so the watchdog can cooperatively cancel a slow-but-alive handler
	command_received.emit(method)
	var result: Dictionary = await _registry.call_command(method, params, ctx)
	_active_contexts.erase(str(id))
	# C3 generation guard: if the watchdog force-cleared us mid-await (generation
	# bumped), a successor mutation now owns the lock. Abandon the ENTIRE tail —
	# the watchdog already responded; touching the flag/queue would corrupt the
	# successor.
	if _mutation_generation != my_generation:
		return
	if scene_queued_ms > 0:
		_inject_concurrency_metadata(result, scene_queued_ms)
	_send_result(peer, id, result)
	_post_mutation_scene_cleanup(peer, method, params, result)
	_mutation_in_flight = false
	_mutation_peer = null
	_mutation_ctx = null
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


# C3: sole recovery for a wedged mutation lock. Runs every _process frame,
# unconditionally. The deadline is adaptive + stamped at execution-start, so a
# legitimately slow (even maxed-out extension) mutation never trips it; only an
# aborted/never-resolving one does. SAFETY NET — a fire means the C1 re-entrancy
# guard failed to prevent the wedge, so it warns loudly.
func _check_mutation_watchdog() -> void:
	if not _mutation_in_flight:
		return
	if Time.get_ticks_msec() <= _mutation_deadline_ms:
		return
	push_warning(("[MCPToolkit] mutation watchdog: '%s' (id %s) exceeded its "
		+ "deadline (%d ms in flight) — force-clearing the dispatch lock. If this "
		+ "recurs, the save-reentrancy guard (C1) is not holding.") % [
			_mutation_method, str(_mutation_id),
			Time.get_ticks_msec() - _mutation_started_ms])
	if _mutation_peer != null and _mutation_peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send_error(_mutation_peer, _mutation_id, -32000,
			"mutation watchdog timeout — the editor did not complete the operation in time")
	# Cooperatively cancel the in-flight handler (if cancellable + still alive): one
	# that polls ctx.is_cancelled() bails at its next check, shrinking the window
	# where a slow-but-alive mutation runs concurrently with its watchdog-started
	# successor. A hung handler ignores this (harmless).
	if _mutation_ctx != null:
		_mutation_ctx.cancel()
	_active_contexts.erase(str(_mutation_id))
	# Bump generation FIRST so the wedged coroutine, if it ever resumes, skips its
	# whole tail (generation guard in _execute_mutation).
	_mutation_generation += 1
	_mutation_in_flight = false
	_mutation_peer = null
	_mutation_ctx = null
	_drain_mutation_queue()


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
		# Fix 4: lease acquisition is now pure bookkeeping — the raw
		# open_scene_from_path was removed (it violated the #75669 deferred-open
		# rule and was unguarded against scans). Tab activation moves to the
		# guarded _execute_scene_queued_* paths via _switch_to_affinity_scene.
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
	# C1: don't steal/drain during a save's re-entry (a lease-steal would drain a
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


# Fix 4: switch the editor to the peer's affinity scene before executing a
# scene-queued command (the raw open was removed from _try_acquire_lease).
# Guarded against an active EditorFileSystem scan. Returns false — and sends the
# peer a TIMEOUT — if it can't switch, so the caller aborts this one entry (the
# rest of the queue stays for the next drain trigger).
func _switch_to_affinity_scene(peer: WebSocketPeer, id) -> bool:
	var scene := str(_peer_scene_affinity.get(peer, ""))
	if scene.is_empty() or _get_active_scene_path() == scene:
		return true
	if await _Hub.Helpers.open_scene_deferred(scene):
		return true
	_send_result(peer, id, MCPToolkitError.fail("TIMEOUT",
		"could not switch to %s — EditorFileSystem still scanning" % scene))
	return false


func _execute_scene_queued_mutation(entry: _SceneQueueEntry,
		queued_ms: int) -> void:
	# Re-queue (no tab switch) BEFORE activating the tab, to avoid an unnecessary
	# switch when the mutation lock is busy.
	if _mutation_in_flight:
		var m_entry := _MutationQueueEntry.new()
		m_entry.peer = entry.peer
		m_entry.id = entry.id
		m_entry.method = entry.method
		m_entry.params = entry.params
		m_entry.scene_queued_ms = queued_ms
		_mutation_queue.append(m_entry)
		_send_notification(entry.peer, "_queued", {"request_id": entry.id})
		return
	# Fix 4: activate the peer's affinity scene here, guarded against a scan.
	if not await _switch_to_affinity_scene(entry.peer, entry.id):
		return
	_execute_mutation(entry.peer, entry.id, entry.method, entry.params, queued_ms)


func _execute_scene_queued_read(entry: _SceneQueueEntry,
		queued_ms: int) -> void:
	# Fix 4: activate the peer's affinity scene (guarded) before the read.
	if not await _switch_to_affinity_scene(entry.peer, entry.id):
		return
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
	Notifier.send_notification(peer, method, params, "[MCPServer]")


func _send_result(peer: WebSocketPeer, id, result) -> void:
	Notifier.send_result(peer, id, result, "[MCPServer]")


func _send_error(peer: WebSocketPeer, id, code: int, error_message: String) -> void:
	Notifier.send_error(peer, id, code, error_message)


# -- Unfocused sleep management -----------------------------------------------
# When the editor loses focus, Godot's unfocused_low_processor_mode_sleep_usec
# (default ~100000 µs ≈ 10 fps) throttles _process. Since we poll WebSocket in
# _process, that slows MCP interactions to ~2-3 Hz — and the editor is normally
# UNFOCUSED during an MCP session (the user is on the chat), so this is the
# common case, not an edge. While an authenticated client is connected AND the
# user has opted in, we lower the sleep to keep the editor responsive unfocused,
# then restore it on the last disconnect / stop.
#
# The key is a machine-wide EditorSetting (every project on this editor version),
# and set_setting only reaches disk on a later save() — so a crash (after a flush)
# or a concurrent second editor could strand it at the boosted value and, worse,
# re-read that as the "original" on the next launch, losing the true default. We
# guard against that with a machine-wide, version-keyed, first-writer-wins backup
# of the TRUE original (in the registry dir, under the registry lock) plus a
# conflict-aware restore and a startup self-heal. Opt-in + tunable rate live in
# EditorSettings (registered in plugin.gd::_register_editor_settings). See iter
# 41l-duotricies / docs/adr/0007-unfocused-responsive-mode.md /
# Insights/unfocused-throttle-analysis.md.

const _UNFOCUSED_SLEEP_KEY := "interface/editor/unfocused_low_processor_mode_sleep_usec"
const _RESPONSIVE_ENABLED_KEY := "mcp_toolkit/performance/keep_editor_responsive_unfocused"
const _RESPONSIVE_SLEEP_KEY := "mcp_toolkit/performance/unfocused_responsive_sleep_usec"


## True when the user has opted in (default true). Missing/unavailable settings
## fall back to the default so behaviour is unchanged from before this iter.
func is_unfocused_responsive_enabled() -> bool:
	var es := EditorInterface.get_editor_settings()
	if es == null or not es.has_setting(_RESPONSIVE_ENABLED_KEY):
		return true
	return bool(es.get_setting(_RESPONSIVE_ENABLED_KEY))


## Configured boosted sleep value in µs (default 16666 = 60 fps; not clamped).
func _configured_responsive_usec() -> int:
	var es := EditorInterface.get_editor_settings()
	if es == null or not es.has_setting(_RESPONSIVE_SLEEP_KEY):
		return _ACTIVE_UNFOCUSED_SLEEP_USEC
	return int(es.get_setting(_RESPONSIVE_SLEEP_KEY))


## fps implied by the configured boosted value, for the dock indicator + log.
func get_unfocused_responsive_fps() -> int:
	var usec := _configured_responsive_usec()
	if usec <= 0:
		return 0
	return int(round(1_000_000.0 / float(usec)))


## True while THIS instance holds the boost active (best-effort; the backup file
## is authoritative for restore). Used by the dock's 3-state indicator.
func is_unfocused_boost_active() -> bool:
	return _original_unfocused_sleep_usec >= 0


## Called by the dock when the user flips the opt-in toggle, so the boost is
## applied/restored immediately rather than only on the next connect/disconnect.
func notify_unfocused_responsive_setting_changed() -> void:
	if is_unfocused_responsive_enabled():
		if get_authed_peer_count() > 0:
			_lower_unfocused_sleep()
	else:
		_restore_unfocused_sleep()


func _lower_unfocused_sleep() -> void:
	if not _UnfocusedBackup.should_capture_boost(
			is_unfocused_responsive_enabled(), is_unfocused_boost_active()):
		return
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	var live := int(es.get_setting(_UNFOCUSED_SLEEP_KEY))
	var boosted := _configured_responsive_usec()
	# Machine-wide first-writer-wins backup of the TRUE original, under the
	# registry lock so a concurrent instance can't capture an already-boosted
	# value as the original.
	var dir := RegistryClient.registry_dir()
	var ver := _UnfocusedBackup.version_key()
	RegistryClient.acquire_lock()
	_UnfocusedBackup.capture_if_absent(dir, live, boosted, ver)
	RegistryClient.release_lock()
	es.set_setting(_UNFOCUSED_SLEEP_KEY, boosted)
	_original_unfocused_sleep_usec = live
	print("[MCPServer] unfocused-responsive mode ON: %s %d → %d (~%d fps while unfocused)" % [
		_UNFOCUSED_SLEEP_KEY, live, boosted, get_unfocused_responsive_fps()])


func _restore_unfocused_sleep() -> void:
	if not is_unfocused_boost_active():
		return
	var es := EditorInterface.get_editor_settings()
	if es == null:
		_original_unfocused_sleep_usec = -1
		return
	var dir := RegistryClient.registry_dir()
	var ver := _UnfocusedBackup.version_key()
	RegistryClient.acquire_lock()
	var backup := _UnfocusedBackup.read_backup(dir, ver)
	var current := int(es.get_setting(_UNFOCUSED_SLEEP_KEY))
	var decision := _UnfocusedBackup.resolve_restore(current, backup)
	if decision["restore"]:
		es.set_setting(_UNFOCUSED_SLEEP_KEY, int(decision["value"]))
	_UnfocusedBackup.delete_backup(dir, ver)
	RegistryClient.release_lock()
	_original_unfocused_sleep_usec = -1
	if decision["restore"]:
		print("[MCPServer] unfocused-responsive mode OFF: %s restored to %d" % [
			_UNFOCUSED_SLEEP_KEY, int(decision["value"])])
	else:
		print("[MCPServer] unfocused-responsive mode OFF: %s left at %d (changed during boost; backup cleared)" % [
			_UNFOCUSED_SLEEP_KEY, current])


## Startup self-heal: if a previous session (crash) or a concurrent instance left
## a backup behind, revert the global key conflict-aware and clear the backup so
## the boost can never persist without a live connection. Runs regardless of the
## opt-in setting (a leftover from when it was ON must be cleaned even after the
## user turns it OFF). Safe at start(): no peer can be authed yet.
func _self_heal_unfocused_sleep() -> void:
	var dir := RegistryClient.registry_dir()
	var ver := _UnfocusedBackup.version_key()
	if not _UnfocusedBackup.has_backup(dir, ver):
		return
	if _transport != null and _transport.get_authed_count() > 0:
		return  # defensive — never true at start() (transport not built yet / no authed peer)
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	RegistryClient.acquire_lock()
	var backup := _UnfocusedBackup.read_backup(dir, ver)
	var current := int(es.get_setting(_UNFOCUSED_SLEEP_KEY))
	var decision := _UnfocusedBackup.resolve_restore(current, backup)
	if decision["restore"]:
		es.set_setting(_UNFOCUSED_SLEEP_KEY, int(decision["value"]))
	_UnfocusedBackup.delete_backup(dir, ver)
	RegistryClient.release_lock()
	if decision["restore"]:
		print("[MCPServer] unfocused-responsive self-heal: reverted leftover %s to %d (crash/concurrent leftover)" % [
			_UNFOCUSED_SLEEP_KEY, int(decision["value"])])
	else:
		print("[MCPServer] unfocused-responsive self-heal: %s changed since boost (now %d); kept it, cleared stale backup" % [
			_UNFOCUSED_SLEEP_KEY, current])
