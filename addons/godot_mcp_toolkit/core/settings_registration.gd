@tool
extends RefCounted
## ProjectSettings registration for limits, audit, and bootstrap keys.
##
## Called once at plugin startup to ensure mcp_toolkit/* keys appear
## in the Project Settings inspector with correct types and defaults, and the
## keys the dock also edits with the same ranges as the dock's spin boxes.

const _BOOTSTRAP_KEY := "mcp_toolkit/internal/bootstrap_complete"

const _LIMITS_NOTE_KEY := "mcp_toolkit/limits/env_override_note"
const _LIMITS_NOTE_TEXT := (
	"These values can be overridden by GODOT_MCP_SCRIPT_READ_LIMIT and "
	+ "GODOT_MCP_WS_BUFFER_LIMIT env vars in .mcp.json. "
	+ "When set, the env var values take priority on connect.")


static func register_all() -> void:
	_register_limits()
	_register_concurrency()
	_register_audit()
	_register_bootstrap_flag()
	# One-way migration: mcp_toolkit/status was persisted by earlier versions and
	# is no longer written, so erase whatever a project still carries — the value
	# describes the machine the editor runs on and has no place in project.godot.
	# The erase is in-memory only: register_all() deliberately never saves, so the
	# key leaves project.godot at the next ProjectSettings save, from whatever source.
	# Removable at 2.0.0 — only 1.0.0 and 1.0.1 ever wrote the key.
	if ProjectSettings.has_setting("mcp_toolkit/status"):
		ProjectSettings.set_setting("mcp_toolkit/status", null)


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


static func _register_limits() -> void:
	# Max script content returned by script.read, in KB.
	_register_basic_ranged_int("mcp_toolkit/limits/script_read_cap_kb", 256, "64,4096,64")
	# Max user-file content returned per save.read window, in KB.
	_register_basic_ranged_int("mcp_toolkit/limits/save_read_cap_kb", 256, "64,4096,64")
	# WebSocket per-peer buffer size, in KB.
	_register_basic_ranged_int("mcp_toolkit/limits/ws_buffer_kb", 1024, "256,8192,256")
	_register_limits_note()


static func _register_concurrency() -> void:
	_register_basic_int("mcp_toolkit/concurrency/scan_idle_timeout_ms", 5000,
		"How long a scene save/open waits for the EditorFileSystem scan to finish before aborting, in ms. 0 = fail-fast; recommended 1000-30000. Higher lets slow-import projects finish scanning at the cost of longer save stalls. Not clamped.")
	_register_basic_int("mcp_toolkit/concurrency/mutation_watchdog_grace_ms", 60000,
		"Grace added to a mutation's deadline before the dispatch watchdog force-clears a wedged lock, in ms. Added to the command's declared timeout (or the 300s ceiling for undeclared commands). The watchdog is a safety net that should normally never fire. Not clamped.")


static func _register_audit() -> void:
	_register_basic_bool("mcp_toolkit/audit/enabled", true,
		"Enable MCP audit log at user://addons/godot_mcp_toolkit/project_instance_<hash>/mcp_audit.log.")
	# Max audit log size in KB. 0 = unlimited. Log truncates to 50% when exceeded.
	_register_basic_ranged_int("mcp_toolkit/audit/max_size_kb", 1024, "0,10240,128")


static func _register_bootstrap_flag() -> void:
	if not ProjectSettings.has_setting(_BOOTSTRAP_KEY):
		ProjectSettings.set_setting(_BOOTSTRAP_KEY, false)
	ProjectSettings.set_initial_value(_BOOTSTRAP_KEY, false)


static func _register_limits_note() -> void:
	ProjectSettings.set_setting(_LIMITS_NOTE_KEY, _LIMITS_NOTE_TEXT)
	ProjectSettings.set_initial_value(_LIMITS_NOTE_KEY, _LIMITS_NOTE_TEXT)
	ProjectSettings.set_as_basic(_LIMITS_NOTE_KEY, true)
	ProjectSettings.add_property_info({
		"name": _LIMITS_NOTE_KEY, "type": TYPE_STRING,
		"hint": PROPERTY_HINT_MULTILINE_TEXT,
		"hint_string": "Read-only — env var override information.",
	})


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


# Creates the key with its default only when it is absent, so a value the project
# already stores is never clobbered, then registers it as a basic setting with its
# inspector hint.
static func _register_basic(
		key: String, variant_type: int, default_value: Variant,
		hint: int, hint_string: String) -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default_value)
	ProjectSettings.set_initial_value(key, default_value)
	ProjectSettings.set_as_basic(key, true)
	ProjectSettings.add_property_info({
		"name": key, "type": variant_type,
		"hint": hint, "hint_string": hint_string,
	})
