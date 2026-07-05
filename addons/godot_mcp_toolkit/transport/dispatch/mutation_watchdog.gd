@tool
extends RefCounted
## Recovers the mutation dispatch lock when an in-flight mutation's coroutine
## aborts or never resolves — the sole safety net that keeps one wedged mutation
## from blocking ALL mutations permanently. It owns the in-flight identity
## (peer/id/method/ctx), the adaptive deadline, and the generation counter that
## lets a wedged coroutine's tail bail when it eventually resumes; the mutation
## lane (dispatch_lane.gd) owns the single-flight flag + FIFO queue. The two talk
## through this tiny surface: arm() at execution-start, disarm() on normal
## completion, tick() every frame, current_generation() for the lane's tail guard,
## and an injected force_clear Callable the trip invokes to recover the lane lock.
##
## Why split from the lane: the watchdog is the one piece that must tick EVERY
## _process frame unconditionally, independent of poll cadence and lane state — a
## different lifecycle cadence than the lane's queue/in-flight bookkeeping.
## Splitting it gives a clean, headless-unit-testable timer+generation child.
##
## Editor-side only (the runtime autoload has no mutation lane → it never preloads
## this), so #91713 does not apply here — but it is kept a CLEAN pure-logic child
## anyway for SRP: it names zero Editor* symbols. The ONLY reach back into the
## editor server is the injected force_clear Callable; everything else is core
## (WebSocketPeer/Time/Callable) plus the shared-clean Notifier and the
## MCPToolkitToolContext value type. The deadline VALUE is computed by the lane
## (it owns the registry + the grace ProjectSetting) and passed into arm(); this
## child only stores it and decides when it has tripped.

const Notifier := preload("res://addons/godot_mcp_toolkit/transport/notifier.gd")

# Injected recovery hook: func(trapped_peer, trapped_id) -> void. Invoked LAST on a
# trip, after this child has bumped the generation and cleared its own identity, to
# recover the lane: erase the trapped request's active context (the peer-scoped key
# needs both halves of the identity), clear the single-flight flag, and drain the
# mutation queue. Draining re-arms a successor synchronously, so it MUST run after
# this child has nulled its own identity (else the drain's fresh arm() would be
# clobbered).
var _force_clear: Callable = Callable()

# True while a mutation is in flight (mirrors the lane's _mutation_in_flight exactly:
# set in arm(), cleared in disarm() and on a trip). Tracked here so tick() is
# self-contained and never reaches into the lane to read the flag.
var _armed := false
# In-flight identity + adaptive deadline, stamped by arm() synchronously before the
# mutation's first await (so the deadline tracks only in-flight time, never the
# queued wait, and can't race).
var _started_ms := 0
var _deadline_ms := 0
var _peer: WebSocketPeer = null
var _id  # int or null — the in-flight mutation's JSON-RPC id
var _method := ""
# The cancellable command's context, tracked so a trip can cooperatively cancel a
# slow-but-alive handler (one that polls ctx.is_cancelled()).
var _ctx: MCPToolkitToolContext = null
# Bumped on every trip so a force-cleared coroutine, if it ever resumes, sees a
# generation mismatch via current_generation() and abandons its whole tail.
var _generation := 0


## Wire the recovery hook the trip invokes to recover the lane lock. Call once at
## construction (from the mutation lane), before the first arm().
func set_force_clear(force_clear: Callable) -> void:
	_force_clear = force_clear


## Stamp a mutation as in-flight: record its identity + the pre-computed deadline,
## and return the current generation so the lane can capture it for its tail guard.
## Called synchronously at execution-start, before the mutation's first await. The
## lane passes the deadline it computed (started + the command's watchdog timeout +
## grace) — this child does not know the registry or the grace setting.
func arm(peer: WebSocketPeer, id, method: String, started_ms: int,
		deadline_ms: int, ctx: MCPToolkitToolContext) -> int:
	_armed = true
	_peer = peer
	_id = id
	_method = method
	_started_ms = started_ms
	_deadline_ms = deadline_ms
	_ctx = ctx
	return _generation


## Clear the in-flight identity on normal completion. Does NOT bump the generation
## (no abandonment happened) and does NOT touch the lane's single-flight flag (the
## lane owns that). Mirrors the lane clearing _mutation_in_flight = false at the
## same point.
func disarm() -> void:
	_armed = false
	_peer = null
	_ctx = null


## The current generation counter — the lane captures this at arm() and re-reads it
## after its handler await to detect a mid-await force-clear (generation mismatch →
## abandon the tail).
func current_generation() -> int:
	return _generation


## Recover the mutation lock if the in-flight mutation has blown its deadline. Runs
## EVERY _process frame, unconditionally — it is the only recovery for a wedged
## lock, so it must never be gated behind the poll cadence or lease state. The
## deadline is adaptive + stamped at execution-start, so a legitimately slow (even
## maxed-out extension) mutation never trips it; only an aborted/never-resolving one
## does. A fire means the C1 save-reentrancy guard failed to prevent the wedge, so
## it warns loudly.
func tick() -> void:
	if not _armed:
		return
	if Time.get_ticks_msec() <= _deadline_ms:
		return
	push_warning(("[MCPToolkit] mutation watchdog: '%s' (id %s) exceeded its "
		+ "deadline (%d ms in flight) - force-clearing the dispatch lock. If this "
		+ "recurs, the save-reentrancy guard (C1) is not holding.") % [
			_method, str(_id), Time.get_ticks_msec() - _started_ms])
	if _peer != null and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		Notifier.send_error(_peer, _id, -32000,
			"mutation watchdog timeout — the editor did not complete the operation in time")
	# Cooperatively cancel the in-flight handler (if cancellable + still alive): one
	# that polls ctx.is_cancelled() bails at its next check, shrinking the window
	# where a slow-but-alive mutation runs concurrently with its watchdog-started
	# successor. A hung handler ignores this (harmless).
	if _ctx != null:
		_ctx.cancel()
	# Bump generation FIRST so the wedged coroutine, if it ever resumes, skips its
	# whole tail (the lane's generation guard in _execute_mutation).
	_generation += 1
	# Capture the identity BEFORE nulling it — force_clear needs peer + id to erase
	# the trapped request's peer-scoped active context.
	var trapped_peer := _peer
	var trapped_id = _id
	# Null our OWN identity before force_clear: force_clear drains the queue, which
	# re-arms a successor synchronously; clearing here first means that fresh arm()
	# is never clobbered.
	_armed = false
	_peer = null
	_ctx = null
	# Recover the lane LAST (erase active context + clear single-flight flag + drain).
	if _force_clear.is_valid():
		_force_clear.call(trapped_peer, trapped_id)
