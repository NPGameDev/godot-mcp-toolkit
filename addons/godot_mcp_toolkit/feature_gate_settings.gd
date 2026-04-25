@tool
extends RefCounted
## Feature-gate ProjectSettings registration and change-detection polling.
## Owns the profile sync logic and per-feature gate change detection.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPFeatureGate = _Hub.MCPFeatureGate
const MCPFeatureRegistry = _Hub.MCPFeatureRegistry
const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")

const _LIMITS_NOTE_KEY := "mcp_toolkit/limits/env_override_note"
const _LIMITS_NOTE_TEXT := (
	"These values can be overridden by GODOT_MCP_SCRIPT_READ_LIMIT and "
	+ "GODOT_MCP_WS_BUFFER_LIMIT env vars in .mcp.json. "
	+ "When set, the env var values take priority on connect.")

const _PROFILE_WARNING_KEY := "mcp_toolkit/feature_gates/profile_warning"
const _PU_WARNING_TEXT := (
	"POWER USER MODE ACTIVE — All feature gates enabled. "
	+ "The AI agent has full control: code execution, OS commands, "
	+ "project settings writes, and file access outside res://. "
	+ "Individual gates cannot be changed — switch to Standard to toggle.")
const _MINIMAL_WARNING_TEXT := (
	"MINIMAL PROFILE ACTIVE — All feature gates disabled. "
	+ "Only core read-only tools are available. "
	+ "Individual gates cannot be changed — switch to Standard to toggle.")

# Profile enum values matching the PROPERTY_HINT_ENUM order.
const PROFILE_MINIMAL := 0
const PROFILE_STANDARD := 1
const PROFILE_POWER_USER := 2

var _last_profile: int = PROFILE_STANDARD
var _last_feature_states: Dictionary = {}  # { ps_key: bool }
var _startup_reconciliation_done: bool = false


func register_all() -> void:
	_register_feature_gates()
	_register_limits()
	_register_audit()
	_last_profile = ProjectSettings.get_setting("mcp_toolkit/feature_gates/profile", PROFILE_STANDARD)
	snapshot_feature_states()


func poll(dock: Control) -> void:
	# One-time startup reconciliation on the first poll cycle.
	if not _startup_reconciliation_done:
		_startup_reconciliation_done = true
		_reconcile_standard_env_vars(dock)

	var profile: int = ProjectSettings.get_setting("mcp_toolkit/feature_gates/profile", PROFILE_STANDARD)
	if profile != _last_profile:
		var old_profile := _last_profile
		_last_profile = profile
		_sync_profile_change(profile, old_profile, dock)
	_poll_feature_states(dock)


## Allow callers (e.g. dock) to acknowledge a profile change they already
## applied, preventing the next poll from re-running _sync_profile_change.
func acknowledge_profile(profile: int) -> void:
	_last_profile = profile
	snapshot_feature_states()


func snapshot_feature_states() -> void:
	_last_feature_states.clear()
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		_last_feature_states[str(entry["ps_key"])] = ProjectSettings.get_setting(
			str(entry["ps_key"]), false)


# -- Registration helpers -----------------------------------------------------


func _register_feature_gates() -> void:
	# Profile dropdown — registered first so it displays at the top.
	if not ProjectSettings.has_setting("mcp_toolkit/feature_gates/profile"):
		ProjectSettings.set_setting("mcp_toolkit/feature_gates/profile", PROFILE_STANDARD)
	ProjectSettings.set_initial_value("mcp_toolkit/feature_gates/profile", PROFILE_STANDARD)
	ProjectSettings.set_as_basic("mcp_toolkit/feature_gates/profile", true)
	ProjectSettings.add_property_info({
		"name": "mcp_toolkit/feature_gates/profile",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "Minimal,Standard,Power User",
	})
	ProjectSettings.set_order("mcp_toolkit/feature_gates/profile", 0)

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
	_register_profile_warning()


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


func _register_profile_warning() -> void:
	if not ProjectSettings.has_setting(_PROFILE_WARNING_KEY):
		ProjectSettings.set_setting(_PROFILE_WARNING_KEY, "")
	ProjectSettings.set_initial_value(_PROFILE_WARNING_KEY, "")
	ProjectSettings.set_as_basic(_PROFILE_WARNING_KEY, true)
	ProjectSettings.set_order(_PROFILE_WARNING_KEY, 1000)
	ProjectSettings.add_property_info({
		"name": _PROFILE_WARNING_KEY, "type": TYPE_STRING,
		"hint": PROPERTY_HINT_MULTILINE_TEXT,
		"hint_string": "Read-only status display — value is managed by the plugin.",
	})
	_update_profile_warning()


func _update_profile_warning() -> void:
	var profile: int = ProjectSettings.get_setting("mcp_toolkit/feature_gates/profile", PROFILE_STANDARD)
	match profile:
		PROFILE_POWER_USER:
			ProjectSettings.set_setting(_PROFILE_WARNING_KEY, _PU_WARNING_TEXT)
		PROFILE_MINIMAL:
			ProjectSettings.set_setting(_PROFILE_WARNING_KEY, _MINIMAL_WARNING_TEXT)
		_:
			ProjectSettings.set_setting(_PROFILE_WARNING_KEY, "")


# -- Profile sync --------------------------------------------------------------


func _sync_profile_change(new_profile: int, old_profile: int, dock: Control) -> void:
	_update_profile_warning()

	# Guard: if the dock already applied this change, just refresh UI.
	# The dock creates the cache when leaving Standard and calls
	# acknowledge_profile() afterward, so this code path only runs when
	# the change was made from ProjectSettings UI.
	if new_profile == PROFILE_POWER_USER:
		# Power User from PS UI — needs confirmation dialog.
		_confirm_power_user_from_ps(old_profile, dock)
		return

	if new_profile == PROFILE_MINIMAL:
		# Minimal from PS UI — apply directly.
		if old_profile == PROFILE_STANDARD:
			MCPFeatureGate.snapshot_standard_gates()
		for feature in MCPFeatureRegistry.all_features():
			var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
			ProjectSettings.set_setting(str(entry["ps_key"]), false)
		if MCPJsonSync.has_mcp_json():
			for feature in MCPFeatureRegistry.all_features():
				var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
				MCPJsonSync.set_env_var(str(entry["env_var"]), false)
			MCPJsonSync.set_env_var_string("GODOT_MCP_PROFILE", "minimal")

	elif new_profile == PROFILE_STANDARD:
		# Standard from PS UI — restore cached gates.
		MCPFeatureGate.restore_standard_gates()
		if MCPJsonSync.has_mcp_json():
			for feature in MCPFeatureRegistry.all_features():
				var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
				var ps_on: bool = ProjectSettings.get_setting(str(entry["ps_key"]), false)
				MCPJsonSync.set_env_var(str(entry["env_var"]), ps_on)
			MCPJsonSync.set_env_var_string("GODOT_MCP_PROFILE", "standard")

	_update_profile_warning()
	ProjectSettings.save()
	snapshot_feature_states()
	if dock != null:
		dock._refresh_features()
		dock._notify_restart_required()


func _confirm_power_user_from_ps(old_profile: int, dock: Control) -> void:
	var features := MCPFeatureRegistry.all_features()
	var lines := PackedStringArray()
	for feature in features:
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		lines.append("  - %s: %s" % [feature, entry["risk"]])

	var dialog := ConfirmationDialog.new()
	dialog.title = "Switch to Power User?"
	dialog.dialog_text = (
		"This enables ALL gated features:\n\n"
		+ "\n".join(lines)
		+ "\n\nThis gives the AI agent full control over your editor\n"
		+ "and project. Only enable if you trust the AI context.")
	dialog.ok_button_text = "I Understand — Switch"
	dialog.confirmed.connect(func():
		if old_profile == PROFILE_STANDARD:
			MCPFeatureGate.snapshot_standard_gates()
		for feature in MCPFeatureRegistry.all_features():
			var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
			ProjectSettings.set_setting(str(entry["ps_key"]), true)
		if MCPJsonSync.has_mcp_json():
			for feature in MCPFeatureRegistry.all_features():
				var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
				MCPJsonSync.set_env_var(str(entry["env_var"]), true)
			MCPJsonSync.set_env_var_string("GODOT_MCP_PROFILE", "power_user")
		_update_profile_warning()
		ProjectSettings.save()
		snapshot_feature_states()
		if dock != null:
			dock._refresh_features()
			dock._notify_restart_required()
		dialog.queue_free()
	)
	dialog.canceled.connect(func():
		# Revert profile to previous value.
		ProjectSettings.set_setting("mcp_toolkit/feature_gates/profile", old_profile)
		_last_profile = old_profile
		_update_profile_warning()
		ProjectSettings.save()
		if dock != null:
			dock._refresh_features()
		dialog.queue_free()
	)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


# -- Startup reconciliation ---------------------------------------------------


func _reconcile_standard_env_vars(dock: Control) -> void:
	var profile: int = ProjectSettings.get_setting("mcp_toolkit/feature_gates/profile", PROFILE_STANDARD)
	if profile != PROFILE_STANDARD:
		return
	if not MCPJsonSync.has_mcp_json():
		return
	var changed := false
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		var ps_on: bool = ProjectSettings.get_setting(str(entry["ps_key"]), false)
		var has_env := MCPJsonSync.has_env_var(str(entry["env_var"]))
		if ps_on and not has_env:
			MCPJsonSync.set_env_var(str(entry["env_var"]), true)
			changed = true
		elif not ps_on and has_env:
			MCPJsonSync.set_env_var(str(entry["env_var"]), false)
			changed = true
	if changed and dock != null:
		dock._notify_restart_required()


# -- Per-feature polling -------------------------------------------------------


func _poll_feature_states(dock: Control) -> void:
	# Enforce read-only text fields — revert any user edits immediately.
	var profile: int = ProjectSettings.get_setting("mcp_toolkit/feature_gates/profile", PROFILE_STANDARD)
	var expected_warning: String
	match profile:
		PROFILE_POWER_USER:
			expected_warning = _PU_WARNING_TEXT
		PROFILE_MINIMAL:
			expected_warning = _MINIMAL_WARNING_TEXT
		_:
			expected_warning = ""
	if ProjectSettings.get_setting(_PROFILE_WARNING_KEY, "") != expected_warning:
		ProjectSettings.set_setting(_PROFILE_WARNING_KEY, expected_warning)
	if ProjectSettings.get_setting(_LIMITS_NOTE_KEY, "") != _LIMITS_NOTE_TEXT:
		ProjectSettings.set_setting(_LIMITS_NOTE_KEY, _LIMITS_NOTE_TEXT)

	# If Power User profile is active, revert any individual gate changes
	# made from the ProjectSettings UI and warn the user.
	if profile == PROFILE_POWER_USER:
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
				dock._warn_profile_locked(PROFILE_POWER_USER)
		return

	# If Minimal profile is active, revert any individual gate set to true.
	if profile == PROFILE_MINIMAL:
		var reverted := false
		for feature in MCPFeatureRegistry.all_features():
			var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
			var ps_key: String = entry["ps_key"]
			var current: bool = ProjectSettings.get_setting(ps_key, false)
			if current:
				ProjectSettings.set_setting(ps_key, false)
				_last_feature_states[ps_key] = false
				reverted = true
		if reverted:
			ProjectSettings.save()
			if dock != null:
				dock._warn_profile_locked(PROFILE_MINIMAL)
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
			MCPJsonSync.set_env_var(str(entry["env_var"]), current)
			changed = true
	if changed:
		if dock != null:
			dock._refresh_features()
			dock._notify_restart_required()
