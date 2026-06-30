@tool
extends RefCounted
## Runtime-autoload self-heal unit tests: the const-match drift guard (the heal's
## registration set must equal export_strip's strip set, or the autoload ships in
## builds) and the pure _compute_missing_autoloads decision (empty / all-present /
## partial present). Exercises plugin.gd's on-load heal logic headless, no editor.

const Plugin := preload("res://addons/godot_mcp_toolkit/plugin.gd")
const ExportStrip := preload("res://addons/godot_mcp_toolkit/core/export_strip.gd")


static func run(testing) -> void:
	_test_const_match_drift_guard(testing)
	_test_compute_missing_autoloads(testing)


# --- Drift guard: heal registration set == export_strip strip set -------------
# The on-load heal registers _REQUIRED_AUTOLOADS as "autoload/<name>" = "*<path>".
# export_strip nulls exactly "autoload/MCPRuntimeServer" for the bake and restores
# it after. If the two ever disagree (a renamed autoload, a second one added on one
# side only), the autoload would ship in the exported PCK. This pins the equality so
# any future divergence fails here instead of leaking into builds. Preloading
# plugin.gd headless is the same @tool-extends-Editor* read serialize_io_tests does
# for export_strip.gd — const-reads don't instantiate the EditorPlugin.
static func _test_const_match_drift_guard(testing) -> void:
	testing.begin("Runtime-autoload heal set matches export-strip set")

	# Derive the heal's registration set from _REQUIRED_AUTOLOADS the same way
	# _ensure_autoloads_registered() writes it: key "autoload/<name>", value "*<path>".
	var heal_set: Dictionary = {}
	for entry in Plugin._REQUIRED_AUTOLOADS:
		var name: String = entry[0]
		var path: String = entry[1]
		heal_set["autoload/" + name] = "*" + path

	# export_strip's single-autoload key/value pair, as the set it nulls + restores.
	var strip_set: Dictionary = {ExportStrip._AUTOLOAD_KEY: ExportStrip._AUTOLOAD_VAL}

	testing.eq(heal_set, strip_set,
			"_REQUIRED_AUTOLOADS-derived set == export_strip _AUTOLOAD_KEY/_VAL (no drift)")
	# Pin the count too: a second autoload added on only one side would still need
	# both sides updated in lockstep, and this catches a one-sided addition.
	testing.eq(heal_set.size(), 1, "exactly one required autoload today")

	print("")


# --- Pure _compute_missing_autoloads decision --------------------------------
# Plain-data-in (the present-key set + the required pairs), plain-data-out (the
# subset of required whose "autoload/<name>" key is absent). No ProjectSettings, no
# Callable — the side-effecting shell does the probing/writing. Three cases: nothing
# present → all required missing; everything present → none; partial → exactly the gap.
static func _test_compute_missing_autoloads(testing) -> void:
	testing.begin("Pure _compute_missing_autoloads decision")

	# Fixture: a two-autoload required list (the production list has one, but the
	# pure fn is list-shaped, so exercise it with two to cover the partial case).
	var required: Array = [
		["MCPRuntimeServer", "res://addons/godot_mcp_toolkit/runtime/mcp_runtime_server.gd"],
		["SecondThing", "res://addons/godot_mcp_toolkit/runtime/second_thing.gd"],
	]

	# 1. Empty present → every required entry is missing (the broken-state case).
	var none_present: PackedStringArray = PackedStringArray()
	var all_missing: Array = Plugin._compute_missing_autoloads(none_present, required)
	testing.eq(all_missing.size(), 2, "empty present → all required missing")
	testing.eq(str(all_missing[0][0]), "MCPRuntimeServer", "missing list preserves entry order")

	# 2. All present → nothing missing (the healthy-project no-op case → no write).
	var all_present: PackedStringArray = PackedStringArray([
		"autoload/MCPRuntimeServer", "autoload/SecondThing"])
	var none_missing: Array = Plugin._compute_missing_autoloads(all_present, required)
	testing.ok(none_missing.is_empty(), "all present → none missing (heal is a no-op)")

	# 3. Partial present → exactly the gap (one registered, one lost out-of-band).
	var one_present: PackedStringArray = PackedStringArray(["autoload/MCPRuntimeServer"])
	var partial_missing: Array = Plugin._compute_missing_autoloads(one_present, required)
	testing.eq(partial_missing.size(), 1, "one present → exactly one missing (the gap)")
	testing.eq(str(partial_missing[0][0]), "SecondThing", "the gap is the absent entry, not the present one")

	# 4. The production list (one entry) against an empty present → that one entry.
	var prod_missing: Array = Plugin._compute_missing_autoloads(
			PackedStringArray(), Plugin._REQUIRED_AUTOLOADS)
	testing.eq(prod_missing.size(), 1, "production _REQUIRED_AUTOLOADS vs empty → the runtime autoload")
	testing.eq(str(prod_missing[0][0]), "MCPRuntimeServer", "production gap is the runtime server")

	print("")
