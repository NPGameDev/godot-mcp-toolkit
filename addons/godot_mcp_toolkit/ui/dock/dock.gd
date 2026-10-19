@tool
extends VBoxContainer
## MCP bottom-panel dock — signal-driven status with polled runtime label.
##
## Created and bound by plugin.gd. Server status is signal-driven
## (no polling delay); a lightweight timer polls the runtime label
## during playtests so it updates without requiring server events.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const NodejsCheck = Modules.NodejsCheck
const MCPJsonWriteFlow := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_write_flow.gd")
const ToolkitDialogPresenter := preload("res://addons/godot_mcp_toolkit/ui/toolkit_dialog_presenter.gd")
const DockSectionCard := preload("res://addons/godot_mcp_toolkit/ui/dock/dock_section_card.gd")
const DockStatusPanel := preload("res://addons/godot_mcp_toolkit/ui/dock/status/dock_status_panel.gd")
const DockLimitsSection := preload("res://addons/godot_mcp_toolkit/ui/dock/limits/dock_limits_section.gd")
const DockUnfocusedControl := preload("res://addons/godot_mcp_toolkit/ui/dock/limits/dock_unfocused_control.gd")
const DockOptionalStepsControl := preload("res://addons/godot_mcp_toolkit/ui/dock/limits/dock_optional_steps_control.gd")
const DockAuditSection := preload("res://addons/godot_mcp_toolkit/ui/dock/security/dock_audit_section.gd")
const DockMcpJsonPanel := preload("res://addons/godot_mcp_toolkit/ui/dock/mcp/dock_mcp_json_panel.gd")
const DockUpdateBadge := preload("res://addons/godot_mcp_toolkit/ui/dock/update/dock_update_badge.gd")
const UpdateCheckRunner = Modules.UpdateCheckRunner

# Toast severity constants (match EditorToaster.Severity).
const _TOAST_INFO := 0
const _TOAST_WARNING := 1
const _TOAST_ERROR := 2

const _SETUP_WIZARD_TOOLTIP := (
	"Walk through every setup step again. Nothing changes until you press a button inside a step.")

var _server: Node = null
var _audit_path: String = ""

# Server-status section — listening/peer/runtime/LSP/activity labels (own sub-panel).
var _status_panel: DockStatusPanel = null

# .mcp.json health surface — shared missing/malformed/read-only warning panel +
# the write-or-open footer button + read-only cache + write/open flow (own sub-panel).
var _mcp_json_panel: DockMcpJsonPanel = null

# Unfocused-responsive mode — opt-in toggle + 3-state indicator (own sub-panel).
var _unfocused_control: DockUnfocusedControl = null

# Audit Log section — settings + view/clear + the lazy log viewer (own sub-panel).
var _audit_section: DockAuditSection = null

# Node.js warning.
var _nodejs_status_warning: Label = null

# Injected cross-cutting collaborators (composer-owned): the shared .mcp.json
# write flow and the editor-global dialog presenter. The dock CONSUMES them —
# footer buttons + the .mcp.json panel — exactly like the Tools menu and the
# onboarding wizard do; it never owns these behaviors.
var _write_flow: MCPJsonWriteFlow = null
var _dialog_presenter: ToolkitDialogPresenter = null
# The composer-owned update check; the dock only hosts its badge.
var _update_check: UpdateCheckRunner = null
# Starts a setup-wizard run for the footer's Setup Wizard button. The dock does not
# own the wizard: the plugin does, and the composer passes this in.
var _start_setup_wizard: Callable = Callable()

# Lightweight timer for runtime-status polling during playtests.
var _runtime_timer: Timer = null


## Binds the dock to the server and the composer-owned collaborators.
## [param on_setup_wizard_requested] is called, with no arguments, when the user
## presses the footer's Setup Wizard button.
func bind(
		server: Node, audit_path: String,
		write_flow: MCPJsonWriteFlow, dialog_presenter: ToolkitDialogPresenter,
		update_check: UpdateCheckRunner, on_setup_wizard_requested: Callable) -> void:
	_server = server
	_audit_path = audit_path
	_write_flow = write_flow
	_dialog_presenter = dialog_presenter
	_update_check = update_check
	_start_setup_wizard = on_setup_wizard_requested
	_server.client_connected.connect(_on_client_connected)
	_server.client_disconnected.connect(_on_client_disconnected)
	_server.command_received.connect(_on_command_received)
	# LSP verdict arrives via editor.set_lsp_status (a command, not a dock signal);
	# refresh exactly when the server sets it, so the label is never stale.
	_server.lsp_status_changed.connect(_on_lsp_status_changed)
	# Listen state (fresh bind, pinned/band conflict, port-config error) — repaint
	# the instant the server's state changes, in addition to the initial pull below.
	_server.port_status_changed.connect(_on_port_status_changed)
	# The connected server's floor verdict — show or clear the below-floor line as
	# soon as a peer authenticates or the last one leaves.
	_server.compat_status_changed.connect(_on_compat_status_changed)
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

	# == Update badge (first child, hidden unless a newer version is published) ==
	add_child(DockUpdateBadge.new(_update_check, Callable(self, "_toast")))

	# == Status section (compact, pinned at top) ==============================
	var status_section := DockSectionCard.make_section("Server Status")
	add_child(status_section)
	var sc: VBoxContainer = status_section.get_meta("content")

	# Server-status labels (listening/peer/runtime/LSP/activity) — own sub-panel.
	# The dock routes server signals to it for label updates; it reads the server.
	_status_panel = DockStatusPanel.new(_server)
	sc.add_child(_status_panel)

	# .mcp.json health panel — the shared missing/malformed/read-only warning sits
	# right after the server status row (prominent); its write-or-open button lives in
	# the footer (placement = orchestrator) but is driven by this panel (meaning).
	# Create the button now so the panel can bind it; the footer positions it below.
	# The warning panel is hosted inside the status panel (between the status row and
	# the runtime label) — placement is the status panel's, behavior stays here.
	var mcp_json_btn := Button.new()
	mcp_json_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mcp_json_panel = DockMcpJsonPanel.new(mcp_json_btn, Callable(self, "_toast"), _write_flow)
	_status_panel.insert_warning_panel(_mcp_json_panel)
	# The Info dialog reads the badge's cached read-only state through the
	# presenter, so the two agree. Set here, not in bind(): the panel exists only
	# once the UI is built.
	if _dialog_presenter != null:
		_dialog_presenter.set_read_only_source(_mcp_json_panel.is_read_only_active)

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
			+ "Node.js 22+. Download it from https://nodejs.org" + _path_hint)
	elif not node_check["meets_minimum"]:
		nodejs_msg = ("Node.js %s found but 22+ is required. "
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

	# The setup wizard's optional-steps setting, the other machine-wide preference
	# here. The control owns its setting I/O and repaints itself on a change.
	sc.add_child(DockOptionalStepsControl.new())

	# == Collapsible sections (one scroll area, spare height below) ===========
	var sections_vbox := DockSectionCard.make_scroll_area(self)
	sections_vbox.add_theme_constant_override("separation", int(2 * scale))

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

	# A dock dragged short keeps every section header in view and scrolls the
	# open sections, while Server Status and the footer stay pinned around them.
	DockSectionCard.apply_header_floor(sections_vbox)

	# == Footer (pinned at bottom) ============================================
	var footer := PanelContainer.new()
	footer.add_theme_stylebox_override("panel", DockSectionCard.make_section_style())
	footer.size_flags_vertical = Control.SIZE_SHRINK_END
	add_child(footer)

	var footer_row := HBoxContainer.new()
	footer.add_child(footer_row)

	footer_row.add_child(_make_footer_button(
			"Companion Skills", "Open Companion Skills folder", _open_companion_skills))
	footer_row.add_child(_make_footer_button(
			"Extensions", "Browse MCP Toolkit extensions", _on_extensions_pressed))

	# Built above (status section) so _mcp_json_panel could bind it; the footer owns
	# only its placement. Label/tooltip/colour/action are driven by the panel.
	mcp_json_btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	footer_row.add_child(mcp_json_btn)

	footer_row.add_child(_make_footer_button("Info / Help", "Info / Help", _on_info_pressed))
	footer_row.add_child(_make_footer_button(
			"Setup Wizard", _SETUP_WIZARD_TOOLTIP, _on_setup_wizard_pressed))


# A footer button that shares the row equally and trims its label with an ellipsis
# when the dock is narrow, instead of widening the row. The tooltip carries the full
# label for a trimmed button.
func _make_footer_button(label: String, tooltip: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.tooltip_text = tooltip
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(on_pressed)
	return button


# ---------------------------------------------------------------------------
# Signal handlers — server events (no polling)
# ---------------------------------------------------------------------------

func _on_client_connected(peer_count: int) -> void:
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


# Floor-verdict signal — route to the status panel's below-floor line. Separate
# handler so bind() can connect before _build_ui exists.
func _on_compat_status_changed() -> void:
	if _status_panel != null:
		_status_panel.refresh_compat()


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


func _on_setup_wizard_pressed() -> void:
	if _start_setup_wizard.is_valid():
		_start_setup_wizard.call()


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
