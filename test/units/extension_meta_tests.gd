@tool
extends RefCounted
## Extension subsystem leaf unit tests: load collision guard, candidate/addon
## detection, onboarding wizard specs, command-entry wire shape, watcher set-diff,
## and the extension path-guard dispatch enforcement.
##
## run() is a coroutine — the path-guard group awaits registry.call_command(); the
## orchestrator must `await` this module's run().

const ExtensionSupport := preload("res://addons/godot_mcp_toolkit/extensions/services/extension_support.gd")
const ExtensionMetaCommands := preload("res://addons/godot_mcp_toolkit/extensions/services/extension_meta_commands.gd")
const ExtensionWatcher := preload("res://addons/godot_mcp_toolkit/extensions/services/extension_watcher.gd")
const OnboardingWizard := preload("res://addons/godot_mcp_toolkit/ui/onboarding_wizard.gd")


static func run(testing) -> void:
	_test_extension_collision_guard(testing)
	_test_extension_support(testing)
	_test_onboarding_wizard_specs(testing)
	_test_build_command_entry(testing)
	_test_compute_class_diff(testing)
	await _test_extension_path_guard(testing)


# --- Extension-load collision guard (first-loaded wins) -------------------
# registry.add() is last-writer-wins by default, but during a bracketed
# extension load (begin/end_extension_load — what extension_loader.gd wraps each
# register() with) an add() of an ALREADY-registered name is REFUSED, not
# overwritten: first-loaded wins. This pins that the incumbent (built-in OR a
# prior extension) is never hijacked and the refusal is reported per offending
# name. Pure/registry-level — no editor, no real extension files.
static func _test_extension_collision_guard(testing) -> void:
	testing.begin("Extension-load collision guard")
	var registry := MCPToolkitCommandRegistry.new()

	# Stand in for a built-in command and one already-loaded extension command.
	# Distinct read-only flags let us prove the incumbent options are untouched.
	registry.add("scene.create_node", testing.noop, MCPToolkitCommandOptions.new().mark_read_only())
	registry.add("acme.do_thing", testing.noop, MCPToolkitCommandOptions.new())
	registry.mark_extension("acme.do_thing")

	# 1. An extension whose add() targets a BUILT-IN name is refused; the built-in
	#    handler + options stay exactly as registered.
	registry.begin_extension_load()
	registry.add("scene.create_node", testing.noop, MCPToolkitCommandOptions.new())  # tries to hijack
	var builtin_collision_refusals := registry.end_extension_load()
	testing.eq(builtin_collision_refusals.size(), 1, "built-in collision → one refusal recorded")
	testing.eq(str(builtin_collision_refusals[0].get("method", "")), "scene.create_node", "refusal names the colliding command")
	testing.ok(registry.is_read_only("scene.create_node"),
			"built-in incumbent untouched (options preserved, not overwritten)")
	testing.ok(not registry.get_extension_methods().has("scene.create_node"),
			"_extension_methods never contains the built-in name after a colliding load")

	# 2. Two extensions registering the same NEW name → first-writer-wins; the
	#    second is refused. (Extension A's add lands; extension B's is refused.)
	registry.begin_extension_load()
	registry.add("shared.tool", testing.noop, MCPToolkitCommandOptions.new().mark_idempotent())  # ext A — lands
	var ext_a_refusals := registry.end_extension_load()
	registry.mark_extension("shared.tool")
	testing.eq(ext_a_refusals.size(), 0, "ext A first add of a new name → not refused")
	testing.ok(registry.has_command("shared.tool"), "ext A's command is registered")

	registry.begin_extension_load()
	registry.add("shared.tool", testing.noop, MCPToolkitCommandOptions.new())  # ext B — refused
	var ext_b_refusals := registry.end_extension_load()
	testing.eq(ext_b_refusals.size(), 1, "ext B duplicate of the same new name → refused (first-writer-wins)")
	testing.ok(registry.get_command_metadata("shared.tool")["annotations"]["idempotentHint"],
			"ext A's options win — ext B did not overwrite")

	# 3. Refusal is per-name, not all-or-nothing: a non-colliding add in the SAME
	#    load still succeeds alongside a refused one.
	registry.begin_extension_load()
	registry.add("acme.do_thing", testing.noop, MCPToolkitCommandOptions.new())  # collides → refused
	registry.add("acme.brand_new", testing.noop, MCPToolkitCommandOptions.new())  # new → lands
	var mixed_load_refusals := registry.end_extension_load()
	testing.eq(mixed_load_refusals.size(), 1, "mixed load → exactly the colliding name refused")
	testing.eq(str(mixed_load_refusals[0].get("method", "")), "acme.do_thing", "the colliding name is the refused one")
	testing.ok(registry.has_command("acme.brand_new"), "non-colliding add in the same load still succeeds")

	# 4. Idempotent reload: a name that was REMOVED first is no longer present, so
	#    re-adding it during the next load is NOT a collision (the loader removes a
	#    modified/removed extension's methods before re-registering — its own name
	#    must re-register, only a FOREIGN name is refused).
	registry.remove("acme.brand_new")
	registry.begin_extension_load()
	registry.add("acme.brand_new", testing.noop, MCPToolkitCommandOptions.new())  # re-add own just-removed name
	var readd_refusals := registry.end_extension_load()
	testing.eq(readd_refusals.size(), 0, "re-adding a just-removed own name → not refused")
	testing.ok(registry.has_command("acme.brand_new"), "extension re-registers its own command after removal")

	# 5. Outside a load window, add() keeps its documented last-writer-wins
	#    behaviour (the guard is scoped strictly to begin/end_extension_load).
	registry.add("acme.brand_new", testing.noop, MCPToolkitCommandOptions.new().mark_read_only())
	testing.ok(registry.is_read_only("acme.brand_new"),
			"no active load window → add() still overwrites (last-writer-wins)")

	print("")


# --- Extension support: candidate + addon-enabled detection ---------------
# extension_support.gd is the shared leaf both discovery and the watcher consume.
# is_extension_candidate and is_addon_enabled are the pure shape-detection
# boundaries: GDScript extensions are matched by base class, C# ones by the
# MCPToolkit prefix on a .cs path, and a script outside a formal (plugin.cfg)
# addon is always enabled. Pure — no editor, no real extension files (the
# disabled-addon branch needs EditorInterface and is left to the interactive sweep).
static func _test_extension_support(testing) -> void:
	testing.begin("Extension support (candidate + addon-enabled)")

	# is_extension_candidate — GDScript matched by base class.
	testing.ok(ExtensionSupport.is_extension_candidate({"base": "MCPToolkitExtension"}),
			"GDScript base == MCPToolkitExtension → candidate")
	# C# matched by MCPToolkit prefix on a .cs path (can't extend the GDScript base).
	testing.ok(ExtensionSupport.is_extension_candidate({"class": "MCPToolkitFoo", "path": "res://foo.cs"}),
			"C# MCPToolkit-prefixed .cs → candidate")
	# Negatives: prefix without .cs, .cs without prefix, unrelated base, empty.
	testing.ok(not ExtensionSupport.is_extension_candidate({"class": "MCPToolkitFoo", "path": "res://foo.gd"}),
			"MCPToolkit-prefixed but .gd (no GDScript base) → not a candidate")
	testing.ok(not ExtensionSupport.is_extension_candidate({"class": "PlainCs", "path": "res://plain.cs"}),
			"non-prefixed .cs → not a candidate")
	testing.ok(not ExtensionSupport.is_extension_candidate({"base": "RefCounted", "class": "Internal"}),
			"unrelated base class → not a candidate")
	testing.ok(not ExtensionSupport.is_extension_candidate({}),
			"empty entry → not a candidate")

	# is_addon_enabled — a script outside res://addons/ has no addon toggle → enabled.
	testing.ok(ExtensionSupport.is_addon_enabled("res://my_ext.gd"),
			"non-addon path → enabled")
	testing.ok(ExtensionSupport.is_addon_enabled("res://scenes/foo/bar.gd"),
			"nested non-addon path → enabled")
	# A path under res://addons/<name>/ where <name> has no plugin.cfg is not a
	# formal addon (no toggle mechanism) → enabled. Uses a name that does not exist
	# on disk, so file_exists is deterministically false headlessly.
	testing.ok(ExtensionSupport.is_addon_enabled("res://addons/_nonexistent_addon_xyz/ext.gd"),
			"addons/ path with no plugin.cfg → enabled (not a formal addon)")

	print("")


# --- Onboarding wizard step specs ----------------------------------------
# The wizard renders each step from a pure "spec" (text + ok_label + ordered
# buttons + optional on_enter side-effect) via one generic renderer. These pins
# lock the exact text-presence, ok-labels, and button (label, action) lists per
# step — including BOTH .mcp.json variants — so the DRY refactor can't silently
# drift the user-visible wizard. The builders are pure (no dialog, no editor):
# constructed with null collaborators, the specs build without an editor and the
# step-2 on_enter (which would reveal the dock) is never invoked here.

static func _assert_buttons(testing, buttons: Array, expected: Array, label: String) -> void:
	# expected is [[label, action], ...] in order. Asserts count then each entry.
	testing.eq(buttons.size(), expected.size(), "%s → button count" % label)
	for i in expected.size():
		if i >= buttons.size():
			break
		var got: Dictionary = buttons[i]
		var want: Array = expected[i]
		testing.eq(str(got.get("label", "")), str(want[0]), "%s → button %d label" % [label, i])
		testing.eq(str(got.get("action", "")), str(want[1]), "%s → button %d action" % [label, i])


static func _test_onboarding_wizard_specs(testing) -> void:
	testing.begin("Onboarding wizard step specs")
	var wizard := OnboardingWizard.new(null, null, null, null)

	# Step 0 — welcome: non-empty text, "Next", single Security-Doc button.
	var welcome_spec: Dictionary = wizard._spec_welcome()
	testing.ok(not str(welcome_spec.get("text", "")).is_empty(), "step 0 → text non-empty")
	testing.eq(str(welcome_spec.get("ok_label", "")), "Next", "step 0 → ok_label")
	_assert_buttons(testing, welcome_spec.get("buttons", []),
			[["Open Security Doc", "open_security"]], "step 0")
	testing.ok(not welcome_spec.has("on_enter"), "step 0 → no on_enter")

	# Step 1 variant A — .mcp.json EXISTS: keep-existing OK + an overwrite button.
	var mcp_json_exists_spec: Dictionary = wizard._spec_mcp_json(true)
	testing.ok(not str(mcp_json_exists_spec.get("text", "")).is_empty(), "step 1 (exists) → text non-empty")
	testing.ok(str(mcp_json_exists_spec.get("text", "")).contains("already exists"),
			"step 1 (exists) → names the existing-file case")
	testing.eq(str(mcp_json_exists_spec.get("ok_label", "")), "Continue (keep existing .mcp.json)",
			"step 1 (exists) → ok_label keeps existing")
	_assert_buttons(testing, mcp_json_exists_spec.get("buttons", []),
			[["Overwrite with clean .mcp.json", "overwrite_mcp"]], "step 1 (exists)")

	# Step 1 variant B — .mcp.json ABSENT: create-it OK + NO custom buttons.
	var mcp_json_absent_spec: Dictionary = wizard._spec_mcp_json(false)
	testing.ok(str(mcp_json_absent_spec.get("text", "")).contains("No .mcp.json was found"),
			"step 1 (absent) → names the missing-file case")
	testing.eq(str(mcp_json_absent_spec.get("ok_label", "")), "Create .mcp.json",
			"step 1 (absent) → ok_label creates")
	_assert_buttons(testing, mcp_json_absent_spec.get("buttons", []), [], "step 1 (absent)")

	# Step 2 — dock overview: "Close" OK, Back then Open-Info, and an on_enter.
	var dock_overview_spec: Dictionary = wizard._spec_dock_overview()
	testing.ok(not str(dock_overview_spec.get("text", "")).is_empty(), "step 2 → text non-empty")
	testing.eq(str(dock_overview_spec.get("ok_label", "")), "Close", "step 2 → ok_label")
	_assert_buttons(testing, dock_overview_spec.get("buttons", []),
			[["Back", "back"], ["Open Info", "open_info"]], "step 2")
	testing.ok(dock_overview_spec.get("on_enter") is Callable, "step 2 → on_enter is a Callable")

	# Dispatcher routes by _step and records _mcp_exists when step 1 renders.
	wizard._step = 0
	testing.eq(str(wizard._spec_for_step().get("ok_label", "")), "Next", "dispatch step 0 → welcome spec")
	wizard._step = 1
	var dispatched_step1_spec: Dictionary = wizard._spec_for_step()
	# The FS probe sets _mcp_exists; the spec variant must agree with it (the exact
	# value is environmental — assert the two are consistent, not which branch ran).
	if wizard._mcp_exists:
		testing.eq(str(dispatched_step1_spec.get("ok_label", "")), "Continue (keep existing .mcp.json)",
				"dispatch step 1 → spec matches _mcp_exists=true")
	else:
		testing.eq(str(dispatched_step1_spec.get("ok_label", "")), "Create .mcp.json",
				"dispatch step 1 → spec matches _mcp_exists=false")
	wizard._step = 2
	testing.eq(str(wizard._spec_for_step().get("ok_label", "")), "Close", "dispatch step 2 → dock spec")

	print("")


# --- Command-entry wire-shape builder (the Published-Language contract pin) --

static func _test_build_command_entry(testing) -> void:
	testing.begin("build_command_entry (extensions.list/refresh/changed wire shape)")

	# This group locks the per-command wire shape that extensions.list,
	# extensions.refresh, and extensions.changed all share via build_command_entry.
	# Any future drift in which fields are present (and the present-iff-non-empty
	# rule) breaks the MCP bridge contract — this group catches it headlessly.
	var registry := MCPToolkitCommandRegistry.new()
	var noop := func(_p: Dictionary) -> Dictionary: return {}

	# A command with every metadata field populated, plus a non-default timeout.
	registry.add("ext.full", noop, MCPToolkitCommandOptions.new()
		.with_description("Full entry")
		.with_input_schema({"type": "object", "properties": {"x": {"type": "string"}}})
		.with_group("grp", "Group desc", ["kw1", "kw2"])
		.with_timeout_ms(5000))
	var full := ExtensionMetaCommands.build_command_entry(registry, "ext.full")
	testing.eq(full.get("method", ""), "ext.full", "full → method seed present")
	testing.eq(full.get("description", ""), "Full entry", "full → description present")
	testing.ok(full.has("input_schema") and not full.get("input_schema", {}).is_empty(),
			"full → input_schema present (non-empty)")
	testing.ok(full.has("annotations"), "full → annotations present (registry always sets them)")
	testing.ok(full.has("group") and full.get("group", {}).get("name", "") == "grp",
			"full → group present with name")
	testing.ok(full.get("group", {}).get("keywords", []).has("kw1"),
			"full → group keywords carried through (the refresh hint source)")
	testing.eq(full.get("timeout_ms", -1), 5000, "full → non-default timeout_ms present")

	# A command with no description/schema/group and the default timeout: every
	# omittable field must be ABSENT (present-iff-non-empty), but method seed and
	# the always-built annotations must be present.
	registry.add("ext.minimal", noop, MCPToolkitCommandOptions.new())
	var minimal := ExtensionMetaCommands.build_command_entry(registry, "ext.minimal")
	testing.eq(minimal.get("method", ""), "ext.minimal", "minimal → method seed present")
	testing.ok(not minimal.has("description"), "minimal → description omitted (empty)")
	testing.ok(not minimal.has("input_schema"), "minimal → input_schema omitted (empty)")
	testing.ok(not minimal.has("group"), "minimal → group omitted (empty)")
	testing.ok(not minimal.has("timeout_ms"), "minimal → timeout_ms omitted (default)")
	testing.ok(minimal.has("annotations"), "minimal → annotations present (always built)")

	# An unregistered method yields just the method seed (empty metadata → all omitted).
	var unknown := ExtensionMetaCommands.build_command_entry(registry, "ext.unknown")
	testing.eq(unknown.size(), 1, "unknown method → entry holds only the method seed")
	testing.eq(unknown.get("method", ""), "ext.unknown", "unknown method → method seed present")

	print("")


# --- Watcher set-diff kernel (add/remove/retry classification) ------------
# compute_class_diff is the pure heart of the watcher's hot-reload rescan,
# extracted so the add/remove/retry classification is testable without an editor
# or real extension files. It takes the freshly-scanned class set plus the
# watcher's known + previously-failed dicts and returns {added, removed, retry}.
# The load-bearing edge: `retry` is computed AGAINST `added` — a previously-failed
# class that is ALSO newly-added counts as added, not a retry (no double-load).
static func _test_compute_class_diff(testing) -> void:
	testing.begin("Watcher set-diff kernel (add/remove/retry classification)")

	# A class only in `current` → added; carries its path.
	var added_diff := ExtensionWatcher.compute_class_diff(
		{"NewExt": "res://new.gd"}, {}, {})
	testing.ok(added_diff["added"].has("NewExt"), "class only in current → added")
	testing.eq(added_diff["added"].get("NewExt", ""), "res://new.gd", "added carries the script path")
	testing.ok(added_diff["removed"].is_empty(), "nothing known → removed empty")
	testing.ok(added_diff["retry"].is_empty(), "nothing failed → retry empty")

	# A class only in `known` → removed (by name); not added.
	var removed_diff := ExtensionWatcher.compute_class_diff(
		{}, {"GoneExt": "res://gone.gd"}, {})
	testing.ok("GoneExt" in removed_diff["removed"], "class only in known → removed")
	testing.ok(removed_diff["added"].is_empty(), "nothing current → added empty")

	# A class in `failed` ∩ `current`, NOT newly-added (also in known) → retry.
	var retry_diff := ExtensionWatcher.compute_class_diff(
		{"FixedExt": "res://fixed.gd"},
		{"FixedExt": "res://fixed.gd"},
		{"FixedExt": true})
	testing.ok(retry_diff["retry"].has("FixedExt"), "failed ∩ current (known) → retry")
	testing.eq(retry_diff["retry"].get("FixedExt", ""), "res://fixed.gd", "retry carries the script path")
	testing.ok(retry_diff["added"].is_empty(), "already known → not added")
	testing.ok(retry_diff["removed"].is_empty(), "still present → not removed")

	# A failed class that is ALSO newly-added (not in known) counts as added, not
	# retry — `retry` excludes anything already in `added` (no double-load).
	var failed_but_new_diff := ExtensionWatcher.compute_class_diff(
		{"FlakyExt": "res://flaky.gd"}, {}, {"FlakyExt": true})
	testing.ok(failed_but_new_diff["added"].has("FlakyExt"), "failed + new → added")
	testing.ok(failed_but_new_diff["retry"].is_empty(), "failed + new → NOT retry (excluded by added)")

	# An unchanged class (in both current and known, not failed) → in none.
	var unchanged_diff := ExtensionWatcher.compute_class_diff(
		{"StableExt": "res://stable.gd"},
		{"StableExt": "res://stable.gd"},
		{})
	testing.ok(unchanged_diff["added"].is_empty(), "unchanged → not added")
	testing.ok(unchanged_diff["removed"].is_empty(), "unchanged → not removed")
	testing.ok(unchanged_diff["retry"].is_empty(), "unchanged → not retried")

	# Empty inputs → empty delta on every axis.
	var empty_diff := ExtensionWatcher.compute_class_diff({}, {}, {})
	testing.ok(empty_diff["added"].is_empty() and empty_diff["removed"].is_empty() and empty_diff["retry"].is_empty(),
			"empty inputs → empty delta")

	print("")


# --- Extension path-guard (dispatch enforcement) --------------------------
# Builder → to_dict → registry storage → dispatch enforcement (toolkit-side).
static func _test_extension_path_guard(testing) -> void:
	testing.begin("Extension path-guard (dispatch enforcement)")
	# Builder serializes path_guards.
	var options_dict := MCPToolkitExtensionOptions.new("test") \
		.guard_project_path("file_path") \
		.guard_user_path("slot").to_dict()
	var path_guards: Dictionary = options_dict.get("path_guards", {})
	testing.eq(path_guards.get("file_path", ""), "project", "guard_project_path → path_guards.file_path=project")
	testing.eq(path_guards.get("slot", ""), "user", "guard_user_path → path_guards.slot=user")
	testing.ok(not MCPToolkitExtensionOptions.new("plain").to_dict().has("path_guards"),
		"no guard methods → no path_guards key")
	# Registry stores + exposes the guards.
	var registry := MCPToolkitCommandRegistry.new()
	registry.add("ext.guarded", testing.noop, MCPToolkitExtensionOptions.new("g").guard_project_path("file_path"))
	testing.eq(registry.path_guards("ext.guarded").get("file_path", ""), "project", "registry stores path_guards")
	testing.eq(registry.path_guards("unknown.method"), {}, "registry path_guards(unknown) → {}")
	# Dispatch enforcement: a traversal path is rejected BEFORE the handler runs.
	var denied: Dictionary = await registry.call_command("ext.guarded", {"file_path": "res://../escape.gd"})
	testing.eq(denied.get("success"), false, "dispatch rejects traversal path")
	testing.eq(denied.get("code", ""), "PATH_DENIED", "dispatch rejection code = PATH_DENIED")
	# A valid res:// path passes the guard (handler runs → testing.noop success).
	var allowed: Dictionary = await registry.call_command("ext.guarded", {"file_path": "res://ok.gd"})
	testing.eq(allowed.get("success"), true, "dispatch allows valid res:// path")
	# Absent param defers to the handler (an unprovided optional path is not a rejection).
	var absent: Dictionary = await registry.call_command("ext.guarded", {})
	testing.eq(absent.get("success"), true, "dispatch skips absent path param")
	# user-guard rejects a res:// value.
	registry.add("ext.user", testing.noop, MCPToolkitExtensionOptions.new("u").guard_user_path("slot"))
	var bad_user: Dictionary = await registry.call_command("ext.user", {"slot": "res://nope.gd"})
	testing.eq(bad_user.get("success"), false, "user-guard rejects res:// value")
	var ok_user: Dictionary = await registry.call_command("ext.user", {"slot": "user://saves/s.json"})
	testing.eq(ok_user.get("success"), true, "user-guard allows user:// value")
	# A command with NO guards is never filtered (built-in parity).
	registry.add("ext.plain", testing.noop, MCPToolkitExtensionOptions.new("p"))
	var passthru: Dictionary = await registry.call_command("ext.plain", {"file_path": "res://../escape.gd"})
	testing.eq(passthru.get("success"), true, "no path_guards → not filtered")
