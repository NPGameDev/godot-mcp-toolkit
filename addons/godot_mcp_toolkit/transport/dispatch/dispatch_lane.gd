@tool
extends RefCounted
## The three dispatch lanes a parsed JSON-RPC request can take. server_request_router.gd
## selects ONE lane per request from the command's registry flags and calls
## lane.drive(...); each lane owns the concurrency discipline for its class of command:
##   - ReadOnlyLane    — execute immediately, no lock (read-only commands).
##   - MutationLane     — single-flight + FIFO queue + the mutation watchdog, so two
##                        mutations never interleave at an await boundary.
##   - SceneLeaseLane   — route through the scene lease (queue until the peer's
##                        affinity scene is the active tab), then hand to MutationLane.
##
## Why three lane objects sharing a base (_LaneBase) rather than one flag-branching
## driver: the lanes have genuinely different state and behaviour — ReadOnlyLane is
## stateless, MutationLane owns the in-flight flag + FIFO queue + watchdog, SceneLeaseLane
## only delegates — so a single driver would drag the mutation-queue fields through the
## read path (low cohesion) and grow an if/elif chain a fourth lane would have to edit
## (OCP). Polymorphic drive() keeps each lane's state local and lets the dispatcher add a
## lane without touching its routing.
##
## EDITOR-CLEAN by design: this file names zero Editor* symbols and preloads only the
## shared-clean Notifier. Every editor-only step — the edited-scene-tab switch before a
## scene-affinity command, the lease bookkeeping — is reached ONLY through injected
## Callables (SceneLeaseLane's _handle_scene_open / _try_queue_for_lease, which the editor
## binds to the scene_lease child that in turn reaches open_scene_deferred; the lane calls
## them blindly). Naming the lease child or EditorInterface here directly would re-taint
## the file (#91713). Mode B has no lanes and never preloads this; staying clean preserves
## the option and keeps the lanes headless-unit-testable.

const Notifier := preload("res://addons/godot_mcp_toolkit/transport/notifier.gd")


## The peer-scoped key an in-flight request is tracked under in the shared
## active-contexts map — public re-export of [code]_LaneBase.context_key[/code]
## for the dispatcher's _cancel lookup (an inner class can't be named cross-file;
## the lanes reach the same implementation by inheritance, so the shape has one home).
static func context_key(peer: WebSocketPeer, id) -> String:
	return _LaneBase.context_key(peer, id)


# -- Shared lane base ----------------------------------------------------------
# Holds the collaborators every lane needs and the read-execute core two lanes share.
# Not instantiated directly — ReadOnlyLane / MutationLane / SceneLeaseLane extend it.
class _LaneBase:
	extends RefCounted

	## The peer-scoped key an in-flight request is tracked under in the shared
	## active-contexts map. JSON-RPC ids are per-client counters, so two peers can
	## legitimately carry the same id concurrently — a bare str(id) key would let one
	## peer's registration overwrite (or its cancel target) the other's. Scoping by
	## the peer instance id makes the key unique per (peer, request). Every lane
	## inherits this; the dispatcher reaches it via the script-level re-export.
	static func context_key(peer: WebSocketPeer, id) -> String:
		return "%d:%s" % [peer.get_instance_id(), str(id)]

	# Command dispatch table — call_command + the per-command flags.
	var _registry: MCPToolkitCommandRegistry = null
	# In-flight cancellable-request contexts keyed by context_key(peer, id) — peer-scoped
	# because JSON-RPC ids are only unique per client. OWNED by the dispatcher and shared
	# (Dictionary is a reference type) so the dispatcher's _cancel handler, both execute
	# paths, and the mutation watchdog's recovery hook all see one map. A lane
	# populates/erases only its own request's entry; it never reads another's.
	var _active_contexts: Dictionary = {}
	# Re-emit the server's command_received signal. func(method: String) -> void.
	var _on_command: Callable = Callable()

	func _wire_base(registry: MCPToolkitCommandRegistry, active_contexts: Dictionary,
			on_command: Callable) -> void:
		_registry = registry
		_active_contexts = active_contexts
		_on_command = on_command

	## Drive a parsed, registry-resolved request to a response on this lane. Overridden
	## per lane. By here the dispatcher has handled parse / _cancel / echo / registry-miss,
	## so the method exists and params is a Dictionary.
	func drive(_peer: WebSocketPeer, _id, _method: String, _params: Dictionary) -> void:
		push_error("[MCPToolkit] _LaneBase.drive() called directly - a lane subclass must override it")

	## Release the registry + active-context references during plugin teardown, breaking
	## the Callable chains (command handlers, the command re-emit) before node free.
	func clear() -> void:
		_registry = null
		_active_contexts = {}
		_on_command = Callable()

	# Read-execute core: create a cancellable context if the command declares one, track
	# it under the peer-scoped request key for the duration of the call, re-emit
	# command_received, and return the handler's result. Shared by ReadOnlyLane.drive and
	# SceneLeaseLane's queued-read path (injected as run_read), so the context bookkeeping
	# lives in one place and _active_contexts stays consistent across both read entry points.
	func _execute_read(peer: WebSocketPeer, method: String, params: Dictionary, id) -> Dictionary:
		var ctx_key := context_key(peer, id)
		var ctx: MCPToolkitToolContext = null
		if _registry.is_cancellable(method):
			ctx = MCPToolkitToolContext.new()
			_active_contexts[ctx_key] = ctx
		_on_command.call(method)
		var result: Dictionary = await _registry.call_command(method, params, ctx)
		_active_contexts.erase(ctx_key)
		return result


# -- ReadOnlyLane --------------------------------------------------------------
# Stateless: read-only commands hold no lock and never queue, so drive() just runs the
# shared read core and sends the result. Maps mcp_server._dispatch_rpc's read-only route.
class ReadOnlyLane:
	extends _LaneBase

	func configure(registry: MCPToolkitCommandRegistry, active_contexts: Dictionary,
			on_command: Callable) -> void:
		_wire_base(registry, active_contexts, on_command)

	func drive(peer: WebSocketPeer, id, method: String, params: Dictionary) -> void:
		var result: Dictionary = await _execute_read(peer, method, params, id)
		Notifier.send_result(peer, id, result, "[MCPServer]")

	## Run the read core and RETURN the result without sending it. The seam the
	## scene-lease lane's queued-read path needs: it injects concurrency metadata into the
	## result before sending, so it can't use drive() (which sends immediately). Same
	## context bookkeeping as drive(), so _active_contexts stays consistent across both.
	func run_returning(peer: WebSocketPeer, method: String, params: Dictionary, id) -> Dictionary:
		return await _execute_read(peer, method, params, id)


# -- MutationLane --------------------------------------------------------------
# Single-flight + FIFO so two mutations never interleave at an await boundary, plus the
# mutation watchdog that recovers the lock if an in-flight coroutine aborts/never
# resolves. Owns the in-flight flag + the FIFO queue; the watchdog (a separate clean
# child) owns the deadline + generation and calls back through the injected force_clear
# hook. Maps mcp_server's mutation route + _execute_mutation + _drain_mutation_queue.
class MutationLane:
	extends _LaneBase

	# One queued mutation request waiting on the single-flight lock.
	class _QueueEntry:
		var peer: WebSocketPeer
		var id  # int or null (JSON-RPC id)
		var method: String
		var params: Dictionary
		var cancelled: bool = false
		var scene_queued_ms: int = 0  # Non-zero when first queued in the scene queue.

	# At most one mutation executes at a time; the rest wait in _queue (FIFO).
	var _in_flight := false
	var _queue: Array = []  # of _QueueEntry

	# The mutation watchdog — recovers the lock if an in-flight coroutine wedges. Injected
	# at construction (set_handlers); armed at execution-start, disarmed on completion.
	var _watchdog = null  # MutationWatchdog (untyped: preloaded by the dispatcher)
	# Post-mutation scene-lease cleanup + the queued-wait concurrency metadata + the
	# scene-queue drain. Injected so the lease child's state stays in the lease child.
	# _inject_concurrency_metadata: func(result: Dictionary, queued_ms: int) -> void
	# _post_mutation_cleanup:        func(peer, method, params, result) -> void
	# _drain_scene_queue:            func() -> void   (called once the mutation queue empties)
	var _inject_concurrency_metadata: Callable = Callable()
	var _post_mutation_cleanup: Callable = Callable()
	var _drain_scene_queue: Callable = Callable()

	func configure(registry: MCPToolkitCommandRegistry, active_contexts: Dictionary,
			on_command: Callable) -> void:
		_wire_base(registry, active_contexts, on_command)

	## Wire the mutation-lane collaborators: the watchdog and the three lease-side seams.
	## Call once at construction, after configure(). The watchdog's force_clear hook is
	## set here too (it recovers THIS lane's lock), so the lane owns that wiring.
	func set_handlers(watchdog, inject_concurrency_metadata: Callable,
			post_mutation_cleanup: Callable, drain_scene_queue: Callable) -> void:
		_watchdog = watchdog
		_watchdog.set_force_clear(_force_clear)
		_inject_concurrency_metadata = inject_concurrency_metadata
		_post_mutation_cleanup = post_mutation_cleanup
		_drain_scene_queue = drain_scene_queue

	func clear() -> void:
		super.clear()
		_watchdog = null
		_inject_concurrency_metadata = Callable()
		_post_mutation_cleanup = Callable()
		_drain_scene_queue = Callable()
		_queue.clear()

	func drive(peer: WebSocketPeer, id, method: String, params: Dictionary) -> void:
		# Single-flight: if a mutation is already running, queue this one and tell the
		# peer; otherwise execute now. _execute sets _in_flight = true synchronously
		# before its first await, so there is no race window between the check and the set.
		if _in_flight:
			_enqueue(peer, id, method, params, 0)
		else:
			await _execute(peer, id, method, params)

	## If a mutation is in flight, append this command to the FIFO + notify the peer it is
	## queued and return true; else return false (the caller proceeds to execute). The
	## scene-lease lane calls this for a scene-queued mutation so the mutation-lane state
	## stays in this lane. queued_ms carries the original scene-queue wait for metadata.
	func enqueue_if_busy(peer: WebSocketPeer, id, method: String, params: Dictionary,
			queued_ms: int) -> bool:
		if not _in_flight:
			return false
		_enqueue(peer, id, method, params, queued_ms)
		return true

	## The mutation-lane entry the scene-lease lane hands a dequeued, tab-activated
	## scene-affinity mutation to (it re-drains the mutation queue on completion).
	func execute(peer: WebSocketPeer, id, method: String, params: Dictionary,
			scene_queued_ms: int) -> void:
		await _execute(peer, id, method, params, scene_queued_ms)

	## Flag a queued (not-yet-executing) mutation for skip-on-drain — the queue-side
	## fallback of cancellation, for targets not found among the in-flight contexts.
	## Matches on the requesting [param peer] AND the id (ids are only unique per
	## client, so an id-only match could cancel another peer's queued mutation).
	## Returns true if a matching entry was found.
	func cancel_queued(peer: WebSocketPeer, target_id: String) -> bool:
		for entry in _queue:
			if entry.peer == peer and str(entry.id) == target_id:
				entry.cancelled = true
				return true
		return false

	func _enqueue(peer: WebSocketPeer, id, method: String, params: Dictionary,
			queued_ms: int) -> void:
		var entry := _QueueEntry.new()
		entry.peer = peer
		entry.id = id
		entry.method = method
		entry.params = params
		entry.scene_queued_ms = queued_ms
		_queue.append(entry)
		Notifier.send_notification(peer, "_queued", {"request_id": id}, "[MCPServer]")

	func _execute(peer: WebSocketPeer, id, method: String, params: Dictionary,
			scene_queued_ms: int = 0) -> void:
		# Take the single-flight lock, then arm the watchdog synchronously BEFORE any
		# await — so its deadline tracks only in-flight time (never the queued wait) and
		# can't race. We compute the deadline here (we own the registry + grace setting)
		# and hand the value to the watchdog; arm() returns the generation we capture for
		# the post-await guard.
		_in_flight = true
		var started_ms := Time.get_ticks_msec()
		var grace_ms: int = ProjectSettings.get_setting(
			"mcp_toolkit/concurrency/mutation_watchdog_grace_ms", 60000)
		# Deadline basis: the command's DECLARED timeout if it set one (trust the author's
		# contract — built-ins + careful extensions get tight, appropriate recovery), else
		# _MAX_TIMEOUT_MS for undeclared methods (the 30 s default isn't a deliberate
		# duration statement, so don't force-clear them early). Grace is added either way;
		# the deadline is stamped at execution-start.
		var deadline_ms := started_ms + _registry.get_watchdog_timeout_ms(method) + grace_ms
		Notifier.send_notification(peer, "_executing", {"request_id": id}, "[MCPServer]")
		var ctx_key := context_key(peer, id)
		var ctx: MCPToolkitToolContext = null
		if _registry.is_cancellable(method):
			ctx = MCPToolkitToolContext.new()
			_active_contexts[ctx_key] = ctx
		# Arm: hands the watchdog the in-flight identity + deadline + ctx (so it can
		# cooperatively cancel a slow-but-alive handler) and returns the generation.
		var my_generation: int = _watchdog.arm(peer, id, method, started_ms, deadline_ms, ctx)
		_on_command.call(method)
		var result: Dictionary = await _registry.call_command(method, params, ctx)
		# Teardown guard: clear() nulls the watchdog and empties the seam Callables while
		# a handler is suspended here (plugin disable / editor exit mid-mutation).
		# Everything is already torn down — abandon the tail instead of null-calling.
		if _watchdog == null:
			return
		# Generation guard: if the watchdog force-cleared us mid-await (generation
		# bumped), a successor mutation now owns the lock. Abandon the ENTIRE tail — the
		# watchdog already responded AND already erased this request's active context
		# (its force_clear hook); erasing here could delete a successor's live ctx if
		# the same peer re-used the id.
		if _watchdog.current_generation() != my_generation:
			return
		_active_contexts.erase(ctx_key)
		if scene_queued_ms > 0:
			_inject_concurrency_metadata.call(result, scene_queued_ms)
		Notifier.send_result(peer, id, result, "[MCPServer]")
		_post_mutation_cleanup.call(peer, method, params, result)
		_in_flight = false
		_watchdog.disarm()
		drain()

	## Execute the next eligible queued mutation (one at a time; the next drain is
	## triggered on completion). Skips cancelled / disconnected / unregistered entries.
	## Once the mutation queue empties, hands off to the scene-queue drain (same-lease
	## entries may now proceed). Called on mutation completion and by the watchdog's
	## force_clear recovery.
	func drain() -> void:
		while not _queue.is_empty():
			var entry: _QueueEntry = _queue.pop_front()
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
			# Found a valid entry — execute it. _execute sets _in_flight = true
			# synchronously before its first await, so there is no race window.
			_execute(entry.peer, entry.id, entry.method, entry.params, entry.scene_queued_ms)
			return  # _execute will call drain() on completion.
		# Mutation queue fully drained — check the scene queue for same-lease entries.
		_drain_scene_queue.call()

	# The watchdog's recovery hook (wired in set_handlers). Runs LAST in a trip, after the
	# watchdog bumped the generation and cleared its own identity, so the drain's
	# synchronous re-arm of a successor is not clobbered: erase the trapped request's
	# active context (peer-scoped key — the watchdog hands back the trapped peer + id),
	# clear the single-flight flag, and drain.
	func _force_clear(trapped_peer: WebSocketPeer, trapped_id) -> void:
		if trapped_peer != null:
			_active_contexts.erase(context_key(trapped_peer, trapped_id))
		_in_flight = false
		drain()


# -- SceneLeaseLane ------------------------------------------------------------
# Tab-dependent commands: route through the scene lease, which queues the request until
# the peer's affinity scene is the active editor tab, then re-dispatches it onto the
# read or mutation lane. This lane is a thin delegator over the (already-extracted)
# scene_lease child, reached through injected Callables so this file names no editor
# symbol. Maps mcp_server's scene-lease route (scene.open + try_queue_for_lease).
class SceneLeaseLane:
	extends _LaneBase

	# Injected scene-lease seams (the lease child is editor-tainted; reaching it directly
	# would taint this file, so it is behind Callables):
	# _handle_scene_open:     func(peer, id, params) -> void (await) — scene.open under
	#   contention (don't switch tabs; return a contention hint).
	# _try_queue_for_lease:   func(peer, id, method, params) -> bool — true if queued (no
	#   response yet), false to proceed to the read/mutation lane now.
	var _handle_scene_open: Callable = Callable()
	var _try_queue_for_lease: Callable = Callable()
	# The lane to fall through to when a tab-dependent command does NOT need to queue
	# (affinity matches the active tab). Set to the mutation or read lane by the
	# dispatcher; SceneLeaseLane never executes a command itself.
	var _read_lane: ReadOnlyLane = null
	var _mutation_lane: MutationLane = null

	func configure(registry: MCPToolkitCommandRegistry, active_contexts: Dictionary,
			on_command: Callable) -> void:
		_wire_base(registry, active_contexts, on_command)

	## Wire the scene-lease seams + the fall-through lanes. Call once at construction.
	func set_handlers(handle_scene_open: Callable, try_queue_for_lease: Callable,
			read_lane: ReadOnlyLane, mutation_lane: MutationLane) -> void:
		_handle_scene_open = handle_scene_open
		_try_queue_for_lease = try_queue_for_lease
		_read_lane = read_lane
		_mutation_lane = mutation_lane

	func clear() -> void:
		super.clear()
		_handle_scene_open = Callable()
		_try_queue_for_lease = Callable()
		_read_lane = null
		_mutation_lane = null

	func drive(peer: WebSocketPeer, id, method: String, params: Dictionary) -> void:
		# scene.open: intercepted because under contention we must NOT open the scene (the
		# tab switch would interfere with the lease holder). The lease child validates +
		# either opens or returns a contention hint.
		if method == "scene.open":
			await _handle_scene_open.call(peer, id, params)
			return
		# Tab-dependent command: queue through the lease when targeting a different scene
		# than the active tab. true → queued (no response yet); false → proceed now.
		if _try_queue_for_lease.call(peer, id, method, params):
			return
		# Affinity matches the active tab (or none) — fall through to the proper lane.
		if _registry.needs_serialization(method):
			await _mutation_lane.drive(peer, id, method, params)
		else:
			await _read_lane.drive(peer, id, method, params)
