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

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const MCPAuth := preload("res://addons/godot_mcp_toolkit/security/auth.gd")
const UndoRedoHelpers := preload("res://addons/godot_mcp_toolkit/scene/undo_redo_helpers.gd")
const Notifier := preload("res://addons/godot_mcp_toolkit/transport/notifier.gd")
const WsTransport := preload("res://addons/godot_mcp_toolkit/transport/ws_transport.gd")
const MutationWatchdog := preload("res://addons/godot_mcp_toolkit/transport/dispatch/mutation_watchdog.gd")
const SceneLease := preload("res://addons/godot_mcp_toolkit/scene/scene_lease.gd")
const RpcDispatcher := preload("res://addons/godot_mcp_toolkit/transport/dispatch/rpc_dispatcher.gd")
const DispatchLane := preload("res://addons/godot_mcp_toolkit/transport/dispatch/dispatch_lane.gd")
const UnfocusedSleepController := preload("res://addons/godot_mcp_toolkit/core/unfocused_sleep_controller.gd")
const LspPublisher := preload("res://addons/godot_mcp_toolkit/paths/lsp_publisher.gd")

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
# fights this deferral + the always-run _mutation_watchdog.tick() for a tiny gain.
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
# C7: routes a parsed JSON-RPC request to the lane its registry policy selects (read /
# mutation / scene-lease) and drives it. Owns the in-flight cancellable-context map + the
# three lanes; this file keeps only the lifecycle wiring + the cross-subsystem seams the
# lanes need injected (the scene-lease handlers, the watchdog, command_received). Built in
# start(); _handle_message hands it each authed frame. See rpc_dispatcher.gd / dispatch_lane.gd.
var _dispatcher: RpcDispatcher = null
# C9: the LSP endpoint publisher (resolve THIS editor's GDScript-LSP endpoint,
# publish it to the registry, re-publish on a debounced settings change) + the
# server-reported LSP liveness mirror live in lsp_publisher.gd. This file keeps only
# the cross-subsystem TRIGGER points (start() → connect the watch; stop() → disconnect
# it; server reports a verdict → set_reported_lsp_status), the public LSP getters the
# dock + commands reach (delegated to this child), and the lsp_status_changed SIGNAL
# (re-emitted here when the child reports a change — the dock binds it on the server).
# Constructed in start() with the bound-port source + the status-changed re-emit
# injected. See lsp_publisher.gd / docs/adr/0008-lsp-port-registry-authoritative.md.
var _lsp: LspPublisher = null
# C8: the unfocused-responsive mechanism (lower/restore/self-heal the machine-wide
# unfocused-sleep EditorSetting + its first-writer-wins backup) lives in
# unfocused_sleep_controller.gd. This file keeps only the cross-subsystem TRIGGER
# points (first authed connect → lower; last disconnect → restore; start() →
# self-heal first) and the public getters the dock reads, delegating each to this
# child. Constructed in start() with the EditorSettings accessor injected. See
# unfocused_sleep_controller.gd / docs/adr/0007-unfocused-responsive-mode.md.
var _unfocused: UnfocusedSleepController = null
## Set by plugin.gd so domain commands can call EditorPlugin API
## (e.g. add_autoload_singleton for immediate editor cache refresh).
var editor_plugin: EditorPlugin = null

## Node holding UndoRedo helper methods that domain commands reference by
## string name. Populated in start(); command closures access it via
## server.undo_helpers.
var undo_helpers: Node = null

# -- Mutation serialisation ---------------------------------------------------
# When multiple WebSocket peers are connected, mutation commands must not
# interleave at await boundaries. A single-flight flag + FIFO queue ensures
# that at most one mutation executes at any time. Read-only commands bypass
# the lock entirely. See iter 41l-decies for the full design.
#
# C7: the single-flight flag + FIFO queue + the mutation execute/drain now live in
# dispatch_lane.gd's MutationLane (constructed by the dispatcher). This file keeps only
# the watchdog INSTANCE (it must tick every _process frame, independent of lane state —
# C5/R4) and hands it to the dispatcher to wire into the mutation lane's recovery hook.

# C5 mutation watchdog — recovers the lock if an in-flight mutation's coroutine
# aborts or never resolves (it would otherwise wedge ALL mutations permanently).
# It owns the in-flight identity + the adaptive deadline + the generation counter.
# Constructed in start() and handed to the dispatcher, which wires its force_clear hook
# into the mutation lane; armed at execution-start by that lane, ticked every _process
# frame HERE (it must run regardless of lane state). See mutation_watchdog.gd.
var _mutation_watchdog: MutationWatchdog = null

# -- Scene lease ---------------------------------------------------------------
# When multiple peers target different scenes, a time-bounded lease prevents
# cross-scene contamination. Tab-dependent commands queue until the peer's
# affinity scene matches the active tab. See iter 41l-decies-bis for design.
#
# C6: the lease mechanism (state + acquire/renew/release/steal/drain + the
# scene-affinity queue + scene.open contention) lives in scene_lease.gd. C7: the dispatch
# ROUTING into it now lives in the scene-lease lane (dispatch_lane.gd), reached through
# the dispatcher. Constructed in start() with the editor's root-resolver + the lane seams
# injected; the scene-lease lane routes via _scene_lease.try_queue_for_lease /
# handle_scene_open, and _process ticks _scene_lease.check_expiry. See scene_lease.gd.
var _scene_lease: SceneLease = null


func set_registry(registry: MCPToolkitCommandRegistry) -> void:
	_registry = registry
	# Push to the children if they already exist (set_registry normally runs before
	# start() builds them, in which case _init_scene_lease / _init_dispatcher seed it).
	if _scene_lease != null:
		_scene_lease.set_registry(registry)
	if _dispatcher != null:
		_dispatcher.set_registry(registry)


## Release the command registry and all its Callable references.
## Called during plugin teardown to break reference chains before node deletion.
func clear_registry() -> void:
	if _registry != null:
		_registry.clear()
		_registry = null
	# Break the children's registry + seam Callable chains too (they hold the registry
	# and seams bound back to this server).
	if _scene_lease != null:
		_scene_lease.clear_registry()
	if _dispatcher != null:
		_dispatcher.clear()


func get_plugin_boot_time() -> int:
	return _plugin_boot_time


func is_listening() -> bool:
	return _transport != null and _transport.is_listening()


func get_authed_peer_count() -> int:
	return _transport.get_authed_count() if _transport != null else 0


func get_bound_port() -> int:
	return _transport.get_bound_port() if _transport != null else -1


## The GDScript LSP endpoint THIS editor's setting points at (default
## 127.0.0.1:6005). Thin static delegate to lsp_publisher.gd (C9) — kept here because
## plugin.gd + the registry callers call MCPServer.resolve_lsp_endpoint() statically;
## the resolved host/port are passed into register()/ensure_registered() so
## registry_client.gd stays editor-clean for the Mode-B runtime autoload.
static func resolve_lsp_endpoint() -> Dictionary:
	return LspPublisher.resolve_lsp_endpoint()


## The MCP server reports the authoritative LSP verdict here (editor.set_lsp_status);
## delegates to the LSP publisher, which stores it and re-emits lsp_status_changed via
## the injected handler so the dock refreshes. The signal stays on this object (the
## dock binds it here). See lsp_publisher.gd / ADR 0008.
func set_reported_lsp_status(status: Dictionary) -> void:
	if _lsp != null:
		_lsp.set_reported_lsp_status(status)


func get_reported_lsp_status() -> Dictionary:
	return _lsp.get_reported_lsp_status() if _lsp != null else {}


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
	# Build the child first (self_heal is its method); no peer can be authed yet.
	_init_unfocused_sleep()
	_unfocused.self_heal(get_authed_peer_count())
	if undo_helpers == null:
		undo_helpers = UndoRedoHelpers.new()
		undo_helpers.name = "UndoRedoHelpers"
		add_child(undo_helpers)
	_plugin_boot_time = int(Time.get_unix_time_from_system())
	_init_transport()
	_init_mutation_watchdog()
	# Build scene_lease + dispatcher, then cross-wire. The two have a mutual seam
	# dependency (the scene-lease lane routes into the lease child; the lease child's
	# queued paths re-enter the read/mutation lanes), so both are CONSTRUCTED first, then
	# wired: _init_dispatcher binds the lanes to the (now-existing) lease methods, and
	# _init_scene_lease binds the lease seams to the (now-existing) lane methods.
	_init_scene_lease()
	_init_dispatcher()
	_wire_scene_lease_to_lanes()
	_init_lsp_publisher()
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


# Build the mutation watchdog. Its force_clear recovery hook is wired by the mutation
# lane (in the dispatcher) — the lane owns the single-flight flag the hook clears, so the
# hook belongs with the lane (C7). This file only constructs the watchdog and ticks() it
# every _process frame (it must run regardless of lane state — C5/R4).
func _init_mutation_watchdog() -> void:
	_mutation_watchdog = MutationWatchdog.new()


# Build the unfocused-sleep controller, injecting the EditorSettings accessor (the
# child's ONLY editor reach — behind a Callable so it stays the testability seam, and
# the EditorInterface name stays in this editor file, mirroring scene_lease's
# root-resolver). The orchestrator keeps the trigger points (boost on first authed,
# restore on last disconnect, self-heal at start); the child owns the mechanism.
func _init_unfocused_sleep() -> void:
	_unfocused = UnfocusedSleepController.new()
	_unfocused.set_settings_accessor(func() -> EditorSettings:
		return EditorInterface.get_editor_settings())


# Construct the scene-lease coordinator and seed the registry. Its seams are wired in
# _wire_scene_lease_to_lanes (after the dispatcher's lanes exist — they have a mutual
# dependency). set_registry usually ran before start() built this, so seed the registry.
func _init_scene_lease() -> void:
	_scene_lease = SceneLease.new()
	_scene_lease.set_registry(_registry)


# Build the dispatcher + its three lanes, injecting the cross-subsystem seams the lanes
# need (each behind a Callable so the dispatcher + lanes stay editor-clean): the
# command_received re-emit, the mutation watchdog, and the scene-lease lane's seams bound
# to the (already-constructed) lease child — handle_scene_open / try_queue_for_lease /
# cancel_queued for routing, and inject_concurrency_metadata / post_mutation_cleanup /
# drain for the mutation lane's completion path. set_registry usually ran before start(),
# so seed the dispatcher's registry too.
func _init_dispatcher() -> void:
	_dispatcher = RpcDispatcher.new()
	_dispatcher.set_registry(_registry)
	_dispatcher.build_lanes(
		func(method: String) -> void: command_received.emit(method),
		_mutation_watchdog,
		_scene_lease.inject_concurrency_metadata,
		_scene_lease.post_mutation_cleanup,
		_scene_lease.drain,
		_scene_lease.handle_scene_open,
		_scene_lease.try_queue_for_lease,
		_scene_lease.cancel_queued,
	)


# Inject the lane methods into the scene-lease child (the second half of the mutual
# wiring): the editor's root-resolver (the ONLY EditorInterface reach — behind a Callable
# so it is the testability seam), the command_received re-emit, the read lane's
# result-returning core (the queued-read path injects concurrency metadata before
# sending, so it needs the result, not a send), and the mutation lane's busy-enqueue +
# execute entry. Runs after _init_dispatcher built the lanes.
func _wire_scene_lease_to_lanes() -> void:
	var mutation_lane = _dispatcher.mutation_lane()
	_scene_lease.set_handlers(
		func() -> Node: return EditorInterface.get_edited_scene_root(),
		func(method: String) -> void: command_received.emit(method),
		_dispatcher.read_lane().run_returning,
		mutation_lane.enqueue_if_busy,
		mutation_lane.execute,
	)


# Build the LSP publisher and inject the two seams it needs from this orchestrator: the
# bound-WS-port source (the transport owns the port; the watch reads it to skip
# re-publishing before the server is listening) and the lsp_status_changed re-emit (the
# signal stays on this object because the dock binds it here). resolve_lsp_endpoint is
# static on the child — it names EditorInterface directly, which is fine for this
# editor-only file (never runtime-preloaded). Constructed in start() before the watch
# is connected.
func _init_lsp_publisher() -> void:
	_lsp = LspPublisher.new()
	_lsp.set_bound_port_provider(func() -> int:
		return _transport.get_bound_port() if _transport != null else -1)
	_lsp.set_status_changed_handler(func() -> void: lsp_status_changed.emit())


func stop() -> void:
	set_process(false)
	_disconnect_lsp_settings_watch()
	if _transport != null:
		_transport.close_all(1000, "")
	if _unfocused != null:
		_unfocused.restore()
	if _transport != null:
		_transport.shutdown_listener()
	print("[MCPServer] stopped")


# LSP settings-watch trigger points (the mechanism lives in lsp_publisher.gd, C9).
# start() connects the watch (resolve baseline + listen on EditorSettings.settings_changed
# for a mid-session GDScript LSP port/host change → debounced registry re-publish);
# stop() disconnects it (I12 symmetry). Thin null-guarded delegates so the lifecycle
# sequencing stays here while the child owns the watch + debounce + re-publish.
func _connect_lsp_settings_watch() -> void:
	if _lsp != null:
		_lsp.connect_settings_watch()


func _disconnect_lsp_settings_watch() -> void:
	if _lsp != null:
		_lsp.disconnect_settings_watch()


# -- Frame loop ----------------------------------------------------------------


func _process(_delta: float) -> void:
	# C5: the mutation watchdog must always run, independent of the poll cadence
	# and lease state — it is the sole recovery for a wedged mutation lock. (The
	# null guard mirrors _poll_connections: start() builds it synchronously in
	# _enter_tree before any _process, but a stray pre-start tick stays a no-op.)
	if _mutation_watchdog != null:
		_mutation_watchdog.tick()
	Modules.LogBuffer.poll()
	_poll_frame_counter += 1
	if _poll_frame_counter < _POLL_FRAME_INTERVAL:
		return
	_poll_frame_counter = 0
	if _scene_lease != null:
		_scene_lease.check_expiry()
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
			_unfocused.restore()
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

	await _dispatcher.route_request(peer, message)


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
		_unfocused.lower()
	client_connected.emit(count)


# Fired by the transport once per closed peer (the transport has already erased
# its peer maps). Does the editor-only PER-PEER cleanup: drop the scene affinity,
# release the lease if this peer held it, drop the peer's queued scene commands.
# The aggregate client_disconnected emit + unfocused restore happen ONCE per tick
# in _poll_connections, keyed off pump()'s return — not here. was_authed is unused
# here (the aggregate uses the transport's batch result).
func _on_peer_closed(peer: WebSocketPeer, _was_authed: bool) -> void:
	_scene_lease.on_peer_closed(peer)


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


# Dispatch routing (_dispatch_rpc), the mutation lane (_execute_mutation /
# _drain_mutation_queue), and the read/scene-lease routes moved to rpc_dispatcher.gd +
# dispatch_lane.gd in concern 007 C7. _handle_message now hands each authed frame to
# _dispatcher.route_request. The framing helper below stays — the orchestrator itself
# sends the pre-dispatch parse errors (-32700 / -32600) in _handle_message.


func _send_error(peer: WebSocketPeer, id, code: int, error_message: String) -> void:
	Notifier.send_error(peer, id, code, error_message)


# -- Unfocused sleep management -----------------------------------------------
# The lower/restore/self-heal mechanism + the first-writer-wins backup moved to
# unfocused_sleep_controller.gd in concern 007 C8. This file keeps the public
# getters the dock reads and delegates each to _unfocused; the cross-subsystem
# trigger points (boost on first authed connect, restore on last disconnect,
# self-heal at start) live in _on_peer_authed / _poll_connections / start(). The
# null guards keep the dock's pre-start indicator refresh honest (the child is
# built in start()), preserving the pre-extraction defaults.


## True when the user has opted in (default true). Missing/unavailable settings
## fall back to the default so behaviour is unchanged from before this iter.
func is_unfocused_responsive_enabled() -> bool:
	return _unfocused.is_unfocused_responsive_enabled() if _unfocused != null else true


## fps implied by the configured boosted value, for the dock indicator + log.
func get_unfocused_responsive_fps() -> int:
	return _unfocused.get_unfocused_responsive_fps() if _unfocused != null else 60


## True while THIS instance holds the boost active (best-effort; the backup file
## is authoritative for restore). Used by the dock's 3-state indicator.
func is_unfocused_boost_active() -> bool:
	return _unfocused.is_unfocused_boost_active() if _unfocused != null else false


## Called by the dock when the user flips the opt-in toggle, so the boost is
## applied/restored immediately rather than only on the next connect/disconnect.
func notify_unfocused_responsive_setting_changed() -> void:
	if _unfocused != null:
		_unfocused.notify_unfocused_responsive_setting_changed(get_authed_peer_count())
