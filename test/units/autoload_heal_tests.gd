@tool
extends RefCounted
## Runtime-autoload self-heal unit tests: the identity drift guard (the derived
## "autoload/<name>" = "*<path>" set must be the exact pair the heal registers and
## export_strip nulls-for-bake, or the autoload ships in builds) and the pure
## compute_missing decision (empty / all-present / partial present). Exercises the
## registration logic headless, no editor.

const AutoloadIdentity := preload("res://addons/godot_mcp_toolkit/core/autoload_identity.gd")
const AutoloadRegistration := preload("res://addons/godot_mcp_toolkit/core/autoload_registration.gd")


static func run(testing) -> void:
	_test_identity_derives_exact_set(testing)
	_test_compute_missing(testing)


# --- Drift guard: identity derives the exact strip/heal pair -------------------
# The runtime autoload's identity lives in one place (autoload_identity): the
# [name, path] pair(s) both the on-load heal registers ("autoload/<name>" = "*<path>")
# and export_strip nulls-for-bake then restores. Pin the derived set to the exact
# concrete key/value so a rename, a path change, or a one-sided second entry fails
# here instead of shipping the autoload in an exported PCK.
static func _test_identity_derives_exact_set(testing) -> void:
	testing.begin("Runtime-autoload identity derives the exact strip/heal set")

	# Derive the set exactly as ensure_registered() writes it and export_strip nulls
	# it: key settings_key(name), value settings_value(path), over the identity SSOT.
	var derived: Dictionary = {}
	for entry in AutoloadIdentity.REQUIRED_AUTOLOADS:
		var autoload_name: String = entry[0]
		var script_path: String = entry[1]
		derived[AutoloadIdentity.settings_key(autoload_name)] = AutoloadIdentity.settings_value(script_path)

	testing.eq(derived,
			{"autoload/MCPRuntimeServer": "*res://addons/godot_mcp_toolkit/runtime/mcp_runtime_server.gd"},
			"identity derives exactly the runtime-autoload key/value pair")
	# Pin the count too: a second autoload added to the SSOT would need every consumer
	# (heal + export strip) updated in lockstep; this catches a one-sided addition.
	testing.eq(derived.size(), 1, "exactly one required autoload today")

	print("")


# --- Pure compute_missing decision -------------------------------------------
# Plain-data-in (the present-key set + the required pairs), plain-data-out (the
# subset of required whose "autoload/<name>" key is absent). No ProjectSettings, no
# Callable — the side-effecting shell does the probing/writing. Three cases: nothing
# present → all required missing; everything present → none; partial → exactly the gap.
static func _test_compute_missing(testing) -> void:
	testing.begin("Pure compute_missing decision")

	# Fixture: a two-autoload required list (the production list has one, but the
	# pure fn is list-shaped, so exercise it with two to cover the partial case).
	var required: Array = [
		["MCPRuntimeServer", "res://addons/godot_mcp_toolkit/runtime/mcp_runtime_server.gd"],
		["SecondThing", "res://addons/godot_mcp_toolkit/runtime/second_thing.gd"],
	]

	# 1. Empty present → every required entry is missing (the broken-state case).
	var none_present: PackedStringArray = PackedStringArray()
	var all_missing: Array = AutoloadRegistration.compute_missing(none_present, required)
	testing.eq(all_missing.size(), 2, "empty present → all required missing")
	testing.eq(str(all_missing[0][0]), "MCPRuntimeServer", "missing list preserves entry order")

	# 2. All present → nothing missing (the healthy-project no-op case → no write).
	var all_present: PackedStringArray = PackedStringArray([
		"autoload/MCPRuntimeServer", "autoload/SecondThing"])
	var none_missing: Array = AutoloadRegistration.compute_missing(all_present, required)
	testing.ok(none_missing.is_empty(), "all present → none missing (heal is a no-op)")

	# 3. Partial present → exactly the gap (one registered, one lost out-of-band).
	var one_present: PackedStringArray = PackedStringArray(["autoload/MCPRuntimeServer"])
	var partial_missing: Array = AutoloadRegistration.compute_missing(one_present, required)
	testing.eq(partial_missing.size(), 1, "one present → exactly one missing (the gap)")
	testing.eq(str(partial_missing[0][0]), "SecondThing", "the gap is the absent entry, not the present one")

	# 4. The production list (one entry) against an empty present → that one entry.
	var prod_missing: Array = AutoloadRegistration.compute_missing(
			PackedStringArray(), AutoloadIdentity.REQUIRED_AUTOLOADS)
	testing.eq(prod_missing.size(), 1, "production REQUIRED_AUTOLOADS vs empty → the runtime autoload")
	testing.eq(str(prod_missing[0][0]), "MCPRuntimeServer", "production gap is the runtime server")

	print("")
