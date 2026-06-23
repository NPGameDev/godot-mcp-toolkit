@tool
extends RefCounted
## Transport dispatch internals unit tests: watchdog timeout basis, scene lease
## bookkeeping, mutation watchdog, lane selection, and summarize_batch rollup.
## Exercises the transport/dispatch/ subsystem's pure logic.

const MutationWatchdog := preload("res://addons/godot_mcp_toolkit/transport/dispatch/mutation_watchdog.gd")
const SceneLease := preload("res://addons/godot_mcp_toolkit/scene/scene_lease.gd")
const ServerRequestRouter := preload("res://addons/godot_mcp_toolkit/transport/dispatch/server_request_router.gd")
const Helpers := preload("res://addons/godot_mcp_toolkit/commands/editor_helpers.gd")


static func run(h) -> void:
	_test_watchdog_timeout(h)
	_test_scene_lease(h)
	_test_mutation_watchdog(h)
	_test_lane_selection(h)
	_test_summarize_batch(h)


# --- Mutation-watchdog deadline basis (Fix 6, 41l-tricies) -----------------
# get_watchdog_timeout_ms: trust a DECLARED timeout; for an undeclared command
# (the 30s default, not a deliberate duration) use _MAX_TIMEOUT_MS so an
# undeclared-but-slow method is never force-cleared early.

static func _test_watchdog_timeout(h) -> void:
	h.begin("Watchdog timeout basis")
	var reg := MCPToolkitCommandRegistry.new()

	# 1. declared timeout → trusted (the author's contract)
	reg.add("wd.declared", h.noop, MCPToolkitCommandOptions.new().with_timeout_ms(5000))
	h.eq(reg.get_watchdog_timeout_ms("wd.declared"), 5000,
			"declared timeout → trusted (5000)")

	# 2. undeclared (default) → _MAX_TIMEOUT_MS (300000), NOT the 30s default
	reg.add("wd.default", h.noop, MCPToolkitCommandOptions.new())
	h.eq(reg.get_watchdog_timeout_ms("wd.default"), 300000,
			"undeclared → _MAX_TIMEOUT_MS, not the 30s default")

	# 3. timeout 0 → treated as undeclared → _MAX_TIMEOUT_MS
	reg.add("wd.zero", h.noop, MCPToolkitCommandOptions.new().with_timeout_ms(0))
	h.eq(reg.get_watchdog_timeout_ms("wd.zero"), 300000,
			"timeout 0 → undeclared → _MAX_TIMEOUT_MS")

	# 4. explicitly declared 30000 is still 'declared' → trusted, NOT forced to _MAX
	reg.add("wd.d30k", h.noop, MCPToolkitCommandOptions.new().with_timeout_ms(30000))
	h.eq(reg.get_watchdog_timeout_ms("wd.d30k"), 30000,
			"explicitly declared 30000 → trusted (not _MAX)")

	# 5. unknown method → _MAX_TIMEOUT_MS (safe ceiling)
	h.eq(reg.get_watchdog_timeout_ms("wd.unknown"), 300000,
			"unknown method → _MAX_TIMEOUT_MS")

	print("")


# --- Scene-lease bookkeeping (Fix 4, 41l-tricies; concern 007 C6) ----------
# After Fix 4, lease acquire/release is pure bookkeeping (the raw
# open_scene_from_path was removed), so it is headless-unit-testable. C6 extracted
# the lease mechanism into scene_lease.gd, so this now instantiates that child
# directly and injects a stub root-resolver (the empty-scene acquire/release paths
# never consult it), exercising the child's public try_acquire / release / lease_holder
# API instead of poking mcp_server internals. Assertions are unchanged.

static func _test_scene_lease(h) -> void:
	h.begin("Scene lease bookkeeping (007 C6)")
	var lease = SceneLease.new()
	# Stub seams — the empty-scene acquire/release/lease_holder paths exercised here
	# do not invoke the root-resolver, command re-emit, read core, or mutation lane.
	var stub_root := func() -> Node: return null
	var noop_cmd := func(_m: String) -> void: pass
	var stub_read := func(_m: String, _p: Dictionary, _id) -> Dictionary: return {}
	var stub_enqueue := func(_pe, _id, _m: String, _p: Dictionary, _q: int) -> bool: return false
	var stub_exec := func(_pe, _id, _m: String, _p: Dictionary, _q: int) -> void: pass
	lease.set_handlers(stub_root, noop_cmd, stub_read, stub_enqueue, stub_exec)
	var peer_a := WebSocketPeer.new()
	var peer_b := WebSocketPeer.new()

	# 1. free lease → A acquires (empty scene skips the file-exists check)
	h.ok(lease.try_acquire(peer_a, ""), "free lease → A acquires")
	h.ok(lease.lease_holder() == peer_a, "lease holder is A")

	# 2. same peer → renews
	h.ok(lease.try_acquire(peer_a, ""), "same peer → renews (true)")
	h.ok(lease.lease_holder() == peer_a, "A still holds after renew")

	# 3. different peer → contended (false); A keeps it
	h.ok(not lease.try_acquire(peer_b, ""), "other peer → contended (false)")
	h.ok(lease.lease_holder() == peer_a, "A still holds under contention")

	# 4. release → no holder
	lease.release()
	h.ok(lease.lease_holder() == null, "release → no holder")

	# 5. after release → B acquires
	h.ok(lease.try_acquire(peer_b, ""), "after release → B acquires")
	h.ok(lease.lease_holder() == peer_b, "lease holder is B")

	print("")


# --- MutationWatchdog (concern 007 C5) -------------------------------------
# The pure timer + generation child that recovers the mutation lock when an
# in-flight mutation aborts/never resolves. Fully headless-testable: inject a fake
# force_clear Callable (recording into a Dictionary so the lambda can mutate it),
# and pass the deadline as a value to arm() — a deadline in the PAST forces a trip,
# one in the FUTURE proves no false-trip, with no time mocking needed (the lane
# owns the clock; this child only compares against the value handed to arm()).

static func _test_mutation_watchdog(h) -> void:
	h.begin("MutationWatchdog (007 C5)")

	# Recorder the fake force_clear writes into (Dictionary → mutable from the lambda).
	var rec := {"calls": 0, "last_id": null}
	var force_clear := func(trapped_id) -> void:
		rec["calls"] += 1
		rec["last_id"] = trapped_id

	# 1. Not armed → tick is a no-op (no force_clear, generation untouched).
	var wd := MutationWatchdog.new()
	wd.set_force_clear(force_clear)
	var gen0 := wd.current_generation()
	wd.tick()
	h.eq(rec["calls"], 0, "not armed → tick does not fire force_clear")
	h.eq(wd.current_generation(), gen0, "not armed → generation untouched")

	# 2. Armed with a FUTURE deadline → tick does NOT trip.
	var peer := WebSocketPeer.new()  # not OPEN → the peer-error send is guarded off
	var future := Time.get_ticks_msec() + 60000
	var gen_armed := wd.arm(peer, 7, "node.create", Time.get_ticks_msec(), future, null)
	h.eq(gen_armed, gen0, "arm → returns the current generation")
	wd.tick()
	h.eq(rec["calls"], 0, "armed, deadline in future → no trip")
	h.eq(wd.current_generation(), gen0, "future deadline → generation untouched")

	# 3. disarm (normal completion) → tick is a no-op (no trip after disarm).
	wd.disarm()
	wd.tick()
	h.eq(rec["calls"], 0, "disarm → tick does not trip")

	# 4. DEADLINE TRIP — arm with a PAST deadline, tick → force_clear fired once with
	#    the trapped id, and the generation is bumped by exactly 1.
	var gen_before := wd.current_generation()
	var past := Time.get_ticks_msec() - 1000
	wd.arm(peer, 42, "node.create", past, past, null)
	wd.tick()
	h.eq(rec["calls"], 1, "past deadline → trip fires force_clear once")
	h.eq(rec["last_id"], 42, "trip → force_clear receives the trapped id")
	h.eq(wd.current_generation(), gen_before + 1, "trip → generation bumped by 1")

	# 5. STALE-TAIL ABANDONMENT — the generation captured at arm() no longer matches
	#    after the trip, so the abandoned coroutine's tail (which compares them) bails.
	h.ok(wd.current_generation() != gen_before, "trip → captured gen != current gen (stale tail bails)")

	# 6. After a trip the watchdog disarmed itself → a second tick is a no-op (no
	#    double-fire even if _process ticks again before a successor arms).
	wd.tick()
	h.eq(rec["calls"], 1, "post-trip → second tick does not re-fire force_clear")

	# 7. COOPERATIVE CANCEL — a cancellable in-flight ctx is cancelled on a trip so a
	#    slow-but-alive handler bails at its next is_cancelled() poll.
	var ctx := MCPToolkitToolContext.new()
	wd.arm(peer, 99, "node.create", past, past, ctx)
	h.ok(not ctx.is_cancelled(), "armed ctx → not cancelled before trip")
	wd.tick()
	h.ok(ctx.is_cancelled(), "trip → in-flight ctx cooperatively cancelled")
	h.eq(rec["last_id"], 99, "trip → force_clear receives the second trapped id")

	# 8. force_clear unset → trip still recovers gracefully (no crash, generation
	#    still bumps). A real lane always wires it; this proves the is_valid() guard.
	var wd2 := MutationWatchdog.new()
	var g2 := wd2.current_generation()
	wd2.arm(peer, 1, "node.create", past, past, null)
	wd2.tick()
	h.eq(wd2.current_generation(), g2 + 1, "no force_clear wired → trip still bumps generation (no crash)")

	print("")


# --- Lane selection (concern 007 C7) ---------------------------------------
# server_request_router.lane_kind_for is the pure data→route mapping at the heart of the
# Lane abstraction: from a command's registry flags alone it decides read / mutation /
# scene_lease. Fully headless-testable — set a registry with commands carrying specific
# flag combos and assert the kind, no live lanes / peers / editor needed. This pins the
# behaviour-preserving routing the pre-extraction _dispatch_rpc hand-coded:
#   - read-only + scene-independent          → read     (bypass lock, no lease)
#   - mutator + scene-independent            → mutation (single-flight FIFO)
#   - active-scene-required (read OR mutate)  → scene_lease (queue on tab contention)
#   - scene.open                             → scene_lease ALWAYS (special-cased), even
#                                              though it is registered scene-independent.

static func _test_lane_selection(h) -> void:
	h.begin("Lane selection (007 C7)")
	var reg := MCPToolkitCommandRegistry.new()
	var disp := ServerRequestRouter.new()
	disp.set_registry(reg)

	# read-only + scene-independent → ReadOnlyLane (no lock, no lease).
	reg.add("t.read", h.noop,
			MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
	h.eq(disp.lane_kind_for("t.read"), ServerRequestRouter.LANE_READ,
			"read-only + scene-independent → read lane")

	# mutator (default, not read-only) + scene-independent → MutationLane.
	reg.add("t.mutate", h.noop, MCPToolkitCommandOptions.new().mark_scene_independent())
	h.eq(disp.lane_kind_for("t.mutate"), ServerRequestRouter.LANE_MUTATION,
			"mutator + scene-independent → mutation lane")

	# exclusive-execution mutator + scene-independent → MutationLane (force-serialized).
	reg.add("t.excl", h.noop,
			MCPToolkitCommandOptions.new().mark_exclusive_execution().mark_scene_independent())
	h.eq(disp.lane_kind_for("t.excl"), ServerRequestRouter.LANE_MUTATION,
			"exclusive-execution + scene-independent → mutation lane")

	# active-scene-required mutator (the default — no mark_scene_independent) → SceneLeaseLane.
	reg.add("t.scene_mut", h.noop, MCPToolkitCommandOptions.new())
	h.eq(disp.lane_kind_for("t.scene_mut"), ServerRequestRouter.LANE_SCENE_LEASE,
			"active-scene-required mutator → scene-lease lane")

	# active-scene-required READ (read-only but NOT scene-independent) → SceneLeaseLane.
	# Scene affinity wins over the read bypass — a read of the active tree still queues.
	reg.add("t.scene_read", h.noop, MCPToolkitCommandOptions.new().mark_read_only())
	h.eq(disp.lane_kind_for("t.scene_read"), ServerRequestRouter.LANE_SCENE_LEASE,
			"active-scene-required read → scene-lease lane (affinity over read bypass)")

	# scene.open → scene_lease ALWAYS, even registered scene-independent (the explicit
	# special-case clause — under contention it must NOT open the scene / switch tabs).
	reg.add("scene.open", h.noop, MCPToolkitCommandOptions.new().mark_scene_independent())
	h.eq(disp.lane_kind_for("scene.open"), ServerRequestRouter.LANE_SCENE_LEASE,
			"scene.open → scene-lease lane always (special-cased, despite scene-independent)")

	# Unknown/unregistered method → mutation lane (the conservative serialized
	# default): is_active_scene_required defaults false for an absent command
	# (cmd == null), so the scene-lease clause is skipped, but needs_serialization
	# defaults true for an absent command, so it falls through to MutationLane.
	# Moot in production — the router's registry-miss guard returns -32601
	# before lane selection is ever reached for an unregistered method.
	h.eq(disp.lane_kind_for("t.unknown"), ServerRequestRouter.LANE_MUTATION,
			"unknown method → mutation lane (conservative serialized default; moot in prod, -32601 guard fires first)")

	print("")


# --- summarize_batch (batch partial-failure rollup) -----------------------
# Pure response shaper: rolls a per-entry results[] up into a top-level failed
# count + hint, additively (all-success batches stay byte-identical). The failure
# predicate is shape-tolerant so it serves both batch conventions: {success:bool}
# (node.set_property batch) AND {status?, error?} with no success key (node.groups
# batch). Pure → pinned here with hand-built dicts, no editor.
static func _test_summarize_batch(h) -> void:
	h.begin("summarize_batch batch partial-failure rollup")

	# All-success {success:true} → UNCHANGED (no failed, no hint added).
	var all_ok := {"results": [{"success": true}, {"success": true}], "count": 2}
	var r_all_ok := Helpers.summarize_batch(all_ok, "results")
	h.ok(not r_all_ok.has("failed"), "all-success → no failed key (additive: unchanged)")
	h.ok(not r_all_ok.has("hint"), "all-success → no hint key")
	h.eq(r_all_ok.get("count"), 2, "all-success → pre-existing keys preserved")

	# 1-of-3 {success:false} → failed=1 + hint naming results[].
	var one_fail := {"results": [
		{"success": true}, {"success": false, "error": "boom"}, {"success": true}]}
	var r_one_fail := Helpers.summarize_batch(one_fail, "results")
	h.eq(r_one_fail.get("failed"), 1, "1-of-3 success:false → failed=1")
	h.ok(str(r_one_fail.get("hint", "")).contains("1 of 3"), "hint reports 1 of 3")
	h.ok(str(r_one_fail.get("hint", "")).contains("results[]"), "hint steers to results[]")

	# Site-2 shape: {status?, error?} with NO success key. An entry with an error
	# and no success is a failure; an entry with a status and no error is not.
	var groups_shape := {"action": "add", "count": 2, "results": [
		{"node_path": "A", "group": "g", "status": "added"},
		{"node_path": "B", "group": "g", "error": "node not found"}]}
	var r_groups := Helpers.summarize_batch(groups_shape, "results")
	h.eq(r_groups.get("failed"), 1, "site-2 (no success key) error entry → counted")
	h.eq(r_groups.get("count"), 2, "site-2 → pre-existing count preserved")
	h.eq(r_groups.get("action"), "add", "site-2 → pre-existing action preserved")

	# A status-only entry (no error, no success) is NOT a failure.
	var all_added := {"results": [
		{"status": "added"}, {"status": "removed"}], "count": 2}
	var r_all_added := Helpers.summarize_batch(all_added, "results")
	h.ok(not r_all_added.has("failed"), "site-2 all-status (no error) → no failed key")

	# Empty results → UNCHANGED.
	var empty := {"results": [], "count": 0}
	var r_empty := Helpers.summarize_batch(empty, "results")
	h.ok(not r_empty.has("failed"), "empty results → no failed key")
	h.ok(not r_empty.has("hint"), "empty results → no hint key")

	# Non-dict entries are tolerated (skipped), not counted as failures by accident
	# of the predicate; a real {success:false} alongside still counts.
	var mixed := {"results": [42, {"success": false, "error": "x"}]}
	var r_mixed := Helpers.summarize_batch(mixed, "results")
	h.eq(r_mixed.get("failed"), 1, "non-dict entry skipped; success:false counted")

	print("")
