@tool
extends RefCounted
## ProjectSettings registration for limits, audit, and bootstrap keys.
##
## Called once at plugin startup to ensure mcp_toolkit/* keys appear
## in the Project Settings inspector with correct types and defaults.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const MCPJsonSync = Modules.MCPJsonSync
const NodejsCheck = Modules.NodejsCheck

const _BOOTSTRAP_KEY := "mcp_toolkit/internal/bootstrap_complete"

const _LIMITS_NOTE_KEY := "mcp_toolkit/limits/env_override_note"
const _LIMITS_NOTE_TEXT := (
	"These values can be overridden by GODOT_MCP_SCRIPT_READ_LIMIT and "
	+ "GODOT_MCP_WS_BUFFER_LIMIT env vars in .mcp.json. "
	+ "When set, the env var values take priority on connect.")

const _STATUS_KEY := "mcp_toolkit/status"
const _READ_ONLY_WARNING_TEXT := (
	"READ-ONLY MODE ACTIVE (GODOT_MCP_READ_ONLY=1) — "
	+ "Only read-only tools are available. Mutating tools are hidden. "
	+ "Remove GODOT_MCP_READ_ONLY from .mcp.json and reconnect "
	+ "the MCP client to restore full access.")
const _MCP_JSON_MISSING_TEXT := (
	"No .mcp.json found — use Project > Tools > MCP Toolkit > "
	+ "Write .mcp.json to create one.")
const _NODEJS_NOT_FOUND_TEXT := (
	"NODE.JS NOT FOUND — The MCP server bridge requires Node.js 22+. "
	+ "Download it from https://nodejs.org")
const _NODEJS_OLD_VERSION_TEXT := (
	"NODE.JS %s FOUND BUT 22+ REQUIRED — "
	+ "Update from https://nodejs.org")


static func register_all() -> void:
	_register_limits()
	_register_concurrency()
	_register_audit()
	_register_bootstrap_flag()
	_register_status_field()
	# Clean up old status key location (was under feature_gates/).
	if ProjectSettings.has_setting("mcp_toolkit/feature_gates/status"):
		ProjectSettings.set_setting("mcp_toolkit/feature_gates/status", null)


## Mirror of register_all — scrub every mcp_toolkit/* ProjectSettings key on
## uninstall (_disable_plugin only). Prefix-scans the live property list so it
## covers all current + future mcp_toolkit/* keys (incl. the legacy
## feature_gates/ one) with no hardcoded list to go stale, then persists
## project.godot. Never call on _exit_tree (that fires every reload).
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
	_register_basic_int("mcp_toolkit/limits/script_read_cap_kb", 256,
		"Max script content returned by script.read, in KB. Minimum 64.")
	_register_basic_int("mcp_toolkit/limits/save_read_cap_kb", 256,
		"Max user-file content returned per save.read window, in KB. Minimum 64.")
	_register_basic_int("mcp_toolkit/limits/ws_buffer_kb", 1024,
		"WebSocket per-peer buffer size, in KB. Minimum 256.")
	_register_limits_note()


static func _register_concurrency() -> void:
	_register_basic_int("mcp_toolkit/concurrency/scan_idle_timeout_ms", 5000,
		"How long a scene save/open waits for the EditorFileSystem scan to finish before aborting, in ms. 0 = fail-fast; recommended 1000-30000. Higher lets slow-import projects finish scanning at the cost of longer save stalls. Not clamped.")
	_register_basic_int("mcp_toolkit/concurrency/mutation_watchdog_grace_ms", 60000,
		"Grace added to a mutation's deadline before the dispatch watchdog force-clears a wedged lock, in ms. Added to the command's declared timeout (or the 300s ceiling for undeclared commands). The watchdog is a safety net that should normally never fire. Not clamped.")


static func _register_audit() -> void:
	_register_basic_bool("mcp_toolkit/audit/enabled", true,
		"Enable MCP audit log at user://addons/godot_mcp_toolkit/project_instance_<hash>/mcp_audit.log.")
	_register_basic_int("mcp_toolkit/audit/max_size_kb", 1024,
		"Max audit log size in KB. 0 = unlimited. Log truncates to 50% when exceeded.")


static func _register_bootstrap_flag() -> void:
	if not ProjectSettings.has_setting(_BOOTSTRAP_KEY):
		ProjectSettings.set_setting(_BOOTSTRAP_KEY, false)
	ProjectSettings.set_initial_value(_BOOTSTRAP_KEY, false)


static func _register_status_field() -> void:
	var text := _compute_status_text()
	if not ProjectSettings.has_setting(_STATUS_KEY):
		ProjectSettings.set_setting(_STATUS_KEY, text)
	else:
		ProjectSettings.set_setting(_STATUS_KEY, text)
	ProjectSettings.set_initial_value(_STATUS_KEY, "")
	ProjectSettings.set_as_basic(_STATUS_KEY, true)
	ProjectSettings.set_order(_STATUS_KEY, 1000)
	ProjectSettings.add_property_info({
		"name": _STATUS_KEY, "type": TYPE_STRING,
		"hint": PROPERTY_HINT_MULTILINE_TEXT,
		"hint_string": "Read-only status display — value is managed by the plugin.",
	})


static func _compute_status_text() -> String:
	var parts := PackedStringArray()
	# Read-only mode check.
	var env := MCPJsonSync.get_all_env_vars()
	if env.get("GODOT_MCP_READ_ONLY", "") == "1":
		parts.append(_READ_ONLY_WARNING_TEXT)
	# .mcp.json presence.
	if not MCPJsonSync.has_mcp_json():
		parts.append(_MCP_JSON_MISSING_TEXT)
	# Node.js availability.
	var node_check := NodejsCheck.check()
	if not node_check["found"]:
		parts.append(_NODEJS_NOT_FOUND_TEXT)
	elif not node_check["meets_minimum"]:
		parts.append(_NODEJS_OLD_VERSION_TEXT % str(node_check["version"]))
	return "\n\n".join(parts)


static func _register_limits_note() -> void:
	ProjectSettings.set_setting(_LIMITS_NOTE_KEY, _LIMITS_NOTE_TEXT)
	ProjectSettings.set_initial_value(_LIMITS_NOTE_KEY, _LIMITS_NOTE_TEXT)
	ProjectSettings.set_as_basic(_LIMITS_NOTE_KEY, true)
	ProjectSettings.add_property_info({
		"name": _LIMITS_NOTE_KEY, "type": TYPE_STRING,
		"hint": PROPERTY_HINT_MULTILINE_TEXT,
		"hint_string": "Read-only — env var override information.",
	})


static func _register_basic_bool(key: String, default_value: bool, hint: String) -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default_value)
	ProjectSettings.set_initial_value(key, default_value)
	ProjectSettings.set_as_basic(key, true)
	ProjectSettings.add_property_info({
		"name": key, "type": TYPE_BOOL,
		"hint": PROPERTY_HINT_NONE, "hint_string": hint,
	})


static func _register_basic_int(key: String, default_value: int, hint: String) -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default_value)
	ProjectSettings.set_initial_value(key, default_value)
	ProjectSettings.set_as_basic(key, true)
	ProjectSettings.add_property_info({
		"name": key, "type": TYPE_INT,
		"hint": PROPERTY_HINT_NONE, "hint_string": hint,
	})
