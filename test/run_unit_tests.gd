extends SceneTree
## Headless unit test runner for MCP Toolkit pure-logic internals.
##
## Run: timeout 30 godot --headless --script test/run_unit_tests.gd
##
## Exit code: 0 = all passed, 1 = failures detected.
## The final banner is always printed for environments where exit codes
## are unreliable (Windows Godot).

const _SafeSceneOps := preload("res://addons/godot_mcp_toolkit/scene/mcp_toolkit_safe_scene_ops.gd")
const EditorRescan := preload("res://addons/godot_mcp_toolkit/commands/editor/editor_rescan.gd")
const UnfocusedBackup := preload("res://addons/godot_mcp_toolkit/core/unfocused_backup.gd")
const RegistryClient := preload("res://addons/godot_mcp_toolkit/registry/registry_client.gd")
const SettingsRegistration := preload("res://addons/godot_mcp_toolkit/core/settings_registration.gd")
const LogHelpers := preload("res://addons/godot_mcp_toolkit/logging/log_helpers.gd")
const ScriptCommands := preload("res://addons/godot_mcp_toolkit/commands/script_commands.gd")
const NodeCommands := preload("res://addons/godot_mcp_toolkit/commands/node_commands.gd")
const FileGuard := preload("res://addons/godot_mcp_toolkit/security/file_guard.gd")
const Untrusted := preload("res://addons/godot_mcp_toolkit/security/untrusted.gd")
const ExtensionCatalog := preload("res://addons/godot_mcp_toolkit/ui/dock/ext/extension_catalog.gd")
const OnboardingWizard := preload("res://addons/godot_mcp_toolkit/ui/onboarding_wizard.gd")
const ExtensionSupport := preload("res://addons/godot_mcp_toolkit/extensions/services/extension_support.gd")
const ExtensionMetaCommands := preload("res://addons/godot_mcp_toolkit/extensions/services/extension_meta_commands.gd")
const ExtensionWatcher := preload("res://addons/godot_mcp_toolkit/extensions/services/extension_watcher.gd")
const SpatialCommands := preload("res://addons/godot_mcp_toolkit/commands/spatial_commands.gd")
const TextureCommands := preload("res://addons/godot_mcp_toolkit/commands/texture_commands.gd")
const ParticleCommands := preload("res://addons/godot_mcp_toolkit/commands/particle_commands.gd")
const SoundCommands := preload("res://addons/godot_mcp_toolkit/commands/sound_commands.gd")
const TilesetTileData := preload("res://addons/godot_mcp_toolkit/commands/tileset/tileset_tile_data.gd")
const TilesetIo := preload("res://addons/godot_mcp_toolkit/commands/tileset/tileset_io.gd")
const ThemeCommands := preload("res://addons/godot_mcp_toolkit/commands/theme_commands.gd")
const PlaytestLogReader := preload("res://addons/godot_mcp_toolkit/commands/playtest_log_reader.gd")
const Coerce := preload("res://addons/godot_mcp_toolkit/contract/coerce.gd")
const SignalPairResolver := preload("res://addons/godot_mcp_toolkit/scene/signal_pair_resolver.gd")
const MutationWatchdog := preload("res://addons/godot_mcp_toolkit/transport/dispatch/mutation_watchdog.gd")
const SceneLease := preload("res://addons/godot_mcp_toolkit/scene/scene_lease.gd")
const ServerRequestRouter := preload("res://addons/godot_mcp_toolkit/transport/dispatch/server_request_router.gd")
const ProjectKey := preload("res://addons/godot_mcp_toolkit/paths/project_key.gd")
const ProjectPaths := preload("res://addons/godot_mcp_toolkit/paths/project_paths.gd")
const RegistryPaths := preload("res://addons/godot_mcp_toolkit/registry/store/registry_paths.gd")
const RegistryEntryFile := preload("res://addons/godot_mcp_toolkit/registry/store/registry_entry_file.gd")
const RegistryProjection := preload("res://addons/godot_mcp_toolkit/registry/store/registry_projection.gd")
const Harness := preload("res://test/units/_harness.gd")
const SecurityTests := preload("res://test/units/security_tests.gd")
const RegistryCommandTests := preload("res://test/units/registry_command_tests.gd")
const RegistryStoreTests := preload("res://test/units/registry_store_tests.gd")
const ExtensionMetaTests := preload("res://test/units/extension_meta_tests.gd")
const OptionsTests := preload("res://test/units/options_tests.gd")

var _h := Harness.new()


func _init() -> void:
	print("=== MCP Toolkit Unit Tests ===")
	print("")

	if not _guard_addon_classes():
		quit(1)
		return

	SecurityTests.run(_h)
	RegistryCommandTests.run(_h)
	RegistryStoreTests.run(_h)
	await ExtensionMetaTests.run(_h)
	OptionsTests.run(_h)
	_test_watchdog_timeout()
	_test_scene_lease()
	_test_signal_pair_resolver()
	_test_mutation_watchdog()
	_test_lane_selection()
	_test_safe_scene_ops()
	_test_tool_context()
	_test_compile_text_filter()
	_test_log_level_continuation()
	_test_set_property_compound()
	_test_compound_set_helper()
	_test_undo_info()
	_test_undo_redo_action()
	_test_error_api()
	_test_error_codes_vocabulary()
	_test_make_error_entry()
	_test_export_strip()
	_test_editor_refresh_reload_filter()
	_test_unfocused_backup()
	_test_stale_instance_hint()
	_test_compile_error_message()
	_test_groups_property_rejection()
	await _test_response_validation()
	_test_response_size_guard()
	_test_spatial_map()
	_test_texture_generate()
	_test_particle_prop_apply()
	_test_particle_merge_overrides()
	_test_sound_generate()
	_test_create_collision_resolver()
	_test_summarize_batch()
	_test_tileset_edit_key_enforcement()
	_test_tileset_io_polygon()
	_test_coerce_roundtrip()
	_test_color_from_dict()
	_test_color_from_dict_opaque()
	_test_node_packed_property_serialize()
	_test_user_path_monitor()
	_test_save_read_paging()
	_test_script_read_paging()
	_test_settings_collect_names()

	var failed := _h.report()
	quit(0 if failed == 0 else 1)


# --- Guards ----------------------------------------------------------------

func _guard_addon_classes() -> bool:
	# If any class_name is unavailable (addon not enabled), Godot throws a
	# parse error before _init() runs. This runtime check is defence-in-depth
	# for unexpected constructor failures.
	var r := MCPToolkitCommandRegistry.new()
	var o := MCPToolkitCommandOptions.new()
	var e := MCPToolkitExtensionOptions.new("guard")
	var c := MCPToolkitToolContext.new()
	if r == null or o == null or e == null or c == null:
		print("FAIL: addon classes not accessible — is the addon enabled in project.godot?")
		return false
	print("Guard: all 4 addon classes accessible")
	print("")
	return true


# --- Log level + continuation leveling (~14 assertions) -------------------
# A2/A3 (41m-ter): editor parse errors on Godot 4.2-4.4 log as TWO lines —
# "SCRIPT ERROR: …" then "   at: <script>.gd:LINE" — and the script path is on the
# continuation line. LogHelpers.is_continuation_line lets the file-tail buffer
# (log_buffer.gd) and the source=file reader (editor_commands.gd) keep such a line at
# the preceding error/warning level instead of "info", so a filename+level=error query
# finds it. _level_sequence mirrors that loop using the shared primitives under test.

func _level_sequence(lines: Array) -> Array:
	var out: Array = []
	var prev := "info"
	for line in lines:
		var stripped: String = str(line).strip_edges()
		if stripped.is_empty():
			continue
		var lvl: String
		if LogHelpers.is_continuation_line(line) and (prev == "error" or prev == "warning"):
			lvl = prev
		else:
			lvl = LogHelpers.detect_log_level(stripped)
		out.append(lvl)
		prev = lvl
	return out


func _test_log_level_continuation() -> void:
	_h.begin("Log level + continuation leveling")

	# detect_log_level prefixes (SHADER ERROR: is the new one)
	_h.eq(LogHelpers.detect_log_level("ERROR: boom"), "error", "ERROR: → error")
	_h.eq(LogHelpers.detect_log_level("SCRIPT ERROR: Parse Error: x"), "error", "SCRIPT ERROR: → error")
	_h.eq(LogHelpers.detect_log_level("SHADER ERROR: bad shader"), "error", "SHADER ERROR: → error (added)")
	_h.eq(LogHelpers.detect_log_level("WARNING: meh"), "warning", "WARNING: → warning")
	_h.eq(LogHelpers.detect_log_level("just a message"), "info", "plain → info")
	_h.eq(LogHelpers.detect_log_level("at: GDScript::reload (res://x.gd:1)"), "info",
		"stripped at: line alone → info (no prefix)")

	# is_continuation_line — pass RAW (un-edge-stripped) lines so indentation is visible
	_h.ok(LogHelpers.is_continuation_line("   at: GDScript::reload (res://x.gd:1)"),
		"indented 'at:' → continuation")
	_h.ok(LogHelpers.is_continuation_line("at: foo (bar:2)"), "bare 'at:' → continuation")
	_h.ok(LogHelpers.is_continuation_line("\ttab indented"), "tab-indented → continuation")
	_h.ok(not LogHelpers.is_continuation_line("SCRIPT ERROR: x"), "error line → not continuation")
	_h.ok(not LogHelpers.is_continuation_line("plain message"), "plain line → not continuation")

	# Sequence: the exact Godot 4.2 parse-error shape → both lines error-leveled.
	var parse_err := [
		'SCRIPT ERROR: Parse Error: Could not find base class "BogusHitClass".',
		'   at: GDScript::reload (res://smoke_txtflt_hit.gd:1)',
	]
	_h.eq(_level_sequence(parse_err), ["error", "error"],
		"4.2 parse error: SCRIPT ERROR: + at: both → error")
	_h.eq(_level_sequence(["WARNING: w", "   at: foo (x:1)"]), ["warning", "warning"],
		"warning + at: both → warning")
	_h.eq(_level_sequence(["a plain info line", "   at: stray (x:1)"]), ["info", "info"],
		"info + at: → info (no spurious error inherit)")


# --- Compile-error diagnostic message (version-aware) (~10 assertions) -----
# script_check / script_write steer the LLM to the right detail tool: editor_get_console
# captures editor PARSE errors only on 4.5+ (Logger); on 4.2-4.4 they aren't file-logged,
# so the diagnostic must point to lsp_diagnostics instead of a dead end. Regression guard
# for the misleading-message bug (standalone follow-up to 41m-ter).

func _test_compile_error_message() -> void:
	_h.begin("Compile-error message (version-aware)")
	# Discriminator: lsp_diagnostics appears ONLY in the <4.5 message (the 4.5+ message
	# directs to editor_get_console). The <4.5 message also names editor_get_console — but
	# only to say it CAN'T capture parse errors there — so don't assert on its mere presence.
	for ver in ["4.2", "4.3", "4.4"]:
		var msg: String = ScriptCommands._compile_error_message(ver)
		_h.ok(msg.contains("lsp_diagnostics"),
			"%s → recommends lsp_diagnostics (editor_get_console can't capture parse errors <4.5)" % ver)
	for ver in ["4.5", "4.6"]:
		var msg: String = ScriptCommands._compile_error_message(ver)
		_h.ok(msg.contains("editor_get_console") and not msg.contains("lsp_diagnostics"),
			"%s → directs to editor_get_console, not lsp (4.5+ Logger captures parse errors)" % ver)


# --- node.set_property "groups" rejection (concern 032) -------------------
# node.set_property does a declarative full-set replace, so accepting "groups"
# would silently drop any group not in the list; node.groups is incremental.
# Single mode whole-call-rejects and batch per-entry-rejects on this one name,
# steering to node.groups. _is_groups_property is the shared pure decision; the
# steering text is pinned so a future edit can't drop the node.groups pointer.

func _test_groups_property_rejection() -> void:
	_h.begin("node.set_property groups rejection (concern 032)")
	# The predicate is exact: only the bare "groups" property is refused.
	_h.ok(NodeCommands._is_groups_property("groups"), "'groups' → refused")
	_h.ok(not NodeCommands._is_groups_property("group"), "'group' → not refused")
	_h.ok(not NodeCommands._is_groups_property("groups_enabled"), "'groups_enabled' → not refused")
	_h.ok(not NodeCommands._is_groups_property(""), "empty → not refused")
	_h.ok(not NodeCommands._is_groups_property("position"), "ordinary property → not refused")
	# The rejection steers to node.groups (the message/hint can't silently lose it).
	_h.ok(not NodeCommands._GROUPS_REJECTION_MESSAGE.is_empty(), "rejection message present")
	_h.ok(NodeCommands._GROUPS_REJECTION_HINT.contains("node.groups"),
		"rejection hint names node.groups")
	print("")


# --- Mutation-watchdog deadline basis (Fix 6, 41l-tricies) -----------------
# get_watchdog_timeout_ms: trust a DECLARED timeout; for an undeclared command
# (the 30s default, not a deliberate duration) use _MAX_TIMEOUT_MS so an
# undeclared-but-slow method is never force-cleared early.

func _test_watchdog_timeout() -> void:
	_h.begin("Watchdog timeout basis")
	var reg := MCPToolkitCommandRegistry.new()

	# 1. declared timeout → trusted (the author's contract)
	reg.add("wd.declared", _h.noop, MCPToolkitCommandOptions.new().with_timeout_ms(5000))
	_h.eq(reg.get_watchdog_timeout_ms("wd.declared"), 5000,
			"declared timeout → trusted (5000)")

	# 2. undeclared (default) → _MAX_TIMEOUT_MS (300000), NOT the 30s default
	reg.add("wd.default", _h.noop, MCPToolkitCommandOptions.new())
	_h.eq(reg.get_watchdog_timeout_ms("wd.default"), 300000,
			"undeclared → _MAX_TIMEOUT_MS, not the 30s default")

	# 3. timeout 0 → treated as undeclared → _MAX_TIMEOUT_MS
	reg.add("wd.zero", _h.noop, MCPToolkitCommandOptions.new().with_timeout_ms(0))
	_h.eq(reg.get_watchdog_timeout_ms("wd.zero"), 300000,
			"timeout 0 → undeclared → _MAX_TIMEOUT_MS")

	# 4. explicitly declared 30000 is still 'declared' → trusted, NOT forced to _MAX
	reg.add("wd.d30k", _h.noop, MCPToolkitCommandOptions.new().with_timeout_ms(30000))
	_h.eq(reg.get_watchdog_timeout_ms("wd.d30k"), 30000,
			"explicitly declared 30000 → trusted (not _MAX)")

	# 5. unknown method → _MAX_TIMEOUT_MS (safe ceiling)
	_h.eq(reg.get_watchdog_timeout_ms("wd.unknown"), 300000,
			"unknown method → _MAX_TIMEOUT_MS")

	print("")


# --- Scene-lease bookkeeping (Fix 4, 41l-tricies; concern 007 C6) ----------
# After Fix 4, lease acquire/release is pure bookkeeping (the raw
# open_scene_from_path was removed), so it is headless-unit-testable. C6 extracted
# the lease mechanism into scene_lease.gd, so this now instantiates that child
# directly and injects a stub root-resolver (the empty-scene acquire/release paths
# never consult it), exercising the child's public try_acquire / release / lease_holder
# API instead of poking mcp_server internals. Assertions are unchanged.

func _test_scene_lease() -> void:
	_h.begin("Scene lease bookkeeping (007 C6)")
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
	_h.ok(lease.try_acquire(peer_a, ""), "free lease → A acquires")
	_h.ok(lease.lease_holder() == peer_a, "lease holder is A")

	# 2. same peer → renews
	_h.ok(lease.try_acquire(peer_a, ""), "same peer → renews (true)")
	_h.ok(lease.lease_holder() == peer_a, "A still holds after renew")

	# 3. different peer → contended (false); A keeps it
	_h.ok(not lease.try_acquire(peer_b, ""), "other peer → contended (false)")
	_h.ok(lease.lease_holder() == peer_a, "A still holds under contention")

	# 4. release → no holder
	lease.release()
	_h.ok(lease.lease_holder() == null, "release → no holder")

	# 5. after release → B acquires
	_h.ok(lease.try_acquire(peer_b, ""), "after release → B acquires")
	_h.ok(lease.lease_holder() == peer_b, "lease holder is B")

	print("")


# --- SignalPairResolver (concern 007 C4) -----------------------------------
# The export-clean skeleton shared by the editor signal handlers and the runtime
# autoload. Pure logic over a tree whose root is supplied by an injected resolver
# Callable, so it is fully headless-testable: build a tiny Node tree, inject
# `func(): return root`, and assert the happy path plus each guard. Uses built-in
# Node signals/methods (`ready` / `queue_free`) so no custom class is needed.

func _test_signal_pair_resolver() -> void:
	_h.begin("SignalPairResolver (007 C4)")
	var root := Node.new()
	root.name = "Root"
	var src := Node.new()
	src.name = "Src"
	var tgt := Node.new()
	tgt.name = "Tgt"
	root.add_child(src)
	root.add_child(tgt)
	var resolver := func() -> Node: return root

	# resolve_node — empty / "." → root; named child → child; missing → null.
	_h.ok(SignalPairResolver.resolve_node("", resolver) == root, "resolve_node '' → root")
	_h.ok(SignalPairResolver.resolve_node(".", resolver) == root, "resolve_node '.' → root")
	_h.ok(SignalPairResolver.resolve_node("Src", resolver) == src, "resolve_node 'Src' → child")
	_h.ok(SignalPairResolver.resolve_node("Nope", resolver) == null, "resolve_node missing → null")
	# Null-root resolver → null (mirrors no edited scene / no live tree).
	var null_resolver := func() -> Node: return null
	_h.ok(SignalPairResolver.resolve_node("Src", null_resolver) == null, "resolve_node null root → null")

	# list_signals_of — built-in Node has a `ready` signal in its signal list.
	var sig_list := SignalPairResolver.list_signals_of(src)
	var has_ready := false
	for entry in sig_list:
		if str(entry.get("name", "")) == "ready":
			has_ready = true
			break
	_h.ok(has_ready, "list_signals_of → includes built-in 'ready' signal")

	# Happy path — Src.ready → Tgt.queue_free (both built-in to Node).
	var ok_params := {
		"source_path": "Src", "signal_name": "ready",
		"target_path": "Tgt", "method_name": "queue_free",
	}
	var r_ok := SignalPairResolver.resolve_pair(ok_params, resolver)
	_h.ok(not r_ok.has("error"), "resolve_pair happy → no error")
	_h.ok(r_ok.get("source") == src, "resolve_pair happy → source is Src")
	_h.ok(r_ok.get("target") == tgt, "resolve_pair happy → target is Tgt")
	_h.ok((r_ok.get("callable") as Callable) == Callable(tgt, "queue_free"),
			"resolve_pair happy → callable is Tgt.queue_free")

	# Guard: non-dict params.
	var r_nondict := SignalPairResolver.resolve_pair("nope", resolver)
	_h.eq(str(r_nondict.get("code", "")), "INVALID_PARAMS", "resolve_pair non-dict → INVALID_PARAMS")

	# Guard: missing required field (method omitted).
	var r_missing := SignalPairResolver.resolve_pair({
		"source_path": "Src", "signal_name": "ready", "target_path": "Tgt",
	}, resolver)
	_h.eq(str(r_missing.get("code", "")), "INVALID_PARAMS", "resolve_pair missing field → INVALID_PARAMS")

	# Guard: bad source path → NOT_FOUND (source).
	var r_bad_src := SignalPairResolver.resolve_pair({
		"source_path": "Ghost", "signal_name": "ready",
		"target_path": "Tgt", "method_name": "queue_free",
	}, resolver)
	_h.eq(str(r_bad_src.get("code", "")), "NOT_FOUND", "resolve_pair bad source → NOT_FOUND")
	_h.ok(str(r_bad_src.get("error", "")).contains("source node not found"),
			"resolve_pair bad source → 'source node not found' message")

	# Guard: bad signal → INVALID_PARAMS (signal not on source).
	var r_bad_sig := SignalPairResolver.resolve_pair({
		"source_path": "Src", "signal_name": "no_such_signal",
		"target_path": "Tgt", "method_name": "queue_free",
	}, resolver)
	_h.eq(str(r_bad_sig.get("code", "")), "INVALID_PARAMS", "resolve_pair bad signal → INVALID_PARAMS")
	_h.ok(str(r_bad_sig.get("error", "")).contains("not on"),
			"resolve_pair bad signal → 'not on' message")

	# Guard: bad target path → NOT_FOUND (target).
	var r_bad_tgt := SignalPairResolver.resolve_pair({
		"source_path": "Src", "signal_name": "ready",
		"target_path": "Ghost", "method_name": "queue_free",
	}, resolver)
	_h.eq(str(r_bad_tgt.get("code", "")), "NOT_FOUND", "resolve_pair bad target → NOT_FOUND")
	_h.ok(str(r_bad_tgt.get("error", "")).contains("target node not found"),
			"resolve_pair bad target → 'target node not found' message")

	# Guard: bad method → INVALID_PARAMS (method not on target).
	var r_bad_meth := SignalPairResolver.resolve_pair({
		"source_path": "Src", "signal_name": "ready",
		"target_path": "Tgt", "method_name": "no_such_method",
	}, resolver)
	_h.eq(str(r_bad_meth.get("code", "")), "INVALID_PARAMS", "resolve_pair bad method → INVALID_PARAMS")
	_h.ok(str(r_bad_meth.get("error", "")).contains("method"),
			"resolve_pair bad method → 'method' message")

	root.free()
	print("")


# --- MutationWatchdog (concern 007 C5) -------------------------------------
# The pure timer + generation child that recovers the mutation lock when an
# in-flight mutation aborts/never resolves. Fully headless-testable: inject a fake
# force_clear Callable (recording into a Dictionary so the lambda can mutate it),
# and pass the deadline as a value to arm() — a deadline in the PAST forces a trip,
# one in the FUTURE proves no false-trip, with no time mocking needed (the lane
# owns the clock; this child only compares against the value handed to arm()).

func _test_mutation_watchdog() -> void:
	_h.begin("MutationWatchdog (007 C5)")

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
	_h.eq(rec["calls"], 0, "not armed → tick does not fire force_clear")
	_h.eq(wd.current_generation(), gen0, "not armed → generation untouched")

	# 2. Armed with a FUTURE deadline → tick does NOT trip.
	var peer := WebSocketPeer.new()  # not OPEN → the peer-error send is guarded off
	var future := Time.get_ticks_msec() + 60000
	var gen_armed := wd.arm(peer, 7, "node.create", Time.get_ticks_msec(), future, null)
	_h.eq(gen_armed, gen0, "arm → returns the current generation")
	wd.tick()
	_h.eq(rec["calls"], 0, "armed, deadline in future → no trip")
	_h.eq(wd.current_generation(), gen0, "future deadline → generation untouched")

	# 3. disarm (normal completion) → tick is a no-op (no trip after disarm).
	wd.disarm()
	wd.tick()
	_h.eq(rec["calls"], 0, "disarm → tick does not trip")

	# 4. DEADLINE TRIP — arm with a PAST deadline, tick → force_clear fired once with
	#    the trapped id, and the generation is bumped by exactly 1.
	var gen_before := wd.current_generation()
	var past := Time.get_ticks_msec() - 1000
	wd.arm(peer, 42, "node.create", past, past, null)
	wd.tick()
	_h.eq(rec["calls"], 1, "past deadline → trip fires force_clear once")
	_h.eq(rec["last_id"], 42, "trip → force_clear receives the trapped id")
	_h.eq(wd.current_generation(), gen_before + 1, "trip → generation bumped by 1")

	# 5. STALE-TAIL ABANDONMENT — the generation captured at arm() no longer matches
	#    after the trip, so the abandoned coroutine's tail (which compares them) bails.
	_h.ok(wd.current_generation() != gen_before, "trip → captured gen != current gen (stale tail bails)")

	# 6. After a trip the watchdog disarmed itself → a second tick is a no-op (no
	#    double-fire even if _process ticks again before a successor arms).
	wd.tick()
	_h.eq(rec["calls"], 1, "post-trip → second tick does not re-fire force_clear")

	# 7. COOPERATIVE CANCEL — a cancellable in-flight ctx is cancelled on a trip so a
	#    slow-but-alive handler bails at its next is_cancelled() poll.
	var ctx := MCPToolkitToolContext.new()
	wd.arm(peer, 99, "node.create", past, past, ctx)
	_h.ok(not ctx.is_cancelled(), "armed ctx → not cancelled before trip")
	wd.tick()
	_h.ok(ctx.is_cancelled(), "trip → in-flight ctx cooperatively cancelled")
	_h.eq(rec["last_id"], 99, "trip → force_clear receives the second trapped id")

	# 8. force_clear unset → trip still recovers gracefully (no crash, generation
	#    still bumps). A real lane always wires it; this proves the is_valid() guard.
	var wd2 := MutationWatchdog.new()
	var g2 := wd2.current_generation()
	wd2.arm(peer, 1, "node.create", past, past, null)
	wd2.tick()
	_h.eq(wd2.current_generation(), g2 + 1, "no force_clear wired → trip still bumps generation (no crash)")

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

func _test_lane_selection() -> void:
	_h.begin("Lane selection (007 C7)")
	var reg := MCPToolkitCommandRegistry.new()
	var disp := ServerRequestRouter.new()
	disp.set_registry(reg)

	# read-only + scene-independent → ReadOnlyLane (no lock, no lease).
	reg.add("t.read", _h.noop,
			MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
	_h.eq(disp.lane_kind_for("t.read"), ServerRequestRouter.LANE_READ,
			"read-only + scene-independent → read lane")

	# mutator (default, not read-only) + scene-independent → MutationLane.
	reg.add("t.mutate", _h.noop, MCPToolkitCommandOptions.new().mark_scene_independent())
	_h.eq(disp.lane_kind_for("t.mutate"), ServerRequestRouter.LANE_MUTATION,
			"mutator + scene-independent → mutation lane")

	# exclusive-execution mutator + scene-independent → MutationLane (force-serialized).
	reg.add("t.excl", _h.noop,
			MCPToolkitCommandOptions.new().mark_exclusive_execution().mark_scene_independent())
	_h.eq(disp.lane_kind_for("t.excl"), ServerRequestRouter.LANE_MUTATION,
			"exclusive-execution + scene-independent → mutation lane")

	# active-scene-required mutator (the default — no mark_scene_independent) → SceneLeaseLane.
	reg.add("t.scene_mut", _h.noop, MCPToolkitCommandOptions.new())
	_h.eq(disp.lane_kind_for("t.scene_mut"), ServerRequestRouter.LANE_SCENE_LEASE,
			"active-scene-required mutator → scene-lease lane")

	# active-scene-required READ (read-only but NOT scene-independent) → SceneLeaseLane.
	# Scene affinity wins over the read bypass — a read of the active tree still queues.
	reg.add("t.scene_read", _h.noop, MCPToolkitCommandOptions.new().mark_read_only())
	_h.eq(disp.lane_kind_for("t.scene_read"), ServerRequestRouter.LANE_SCENE_LEASE,
			"active-scene-required read → scene-lease lane (affinity over read bypass)")

	# scene.open → scene_lease ALWAYS, even registered scene-independent (the explicit
	# special-case clause — under contention it must NOT open the scene / switch tabs).
	reg.add("scene.open", _h.noop, MCPToolkitCommandOptions.new().mark_scene_independent())
	_h.eq(disp.lane_kind_for("scene.open"), ServerRequestRouter.LANE_SCENE_LEASE,
			"scene.open → scene-lease lane always (special-cased, despite scene-independent)")

	# Unknown/unregistered method → mutation lane (the conservative serialized
	# default): is_active_scene_required defaults false for an absent command
	# (cmd == null), so the scene-lease clause is skipped, but needs_serialization
	# defaults true for an absent command, so it falls through to MutationLane.
	# Moot in production — the router's registry-miss guard returns -32601
	# before lane selection is ever reached for an unregistered method.
	_h.eq(disp.lane_kind_for("t.unknown"), ServerRequestRouter.LANE_MUTATION,
			"unknown method → mutation lane (conservative serialized default; moot in prod, -32601 guard fires first)")

	print("")


# --- MCPToolkitSafeSceneOps public API (Fix 1, 41l-tricies) ----------------
# is_dispatching() is the pure, headless-testable surface. wait_for_scan_idle /
# save_scene / queue_save touch EditorInterface (null in this --script runner),
# so they are covered by the smoke suite + the editor-required dispatch
# integration / A-B validation that exercise editor_save_scene end to end.

func _test_safe_scene_ops() -> void:
	_h.begin("MCPToolkitSafeSceneOps (public API)")
	_h.ok(not _SafeSceneOps.is_dispatching(), "is_dispatching → false by default")
	_SafeSceneOps._in_dispatch = true
	_h.ok(_SafeSceneOps.is_dispatching(), "is_dispatching → true when _in_dispatch set")
	_SafeSceneOps._in_dispatch = false
	_h.ok(not _SafeSceneOps.is_dispatching(), "is_dispatching → false after reset")

	# C# reaches the safe-save API through the registry facade (like
	# create_undo_action), so verify the registry bridge forwards to SafeSceneOps.
	# (queue_save fires the editor-coupled save → integration-tested; check_save
	# is pure dict logic → testable here.)
	var _reg := MCPToolkitCommandRegistry.new()
	_h.ok(_reg.check_save("nope").get("unknown", false),
			"registry.check_save bridge → forwards to SafeSceneOps")

	# check_save — pure dict logic; seed _save_results directly to bypass the
	# editor-coupled save in queue_save/_run_queued_save.
	_SafeSceneOps._save_results = {}
	_h.ok(_SafeSceneOps.check_save("nope").get("unknown", false),
			"check_save(unknown id) → unknown:true")
	_SafeSceneOps._save_results["s1"] = {"done": false}
	_h.ok(not _SafeSceneOps.check_save("s1").get("done", true),
			"pending save → done:false")
	_SafeSceneOps._save_results["s1"] = {"done": true, "success": true}
	_h.ok(_SafeSceneOps.check_save("s1").get("success", false),
			"completed save → success:true")
	_SafeSceneOps.check_save("s1", true)  # clear a done save
	_h.ok(_SafeSceneOps.check_save("s1").get("unknown", false),
			"check_save(clear) on done → record removed")
	_SafeSceneOps._save_results["s2"] = {"done": false}
	_SafeSceneOps.check_save("s2", true)  # clear a pending save → no-op
	_h.ok(_SafeSceneOps._save_results.has("s2"),
			"check_save(clear) on pending → kept")
	_SafeSceneOps._save_results = {}  # reset the shared static
	print("")


# --- ToolContext cancellation (~3 assertions) ------------------------------

func _test_tool_context() -> void:
	_h.begin("ToolContext cancellation")

	# 1. fresh → is_cancelled false
	var ctx := MCPToolkitToolContext.new()
	_h.ok(not ctx.is_cancelled(), "fresh context → is_cancelled false")

	# 2. cancel → is_cancelled true
	ctx.cancel()
	_h.ok(ctx.is_cancelled(), "after cancel → is_cancelled true")

	# 3. cancelled signal fires synchronously
	var ctx2 := MCPToolkitToolContext.new()
	var fired := [false]
	ctx2.cancelled.connect(func(): fired[0] = true)
	ctx2.cancel()
	_h.ok(fired[0], "cancel → cancelled signal fires")

	print("")


# --- Helpers: compile_text_filter (~6 assertions) -------------------------

const Helpers := preload("res://addons/godot_mcp_toolkit/commands/editor_helpers.gd")

func _test_compile_text_filter() -> void:
	_h.begin("compile_text_filter")

	# 1. Empty filter → null regex, no error
	var r1 := Helpers.compile_text_filter({"text_filter": "", "is_regex": true})
	_h.ok(r1[0] == null, "empty filter → null regex")
	_h.ok(r1[1] == null, "empty filter → no error")

	# 2. Non-regex → null regex
	var r2 := Helpers.compile_text_filter({"text_filter": "hello", "is_regex": false})
	_h.ok(r2[0] == null, "is_regex=false → null regex")

	# 3. Valid regex compiles
	var r3 := Helpers.compile_text_filter({"text_filter": "[0-9]+", "is_regex": true})
	_h.ok(r3[0] != null, "valid regex → RegEx instance")
	_h.ok(r3[1] == null, "valid regex → no error")

	# 4. Invalid regex → error returned
	var r4 := Helpers.compile_text_filter({"text_filter": "(unclosed", "is_regex": true})
	_h.ok(r4[0] == null, "invalid regex → null regex")
	_h.ok(r4[1] != null, "invalid regex → error dict")

	# 5. Double-escaped \\d → warning
	var r5 := Helpers.compile_text_filter({"text_filter": "test\\\\d+", "is_regex": true})
	_h.ok(r5[2] != "", "double-escaped \\d → warning not empty")

	# 6. Clean regex → empty warning
	var r6 := Helpers.compile_text_filter({"text_filter": "[0-9]+", "is_regex": true})
	_h.ok(r6[2] == "", "clean regex → empty warning")

	print("")


# --- Helpers: set_property_compound (~6 assertions) -----------------------

func _test_set_property_compound() -> void:
	_h.begin("set_property_compound")

	# 1. Simple slash path on a Control (theme_override)
	var ctrl := Control.new()
	var r1 := Helpers.set_property_compound(
		ctrl, "theme_override_font_sizes/font_size", 24)
	_h.ok(r1.get("ok", false), "theme_override slash path → ok")
	_h.eq(ctrl.get("theme_override_font_sizes/font_size"), 24,
		"theme_override readback = 24")
	ctrl.free()

	# 2. Colon path to sub-resource (ShaderMaterial shader_parameter)
	var shader := Shader.new()
	shader.code = "shader_type canvas_item;\nuniform float brightness : hint_range(0, 1) = 0.75;"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	# The node needs the material as a property for colon-chain navigation.
	# Use a Sprite2D which has a "material" property.
	var sprite := Sprite2D.new()
	sprite.material = mat
	var r2 := Helpers.set_property_compound(
		sprite, "material:shader_parameter/brightness", 0.3)
	_h.ok(r2.get("ok", false), "shader_parameter colon path → ok")
	var readback = sprite.get("material").get_shader_parameter("brightness")
	_h.eq(readback, 0.3, "shader_parameter readback = 0.3")
	sprite.free()

	# 3. Non-existent sub-resource → NOT_FOUND
	var node := Node2D.new()
	var r3 := Helpers.set_property_compound(
		node, "material:shader_parameter/x", 1.0)
	_h.ok(not r3.get("ok", false), "null sub-resource → error")
	_h.eq(r3.get("code", ""), "NOT_FOUND", "error code = NOT_FOUND")
	node.free()

	print("")


# --- compound_set helper (~8 assertions) ------------------------------------

const UndoRedoHelpers := preload("res://addons/godot_mcp_toolkit/scene/undo_redo_helpers.gd")

func _test_compound_set_helper() -> void:
	_h.begin("compound_set helper")
	var helpers := UndoRedoHelpers.new()

	# 1. Slash-only path (theme override on Control)
	var ctrl := Control.new()
	ctrl.add_theme_font_size_override("font_size", 16)
	helpers.compound_set(ctrl, "theme_override_font_sizes/font_size", 32)
	_h.eq(ctrl.get("theme_override_font_sizes/font_size"), 32,
		"slash-only: theme_override set to 32")
	ctrl.free()

	# 2. Single-colon sub-resource (shader_parameter on ShaderMaterial)
	var shader := Shader.new()
	shader.code = "shader_type canvas_item;\nuniform float brightness : hint_range(0, 1) = 0.75;"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	var sprite := Sprite2D.new()
	sprite.material = mat
	helpers.compound_set(sprite, "material:shader_parameter/brightness", 0.4)
	_h.eq(mat.get_shader_parameter("brightness"), 0.4,
		"single-colon: shader_parameter set to 0.4")
	# Undo by setting back
	helpers.compound_set(sprite, "material:shader_parameter/brightness", 0.75)
	_h.eq(mat.get_shader_parameter("brightness"), 0.75,
		"single-colon: shader_parameter restored to 0.75")
	sprite.free()

	# 3. Multi-colon sub-resource navigation
	var shader2 := Shader.new()
	shader2.code = "shader_type canvas_item;\nuniform float glow : hint_range(0, 1) = 0.0;"
	var pass2 := ShaderMaterial.new()
	pass2.shader = shader2
	var mat2 := ShaderMaterial.new()
	mat2.shader = shader
	mat2.next_pass = pass2
	var sprite2 := Sprite2D.new()
	sprite2.material = mat2
	helpers.compound_set(sprite2, "material:next_pass:shader_parameter/glow", 0.5)
	_h.eq(pass2.get_shader_parameter("glow"), 0.5,
		"multi-colon: next_pass shader_parameter set to 0.5")
	sprite2.free()

	# 4. Simple property (no colon, no slash)
	var node := Node2D.new()
	node.visible = true
	helpers.compound_set(node, "visible", false)
	_h.eq(node.visible, false, "simple: visible set to false")
	node.free()

	# 5. Null sub-resource → no crash (silent return)
	var empty := Sprite2D.new()
	helpers.compound_set(empty, "material:shader_parameter/x", 1.0)
	_h.ok(true, "null sub-resource: no crash")
	empty.free()

	helpers.free()
	print("")


# --- _undo info from set_property_compound (~6 assertions) ------------------

func _test_undo_info() -> void:
	_h.begin("_undo info")

	# 1. Slash-only path returns property type
	var ctrl := Control.new()
	var r1 := Helpers.set_property_compound(
		ctrl, "theme_override_font_sizes/font_size", 24)
	_h.ok(r1.get("ok", false), "slash-only: set ok")
	var u1: Dictionary = r1.get("_undo", {})
	_h.eq(u1.get("type"), "property", "slash-only: _undo type = property")
	_h.eq(u1.get("path"), "theme_override_font_sizes/font_size",
		"slash-only: _undo path preserved")
	ctrl.free()

	# 2. Single-colon path returns sub_resource type (readback null for in-memory)
	var shader := Shader.new()
	shader.code = "shader_type canvas_item;\nuniform float brightness : hint_range(0, 1) = 0.75;"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	var sprite := Sprite2D.new()
	sprite.material = mat
	var r2 := Helpers.set_property_compound(
		sprite, "material:shader_parameter/brightness", 0.3)
	_h.ok(r2.get("ok", false), "colon: set ok")
	var u2: Dictionary = r2.get("_undo", {})
	_h.ok(u2.get("type") == "property" or u2.get("type") == "sub_resource",
		"colon: _undo type is property or sub_resource")
	_h.eq(u2.get("old"), null, "colon: _undo old = null (no prior override)")
	sprite.free()

	print("")


# --- MCPToolkitUndoRedoAction (headless-safe subset) -----------------------

func _test_undo_redo_action() -> void:
	_h.begin("MCPToolkitUndoRedoAction")

	# 1. begin() returns non-null instance
	var action := MCPToolkitUndoRedoAction.begin("test action")
	_h.ok(action != null, "begin() returns non-null instance")

	# 2. is_active() returns false in headless (no plugin loaded)
	_h.ok(not action.is_active(), "is_active() false in headless")

	# 3. Fluent chaining — every method returns self
	var a2 := MCPToolkitUndoRedoAction.begin("chain test")
	var node := Node2D.new()
	var r1 = a2.do_property(node, &"position", Vector2(1, 2))
	_h.ok(r1 == a2, "do_property returns self")
	var r2 = a2.undo_property(node, &"position", Vector2.ZERO)
	_h.ok(r2 == a2, "undo_property returns self")
	var r3 = a2.do_method(node.set.bind(&"rotation", 1.0))
	_h.ok(r3 == a2, "do_method returns self")
	var r4 = a2.undo_method(node.set.bind(&"rotation", 0.0))
	_h.ok(r4 == a2, "undo_method returns self")
	var r5 = a2.do_reference(node)
	_h.ok(r5 == a2, "do_reference returns self")
	var r6 = a2.undo_reference(node)
	_h.ok(r6 == a2, "undo_reference returns self")
	node.free()

	# 4. All methods no-op without crash when inactive
	var inactive := MCPToolkitUndoRedoAction.begin("noop test")
	inactive.do_property(Node.new(), &"name", "test")  # won't crash
	inactive.undo_property(Node.new(), &"name", "old")
	inactive.do_method(Callable())
	inactive.undo_method(Callable())
	inactive.commit_recorded()
	_h.ok(true, "all methods no-op without crash when inactive")

	# 5. Double-commit guard — second call is no-op (warning logged)
	var a3 := MCPToolkitUndoRedoAction.begin("double commit")
	a3.commit_recorded()
	a3.commit_recorded()  # should push_warning, not crash
	_h.ok(true, "double commit_recorded() does not crash")

	# 6. commit() also guarded
	var a4 := MCPToolkitUndoRedoAction.begin("commit guard")
	a4.commit()
	a4.commit()  # should push_warning, not crash
	_h.ok(true, "double commit() does not crash")

	# 7. Cross-commit guard (commit after commit_recorded)
	var a5 := MCPToolkitUndoRedoAction.begin("cross commit")
	a5.commit_recorded()
	a5.commit()  # should push_warning, not crash
	_h.ok(true, "commit() after commit_recorded() does not crash")

	# 8. Registry factory returns valid instance
	var reg := MCPToolkitCommandRegistry.new()
	var factory_action := reg.create_undo_action("factory test")
	_h.ok(factory_action != null, "create_undo_action() returns non-null")
	_h.ok(not factory_action.is_active(), "factory action inactive in headless")

	print("")


# --- MCPToolkitError API (~5 assertions) ------------------------------------

func _test_error_api() -> void:
	_h.begin("MCPToolkitError API")

	# 1. fail() returns correct shape
	var e1 := MCPToolkitError.fail("NOT_FOUND", "Node missing")
	_h.ok(e1["success"] == false, "fail() → success false")
	_h.eq(e1["error"], "Node missing", "fail() → error message")
	_h.eq(e1["code"], "NOT_FOUND", "fail() → code")

	# 2. fail() with DEFAULT_HINTS code → auto-hint attached
	var e2 := MCPToolkitError.fail("TIMEOUT", "Editor busy")
	_h.ok(e2.has("hint"), "fail(TIMEOUT) → auto-hint attached")
	_h.eq(e2["hint"], MCPToolkitError.DEFAULT_HINTS["TIMEOUT"],
			"fail(TIMEOUT) → hint matches DEFAULT_HINTS")

	# 3. fail() with explicit hint → overrides auto-hint
	var e3 := MCPToolkitError.fail("TIMEOUT", "Custom", "My hint")
	_h.eq(e3["hint"], "My hint", "fail() explicit hint → overrides auto-hint")

	# 4. fail() with non-DEFAULT_HINTS code and no hint → no hint key
	var e4 := MCPToolkitError.fail("NOT_FOUND", "Missing")
	_h.ok(not e4.has("hint"), "fail(NOT_FOUND, no hint) → no hint key")

	# 5. require() with all params present → returns null
	var ok_params := {"node_path": "/root/Player", "file_path": "res://s.gd"}
	_h.eq(MCPToolkitError.require(ok_params, ["node_path", "file_path"]), null,
			"require() all present → null")

	# 6. require() with missing param → returns error with hint
	var bad_params := {"node_path": ""}
	var e5 = MCPToolkitError.require(bad_params, ["node_path"])
	_h.ok(e5 is Dictionary, "require() missing → returns Dictionary")
	_h.eq(e5["code"], "INVALID_PARAMS", "require() missing → INVALID_PARAMS")
	_h.eq(e5["hint"], MCPToolkitError.HINT_NODE_PATH,
			"require(node_path) → HINT_NODE_PATH")

	# 7. require() with missing file_path → HINT_FILE_PATH
	var bad_params2 := {"file_path": ""}
	var e6 = MCPToolkitError.require(bad_params2, ["file_path"])
	_h.eq(e6["hint"], MCPToolkitError.HINT_FILE_PATH,
			"require(file_path) → HINT_FILE_PATH")

	print("")


# --- Error-code vocabulary (drift guard) ------------------------------------

## Enforces that MCPToolkitError.CODES is the complete emitted-code vocabulary.
## (a) Every DEFAULT_HINTS key must be in CODES — this exact invariant catches
##     the class of bug where a code is emitted (and given a default hint) but
##     never registered, leaving fail()'s assert and audits with no anchor.
## (b) Codes confirmed emitted by the contract audit must each be in CODES, so
##     a future deletion that re-introduces the drift fails here.
func _test_error_codes_vocabulary() -> void:
	_h.begin("MCPToolkitError vocabulary")

	# (a) Every DEFAULT_HINTS key is a declared code.
	for key in MCPToolkitError.DEFAULT_HINTS.keys():
		var hint_code: String = str(key)
		_h.ok(MCPToolkitError.CODES.has(hint_code),
				"DEFAULT_HINTS key '%s' present in CODES" % hint_code)

	# (b) Every audit-confirmed emitted code is declared. Sourced from the
	# error-emit-site sweep across addons/ (fail() literals + re-emitted
	# {"code": ...} helper results). Keep in sync when adding error codes.
	var emitted: Array[String] = [
		"ALREADY_EXISTS", "ALREADY_PLAYING", "BUSY", "CLASS_MISMATCH",
		"COMPILATION_FAILED", "CONNECT_FAILED", "CREATE_DIR_FAILED",
		"DELETE_FAILED", "DIR_NOT_EMPTY", "EDITED_SCENE", "EMPTY_CONTENT",
		"EXECUTE_FAILED", "FAILED", "FILE_TOO_LARGE", "FILESYSTEM_NOT_READY",
		"FOLDER_PROTECTED", "GAME_NOT_RUNNING", "HEADLESS_UNSUPPORTED",
		"INTERNAL", "INVALID_CLASS", "INVALID_METHOD", "INVALID_PARAMS",
		"INVALID_PATH", "INVALID_STATE", "INVALID_VALUE", "LOAD_FAILED",
		"LOG_BUSY", "LOG_UNAVAILABLE", "NO_SCENE", "NODE_NOT_FOUND",
		"NOT_A_RESOURCE", "NOT_BREAKED", "NOT_FOUND", "PACK_FAILED",
		"PARENT_NOT_FOUND", "PARSE_ERROR", "PATH_DENIED", "PATH_IN_USE",
		"PROPERTY_NOT_FOUND", "READ_FAILED", "RESPONSE_TOO_LARGE",
		"SAVE_DELETE_FAILED", "SAVE_FAILED", "SAVE_READ_FAILED",
		"SAVE_WRITE_FAILED", "SET_FAILED", "TIMEOUT", "UNKNOWN_CLASS",
		"UNSUPPORTED", "UNSUPPORTED_FILE_TYPE", "WRITE_FAILED",
	]
	for emitted_code in emitted:
		_h.ok(MCPToolkitError.CODES.has(emitted_code),
				"emitted code '%s' present in CODES" % emitted_code)

	# CODES carries no accidental duplicate entry.
	var seen: Dictionary = {}
	var dupes: int = 0
	for entry in MCPToolkitError.CODES:
		var entry_str: String = str(entry)
		if seen.has(entry_str):
			dupes += 1
		seen[entry_str] = true
	_h.eq(dupes, 0, "CODES has no duplicate entries")

	print("")


# --- debug_bridge error-entry shape (concern 033 DRY) -----------------------
# make_error_entry is the single shared constructor for the error-buffer dict
# emitted by the live capture path (debug_bridge), the break fallback, and the
# log-scan fallback (playtest_log_reader). Pins the exact key set + order +
# pass-through so the DRY extraction can't drift any one call site's output.
# In-process call (no JSON/WS boundary), so line/timestamp_ms stay true int.

func _test_make_error_entry() -> void:
	_h.begin("debug_bridge error-entry shape")
	var e := PlaytestLogReader.make_error_entry(123, "msg", "res://a.gd", "f", 7, "error")
	# exact key set, count, and order-of-keys pinned
	_h.eq(e.size(), 6, "entry has exactly 6 keys")
	_h.ok(e.keys() == ["timestamp_ms", "message", "source", "function", "line", "type"],
			"key set + order pinned")
	_h.eq(e["timestamp_ms"], 123, "timestamp_ms passthrough")
	_h.eq(e["message"], "msg", "message passthrough")
	_h.eq(e["source"], "res://a.gd", "source passthrough")
	_h.eq(e["function"], "f", "function passthrough")
	_h.eq(e["line"], 7, "line passthrough")
	_h.eq(e["type"], "error", "type passthrough")
	_h.ok(typeof(e["line"]) == TYPE_INT, "line is int (no JSON float coercion in-process)")
	_h.ok(typeof(e["timestamp_ms"]) == TYPE_INT, "timestamp_ms is int")
	# log-scan variant reproduces Site-2 derivation
	var e2 := PlaytestLogReader.make_error_entry(0, "m2", "", "", 0, "log_scan")
	_h.eq(e2["timestamp_ms"], 0, "log_scan timestamp_ms=0 preserved")
	_h.eq(e2["type"], "log_scan", "log_scan type preserved")

	print("")


# --- Response validation (~6 assertions) ------------------------------------

func _bad_handler_non_dict(_p: Dictionary) -> String:
	return "not a dictionary"

func _bad_handler_no_success(_p: Dictionary) -> Dictionary:
	return {"data": "missing success"}

func _good_handler(_p: Dictionary) -> Dictionary:
	return {"success": true, "data": "ok"}

func _handler_with_hint(_p: Dictionary) -> Dictionary:
	return {"success": true, "hint": "handler hint"}

func _handler_fail(_p: Dictionary) -> Dictionary:
	return {"success": false, "error": "nope", "code": "TEST"}

func _test_response_validation() -> void:
	_h.begin("Response validation")
	var reg := MCPToolkitCommandRegistry.new()

	# 1. Handler returns non-Dictionary → INTERNAL error
	reg.add("rv.bad_type", _bad_handler_non_dict,
			MCPToolkitCommandOptions.new())
	var r1: Dictionary = await reg.call_command("rv.bad_type", {})
	_h.eq(r1["success"], false, "non-Dict handler → success false")
	_h.eq(r1["code"], "INTERNAL", "non-Dict handler → INTERNAL code")

	# 2. Handler returns Dict without success → INTERNAL error
	reg.add("rv.no_success", _bad_handler_no_success,
			MCPToolkitCommandOptions.new())
	var r2: Dictionary = await reg.call_command("rv.no_success", {})
	_h.eq(r2["success"], false, "no-success handler → success false")
	_h.eq(r2["code"], "INTERNAL", "no-success handler → INTERNAL code")

	# 3. Good handler → passes through
	reg.add("rv.good", _good_handler, MCPToolkitCommandOptions.new())
	var r3: Dictionary = await reg.call_command("rv.good", {})
	_h.eq(r3["success"], true, "good handler → success true")
	_h.eq(r3["data"], "ok", "good handler → data preserved")

	# 4. with_success_hint() auto-injection on success
	reg.add("rv.hinted", _good_handler,
			MCPToolkitCommandOptions.new().with_success_hint("Next step"))
	var r4: Dictionary = await reg.call_command("rv.hinted", {})
	_h.eq(r4["hint"], "Next step", "with_success_hint → auto-injected")

	# 5. Handler hint overrides registered hint
	reg.add("rv.override", _handler_with_hint,
			MCPToolkitCommandOptions.new().with_success_hint("Registered"))
	var r5: Dictionary = await reg.call_command("rv.override", {})
	_h.eq(r5["hint"], "handler hint", "handler hint → overrides registered")

	# 6. No injection on success: false
	reg.add("rv.fail", _handler_fail,
			MCPToolkitCommandOptions.new().with_success_hint("Should not appear"))
	var r6: Dictionary = await reg.call_command("rv.fail", {})
	_h.ok(not r6.has("hint") or r6.get("hint", "") != "Should not appear",
			"success:false → no success_hint injection")

	print("")


# --- Response size guard (~9 assertions) ------------------------------------
# guard_response_size() defends against the native WS send rejecting any frame
# whose payload exceeds the peer's outbound buffer (wholesale, no chunking). It
# is pure dict→dict, so the decision is fully exercisable headless; only the
# live-peer send_text return path needs an editor (covered by dispatch-
# integration flows + smoke at Pass 3).

func _test_response_size_guard() -> void:
	_h.begin("Response size guard")

	# A roomy cap so an ordinary response is nowhere near the limit.
	var max_bytes := 65536

	# 1. Under-size response → passed through UNCHANGED (same object identity-wise
	#    in content: jsonrpc, id, and result all intact).
	var small := {"jsonrpc": "2.0", "id": 7, "result": {"success": true, "data": "ok"}}
	var g_small := MCPToolkitError.guard_response_size(small, max_bytes)
	_h.eq(g_small["id"], 7, "under-size → id preserved")
	_h.eq(g_small["result"]["success"], true, "under-size → result unchanged")
	_h.eq(g_small["result"].get("data", ""), "ok", "under-size → result payload intact")

	# 2. Over-size response → replaced with a compact RESPONSE_TOO_LARGE error,
	#    same id + jsonrpc, and the replacement now fits the cap.
	var filler := "x".repeat(max_bytes + 4096)  # comfortably over the cap
	var big := {"jsonrpc": "2.0", "id": 42, "result": {"success": true, "blob": filler}}
	var g_big := MCPToolkitError.guard_response_size(big, max_bytes)
	_h.eq(g_big["id"], 42, "over-size → id preserved")
	_h.eq(g_big["jsonrpc"], "2.0", "over-size → jsonrpc preserved")
	_h.eq(g_big["result"]["success"], false, "over-size → result.success false")
	_h.eq(g_big["result"]["code"], "RESPONSE_TOO_LARGE", "over-size → RESPONSE_TOO_LARGE code")
	_h.ok(MCPToolkitError.response_byte_size(g_big) <= max_bytes,
			"over-size → replacement fits within max_bytes")

	# 3. Boundary: a response sized just BELOW the (max_bytes − margin) threshold
	#    passes; nudging it just ABOVE the threshold trips the guard. This pins the
	#    margin to the documented value rather than an arbitrary cushion.
	var margin := MCPToolkitError._SIZE_GUARD_MARGIN
	# Envelope overhead (jsonrpc+id+result-wrapping+the "p" key) is a few dozen
	# bytes; subtract a safe pad so the filler alone lands us just under threshold.
	var envelope_pad := 64
	var under_len := (max_bytes - margin) - envelope_pad
	var at_threshold := {"jsonrpc": "2.0", "id": 1, "result": {"p": "y".repeat(under_len)}}
	var g_under := MCPToolkitError.guard_response_size(at_threshold, max_bytes)
	_h.ok(g_under["result"].has("p"), "boundary just-under → passes through unchanged")
	# A response OVER (max_bytes − margin) but still UNDER max_bytes itself must
	# trip — proving the margin (not the raw buffer cap) is the live threshold.
	var over_len := (max_bytes - margin) + 1024  # ~62464: above threshold, below cap
	var over_threshold := {"jsonrpc": "2.0", "id": 1, "result": {"p": "y".repeat(over_len)}}
	_h.ok(MCPToolkitError.response_byte_size(over_threshold) < max_bytes,
			"boundary over-case is genuinely under the raw cap")
	var g_over := MCPToolkitError.guard_response_size(over_threshold, max_bytes)
	_h.eq(g_over["result"].get("code", ""), "RESPONSE_TOO_LARGE",
			"boundary over-margin/under-cap → tripped (margin is load-bearing)")

	print("")


# --- UserPathMonitor change detection (~8 assertions) ----------------------
# Godot derives user:// from THREE settings — config/name, use_custom_user_dir,
# and custom_user_dir_name. _on_settings_changed is the detection method: it
# compares all three against the primed cache and re-emits user_path_changed
# when ANY differs. Mutating a key + calling _on_settings_changed directly
# exercises the detection without the editor's settings_changed plumbing.
# Originals are restored so project state (and subsequent tests) are unaffected.

const UserPathMonitor := preload("res://addons/godot_mcp_toolkit/paths/user_path_monitor.gd")

func _test_user_path_monitor() -> void:
	_h.begin("UserPathMonitor change detection")

	# str()/bool() so these infer concrete types, not Variant (this test file is
	# outside addons/, so warnings-as-errors applies here even though it doesn't
	# to the addon source).
	var orig_name := str(ProjectSettings.get_setting("application/config/name", ""))
	var orig_use_custom := bool(ProjectSettings.get_setting("application/config/use_custom_user_dir", false))
	var orig_custom_name := str(ProjectSettings.get_setting("application/config/custom_user_dir_name", ""))

	var monitor := UserPathMonitor.new()
	var fired := [0]
	monitor.user_path_changed.connect(func(): fired[0] += 1)
	# Prime the cache WITHOUT calling start() — start() also subscribes to the
	# live ProjectSettings.settings_changed, which our set_setting() calls below
	# would trigger, double-counting emits. We drive _on_settings_changed
	# directly so each mutation is detected exactly once.
	monitor._cache_settings()

	# 1. No change → no emit.
	monitor._on_settings_changed()
	_h.eq(fired[0], 0, "no change → signal not emitted")

	# 2. config/name change → emit.
	ProjectSettings.set_setting("application/config/name", str(orig_name) + "_renamed")
	monitor._on_settings_changed()
	_h.eq(fired[0], 1, "config/name change → signal emitted")

	# 3. use_custom_user_dir toggle → emit (name unchanged from prior step).
	ProjectSettings.set_setting("application/config/use_custom_user_dir", not bool(orig_use_custom))
	monitor._on_settings_changed()
	_h.eq(fired[0], 2, "use_custom_user_dir toggle → signal emitted")

	# 4. custom_user_dir_name change → emit.
	ProjectSettings.set_setting("application/config/custom_user_dir_name", str(orig_custom_name) + "_dir")
	monitor._on_settings_changed()
	_h.eq(fired[0], 3, "custom_user_dir_name change → signal emitted")

	# 5. Re-check with no further change → no extra emit (cache updated each time).
	monitor._on_settings_changed()
	_h.eq(fired[0], 3, "stable after change → no spurious re-emit")

	# Restore originals so other tests / the project see pristine settings.
	ProjectSettings.set_setting("application/config/name", orig_name)
	ProjectSettings.set_setting("application/config/use_custom_user_dir", orig_use_custom)
	ProjectSettings.set_setting("application/config/custom_user_dir_name", orig_custom_name)

	print("")


# --- Export strip + binary-token warning set (~7 strip + 22 warning) --------

const ExportStrip := preload("res://addons/godot_mcp_toolkit/core/export_strip.gd")

func _test_export_strip() -> void:
	_h.begin("Export strip set")

	# Strip is single-level: only DIRECT subclasses of MCPToolkitExtension
	# (base == "MCPToolkitExtension") are stripped, mirroring the loader's
	# definition of an extension. Path-extends to a direct subclass is flattened
	# by the engine to the same base, so it is covered too.
	var classes := [
		{"class": "MCPToolkitExtension", "base": "RefCounted", "path": "res://addons/godot_mcp_toolkit/extensions/mcp_toolkit_extension.gd"},
		{"class": "DirectExt", "base": "MCPToolkitExtension", "path": "res://a/direct.gd"},
		{"class": "PathDirectExt", "base": "MCPToolkitExtension", "path": "res://e/path_direct.gd"},
		{"class": "ChildExt", "base": "ParentExt", "path": "res://b/child.gd"},
		{"class": "GameThing", "base": "Node", "path": "res://g/game.gd"},
		{"class": "WeirdCs", "base": "MCPToolkitExtension", "path": "res://c/weird.cs"},
		{"class": "FakeChild", "base": "MCPToolkitFake", "path": "res://f/fakechild.gd"},
	]
	var strip: Dictionary = ExportStrip._compute_strip_paths(classes)

	# Direct subclasses (identifier form + path-extends flattened to the same base).
	_h.ok(strip.has("res://a/direct.gd"), "direct subclass → stripped")
	_h.ok(strip.has("res://e/path_direct.gd"), "path-flattened direct subclass → stripped")

	# Multi-level (base is an intermediate, not MCPToolkitExtension) → NOT stripped
	# (single-level by design; such files ship as harmless orphans).
	_h.ok(not strip.has("res://b/child.gd"), "multi-level child → NOT stripped (single-level)")

	# Unrelated game class → not stripped.
	_h.ok(not strip.has("res://g/game.gd"), "unrelated game class → not stripped")

	# .cs excluded by the .gd guard even if its base matched (C# can't be stripped).
	_h.ok(not strip.has("res://c/weird.cs"), ".cs excluded by .gd guard")

	# Base class itself (base RefCounted) → not matched; prefix-stripped at runtime.
	_h.ok(not strip.has("res://addons/godot_mcp_toolkit/extensions/mcp_toolkit_extension.gd"),
			"base class itself → not matched (prefix-stripped at runtime)")

	# Exact base match → no false positive from a coincidentally MCPToolkit*-named
	# class (FakeChild's base is "MCPToolkitFake", not "MCPToolkitExtension").
	_h.ok(not strip.has("res://f/fakechild.gd"),
			"subclass of coincidentally-named MCPToolkit* class → not stripped")

	# ── Binary-token leak warning (Q6) — pure _decide_warning decision ──────
	# args: (saw_addon_script, saw_addon_nonscript, extension_strip_paths, seen_ext)

	# No leak: text mode / 4.2 → addon scripts AND non-scripts reached us; no exts.
	var d_clean: Dictionary = ExportStrip._decide_warning(true, true, {}, {})
	_h.ok(not d_clean["warn"], "all addon files seen (text mode) → no warning")

	# Addon-only leak (binary mode, no extensions): non-scripts seen, scripts gone.
	var d_addon: Dictionary = ExportStrip._decide_warning(false, true, {}, {})
	_h.ok(d_addon["warn"], "addon non-script seen but no script → warn")
	_h.ok(d_addon["addon_leaked"], "addon-only leak → addon_leaked true")
	_h.ok(int(d_addon["leaked_ext_count"]) == 0, "addon-only leak → 0 extensions")
	_h.ok(str(d_addon["message"]).find("Godot MCP Toolkit addon") >= 0, "addon message names the addon")
	# Tail always says "extension path"; the subject clause "N extension script(s)" must be absent.
	_h.ok(str(d_addon["message"]).find("extension script") < 0, "addon-only message omits extension clause")

	# Both leak (binary mode, 1 extension): addon + one unseen extension path.
	var d_both: Dictionary = ExportStrip._decide_warning(false, true, {"res://x/ext.gd": true}, {})
	_h.ok(d_both["warn"], "addon + unseen extension → warn")
	_h.ok(int(d_both["leaked_ext_count"]) == 1, "1 unseen extension counted")
	_h.ok(str(d_both["message"]).find("addon and 1 extension script(s)") >= 0, "message joins addon + 1 extension")
	# REGRESSION: the recipe must list the addon glob AND the explicit extension path.
	_h.ok(str(d_both["message"]).find("res://addons/godot_mcp_toolkit/*") >= 0, "message includes the addon exclude glob")
	_h.ok(str(d_both["message"]).find("res://x/ext.gd") >= 0, "message lists the leaked extension path explicitly")

	# Two leaked extensions → BOTH paths listed (comma-join regression guard).
	var d_two: Dictionary = ExportStrip._decide_warning(false, true, {"res://x/a.gd": true, "res://y/b.gd": true}, {})
	_h.ok(int(d_two["leaked_ext_count"]) == 2, "2 unseen extensions counted")
	_h.ok(d_two["leaked_ext_paths"].size() == 2, "leaked_ext_paths populated")
	_h.ok(str(d_two["message"]).find("2 extension script(s)") >= 0, "subject reports 2 extensions")
	_h.ok(str(d_two["message"]).find("res://x/a.gd") >= 0 and str(d_two["message"]).find("res://y/b.gd") >= 0, "both extension paths listed")

	# Q6 guard: addon already excluded by the user → NO addon file reaches us.
	var d_excluded: Dictionary = ExportStrip._decide_warning(false, false, {}, {})
	_h.ok(not d_excluded["warn"], "addon excluded (no non-script seen) → no false-positive warning")

	# Extension-only leak: addon excluded but an extension still shipped as .gdc.
	var d_ext: Dictionary = ExportStrip._decide_warning(false, false, {"res://x/ext.gd": true}, {})
	_h.ok(d_ext["warn"], "unseen extension alone → warn")
	_h.ok(not d_ext["addon_leaked"], "extension-only leak → addon_leaked false")
	_h.ok(str(d_ext["message"]).find("1 extension script(s)") >= 0, "extension-only message names the extension")
	_h.ok(str(d_ext["message"]).find("res://x/ext.gd") >= 0, "extension-only message lists the path explicitly")
	# Addon not leaked → neither the addon subject phrase nor the addon glob appears.
	_h.ok(str(d_ext["message"]).find("Godot MCP Toolkit addon") < 0, "extension-only message omits addon clause")
	_h.ok(str(d_ext["message"]).find("res://addons/godot_mcp_toolkit/*") < 0, "extension-only message omits addon glob")

	# Extension seen (text mode for the extension) → not counted as leaked.
	var d_ext_seen: Dictionary = ExportStrip._decide_warning(true, true, {"res://x/ext.gd": true}, {"res://x/ext.gd": true})
	_h.ok(not d_ext_seen["warn"], "extension seen (stripped) → no warning")

	print("")


# --- editor.refresh reload filter (Fix, 41l-tricies) -----------------------
# should_reload_open_script: reload only scan-changed, non-toolkit open scripts.
# Pins the fix against a regression back to "reload all open scripts" (which
# cancels suspended coroutines → the C1/C3 crash class).

func _test_editor_refresh_reload_filter() -> void:
	_h.begin("editor.refresh reload filter")
	var changed := {
		"res://game/player.gd": true,
		"res://addons/godot_mcp_toolkit/commands/scene_commands.gd": true,
	}
	# 1. changed user script → reload
	_h.ok(EditorRescan.should_reload_open_script("res://game/player.gd", changed),
			"changed user script → reload")
	# 2. unchanged user script → skip
	_h.ok(not EditorRescan.should_reload_open_script("res://game/enemy.gd", changed),
			"unchanged user script → skip")
	# 3. toolkit's own script, even if scan-changed → skip (never self-reload)
	_h.ok(not EditorRescan.should_reload_open_script(
			"res://addons/godot_mcp_toolkit/commands/scene_commands.gd", changed),
			"toolkit-own changed script → skip (never self-reload)")
	# 4. unchanged toolkit script → skip
	_h.ok(not EditorRescan.should_reload_open_script(
			"res://addons/godot_mcp_toolkit/transport/mcp_server.gd", changed),
			"unchanged toolkit script → skip")
	print("")


# --- Unfocused-sleep backup (41l-duotricies) -------------------------------
# Machine-wide crash-safe restore of the global unfocused frame-rate setting.
# The editor-coupled get/set EditorSettings calls live in mcp_server.gd (covered
# by interactive verification); the conflict-resolution + first-writer-wins +
# both-values-stored logic is pure and headless-testable here against a temp dir.

func _test_unfocused_backup() -> void:
	_h.begin("Unfocused-sleep backup")
	var dir := ProjectSettings.globalize_path("user://_mcp_unfocused_backup_test")
	DirAccess.make_dir_recursive_absolute(dir)
	var ver := "9.9"  # fixed test key + temp dir → isolated from any real backup
	UnfocusedBackup.delete_backup(dir, ver)  # clean slate

	# should_capture_boost — opt-out + idempotency gate (the "no-op when off" unit).
	_h.ok(UnfocusedBackup.should_capture_boost(true, false),
			"should_capture_boost(on, idle) → true")
	_h.ok(not UnfocusedBackup.should_capture_boost(false, false),
			"should_capture_boost(off, idle) → false (no-op when off)")
	_h.ok(not UnfocusedBackup.should_capture_boost(true, true),
			"should_capture_boost(on, already active) → false (idempotent)")

	# 1. capture_if_absent writes when no backup exists (first-writer-wins).
	_h.ok(UnfocusedBackup.capture_if_absent(dir, 100000, 16666, ver),
			"first capture → writes backup (true)")
	_h.ok(UnfocusedBackup.has_backup(dir, ver), "backup file exists after capture")

	# 2. backup stores BOTH original and boosted.
	var b: Dictionary = UnfocusedBackup.read_backup(dir, ver)
	_h.eq(b.get("original", -1), 100000, "backup stores original")
	_h.eq(b.get("boosted", -1), 16666, "backup stores boosted")

	# 3. second capture does NOT overwrite (first-writer-wins).
	_h.ok(not UnfocusedBackup.capture_if_absent(dir, 33333, 8333, ver),
			"second capture → does not overwrite (false)")
	var b2: Dictionary = UnfocusedBackup.read_backup(dir, ver)
	_h.eq(b2.get("original", -1), 100000, "original preserved after second capture")
	_h.eq(b2.get("boosted", -1), 16666, "boosted preserved after second capture")

	# 4. resolve_restore: current == boosted → restore the true original (self-heal A).
	var d1: Dictionary = UnfocusedBackup.resolve_restore(16666, b2)
	_h.ok(d1["restore"], "current == boosted → restore true")
	_h.eq(d1["value"], 100000, "current == boosted → value is the original")

	# 5. resolve_restore: current != boosted → keep current, conflict-aware (self-heal B).
	var d2: Dictionary = UnfocusedBackup.resolve_restore(50000, b2)
	_h.ok(not d2["restore"], "current != boosted → restore false (kept)")
	_h.eq(d2["value"], 50000, "current != boosted → value echoes current")

	# 6. resolve_restore: empty / malformed backup → no-op.
	_h.ok(not UnfocusedBackup.resolve_restore(16666, {})["restore"],
			"empty backup → restore false")
	_h.ok(not UnfocusedBackup.resolve_restore(16666, {"original": 100000})["restore"],
			"backup missing 'boosted' → restore false")

	# 7. delete_backup removes the file; read on missing → empty dict.
	UnfocusedBackup.delete_backup(dir, ver)
	_h.ok(not UnfocusedBackup.has_backup(dir, ver), "delete_backup → file gone")
	_h.eq(UnfocusedBackup.read_backup(dir, ver), {}, "read missing backup → empty dict")

	# 8. version_key derives "<major>.<minor>" (override form).
	_h.eq(UnfocusedBackup.version_key({"major": 4, "minor": 2}), "4.2",
			"version_key({4,2}) → '4.2'")

	DirAccess.remove_absolute(dir)  # cleanup
	print("")


# --- Stale-live-instance hint (41m-bis-bis) --------------------------------
# Pure decision predicates + message builders + on-disk helpers for the
# stale-live-instance method-call hazard. The editor-coupled callers
# (script_commands.gd proactive at script.write, node_commands.gd reactive at
# INVALID_METHOD) read the running version + on-disk source and feed these.
# Boundary: STALE on Godot < 4.4 (minor 2,3), live on 4.4+ (minor 4,5,6) —
# empirically characterised across 4.2-4.6 (boundary 4.3->4.4); see
# Insights/stale-live-instance-method-hazard.md + test/flows/02_*.

const StaleInstanceHint := preload("res://addons/godot_mcp_toolkit/versioning/stale_instance_hint.gd")

func _test_stale_instance_hint() -> void:
	_h.begin("Stale-instance hint")

	# should_warn_on_write(existed, compiled_ok, extension, major, minor) — proactive gate
	_h.ok(StaleInstanceHint.should_warn_on_write(true, true, "gd", 4, 2),
			"write: existing .gd compiled on 4.2 → warn")
	_h.ok(StaleInstanceHint.should_warn_on_write(true, true, "gd", 4, 3),
			"write: existing .gd compiled on 4.3 → warn")
	_h.ok(not StaleInstanceHint.should_warn_on_write(true, true, "gd", 4, 4),
			"write: 4.4 → no warn (hot-reloads)")
	_h.ok(not StaleInstanceHint.should_warn_on_write(true, true, "gd", 4, 5),
			"write: 4.5 → no warn")
	_h.ok(not StaleInstanceHint.should_warn_on_write(true, true, "gd", 4, 6),
			"write: 4.6 → no warn")
	_h.ok(not StaleInstanceHint.should_warn_on_write(false, true, "gd", 4, 3),
			"write: create (new file) → no warn")
	_h.ok(not StaleInstanceHint.should_warn_on_write(true, false, "gd", 4, 3),
			"write: compile-failed → no warn (Scenario C gate)")
	_h.ok(not StaleInstanceHint.should_warn_on_write(true, true, "cs", 4, 3),
			"write: .cs → no warn (out of scope)")
	_h.ok(not StaleInstanceHint.should_warn_on_write(true, true, "gdshader", 4, 2),
			"write: .gdshader → no warn")
	_h.ok(not StaleInstanceHint.should_warn_on_write(true, true, "gd", 5, 0),
			"should_warn_on_write: Godot 5.0 does not warn — gate is major-aware")

	# should_hint_on_call(has_method, disk_has_method, disk_compiles, is_gd, major, minor)
	_h.ok(StaleInstanceHint.should_hint_on_call(false, true, true, true, 4, 3),
			"call: stale method on 4.3 → hint")
	_h.ok(StaleInstanceHint.should_hint_on_call(false, true, true, true, 4, 2),
			"call: stale method on 4.2 → hint")
	_h.ok(not StaleInstanceHint.should_hint_on_call(false, true, true, true, 4, 4),
			"call: 4.4 → no hint")
	_h.ok(not StaleInstanceHint.should_hint_on_call(false, false, true, true, 4, 3),
			"call: method absent on disk (typo) → no hint")
	_h.ok(not StaleInstanceHint.should_hint_on_call(false, true, false, true, 4, 3),
			"call: disk doesn't compile → no hint (Option B)")
	_h.ok(not StaleInstanceHint.should_hint_on_call(true, true, true, true, 4, 3),
			"call: has_method true → no hint")
	_h.ok(not StaleInstanceHint.should_hint_on_call(false, true, true, false, 4, 3),
			"call: non-.gd script → no hint")
	_h.ok(not StaleInstanceHint.should_hint_on_call(false, true, true, true, 5, 0),
			"should_hint_on_call: Godot 5.0 does not hint — gate is major-aware")

	# source_compiles — safe GDScript.new().reload() parse (class_name stripped)
	_h.ok(StaleInstanceHint.source_compiles("extends Node\nfunc a() -> int:\n\treturn 1\n"),
			"source_compiles: valid GDScript → true")
	_h.ok(not StaleInstanceHint.source_compiles("extends Node\nvar = = =\n"),
			"source_compiles: broken GDScript → false")
	_h.ok(StaleInstanceHint.source_compiles("class_name FooProbe9\nextends Node\nfunc a():\n\tpass\n"),
			"source_compiles: class_name script → true (no false collision)")

	# source_has_method — line scan, word-exact, string/comment safe
	_h.ok(StaleInstanceHint.source_has_method("func foo():\n\tpass", "foo"),
			"source_has_method: func foo → true")
	_h.ok(StaleInstanceHint.source_has_method("static func bar() -> int:\n\treturn 1", "bar"),
			"source_has_method: static func bar → true")
	_h.ok(not StaleInstanceHint.source_has_method("func foo():\n\tpass", "baz"),
			"source_has_method: absent method → false")
	_h.ok(not StaleInstanceHint.source_has_method("func foo_bar():\n\tpass", "foo"),
			"source_has_method: foo_bar not matched by foo (word-exact)")
	_h.ok(StaleInstanceHint.source_has_method("\tfunc inner():\n\t\tpass", "inner"),
			"source_has_method: indented inner method → true")
	_h.ok(not StaleInstanceHint.source_has_method("var x = \"func ghost(\"", "ghost"),
			"source_has_method: 'func' inside a string → false")
	_h.ok(not StaleInstanceHint.source_has_method("func foo():\n\tpass", ""),
			"source_has_method: empty method → false")

	# recovery_message — names the version, covers bodies+added, relaunch + fresh-node
	var msg := StaleInstanceHint.recovery_message("4.3")
	_h.ok(msg.contains("4.3"), "recovery_message: names the version")
	_h.ok(msg.contains("relaunch"), "recovery_message: recommends relaunch")
	_h.ok(msg.contains("fresh node"), "recovery_message: notes a fresh node doesn't help")
	_h.ok(msg.contains("changed method bodies") and msg.contains("added members"),
			"recovery_message: covers changed bodies AND added members")

	# write_hint — validation guidance FIRST, stale nudge in the recency slot (Q3)
	var wh := StaleInstanceHint.write_hint("4.2")
	_h.ok(wh.begins_with("Validate"), "write_hint: validation guidance leads")
	_h.ok(wh.contains("script_check"), "write_hint: mentions script_check")
	_h.ok(wh.find("Validate") < wh.find("relaunch"),
			"write_hint: validation before stale nudge (recency ordering)")
	_h.ok(wh.contains("4.2"), "write_hint: carries the version label")

	print("")


# --- Report ----------------------------------------------------------------

# --- 41m-quinquies: scene.spatial_map geometry ----------------------------
func _test_spatial_map() -> void:
	_h.begin("scene.spatial_map (geometry)")

	# _world_bounds dispatch by node type. Nodes stay parentless so global ==
	# local transform (headless has no initialised World3D for a tree-parented
	# Node3D; real tree behaviour is covered by interactive smoke/sweep).
	var n3 := Node3D.new()
	n3.position = Vector3(1, 2, 3)
	var b3 = SpatialCommands._world_bounds(n3)
	_h.ok(typeof(b3) == TYPE_AABB, "Node3D → AABB")
	_h.ok(b3.size == Vector3.ZERO, "Node3D → point AABB (zero size; world pos via interactive)")
	n3.free()

	var n2 := Node2D.new()
	n2.position = Vector2(5, 6)
	var b2 = SpatialCommands._world_bounds(n2)
	_h.ok(typeof(b2) == TYPE_RECT2, "Node2D → Rect2")
	_h.ok(b2.position == Vector2(5, 6), "Node2D Rect2 at global_position")
	n2.free()

	var ctrl := Control.new()
	ctrl.position = Vector2(10, 10)
	ctrl.size = Vector2(20, 30)
	var bc = SpatialCommands._world_bounds(ctrl)
	_h.ok(typeof(bc) == TYPE_RECT2, "Control → Rect2")
	_h.ok(bc.size == Vector2(20, 30), "Control Rect2 size from get_global_rect")
	ctrl.free()

	var plain := Node.new()
	_h.ok(SpatialCommands._world_bounds(plain) == null, "plain Node → null (non-spatial)")
	plain.free()

	# _xform_rect2 / _xform_aabb world-space transform.
	_h.ok(SpatialCommands._xform_rect2(Transform2D.IDENTITY, Rect2(0, 0, 10, 10)) == Rect2(0, 0, 10, 10),
		"_xform_rect2 identity → same")
	var rt = SpatialCommands._xform_rect2(Transform2D(0.0, Vector2(5, 5)), Rect2(0, 0, 10, 10))
	_h.ok(rt.position == Vector2(5, 5) and rt.size == Vector2(10, 10), "_xform_rect2 translate")
	_h.ok(SpatialCommands._xform_aabb(Transform3D.IDENTITY, AABB(Vector3.ZERO, Vector3(2, 2, 2)))
		== AABB(Vector3.ZERO, Vector3(2, 2, 2)), "_xform_aabb identity → same")

	# _compute_relations: overlap + containment + nearest (full).
	var entries := [
		{"path": "a", "bounds": Rect2(0, 0, 10, 10)},
		{"path": "b", "bounds": Rect2(5, 5, 10, 10)},
		{"path": "c", "bounds": Rect2(100, 100, 5, 5)},
		{"path": "d", "bounds": Rect2(2, 2, 3, 3)},
	]
	SpatialCommands._compute_relations(entries, "full")
	_h.ok(entries[0]["overlaps"].has("b"), "overlap a-b detected")
	_h.ok(not entries[0]["overlaps"].has("c"), "no overlap a-c (disjoint)")
	_h.ok(entries[0]["contains"].has("d"), "containment a contains d")
	_h.ok(entries[3]["contained_by"].has("a"), "containment d contained_by a")
	_h.ok(entries[0].has("nearest"), "nearest neighbour computed (full)")

	# 2D and 3D never relate.
	var mixed := [
		{"path": "p2", "bounds": Rect2(0, 0, 10, 10)},
		{"path": "p3", "bounds": AABB(Vector3.ZERO, Vector3(10, 10, 10))},
	]
	SpatialCommands._compute_relations(mixed, "normal")
	_h.ok(mixed[0]["overlaps"].is_empty(), "2D node never overlaps 3D node")

	# Region parsing + filtering.
	_h.ok(typeof(SpatialCommands._parse_region([0, 0, 10, 10])) == TYPE_RECT2, "_parse_region 4 nums → Rect2")
	_h.ok(typeof(SpatialCommands._parse_region([0, 0, 0, 1, 1, 1])) == TYPE_AABB, "_parse_region 6 nums → AABB")
	_h.ok(SpatialCommands._parse_region([1, 2, 3]).has("error"), "_parse_region bad size → error")
	_h.ok(SpatialCommands._parse_region(null) == null, "_parse_region null → null")
	_h.ok(SpatialCommands._passes_filters(Rect2(0, 0, 5, 5), Rect2(0, 0, 10, 10), null),
		"region: 2D node inside → pass")
	_h.ok(not SpatialCommands._passes_filters(Rect2(0, 0, 5, 5), AABB(Vector3.ZERO, Vector3.ONE), null),
		"region: 3D region excludes 2D node")

	# Serialization.
	_h.eq(SpatialCommands._vec_to_array(Vector2(1, 2)), [1.0, 2.0], "_vec_to_array Vector2")
	_h.eq(SpatialCommands._vec_to_array(Vector3(1, 2, 3)), [1.0, 2.0, 3.0], "_vec_to_array Vector3")


# --- 41m-quinquies: texture.generate pixels + colour ----------------------
func _test_texture_generate() -> void:
	_h.begin("texture.generate (pixels + colour)")

	# _parse_color (hex / named, 0-1 vs 0-255 arrays, alpha-absent).
	_h.ok(TextureCommands._parse_color(null, Color(0.5, 0.5, 0.5, 1)) == Color(0.5, 0.5, 0.5, 1),
		"_parse_color null → default")
	var c_hex = TextureCommands._parse_color("#ff0000", Color.BLACK)
	_h.ok(c_hex.r > 0.99 and c_hex.g < 0.01 and c_hex.b < 0.01, "_parse_color #ff0000 → red")
	_h.ok(TextureCommands._parse_color([0, 255, 0], Color.BLACK).g > 0.99, "_parse_color [0,255,0] → green (0-255)")
	_h.ok(TextureCommands._parse_color([0, 0, 1], Color.BLACK).b > 0.99, "_parse_color [0,0,1] → blue (0-1)")
	_h.ok(TextureCommands._parse_color([0, 0, 0, 0], Color.WHITE).a == 0.0,
		"_parse_color [0,0,0,0] → transparent (alpha-absent)")

	# _in_shape inside/outside.
	_h.ok(TextureCommands._in_shape("solid", 8, 8, 16, 16, "up", 0), "solid: center inside")
	_h.ok(TextureCommands._in_shape("circle", 8, 8, 16, 16, "up", 0), "circle: center inside")
	_h.ok(not TextureCommands._in_shape("circle", 0, 0, 16, 16, "up", 0), "circle: corner outside")
	_h.ok(TextureCommands._in_shape("diamond", 8, 8, 16, 16, "up", 0), "diamond: center inside")
	_h.ok(not TextureCommands._in_shape("diamond", 0, 0, 16, 16, "up", 0), "diamond: corner outside")
	_h.ok(TextureCommands._in_shape("triangle", 8, 14, 16, 16, "up", 0), "triangle(up): bottom-center inside")
	_h.ok(not TextureCommands._in_shape("triangle", 1, 1, 16, 16, "up", 0), "triangle(up): top-corner outside")

	var red := Color(1, 0, 0, 1)
	var blue := Color(0, 0, 1, 1)
	var clear := Color(0, 0, 0, 0)

	# Solid fill covers everything.
	var solid := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	solid.fill(clear)
	TextureCommands._draw_shape(solid, "solid", red, clear, 0, clear, 4, "right")
	_h.ok(solid.get_pixel(8, 8) == red, "solid fill: center red")
	_h.ok(solid.get_pixel(0, 0) == red, "solid fill: corner red (covers all)")

	# Circle fill on transparent background.
	var circ := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	circ.fill(clear)
	TextureCommands._draw_shape(circ, "circle", red, clear, 0, clear, 4, "right")
	_h.ok(circ.get_pixel(8, 8) == red, "circle fill: center red")
	_h.ok(circ.get_pixel(0, 0).a == 0.0, "circle: corner transparent (background)")

	# Hollow shape: transparent fill + opaque outline → interior clear, band is outline.
	var hollow := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	hollow.fill(clear)
	TextureCommands._draw_shape(hollow, "solid", clear, blue, 2, clear, 4, "right")
	_h.ok(hollow.get_pixel(0, 0) == blue, "hollow solid: border blue (outline band)")
	_h.ok(hollow.get_pixel(8, 8).a == 0.0, "hollow solid: interior transparent (no fill)")

	# Checkerboard alternates fill / background.
	var checker := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	checker.fill(clear)
	TextureCommands._draw_shape(checker, "checkerboard", red, clear, 0, clear, 8, "right")
	_h.ok(checker.get_pixel(0, 0) == red, "checkerboard: cell (0,0) fill")
	_h.ok(checker.get_pixel(8, 0).a == 0.0, "checkerboard: cell (1,0) background")


# --- 41n/034 C1: particles.create _PROP_SPEC / _apply_props ----------------
# Pins the data-driven property applier that replaced pass 7's if-ladder. The
# load-bearing contract is the RETURNED count (== properties_set delta) plus the
# exact value + cast landing on the node / material. ParticleProcessMaterial and
# GPUParticles2D are not editor-only, so this runs headless.
func _test_particle_prop_apply() -> void:
	_h.begin("particles _apply_props (_PROP_SPEC)")

	# --- All 15 uniform props present → count 15, every value lands + cast.
	# Scalars deliberately arrive in the "wrong" numeric type to pin the cast:
	# amount as a float (→ int), spread as an int (→ float), one_shot as int 1
	# (→ bool true). Vectors/colour are pre-built (RAW direct-assign, no recast).
	var node_all := GPUParticles2D.new()
	var mat_all := ParticleProcessMaterial.new()
	var dir := Vector3(0, -1, 0)
	var grav := Vector3(0, 49, 0)
	var box := Vector3(100, 50, 0)
	var col := Color(0.2, 0.4, 0.6, 0.8)
	var eff_all := {
		"amount": 24.0,  # float in → int out
		"lifetime": 1.5,
		"explosiveness": 0.5,
		"speed_scale": 2.0,
		"one_shot": 1,  # int in → bool out
		"local_coords": true,
		"direction": dir,
		"spread": 30,  # int in → float out
		"gravity": grav,
		"color": col,
		"particle_flag_align_y": true,
		"emission_sphere_radius": 12.0,
		"emission_box_extents": box,
		"turbulence_enabled": true,
		"turbulence_noise_strength": 0.75,
	}
	var n_all := ParticleCommands._apply_props(node_all, mat_all, eff_all)
	_h.eq(n_all, 15, "all 15 props present → count 15")

	# Node group values + casts.
	_h.eq(node_all.amount, 24, "amount float 24.0 → int 24")
	_h.ok(typeof(node_all.amount) == TYPE_INT, "amount cast to int")
	_h.ok(is_equal_approx(node_all.lifetime, 1.5), "lifetime → 1.5")
	_h.ok(is_equal_approx(node_all.explosiveness, 0.5), "explosiveness → 0.5")
	_h.ok(is_equal_approx(node_all.speed_scale, 2.0), "speed_scale → 2.0")
	_h.eq(node_all.one_shot, true, "one_shot int 1 → bool true")
	_h.eq(node_all.local_coords, true, "local_coords → true")

	# Material group values + casts.
	_h.eq(mat_all.direction, dir, "direction → Vector3 (raw assign)")
	_h.ok(is_equal_approx(mat_all.spread, 30.0), "spread int 30 → float 30.0")
	_h.eq(mat_all.gravity, grav, "gravity → Vector3 (raw assign)")
	_h.eq(mat_all.color, col, "color → Color (raw assign)")
	_h.eq(mat_all.particle_flag_align_y, true, "particle_flag_align_y → true")
	_h.ok(is_equal_approx(mat_all.emission_sphere_radius, 12.0), "emission_sphere_radius → 12.0")
	_h.eq(mat_all.emission_box_extents, box, "emission_box_extents → Vector3 (raw assign)")
	_h.eq(mat_all.turbulence_enabled, true, "turbulence_enabled → true")
	_h.ok(is_equal_approx(mat_all.turbulence_noise_strength, 0.75), "turbulence_noise_strength → 0.75")
	node_all.free()

	# --- No props present → count 0, nothing written (props keep defaults).
	var node_none := GPUParticles2D.new()
	var mat_none := ParticleProcessMaterial.new()
	var amount_default := node_none.amount
	var spread_default := mat_none.spread
	_h.eq(ParticleCommands._apply_props(node_none, mat_none, {}), 0, "empty eff → count 0")
	_h.eq(node_none.amount, amount_default, "empty eff → amount untouched")
	_h.eq(mat_none.spread, spread_default, "empty eff → spread untouched")
	node_none.free()

	# --- Subset (1 node + 2 material) → count 3, only those land.
	var node_sub := GPUParticles2D.new()
	var mat_sub := ParticleProcessMaterial.new()
	var n_sub := ParticleCommands._apply_props(node_sub, mat_sub, {
		"lifetime": 3.0,
		"spread": 45.0,
		"turbulence_enabled": true,
	})
	_h.eq(n_sub, 3, "subset of 3 → count 3")
	_h.ok(is_equal_approx(node_sub.lifetime, 3.0), "subset: lifetime landed")
	_h.ok(is_equal_approx(mat_sub.spread, 45.0), "subset: spread landed")
	_h.eq(mat_sub.turbulence_enabled, true, "subset: turbulence_enabled landed")
	# A prop absent from the subset eff must NOT have been counted/written.
	_h.eq(node_sub.amount, node_none.amount, "subset: absent amount stays default")
	node_sub.free()


# --- 41n/034 C2: particles.create _OVERRIDE_SPEC / _merge_overrides --------
# Pins the data-driven override merge that replaced pass 6's match-ladder. The
# load-bearing contracts are (a) the merged eff values + casts and (b) the RETURNED
# overrides_applied array — its CONTENTS and ORDER are part of the particles.create
# response. Pure dict→dict logic, so this runs headless (no node, no editor).
func _test_particle_merge_overrides() -> void:
	_h.begin("particles _merge_overrides (_OVERRIDE_SPEC)")

	# --- Preset-only (no params) → eff unchanged, overrides empty.
	var fire: Dictionary = ParticleCommands._PRESETS["fire"].duplicate(true)
	var eff_pre: Dictionary = fire.duplicate(true)
	var ov_none := ParticleCommands._merge_overrides(eff_pre, {})
	_h.eq(ov_none.size(), 0, "no params → overrides_applied empty")
	_h.eq(eff_pre, fire, "no params → eff identical to preset")

	# --- Subset shadowing the preset → values + casts land, overrides in order.
	# fire has amount, spread, initial_velocity_min → all three shadow. params arrive
	# in the "wrong" numeric type to pin the cast (amount float→int, spread int→float).
	var eff_sub: Dictionary = fire.duplicate(true)
	var ov_sub := ParticleCommands._merge_overrides(eff_sub, {
		"amount": 99.0,  # float in → int out
		"spread": 5,  # int in → float out
		"initial_velocity": {"min": 1.0, "max": 2.0},
	})
	# _OVERRIDE_SPEC order puts amount before spread; range params append after.
	_h.eq(ov_sub, ["amount", "spread", "initial_velocity"], "shadowing overrides in contract order")
	_h.eq(eff_sub["amount"], 99, "amount float 99.0 → int 99")
	_h.ok(typeof(eff_sub["amount"]) == TYPE_INT, "amount cast to int")
	_h.ok(is_equal_approx(eff_sub["spread"], 5.0), "spread int 5 → float 5.0")
	_h.ok(is_equal_approx(eff_sub["initial_velocity_min"], 1.0), "range min landed")
	_h.ok(is_equal_approx(eff_sub["initial_velocity_max"], 2.0), "range max landed")

	# --- Vector/colour coercion (the merge VEC3/COLOR modes, distinct from apply RAW).
	var eff_vec := {}
	var ov_vec := ParticleCommands._merge_overrides(eff_vec, {
		"direction": {"x": 0.0, "y": -1.0, "z": 0.0},
		"color": {"r": 0.2, "g": 0.4, "b": 0.6, "a": 0.8},
		"gravity": {"x": 0.0, "y": 49.0, "z": 0.0},
	})
	_h.eq(ov_vec.size(), 0, "no preset → vec/colour applied but nothing shadowed")
	_h.eq(eff_vec["direction"], Vector3(0, -1, 0), "direction dict → Vector3")
	_h.eq(eff_vec["color"], Color(0.2, 0.4, 0.6, 0.8), "color dict → Color")
	_h.eq(eff_vec["gravity"], Vector3(0, 49, 0), "gravity dict → Vector3")

	# --- No preset → values written to eff but NONE appended (no shadow); range as
	# a bare scalar fans into _min/_max; an absent key never appears.
	var eff_np := {}
	var ov_np := ParticleCommands._merge_overrides(eff_np, {
		"amount": 7,
		"scale_range": 2.0,  # bare scalar → min == max
	})
	_h.eq(ov_np.size(), 0, "empty eff → nothing shadowed → overrides empty")
	_h.eq(eff_np["amount"], 7, "no-preset: amount still written to eff")
	_h.ok(is_equal_approx(eff_np["scale_min"], 2.0), "scalar range → scale_min")
	_h.ok(is_equal_approx(eff_np["scale_max"], 2.0), "scalar range → scale_max == min")
	_h.ok(not eff_np.has("lifetime"), "absent param never written")

	# --- Cross-sub-pass ORDER pin: simple + range + emission against an eff that
	# holds all three preset keys → array order is [simple, range, emission].
	var eff_ord := {"color": Color.WHITE, "scale_min": 0.5, "emission_shape": "point"}
	var ov_ord := ParticleCommands._merge_overrides(eff_ord, {
		"emission_shape": "box",
		"scale_range": {"min": 1.0, "max": 3.0},
		"color": {"r": 1.0, "g": 0.0, "b": 0.0, "a": 1.0},
	})
	_h.eq(ov_ord, ["color", "scale_range", "emission_shape"], "order: simple → range → emission")
	_h.eq(eff_ord["emission_shape"], "box", "emission_shape override landed (name kept)")


# --- 41m-quinquies: sound.generate synthesis ------------------------------
func _test_sound_generate() -> void:
	_h.begin("sound.generate (synth)")

	# _oscillator waveforms.
	_h.ok(abs(SoundCommands._oscillator("sine", 0.0)) < 0.001, "sine(0) approx 0")
	_h.ok(SoundCommands._oscillator("sine", PI / 2.0) > 0.99, "sine(pi/2) approx 1")
	_h.ok(SoundCommands._oscillator("square", 0.5) == 1.0, "square(+) = 1")
	_h.ok(SoundCommands._oscillator("square", PI + 0.5) == -1.0, "square(-) = -1")
	_h.ok(SoundCommands._oscillator("sawtooth", 0.0) < -0.99, "sawtooth(0) approx -1")
	_h.ok(SoundCommands._oscillator("triangle", PI / 2.0) > 0.99, "triangle(pi/2) approx 1")

	# _build_pcm length + content (mono 16-bit @ 44100).
	var pcm := SoundCommands._build_pcm("sine", 440.0, 440.0, false, 0.1, 0.8, 0.003, 0.003, 0.0)
	var expected_samples := int(0.1 * 44100)
	_h.eq(pcm.size(), expected_samples * 2, "_build_pcm byte length = samples*2 (16-bit mono)")
	var mid := expected_samples / 2
	var found_nonzero := false
	for i in range(mid, mini(mid + 120, expected_samples)):
		if pcm.decode_s16(i * 2) != 0:
			found_nonzero = true
			break
	_h.ok(found_nonzero, "_build_pcm sine non-silent in sustain")

	# volume 0 → silence.
	var silent := SoundCommands._build_pcm("sine", 440.0, 440.0, false, 0.05, 0.0, 0.0, 0.0, 0.0)
	var all_zero := true
	for i in range(silent.size() / 2):
		if silent.decode_s16(i * 2) != 0:
			all_zero = false
			break
	_h.ok(all_zero, "_build_pcm volume 0 → silence")

	# noise varies sample-to-sample.
	var noise := SoundCommands._build_pcm("noise", 440.0, 440.0, false, 0.05, 0.8, 0.0, 0.0, 0.0)
	var distinct := {}
	for i in range(mini(50, noise.size() / 2)):
		distinct[noise.decode_s16(i * 2)] = true
	_h.ok(distinct.size() > 5, "_build_pcm noise varies sample-to-sample")


# --- resolve_create_collision (concern 017) -------------------------------
# Pure decision query shared by the file creators (scene.create, asset.import,
# texture/sound.generate). Validates if_exists, stats the destination, returns
# the {valid, existed, action} DECISION — no payload, no write. Editor-free:
# FileAccess.file_exists sees user:// paths, so existence cases use a temp file.
func _test_create_collision_resolver() -> void:
	_h.begin("resolve_create_collision (concern 017)")

	# A guaranteed-absent res:// path (randomised to dodge any stray fixture).
	var absent := "res://__nope_%d.png" % (randi() % 1_000_000)

	# Not-exists: every legal if_exists short-circuits to action "create".
	var c_create := Helpers.resolve_create_collision(absent, "return")
	_h.eq(c_create.get("valid"), true, "absent + return → valid")
	_h.eq(c_create.get("existed"), false, "absent + return → existed false")
	_h.eq(c_create.get("action"), "create", "absent + return → action create")
	_h.eq(Helpers.resolve_create_collision(absent, "fail").get("action"), "create",
		"absent + fail → action create (value irrelevant when absent)")
	_h.eq(Helpers.resolve_create_collision(absent, "replace").get("action"), "create",
		"absent + replace → action create")

	# Invalid if_exists → {valid:false} (no existence read needed).
	_h.eq(Helpers.resolve_create_collision(absent, "clobber").get("valid"), false,
		"invalid value 'clobber' → valid false")
	_h.eq(Helpers.resolve_create_collision(absent, "").get("valid"), false,
		"empty value → valid false")
	_h.eq(Helpers.resolve_create_collision(absent, "Return").get("valid"), false,
		"wrong-case 'Return' → valid false (exact-case match)")

	# Exists: write a temp file under user://, assert the action == if_exists, clean up.
	var present := "user://__collision_test_%d.tmp" % (randi() % 1_000_000)
	var f := FileAccess.open(present, FileAccess.WRITE)
	if f == null:
		_h.ok(false, "could not open temp file for existence cases — SKIPPED exists path")
	else:
		f.store_string("x")
		f.close()

		var c_return := Helpers.resolve_create_collision(present, "return")
		_h.eq(c_return.get("valid"), true, "exists + return → valid")
		_h.eq(c_return.get("existed"), true, "exists + return → existed true")
		_h.eq(c_return.get("action"), "return", "exists + return → action return")
		_h.eq(Helpers.resolve_create_collision(present, "fail").get("action"), "fail",
			"exists + fail → action fail")
		_h.eq(Helpers.resolve_create_collision(present, "replace").get("action"), "replace",
			"exists + replace → action replace")

		# Validation precedes existence: invalid value while the file exists is
		# still {valid:false} — locks that the value check runs before the stat.
		_h.eq(Helpers.resolve_create_collision(present, "nope").get("valid"), false,
			"exists + invalid value → valid false (validation precedes existence)")

		DirAccess.remove_absolute(ProjectSettings.globalize_path(present))


# --- summarize_batch (batch partial-failure rollup) -----------------------
# Pure response shaper: rolls a per-entry results[] up into a top-level failed
# count + hint, additively (all-success batches stay byte-identical). The failure
# predicate is shape-tolerant so it serves both batch conventions: {success:bool}
# (node.set_property batch) AND {status?, error?} with no success key (node.groups
# batch). Pure → pinned here with hand-built dicts, no editor.
func _test_summarize_batch() -> void:
	_h.begin("summarize_batch batch partial-failure rollup")

	# All-success {success:true} → UNCHANGED (no failed, no hint added).
	var all_ok := {"results": [{"success": true}, {"success": true}], "count": 2}
	var r_all_ok := Helpers.summarize_batch(all_ok, "results")
	_h.ok(not r_all_ok.has("failed"), "all-success → no failed key (additive: unchanged)")
	_h.ok(not r_all_ok.has("hint"), "all-success → no hint key")
	_h.eq(r_all_ok.get("count"), 2, "all-success → pre-existing keys preserved")

	# 1-of-3 {success:false} → failed=1 + hint naming results[].
	var one_fail := {"results": [
		{"success": true}, {"success": false, "error": "boom"}, {"success": true}]}
	var r_one_fail := Helpers.summarize_batch(one_fail, "results")
	_h.eq(r_one_fail.get("failed"), 1, "1-of-3 success:false → failed=1")
	_h.ok(str(r_one_fail.get("hint", "")).contains("1 of 3"), "hint reports 1 of 3")
	_h.ok(str(r_one_fail.get("hint", "")).contains("results[]"), "hint steers to results[]")

	# Site-2 shape: {status?, error?} with NO success key. An entry with an error
	# and no success is a failure; an entry with a status and no error is not.
	var groups_shape := {"action": "add", "count": 2, "results": [
		{"node_path": "A", "group": "g", "status": "added"},
		{"node_path": "B", "group": "g", "error": "node not found"}]}
	var r_groups := Helpers.summarize_batch(groups_shape, "results")
	_h.eq(r_groups.get("failed"), 1, "site-2 (no success key) error entry → counted")
	_h.eq(r_groups.get("count"), 2, "site-2 → pre-existing count preserved")
	_h.eq(r_groups.get("action"), "add", "site-2 → pre-existing action preserved")

	# A status-only entry (no error, no success) is NOT a failure.
	var all_added := {"results": [
		{"status": "added"}, {"status": "removed"}], "count": 2}
	var r_all_added := Helpers.summarize_batch(all_added, "results")
	_h.ok(not r_all_added.has("failed"), "site-2 all-status (no error) → no failed key")

	# Empty results → UNCHANGED.
	var empty := {"results": [], "count": 0}
	var r_empty := Helpers.summarize_batch(empty, "results")
	_h.ok(not r_empty.has("failed"), "empty results → no failed key")
	_h.ok(not r_empty.has("hint"), "empty results → no hint key")

	# Non-dict entries are tolerated (skipped), not counted as failures by accident
	# of the predicate; a real {success:false} alongside still counts.
	var mixed := {"results": [42, {"success": false, "error": "x"}]}
	var r_mixed := Helpers.summarize_batch(mixed, "results")
	_h.eq(r_mixed.get("failed"), 1, "non-dict entry skipped; success:false counted")

	print("")


# --- tileset.edit_* per-verb key enforcement (concern 031) ----------------
# The five tileset.edit_* tools share one handler but each owns exactly one
# tile-data concern. _foreign_key_error is the pure gate: it accepts only the
# verb's own keys (plus the universal atlas_x/atlas_y selectors) and rejects the
# first foreign key with a message that names the tool owning it. Pure → testable
# without an editor or a TileSet resource.
func _test_tileset_edit_key_enforcement() -> void:
	_h.begin("tileset.edit_* key enforcement (concern 031)")

	# Happy path: each verb with only its own keys (+ coords) → accepted ("").
	_h.eq(TilesetTileData._foreign_key_error("physics",
		{"atlas_x": 0, "atlas_y": 0, "physics_polygon": "full", "physics_layer": 0,
			"one_way_collision": true}), "", "physics accepts its own keys")
	_h.eq(TilesetTileData._foreign_key_error("terrain",
		{"atlas_x": 1, "atlas_y": 0, "terrain_set": 0, "terrain": 0,
			"terrain_peering": {"center": 0}}), "", "terrain accepts its own keys")
	_h.eq(TilesetTileData._foreign_key_error("navigation",
		{"atlas_x": 0, "atlas_y": 0, "navigation_polygon": "full", "navigation_layer": 0}),
		"", "navigation accepts its own keys")
	_h.eq(TilesetTileData._foreign_key_error("visuals",
		{"atlas_x": 0, "atlas_y": 0, "occlusion_polygon": "full", "occlusion_layer": 0,
			"animation": {"frame_count": 2}, "probability": 0.5}), "",
		"visuals accepts occlusion+animation+probability bundle")
	_h.eq(TilesetTileData._foreign_key_error("custom_data",
		{"atlas_x": 0, "atlas_y": 0, "custom_data": {"damage": 10}}), "",
		"custom_data accepts its own key")

	# Coordinate-only tile is always valid (selectors are universal).
	_h.eq(TilesetTileData._foreign_key_error("physics", {"atlas_x": 0, "atlas_y": 0}),
		"", "coords-only tile accepted")

	# Foreign key → rejected, and the message names the OWNING tool.
	var r1 := TilesetTileData._foreign_key_error("physics",
		{"atlas_x": 0, "atlas_y": 0, "terrain_set": 0})
	_h.ok(not r1.is_empty(), "terrain_set on physics → rejected")
	_h.ok(r1.contains("tileset.edit_terrain"), "physics rejection names tileset.edit_terrain")

	var r2 := TilesetTileData._foreign_key_error("terrain",
		{"atlas_x": 0, "atlas_y": 0, "physics_polygon": "full"})
	_h.ok(r2.contains("tileset.edit_physics"), "physics_polygon on terrain → names edit_physics")

	var r3 := TilesetTileData._foreign_key_error("navigation",
		{"atlas_x": 0, "atlas_y": 0, "probability": 0.5})
	_h.ok(r3.contains("tileset.edit_visuals"), "probability on navigation → names edit_visuals")

	var r4 := TilesetTileData._foreign_key_error("custom_data",
		{"atlas_x": 0, "atlas_y": 0, "navigation_polygon": "full"})
	_h.ok(r4.contains("tileset.edit_navigation"), "navigation_polygon on custom_data → names edit_navigation")

	var r5 := TilesetTileData._foreign_key_error("visuals",
		{"atlas_x": 0, "atlas_y": 0, "custom_data": {"x": 1}})
	_h.ok(r5.contains("tileset.edit_custom_data"), "custom_data on visuals → names edit_custom_data")

	# A key owned by no verb → rejected via the "unknown key" branch (no owner).
	var r6 := TilesetTileData._foreign_key_error("physics",
		{"atlas_x": 0, "atlas_y": 0, "bogus_key": 1})
	_h.ok(not r6.is_empty(), "unknown key on physics → rejected")
	_h.ok(r6.contains("unknown key"), "unknown-key rejection uses unknown-key wording")

	# Unknown verb has an empty allow-list → first non-coord key is foreign.
	_h.ok(not TilesetTileData._foreign_key_error("bogus_verb",
		{"atlas_x": 0, "atlas_y": 0, "physics_polygon": "full"}).is_empty(),
		"unknown verb rejects any non-coord key")


# --- tileset_io full-tile polygon (decompose 034 C1, DRY ×3 → 1) ----------
# build_full_tile_polygon is the consolidated unit rectangle that create's
# collision seed and edit_physics' "full"/"one_way" shape all share. Pure
# geometry — pin the exact vertex output so the DRY can never drift.
func _test_tileset_io_polygon() -> void:
	_h.begin("tileset_io.build_full_tile_polygon (geometry)")

	# 16×16 tile → ±8 corners, wound TL → TR → BR → BL (the order create and
	# edit_physics both rely on for set_collision_polygon_points).
	var p16 := TilesetIo.build_full_tile_polygon(Vector2i(16, 16))
	_h.eq(p16, PackedVector2Array([
		Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)]),
		"16x16 → exact ±8 rectangle in winding order")

	# Non-square tile uses x and y half-extents independently.
	var p_rect := TilesetIo.build_full_tile_polygon(Vector2i(32, 16))
	_h.eq(p_rect, PackedVector2Array([
		Vector2(-16, -8), Vector2(16, -8), Vector2(16, 8), Vector2(-16, 8)]),
		"32x16 → independent half-extents")

	# Odd size keeps the float half (/ 2.0) — no integer truncation.
	var p_odd := TilesetIo.build_full_tile_polygon(Vector2i(15, 15))
	_h.eq(p_odd[0], Vector2(-7.5, -7.5), "odd size keeps .5 half (float division)")


# --- Coerce/serialize round-trip symmetry (concern 018) -------------------
# coerce_value (JSON dict → Godot) and serialize_value (Godot → JSON dict)
# share one tagged-type vocabulary. For value types that serialize_value emits
# as a tagged dict, the Godot-value round-trip coerce_value(serialize_value(V))
# must reproduce V exactly (native compare — no float-string fragility).
#
# Packed* tags (PackedVector2/3Array, PackedColorArray) are bidirectionally
# symmetric as of concern 053 — serialize_value emits the tagged form, so the full
# native round-trip coerce_value(serialize_value(V)) == V holds (asserted below).
# LayerMask stays coerce-only BY DESIGN: a mask is a bare int with no per-value
# marker, so serialize_value cannot tag it without tagging every int — it reads
# back as a plain int, itself writable as-is (no value round-trip break).
# Resource/NewResource are skipped: path-based (ResourceLoader), not value-symmetric.

func _test_coerce_roundtrip() -> void:
	_h.begin("Coerce/serialize round-trip (concern 018)")

	# Tagged-dict value types: coerce_value(serialize_value(V)) == V (both legs).
	var vec2: Vector2 = Vector2(3.5, -2.0)
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(vec2)) == vec2, "Vector2 round-trips")
	var vec3: Vector3 = Vector3(1.0, 2.0, -3.5)
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(vec3)) == vec3, "Vector3 round-trips")
	var vec4: Vector4 = Vector4(1.0, 2.0, 3.0, 4.0)
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(vec4)) == vec4, "Vector4 round-trips")
	var vec2i: Vector2i = Vector2i(7, -8)
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(vec2i)) == vec2i, "Vector2i round-trips")
	var vec3i: Vector3i = Vector3i(-1, 2, 9)
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(vec3i)) == vec3i, "Vector3i round-trips")
	var col: Color = Color(0.25, 0.5, 0.75, 1.0)
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(col)) == col, "Color round-trips")
	var rect2: Rect2 = Rect2(1.0, 2.0, 3.0, 4.0)
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(rect2)) == rect2, "Rect2 round-trips")
	var rect2i: Rect2i = Rect2i(5, 6, 7, 8)
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(rect2i)) == rect2i, "Rect2i round-trips")
	var xform2d: Transform2D = Transform2D(Vector2(0.0, 1.0), Vector2(-1.0, 0.0), Vector2(5.0, 6.0))
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(xform2d)) == xform2d, "Transform2D round-trips")
	var basis: Basis = Basis(Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.0, 0.0))
	var xform3d: Transform3D = Transform3D(basis, Vector3(7.0, 8.0, 9.0))
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(xform3d)) == xform3d, "Transform3D round-trips")
	var npath: NodePath = NodePath("Player/Sprite2D:position")
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(npath)) == npath, "NodePath round-trips")

	# Coerce leg: assert coerce_value parses the EXACT documented tagged wire form
	# (JSON→Godot). For Packed* this complements the symmetric round-trip below — it
	# pins the wire shape itself, not just coerce∘serialize self-consistency.
	# LayerMask is coerce-only by design (see header).
	var pv2: Variant = Coerce.coerce_value({
		"type": "PackedVector2Array",
		"values": [{"type": "Vector2", "x": 1.0, "y": 2.0}, {"type": "Vector2", "x": 3.0, "y": 4.0}],
	})
	_h.ok(pv2 == PackedVector2Array([Vector2(1.0, 2.0), Vector2(3.0, 4.0)]),
			"PackedVector2Array coerces from the documented tagged form")
	var pv3: Variant = Coerce.coerce_value({
		"type": "PackedVector3Array",
		"values": [{"type": "Vector3", "x": 1.0, "y": 2.0, "z": 3.0}],
	})
	_h.ok(pv3 == PackedVector3Array([Vector3(1.0, 2.0, 3.0)]),
			"PackedVector3Array coerces from the documented tagged form")
	var pcol: Variant = Coerce.coerce_value({
		"type": "PackedColorArray",
		"values": [{"type": "Color", "r": 1.0, "g": 0.0, "b": 0.0, "a": 1.0}],
	})
	_h.ok(pcol == PackedColorArray([Color(1.0, 0.0, 0.0, 1.0)]),
			"PackedColorArray coerces from the documented tagged form")
	# LayerMask: numeric layers 1 and 3 → bits 0 and 2 → 0b101 = 5 (no ProjectSettings).
	var mask: Variant = Coerce.coerce_value({"type": "LayerMask", "layers": [1, 3]})
	_h.eq(mask, 5, "LayerMask coerces layers [1,3] → bitmask 5 (coerce-only tag)")

	# Concern 053: serialize_value now emits the tagged Packed* form (was a
	# var_to_str string), so the Packed* tags are bidirectionally symmetric.
	# Assert the full native round-trip coerce_value(serialize_value(V)) == V.
	var pv2_native: PackedVector2Array = PackedVector2Array([Vector2(1.0, 2.0), Vector2(-3.5, 4.0)])
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(pv2_native)) == pv2_native,
			"PackedVector2Array round-trips (now symmetric)")
	var pv3_native: PackedVector3Array = PackedVector3Array([Vector3(1.0, 2.0, 3.0), Vector3(-4.0, 5.5, 6.0)])
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(pv3_native)) == pv3_native,
			"PackedVector3Array round-trips (now symmetric)")
	var pcol_native: PackedColorArray = PackedColorArray([Color(1.0, 0.0, 0.0, 1.0), Color(0.25, 0.5, 0.75, 0.5)])
	_h.ok(Coerce.coerce_value(Coerce.serialize_value(pcol_native)) == pcol_native,
			"PackedColorArray round-trips (now symmetric)")

	print("")


# --- color_from_dict white-default projection -----------------------------
# Pins both default behaviours of Coerce.color_from_dict so neither the
# white-default (modulate/tint) family nor the override path drifts after the
# 3d/particle/procedural/tileset sites were routed through this one helper.
func _test_color_from_dict() -> void:
	_h.begin("Coerce.color_from_dict white-default projection")

	# Full {r,g,b,a} dict → exact Color, no defaulting.
	_h.eq(Coerce.color_from_dict({"r": 0.25, "g": 0.5, "b": 0.75, "a": 0.5}),
			Color(0.25, 0.5, 0.75, 0.5), "full {r,g,b,a} → exact Color")
	# Missing channels fall to opaque-white (1.0) — alpha included.
	_h.eq(Coerce.color_from_dict({"r": 1.0, "g": 0.0, "b": 0.0}),
			Color(1.0, 0.0, 0.0, 1.0), "missing alpha → opaque (a defaults 1.0)")
	# Empty dict → all channels default 1.0 → opaque white.
	_h.eq(Coerce.color_from_dict({}), Color(1.0, 1.0, 1.0, 1.0),
			"empty dict → opaque white via channel defaults")
	# Non-dict, no override → the white default.
	_h.eq(Coerce.color_from_dict(null), Color(1.0, 1.0, 1.0, 1.0),
			"non-dict → white default")
	_h.eq(Coerce.color_from_dict("not a dict"), Color(1.0, 1.0, 1.0, 1.0),
			"non-dict string → white default")
	# default override governs the non-dict case only.
	_h.eq(Coerce.color_from_dict(null, Color.BLACK), Color(0.0, 0.0, 0.0, 1.0),
			"non-dict + BLACK override → black default")
	# A dict still channel-defaults to white even when an override is passed
	# (override is the non-dict fallback, not a per-channel source).
	_h.eq(Coerce.color_from_dict({"r": 0.5}, Color.BLACK), Color(0.5, 1.0, 1.0, 1.0),
			"dict ignores override; channels stay opaque white")

	print("")


# --- _color_from_dict_opaque black-default projection ---------------------
# Pins the paint/opaque-BLACK channel defaults of theme_commands'
# _color_from_dict_opaque (r/g/b default 0.0, a defaults 1.0) — the sibling of
# Coerce.color_from_dict's opaque-WHITE defaults. The partial-dict case is the
# decisive contrast: a missing g/b must stay 0.0 here, NOT 1.0 (that is the tint
# helper), so the two paint/tint facts never drift together.
func _test_color_from_dict_opaque() -> void:
	_h.begin("theme _color_from_dict_opaque black-default projection")

	# Partial dict: missing g/b default 0.0 (the contrast vs the white helper).
	_h.eq(ThemeCommands._color_from_dict_opaque({"r": 0.5}), Color(0.5, 0, 0, 1),
			"partial {r} → missing g/b default 0.0 (paint, not tint)")
	# Full {r,g,b,a} dict → exact Color, no defaulting.
	_h.eq(ThemeCommands._color_from_dict_opaque({"r": 0.25, "g": 0.5, "b": 0.75, "a": 0.5}),
			Color(0.25, 0.5, 0.75, 0.5), "full {r,g,b,a} → exact Color")
	# Non-dict → opaque black.
	_h.eq(ThemeCommands._color_from_dict_opaque(null), Color(0, 0, 0, 1),
			"non-dict → opaque black")

	print("")


# --- node-sourced Packed property serialises tagged (concern 053) ----------
# The unit suite above pins coerce∘serialize on hand-built Packed* values; this
# pins the read PATH'S contract: node.get_property serialises the property VALUE
# through Coerce.serialize_value (node_commands.gd:158 — the single-property read).
# Here we obtain a PackedVector2Array from an ACTUAL node property (Line2D.points)
# and assert serialize_value emits the TAGGED dict {type:"PackedVector2Array", …}
# — NOT a var_to_str String — and that it round-trips back to the exact value.
# This is the headless proxy for sweep 3.20b (node_set_property → node_get_property).
# No editor/dispatch context needed: serialize_value is the same call the handler
# makes on node.get(property), so exercising it on a node-sourced value covers the
# read path's serialisation without a live scene. Node built with .new()/free().
func _test_node_packed_property_serialize() -> void:
	_h.begin("node-sourced Packed property serialises tagged (concern 053)")

	var line := Line2D.new()
	var written: PackedVector2Array = PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(100.0, 50.0), Vector2(200.0, 0.0)])
	line.points = written

	# Read the property the way the handler does (node.get(...) → Variant), then
	# serialise it the way node.get_property does (Coerce.serialize_value).
	var read_value: Variant = line.get("points")
	_h.eq(typeof(read_value), TYPE_PACKED_VECTOR2_ARRAY,
			"Line2D.points reads back as a PackedVector2Array")

	var serialised: Variant = Coerce.serialize_value(read_value)
	# The contract: a tagged Dictionary, NOT a var_to_str String (the 053 fix).
	_h.eq(typeof(serialised), TYPE_DICTIONARY,
			"serialised node Packed value is a Dictionary, not a String (concern 053)")
	var serialised_dict: Dictionary = serialised
	_h.eq(str(serialised_dict.get("type", "")), "PackedVector2Array",
			"serialised form carries type tag 'PackedVector2Array' (not a var_to_str string)")
	var values_field: Variant = serialised_dict.get("values", null)
	_h.eq(typeof(values_field), TYPE_ARRAY, "serialised form has a 'values' array")

	# Read-form must round-trip back to the written value (read==write for the LLM).
	var restored: Variant = Coerce.coerce_value(serialised)
	_h.ok(restored == written,
			"node-sourced PackedVector2Array round-trips (coerce(serialize(points)) == written)")

	line.free()
	print("")


# --- save.read configurable cap + byte-offset paging (concern 025) ---------
# _cmd_save_read gained a configurable cap (save_read_cap_kb, min 64) replacing
# the hardcoded 256 KB, an `offset` param for windowed paging, a `next_offset`
# return, and a FILE_TOO_LARGE frame guard (base64 1.33× projection vs
# ws_buffer_kb) so an oversized window is rejected before it silently vanishes on
# the transport. Drives the real handler against a user:// temp file; restores
# the mutated limit settings afterward.

const SaveCommands := preload("res://addons/godot_mcp_toolkit/commands/save_commands.gd")

func _test_save_read_paging() -> void:
	_h.begin("save.read cap + offset paging (concern 025)")

	# Preserve the limit settings this test mutates (str/int coercion — Variant
	# source, warnings-as-error in test/).
	var orig_cap: int = int(ProjectSettings.get_setting("mcp_toolkit/limits/save_read_cap_kb", 256))
	var orig_ws: int = int(ProjectSettings.get_setting("mcp_toolkit/limits/ws_buffer_kb", 1024))

	# A deterministic ASCII fixture so byte offsets == character offsets and the
	# UTF-8 decode path (not base64) is exercised. 1000 bytes total.
	var body := "A".repeat(1000)
	var rel_path := "user://saves/sv2_paging_025.txt"
	var abs_path := ProjectSettings.globalize_path(rel_path)
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	var wf := FileAccess.open(abs_path, FileAccess.WRITE)
	_h.ok(wf != null, "fixture file opened for write")
	if wf != null:
		wf.store_string(body)
		wf.close()

	# Default cap (256 KB) for the paging assertions.
	ProjectSettings.set_setting("mcp_toolkit/limits/save_read_cap_kb", 256)
	ProjectSettings.set_setting("mcp_toolkit/limits/ws_buffer_kb", 1024)

	# 1. First window: offset 0, max_bytes 400 → 400 bytes, next_offset 400,
	#    truncated true (600 remain), total_bytes 1000.
	var p1: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": 400})
	_h.ok(p1.get("success", false), "window 1 → success")
	_h.eq(p1.get("bytes_returned", -1), 400, "window 1 → 400 bytes returned")
	_h.eq(p1.get("offset", -1), 0, "window 1 → offset 0 echoed")
	_h.eq(p1.get("next_offset", -1), 400, "window 1 → next_offset 400")
	_h.eq(p1.get("total_bytes", -1), 1000, "window 1 → total_bytes 1000")
	_h.eq(p1.get("truncated", null), true, "window 1 → truncated true (more remains)")
	# Uniform pagination contract (concern 054): truncated window carries a prose
	# hint naming next_offset; not-truncated windows omit it (asserted below).
	_h.ok(p1.has("hint"), "window 1 → hint present (truncated)")
	_h.ok(str(p1.get("hint", "")).contains("next_offset"), "window 1 → hint names next_offset")

	# 2. Middle window: seek correctness — offset 400, max_bytes 400 → next_offset
	#    800, still truncated.
	var p2: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "offset": 400, "max_bytes": 400})
	_h.eq(p2.get("bytes_returned", -1), 400, "window 2 → 400 bytes returned")
	_h.eq(p2.get("offset", -1), 400, "window 2 → offset 400 echoed")
	_h.eq(p2.get("next_offset", -1), 800, "window 2 → next_offset 800")
	_h.eq(p2.get("truncated", null), true, "window 2 → still truncated")

	# 3. Final window: offset 800 → only 200 bytes left; next_offset reaches EOF,
	#    truncated false. Pins next_offset arithmetic = offset + bytes_returned.
	var p3: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "offset": 800, "max_bytes": 400})
	_h.eq(p3.get("bytes_returned", -1), 200, "window 3 → 200 bytes (clamped to remaining)")
	_h.eq(p3.get("next_offset", -1), 1000, "window 3 → next_offset 1000 (== total)")
	_h.eq(p3.get("truncated", null), false, "window 3 → truncated false (reached EOF)")
	_h.ok(not p3.has("hint"), "window 3 → no hint (not truncated)")

	# 4. Offset exactly AT EOF → 0 bytes, not an error; next_offset == total,
	#    truncated false (graceful completion sentinel for a paging caller).
	var p_eof: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "offset": 1000})
	_h.ok(p_eof.get("success", false), "offset == EOF → success (not an error)")
	_h.eq(p_eof.get("bytes_returned", -1), 0, "offset == EOF → 0 bytes")
	_h.eq(p_eof.get("next_offset", -1), 1000, "offset == EOF → next_offset == total")
	_h.eq(p_eof.get("truncated", null), false, "offset == EOF → truncated false")

	# 5. Offset PAST EOF → still graceful: 0 bytes, no error.
	var p_past: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "offset": 99999})
	_h.ok(p_past.get("success", false), "offset past EOF → success (not an error)")
	_h.eq(p_past.get("bytes_returned", -1), 0, "offset past EOF → 0 bytes")
	_h.eq(p_past.get("truncated", null), false, "offset past EOF → truncated false")

	# 6. Negative offset → INVALID_PARAMS.
	var p_neg: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "offset": -1})
	_h.eq(p_neg.get("success", null), false, "negative offset → rejected")
	_h.eq(str(p_neg.get("code", "")), "INVALID_PARAMS", "negative offset → INVALID_PARAMS")

	# 7. Cap clamp — at the default 256 KB cap, max_bytes one past the cap is
	#    rejected; exactly at the cap is accepted (the 256 KB default == the former
	#    hardcoded ceiling, so default behaviour is unchanged).
	var at_cap := 262144
	var over_cap: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": at_cap + 1})
	_h.eq(over_cap.get("success", null), false, "max_bytes cap+1 → rejected")
	_h.eq(str(over_cap.get("code", "")), "INVALID_PARAMS", "max_bytes cap+1 → INVALID_PARAMS")
	var at_cap_ok: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": at_cap})
	_h.ok(at_cap_ok.get("success", false), "max_bytes == cap → accepted")

	# 8. Cap is configurable upward: raise to 512 KB → a max_bytes of 300 KB
	#    (rejected at the default) is now accepted.
	ProjectSettings.set_setting("mcp_toolkit/limits/save_read_cap_kb", 512)
	var raised: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": 300 * 1024})
	_h.ok(raised.get("success", false), "raised cap 512 KB → 300 KB max_bytes accepted")

	# 9. Cap floor — a sub-minimum cap setting (32) is floored to 64 KB, so a
	#    max_bytes above 64 KB but below the raw setting is rejected at the floor.
	ProjectSettings.set_setting("mcp_toolkit/limits/save_read_cap_kb", 32)
	var floored: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": 100 * 1024})
	_h.eq(floored.get("success", null), false, "cap 32 floored to 64 KB → 100 KB max_bytes rejected")
	var floored_ok: Dictionary = SaveCommands._cmd_save_read({"path": rel_path, "max_bytes": 64 * 1024})
	_h.ok(floored_ok.get("success", false), "cap 32 floored to 64 KB → 64 KB max_bytes accepted")

	# 10. FILE_TOO_LARGE frame guard — raise the cap high and drop ws_buffer_kb to
	#     256 (its floor). A 250 KB window projects to ~333 KB base64, over the
	#     256 KB buffer → FILE_TOO_LARGE BEFORE any read, with total_bytes + a hint.
	#     (Use a larger fixture so 250 KB is actually available to request.)
	var big_body := "B".repeat(300 * 1024)
	var big_rel := "user://saves/sv2_paging_025_big.txt"
	var big_abs := ProjectSettings.globalize_path(big_rel)
	var bwf := FileAccess.open(big_abs, FileAccess.WRITE)
	if bwf != null:
		bwf.store_string(big_body)
		bwf.close()
	ProjectSettings.set_setting("mcp_toolkit/limits/save_read_cap_kb", 1024)
	ProjectSettings.set_setting("mcp_toolkit/limits/ws_buffer_kb", 256)
	var too_large: Dictionary = SaveCommands._cmd_save_read({"path": big_rel, "max_bytes": 250 * 1024})
	_h.eq(too_large.get("success", null), false, "oversized window → rejected")
	_h.eq(str(too_large.get("code", "")), "FILE_TOO_LARGE", "oversized window → FILE_TOO_LARGE")
	_h.ok(too_large.has("total_bytes"), "FILE_TOO_LARGE → carries total_bytes")
	_h.ok(str(too_large.get("hint", "")).contains("offset"),
			"FILE_TOO_LARGE → hint mentions offset paging")
	# A small window of the SAME big file fits and succeeds (guard is per-window,
	# not per-file).
	var small_window: Dictionary = SaveCommands._cmd_save_read({"path": big_rel, "max_bytes": 100 * 1024})
	_h.ok(small_window.get("success", false), "small window of the big file → fits, succeeds")

	# Cleanup: remove fixtures, restore the mutated limit settings.
	DirAccess.remove_absolute(abs_path)
	DirAccess.remove_absolute(big_abs)
	ProjectSettings.set_setting("mcp_toolkit/limits/save_read_cap_kb", orig_cap)
	ProjectSettings.set_setting("mcp_toolkit/limits/ws_buffer_kb", orig_ws)
	print("")


# --- script.read uniform pagination contract (concern 054) -----------------
# script.read now mirrors save.read's SHAPE in LINE units: every success carries
# truncated + total_lines; a windowed read whose end precedes EOF also carries
# next_start_line (1-based resume = clamped end_line + 1) + a prose hint; a full
# read (and a window reaching EOF) returns truncated:false with no hint. ADD-ONLY
# (concern 054) — existing start_line/end_line/total_lines/content are unchanged.
# Drives the real handler against a res:// temp fixture; removes it afterward.

func _test_script_read_paging() -> void:
	_h.begin("script.read pagination contract (concern 054)")

	# A deterministic 5-line fixture (no trailing newline → split("\n") size 5).
	var fixture := "res://sv2_script_read_054.gd"
	var sf := FileAccess.open(fixture, FileAccess.WRITE)
	_h.ok(sf != null, "fixture script opened for write")
	if sf != null:
		sf.store_string("line1\nline2\nline3\nline4\nline5")
		sf.close()

	# 1. Windowed read that ENDS BEFORE EOF (lines 1..2 of 5) → truncated true,
	#    next_start_line 3, hint naming next_start_line. total_lines preserved.
	var w: Dictionary = ScriptCommands._cmd_script_read({"file_path": fixture, "start_line": 1, "end_line": 2})
	_h.ok(w.get("success", false), "window 1..2 → success")
	_h.eq(w.get("start_line", -1), 1, "window → start_line 1 preserved")
	_h.eq(w.get("end_line", -1), 2, "window → end_line 2 preserved")
	_h.eq(w.get("total_lines", -1), 5, "window → total_lines 5 preserved")
	_h.eq(w.get("truncated", null), true, "window 1..2 → truncated true (2 < 5)")
	_h.eq(w.get("next_start_line", -1), 3, "window → next_start_line = end_line + 1 = 3 (1-based)")
	_h.ok(str(w.get("hint", "")).contains("next_start_line"), "window → hint names next_start_line")

	# 2. Windowed read that REACHES EOF (lines 3..5; end clamps to 5) → truncated
	#    false, no next_start_line, no hint.
	var eofw: Dictionary = ScriptCommands._cmd_script_read({"file_path": fixture, "start_line": 3, "end_line": 999})
	_h.eq(eofw.get("end_line", -1), 5, "window 3..999 → end_line clamped to 5")
	_h.eq(eofw.get("truncated", null), false, "window reaching EOF → truncated false")
	_h.ok(not eofw.has("next_start_line"), "window at EOF → no next_start_line")
	_h.ok(not eofw.has("hint"), "window at EOF → no hint")

	# 3. FULL read (no start_line) → truncated false + total_lines, contract-complete.
	#    Existing 'content' field is still present (additive change).
	var full: Dictionary = ScriptCommands._cmd_script_read({"file_path": fixture})
	_h.ok(full.get("success", false), "full read → success")
	_h.ok(full.has("content"), "full read → content preserved")
	_h.eq(full.get("total_lines", -1), 5, "full read → total_lines 5 (added for uniformity)")
	_h.eq(full.get("truncated", null), false, "full read → truncated false")
	_h.ok(not full.has("next_start_line"), "full read → no next_start_line")
	_h.ok(not full.has("hint"), "full read → no hint")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(fixture))
	print("")


# --- SettingsRegistration mcp_toolkit/* collector (concern 002) -------------
# unregister_all() scrubs every mcp_toolkit/* ProjectSettings key on uninstall
# via a PREFIX SCAN, not a hardcoded list — that staleness is the concern (its
# own list missed save_read_cap_kb). _collect_mcp_setting_names is the read-only
# core that scan drives; pinning it proves the prefix matches the keys that
# matter (incl. the one the stale list dropped) and excludes engine keys.
# READ-ONLY by design: asserts the collector only — it must NOT call
# unregister_all / set_setting-persist / save (the runner loads the real dogfood
# project, so a save would scrub project.godot). It calls register_all() first
# (mirroring the plugin's _enter_tree) so the collector sees the full registered
# set — register_all is in-memory only (no save), so project.godot stays clean.
func _test_settings_collect_names() -> void:
	_h.begin("SettingsRegistration mcp_toolkit/* collector (concern 002)")
	# Establish production's precondition: register_all() runs in the plugin's
	# _enter_tree before unregister_all() is ever reached in _disable_plugin. The
	# headless --script runner doesn't run _enter_tree, so register the keys here
	# so the collector sees the full set. register_all() does NOT call
	# ProjectSettings.save() — purely in-memory, so project.godot is untouched.
	SettingsRegistration.register_all()
	var names := SettingsRegistration._collect_mcp_setting_names()
	# Regression-pin: the exact key the concern's stale hardcoded list missed.
	_h.ok(names.has("mcp_toolkit/limits/save_read_cap_kb"),
			"collector includes save_read_cap_kb (the key the stale list missed)")
	_h.ok(names.has("mcp_toolkit/limits/script_read_cap_kb"),
			"collector includes script_read_cap_kb")
	_h.ok(names.has("mcp_toolkit/status"), "collector includes status")
	_h.ok(names.has("mcp_toolkit/internal/bootstrap_complete"),
			"collector includes internal/bootstrap_complete")
	# An unrelated engine key is NOT swept by the mcp_toolkit/ prefix.
	_h.ok(not names.has("application/config/name"),
			"collector excludes unrelated engine key (application/config/name)")
	print("")
