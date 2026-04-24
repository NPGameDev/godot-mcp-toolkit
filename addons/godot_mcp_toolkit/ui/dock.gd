@tool
extends VBoxContainer
## MCP bottom-panel dock — signal-driven status with polled runtime label.
##
## Created and bound by plugin.gd. Server status is signal-driven
## (no polling delay); a lightweight timer polls the runtime label
## during playtests so it updates without requiring server events.

const MCPFeatureRegistry := preload("res://addons/godot_mcp_toolkit/feature_registry.gd")
const MCPFeatureGate := preload("res://addons/godot_mcp_toolkit/feature_gate.gd")
const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")
const MCPRegistryClient := preload("res://addons/godot_mcp_toolkit/registry_client.gd")
const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")

# Toast severity constants (match EditorToaster.Severity).
const _TOAST_INFO := 0
const _TOAST_WARNING := 1
const _TOAST_ERROR := 2

var _server: Node = null
var _audit_path: String = ""

# Status widgets.
var _status_label: Label = null
var _peer_label: Label = null
var _activity_label: Label = null
var _runtime_label: Label = null

# Feature rows: { feature_name: { check: CheckBox, sync_icon: Label } }
var _feature_rows: Dictionary = {}
var _power_user_btn: Button = null

# Power User warnings.
var _power_user_warning: Label = null
var _feature_lock_warning: Label = null


# Settings widgets.
var _script_cap_spinbox: SpinBox = null
var _ws_buffer_spinbox: SpinBox = null

# Info/Help dialog (populated on demand).
var _info_dialog: AcceptDialog = null

# Audit log dialog (populated on demand).
var _audit_dialog: AcceptDialog = null

# Lightweight timer for runtime-status polling during playtests.
var _runtime_timer: Timer = null


func bind(server: Node, audit_path: String) -> void:
	_server = server
	_audit_path = audit_path
	_server.client_connected.connect(_on_client_connected)
	_server.client_disconnected.connect(_on_client_disconnected)
	_server.command_received.connect(_on_command_received)
	_refresh_status()
	_refresh_features()


func _ready() -> void:
	_build_ui()
	# bind() runs before _ready (node not yet in tree), so its refresh
	# calls exit early on null widgets. Re-run now that UI exists.
	_refresh_features()
	_refresh_status()
	# Lightweight timer so runtime label updates during playtests without
	# requiring server events (e.g. port discovery, playtest end).
	_runtime_timer = Timer.new()
	_runtime_timer.wait_time = 1.0
	_runtime_timer.timeout.connect(_refresh_runtime_status)
	add_child(_runtime_timer)
	_runtime_timer.start()


func _exit_tree() -> void:
	for dialog in [_audit_dialog, _info_dialog, _pu_lock_dialog, _restart_dialog]:
		if dialog != null and is_instance_valid(dialog):
			dialog.queue_free()
	_audit_dialog = null
	_info_dialog = null
	_pu_lock_dialog = null
	_restart_dialog = null


# ---------------------------------------------------------------------------
# UI construction (programmatic — all dynamic content)
# ---------------------------------------------------------------------------


func _make_section_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	var scale := EditorInterface.get_editor_scale()
	# Sample the editor Panel stylebox for a theme-adaptive base color.
	var base := Color(0.22, 0.22, 0.22)
	var theme := _Hub.get_editor_theme()
	if theme:
		var sb = theme.get_stylebox("panel", "Panel")
		if sb is StyleBoxFlat:
			base = sb.bg_color
	style.bg_color = base.darkened(0.12)
	style.border_color = base.lightened(0.15)
	style.set_border_width_all(1)
	style.set_corner_radius_all(int(3 * scale))
	style.content_margin_left = 8.0 * scale
	style.content_margin_right = 8.0 * scale
	style.content_margin_top = 6.0 * scale
	style.content_margin_bottom = 6.0 * scale
	return style


## Build a styled section card with a header and content VBox.
## Access the content VBox via  section.get_meta("content").
func _make_section(title: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _make_section_style())
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var outer := VBoxContainer.new()
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(outer)

	var header := Label.new()
	header.text = title
	header.add_theme_font_size_override("font_size", 13)
	outer.add_child(header)
	outer.add_child(HSeparator.new())

	var content := VBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(content)
	panel.set_meta("content", content)
	return panel


func _build_ui() -> void:
	var scale := EditorInterface.get_editor_scale()
	add_theme_constant_override("separation", int(4 * scale))

	# == Status section (compact, pinned at top) ==============================
	var status_section := _make_section("Server Status")
	status_section.size_flags_vertical = 0  # fixed height
	add_child(status_section)
	var sc: VBoxContainer = status_section.get_meta("content")

	var status_row := HBoxContainer.new()
	sc.add_child(status_row)

	_status_label = Label.new()
	_status_label.text = "... starting"
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_status_label)

	_peer_label = Label.new()
	_peer_label.text = "0 peers"
	status_row.add_child(_peer_label)

	_activity_label = Label.new()
	_activity_label.text = "Last activity: —"
	_activity_label.add_theme_font_size_override("font_size", 11)
	sc.add_child(_activity_label)

	_runtime_label = Label.new()
	_runtime_label.text = "Runtime: not running"
	_runtime_label.add_theme_font_size_override("font_size", 11)
	_runtime_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	sc.add_child(_runtime_label)

	_power_user_warning = Label.new()
	_power_user_warning.text = (
		"WARNING: Power User profile active — includes tools that can "
		+ "modify project settings, execute code, and write outside res://.")
	_power_user_warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_power_user_warning.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	_power_user_warning.add_theme_font_size_override("font_size", 11)
	_power_user_warning.visible = false
	sc.add_child(_power_user_warning)

	# == Main resizable area (Feature Gates / Audit / bottom) =================
	var main_split := VSplitContainer.new()
	main_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_split.split_offset = int(200 * scale)
	add_child(main_split)

	# -- Feature Gates section (top pane) -------------------------------------
	var feat_section := _make_section("Feature Gates")
	feat_section.custom_minimum_size.y = int(80 * scale)
	main_split.add_child(feat_section)
	var fc: VBoxContainer = feat_section.get_meta("content")

	_feature_lock_warning = Label.new()
	_feature_lock_warning.text = (
		"Power User Mode is active — disable it to toggle individual gates.")
	_feature_lock_warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_feature_lock_warning.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	_feature_lock_warning.add_theme_font_size_override("font_size", 11)
	_feature_lock_warning.visible = false
	fc.add_child(_feature_lock_warning)

	var feat_scroll := ScrollContainer.new()
	feat_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	feat_scroll.custom_minimum_size.y = int(30 * scale)
	fc.add_child(feat_scroll)

	var feat_vbox := VBoxContainer.new()
	feat_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	feat_scroll.add_child(feat_vbox)

	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		var row := HBoxContainer.new()
		feat_vbox.add_child(row)

		var check := CheckBox.new()
		check.text = feature
		check.tooltip_text = str(entry["risk"])
		check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		check.toggled.connect(_on_feature_toggled.bind(feature))
		row.add_child(check)

		var badge := Label.new()
		badge.text = "(dual)" if entry["dual_gate"] else "(single)"
		badge.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		badge.add_theme_font_size_override("font_size", 11)
		row.add_child(badge)

		var sync_icon := Label.new()
		sync_icon.text = "!"
		sync_icon.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
		sync_icon.visible = false
		sync_icon.tooltip_text = ""
		row.add_child(sync_icon)

		_feature_rows[feature] = {"check": check, "sync_icon": sync_icon}

	_power_user_btn = Button.new()
	_power_user_btn.text = "Enable All (Power User)"
	_power_user_btn.pressed.connect(_on_power_user_pressed)
	fc.add_child(_power_user_btn)

	# -- Lower split (Audit / bottom stack) -----------------------------------
	var lower_split := VSplitContainer.new()
	lower_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lower_split.split_offset = int(150 * scale)
	main_split.add_child(lower_split)

	# -- Audit Log section (top of lower split) -------------------------------
	var audit_section := _make_section("Audit Log")
	audit_section.size_flags_vertical = 0  # fixed height
	lower_split.add_child(audit_section)
	var ac: VBoxContainer = audit_section.get_meta("content")

	var audit_settings_row := HBoxContainer.new()
	ac.add_child(audit_settings_row)

	var audit_enabled_check := CheckBox.new()
	audit_enabled_check.text = "Enabled"
	audit_enabled_check.button_pressed = ProjectSettings.get_setting(
		"mcp_toolkit/audit/enabled", true)
	audit_enabled_check.toggled.connect(_on_audit_enabled_toggled)
	audit_settings_row.add_child(audit_enabled_check)

	var audit_size_label := Label.new()
	audit_size_label.text = "  Max KB:"
	audit_size_label.add_theme_font_size_override("font_size", 11)
	audit_settings_row.add_child(audit_size_label)

	var audit_size_spin := SpinBox.new()
	audit_size_spin.min_value = 0
	audit_size_spin.max_value = 10240
	audit_size_spin.step = 128
	audit_size_spin.value = ProjectSettings.get_setting(
		"mcp_toolkit/audit/max_size_kb", 1024)
	audit_size_spin.tooltip_text = "0 = unlimited"
	audit_size_spin.value_changed.connect(_on_audit_max_size_changed)
	audit_settings_row.add_child(audit_size_spin)

	var audit_btns := HBoxContainer.new()
	ac.add_child(audit_btns)

	var view_log_btn := Button.new()
	view_log_btn.text = "View Audit Log"
	view_log_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view_log_btn.pressed.connect(show_audit_dialog)
	audit_btns.add_child(view_log_btn)

	var clear_log_btn := Button.new()
	clear_log_btn.text = "Clear Audit Log"
	clear_log_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_log_btn.pressed.connect(_on_clear_audit_log)
	audit_btns.add_child(clear_log_btn)

	# -- Bottom stack (Security & Limits + Info button) -----------------------
	var bottom_section := _make_section("Security & Response Limits")
	bottom_section.size_flags_vertical = 0  # fixed height
	lower_split.add_child(bottom_section)
	var lc: VBoxContainer = bottom_section.get_meta("content")

	var regen_btn := Button.new()
	regen_btn.text = "Regenerate Token"
	regen_btn.pressed.connect(_on_regen_token)
	lc.add_child(regen_btn)

	var limits_row := HBoxContainer.new()
	lc.add_child(limits_row)
	var cap_label := Label.new()
	cap_label.text = "Script cap:"
	limits_row.add_child(cap_label)
	_script_cap_spinbox = SpinBox.new()
	_script_cap_spinbox.min_value = 64
	_script_cap_spinbox.max_value = 4096
	_script_cap_spinbox.step = 64
	_script_cap_spinbox.suffix = "KB"
	_script_cap_spinbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_script_cap_spinbox.value = ProjectSettings.get_setting(
		"mcp_toolkit/limits/script_read_cap_kb", 256)
	_script_cap_spinbox.value_changed.connect(_on_script_cap_changed)
	limits_row.add_child(_script_cap_spinbox)
	var ws_label := Label.new()
	ws_label.text = "WS buffer:"
	limits_row.add_child(ws_label)
	_ws_buffer_spinbox = SpinBox.new()
	_ws_buffer_spinbox.min_value = 256
	_ws_buffer_spinbox.max_value = 8192
	_ws_buffer_spinbox.step = 256
	_ws_buffer_spinbox.suffix = "KB"
	_ws_buffer_spinbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ws_buffer_spinbox.value = ProjectSettings.get_setting(
		"mcp_toolkit/limits/ws_buffer_kb", 1024)
	_ws_buffer_spinbox.value_changed.connect(_on_ws_buffer_changed)
	limits_row.add_child(_ws_buffer_spinbox)

	var limits_note := Label.new()
	limits_note.text = "These may be overridden by env vars in .mcp.json on connect."
	limits_note.add_theme_font_size_override("font_size", 11)
	limits_note.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	limits_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lc.add_child(limits_note)

	if MCPJsonSync.has_mcp_json():
		var edit_mcp_btn := Button.new()
		edit_mcp_btn.text = "Edit .mcp.json"
		edit_mcp_btn.pressed.connect(func():
			OS.shell_open(MCPJsonSync.get_mcp_json_path()))
		lc.add_child(edit_mcp_btn)

	var info_btn := Button.new()
	info_btn.text = "Info / Help"
	info_btn.pressed.connect(_show_info_dialog)
	lc.add_child(info_btn)



# ---------------------------------------------------------------------------
# Signal handlers — server events (no polling)
# ---------------------------------------------------------------------------

func _on_client_connected(peer_count: int) -> void:
	_peer_label.text = "%d peer%s" % [peer_count, "" if peer_count == 1 else "s"]
	_activity_label.text = "Last activity: client connected"
	_toast("MCP client connected (%d peer%s)" % [
		peer_count, "" if peer_count == 1 else "s"])


func _on_client_disconnected(peer_count: int) -> void:
	_peer_label.text = "%d peer%s" % [peer_count, "" if peer_count == 1 else "s"]
	_activity_label.text = "Last activity: client disconnected"
	if peer_count == 0:
		_toast("MCP client lost connection", _TOAST_WARNING)


func _on_command_received(method: String) -> void:
	if _activity_label != null:
		_activity_label.text = "Last activity: %s" % method


# ---------------------------------------------------------------------------
# Status refresh
# ---------------------------------------------------------------------------

func _refresh_status() -> void:
	if _server == null or _status_label == null:
		return
	var profile := _read_mcp_profile()
	var display := _display_profile_name(profile)
	var port: int = _server.get_bound_port()
	var port_str := str(port) if port > 0 else "6505"
	if _server.is_listening():
		_status_label.text = "Listening on 127.0.0.1:%s · %s" % [port_str, display]
	else:
		_status_label.text = "Not listening · %s" % display
	var count: int = _server.get_authed_peer_count()
	_peer_label.text = "%d peer%s" % [count, "" if count == 1 else "s"]
	if _power_user_warning != null:
		_power_user_warning.visible = (profile == "full")
	_refresh_runtime_status()


func _refresh_runtime_status() -> void:
	if _runtime_label == null:
		return
	if EditorInterface.is_playing_scene():
		var rt_port := MCPRegistryClient.get_runtime_port()
		if rt_port > 0:
			_runtime_label.text = "Runtime: listening on 127.0.0.1:%d" % rt_port
			_runtime_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
		else:
			_runtime_label.text = "Runtime: game running, waiting for port..."
			_runtime_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	else:
		_runtime_label.text = "Runtime: not running (start playtest with F5)"
		_runtime_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))


## Read GODOT_MCP_PROFILE from .mcp.json env block (server-side setting).
func _read_mcp_profile() -> String:
	if not MCPJsonSync.has_mcp_json():
		return "standard"
	var env := MCPJsonSync.get_all_env_vars()
	var p: String = str(env.get("GODOT_MCP_PROFILE", "standard")).to_lower()
	if p in ["minimal", "standard", "full", "custom"]:
		return p
	return "standard"


# ---------------------------------------------------------------------------
# Feature toggle + .mcp.json sync
# ---------------------------------------------------------------------------

func _refresh_features() -> void:
	if _power_user_btn == null:
		return
	var allow_all: bool = ProjectSettings.get_setting("mcp_toolkit/feature_gates/power_user_mode", false)
	_power_user_btn.text = "Disable Power User Mode" if allow_all else "Enable All (Power User)"
	if _feature_lock_warning != null:
		_feature_lock_warning.visible = allow_all

	for feature in _feature_rows:
		var row: Dictionary = _feature_rows[feature]
		var check: CheckBox = row["check"]
		var sync_icon: Label = row["sync_icon"]
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)

		check.set_pressed_no_signal(true if allow_all else ProjectSettings.get_setting(str(entry["ps_key"]), false))
		check.disabled = allow_all
		if allow_all:
			check.tooltip_text = "Disable Power User Mode to toggle individual gates"
		else:
			check.tooltip_text = str(entry["risk"])

		var ps_ok: bool = allow_all or ProjectSettings.get_setting(str(entry["ps_key"]), false)
		var env_ok: bool = OS.get_environment(str(entry["env_var"])) == "1"
		var has_env_in_json := MCPJsonSync.has_env_var(str(entry["env_var"])) \
			if MCPJsonSync.has_mcp_json() else false

		sync_icon.visible = false
		if entry["dual_gate"]:
			if ps_ok and not env_ok and not has_env_in_json:
				sync_icon.visible = true
				sync_icon.tooltip_text = (
					"ProjectSettings enabled but %s not found in .mcp.json"
					+ " — feature won't activate until the env var is also set"
				) % entry["env_var"]
			elif (has_env_in_json or env_ok) and not ps_ok:
				sync_icon.visible = true
				sync_icon.tooltip_text = (
					"Env var set but ProjectSettings disabled"
					+ " — enable in Project Settings -> mcp_toolkit/feature_gates/"
				)


func _on_feature_toggled(enabled: bool, feature: String) -> void:
	# Block individual toggles while Power User Mode is active.
	var allow_all: bool = ProjectSettings.get_setting(
		"mcp_toolkit/feature_gates/power_user_mode", false)
	if allow_all:
		var row: Dictionary = _feature_rows[feature]
		row["check"].set_pressed_no_signal(true)
		_warn_power_user_locked()
		return
	var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
	if entry == null:
		return

	ProjectSettings.set_setting(str(entry["ps_key"]), enabled)
	ProjectSettings.save()

	# Auto-sync env var in .mcp.json for dual-gate features.
	var env_changed := false
	if entry["dual_gate"]:
		if MCPJsonSync.has_mcp_json():
			var env_var: String = entry["env_var"]
			var has_env := MCPJsonSync.has_env_var(env_var)
			if enabled and not has_env:
				MCPJsonSync.set_env_var(env_var, true)
				env_changed = true
			elif not enabled and has_env:
				MCPJsonSync.set_env_var(env_var, false)
				env_changed = true
		elif not MCPJsonSync.has_mcp_json() and enabled:
			_toast(
				"No .mcp.json found — use MCP Toolkit: Write .mcp.json first"
				, _TOAST_WARNING)

	_refresh_features()

	if env_changed:
		_notify_restart_required()


## Warn the user that individual gates are locked while Power User Mode is on.
var _pu_lock_dialog: AcceptDialog = null

func _warn_power_user_locked() -> void:
	if _pu_lock_dialog != null and is_instance_valid(_pu_lock_dialog):
		return
	_pu_lock_dialog = AcceptDialog.new()
	_pu_lock_dialog.title = "Power User Mode Active"
	_pu_lock_dialog.dialog_text = (
		"Individual feature gates cannot be changed while\n"
		+ "Power User Mode is enabled.\n\n"
		+ "Disable Power User Mode first to toggle gates individually.")
	_pu_lock_dialog.ok_button_text = "OK"
	_pu_lock_dialog.exclusive = false
	_pu_lock_dialog.confirmed.connect(func():
		_pu_lock_dialog.queue_free()
		_pu_lock_dialog = null
	)
	_pu_lock_dialog.canceled.connect(func():
		_pu_lock_dialog.queue_free()
		_pu_lock_dialog = null
	)
	EditorInterface.get_base_control().add_child(_pu_lock_dialog)
	_pu_lock_dialog.popup_centered()


## Show a dialog telling the user to restart their MCP client.
## Guards against multiple concurrent dialogs.
var _restart_dialog: AcceptDialog = null

func _notify_restart_required() -> void:
	if _restart_dialog != null and is_instance_valid(_restart_dialog):
		return
	_restart_dialog = AcceptDialog.new()
	_restart_dialog.title = "Restart Required"
	_restart_dialog.dialog_text = (
		"Settings and .mcp.json have been updated.\n\n"
		+ "You must restart your MCP client (e.g. Claude Code)\n"
		+ "for the changes to take effect.")
	_restart_dialog.ok_button_text = "OK"
	_restart_dialog.exclusive = false
	_restart_dialog.add_button("Restart Editor", true, "restart")
	_restart_dialog.confirmed.connect(func():
		_restart_dialog.queue_free()
		_restart_dialog = null
	)
	_restart_dialog.canceled.connect(func():
		_restart_dialog.queue_free()
		_restart_dialog = null
	)
	_restart_dialog.custom_action.connect(func(action: StringName):
		if action == &"restart":
			EditorInterface.restart_editor(true)
	)
	EditorInterface.get_base_control().add_child(_restart_dialog)
	_restart_dialog.popup_centered()


# ---------------------------------------------------------------------------
# Power User Mode
# ---------------------------------------------------------------------------

func _on_power_user_pressed() -> void:
	var allow_all: bool = ProjectSettings.get_setting("mcp_toolkit/feature_gates/power_user_mode", false)
	if allow_all:
		_confirm_disable_power_user()
	else:
		_confirm_enable_power_user()


## Public entry point — also called from plugin.gd menu item / onboarding.
func toggle_power_user_mode() -> void:
	_on_power_user_pressed()


func _confirm_enable_power_user() -> void:
	var features := MCPFeatureRegistry.all_features()
	var lines := PackedStringArray()
	for feature in features:
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		lines.append("  - %s: %s" % [feature, entry["risk"]])

	var dialog := ConfirmationDialog.new()
	dialog.title = "Enable Power User Mode?"
	dialog.dialog_text = (
		"This enables ALL gated features:\n\n"
		+ "\n".join(lines)
		+ "\n\nThis gives the AI agent full control over your editor\n"
		+ "and project. Only enable if you trust the AI context.")
	dialog.ok_button_text = "I Understand — Enable All"
	dialog.confirmed.connect(func():
		_apply_power_user_mode(true)
		dialog.queue_free()
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


func _confirm_disable_power_user() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Disable Power User Mode?"
	dialog.dialog_text = "All features will revert to their individual settings."
	dialog.confirmed.connect(func():
		_apply_power_user_mode(false)
		dialog.queue_free()
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


func _apply_power_user_mode(enable: bool) -> void:
	if enable:
		# Snapshot current per-feature PS state (persisted via ProjectSettings).
		MCPFeatureGate.snapshot_pre_power_user()

	ProjectSettings.set_setting("mcp_toolkit/feature_gates/power_user_mode", enable)

	if enable:
		for feature in MCPFeatureRegistry.all_features():
			var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
			ProjectSettings.set_setting(str(entry["ps_key"]), true)
		if MCPJsonSync.has_mcp_json():
			for feature in MCPFeatureRegistry.all_features():
				var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
				MCPJsonSync.set_env_var(str(entry["env_var"]), true)
		else:
			_offer_create_mcp_json_for_power_user()
	else:
		# Restore previous per-feature PS state from persistent cache.
		MCPFeatureGate.restore_pre_power_user()
		if MCPJsonSync.has_mcp_json():
			# Env vars not cached — clear all; user re-enables individually.
			for feature in MCPFeatureRegistry.all_features():
				var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
				var ps_on: bool = ProjectSettings.get_setting(str(entry["ps_key"]), false)
				MCPJsonSync.set_env_var(str(entry["env_var"]), ps_on)

	ProjectSettings.save()
	_refresh_features()
	_notify_restart_required()


func _offer_create_mcp_json_for_power_user() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "No .mcp.json found"
	dialog.dialog_text = "No .mcp.json found at project root.\nCreate it now?"
	dialog.confirmed.connect(func():
		write_mcp_json()
		for feature in MCPFeatureRegistry.all_features():
			var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
			MCPJsonSync.set_env_var(str(entry["env_var"]), true)
		dialog.queue_free()
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


# ---------------------------------------------------------------------------
# Audit log popup
# ---------------------------------------------------------------------------

func show_audit_dialog() -> void:
	# Read the log file.
	var path := _audit_path
	if path.is_empty():
		path = "user://addons/godot_mcp_toolkit/mcp_audit.log"
	var log_text := ""
	if FileAccess.file_exists(path):
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			var full_text := file.get_as_text()
			file.close()
			var lines := full_text.split("\n")
			if lines.size() > 100:
				var tail := lines.slice(lines.size() - 100)
				log_text = "\n".join(tail)
				log_text += "\n\n... Showing last 100 lines. Open the file to view the full log."
			else:
				log_text = full_text
	if log_text.strip_edges().is_empty():
		log_text = "(audit log is empty)"

	# Reuse or create dialog.
	if _audit_dialog != null and is_instance_valid(_audit_dialog):
		_audit_dialog.queue_free()
		_audit_dialog = null

	_audit_dialog = AcceptDialog.new()
	_audit_dialog.title = "MCP Toolkit — Audit Log"
	_audit_dialog.ok_button_text = "Close"
	_audit_dialog.exclusive = false
	_audit_dialog.min_size = Vector2i(620, 480)
	_audit_dialog.confirmed.connect(func():
		_audit_dialog.queue_free()
		_audit_dialog = null
	)
	_audit_dialog.canceled.connect(func():
		_audit_dialog.queue_free()
		_audit_dialog = null
	)

	_audit_dialog.add_button("Open File", true, "open_file")
	_audit_dialog.custom_action.connect(func(action: StringName):
		if action == "open_file":
			var global_path := ProjectSettings.globalize_path(path)
			OS.shell_open(global_path)
	)

	var vbox := VBoxContainer.new()
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_audit_dialog.add_child(vbox)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(600, 400)
	vbox.add_child(scroll)

	var text_label := RichTextLabel.new()
	text_label.bbcode_enabled = false
	text_label.fit_content = true
	text_label.scroll_active = false  # scroll handled by parent ScrollContainer
	text_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_label.selection_enabled = true
	text_label.text = log_text
	text_label.add_theme_font_size_override("normal_font_size", 11)
	scroll.add_child(text_label)

	# Scroll to bottom after layout pass.
	EditorInterface.get_base_control().add_child(_audit_dialog)
	_audit_dialog.popup_centered()
	await get_tree().process_frame
	scroll.scroll_vertical = scroll.get_v_scroll_bar().max_value


func _on_clear_audit_log() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Clear Audit Log?"
	dialog.dialog_text = "This will permanently delete all audit log entries."
	dialog.ok_button_text = "Clear"
	dialog.confirmed.connect(func():
		var path := _audit_path
		if path.is_empty():
			path = "user://addons/godot_mcp_toolkit/mcp_audit.log"
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string("")
			file.close()
		_toast("Audit log cleared")
		dialog.queue_free()
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


# ---------------------------------------------------------------------------
# Token regeneration
# ---------------------------------------------------------------------------

func _on_regen_token() -> void:
	if _server != null and _server.has_method("regenerate_token"):
		_server.regenerate_token()
		_toast("MCP token rotated")


# ---------------------------------------------------------------------------
# Write .mcp.json (public — also called from plugin.gd menu item)
# ---------------------------------------------------------------------------

func write_mcp_json(force_overwrite: bool = false) -> void:
	var template_path := "res://addons/godot_mcp_toolkit/.mcp.json.template"
	if not FileAccess.file_exists(template_path):
		_toast("Template not found: " + template_path, _TOAST_ERROR)
		return
	var content := FileAccess.get_file_as_string(template_path)
	var dest := MCPJsonSync.get_mcp_json_path()

	if FileAccess.file_exists(dest) and not force_overwrite:
		var dialog := ConfirmationDialog.new()
		dialog.title = ".mcp.json already exists"
		dialog.dialog_text = (
			"Overwrite existing .mcp.json at:\n" + dest
			+ "\n\nThis will replace any custom env vars you have set.")
		dialog.ok_button_text = "Overwrite"
		dialog.confirmed.connect(func():
			_do_write_mcp_json(dest, content)
			dialog.queue_free()
		)
		dialog.canceled.connect(func(): dialog.queue_free())
		EditorInterface.get_base_control().add_child(dialog)
		dialog.popup_centered()
		return

	_do_write_mcp_json(dest, content)


func _do_write_mcp_json(dest: String, content: String) -> void:
	var file := FileAccess.open(dest, FileAccess.WRITE)
	if file == null:
		_toast("Failed to write .mcp.json (err %d)" % FileAccess.get_open_error(),
			_TOAST_ERROR)
		return
	file.store_string(content)
	file.close()
	_toast("MCP: .mcp.json updated — restart your MCP client", _TOAST_INFO,
		"Wrote to " + dest)


# ---------------------------------------------------------------------------
# Display name helper
# ---------------------------------------------------------------------------

func _display_profile_name(profile: String) -> String:
	match profile:
		"full":
			return "Power User"
		_:
			return profile.capitalize()


# ---------------------------------------------------------------------------
# Settings handlers
# ---------------------------------------------------------------------------

func _on_script_cap_changed(value: float) -> void:
	var clamped := maxi(64, int(value))
	ProjectSettings.set_setting("mcp_toolkit/limits/script_read_cap_kb", clamped)
	ProjectSettings.save()


func _on_ws_buffer_changed(value: float) -> void:
	var clamped := maxi(256, int(value))
	ProjectSettings.set_setting("mcp_toolkit/limits/ws_buffer_kb", clamped)
	ProjectSettings.save()


func _on_audit_enabled_toggled(enabled: bool) -> void:
	ProjectSettings.set_setting("mcp_toolkit/audit/enabled", enabled)
	ProjectSettings.save()


func _on_audit_max_size_changed(value: float) -> void:
	ProjectSettings.set_setting("mcp_toolkit/audit/max_size_kb", int(value))
	ProjectSettings.save()


# ---------------------------------------------------------------------------
# Info / Help popup
# ---------------------------------------------------------------------------

func _show_info_dialog() -> void:
	if _info_dialog != null and is_instance_valid(_info_dialog):
		_info_dialog.popup_centered()
		return

	_info_dialog = AcceptDialog.new()
	_info_dialog.title = "MCP Toolkit — Info / Help"
	_info_dialog.ok_button_text = "Close"
	_info_dialog.exclusive = false
	_info_dialog.min_size = Vector2i(520, 460)
	_info_dialog.confirmed.connect(func():
		_info_dialog.queue_free()
		_info_dialog = null
	)
	_info_dialog.canceled.connect(func():
		_info_dialog.queue_free()
		_info_dialog = null
	)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(500, 400)
	_info_dialog.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	# -- Connection info --
	_add_info_header(vbox, "Connection")
	var profile := _read_mcp_profile()
	var display := _display_profile_name(profile)
	if _server != null and _server.is_listening():
		var port: int = _server.get_bound_port()
		var peers: int = _server.get_authed_peer_count()
		_add_info_row(vbox, "Address", "127.0.0.1:%d" % port)
		_add_info_row(vbox, "Peers", "%d connected" % peers)
	else:
		_add_info_row(vbox, "Address", "not listening")
	_add_info_row(vbox, "Profile", display)

	# -- Version --
	var plugin_ver := _get_plugin_version()
	var vi := Engine.get_version_info()
	var godot_ver := "%d.%d.%d" % [vi["major"], vi["minor"], vi["patch"]]
	_add_info_row(vbox, "Plugin", "v%s" % plugin_ver)
	_add_info_row(vbox, "Godot", godot_ver)

	# -- Registered tools --
	_add_info_header(vbox, "Registered Tools")
	if _server != null and _server.has_method("get_command_methods"):
		var methods: Array = _server.get_command_methods()
		methods.sort()
		var groups: Dictionary = {}
		for method in methods:
			var parts := str(method).split(".", true, 1)
			var domain: String = parts[0] if parts.size() > 0 else "other"
			if not groups.has(domain):
				groups[domain] = []
			groups[domain].append(str(method))
		var domain_keys: Array = groups.keys()
		domain_keys.sort()
		_add_info_row(vbox, "Total", "%d tools" % methods.size())
		for domain in domain_keys:
			var tools: Array = groups[domain]
			var lbl := Label.new()
			lbl.text = "  %s (%d): %s" % [
				str(domain).capitalize(), tools.size(),
				", ".join(PackedStringArray(tools))]
			lbl.add_theme_font_size_override("font_size", 11)
			lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			vbox.add_child(lbl)
	else:
		_add_info_row(vbox, "Status", "server not ready")

	# -- Multi-instance support --
	_add_info_header(vbox, "Multi-Instance Multiplayer")
	var multi := Label.new()
	multi.text = (
		"A:  Two copies via git worktree — FULLY SUPPORTED\n"
		+ "     Each editor gets its own project root, registry entry, and port.\n\n"
		+ "B:  Built-in multi-instance run (F5 + multiple windows) — MOSTLY SUPPORTED\n"
		+ "     Runtime server available; editor MCP commands limited to the host.\n\n"
		+ "C:  Same directory, two editors — NOT SUPPORTED\n"
		+ "     Port collision and registry overwrite; use Pattern A instead.\n\n"
		+ "See addons/godot_mcp_toolkit/docs/multi-instance.md for full details.")
	multi.add_theme_font_size_override("font_size", 11)
	multi.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(multi)

	# -- Links --
	_add_info_header(vbox, "Links")
	var links_row := HBoxContainer.new()
	vbox.add_child(links_row)
	for pair in [
		["GitHub", "https://github.com/NPGameDev/godot-mcp-toolkit"],
		["Issues", "https://github.com/NPGameDev/godot-mcp-toolkit/issues"],
		["Server Repo", "https://github.com/NPGameDev/godot-mcp-server"],
		["Contributing", "https://github.com/NPGameDev/godot-mcp-toolkit/blob/main/CONTRIBUTING.md"],
	]:
		var btn := Button.new()
		btn.text = pair[0]
		var url: String = pair[1]
		btn.pressed.connect(func(): OS.shell_open(url))
		links_row.add_child(btn)

	EditorInterface.get_base_control().add_child(_info_dialog)
	_info_dialog.popup_centered()


func _add_info_header(parent: VBoxContainer, title: String) -> void:
	parent.add_child(HSeparator.new())
	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 13)
	parent.add_child(lbl)


func _add_info_row(parent: VBoxContainer, key: String, value: String) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var k := Label.new()
	k.text = key + ":"
	k.custom_minimum_size.x = 80
	k.add_theme_font_size_override("font_size", 12)
	row.add_child(k)
	var v := Label.new()
	v.text = value
	v.add_theme_font_size_override("font_size", 12)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(v)


func _get_plugin_version() -> String:
	var cfg := ConfigFile.new()
	var err := cfg.load("res://addons/godot_mcp_toolkit/plugin.cfg")
	if err != OK:
		return "unknown"
	return cfg.get_value("plugin", "version", "unknown")


# ---------------------------------------------------------------------------
# Toast helper
# ---------------------------------------------------------------------------

func _toast(msg: String, severity: int = _TOAST_INFO, tooltip_text: String = "") -> void:
	if not Engine.is_editor_hint():
		return
	print("[MCP] %s" % msg)
	# EditorToaster available in Godot 4.4+ (dynamic dispatch for compat).
	var toaster = _Hub.get_toaster()
	if toaster != null:
		toaster.push_toast(msg, severity, tooltip_text)
