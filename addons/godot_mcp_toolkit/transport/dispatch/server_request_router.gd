@tool
extends RefCounted
## Routes a parsed JSON-RPC request to the dispatch lane its per-command policy selects
## and drives that lane to a response. Keeps the dispatcher-level concerns — id/method
## /params parsing, the _cancel and echo notifications, and the registry-miss (-32601)
## reply — then selects ONE of three lanes (read-only / mutation / scene-lease) from the
## command's registry flags and calls lane.drive(...). The lanes (dispatch_lane.gd) own
## the per-class concurrency discipline; this file owns only the routing.
##
## The wire contract is frozen: the notification methods _queued / _executing /
## _cancel / echo, the JSON-RPC error codes, and the envelope keys are the contract
## the TS bridge speaks — do not rename or reshape them here.
##
## EDITOR-CLEAN by design: names zero Editor* symbols and preloads only the shared-clean
## Notifier + the (clean) dispatch lanes. Everything editor-only (the scene-tab switch,
## the lease) is reached by the lanes through injected Callables, never named here. Mode B
## has no dispatcher and never preloads this; staying clean preserves the option and keeps
## the routing headless-testable.

const Notifier := preload("res://addons/godot_mcp_toolkit/transport/notifier.gd")
const DispatchLane := preload("res://addons/godot_mcp_toolkit/transport/dispatch/dispatch_lane.gd")

# Command dispatch table — has_command + the flags that pick a lane.
var _registry: MCPToolkitCommandRegistry = null
# In-flight cancellable-request contexts keyed by DispatchLane.context_key(peer, id)
# (peer-scoped — ids are only unique per client). OWNED here and shared (by
# reference) with the lanes + the mutation watchdog so _cancel can cancel an in-flight
# request while the lanes populate/erase their own entries. See dispatch_lane.gd.
var _active_contexts: Dictionary = {}

# The three lanes, constructed + wired in build_lanes(). A request is routed to exactly
# one of them per its registry flags. Untyped (concrete types are DispatchLane's inner
# classes ReadOnlyLane / MutationLane / SceneLeaseLane): GDScript resolves them via the
# DispatchLane const at .new() time, but an inner-class-of-preload TYPE annotation has no
# precedent in this codebase, so they stay untyped to keep the parse unambiguous.
var _read_lane = null  # DispatchLane.ReadOnlyLane
var _mutation_lane = null  # DispatchLane.MutationLane
var _scene_lease_lane = null  # DispatchLane.SceneLeaseLane

# Cancel a queued (not-yet-executing) scene-queue command. Injected (the scene queue
# lives in the editor-tainted lease child): func(peer, target_id: String) -> bool —
# peer-scoped like the other two cancel scans (ids are only unique per client).
var _cancel_scene_queued: Callable = Callable()


func set_registry(registry: MCPToolkitCommandRegistry) -> void:
	_registry = registry


## Construct and wire the three lanes. The caller (mcp_server) supplies the registry, the
## command_received re-emit, the watchdog, and the scene-lease seams (each behind a
## Callable so this file + the lanes stay editor-clean). Call once at start(), after
## set_registry. Lanes hold the shared _active_contexts by reference.
func build_lanes(on_command: Callable, watchdog,
		inject_concurrency_metadata: Callable, post_mutation_cleanup: Callable,
		drain_scene_queue: Callable, handle_scene_open: Callable,
		try_queue_for_lease: Callable, cancel_scene_queued: Callable) -> void:
	_cancel_scene_queued = cancel_scene_queued

	_read_lane = DispatchLane.ReadOnlyLane.new()
	_read_lane.configure(_registry, _active_contexts, on_command)

	_mutation_lane = DispatchLane.MutationLane.new()
	_mutation_lane.configure(_registry, _active_contexts, on_command)
	_mutation_lane.set_handlers(watchdog, inject_concurrency_metadata,
		post_mutation_cleanup, drain_scene_queue)

	_scene_lease_lane = DispatchLane.SceneLeaseLane.new()
	_scene_lease_lane.configure(_registry, _active_contexts, on_command)
	_scene_lease_lane.set_handlers(handle_scene_open, try_queue_for_lease,
		_read_lane, _mutation_lane)


## The mutation lane (DispatchLane.MutationLane) — the server injects its enqueue_if_busy
## + execute entry points into the scene-lease child (a scene-queued mutation re-enters
## the mutation lane). Untyped return for the inner-class-of-preload reason above.
func mutation_lane():
	return _mutation_lane


## The read lane (DispatchLane.ReadOnlyLane) — the server injects its read core into the
## scene-lease child (the queued-read path runs the same context-tracked read as a direct
## read-only command). Untyped return for the inner-class-of-preload reason above.
func read_lane():
	return _read_lane


## Release the lanes' registry + Callable references during plugin teardown, breaking the
## reference chains before the server node is freed.
func clear() -> void:
	_registry = null
	_cancel_scene_queued = Callable()
	if _read_lane != null:
		_read_lane.clear()
	if _mutation_lane != null:
		_mutation_lane.clear()
	if _scene_lease_lane != null:
		_scene_lease_lane.clear()


## Parse a raw JSON-RPC request, handle the dispatcher-level cases (_cancel, echo,
## missing method, registry miss), then route the rest to the lane its registry flags
## select. The transport awaits this so dispatch stays sequential within a poll tick.
func route_request(peer: WebSocketPeer, message: Dictionary) -> void:
	var id = message.get("id", null)
	# Godot's JSON parser returns every number as float; coerce whole-float ids back to
	# int so {"id": 1} round-trips as {"id": 1}, not {"id": 1.0}.
	if typeof(id) == TYPE_FLOAT and int(id) == id:
		id = int(id)
	var method := str(message.get("method", ""))
	var parameters = message.get("params", null)

	if method.is_empty():
		Notifier.send_error(peer, id, -32600, "Invalid Request: missing method")
		return

	# _cancel is a fire-and-forget notification from the bridge — no response. Triggers
	# cooperative cancellation on the MCPToolkitToolContext for the target request. Scans
	# both the mutation and scene queues for queued (not-yet-executing) commands and flags
	# them for skip-on-drain. Scoped to the REQUESTING peer — ids are only unique per
	# client, so a global id match could cancel another peer's request.
	if method == "_cancel":
		_handle_cancel(peer, parameters)
		return

	# echo is a transport-level diagnostic, not a domain command.
	if method == "echo":
		Notifier.send_result(peer, id, parameters, "[MCPServer]")
		return

	if _registry == null or not _registry.has_command(method):
		Notifier.send_error(peer, id, -32601, "Method not found: %s" % method)
		return

	var safe_parameters: Dictionary = parameters \
		if typeof(parameters) == TYPE_DICTIONARY else {}

	await _select_lane(method).drive(peer, id, method, safe_parameters)


# Lane-kind discriminators (the data→route mapping's vocabulary). Returned by
# lane_kind_for; mapped to the constructed lane instance by _select_lane.
const LANE_READ := "read"
const LANE_MUTATION := "mutation"
const LANE_SCENE_LEASE := "scene_lease"


## The lane KIND `method` routes to, from its registry flags alone — the pure data→route
## mapping that is this abstraction's core invariant (unit-tested directly, no live lanes):
##   - scene.open and active-scene-required commands → scene_lease (the lane queues on
##     contention, else falls through to the mutation/read lane internally — exactly what
##     the old handle_scene_open / try_queue_for_lease block did);
##   - other mutations → mutation; everything else → read.
## A non-scene-required command skips the lease lane, which is equivalent to the old
## try_queue_for_lease returning false immediately (no lease renewal) before the same
## mutation/read decision. Mirrors the pre-extraction sequential routing in _dispatch_rpc.
func lane_kind_for(method: String) -> String:
	if method == "scene.open" or _registry.is_active_scene_required(method):
		return LANE_SCENE_LEASE
	if _registry.needs_serialization(method):
		return LANE_MUTATION
	return LANE_READ


# Map the lane kind for `method` to its constructed lane instance.
func _select_lane(method: String):
	var kind := lane_kind_for(method)
	if kind == LANE_SCENE_LEASE:
		return _scene_lease_lane
	if kind == LANE_MUTATION:
		return _mutation_lane
	return _read_lane


# _cancel routing: in-flight → cancel via the tracked context; else flag a queued entry
# in the mutation queue, then the scene queue. Fire-and-forget — no response either way.
# The in-flight lookup and the mutation-queue scan are scoped to the requesting peer
# (the context map keys on context_key(peer, id) — ids are only unique per client).
func _handle_cancel(peer: WebSocketPeer, parameters) -> void:
	var safe_params: Dictionary = parameters \
		if typeof(parameters) == TYPE_DICTIONARY else {}
	var target_id := str(safe_params.get("request_id", ""))
	# In-flight: cancel via context (this peer's registration of that id only).
	var target_key := DispatchLane.context_key(peer, target_id)
	if _active_contexts.has(target_key):
		_active_contexts[target_key].cancel()
		return
	# Queued in the mutation queue (peer-scoped match):
	if _mutation_lane.cancel_queued(peer, target_id):
		return
	# Queued in the scene queue (lease child owns it; peer-scoped match):
	_cancel_scene_queued.call(peer, target_id)
