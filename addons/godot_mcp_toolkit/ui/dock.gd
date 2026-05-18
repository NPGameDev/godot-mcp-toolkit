@tool
extends VBoxContainer
## MCP bottom-panel dock — signal-driven status with polled runtime label.
##
## Created and bound by plugin.gd. Server status is signal-driven
## (no polling delay); a lightweight timer polls the runtime label
## during playtests so it updates without requiring server events.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPFeatureRegistry = _Hub.MCPFeatureRegistry
const MCPFeatureGate = _Hub.MCPFeatureGate
const MCPJsonSync = _Hub.MCPJsonSync
const MCPStateFile = _Hub.MCPStateFile
const MCPRegistryClient = _Hub.MCPRegistryClient
const MCPNodejsCheck = _Hub.MCPNodejsCheck

# Toast severity constants (match EditorToaster.Severity).
const _TOAST_INFO := 0
const _TOAST_WARNING := 1
const _TOAST_ERROR := 2

var _server: Node = null
var _audit_path: String = ""
var _events: RefCounted = null  # GateEvents signal bus
var _notifier: RefCounted = null  # GateNotifier

# Status widgets.
var _status_label: Label = null
var _peer_label: Label = null
var _activity_label: Label = null
var _runtime_label: Label = null
var _read_only_badge: Label = null

# Feature rows: { feature_name: { check: CheckBox } }
var _feature_rows: Dictionary = {}
var _mcp_json_hint: Label = null
# Node.js warnings (shared detection via MCPNodejsCheck, two display locations).
var _nodejs_status_warning: Label = null
var _nodejs_gate_warning: Label = null
# Gates collapsible section header + scroll — for read-only visibility toggle.
var _gates_header: PanelContainer = null
var _gates_scroll: ScrollContainer = null

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


func bind_events(events: RefCounted) -> void:
	_events = events
	_events.features_changed.connect(_refresh_features)
	_events.status_changed.connect(_refresh_status)


func bind_notifier(notifier: RefCounted) -> void:
	_notifier = notifier


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
	for dialog in [_audit_dialog, _info_dialog, _danger_dialog]:
		if dialog != null and is_instance_valid(dialog):
			dialog.queue_free()
	_audit_dialog = null
	_info_dialog = null
	_danger_dialog = null


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


## Build a collapsible section with a styled header bar and per-section
## ScrollContainer. The header is added to `parent` so it never scrolls away;
## only the section content scrolls. Returns the content VBoxContainer.
func _make_collapsible_section(parent: VBoxContainer, title: String, expanded: bool, min_height: float = 75.0) -> VBoxContainer:
	var header := PanelContainer.new()
	header.add_theme_stylebox_override("panel", _make_section_style())
	parent.add_child(header)

	var toggle := Button.new()
	toggle.flat = true
	toggle.toggle_mode = true
	toggle.button_pressed = expanded
	toggle.text = "%s %s" % ["\u25bc" if expanded else "\u25b6", title]
	toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.add_child(toggle)

	var content_scroll := ScrollContainer.new()
	content_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_scroll.custom_minimum_size.y = int(min_height * EditorInterface.get_editor_scale())
	content_scroll.visible = expanded
	parent.add_child(content_scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_scroll.add_child(content)

	var t := title  # capture for lambda
	toggle.toggled.connect(func(pressed: bool):
		content_scroll.visible = pressed
		toggle.text = "%s %s" % ["\u25bc" if pressed else "\u25b6", t]
	)

	return content


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

	_read_only_badge = Label.new()
	_read_only_badge.text = "\u26a0 Read-only mode"
	_read_only_badge.tooltip_text = (
		"Only read-only tools are available. To exit: remove "
		+ "GODOT_MCP_READ_ONLY from .mcp.json and reconnect the MCP client.")
	_read_only_badge.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_read_only_badge.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	_read_only_badge.add_theme_font_size_override("font_size", 11)
	_read_only_badge.visible = _is_read_only()
	sc.add_child(_read_only_badge)

	# Node.js availability — shared detection, dual display (Status + Gates).
	var node_check := MCPNodejsCheck.check()
	var nodejs_msg := ""
	if not node_check["found"]:
		nodejs_msg = ("Node.js not found — the MCP server bridge requires "
			+ "Node.js 20+. Download it from https://nodejs.org")
	elif not node_check["meets_minimum"]:
		nodejs_msg = ("Node.js %s found but 20+ is required. "
			+ "Update from https://nodejs.org") % str(node_check["version"])
	_nodejs_status_warning = Label.new()
	_nodejs_status_warning.text = nodejs_msg
	_nodejs_status_warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_nodejs_status_warning.add_theme_color_override("font_color", Color(1.0, 0.6, 0.3))
	_nodejs_status_warning.add_theme_font_size_override("font_size", 11)
	_nodejs_status_warning.visible = nodejs_msg != ""
	sc.add_child(_nodejs_status_warning)

	# == Collapsible sections (titles always visible) =========================
	var sections_vbox := VBoxContainer.new()
	sections_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sections_vbox.add_theme_constant_override("separation", int(2 * scale))
	add_child(sections_vbox)

	# -- Feature Gates section (expanded by default) --------------------------
	# Keep references to header + scroll so we can hide them when read-only.
	var fc := _make_collapsible_section(sections_vbox, "Feature Gates", true, 40.0)
	_gates_header = sections_vbox.get_child(sections_vbox.get_child_count() - 2) as PanelContainer
	_gates_scroll = sections_vbox.get_child(sections_vbox.get_child_count() - 1) as ScrollContainer

	_mcp_json_hint = Label.new()
	_mcp_json_hint.text = "No .mcp.json found — use Project > Tools > MCP Toolkit > Write .mcp.json"
	_mcp_json_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mcp_json_hint.add_theme_color_override("font_color", Color(1.0, 0.6, 0.3))
	_mcp_json_hint.add_theme_font_size_override("font_size", 11)
	_mcp_json_hint.visible = false
	fc.add_child(_mcp_json_hint)

	_nodejs_gate_warning = Label.new()
	_nodejs_gate_warning.text = nodejs_msg
	_nodejs_gate_warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_nodejs_gate_warning.add_theme_color_override("font_color", Color(1.0, 0.6, 0.3))
	_nodejs_gate_warning.add_theme_font_size_override("font_size", 11)
	_nodejs_gate_warning.visible = nodejs_msg != ""
	fc.add_child(_nodejs_gate_warning)

	var feat_grid := GridContainer.new()
	feat_grid.columns = 3
	feat_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fc.add_child(feat_grid)

	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)

		var check := CheckBox.new()
		check.text = feature
		check.tooltip_text = str(entry["risk"])
		check.size_flags_horizontal = Control.SIZE_EXPAND | Control.SIZE_SHRINK_CENTER
		check.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		check.toggled.connect(_on_feature_toggled.bind(feature))
		feat_grid.add_child(check)

		_feature_rows[feature] = {"check": check}

	# -- Audit Log section (collapsed by default) -----------------------------
	var ac := _make_collapsible_section(sections_vbox, "Audit Log", false)

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

	# -- Security & Response Limits section (collapsed by default) ------------
	var lc := _make_collapsible_section(sections_vbox, "Security & Response Limits", false)

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

	# == Footer (pinned at bottom) ============================================
	var footer := PanelContainer.new()
	footer.add_theme_stylebox_override("panel", _make_section_style())
	footer.size_flags_vertical = Control.SIZE_SHRINK_END
	add_child(footer)

	var footer_row := HBoxContainer.new()
	footer.add_child(footer_row)

	var skills_btn := Button.new()
	skills_btn.text = "Companion Skills"
	skills_btn.tooltip_text = "Open Companion Skills folder"
	skills_btn.pressed.connect(_open_companion_skills)
	skills_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer_row.add_child(skills_btn)

	var info_btn := Button.new()
	info_btn.text = "Info / Help"
	info_btn.pressed.connect(_show_info_dialog)
	info_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer_row.add_child(info_btn)



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
	var port: int = _server.get_bound_port()
	var port_str := str(port) if port > 0 else "6505"
	if _server.is_listening():
		_status_label.text = "Listening on 127.0.0.1:%s" % port_str
	else:
		_status_label.text = "Not listening"
	var count: int = _server.get_authed_peer_count()
	_peer_label.text = "%d peer%s" % [count, "" if count == 1 else "s"]
	if _read_only_badge != null:
		_read_only_badge.visible = _is_read_only()
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


# ---------------------------------------------------------------------------
# Feature toggle
# ---------------------------------------------------------------------------

func _refresh_features() -> void:
	if _feature_rows.is_empty():
		return

	var read_only := _is_read_only()

	# Hide gates section entirely when read-only (mutating tools excluded server-side).
	if _gates_header != null:
		_gates_header.visible = not read_only
	if _gates_scroll != null:
		_gates_scroll.visible = not read_only

	# Show hint when .mcp.json is missing.
	var has_mcp := MCPJsonSync.has_mcp_json()
	if _mcp_json_hint != null:
		_mcp_json_hint.visible = not has_mcp

	# Update gate checkboxes — sidecar is the runtime source of truth,
	# with PS fallback when sidecar is missing (e.g. after .godot/ deletion).
	var sidecar_gates := MCPStateFile.get_current_gates()
	var sidecar_has_gates := not sidecar_gates.is_empty()
	for feature in _feature_rows:
		var row: Dictionary = _feature_rows[feature]
		var check: CheckBox = row["check"]
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		var enabled: bool
		if sidecar_has_gates:
			enabled = sidecar_gates.get(str(entry["env_var"]), false) == true
		else:
			enabled = ProjectSettings.get_setting(str(entry["ps_key"]), false)
		check.set_pressed_no_signal(enabled)
		check.disabled = false
		check.tooltip_text = str(entry["risk"])


func _on_feature_toggled(enabled: bool, feature: String) -> void:
	var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
	if entry == null:
		return

	# H7: Dangerous-gate confirmation for RCE-class features.
	if enabled and MCPFeatureGate.needs_danger_warning(feature):
		_feature_rows[feature]["check"].set_pressed_no_signal(false)
		_show_danger_confirmation(feature)
		return

	# Write to sidecar (runtime source of truth).
	var err := MCPStateFile.set_gate(str(entry["env_var"]), enabled)
	if err != OK:
		_toast("Could not update gate state (err %d)" % err, _TOAST_WARNING)
		_feature_rows[feature]["check"].set_pressed_no_signal(not enabled)
		return

	# Sync PS mirror for immediate Inspector update.
	ProjectSettings.set_setting(str(entry["ps_key"]), enabled)
	ProjectSettings.save()

	_refresh_features()
	if _notifier != null:
		_notifier.broadcast_config_reloaded()


## H7: Dangerous-gate confirmation for RCE-class features.
var _danger_dialog: ConfirmationDialog = null

func _show_danger_confirmation(feature: String) -> void:
	# H7: Clean up any lingering dialog (queue_free may not have processed yet).
	if _danger_dialog != null:
		if is_instance_valid(_danger_dialog):
			_danger_dialog.hide()
			_danger_dialog.queue_free()
		_danger_dialog = null
	var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
	var warn_text: String = entry.get("warn_text", str(entry["risk"]))
	_danger_dialog = ConfirmationDialog.new()
	_danger_dialog.exclusive = false
	_danger_dialog.title = "Enable %s?" % feature
	_danger_dialog.dialog_text = (
		"WARNING: This is a potentially dangerous capability.\n\n"
		+ "%s\n\n" % warn_text
		+ "Risk level: %s\n\n" % entry["risk"]
		+ "Only enable if you trust the current AI context.")
	_danger_dialog.ok_button_text = "I Understand — Enable"
	_danger_dialog.confirmed.connect(func():
		MCPFeatureGate.mark_warned(feature)
		# Proceed with the toggle as if the user just pressed the checkbox.
		_on_feature_toggled(true, feature)
		var d := _danger_dialog
		_danger_dialog = null
		if d != null:
			d.hide()
			d.queue_free()
	)
	_danger_dialog.canceled.connect(func():
		var d := _danger_dialog
		_danger_dialog = null
		if d != null:
			d.hide()
			d.queue_free()
	)
	EditorInterface.get_base_control().add_child(_danger_dialog)
	_danger_dialog.popup_centered()


## Enable all feature gates (called from onboarding wizard "Enable All" button).
func enable_all_gates() -> void:
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		MCPStateFile.set_gate(str(entry["env_var"]), true)
		ProjectSettings.set_setting(str(entry["ps_key"]), true)
	ProjectSettings.save()
	_refresh_features()
	_refresh_status()
	if _notifier != null:
		_notifier.broadcast_config_reloaded()


# ---------------------------------------------------------------------------
# Audit log popup
# ---------------------------------------------------------------------------

func show_audit_dialog() -> void:
	# Read the log file.
	var path := _audit_path
	if path.is_empty():
		path = _Hub.MCPAudit.get_log_path()
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
	dialog.exclusive = false
	dialog.title = "Clear Audit Log?"
	dialog.dialog_text = "This will permanently delete all audit log entries."
	dialog.ok_button_text = "Clear"
	dialog.confirmed.connect(func():
		var path := _audit_path
		if path.is_empty():
			path = _Hub.MCPAudit.get_log_path()
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
		dialog.exclusive = false
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
	_toast("MCP: .mcp.json created from template", _TOAST_INFO,
		"Wrote to " + dest)


# ---------------------------------------------------------------------------
# Read-only mode detection
# ---------------------------------------------------------------------------

func _is_read_only() -> bool:
	var env := MCPJsonSync.get_all_env_vars()
	return env.get("GODOT_MCP_READ_ONLY", "") == "1"


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
# Companion Skills
# ---------------------------------------------------------------------------

func _open_companion_skills() -> void:
	var skills_dir := "res://addons/godot_mcp_toolkit/CompanionSkills"
	var global_path := ProjectSettings.globalize_path(skills_dir)
	OS.shell_open(global_path)


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
	if _server != null and _server.is_listening():
		var port: int = _server.get_bound_port()
		var peers: int = _server.get_authed_peer_count()
		_add_info_row(vbox, "Address", "127.0.0.1:%d" % port)
		_add_info_row(vbox, "Peers", "%d connected" % peers)
	else:
		_add_info_row(vbox, "Address", "not listening")
	if _is_read_only():
		_add_info_row(vbox, "Mode", "Read-only (GODOT_MCP_READ_ONLY=1)")

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

	# -- Read-only mode --
	_add_info_header(vbox, "Read-Only Mode")
	var readonly_note := Label.new()
	readonly_note.text = (
		"For supervised environments (classrooms, CI, demos).\n"
		+ "Set GODOT_MCP_READ_ONLY=1 in your .mcp.json env to restrict\n"
		+ "the toolkit to read-only tools only. All mutating tools\n"
		+ "(create, delete, write, execute) are hidden from the AI agent.\n"
		+ "Remove the env var and reconnect to restore full access.")
	readonly_note.add_theme_font_size_override("font_size", 11)
	readonly_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(readonly_note)

	# -- Companion Skills --
	_add_info_header(vbox, "Companion Skills")
	var skills_note := Label.new()
	skills_note.text = (
		"Claude Code skills for common toolkit workflows are bundled\n"
		+ "with the plugin. Click the 'Companion Skills' button in the\n"
		+ "dock to browse them, then copy any skill you want into your\n"
		+ "project's .claude/skills/ directory.")
	skills_note.add_theme_font_size_override("font_size", 11)
	skills_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(skills_note)

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
	if severity >= _TOAST_WARNING:
		push_warning("[MCP] %s" % msg)
	else:
		print("[MCP] %s" % msg)
	# EditorToaster available in Godot 4.4+ (dynamic dispatch for compat).
	var toaster = _Hub.get_toaster()
	if toaster != null:
		toaster.push_toast(msg, severity, tooltip_text)
