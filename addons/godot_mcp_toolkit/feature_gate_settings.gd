@tool
extends RefCounted
## Feature-gate ProjectSettings registration and bidirectional sync.
##
## The sidecar (user://…/project_instance_<hash>/mcp_toolkit_state.json)
## is the runtime source of truth for gate state. PS bools are a mirror
## UI — the Inspector and dock both reflect the sidecar. Changes from
## either side are synced bidirectionally: PS change → write sidecar;
## sidecar change → update PS. .mcp.json is read-only — used only for
## one-time sidecar bootstrap (migration from pre-sidecar plugin versions).

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPFeatureGate = _Hub.MCPFeatureGate
const MCPFeatureRegistry = _Hub.MCPFeatureRegistry
const MCPJsonSync = _Hub.MCPJsonSync
const MCPStateFile = _Hub.MCPStateFile
const MCPNodejsCheck = _Hub.MCPNodejsCheck

const _LIMITS_NOTE_KEY := "mcp_toolkit/limits/env_override_note"
const _LIMITS_NOTE_TEXT := (
	"These values can be overridden by GODOT_MCP_SCRIPT_READ_LIMIT and "
	+ "GODOT_MCP_WS_BUFFER_LIMIT env vars in .mcp.json. "
	+ "When set, the env var values take priority on connect.")

const _STATUS_KEY := "mcp_toolkit/feature_gates/status"
const _READ_ONLY_WARNING_TEXT := (
	"READ-ONLY MODE ACTIVE (GODOT_MCP_READ_ONLY=1) — "
	+ "Only read-only tools are available. Mutating tools are hidden. "
	+ "Remove GODOT_MCP_READ_ONLY from .mcp.json env and reconnect "
	+ "the MCP client to restore full access.")
const _MCP_JSON_MISSING_TEXT := (
	"No .mcp.json found — use Project > Tools > MCP Toolkit > "
	+ "Write .mcp.json to create one.")
const _NODEJS_NOT_FOUND_TEXT := (
	"NODE.JS NOT FOUND — The MCP server bridge requires Node.js 20+. "
	+ "Download it from https://nodejs.org")
const _NODEJS_OLD_VERSION_TEXT := (
	"NODE.JS %s FOUND BUT 20+ REQUIRED — "
	+ "Update from https://nodejs.org")

var _last_feature_states: Dictionary = {}  # { ps_key: bool } — snapshot for change detection
var _last_mcp_json_present: bool = false  # L1: track .mcp.json presence transitions
var _sidecar_was_present: bool = false  # P2: detect sidecar loss (manual deletion)
var _nodejs_ok: bool = true  # Cached Node.js availability (set once in register_all).
var _nodejs_warning_text: String = ""  # Human-readable warning (empty when OK).
var _events: RefCounted = null  # GateEvents signal bus
var _bootstrap_retry_after_msec: int = 0  # P-055: cooldown to avoid per-frame spam on persistent failure


func bind_events(events: RefCounted) -> void:
	_events = events


func bind_user_path_monitor(monitor: RefCounted) -> void:
	monitor.project_name_changed.connect(_on_project_name_changed)


func _on_project_name_changed(_old_name: String, _new_name: String) -> void:
	rebootstrap_after_rename()


func register_all() -> void:
	# Cache Node.js availability once at plugin startup.
	var node_check := MCPNodejsCheck.check()
	_nodejs_ok = node_check["meets_minimum"]
	if not node_check["found"]:
		_nodejs_warning_text = _NODEJS_NOT_FOUND_TEXT
	elif not node_check["meets_minimum"]:
		_nodejs_warning_text = _NODEJS_OLD_VERSION_TEXT % str(node_check["version"])

	_register_feature_gates()
	_register_limits()
	_register_audit()
	_last_mcp_json_present = MCPJsonSync.has_mcp_json()
	# Bootstrap sidecar if missing. Discriminate P2 (sidecar lost, PS bools
	# are correct) from P3 (first-time migration from pre-sidecar plugin):
	# non-default PS bools prove a prior session → P2; all default → P3.
	# Use read() instead of file_exists() — the latter can return stale true
	# on Windows after a failed rename-based write from a prior session.
	_sidecar_was_present = not MCPStateFile.read().is_empty()
	if not _sidecar_was_present:
		var has_nondefault_ps := false
		for feature in MCPFeatureRegistry.all_features():
			var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
			if ProjectSettings.get_setting(str(entry["ps_key"]), false):
				has_nondefault_ps = true
				break
		if has_nondefault_ps:
			# P2: PS bools are authoritative — sidecar was deleted.
			_bootstrap_sidecar_from_ps()
		elif _last_mcp_json_present:
			# P3: first-time migration from pre-sidecar plugin.
			_bootstrap_sidecar_from_mcp_json()
		else:
			# Neither PS nor .mcp.json has state — seed from PS defaults.
			_bootstrap_sidecar_from_ps()
	snapshot_feature_states()


func poll() -> void:
	_poll_feature_states()


func snapshot_feature_states() -> void:
	_last_feature_states.clear()
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		_last_feature_states[str(entry["ps_key"])] = ProjectSettings.get_setting(
			str(entry["ps_key"]), false)


## P3: Bootstrap sidecar from .mcp.json env vars (one-time migration).
func _bootstrap_sidecar_from_mcp_json() -> void:
	var mcp_env := MCPJsonSync.get_all_env_vars()
	var gates := {}
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		gates[str(entry["env_var"])] = mcp_env.get(str(entry["env_var"]), "") == "1"
	var err := MCPStateFile.write_gates(gates)
	if err == OK:
		_sidecar_was_present = true
		print("[MCPStateFile] bootstrapped sidecar from .mcp.json")
	else:
		push_warning("[MCPStateFile] bootstrap from .mcp.json failed (err %d) — will retry on next poll" % err)


## Seed sidecar from current ProjectSettings bools when neither .mcp.json
## nor sidecar exists (fresh install, or after user:// instance dir + .mcp.json deletion).
## Called by plugin.gd when UserPathMonitor detects a config/name change.
## Re-creates the sidecar at the new user:// path and resets the retry cooldown.
func rebootstrap_after_rename() -> void:
	_bootstrap_sidecar_from_ps()
	if not MCPStateFile.read().is_empty():
		_sidecar_was_present = true
		_bootstrap_retry_after_msec = 0
		snapshot_feature_states()
		_emit_features_changed()
		_emit_config_reloaded()


func _bootstrap_sidecar_from_ps() -> void:
	var err := MCPStateFile.write_gates(MCPStateFile.gates_from_ps())
	if err == OK:
		_sidecar_was_present = true
		print("[MCPStateFile] seeded sidecar from ProjectSettings")
	else:
		push_warning("[MCPStateFile] bootstrap from ProjectSettings failed (err %d) — will retry on next poll" % err)


# -- Registration helpers -----------------------------------------------------


func _register_feature_gates() -> void:
	# Per-feature PS bools — mirror UI for .mcp.json env vars.
	var order_idx := 1
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		var ps_key: String = entry["ps_key"]
		_register_basic_bool(ps_key, false,
			"DANGER: %s. Mirrors .mcp.json env var. Default off." % entry["risk"])
		ProjectSettings.set_order(ps_key, order_idx)
		order_idx += 1

	# Profile warning — read-only status display at the end of Feature Gates.
	_register_status_field()


func _register_limits() -> void:
	_register_basic_int("mcp_toolkit/limits/script_read_cap_kb", 256,
		"Max script content returned by script.read, in KB. Minimum 64.")
	_register_basic_int("mcp_toolkit/limits/ws_buffer_kb", 1024,
		"WebSocket per-peer buffer size, in KB. Minimum 256.")
	_register_limits_note()


func _register_audit() -> void:
	_register_basic_bool("mcp_toolkit/audit/enabled", true,
		"Enable MCP audit log at user://addons/godot_mcp_toolkit/project_instance_<hash>/mcp_audit.log.")
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


func _register_status_field() -> void:
	if not ProjectSettings.has_setting(_STATUS_KEY):
		ProjectSettings.set_setting(_STATUS_KEY, "")
	ProjectSettings.set_initial_value(_STATUS_KEY, "")
	ProjectSettings.set_as_basic(_STATUS_KEY, true)
	ProjectSettings.set_order(_STATUS_KEY, 1000)
	ProjectSettings.add_property_info({
		"name": _STATUS_KEY, "type": TYPE_STRING,
		"hint": PROPERTY_HINT_MULTILINE_TEXT,
		"hint_string": "Read-only status display — value is managed by the plugin.",
	})
	_update_status_text()


func _compute_status_text() -> String:
	var parts := PackedStringArray()
	if _is_read_only():
		parts.append(_READ_ONLY_WARNING_TEXT)
	if not MCPJsonSync.has_mcp_json():
		parts.append(_MCP_JSON_MISSING_TEXT)
	if not _nodejs_ok:
		parts.append(_nodejs_warning_text)
	return "\n\n".join(parts)


## Check if read-only mode is active (GODOT_MCP_READ_ONLY=1 in .mcp.json).
func _is_read_only() -> bool:
	var env := MCPJsonSync.get_all_env_vars()
	return env.get("GODOT_MCP_READ_ONLY", "") == "1"


func _update_status_text() -> void:
	ProjectSettings.set_setting(_STATUS_KEY, _compute_status_text())


# -- Bidirectional sync --------------------------------------------------------


func _poll_feature_states() -> void:
	# L1: Detect .mcp.json presence transitions (updates dock/PS hints).
	var mcp_present := MCPJsonSync.has_mcp_json()
	if mcp_present != _last_mcp_json_present:
		_last_mcp_json_present = mcp_present
		_emit_features_changed()
		_emit_status_changed()

	# Enforce read-only text fields — revert any user edits immediately.
	var expected_status := _compute_status_text()
	if ProjectSettings.get_setting(_STATUS_KEY, "") != expected_status:
		ProjectSettings.set_setting(_STATUS_KEY, expected_status)
	if ProjectSettings.get_setting(_LIMITS_NOTE_KEY, "") != _LIMITS_NOTE_TEXT:
		ProjectSettings.set_setting(_LIMITS_NOTE_KEY, _LIMITS_NOTE_TEXT)

	# P2: Sidecar recovery — recreate from PS if missing (covers manual
	# deletion). Use read() — file_exists() can lie on Windows.
	# P-055: cooldown prevents per-frame spam when ensure_dirs fails.
	if MCPStateFile.read().is_empty():
		var _now_msec := Time.get_ticks_msec()
		if _now_msec >= _bootstrap_retry_after_msec:
			_bootstrap_sidecar_from_ps()
			if not MCPStateFile.read().is_empty():
				_sidecar_was_present = true
				_bootstrap_retry_after_msec = 0
				snapshot_feature_states()
				_emit_features_changed()
				_emit_config_reloaded()
			else:
				_bootstrap_retry_after_msec = _now_msec + 5000

	# Read sidecar once for all sync operations below.
	var sidecar_data := MCPStateFile.read()
	var sidecar_gates: Dictionary = sidecar_data.get("gates", {})
	var sidecar_valid := not sidecar_gates.is_empty()

	# Bidirectional sync between PS bools and sidecar.
	var ps_changed := false
	var sidecar_changed := false
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		var ps_key: String = entry["ps_key"]
		var env_var: String = entry["env_var"]
		var ps_current: bool = ProjectSettings.get_setting(ps_key, false)
		var ps_last: bool = _last_feature_states.get(ps_key, false)
		if ps_current != ps_last:
			# H7: Dangerous-gate check when enabling from PS Inspector.
			if ps_current and not ps_last:
				if MCPFeatureGate.needs_danger_warning(feature):
					ProjectSettings.set_setting(ps_key, false)
					_last_feature_states[ps_key] = false
					_show_ps_danger_confirmation(feature, ps_key, env_var)
					continue
			# PS changed by user (Inspector toggle) → write to sidecar.
			MCPStateFile.set_gate(env_var, ps_current)
			_last_feature_states[ps_key] = ps_current
			ps_changed = true
		elif sidecar_valid:
			# Sidecar changed (dock toggle or manual edit) → pull to PS.
			var sidecar_on: bool = sidecar_gates.get(env_var, false) == true
			if sidecar_on != ps_current:
				ProjectSettings.set_setting(ps_key, sidecar_on)
				_last_feature_states[ps_key] = sidecar_on
				sidecar_changed = true

	if ps_changed:
		_emit_features_changed()
		_emit_config_reloaded()
		if _is_read_only():
			_show_read_only_gate_warning()
	elif sidecar_changed:
		_emit_features_changed()
		_emit_config_reloaded()


# -- H7: Dangerous-gate confirmation from PS Inspector -----------------------

var _ps_danger_dialog: ConfirmationDialog = null

func _show_ps_danger_confirmation(feature: String, ps_key: String, env_var: String) -> void:
	# H7: Clean up any lingering dialog (queue_free may not have processed yet).
	if _ps_danger_dialog != null:
		if is_instance_valid(_ps_danger_dialog):
			_ps_danger_dialog.hide()
			_ps_danger_dialog.queue_free()
		_ps_danger_dialog = null
	var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
	var warn_text: String = entry.get("warn_text", str(entry["risk"]))
	_ps_danger_dialog = ConfirmationDialog.new()
	_ps_danger_dialog.exclusive = false
	_ps_danger_dialog.title = "Enable %s?" % feature
	_ps_danger_dialog.dialog_text = (
		"WARNING: This is a potentially dangerous capability.\n\n"
		+ "%s\n\n" % warn_text
		+ "Risk level: %s\n\n" % entry["risk"]
		+ "Only enable if you trust the current AI context.")
	_ps_danger_dialog.ok_button_text = "I Understand — Enable"
	_ps_danger_dialog.confirmed.connect(func():
		MCPFeatureGate.mark_warned(feature)
		ProjectSettings.set_setting(ps_key, true)
		MCPStateFile.set_gate(env_var, true)
		_last_feature_states[ps_key] = true
		ProjectSettings.save()
		snapshot_feature_states()
		_emit_features_changed()
		_emit_config_reloaded()
		var d := _ps_danger_dialog
		_ps_danger_dialog = null
		if d != null:
			d.hide()
			d.queue_free()
	)
	_ps_danger_dialog.canceled.connect(func():
		_emit_features_changed()
		var d := _ps_danger_dialog
		_ps_danger_dialog = null
		if d != null:
			d.hide()
			d.queue_free()
	)
	EditorInterface.get_base_control().add_child(_ps_danger_dialog)
	_ps_danger_dialog.popup_centered()


# -- Read-only gate warning ----------------------------------------------------

var _ro_warning_dialog: AcceptDialog = null

func _show_read_only_gate_warning() -> void:
	if _ro_warning_dialog != null and is_instance_valid(_ro_warning_dialog):
		return
	_ro_warning_dialog = AcceptDialog.new()
	_ro_warning_dialog.exclusive = false
	_ro_warning_dialog.title = "Read-Only Mode Active"
	_ro_warning_dialog.dialog_text = (
		"Your gate change has been saved, but read-only mode is active "
		+ "(GODOT_MCP_READ_ONLY=1 in .mcp.json).\n\n"
		+ "The MCP server will continue to hide mutating tools until you:\n"
		+ "  1. Remove GODOT_MCP_READ_ONLY from .mcp.json\n"
		+ "  2. Restart the editor\n"
		+ "  3. Reconnect the MCP client")
	_ro_warning_dialog.ok_button_text = "OK"
	_ro_warning_dialog.confirmed.connect(func():
		_ro_warning_dialog.queue_free()
		_ro_warning_dialog = null
	)
	_ro_warning_dialog.canceled.connect(func():
		_ro_warning_dialog.queue_free()
		_ro_warning_dialog = null
	)
	EditorInterface.get_base_control().add_child(_ro_warning_dialog)
	_ro_warning_dialog.popup_centered()


# -- Signal bus helpers --------------------------------------------------------


func _emit_features_changed() -> void:
	if _events != null:
		_events.features_changed.emit()


func _emit_status_changed() -> void:
	if _events != null:
		_events.status_changed.emit()


func _emit_config_reloaded() -> void:
	if _events != null:
		_events.config_reloaded.emit()
