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

const _LIMITS_NOTE_KEY := "mcp_toolkit/limits/env_override_note"
const _LIMITS_NOTE_TEXT := (
	"These values can be overridden by GODOT_MCP_SCRIPT_READ_LIMIT and "
	+ "GODOT_MCP_WS_BUFFER_LIMIT env vars in .mcp.json. "
	+ "When set, the env var values take priority on connect.")

const _STATUS_KEY := "mcp_toolkit/feature_gates/status"
const _PU_WARNING_TEXT := (
	"POWER USER MODE ACTIVE — All feature gates enabled. "
	+ "The AI agent has full control: arbitrary code execution, "
	+ "project settings writes, and file access outside res://. "
	+ "Individual gates cannot be changed — switch to Standard to toggle.")
const _MINIMAL_WARNING_TEXT := (
	"MINIMAL PROFILE ACTIVE — All feature gates disabled. "
	+ "Only core read-only tools are available. "
	+ "Individual gates cannot be changed — switch to Standard to toggle.")
const _MCP_JSON_MISSING_TEXT := (
	"No .mcp.json found — use Project > Tools > MCP Toolkit > "
	+ "Write .mcp.json to create one.")

# Profile enum values — canonical definition in MCPFeatureRegistry.
const PROFILE_MINIMAL := MCPFeatureRegistry.PROFILE_MINIMAL
const PROFILE_STANDARD := MCPFeatureRegistry.PROFILE_STANDARD
const PROFILE_POWER_USER := MCPFeatureRegistry.PROFILE_POWER_USER

var _last_profile: int = PROFILE_STANDARD
var _last_feature_states: Dictionary = {}  # { ps_key: bool } — snapshot for change detection
var _last_mcp_json_present: bool = false  # L1: track .mcp.json presence transitions
var _sidecar_was_present: bool = false  # P2: detect sidecar loss (manual deletion)
var _events: RefCounted = null  # GateEvents signal bus


func bind_events(events: RefCounted) -> void:
	_events = events
	_events.profile_acknowledged.connect(acknowledge_profile)


func register_all() -> void:
	_register_feature_gates()
	_register_limits()
	_register_audit()
	_last_profile = ProjectSettings.get_setting("mcp_toolkit/feature_gates/profile", PROFILE_STANDARD)
	_last_mcp_json_present = MCPJsonSync.has_mcp_json()
	# Bootstrap sidecar if missing. Discriminate P2 (sidecar lost, PS bools
	# are correct) from P3 (first-time migration from pre-sidecar plugin):
	# non-default PS bools prove a prior session → P2; all default → P3.
	# Since the sidecar now lives under user:// (always writable at startup),
	# bootstrap should never fail — no deferred retry needed.
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
	var profile: int = ProjectSettings.get_setting("mcp_toolkit/feature_gates/profile", PROFILE_STANDARD)
	if profile != _last_profile:
		var old_profile := _last_profile
		_last_profile = profile
		_sync_profile_change(profile, old_profile)
	_poll_feature_states()


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


## P3: Bootstrap sidecar from .mcp.json env vars (one-time migration).
func _bootstrap_sidecar_from_mcp_json() -> void:
	var mcp_env := MCPJsonSync.get_all_env_vars()
	var profile_str: String = str(mcp_env.get("GODOT_MCP_PROFILE", "standard"))
	if profile_str.is_empty():
		profile_str = "standard"
	var gates := {}
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		gates[str(entry["env_var"])] = mcp_env.get(str(entry["env_var"]), "") == "1"
	var err := MCPStateFile.write(profile_str, gates)
	if err == OK:
		_sidecar_was_present = true
		print("[MCPStateFile] bootstrapped sidecar from .mcp.json (profile=%s)" % profile_str)
	else:
		push_warning("[MCPStateFile] bootstrap from .mcp.json failed (err %d) — will retry on next poll" % err)


## Seed sidecar from current ProjectSettings bools when neither .mcp.json
## nor sidecar exists (fresh install, or after user:// instance dir + .mcp.json deletion).
func _bootstrap_sidecar_from_ps() -> void:
	var profile: int = ProjectSettings.get_setting("mcp_toolkit/feature_gates/profile", PROFILE_STANDARD)
	var profile_str: String
	match profile:
		PROFILE_MINIMAL: profile_str = "minimal"
		PROFILE_POWER_USER: profile_str = "power_user"
		_: profile_str = "standard"
	var err := MCPStateFile.write(profile_str, MCPStateFile.gates_from_ps())
	if err == OK:
		_sidecar_was_present = true
		print("[MCPStateFile] seeded sidecar from ProjectSettings (profile=%s)" % profile_str)
	else:
		push_warning("[MCPStateFile] bootstrap from ProjectSettings failed (err %d) — will retry on next poll" % err)


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


func _update_status_text() -> void:
	# .mcp.json missing takes priority — gates cannot function without it.
	if not MCPJsonSync.has_mcp_json():
		ProjectSettings.set_setting(_STATUS_KEY, _MCP_JSON_MISSING_TEXT)
		return
	var profile: int = ProjectSettings.get_setting("mcp_toolkit/feature_gates/profile", PROFILE_STANDARD)
	match profile:
		PROFILE_POWER_USER:
			ProjectSettings.set_setting(_STATUS_KEY, _PU_WARNING_TEXT)
		PROFILE_MINIMAL:
			ProjectSettings.set_setting(_STATUS_KEY, _MINIMAL_WARNING_TEXT)
		_:
			ProjectSettings.set_setting(_STATUS_KEY, "")


# -- Profile sync --------------------------------------------------------------


func _sync_profile_change(new_profile: int, old_profile: int) -> void:
	_update_status_text()

	# Guard: if the dock already applied this change, just refresh UI.
	if new_profile == PROFILE_POWER_USER:
		_confirm_power_user_from_ps(old_profile)
		return

	if new_profile == PROFILE_MINIMAL:
		if old_profile == PROFILE_STANDARD:
			MCPFeatureGate.snapshot_standard_gates()
		for feature in MCPFeatureRegistry.all_features():
			var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
			ProjectSettings.set_setting(str(entry["ps_key"]), false)
		MCPStateFile.write("minimal", MCPStateFile.build_gates_dict(false))

	elif new_profile == PROFILE_STANDARD:
		MCPFeatureGate.restore_standard_gates()
		# Sync PS from sidecar (restore writes gates there).
		var sidecar_gates := MCPStateFile.get_current_gates()
		for feature in MCPFeatureRegistry.all_features():
			var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
			var on: bool = sidecar_gates.get(str(entry["env_var"]), false) == true
			ProjectSettings.set_setting(str(entry["ps_key"]), on)

	_update_status_text()
	ProjectSettings.save()
	snapshot_feature_states()
	_emit_features_changed()
	_emit_status_changed()
	_emit_config_reloaded()


var _pu_confirm_dialog: ConfirmationDialog = null

func _confirm_power_user_from_ps(old_profile: int) -> void:
	if _pu_confirm_dialog != null and is_instance_valid(_pu_confirm_dialog):
		# D1: dialog already pending — revert PS profile and tracking to
		# prevent the enforcement loop from applying PU unconfirmed.
		ProjectSettings.set_setting("mcp_toolkit/feature_gates/profile", old_profile)
		_last_profile = old_profile
		return
	# Snapshot Standard gates IMMEDIATELY — before the poll loop can corrupt
	# them.  The PS profile is already POWER_USER (user changed it in the
	# Inspector), so the poll would enforce all-true on the next frame,
	# overwriting the real Standard values.
	if old_profile == PROFILE_STANDARD:
		MCPFeatureGate.snapshot_standard_gates()

	# Revert the PS profile to the old value while the dialog is pending.
	ProjectSettings.set_setting("mcp_toolkit/feature_gates/profile", old_profile)
	_last_profile = old_profile
	_update_status_text()

	var features := MCPFeatureRegistry.all_features()
	var lines := PackedStringArray()
	for feature in features:
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		lines.append("  - %s: %s" % [feature, entry["risk"]])

	_pu_confirm_dialog = ConfirmationDialog.new()
	_pu_confirm_dialog.exclusive = false
	_pu_confirm_dialog.title = "Switch to Power User?"
	_pu_confirm_dialog.dialog_text = (
		"This enables ALL gated features:\n\n"
		+ "\n".join(lines)
		+ "\n\nThis gives the AI agent full control over your editor\n"
		+ "and project. Only enable if you trust the AI context.")
	_pu_confirm_dialog.ok_button_text = "I Understand — Switch"
	_pu_confirm_dialog.confirmed.connect(func():
		ProjectSettings.set_setting("mcp_toolkit/feature_gates/profile", PROFILE_POWER_USER)
		for feat in MCPFeatureRegistry.all_features():
			var ent: Dictionary = MCPFeatureRegistry.get_entry(feat)
			ProjectSettings.set_setting(str(ent["ps_key"]), true)
		MCPStateFile.write("power_user", MCPStateFile.build_gates_dict(true))
		_last_profile = PROFILE_POWER_USER
		_update_status_text()
		ProjectSettings.save()
		snapshot_feature_states()
		_emit_features_changed()
		_emit_status_changed()
		_emit_config_reloaded()
		_pu_confirm_dialog.queue_free()
		_pu_confirm_dialog = null
	)
	_pu_confirm_dialog.canceled.connect(func():
		_emit_features_changed()
		_emit_status_changed()
		_pu_confirm_dialog.queue_free()
		_pu_confirm_dialog = null
	)
	EditorInterface.get_base_control().add_child(_pu_confirm_dialog)
	_pu_confirm_dialog.popup_centered()


# -- Bidirectional sync --------------------------------------------------------


func _poll_feature_states() -> void:
	# L1: Detect .mcp.json presence transitions (updates dock/PS hints).
	var mcp_present := MCPJsonSync.has_mcp_json()
	if mcp_present != _last_mcp_json_present:
		_last_mcp_json_present = mcp_present
		_emit_features_changed()
		_emit_status_changed()

	# Enforce read-only text fields — revert any user edits immediately.
	var profile: int = ProjectSettings.get_setting("mcp_toolkit/feature_gates/profile", PROFILE_STANDARD)
	var expected_status: String
	if not MCPJsonSync.has_mcp_json():
		expected_status = _MCP_JSON_MISSING_TEXT
	else:
		match profile:
			PROFILE_POWER_USER:
				expected_status = _PU_WARNING_TEXT
			PROFILE_MINIMAL:
				expected_status = _MINIMAL_WARNING_TEXT
			_:
				expected_status = ""
	if ProjectSettings.get_setting(_STATUS_KEY, "") != expected_status:
		ProjectSettings.set_setting(_STATUS_KEY, expected_status)
	if ProjectSettings.get_setting(_LIMITS_NOTE_KEY, "") != _LIMITS_NOTE_TEXT:
		ProjectSettings.set_setting(_LIMITS_NOTE_KEY, _LIMITS_NOTE_TEXT)

	# P2: Sidecar recovery — recreate from PS if missing (covers manual
	# deletion). Runs before profile enforcement so locked profiles can
	# also recover.  Use read() — file_exists() can lie on Windows.
	if MCPStateFile.read().is_empty():
		_bootstrap_sidecar_from_ps()
		if _sidecar_was_present:
			# Bootstrap just succeeded — notify dock and bridge.
			snapshot_feature_states()
			_emit_features_changed()
			_emit_config_reloaded()

	# Read sidecar once for all sync operations below.
	var sidecar_data := MCPStateFile.read()
	var sidecar_gates: Dictionary = sidecar_data.get("gates", {})
	var sidecar_profile_str: String = str(sidecar_data.get("profile", ""))
	var sidecar_valid := not sidecar_gates.is_empty()

	# Detect sidecar profile changes (manual file edit). Apply directly —
	# the user made a conscious decision by editing the file.
	if sidecar_valid and not sidecar_profile_str.is_empty():
		var sidecar_profile_int: int
		match sidecar_profile_str:
			"minimal": sidecar_profile_int = PROFILE_MINIMAL
			"power_user", "full": sidecar_profile_int = PROFILE_POWER_USER
			_: sidecar_profile_int = PROFILE_STANDARD
		if sidecar_profile_int != profile:
			if profile == PROFILE_STANDARD:
				MCPFeatureGate.snapshot_standard_gates()
			ProjectSettings.set_setting("mcp_toolkit/feature_gates/profile", sidecar_profile_int)
			_last_profile = sidecar_profile_int
			profile = sidecar_profile_int
			_update_status_text()
			ProjectSettings.save()
			snapshot_feature_states()
			_emit_features_changed()
			_emit_status_changed()
			_emit_config_reloaded()

	# Power User: force all PS bools true + enforce sidecar consistency.
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
			_emit_profile_lock_warning(PROFILE_POWER_USER)
		# Correct sidecar if a gate was manually set to false.
		if sidecar_valid:
			var sidecar_dirty := false
			for feature in MCPFeatureRegistry.all_features():
				var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
				if sidecar_gates.get(str(entry["env_var"]), false) != true:
					sidecar_dirty = true
					break
			if sidecar_dirty:
				MCPStateFile.write("power_user", MCPStateFile.build_gates_dict(true))
				_emit_config_reloaded()
		return

	# Minimal: force all PS bools false + enforce sidecar consistency.
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
			_emit_profile_lock_warning(PROFILE_MINIMAL)
		# Correct sidecar if a gate was manually set to true.
		if sidecar_valid:
			var sidecar_dirty := false
			for feature in MCPFeatureRegistry.all_features():
				var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
				if sidecar_gates.get(str(entry["env_var"]), false) != false:
					sidecar_dirty = true
					break
			if sidecar_dirty:
				MCPStateFile.write("minimal", MCPStateFile.build_gates_dict(false))
				_emit_config_reloaded()
		return

	# Standard: bidirectional sync between PS bools and sidecar.
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
			# Guard: skip when sidecar is empty/missing to avoid
			# overwriting correct PS bools with false defaults.
			var sidecar_on: bool = sidecar_gates.get(env_var, false) == true
			if sidecar_on != ps_current:
				ProjectSettings.set_setting(ps_key, sidecar_on)
				_last_feature_states[ps_key] = sidecar_on
				sidecar_changed = true

	if ps_changed:
		_emit_features_changed()
		_emit_config_reloaded()
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


func _emit_profile_lock_warning(profile: int) -> void:
	if _events != null:
		_events.profile_lock_warning.emit(profile)
