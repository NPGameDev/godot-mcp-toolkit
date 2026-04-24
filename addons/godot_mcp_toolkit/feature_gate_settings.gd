@tool
extends RefCounted
## Feature-gate ProjectSettings registration and change-detection polling.
## Owns the power_user_mode sync logic and per-feature gate change detection.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPFeatureGate = _Hub.MCPFeatureGate
const MCPFeatureRegistry = _Hub.MCPFeatureRegistry
const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")

const _LIMITS_NOTE_KEY := "mcp_toolkit/limits/env_override_note"
const _LIMITS_NOTE_TEXT := (
	"These values can be overridden by GODOT_MCP_SCRIPT_READ_LIMIT and "
	+ "GODOT_MCP_WS_BUFFER_LIMIT env vars in .mcp.json. "
	+ "When set, the env var values take priority on connect.")

const _PU_WARNING_KEY := "mcp_toolkit/feature_gates/power_user_warning"
const _PU_WARNING_TEXT := (
	"POWER USER MODE ACTIVE — All feature gates enabled. "
	+ "The AI agent has full control: code execution, OS commands, "
	+ "project settings writes, and file access outside res://.")

var _last_power_user: bool = false
var _last_feature_states: Dictionary = {}  # { ps_key: bool }


func register_all() -> void:
	_register_feature_gates()
	_register_limits()
	_register_audit()
	_last_power_user = ProjectSettings.get_setting(
		"mcp_toolkit/feature_gates/power_user_mode", false)
	snapshot_feature_states()


func poll(dock: Control) -> void:
	var power_user: bool = ProjectSettings.get_setting(
		"mcp_toolkit/feature_gates/power_user_mode", false)
	if power_user != _last_power_user:
		_last_power_user = power_user
		_sync_power_user_mode(power_user, dock)
	_poll_feature_states(dock)


func snapshot_feature_states() -> void:
	_last_feature_states.clear()
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		_last_feature_states[str(entry["ps_key"])] = ProjectSettings.get_setting(
			str(entry["ps_key"]), false)


# -- Registration helpers -----------------------------------------------------


func _register_feature_gates() -> void:
	# power_user_mode — master switch, registered first so it displays first.
	_register_basic_bool("mcp_toolkit/feature_gates/power_user_mode", false,
		"WARNING: Enables ALL feature gates and grants the AI agent "
		+ "full control — code execution, OS commands, project settings writes, "
		+ "and file access outside res://. Individual gates sync automatically.")
	ProjectSettings.set_order("mcp_toolkit/feature_gates/power_user_mode", 0)

	var order_idx := 1
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		var ps_key: String = entry["ps_key"]
		var gate_label := "dual-gate: env AND PS" if entry["dual_gate"] else "single-gate: env OR PS"
		_register_basic_bool(ps_key, false,
			"DANGER: %s (%s). Default off." % [entry["risk"], gate_label])
		ProjectSettings.set_order(ps_key, order_idx)
		order_idx += 1

	# Power User warning — read-only status display at the end of Feature Gates.
	_register_power_user_warning()


func _register_limits() -> void:
	_register_basic_int("mcp_toolkit/limits/script_read_cap_kb", 256,
		"Max script content returned by script.read, in KB. Minimum 64.")
	_register_basic_int("mcp_toolkit/limits/ws_buffer_kb", 1024,
		"WebSocket per-peer buffer size, in KB. Minimum 256.")
	_register_limits_note()


func _register_audit() -> void:
	_register_basic_bool("mcp_toolkit/audit/enabled", true,
		"Enable MCP audit log at user://addons/godot_mcp_toolkit/mcp_audit.log.")
	_register_basic_int("mcp_toolkit/audit/max_size_kb", 1024,
		"Max audit log size in KB. 0 = unlimited. Log truncates to 50% when exceeded.")


func _register_basic_bool(key: String, default_value: bool, hint: String) -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default_value)
	ProjectSettings.set_initial_value(key, default_value)
	ProjectSettings.set_as_basic(key, true)
	ProjectSettings.add_property_info({
		"name": key, "type": TYPE_BOOL,
		"hint": PROPERTY_HINT_NONE, "hint_string": hint,
	})


func _register_basic_int(key: String, default_value: int, hint: String) -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default_value)
	ProjectSettings.set_initial_value(key, default_value)
	ProjectSettings.set_as_basic(key, true)
	ProjectSettings.add_property_info({
		"name": key, "type": TYPE_INT,
		"hint": PROPERTY_HINT_NONE, "hint_string": hint,
	})


func _register_limits_note() -> void:
	ProjectSettings.set_setting(_LIMITS_NOTE_KEY, _LIMITS_NOTE_TEXT)
	ProjectSettings.set_initial_value(_LIMITS_NOTE_KEY, _LIMITS_NOTE_TEXT)
	ProjectSettings.set_as_basic(_LIMITS_NOTE_KEY, true)
	ProjectSettings.add_property_info({
		"name": _LIMITS_NOTE_KEY, "type": TYPE_STRING,
		"hint": PROPERTY_HINT_MULTILINE_TEXT,
		"hint_string": "Read-only — env var override information.",
	})


func _register_power_user_warning() -> void:
	if not ProjectSettings.has_setting(_PU_WARNING_KEY):
		ProjectSettings.set_setting(_PU_WARNING_KEY, "")
	ProjectSettings.set_initial_value(_PU_WARNING_KEY, "")
	ProjectSettings.set_as_basic(_PU_WARNING_KEY, true)
	ProjectSettings.set_order(_PU_WARNING_KEY, 1000)
	ProjectSettings.add_property_info({
		"name": _PU_WARNING_KEY, "type": TYPE_STRING,
		"hint": PROPERTY_HINT_MULTILINE_TEXT,
		"hint_string": "Read-only status display — value is managed by the plugin.",
	})
	_update_power_user_warning()


func _update_power_user_warning() -> void:
	var enabled: bool = ProjectSettings.get_setting(
		"mcp_toolkit/feature_gates/power_user_mode", false)
	ProjectSettings.set_setting(_PU_WARNING_KEY, _PU_WARNING_TEXT if enabled else "")


# -- Power user mode sync -----------------------------------------------------


func _sync_power_user_mode(enable: bool, dock: Control) -> void:
	_update_power_user_warning()
	# Guard: skip full sync if the dock already applied this change.
	if enable and MCPFeatureGate.has_power_user_cache():
		# Dock already snapshotted + set keys — just refresh UI.
		if dock != null:
			dock._refresh_features()
		return
	if not enable and not MCPFeatureGate.has_power_user_cache():
		# Dock already restored + cleared cache — just refresh UI.
		snapshot_feature_states()
		if dock != null:
			dock._refresh_features()
		return
	if enable:
		MCPFeatureGate.snapshot_pre_power_user()
		for feature in MCPFeatureRegistry.all_features():
			var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
			ProjectSettings.set_setting(str(entry["ps_key"]), true)
		if MCPJsonSync.has_mcp_json():
			for feature in MCPFeatureRegistry.all_features():
				var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
				MCPJsonSync.set_env_var(str(entry["env_var"]), true)
	else:
		MCPFeatureGate.restore_pre_power_user()
		if MCPJsonSync.has_mcp_json():
			for feature in MCPFeatureRegistry.all_features():
				var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
				var ps_on: bool = ProjectSettings.get_setting(str(entry["ps_key"]), false)
				MCPJsonSync.set_env_var(str(entry["env_var"]), ps_on)
	_update_power_user_warning()
	ProjectSettings.save()
	snapshot_feature_states()
	if dock != null:
		dock._refresh_features()
		dock._notify_restart_required()


# -- Per-feature polling -------------------------------------------------------


func _poll_feature_states(dock: Control) -> void:
	# Enforce read-only text fields — revert any user edits immediately.
	var power_user: bool = ProjectSettings.get_setting(
		"mcp_toolkit/feature_gates/power_user_mode", false)
	var expected_warning := _PU_WARNING_TEXT if power_user else ""
	if ProjectSettings.get_setting(_PU_WARNING_KEY, "") != expected_warning:
		ProjectSettings.set_setting(_PU_WARNING_KEY, expected_warning)
	if ProjectSettings.get_setting(_LIMITS_NOTE_KEY, "") != _LIMITS_NOTE_TEXT:
		ProjectSettings.set_setting(_LIMITS_NOTE_KEY, _LIMITS_NOTE_TEXT)

	# If Power User Mode is active, revert any individual gate changes
	# made from the ProjectSettings UI and warn the user.
	if power_user:
		var reverted := false
		for feature in MCPFeatureRegistry.all_features():
			var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
			var ps_key: String = entry["ps_key"]
			var current: bool = ProjectSettings.get_setting(ps_key, false)
			if not current:
				ProjectSettings.set_setting(ps_key, true)
				_last_feature_states[ps_key] = true
				reverted = true
		if reverted:
			ProjectSettings.save()
			if dock != null:
				dock._warn_power_user_locked()
		return

	if not MCPJsonSync.has_mcp_json():
		return
	var changed := false
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		var ps_key: String = entry["ps_key"]
		var current: bool = ProjectSettings.get_setting(ps_key, false)
		var prev: bool = _last_feature_states.get(ps_key, false)
		if current != prev:
			_last_feature_states[ps_key] = current
			if entry["dual_gate"]:
				MCPJsonSync.set_env_var(str(entry["env_var"]), current)
				changed = true
	if changed:
		if dock != null:
			dock._refresh_features()
			dock._notify_restart_required()
