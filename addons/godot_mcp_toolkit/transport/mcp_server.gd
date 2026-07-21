@tool
extends Node
## The editor-side MCP server — the transport orchestration facade.
##
## Constructs, wires, and drives the transport subsystems, keeping only the
## lifecycle and the cross-subsystem seams: ws_transport owns the TCP listener +
## WS peer accept/poll + auth-handshake framing, notifier owns notification
## framing/sends, server_request_router + dispatch_lane own request routing and
## lane dispatch, and scene_lease / mutation_watchdog / unfocused_sleep_controller
## / lsp_publisher own their domains. All command logic lives in per-domain
## modules under commands/.

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
## Emitted when the listen state changes — a fresh bind, a listen conflict
## (pinned port occupied / scan band exhausted / lost rebind) raised or cleared,
## or a port-config error. The dock re-reads get_port_warning() + the listening
## state and repaints. Immediate counterpart to the dock's own refresh pull.
signal port_status_changed
## Emitted on a fresh listener bind (initial, or late — e.g. a pinned port that
## frees after a startup conflict), carrying the bound port. The composition root
## (re)publishes the registry entry on it, so the actual bound port lands in
## projects.json in every mode — the ground truth the server's desync cross-check
## reads.
signal port_bound(port: int)

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const MCPAuth := preload("res://addons/godot_mcp_toolkit/security/auth.gd")
const UndoRedoHelpers := preload("res://addons/godot_mcp_toolkit/scene/undo_redo_helpers.gd")
const Notifier := preload("res://addons/godot_mcp_toolkit/transport/notifier.gd")
const WsTransport := preload("res://addons/godot_mcp_toolkit/transport/ws_transport.gd")
const MutationWatchdog := preload("res://addons/godot_mcp_toolkit/transport/dispatch/mutation_watchdog.gd")
const SceneLease := preload("res://addons/godot_mcp_toolkit/scene/scene_lease.gd")
const ServerRequestRouter := preload("res://addons/godot_mcp_toolkit/transport/dispatch/server_request_router.gd")
const DispatchLane := preload("res://addons/godot_mcp_toolkit/transport/dispatch/dispatch_lane.gd")
const UnfocusedSleepController := preload("res://addons/godot_mcp_toolkit/core/unfocused_sleep_controller.gd")
const LspPublisher := preload("res://addons/godot_mcp_toolkit/paths/lsp_publisher.gd")
const PortConfig := preload("res://addons/godot_mcp_toolkit/transport/port_config.gd")

# Default editor scan band (inclusive). GODOT_MCP_EDITOR_PORT pins an exact port
# (bind-exact-or-fail); GODOT_MCP_EDITOR_PORT_MIN/_MAX relocate the band. Resolved
# by PortConfig; the two modes are mutually exclusive (a pin ignores the band).
const PORT_MIN := 6550
const PORT_MAX := 6560  # 6550..6560 inclusive
const _ENV_PIN := "GODOT_MCP_EDITOR_PORT"
const _ENV_PORT_MIN := "GODOT_MCP_EDITOR_PORT_MIN"
const _ENV_PORT_MAX := "GODOT_MCP_EDITOR_PORT_MAX"
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
#      the collision window ~4x.
#   2. Deferred dispatch: _process schedules the poll body via
#      call_deferred instead of running it inline, moving our I/O out
#      of the _process call stack where reentrancy is most dangerous.
# Side-effect: commands run inside the deferred-call context, so Godot
# APIs that use the progress dialog (e.g. save_scene) log benign
# progress_dialog.cpp errors. This is acceptable — the alternative
# (inline _process poll) causes reproducible editor crashes.
# No upstream structural fix exists as of Godot 4.5/4.6-dev.
# Cold/hot sleep mode (set_process(false) with no client) was considered and
# rejected: no TCPServer accept signal exists to wake on, and gating the loop
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
# Resolved listen-port configuration (PortConfig.resolve result). A non-empty
# "error" is fatal — the editor server does not listen and the dock shows why.
var _port_config: Dictionary = {}
# Captured at start() so editor.get_console's log-file selection heuristic
# can prefer post-boot logs over stale rotated ones.
var _plugin_boot_time: int = 0
var _registry: MCPToolkitCommandRegistry = null
# Routes a parsed JSON-RPC request to the lane its registry policy selects (read /
# mutation / scene-lease) and drives it. Owns the in-flight cancellable-context map + the
# three lanes; this file keeps only the lifecycle wiring + the cross-subsystem seams the
# lanes need injected (the scene-lease handlers, the watchdog, command_received). Built in
# start(); _handle_message hands it each authed frame. See server_request_router.gd / dispatch_lane.gd.
var _router: ServerRequestRouter = null
# The LSP endpoint publisher (resolve THIS editor's GDScript-LSP endpoint,
# publish it to the registry, re-publish on a debounced settings change) + the
# server-reported LSP liveness mirror live in lsp_publisher.gd. This file keeps only
# the cross-subsystem TRIGGER points (start() → connect the watch; stop() → disconnect
# it; server reports a verdict → set_reported_lsp_status), the public LSP getters the
# dock + commands reach (delegated to this child), and the lsp_status_changed SIGNAL
# (re-emitted here when the child reports a change — the dock binds it on the server).
# Constructed in start() with the bound-port source + the status-changed re-emit
# injected. See lsp_publisher.gd.
var _lsp: LspPublisher = null
# The unfocused-responsive mechanism (lower/restore/self-heal the machine-wide
# unfocused-sleep EditorSetting + its first-writer-wins backup) lives in
# unfocused_sleep_controller.gd. This file keeps only the cross-subsystem TRIGGER
# points (first authed connect → lower; last disconnect → restore; start() →
# self-heal first) and the public getters the dock reads, delegating each to this
# child. Constructed in start() with the EditorSettings accessor injected. See
# unfocused_sleep_controller.gd.
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
# the lock entirely.
#
# The single-flight flag + FIFO queue + the mutation execute/drain live in
# dispatch_lane.gd's MutationLane (constructed by the dispatcher). This file keeps only
# the watchdog INSTANCE (it must tick every _process frame, independent of lane state)
# and hands it to the dispatcher to wire into the mutation lane's recovery hook.

# Mutation watchdog — recovers the lock if an in-flight mutation's coroutine
# aborts or never resolves (it would otherwise wedge ALL mutations permanently).
# It owns the in-flight identity + the adaptive deadline + the generation counter.
# Constructed in start() and handed to the dispatcher, which wires its force_clear hook
# into the mutation lane; armed at execution-start by that lane, ticked every _process
# frame HERE (it must run regardless of lane state). See mutation_watchdog.gd.
var _mutation_watchdog: MutationWatchdog = null

# -- Scene lease ---------------------------------------------------------------
# When multiple peers target different scenes, a time-bounded lease prevents
# cross-scene contamination. Tab-dependent commands queue until the peer's
# affinity scene matches the active tab.
#
# The lease mechanism (state + acquire/renew/release/steal/drain + the
# scene-affinity queue + scene.open contention) lives in scene_lease.gd; the dispatch
# ROUTING into it lives in the scene-lease lane (dispatch_lane.gd), reached through
# the dispatcher. Constructed in start() with the editor's root-resolver + the lane seams
# injected; the scene-lease lane routes via _scene_lease.try_queue_for_lease /
# handle_scene_open, and _process ticks _scene_lease.check_expiry. See scene_lease.gd.
var _scene_lease: SceneLease = null


func set_registry(registry: MCPToolkitCommandRegistry) -> void:
	_registry = registry
	# Push to the children if they already exist (set_registry normally runs before
	# start() builds them, in which case _init_scene_lease / _init_router seed it).
	if _scene_lease != null:
		_scene_lease.set_registry(registry)
	if _router != null:
		_router.set_registry(registry)


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
	if _router != null:
		_router.clear()


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
## dock binds it here). See lsp_publisher.gd.
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
## Triggers a server-side tool-list reload without a restart
## (e.g. after the tool surface changes, such as a group activation
## or an extension being added).
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
	# wired: _init_router binds the lanes to the (now-existing) lease methods, and
	# _init_scene_lease binds the lease seams to the (now-existing) lane methods.
	_init_scene_lease()
	_init_router()
	_wire_scene_lease_to_lanes()
	_init_lsp_publisher()
	var token := MCPAuth.generate_token()
	# A port-config error leaves _transport null (start() still wires the rest so the
	# dock + LSP watch come up and can surface the error); skip the listen path.
	if _transport != null:
		_transport.set_token(token)
	var write_err := MCPAuth.write_token(token)
	if write_err != OK:
		push_warning("[MCPServer] failed to write token (err %d); auth will still be enforced but bridge may not find the file" % write_err)
	else:
		var token_path := MCPAuth.get_token_path()
		print("[MCPServer] session token written to %s" % token_path)
	if _transport != null:
		_transport.ensure_listening()
	else:
		port_status_changed.emit()
	_connect_lsp_settings_watch()


# Build the WS transport and inject the editor-side seams: the auth-vs-dispatch
# router, the auth-ack payload (Mode A adds godot_version + version), the
# boost-on-first-authed callback, the lease/unfocused/signal cleanup on close, the
# fresh-bind announce (registry re-publish + dock repaint), and the listen
# conflict → dock warning. Resolves the listen-port config first; a config error
# leaves _transport null so start() skips listening (dock shows why).
func _init_transport() -> void:
	_port_config = PortConfig.resolve(_ENV_PIN, _ENV_PORT_MIN, _ENV_PORT_MAX, PORT_MIN, PORT_MAX)
	_log_port_config()
	if not str(_port_config.get("error", "")).is_empty():
		return
	_transport = WsTransport.new()
	var pinned: bool = _port_config["mode"] == PortConfig.MODE_PINNED
	var base: int = int(_port_config["port"]) if pinned else int(_port_config["port_min"])
	var count: int = 1 if pinned else int(_port_config["port_max"]) - int(_port_config["port_min"]) + 1
	# await_messages = true: the editor dispatches sequentially within a poll tick
	# (its mutation serialisation depends on this).
	_transport.configure("[MCPServer]", base, count, BIND,
		_RELISTEN_FRAME_INTERVAL, _AUTH_TIMEOUT_MS, true,
		"no free port in %d-%d; will retry every ~1s", pinned,
		"Free the port, or change %s (or unset it to use the scanned band)." % _ENV_PIN)
	_transport.set_handlers(_handle_message, _build_auth_ack, _on_peer_authed,
		_on_peer_closed, _on_transport_bound, _on_listen_conflict_changed)


# Log the resolved listen-port config at startup: the port + source (so both the
# editor console and the dock can tell WHY this port was chosen — pin, band, or
# default), a one-line note when a pin makes the band moot, or a
# loud push_error on a config error (bad pin / MIN > MAX) — never a silent default.
func _log_port_config() -> void:
	var config_error := str(_port_config.get("error", ""))
	if not config_error.is_empty():
		push_error("[MCPServer] Invalid port config: %s - the editor MCP server did not start. Fix the environment variable and restart the editor (env is read at editor launch; re-enabling the plugin keeps the old value)." % config_error)
		return
	if bool(_port_config.get("band_ignored", false)):
		print("[MCPServer] note: %s pins an exact port, so the %s/%s band is ignored." % [
			_ENV_PIN, _ENV_PORT_MIN, _ENV_PORT_MAX])
	match str(_port_config.get("source", "")):
		"env-pin":
			print("[MCPServer] port %d (pinned via %s)" % [int(_port_config["port"]), _ENV_PIN])
		"env-band":
			print("[MCPServer] port: scanning %d-%d (band via %s/%s)" % [
				int(_port_config["port_min"]), int(_port_config["port_max"]),
				_ENV_PORT_MIN, _ENV_PORT_MAX])
		_:
			print("[MCPServer] port: scanning %d-%d (default)" % [
				int(_port_config["port_min"]), int(_port_config["port_max"])])


# Fresh listener bind (initial or late, both modes). Announce the port so the
# composition root (re)publishes the registry entry — this is what keeps a late
# pinned bind discoverable — and repaint the dock's listen state.
func _on_transport_bound(port: int) -> void:
	port_bound.emit(port)
	port_status_changed.emit()


# Listen-conflict state changed in the transport (unbindable ⇄ bound). Re-emit so
# the dock repaints; the dock also pulls the state on its own refresh, so a missed
# emit (e.g. during start(), before the dock binds) is still caught.
func _on_listen_conflict_changed(_port: int, _active: bool) -> void:
	port_status_changed.emit()


## The resolved listen-port source for the dock status label: "pinned" /
## "band" / "default", or "" when the config failed to resolve.
func get_port_source() -> String:
	match str(_port_config.get("source", "")):
		"env-pin":
			return "pinned"
		"env-band":
			return "band"
		"default":
			return "default"
		_:
			return ""


## The current not-listening warning for the dock: a fatal port-config error, a
## pinned-port conflict, or a scan-band-exhausted conflict. Returns
## { "active": bool, "message": String, "label": String } — message is the full
## warning-panel text, label the concise reason for the status row; active is
## false when the server bound normally.
func get_port_warning() -> Dictionary:
	var config_error := str(_port_config.get("error", ""))
	if not config_error.is_empty():
		return {
			"active": true,
			"message": "Invalid port config: %s — the MCP editor server did not start. Fix the environment variable and restart the editor (env is read at editor launch; re-enabling the plugin keeps the old value)." % config_error,
			"label": "invalid port config",
		}
	if _transport != null and _transport.is_listen_conflict():
		if _port_config.get("mode", "") == PortConfig.MODE_PINNED:
			var pinned_port: int = int(_port_config["port"])
			return {
				"active": true,
				"message": "Pinned port: %d not available — the MCP editor server did not bind. Free the port, or change %s (or unset it to use the scanned band)." % [pinned_port, _ENV_PIN],
				"label": "pinned port %d not available" % pinned_port,
			}
		# A lost listen socket is retried on the SAME port only (get_bound_port()
		# stays set), so range-wide advice would be ineffective — name that port.
		var lost_port: int = _transport.get_bound_port()
		if lost_port > 0:
			return {
				"active": true,
				"message": "Port: %d not available — the MCP editor server lost its listen socket and is retrying that port. Free port %d to recover." % [lost_port, lost_port],
				"label": "port %d not available" % lost_port,
			}
		var low: int = int(_port_config.get("port_min", PORT_MIN))
		var high: int = int(_port_config.get("port_max", PORT_MAX))
		return {
			"active": true,
			"message": "Range of ports: %d-%d not available — the MCP editor server did not bind. Free a port in the range, or move it with %s/%s." % [low, high, _ENV_PORT_MIN, _ENV_PORT_MAX],
			"label": "ports %d-%d not available" % [low, high],
		}
	return {"active": false, "message": "", "label": ""}


# Build the mutation watchdog. Its force_clear recovery hook is wired by the mutation
# lane (in the dispatcher) — the lane owns the single-flight flag the hook clears, so the
# hook belongs with the lane. This file only constructs the watchdog and ticks() it
# every _process frame (it must run regardless of lane state).
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
func _init_router() -> void:
	_router = ServerRequestRouter.new()
	_router.set_registry(_registry)
	_router.build_lanes(
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
# execute entry. Runs after _init_router built the lanes.
func _wire_scene_lease_to_lanes() -> void:
	var mutation_lane = _router.mutation_lane()
	_scene_lease.set_handlers(
		func() -> Node: return EditorInterface.get_edited_scene_root(),
		func(method: String) -> void: command_received.emit(method),
		_router.read_lane().run_returning,
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
	# The mutation watchdog must always run, independent of the poll cadence
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
	# Skip this re-entrant tick while a save's Main::iteration() re-entry is
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
				_check_version_mismatch(Modules.VersionUtils.read_plugin_version(), server_ver)
		return

	await _router.route_request(peer, message)


# Supplies the Mode-A auth-ack payload to the transport: the bare {authed:true} plus
# this editor's Godot + plugin versions and its display mode (the runtime sends
# {authed:true} only). `headless` is the wire signal the server reads to branch its
# headless-degraded tool assertions. Pure — no side effects; the boost/signal happen in
# _on_peer_authed.
func _build_auth_ack(_message: Dictionary) -> Dictionary:
	var vi := Engine.get_version_info()
	return {
		"authed": true,
		"godot_version": "%d.%d.%d" % [vi["major"], vi["minor"], vi["patch"]],
		"version": Modules.VersionUtils.read_plugin_version(),
		"headless": Modules.VersionUtils.is_headless(),
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


func _check_version_mismatch(local: String, remote: String) -> void:
	var local_parts := local.split(".")
	var remote_parts := remote.split(".")
	if local_parts.size() != 3 or remote_parts.size() != 3:
		return  # Non-semver — skip comparison.
	if not local_parts[0].is_valid_int() or not remote_parts[0].is_valid_int():
		return
	if int(local_parts[0]) != int(remote_parts[0]):
		push_error("[MCPServer] Major version mismatch - plugin %s, server %s. Update both to the same major version." % [local, remote])
	elif local != remote:
		push_warning("[MCPServer] Version mismatch - plugin %s, server %s. Consider updating." % [local, remote])


# Dispatch routing, the mutation lane, and the read/scene-lease routes live in
# server_request_router.gd + dispatch_lane.gd; _handle_message hands each authed
# frame to _router.route_request. The framing helper below stays — the orchestrator
# itself sends the pre-dispatch parse errors (-32700 / -32600) in _handle_message.


func _send_error(peer: WebSocketPeer, id, code: int, error_message: String) -> void:
	Notifier.send_error(peer, id, code, error_message)


# -- Unfocused sleep management -----------------------------------------------
# The lower/restore/self-heal mechanism + the first-writer-wins backup live in
# unfocused_sleep_controller.gd. This file keeps the public
# getters the dock reads and delegates each to _unfocused; the cross-subsystem
# trigger points (boost on first authed connect, restore on last disconnect,
# self-heal at start) live in _on_peer_authed / _poll_connections / start(). The
# null guards keep the dock's pre-start indicator refresh honest (the child is
# built in start()), preserving the pre-extraction defaults.


## True when the user has opted in (default true). Missing/unavailable settings
## fall back to the default so the opt-in never blocks on settings availability.
func is_unfocused_responsive_enabled() -> bool:
	return _unfocused.is_unfocused_responsive_enabled() if _unfocused != null else true


## fps implied by the configured boosted value, for the dock indicator + log.
func get_unfocused_responsive_fps() -> int:
	return _unfocused.get_unfocused_responsive_fps() if _unfocused != null else 60


## True while THIS instance holds the boost active — delegated; semantics in
## unfocused_sleep_controller.gd's is_unfocused_boost_active.
func is_unfocused_boost_active() -> bool:
	return _unfocused.is_unfocused_boost_active() if _unfocused != null else false


## Apply or restore the unfocused-responsive boost immediately when the opt-in
## setting changes, rather than waiting for the next connect/disconnect.
func notify_unfocused_responsive_setting_changed() -> void:
	if _unfocused != null:
		_unfocused.notify_unfocused_responsive_setting_changed(get_authed_peer_count())
