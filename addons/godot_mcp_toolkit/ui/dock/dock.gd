@tool
extends VBoxContainer
## MCP bottom-panel dock — signal-driven status with polled runtime label.
##
## Created and bound by plugin.gd. Server status is signal-driven
## (no polling delay); a lightweight timer polls the runtime label
## during playtests so it updates without requiring server events.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const NodejsCheck = Modules.NodejsCheck
const MCPJsonSync = Modules.MCPJsonSync
const MacosLaunchHint := preload("res://addons/godot_mcp_toolkit/ui/dock/status/macos_launch_hint.gd")
const MCPJsonWriteFlow := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_write_flow.gd")
const ToolkitDialogPresenter := preload("res://addons/godot_mcp_toolkit/ui/toolkit_dialog_presenter.gd")
const DockSectionCard := preload("res://addons/godot_mcp_toolkit/ui/dock/dock_section_card.gd")
const DockStatusPanel := preload("res://addons/godot_mcp_toolkit/ui/dock/status/dock_status_panel.gd")
const DockLimitsSection := preload("res://addons/godot_mcp_toolkit/ui/dock/limits/dock_limits_section.gd")
const DockUnfocusedControl := preload("res://addons/godot_mcp_toolkit/ui/dock/limits/dock_unfocused_control.gd")
const DockAuditSection := preload("res://addons/godot_mcp_toolkit/ui/dock/security/dock_audit_section.gd")
const DockMcpJsonPanel := preload("res://addons/godot_mcp_toolkit/ui/dock/mcp/dock_mcp_json_panel.gd")
const DockMacosLaunchPanel := preload("res://addons/godot_mcp_toolkit/ui/dock/status/dock_macos_launch_panel.gd")

# Toast severity constants (match EditorToaster.Severity).
const _TOAST_INFO := 0
const _TOAST_WARNING := 1
const _TOAST_ERROR := 2

var _server: Node = null
var _audit_path: String = ""

# Server-status section — listening/peer/runtime/LSP/activity labels (own sub-panel).
var _status_panel: DockStatusPanel = null

# .mcp.json health surface — shared missing/malformed/read-only warning panel +
# the tri-mode footer button + read-only cache + write/open/fix flow (own sub-panel).
var _mcp_json_panel: DockMcpJsonPanel = null

# Unfocused-responsive mode — opt-in toggle + 3-state indicator (own sub-panel).
var _unfocused_control: DockUnfocusedControl = null

# Audit Log section — settings + view/clear + the lazy log viewer (own sub-panel).
var _audit_section: DockAuditSection = null

# macOS "listening, no client connected" guidance — persistent, all-version panel,
# driven by the connection-state gate below (replaces the 4.4+-only toast).
var _macos_launch_panel: DockMacosLaunchPanel = null

# Node.js warning.
var _nodejs_status_warning: Label = null

# Injected cross-cutting collaborators (composer-owned): the shared .mcp.json
# write flow and the editor-global dialog presenter. The dock CONSUMES them —
# footer buttons + the .mcp.json panel — exactly like the Tools menu and the
# onboarding wizard do; it never owns these behaviors.
var _write_flow: MCPJsonWriteFlow = null
var _dialog_presenter: ToolkitDialogPresenter = null

# Lightweight timer for runtime-status polling during playtests.
var _runtime_timer: Timer = null

# macOS GUI-launch guidance — session state the pure MacosLaunchHint predicate
# reads. _ever_connected latches true on the first client connect, so a peer that
# connects then drops never re-arms the guidance; _macos_hint_dismissed latches when
# the user closes the panel this session; _listening_seen_ms times the connect grace
# (mirrors the status panel's runtime-reach grace). All reset only by a fresh session.
var _ever_connected: bool = false
var _macos_hint_dismissed: bool = false
var _listening_seen_ms: int = -1


func bind(
		server: Node, audit_path: String,
		write_flow: MCPJsonWriteFlow, dialog_presenter: ToolkitDialogPresenter) -> void:
	_server = server
	_audit_path = audit_path
	_write_flow = write_flow
	_dialog_presenter = dialog_presenter
	_server.client_connected.connect(_on_client_connected)
	_server.client_disconnected.connect(_on_client_disconnected)
	_server.command_received.connect(_on_command_received)
	# LSP verdict arrives via editor.set_lsp_status (a command, not a dock signal);
	# refresh exactly when the server sets it, so the label is never stale.
	_server.lsp_status_changed.connect(_on_lsp_status_changed)
	# Listen state (fresh bind, pinned/band conflict, port-config error) — repaint
	# the instant the server's state changes, in addition to the initial pull below.
	_server.port_status_changed.connect(_on_port_status_changed)
	_refresh_status()


func _ready() -> void:
	_build_ui()
	# bind() runs before _ready (node not yet in tree), so its refresh
	# calls exit early on null widgets. Re-run now that UI exists.
	_refresh_status()
	# One 1s timer, fanned out in _on_runtime_timer_timeout to the runtime label
	# (playtest port discovery / playtest end) and the .mcp.json panel's file-validity
	# refresh; read-only stays server-synced (see _on_client_connected), never polled.
	_runtime_timer = Timer.new()
	_runtime_timer.wait_time = 1.0
	_runtime_timer.timeout.connect(_on_runtime_timer_timeout)
	add_child(_runtime_timer)
	_runtime_timer.start()


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

	# Server-status labels (listening/peer/runtime/LSP/activity) — own sub-panel.
	# The dock routes server signals to it for label updates; it reads the server.
	_status_panel = DockStatusPanel.new(_server)
	sc.add_child(_status_panel)

	# .mcp.json health panel — the shared missing/malformed/read-only warning sits
	# right after the server status row (prominent); its tri-mode button lives in
	# the footer (placement = orchestrator) but is driven by this panel (meaning).
	# Create the button now so the panel can bind it; the footer positions it below.
	# The warning panel is hosted inside the status panel (between the status row and
	# the runtime label) — placement is the status panel's, behavior stays here.
	var mcp_json_btn := Button.new()
	mcp_json_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mcp_json_panel = DockMcpJsonPanel.new(mcp_json_btn, Callable(self, "_toast"), _write_flow)
	_status_panel.insert_warning_panel(_mcp_json_panel)

	# macOS "listening, no client connected" guidance — a persistent, all-version
	# panel (a toast is 4.4+ only and transient). The dock drives its visibility from
	# the connection-state gate in _refresh_macos_launch_hint; the panel renders the
	# message + a session dismiss control.
	_macos_launch_panel = DockMacosLaunchPanel.new(MacosLaunchHint.message())
	_macos_launch_panel.dismissed.connect(_on_macos_hint_dismissed)
	sc.add_child(_macos_launch_panel)

	# Node.js availability — shared detection.
	var node_check := NodejsCheck.check()
	var nodejs_msg := ""
	if not node_check["found"]:
		var _path_hint := ""
		if OS.get_name() == "Windows":
			_path_hint = "\nIf Node.js is installed, ensure it is on your system PATH."
		elif OS.get_name() == "macOS":
			# A version-manager Node may not be on PATH for an app launched from
			# Finder/Dock; launching from a terminal inherits your shell PATH.
			_path_hint = ("\nIf Node.js is installed, ensure it is on your PATH. A "
				+ "version-manager Node (nvm/fnm/Homebrew) may need you to launch the "
				+ "editor and MCP client from a terminal, or install Node from "
				+ "https://nodejs.org so it lands on the default PATH.")
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

	# Unfocused-responsive mode — opt-in toggle + 3-state indicator sub-panel.
	# (Lives in Editor Settings, not Project Settings — a per-user, machine-wide
	# preference that must never land in project.godot / VCS.) The panel
	# owns the setting I/O + indicator; the dock routes refreshes to it. Applying
	# the setting (conflict-aware/crash-safe restore) is server-side; the panel
	# calls the bound server directly, so no signal back to the dock is needed.
	_unfocused_control = DockUnfocusedControl.new(_server)
	sc.add_child(_unfocused_control)

	# == Collapsible sections (titles always visible) =========================
	var sections_vbox := VBoxContainer.new()
	sections_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sections_vbox.add_theme_constant_override("separation", int(2 * scale))
	add_child(sections_vbox)

	# -- Audit Log section (collapsed by default) -----------------------------
	# The panel owns the audit settings + view/clear buttons + the lazy log
	# viewer; the dock injects its toast so the panel needs no toaster dependency.
	var ac := DockSectionCard.make_collapsible(sections_vbox, "Audit Log", false)
	_audit_section = DockAuditSection.new(_audit_path, Callable(self, "_toast"))
	ac.add_child(_audit_section)

	# -- Security & Response Limits section (collapsed by default) ------------
	var lc := DockSectionCard.make_collapsible(sections_vbox, "Security & Response Limits", false)
	var limits_section := DockLimitsSection.new()
	limits_section.regenerate_token_requested.connect(_on_regen_token)
	lc.add_child(limits_section)

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
	extensions_btn.pressed.connect(_on_extensions_pressed)
	extensions_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer_row.add_child(extensions_btn)

	# Built above (status section) so _mcp_json_panel could bind it; the footer owns
	# only its placement. Label/tooltip/colour/action are driven by the panel.
	footer_row.add_child(mcp_json_btn)

	var info_btn := Button.new()
	info_btn.text = "Info / Help"
	info_btn.pressed.connect(_on_info_pressed)
	info_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer_row.add_child(info_btn)



# ---------------------------------------------------------------------------
# Signal handlers — server events (no polling)
# ---------------------------------------------------------------------------

func _on_client_connected(peer_count: int) -> void:
	# A client connected — the macOS launch nudge no longer applies this session,
	# even if this peer later drops (a connected-then-dropped peer is a different
	# state than never-connected).
	_ever_connected = true
	# Status labels live in the status panel; the dock keeps the toast + the
	# fan-out to the other sub-panels (it knows which panel reacts to which event).
	if _status_panel != null:
		_status_panel.set_peer_count(peer_count)
		_status_panel.set_activity("Last activity: client connected")
	_toast("MCP client connected (%d peer%s)" % [
		peer_count, "" if peer_count == 1 else "s"])
	# A (re)connecting MCP server has just read GODOT_MCP_READ_ONLY from its env, so
	# this is exactly when read-only takes effect — sync the badge to match it.
	# Caveat: an already-connected server keeps its launch-time read-only and does
	# NOT switch on a later .mcp.json edit (the server reads the env once at launch).
	# The badge reflects the latest connect's .mcp.json; older still-running servers
	# (multi-client) won't switch until they themselves reconnect.
	if _mcp_json_panel != null:
		_mcp_json_panel.sync_read_only_state()
	if _unfocused_control != null:
		_unfocused_control.refresh()
	# A peer connected — the macOS guidance no longer applies; clear it at once
	# rather than waiting for the next timer tick.
	_refresh_macos_launch_hint()


func _on_client_disconnected(peer_count: int) -> void:
	if _status_panel != null:
		_status_panel.set_peer_count(peer_count)
		_status_panel.set_activity("Last activity: client disconnected")
	if peer_count == 0:
		_toast("MCP client disconnected")
	if _unfocused_control != null:
		_unfocused_control.refresh()


func _on_command_received(method: String) -> void:
	if _status_panel != null:
		_status_panel.set_activity("Last activity: %s" % method)


# LSP verdict signal — route to the status panel's LSP label (server-driven,
# never stale). Separate handler so bind() can connect before _build_ui exists.
func _on_lsp_status_changed() -> void:
	if _status_panel != null:
		_status_panel.refresh_lsp()


# Listen-state signal (fresh bind / conflict raised or cleared / config error) —
# repaint the status panel, which derives the status-row style and the
# not-listening warning from the server in one pass. Separate handler so bind()
# can connect before _build_ui exists.
func _on_port_status_changed() -> void:
	if _status_panel != null:
		_status_panel.refresh()


# 1s poll — one timer fans out to the runtime label (playtest port discovery /
# playtest end) AND the .mcp.json panel's file-validity refresh (file presence /
# malformed → button mode + warning). Both are live FACTs safe to poll; read-only
# stays server-synced (see _on_client_connected), never on this timer.
func _on_runtime_timer_timeout() -> void:
	if _status_panel != null:
		_status_panel.refresh_runtime()
	if _mcp_json_panel != null:
		_mcp_json_panel.refresh()
	_refresh_macos_launch_hint()


# macOS GUI-launch guidance: when the toolkit is listening but no client has
# connected after a grace period AND a valid .mcp.json exists (a client IS
# configured), surface a calm nudge with what to check. Drive the persistent panel
# from that state every tick, so it appears after the grace, self-clears the moment
# a client connects or the config is fixed, and stays hidden once the user dismisses
# it. The pure MacosLaunchHint predicate owns the decision; the dock owns the session
# state + timing here.
func _refresh_macos_launch_hint() -> void:
	if _macos_launch_panel == null or _server == null:
		return
	# Off macOS, dismissed, or a peer already connected → never show (and hide the
	# panel if it is currently up). Cheaper gates first: skip the file probe below.
	if OS.get_name() != "macOS" or _macos_hint_dismissed or _ever_connected:
		_macos_launch_panel.set_shown(false)
		return
	var listening: bool = _server.is_listening()
	# First tick of continuous listening — mirrors the status panel's runtime-reach
	# seen-timestamp grace; reset if listening drops so the grace measures continuity.
	if listening:
		if _listening_seen_ms < 0:
			_listening_seen_ms = Time.get_ticks_msec()
	else:
		_listening_seen_ms = -1
		_macos_launch_panel.set_shown(false)
		return
	var grace_elapsed := Time.get_ticks_msec() - _listening_seen_ms > MacosLaunchHint.NO_PEER_GRACE_MS
	# A valid (exists + parseable) .mcp.json means a client IS configured — the
	# anti-nag gate. Probed only after the cheaper gates pass.
	var mcp_json_valid := MCPJsonSync.has_mcp_json() and not MCPJsonSync.is_malformed()
	_macos_launch_panel.set_shown(MacosLaunchHint.should_show(
			OS.get_name(), listening, mcp_json_valid,
			_ever_connected, grace_elapsed, _macos_hint_dismissed))


# The user closed the guidance panel — latch the session dismiss so it stays hidden
# until the next editor session, and hide it now.
func _on_macos_hint_dismissed() -> void:
	_macos_hint_dismissed = true
	if _macos_launch_panel != null:
		_macos_launch_panel.set_shown(false)


# ---------------------------------------------------------------------------
# Status refresh — thin fan-out (the orchestrator decides what refreshes when)
# ---------------------------------------------------------------------------

func _refresh_status() -> void:
	if _status_panel != null:
		_status_panel.refresh()
	if _mcp_json_panel != null:
		_mcp_json_panel.sync_read_only_state()
	if _unfocused_control != null:
		_unfocused_control.refresh()


# ---------------------------------------------------------------------------
# Audit log popup
# ---------------------------------------------------------------------------

# Thin delegator — the audit dialog now lives in _audit_section. Kept public so
# the Tools menu (tool_menu.gd) can still open the log via the dock.
func show_audit_dialog() -> void:
	if _audit_section != null:
		_audit_section.show_dialog()


# ---------------------------------------------------------------------------
# Token regeneration
# ---------------------------------------------------------------------------

func _on_regen_token() -> void:
	if _server != null and _server.has_method("regenerate_token"):
		_server.regenerate_token()
		_toast("MCP token rotated")


# ---------------------------------------------------------------------------
# Companion Skills
# ---------------------------------------------------------------------------

func _open_companion_skills() -> void:
	var skills_dir := "res://addons/godot_mcp_toolkit/CompanionSkills"
	var global_path := ProjectSettings.globalize_path(skills_dir)
	OS.shell_open(global_path)


# ---------------------------------------------------------------------------
# Footer dialogs — thin consumers of the injected dialog presenter
# ---------------------------------------------------------------------------

func _on_extensions_pressed() -> void:
	if _dialog_presenter != null:
		_dialog_presenter.show_extension_catalog()


func _on_info_pressed() -> void:
	if _dialog_presenter != null:
		_dialog_presenter.show_info(_server)


# ---------------------------------------------------------------------------
# Toast helper
# ---------------------------------------------------------------------------

func _toast(msg: String, severity: int = _TOAST_INFO, tooltip_text: String = "") -> void:
	if severity >= _TOAST_WARNING:
		push_warning("[MCP] %s" % msg)
	else:
		print("[MCP] %s" % msg)
	# EditorToaster available in Godot 4.4+ (dynamic dispatch for compat).
	var toaster = Modules.EditorAccess.get_toaster()
	if toaster != null:
		toaster.push_toast(msg, severity, tooltip_text)
