@tool
extends RefCounted
## ProjectSettings registration for the limits, concurrency, audit, server-pin and
## update-check keys.
##
## Called once at plugin startup to ensure mcp_toolkit/* keys appear
## in the Project Settings inspector with correct types and defaults, and the
## keys the dock also edits with the same ranges as the dock's spin boxes.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const ResponseLimits = Modules.ResponseLimits
const ServerPinPolicy = Modules.ServerPinPolicy
const UpdateCheck = Modules.UpdateCheck

# Keys earlier versions stored and this one no longer writes. Each entry is
# removable at 2.0.0.
const _RETIRED_KEYS: Array[String] = [
	# Described the machine the editor runs on; only 1.0.0 and 1.0.1 wrote it.
	"mcp_toolkit/status",
	# A free-text note on env overrides, rewritten at every start up to 1.0.3. The
	# dock now names each limit an env override controls.
	"mcp_toolkit/limits/env_override_note",
]


static func register_all() -> void:
	_register_limits()
	_register_concurrency()
	_register_audit()
	_register_server()
	_register_updates()
	# One-way migration: erase whatever retired key a project still carries. The
	# erase is in-memory only: register_all() deliberately never saves, so the key
	# leaves project.godot at the next ProjectSettings save, from whatever source.
	for retired_key in _RETIRED_KEYS:
		if ProjectSettings.has_setting(retired_key):
			ProjectSettings.set_setting(retired_key, null)


## Mirror of register_all — scrub every mcp_toolkit/* ProjectSettings key on
## uninstall (_disable_plugin only). Prefix-scans the live property list so it
## covers all current + future mcp_toolkit/* keys with no hardcoded list to go
## stale, then persists project.godot. Never call on _exit_tree (that fires
## every reload).
static func unregister_all() -> void:
	# Two-pass: collect first (read-only), then null — never mutate the property
	# list while iterating it.
	var names := _collect_mcp_setting_names()
	for name in names:
		ProjectSettings.set_setting(name, null)
	ProjectSettings.save()


## Read-only: collect every ProjectSettings key under the mcp_toolkit/ prefix.
## Side-effect-free core of unregister_all (and the only unit-testable seam) —
## scans ProjectSettings.get_property_list() and returns the matching names.
static func _collect_mcp_setting_names() -> PackedStringArray:
	var out := PackedStringArray()
	for entry in ProjectSettings.get_property_list():
		var name := str(entry.get("name", ""))
		if name.begins_with("mcp_toolkit/"):
			out.append(name)
	return out


# The response limits, from the table the dock's spin boxes also read.
static func _register_limits() -> void:
	for key in ResponseLimits.KEYS:
		_register_basic_ranged_int(ResponseLimits.setting_path(key),
				ResponseLimits.default_kb(key), ResponseLimits.range_hint(key))


static func _register_concurrency() -> void:
	_register_basic_int("mcp_toolkit/concurrency/scan_idle_timeout_ms", 5000,
		"How long a scene save/open waits for the EditorFileSystem scan to finish before aborting, in ms. 0 = fail-fast; recommended 1000-30000. Higher lets slow-import projects finish scanning at the cost of longer save stalls. Not clamped.")
	_register_basic_int("mcp_toolkit/concurrency/mutation_watchdog_grace_ms", 60000,
		"Grace added to a mutation's deadline before the dispatch watchdog force-clears a wedged lock, in ms. Added to the command's declared timeout (or the 300s ceiling for undeclared commands). The watchdog is a safety net that should normally never fire. Not clamped.")
	_register_basic_int("mcp_toolkit/concurrency/scene_lease_ttl_ms", 8000,
		"How long the scene lease holder may go without renewing before a waiting client can steal the lease, in ms. Lower hands off between clients faster but switches scene tabs more; higher switches less but a waiting client blocks longer. Not clamped.")


static func _register_audit() -> void:
	_register_basic_bool("mcp_toolkit/audit/enabled", true,
		"Enable MCP audit log at user://addons/godot_mcp_toolkit/project_instance_<hash>/mcp_audit.log.")
	# Max audit log size in KB. 0 = unlimited. Log truncates to 50% when exceeded.
	_register_basic_ranged_int("mcp_toolkit/audit/max_size_kb", 1024, "0,10240,128")


# Advanced, not basic: most projects keep the default pin, and the dock and the
# setup wizard switch between the two everyday modes.
static func _register_server() -> void:
	_register_setting(ServerPinPolicy.SERVER_VERSION_SETTING, TYPE_STRING, "", PROPERTY_HINT_NONE,
		"Server version Write .mcp.json pins. Empty = the version this toolkit was tested with (recommended); latest = always the newest; any other value is used as the npm version, range or tag (you own compatibility). Team-shared. Restart your MCP client after a change.",
		false)


# Basic: a privacy switch belongs where users see it without Advanced Settings.
static func _register_updates() -> void:
	_register_basic_bool(UpdateCheck.SETTING, true,
		"Checks GitHub at most once a day for a newer toolkit version, then the Asset Store if one exists, and shows a badge in the dock. The requests carry no identifier and nothing about your project.")


static func _register_basic_bool(key: String, default_value: bool, description: String) -> void:
	_register_basic(key, TYPE_BOOL, default_value, PROPERTY_HINT_NONE, description)


static func _register_basic_int(key: String, default_value: int, description: String) -> void:
	_register_basic(key, TYPE_INT, default_value, PROPERTY_HINT_NONE, description)


## Registers an int whose Project Settings inspector editor is bounded by
## [param range_hint] ("min,max,step"). Keep each range equal to the dock spin box
## that edits the same key, so the two surfaces accept the same values; the unit
## suite asserts that they match.
##
## The hint bounds inspector edits only and never rewrites a stored value. A value
## already stored out of range or off step (5000, or 100 on a 64-step cap) keeps
## working as stored, while the inspector and the dock show it clamped or snapped
## until someone edits it.
static func _register_basic_ranged_int(
		key: String, default_value: int, range_hint: String) -> void:
	_register_basic(key, TYPE_INT, default_value, PROPERTY_HINT_RANGE, range_hint)


static func _register_basic(
		key: String, variant_type: int, default_value: Variant,
		hint: int, hint_string: String) -> void:
	_register_setting(key, variant_type, default_value, hint, hint_string, true)


# Creates the key with its default only when it is absent, so a value the project
# already stores is never clobbered, then registers it with its inspector hint; a
# basic setting shows without the inspector's Advanced toggle.
static func _register_setting(
		key: String, variant_type: int, default_value: Variant,
		hint: int, hint_string: String, basic: bool) -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default_value)
	ProjectSettings.set_initial_value(key, default_value)
	ProjectSettings.set_as_basic(key, basic)
	ProjectSettings.add_property_info({
		"name": key, "type": variant_type,
		"hint": hint, "hint_string": hint_string,
	})
