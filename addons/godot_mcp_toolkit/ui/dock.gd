@tool
extends VBoxContainer
## MCP bottom-panel dock — signal-driven status with polled runtime label.
##
## Created and bound by plugin.gd. Server status is signal-driven
## (no polling delay); a lightweight timer polls the runtime label
## during playtests so it updates without requiring server events.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const McpJsonSync = _Hub.McpJsonSync
const RegistryClient = _Hub.RegistryClient
const NodejsCheck = _Hub.NodejsCheck
const ExtensionCatalogDialog := preload("res://addons/godot_mcp_toolkit/ui/extension_catalog_dialog.gd")
const AuditLogDialog := preload("res://addons/godot_mcp_toolkit/ui/audit_log_dialog.gd")
const InfoDialog := preload("res://addons/godot_mcp_toolkit/ui/info_dialog.gd")
const DockConfirm := preload("res://addons/godot_mcp_toolkit/ui/dock_confirm.gd")
const DockSectionCard := preload("res://addons/godot_mcp_toolkit/ui/dock_section_card.gd")

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
var _lsp_label: Label = null
# Shared warning panel for the two "something needs attention" .mcp.json states:
# missing file (live FACT) OR read-only mode (server-synced). Its label text is
# set per-state by _refresh_mcp_json_indicators(); the panel/label are built once
# in _build_ui (style fixed there).
var _warning_panel: PanelContainer = null
var _warning_label: Label = null
var _mcp_json_btn: Button = null
# Cached read-only state — synced from .mcp.json on server (re)connect + startup,
# NOT on the 1s timer: the server reads GODOT_MCP_READ_ONLY from process.env once
# at its launch and never re-checks, so a live poll would claim read-only is active
# before the server applies it (a client→server relaunch is what takes effect).
var _read_only_active: bool = false

# Unfocused-responsive mode — 3-state indicator + inline opt-in toggle.
var _unfocused_check: CheckBox = null
var _unfocused_state_label: Label = null

# Node.js warning.
var _nodejs_status_warning: Label = null

# Settings widgets.
var _script_cap_spinbox: SpinBox = null
var _save_cap_spinbox: SpinBox = null
var _ws_buffer_spinbox: SpinBox = null

# Info/Help dialog (populated on demand).
var _info_dialog: InfoDialog = null

# Extension catalog dialog (populated on demand).
var _catalog_dialog: Window = null

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
	# LSP verdict arrives via editor.set_lsp_status (a command, not a dock signal);
	# refresh exactly when the server sets it, so the label is never stale.
	_server.lsp_status_changed.connect(_refresh_lsp_label)
	_refresh_status()


func _ready() -> void:
	_build_ui()
	# bind() runs before _ready (node not yet in tree), so its refresh
	# calls exit early on null widgets. Re-run now that UI exists.
	_refresh_status()
	# Lightweight timer so the runtime label updates during playtests without
	# requiring server events (e.g. port discovery, playtest end). It also keeps the
	# .mcp.json BUTTON + warning panel honest about file presence (Write vs Open,
	# missing-warning) — a cheap file_exists, never misleading. It deliberately does
	# NOT refresh the read-only state: that is server-synced (see _on_client_connected),
	# never polled.
	_runtime_timer = Timer.new()
	_runtime_timer.wait_time = 1.0
	_runtime_timer.timeout.connect(_refresh_runtime_status)
	_runtime_timer.timeout.connect(_refresh_mcp_json_indicators)
	add_child(_runtime_timer)
	_runtime_timer.start()


func _exit_tree() -> void:
	for dialog in [_audit_dialog, _info_dialog, _catalog_dialog]:
		if dialog != null and is_instance_valid(dialog):
			dialog.queue_free()
	_audit_dialog = null
	_info_dialog = null
	_catalog_dialog = null


# ---------------------------------------------------------------------------
# UI construction (programmatic — all dynamic content)
# ---------------------------------------------------------------------------


func _build_ui() -> void:
	var scale := EditorInterface.get_editor_scale()
	add_theme_constant_override("separation", int(4 * scale))

	# == Status section (compact, pinned at top) ==============================
	var status_section := DockSectionCard.make_section("Server Status")
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

	# Shared missing/read-only warning — prominent, right after the server status
	# row. Text + visibility are owned by _refresh_mcp_json_indicators() (driven by
	# the first _refresh_status() + the 1s timer); built hidden + empty here.
	_warning_panel = PanelContainer.new()
	var warn_sb := StyleBoxFlat.new()
	warn_sb.bg_color = Color(0.35, 0.22, 0.0)
	warn_sb.corner_radius_top_left = 4
	warn_sb.corner_radius_top_right = 4
	warn_sb.corner_radius_bottom_left = 4
	warn_sb.corner_radius_bottom_right = 4
	warn_sb.content_margin_left = 8
	warn_sb.content_margin_right = 8
	warn_sb.content_margin_top = 6
	warn_sb.content_margin_bottom = 6
	_warning_panel.add_theme_stylebox_override("panel", warn_sb)
	_warning_panel.visible = false

	_warning_label = Label.new()
	_warning_label.text = ""
	_warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_warning_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	_warning_label.add_theme_font_size_override("font_size", 12)
	_warning_panel.add_child(_warning_label)
	sc.add_child(_warning_panel)

	_runtime_label = Label.new()
	_runtime_label.text = "Runtime: not running"
	_runtime_label.add_theme_font_size_override("font_size", 13)
	sc.add_child(_runtime_label)

	# GDScript LSP endpoint the server discovers for this editor (best-effort;
	# the server is authoritative for conflicts). See Fix 3, 41l-tertricies.
	_lsp_label = Label.new()
	_lsp_label.text = "LSP: —"
	_lsp_label.add_theme_font_size_override("font_size", 12)
	_lsp_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	sc.add_child(_lsp_label)

	_activity_label = Label.new()
	_activity_label.text = "Last activity: —"
	_activity_label.add_theme_font_size_override("font_size", 12)
	_activity_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	sc.add_child(_activity_label)

	# Node.js availability — shared detection.
	var node_check := NodejsCheck.check()
	var nodejs_msg := ""
	if not node_check["found"]:
		var _path_hint := ""
		if OS.get_name() == "Windows":
			_path_hint = "\nIf Node.js is installed, ensure it is on your system PATH."
		nodejs_msg = ("Node.js not found — the MCP server bridge requires "
			+ "Node.js 20+. Download it from https://nodejs.org" + _path_hint)
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

	# Unfocused-responsive mode — inline opt-in toggle + 3-state indicator.
	# (Lives in Editor Settings, not Project Settings; see ADR 0007.)
	var unfocused_row := HBoxContainer.new()
	sc.add_child(unfocused_row)

	_unfocused_check = CheckBox.new()
	_unfocused_check.text = "Responsive when unfocused"
	var resp_enabled := true
	var resp_es := EditorInterface.get_editor_settings()
	if resp_es != null and resp_es.has_setting(
			"mcp_toolkit/performance/keep_editor_responsive_unfocused"):
		resp_enabled = bool(resp_es.get_setting(
			"mcp_toolkit/performance/keep_editor_responsive_unfocused"))
	_unfocused_check.set_pressed_no_signal(resp_enabled)
	_unfocused_check.toggled.connect(_on_unfocused_responsive_toggled)
	unfocused_row.add_child(_unfocused_check)

	_unfocused_state_label = Label.new()
	_unfocused_state_label.add_theme_font_size_override("font_size", 11)
	_unfocused_state_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_unfocused_state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	unfocused_row.add_child(_unfocused_state_label)

	# == Collapsible sections (titles always visible) =========================
	var sections_vbox := VBoxContainer.new()
	sections_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sections_vbox.add_theme_constant_override("separation", int(2 * scale))
	add_child(sections_vbox)

	# -- Audit Log section (collapsed by default) -----------------------------
	var ac := DockSectionCard.make_collapsible(sections_vbox, "Audit Log", false)

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
	var lc := DockSectionCard.make_collapsible(sections_vbox, "Security & Response Limits", false)

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
	var save_cap_label := Label.new()
	save_cap_label.text = "Save cap:"
	limits_row.add_child(save_cap_label)
	_save_cap_spinbox = SpinBox.new()
	_save_cap_spinbox.min_value = 64
	_save_cap_spinbox.max_value = 4096
	_save_cap_spinbox.step = 64
	_save_cap_spinbox.suffix = "KB"
	_save_cap_spinbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_cap_spinbox.value = ProjectSettings.get_setting(
		"mcp_toolkit/limits/save_read_cap_kb", 256)
	_save_cap_spinbox.value_changed.connect(_on_save_cap_changed)
	limits_row.add_child(_save_cap_spinbox)
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
	footer.add_theme_stylebox_override("panel", DockSectionCard.make_section_style())
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

	var extensions_btn := Button.new()
	extensions_btn.text = "Extensions"
	extensions_btn.tooltip_text = "Browse MCP Toolkit extensions"
	extensions_btn.pressed.connect(show_extension_catalog)
	extensions_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer_row.add_child(extensions_btn)

	_mcp_json_btn = Button.new()
	# Label/tooltip/colour are owned by _refresh_mcp_json_indicators() (driven by the
	# first _refresh_status() + the 1s timer); this initial text is just a
	# pre-refresh placeholder.
	_mcp_json_btn.text = "Open .mcp.json"
	_mcp_json_btn.tooltip_text = "Open .mcp.json in the system editor"
	_mcp_json_btn.pressed.connect(_on_mcp_json_btn_pressed)
	_mcp_json_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer_row.add_child(_mcp_json_btn)

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
	# A (re)connecting MCP server has just read GODOT_MCP_READ_ONLY from its env, so
	# this is exactly when read-only takes effect — sync the badge to match it.
	# Caveat: an already-connected server keeps its launch-time read-only and does
	# NOT switch on a later .mcp.json edit (the server reads the env once at launch).
	# The badge reflects the latest connect's .mcp.json; older still-running servers
	# (multi-client) won't switch until they themselves reconnect.
	_refresh_read_only_state()
	_refresh_unfocused_indicator()


func _on_client_disconnected(peer_count: int) -> void:
	_peer_label.text = "%d peer%s" % [peer_count, "" if peer_count == 1 else "s"]
	_activity_label.text = "Last activity: client disconnected"
	if peer_count == 0:
		_toast("MCP client disconnected")
	_refresh_unfocused_indicator()


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
	var port_str := str(port) if port > 0 else "6550"
	if _server.is_listening():
		_status_label.text = "Listening on 127.0.0.1:%s" % port_str
	else:
		_status_label.text = "Not listening"
	var count: int = _server.get_authed_peer_count()
	_peer_label.text = "%d peer%s" % [count, "" if count == 1 else "s"]
	_refresh_read_only_state()
	_refresh_runtime_status()
	_refresh_lsp_label()
	_refresh_unfocused_indicator()


## Sync the read-only state from .mcp.json: cache it in _read_only_active, then
## refresh the indicators (the shared warning panel + the dual-mode button, whose
## ⚠ depends on this). Called on startup, on server (re)connect, and after a dock
## write — NEVER on the 1s timer: read-only takes effect server-side only when the
## MCP client relaunches the server (it reads GODOT_MCP_READ_ONLY from process.env
## once at startup), so polling would falsely show read-only before the server
## actually applies it. (The panel's visibility is owned by
## _refresh_mcp_json_indicators, which this calls — this method only caches state.)
func _refresh_read_only_state() -> void:
	_read_only_active = McpJsonSync.has_mcp_json() and McpJsonSync.is_read_only()
	_refresh_mcp_json_indicators()


## Refresh BOTH the shared warning panel AND the dual-mode footer button from one
## computed state (DRY) — three cases: missing .mcp.json, read-only, or normal.
##   * MISSING is a LIVE file FACT (cheap file_exists) — safe to poll on the 1s
##     timer and never misleading: panel warns + button says "Write" + amber.
##   * READ-ONLY uses the cached _read_only_active (server-synced, NOT a live
##     read-only poll): panel warns + button says "Open ⚠" + amber.
##   * NORMAL: panel hidden + button "Open" + neutral.
## The button's action re-checks has_mcp_json() on press, so it is never wrong.
func _refresh_mcp_json_indicators() -> void:
	var warn_text := ""
	var btn_text := "Open .mcp.json"
	var btn_tip := "Open .mcp.json in the system editor"
	var highlight := false
	if not McpJsonSync.has_mcp_json():  # live file FACT — safe to show live
		warn_text = "⚠️ NO .mcp.json — the MCP client has nothing to connect with. Use the \"Write .mcp.json\" button below to create one from the bundled template."
		btn_text = "Write .mcp.json"
		btn_tip = "No .mcp.json found — write one from the bundled template"
		highlight = true
	elif McpJsonSync.is_malformed():  # live file FACT — present but invalid JSON
		warn_text = "⚠️ .mcp.json isn't valid JSON — the MCP client can't read it, so it won't connect. Click \"Fix .mcp.json\" to repair it: overwrite with a clean template, or open the file to fix the JSON yourself."
		btn_text = "Fix .mcp.json"
		btn_tip = "Replace the malformed .mcp.json with a clean template (asks to confirm before overwriting)"
		highlight = true
	elif _read_only_active:  # cached, server-synced (NOT a live read-only poll)
		warn_text = "⚠️ READ-ONLY MODE — mutating tools are hidden. Remove GODOT_MCP_READ_ONLY from .mcp.json and reconnect the MCP client to restore full access."
		btn_text = "Open .mcp.json ⚠"
		btn_tip = "Open .mcp.json in the system editor (read-only mode active)"
		highlight = true
	# Warning panel (shared by both states).
	if _warning_panel != null:
		_warning_panel.visible = not warn_text.is_empty()
		if not warn_text.is_empty() and _warning_label != null:
			_warning_label.text = warn_text
	# Dual-mode button (shared amber highlight).
	if _mcp_json_btn != null:
		_mcp_json_btn.text = btn_text
		_mcp_json_btn.tooltip_text = btn_tip
		if highlight:
			_mcp_json_btn.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
		else:
			_mcp_json_btn.remove_theme_color_override("font_color")


func _refresh_runtime_status() -> void:
	if _runtime_label == null:
		return
	if EditorInterface.is_playing_scene():
		var rt_port := RegistryClient.get_runtime_port()
		if rt_port > 0:
			_runtime_label.text = "Runtime: listening on 127.0.0.1:%d" % rt_port
			_runtime_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
		else:
			_runtime_label.text = "Runtime: game running, waiting for port..."
			_runtime_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	else:
		_runtime_label.text = "Runtime: not running (start playtest with F5)"
		_runtime_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))


## LSP status indicator. The MCP server reports the authoritative verdict
## (editor.set_lsp_status) — the editor can't read its own LSP bind status, and
## in-engine cross-process liveness is unreliable on Windows, so the dock renders
## what the server determined. Falls back to the configured (published) endpoint
## until an MCP server connects.
func _refresh_lsp_label() -> void:
	if _lsp_label == null:
		return
	var st: Dictionary = {}
	if _server != null and _server.has_method("get_reported_lsp_status"):
		st = _server.get_reported_lsp_status()
	if not st.is_empty() and st.has("state"):
		var host := str(st.get("host", "127.0.0.1"))
		var port := int(st.get("port", 6005))
		match str(st.get("state", "")):
			"active":
				_lsp_label.text = "LSP: %s:%d · active" % [host, port]
				_lsp_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
				_lsp_label.tooltip_text = "This editor owns the GDScript LSP port (reported by the MCP server)."
			"conflict":
				_lsp_label.text = "LSP: %d ⚠ conflict — another editor owns this port" % port
				_lsp_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
				_lsp_label.tooltip_text = (
					"Another editor owns the machine-wide GDScript LSP port, so this editor's "
					+ "LSP tools are unavailable. Give each editor a distinct --lsp-port + "
					+ "GODOT_MCP_LSP_PORT. See docs/multi-instance.md.")
			_:  # "unavailable" / unknown
				_lsp_label.text = "LSP: %d ⚠ unavailable" % port
				_lsp_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
				_lsp_label.tooltip_text = str(st.get("detail", "GDScript LSP not reachable."))
		return
	# No server has reported yet — show the configured (published) endpoint.
	var ep := RegistryClient.get_lsp_endpoint()
	if ep.is_empty():
		_lsp_label.text = "LSP: —"
		_lsp_label.tooltip_text = ""
		_lsp_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		return
	_lsp_label.text = "LSP: %s:%d (editor setting · awaiting MCP server)" % [ep["host"], ep["port"]]
	_lsp_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_lsp_label.tooltip_text = (
		"Configured GDScript LSP port (the editor setting). If this editor was launched "
		+ "with --lsp-port the actual port differs — Godot doesn't expose it to the plugin, "
		+ "so the MCP server reports the real port (and owner/conflict status) on connect.")


# ---------------------------------------------------------------------------
# Audit log popup
# ---------------------------------------------------------------------------

func show_audit_dialog() -> void:
	if _audit_dialog == null or not is_instance_valid(_audit_dialog):
		_audit_dialog = AuditLogDialog.new()
		EditorInterface.get_base_control().add_child(_audit_dialog)
	_audit_dialog.show_log(_audit_path)


func _on_clear_audit_log() -> void:
	DockConfirm.confirm(
		"Clear Audit Log?",
		"This will permanently delete all audit log entries.",
		"Clear",
		func() -> void:
			var path := _audit_path
			if path.is_empty():
				path = _Hub.Audit.get_log_path()
			var file := FileAccess.open(path, FileAccess.WRITE)
			if file != null:
				file.store_string("")
				file.close()
			_toast("Audit log cleared")
	)


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
	# UI (the overwrite-confirm dialog + the result toast) stays here; the file
	# I/O lives in the McpJsonSync repository. When overwriting an existing file
	# and not already forced, confirm first, then write on confirmation.
	if not force_overwrite and McpJsonSync.needs_overwrite_confirm():
		var dest := McpJsonSync.get_mcp_json_path()
		# "Cancel" is repurposed as "Open .mcp.json": declining the overwrite opens
		# the file so the user can edit it (fix a malformed file, or inspect a valid
		# one) rather than lose it. Esc/✕ route through the same path — the intended
		# "don't overwrite, let me look at it" recovery.
		DockConfirm.confirm(
			".mcp.json already exists",
			"Overwrite .mcp.json with a clean template?\n\n" + dest
				+ "\n\nThis replaces your current content — choose \"Open .mcp.json\" instead to edit the file yourself.",
			"Overwrite",
			func() -> void: McpJsonSync.write_from_template(true, _on_mcp_json_write_result),
			"Open .mcp.json",
			func() -> void: OS.shell_open(dest),
		)
		return

	McpJsonSync.write_from_template(force_overwrite, _on_mcp_json_write_result)


# Result sink for McpJsonSync.write_from_template — maps the repository's
# (ok, message, severity, tooltip) report straight onto a toast. `severity`
# already matches the _TOAST_* scale (0 info / 1 warning / 2 error). On success
# (e.g. a dock write of a missing file), re-sync the read-only + button state now
# so the dual-mode button flips "Write" -> "Open" immediately rather than on the
# next timer tick.
func _on_mcp_json_write_result(ok: bool, message: String, severity: int, tooltip: String) -> void:
	_toast(message, severity, tooltip)
	if ok:
		_refresh_read_only_state()


# ---------------------------------------------------------------------------
# Settings handlers
# ---------------------------------------------------------------------------

func _on_script_cap_changed(value: float) -> void:
	var clamped := maxi(64, int(value))
	ProjectSettings.set_setting("mcp_toolkit/limits/script_read_cap_kb", clamped)
	ProjectSettings.save()


func _on_save_cap_changed(value: float) -> void:
	var clamped := maxi(64, int(value))
	ProjectSettings.set_setting("mcp_toolkit/limits/save_read_cap_kb", clamped)
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
# Unfocused-responsive mode (Editor Setting + 3-state indicator)
# ---------------------------------------------------------------------------

func _on_unfocused_responsive_toggled(enabled: bool) -> void:
	var es := EditorInterface.get_editor_settings()
	if es != null:
		es.set_setting("mcp_toolkit/performance/keep_editor_responsive_unfocused", enabled)
	# Apply immediately: on while connected → boost now; off while active →
	# conflict-aware restore now (instead of waiting for the next connect/disconnect).
	if _server != null:
		_server.notify_unfocused_responsive_setting_changed()
	_refresh_unfocused_indicator()


## Always-honest 3-state indicator: Off / On (idle) / On · active · {fps} fps.
func _refresh_unfocused_indicator() -> void:
	if _unfocused_state_label == null or _unfocused_check == null:
		return
	var enabled := true
	var es := EditorInterface.get_editor_settings()
	if es != null and es.has_setting(
			"mcp_toolkit/performance/keep_editor_responsive_unfocused"):
		enabled = bool(es.get_setting(
			"mcp_toolkit/performance/keep_editor_responsive_unfocused"))
	# Keep the checkbox in sync if the setting was changed in Editor Settings.
	if _unfocused_check.button_pressed != enabled:
		_unfocused_check.set_pressed_no_signal(enabled)
	var fps: int = _server.get_unfocused_responsive_fps() if _server != null else 60
	var connected: bool = _server != null and _server.get_authed_peer_count() > 0
	_unfocused_check.tooltip_text = (
		"Editor stays ~%d fps while unfocused so MCP commands stay responsive "
		+ "while a client is connected — raises background CPU. Off uses Godot's "
		+ "default low-power unfocused throttle. Configure the rate in "
		+ "Editor Settings → Mcp Toolkit → Performance.") % fps
	if not enabled:
		_unfocused_state_label.text = "Off"
		_unfocused_state_label.remove_theme_color_override("font_color")
	elif not connected:
		_unfocused_state_label.text = "On (idle)"
		_unfocused_state_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	else:
		_unfocused_state_label.text = "On · active · %d fps" % fps
		_unfocused_state_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))


# ---------------------------------------------------------------------------
# .mcp.json
# ---------------------------------------------------------------------------

# Tri-mode footer button (label set by _refresh_mcp_json_indicators):
#   * present + valid   -> "Open"  : open .mcp.json in the system editor.
#   * missing           -> "Write" : write_mcp_json() — a direct write (no file to
#                                    overwrite, so no confirm).
#   * present + invalid -> "Fix"   : write_mcp_json() — the file EXISTS, so the
#                                    existing overwrite-confirm fires before
#                                    replacing it with a clean template; a malformed
#                                    file is never silently clobbered (Cancel keeps
#                                    it for a manual fix). Same tested write flow.
# Re-checks state on press, so the action is always correct even if the label is
# momentarily stale.
func _on_mcp_json_btn_pressed() -> void:
	if McpJsonSync.has_mcp_json() and not McpJsonSync.is_malformed():
		OS.shell_open(McpJsonSync.get_mcp_json_path())
	else:
		write_mcp_json()


# ---------------------------------------------------------------------------
# Companion Skills
# ---------------------------------------------------------------------------

func _open_companion_skills() -> void:
	var skills_dir := "res://addons/godot_mcp_toolkit/CompanionSkills"
	var global_path := ProjectSettings.globalize_path(skills_dir)
	OS.shell_open(global_path)


# ---------------------------------------------------------------------------
# Extension Catalog
# ---------------------------------------------------------------------------


func show_extension_catalog() -> void:
	if _catalog_dialog == null or not is_instance_valid(_catalog_dialog):
		_catalog_dialog = ExtensionCatalogDialog.new()
		EditorInterface.get_base_control().add_child(_catalog_dialog)
	_catalog_dialog.show_catalog()


# ---------------------------------------------------------------------------
# Info / Help popup
# ---------------------------------------------------------------------------

func _show_info_dialog() -> void:
	if _info_dialog == null or not is_instance_valid(_info_dialog):
		_info_dialog = InfoDialog.new()
		EditorInterface.get_base_control().add_child(_info_dialog)
	_info_dialog.show_info(_server)


# ---------------------------------------------------------------------------
# Toast helper
# ---------------------------------------------------------------------------

func _toast(msg: String, severity: int = _TOAST_INFO, tooltip_text: String = "") -> void:
	if severity >= _TOAST_WARNING:
		push_warning("[MCP] %s" % msg)
	else:
		print("[MCP] %s" % msg)
	# EditorToaster available in Godot 4.4+ (dynamic dispatch for compat).
	var toaster = _Hub.EditorAccess.get_toaster()
	if toaster != null:
		toaster.push_toast(msg, severity, tooltip_text)
