@tool
extends RefCounted
## Cross-version / paths / editor-lifecycle pure-logic unit tests: compile-error
## message (version-aware), node.set_property groups rejection, UserPathMonitor
## change detection, editor.refresh reload filter, unfocused-sleep backup, and the
## stale-live-instance hint. Exercises the versioning/ + paths/ + editor-lifecycle
## pure logic.

const ScriptCommands := preload("res://addons/godot_mcp_toolkit/commands/script_commands.gd")
const NodeCommands := preload("res://addons/godot_mcp_toolkit/commands/node_commands.gd")
const UserPathMonitor := preload("res://addons/godot_mcp_toolkit/paths/user_path_monitor.gd")
const EditorRescan := preload("res://addons/godot_mcp_toolkit/commands/editor/editor_rescan.gd")
const UnfocusedBackup := preload("res://addons/godot_mcp_toolkit/core/unfocused_backup.gd")
const StaleInstanceHint := preload("res://addons/godot_mcp_toolkit/versioning/stale_instance_hint.gd")


static func run(testing) -> void:
	_test_compile_error_message(testing)
	_test_groups_property_rejection(testing)
	_test_user_path_monitor(testing)
	_test_editor_refresh_reload_filter(testing)
	_test_unfocused_backup(testing)
	_test_stale_instance_hint(testing)


# --- Compile-error diagnostic message (version-aware) (~10 assertions) -----
# script_check / script_write steer the LLM to the right detail tool: editor_get_console
# captures editor PARSE errors only on 4.5+ (Logger); on 4.2-4.4 they aren't file-logged,
# so the diagnostic must point to lsp_diagnostics instead of a dead end. Regression guard
# for the misleading-message bug.

static func _test_compile_error_message(testing) -> void:
	testing.begin("Compile-error message (version-aware)")
	# Discriminator: lsp_diagnostics appears ONLY in the <4.5 message (the 4.5+ message
	# directs to editor_get_console). The <4.5 message also names editor_get_console — but
	# only to say it CAN'T capture parse errors there — so don't assert on its mere presence.
	for ver in ["4.2", "4.3", "4.4"]:
		var msg: String = ScriptCommands._compile_error_message(ver)
		testing.ok(msg.contains("lsp_diagnostics"),
			"%s → recommends lsp_diagnostics (editor_get_console can't capture parse errors <4.5)" % ver)
	for ver in ["4.5", "4.6"]:
		var msg: String = ScriptCommands._compile_error_message(ver)
		testing.ok(msg.contains("editor_get_console") and not msg.contains("lsp_diagnostics"),
			"%s → directs to editor_get_console, not lsp (4.5+ Logger captures parse errors)" % ver)


# --- node.set_property "groups" rejection ----------------------------------
# node.set_property does a declarative full-set replace, so accepting "groups"
# would silently drop any group not in the list; node.groups is incremental.
# Single mode whole-call-rejects and batch per-entry-rejects on this one name,
# steering to node.groups. _is_groups_property is the shared pure decision; the
# steering text is pinned so a future edit can't drop the node.groups pointer.

static func _test_groups_property_rejection(testing) -> void:
	testing.begin("node.set_property groups rejection")
	# The predicate is exact: only the bare "groups" property is refused.
	testing.ok(NodeCommands._is_groups_property("groups"), "'groups' → refused")
	testing.ok(not NodeCommands._is_groups_property("group"), "'group' → not refused")
	testing.ok(not NodeCommands._is_groups_property("groups_enabled"), "'groups_enabled' → not refused")
	testing.ok(not NodeCommands._is_groups_property(""), "empty → not refused")
	testing.ok(not NodeCommands._is_groups_property("position"), "ordinary property → not refused")
	# The rejection steers to node.groups (the message/hint can't silently lose it).
	testing.ok(not NodeCommands._GROUPS_REJECTION_MESSAGE.is_empty(), "rejection message present")
	testing.ok(NodeCommands._GROUPS_REJECTION_HINT.contains("node.groups"),
		"rejection hint names node.groups")
	print("")


# --- UserPathMonitor change detection (~8 assertions) ----------------------
# Godot derives user:// from THREE settings — config/name, use_custom_user_dir,
# and custom_user_dir_name. _on_settings_changed is the detection method: it
# compares all three against the primed cache and re-emits user_path_changed
# when ANY differs. Mutating a key + calling _on_settings_changed directly
# exercises the detection without the editor's settings_changed plumbing.
# Originals are restored so project state (and subsequent tests) are unaffected.

static func _test_user_path_monitor(testing) -> void:
	testing.begin("UserPathMonitor change detection")

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
	testing.eq(fired[0], 0, "no change → signal not emitted")

	# 2. config/name change → emit.
	ProjectSettings.set_setting("application/config/name", str(orig_name) + "_renamed")
	monitor._on_settings_changed()
	testing.eq(fired[0], 1, "config/name change → signal emitted")

	# 3. use_custom_user_dir toggle → emit (name unchanged from prior step).
	ProjectSettings.set_setting("application/config/use_custom_user_dir", not bool(orig_use_custom))
	monitor._on_settings_changed()
	testing.eq(fired[0], 2, "use_custom_user_dir toggle → signal emitted")

	# 4. custom_user_dir_name change → emit.
	ProjectSettings.set_setting("application/config/custom_user_dir_name", str(orig_custom_name) + "_dir")
	monitor._on_settings_changed()
	testing.eq(fired[0], 3, "custom_user_dir_name change → signal emitted")

	# 5. Re-check with no further change → no extra emit (cache updated each time).
	monitor._on_settings_changed()
	testing.eq(fired[0], 3, "stable after change → no spurious re-emit")

	# Restore originals so other tests / the project see pristine settings.
	ProjectSettings.set_setting("application/config/name", orig_name)
	ProjectSettings.set_setting("application/config/use_custom_user_dir", orig_use_custom)
	ProjectSettings.set_setting("application/config/custom_user_dir_name", orig_custom_name)

	print("")


# --- editor.refresh reload filter ------------------------------------------
# should_reload_open_script: reload only scan-changed, non-toolkit open scripts.
# Guards against a regression back to "reload all open scripts" (which cancels
# suspended coroutines mid-dispatch → an editor crash).

static func _test_editor_refresh_reload_filter(testing) -> void:
	testing.begin("editor.refresh reload filter")
	var changed := {
		"res://game/player.gd": true,
		"res://addons/godot_mcp_toolkit/commands/scene_commands.gd": true,
	}
	# 1. changed user script → reload
	testing.ok(EditorRescan.should_reload_open_script("res://game/player.gd", changed),
			"changed user script → reload")
	# 2. unchanged user script → skip
	testing.ok(not EditorRescan.should_reload_open_script("res://game/enemy.gd", changed),
			"unchanged user script → skip")
	# 3. toolkit's own script, even if scan-changed → skip (never self-reload)
	testing.ok(not EditorRescan.should_reload_open_script(
			"res://addons/godot_mcp_toolkit/commands/scene_commands.gd", changed),
			"toolkit-own changed script → skip (never self-reload)")
	# 4. unchanged toolkit script → skip
	testing.ok(not EditorRescan.should_reload_open_script(
			"res://addons/godot_mcp_toolkit/transport/mcp_server.gd", changed),
			"unchanged toolkit script → skip")
	print("")


# --- Unfocused-sleep backup ------------------------------------------------
# Machine-wide crash-safe restore of the global unfocused frame-rate setting.
# The editor-coupled get/set EditorSettings calls live in mcp_server.gd (covered
# by interactive verification); the conflict-resolution + first-writer-wins +
# both-values-stored logic is pure and headless-testable here against a temp dir.

static func _test_unfocused_backup(testing) -> void:
	testing.begin("Unfocused-sleep backup")
	var dir := ProjectSettings.globalize_path("user://_mcp_unfocused_backup_test")
	DirAccess.make_dir_recursive_absolute(dir)
	var ver := "9.9"  # fixed test key + temp dir → isolated from any real backup
	UnfocusedBackup.delete_backup(dir, ver)  # clean slate

	# should_capture_boost — opt-out + idempotency gate (the "no-op when off" unit).
	testing.ok(UnfocusedBackup.should_capture_boost(true, false),
			"should_capture_boost(on, idle) → true")
	testing.ok(not UnfocusedBackup.should_capture_boost(false, false),
			"should_capture_boost(off, idle) → false (no-op when off)")
	testing.ok(not UnfocusedBackup.should_capture_boost(true, true),
			"should_capture_boost(on, already active) → false (idempotent)")

	# 1. capture_if_absent writes when no backup exists (first-writer-wins).
	testing.ok(UnfocusedBackup.capture_if_absent(dir, 100000, 16666, ver),
			"first capture → writes backup (true)")
	testing.ok(UnfocusedBackup.has_backup(dir, ver), "backup file exists after capture")

	# 2. backup stores BOTH original and boosted.
	var b: Dictionary = UnfocusedBackup.read_backup(dir, ver)
	testing.eq(b.get("original", -1), 100000, "backup stores original")
	testing.eq(b.get("boosted", -1), 16666, "backup stores boosted")

	# 3. second capture does NOT overwrite (first-writer-wins).
	testing.ok(not UnfocusedBackup.capture_if_absent(dir, 33333, 8333, ver),
			"second capture → does not overwrite (false)")
	var b2: Dictionary = UnfocusedBackup.read_backup(dir, ver)
	testing.eq(b2.get("original", -1), 100000, "original preserved after second capture")
	testing.eq(b2.get("boosted", -1), 16666, "boosted preserved after second capture")

	# 4. resolve_restore: current == boosted → restore the true original (self-heal A).
	var d1: Dictionary = UnfocusedBackup.resolve_restore(16666, b2)
	testing.ok(d1["restore"], "current == boosted → restore true")
	testing.eq(d1["value"], 100000, "current == boosted → value is the original")

	# 5. resolve_restore: current != boosted → keep current, conflict-aware (self-heal B).
	var d2: Dictionary = UnfocusedBackup.resolve_restore(50000, b2)
	testing.ok(not d2["restore"], "current != boosted → restore false (kept)")
	testing.eq(d2["value"], 50000, "current != boosted → value echoes current")

	# 6. resolve_restore: empty / malformed backup → no-op.
	testing.ok(not UnfocusedBackup.resolve_restore(16666, {})["restore"],
			"empty backup → restore false")
	testing.ok(not UnfocusedBackup.resolve_restore(16666, {"original": 100000})["restore"],
			"backup missing 'boosted' → restore false")

	# 7. delete_backup removes the file; read on missing → empty dict.
	UnfocusedBackup.delete_backup(dir, ver)
	testing.ok(not UnfocusedBackup.has_backup(dir, ver), "delete_backup → file gone")
	testing.eq(UnfocusedBackup.read_backup(dir, ver), {}, "read missing backup → empty dict")

	# 8. version_key derives "<major>.<minor>" (override form).
	testing.eq(UnfocusedBackup.version_key({"major": 4, "minor": 2}), "4.2",
			"version_key({4,2}) → '4.2'")

	DirAccess.remove_absolute(dir)  # cleanup
	print("")


# --- Stale-live-instance hint ----------------------------------------------
# Pure decision predicates + message builders + on-disk helpers for the
# stale-live-instance method-call hazard. Models the pure decision that the
# proactive script-write path and the reactive INVALID-METHOD path both consume
# (each reads the running version + on-disk source and feeds these).
# Boundary: STALE on Godot < 4.4 (minor 2,3), live on 4.4+ (boundary 4.3→4.4); see
# Insights/stale-live-instance-method-hazard.md + test/flows/02_*.

static func _test_stale_instance_hint(testing) -> void:
	testing.begin("Stale-instance hint")

	# should_warn_on_write(existed, compiled_ok, extension, major, minor) — proactive gate
	testing.ok(StaleInstanceHint.should_warn_on_write(true, true, "gd", 4, 2),
			"write: existing .gd compiled on 4.2 → warn")
	testing.ok(StaleInstanceHint.should_warn_on_write(true, true, "gd", 4, 3),
			"write: existing .gd compiled on 4.3 → warn")
	testing.ok(not StaleInstanceHint.should_warn_on_write(true, true, "gd", 4, 4),
			"write: 4.4 → no warn (hot-reloads)")
	testing.ok(not StaleInstanceHint.should_warn_on_write(true, true, "gd", 4, 5),
			"write: 4.5 → no warn")
	testing.ok(not StaleInstanceHint.should_warn_on_write(true, true, "gd", 4, 6),
			"write: 4.6 → no warn")
	testing.ok(not StaleInstanceHint.should_warn_on_write(false, true, "gd", 4, 3),
			"write: create (new file) → no warn")
	testing.ok(not StaleInstanceHint.should_warn_on_write(true, false, "gd", 4, 3),
			"write: compile-failed → no warn (Scenario C gate)")
	testing.ok(not StaleInstanceHint.should_warn_on_write(true, true, "cs", 4, 3),
			"write: .cs → no warn (out of scope)")
	testing.ok(not StaleInstanceHint.should_warn_on_write(true, true, "gdshader", 4, 2),
			"write: .gdshader → no warn")
	testing.ok(not StaleInstanceHint.should_warn_on_write(true, true, "gd", 5, 0),
			"should_warn_on_write: Godot 5.0 does not warn — gate is major-aware")

	# should_hint_on_call(has_method, disk_has_method, disk_compiles, is_gd, major, minor)
	testing.ok(StaleInstanceHint.should_hint_on_call(false, true, true, true, 4, 3),
			"call: stale method on 4.3 → hint")
	testing.ok(StaleInstanceHint.should_hint_on_call(false, true, true, true, 4, 2),
			"call: stale method on 4.2 → hint")
	testing.ok(not StaleInstanceHint.should_hint_on_call(false, true, true, true, 4, 4),
			"call: 4.4 → no hint")
	testing.ok(not StaleInstanceHint.should_hint_on_call(false, false, true, true, 4, 3),
			"call: method absent on disk (typo) → no hint")
	testing.ok(not StaleInstanceHint.should_hint_on_call(false, true, false, true, 4, 3),
			"call: disk doesn't compile → no hint (Option B)")
	testing.ok(not StaleInstanceHint.should_hint_on_call(true, true, true, true, 4, 3),
			"call: has_method true → no hint")
	testing.ok(not StaleInstanceHint.should_hint_on_call(false, true, true, false, 4, 3),
			"call: non-.gd script → no hint")
	testing.ok(not StaleInstanceHint.should_hint_on_call(false, true, true, true, 5, 0),
			"should_hint_on_call: Godot 5.0 does not hint — gate is major-aware")

	# source_compiles — safe GDScript.new().reload() parse (class_name stripped)
	testing.ok(StaleInstanceHint.source_compiles("extends Node\nfunc a() -> int:\n\treturn 1\n"),
			"source_compiles: valid GDScript → true")
	testing.ok(not StaleInstanceHint.source_compiles("extends Node\nvar = = =\n"),
			"source_compiles: broken GDScript → false")
	testing.ok(StaleInstanceHint.source_compiles("class_name FooProbe9\nextends Node\nfunc a():\n\tpass\n"),
			"source_compiles: class_name script → true (no false collision)")

	# source_has_method — line scan, word-exact, string/comment safe
	testing.ok(StaleInstanceHint.source_has_method("func foo():\n\tpass", "foo"),
			"source_has_method: func foo → true")
	testing.ok(StaleInstanceHint.source_has_method("static func bar() -> int:\n\treturn 1", "bar"),
			"source_has_method: static func bar → true")
	testing.ok(not StaleInstanceHint.source_has_method("func foo():\n\tpass", "baz"),
			"source_has_method: absent method → false")
	testing.ok(not StaleInstanceHint.source_has_method("func foo_bar():\n\tpass", "foo"),
			"source_has_method: foo_bar not matched by foo (word-exact)")
	testing.ok(StaleInstanceHint.source_has_method("\tfunc inner():\n\t\tpass", "inner"),
			"source_has_method: indented inner method → true")
	testing.ok(not StaleInstanceHint.source_has_method("var x = \"func ghost(\"", "ghost"),
			"source_has_method: 'func' inside a string → false")
	testing.ok(not StaleInstanceHint.source_has_method("func foo():\n\tpass", ""),
			"source_has_method: empty method → false")

	# recovery_message — names the version, covers bodies+added, relaunch + fresh-node
	var msg := StaleInstanceHint.recovery_message("4.3")
	testing.ok(msg.contains("4.3"), "recovery_message: names the version")
	testing.ok(msg.contains("relaunch"), "recovery_message: recommends relaunch")
	testing.ok(msg.contains("fresh node"), "recovery_message: notes a fresh node doesn't help")
	testing.ok(msg.contains("changed method bodies") and msg.contains("added members"),
			"recovery_message: covers changed bodies AND added members")

	# write_hint — validation guidance FIRST, stale nudge in the recency slot
	var wh := StaleInstanceHint.write_hint("4.2")
	testing.ok(wh.begins_with("Validate"), "write_hint: validation guidance leads")
	testing.ok(wh.contains("script_check"), "write_hint: mentions script_check")
	testing.ok(wh.find("Validate") < wh.find("relaunch"),
			"write_hint: validation before stale nudge (recency ordering)")
	testing.ok(wh.contains("4.2"), "write_hint: carries the version label")

	print("")
