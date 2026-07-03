@tool
extends PanelContainer
## Dock ".mcp.json health" sub-panel — the shared missing/malformed/read-only
## warning, the tri-mode footer button, and the write/open/fix flow.
##
## A dock sub-panel. Constructed and owned by dock.gd; this PanelContainer IS the
## shared warning panel and is added into the dock's status card (so the editor
## frees it with the dock). It owns the dock's .mcp.json UX cluster: the warning
## panel + label (built once here), the tri-mode footer button (built by the
## footer and injected, so the footer owns placement while this panel owns the
## button's meaning), the server-synced read-only cache, and the periodic
## file-validity poll. Writes delegate to the injected shared write flow (which
## owns the overwrite-confirm and its "Open .mcp.json" recovery); this panel
## keeps only its result sink (toast + read-only re-sync).
##
## Two refresh triggers, deliberately distinct (preserves 68fb6eb's model):
##   * file VALIDITY/presence is a live FACT — refreshed by the dock's 1s timer
##     fan-out (refresh(): Write-vs-Open-vs-Fix button mode + missing/malformed warning).
##   * read-only is SERVER STATE — synced only on server (re)connect + startup +
##     after a dock write (sync_read_only_state()), NEVER on the timer: the server
##     reads GODOT_MCP_READ_ONLY once at launch, so a live poll would claim
##     read-only before the server actually applies it.
## Both refresh paths MUTATE the warning panel + button built in _init(); they
## never recreate nodes. Toasts go through an injected Callable so the panel never
## touches the dock's private toaster.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const MCPJsonSync = Modules.MCPJsonSync
const MCPJsonWriteFlow := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_write_flow.gd")

# Toast severity constants (match EditorToaster.Severity / the dock's _TOAST_*).
const _TOAST_INFO := 0
const _TOAST_WARNING := 1
const _TOAST_ERROR := 2

# Tri-mode footer button — built + placed by the footer (dock owns placement),
# injected here so this panel owns its label/tooltip/colour/action (its meaning).
var _mcp_json_btn: Button = null
# Dock-supplied toast sink (msg, severity, tooltip) — injected so the panel stays
# decoupled from the editor toaster the dock owns.
var _toast: Callable = Callable()

# Shared confirm-then-write flow — injected (composer-owned) so the panel consumes
# the same flow as the Tools menu and onboarding wizard instead of owning it.
var _write_flow: MCPJsonWriteFlow = null

# The warning label inside this panel (this PanelContainer is the warning panel).
var _warning_label: Label = null

# Cached read-only state — synced from .mcp.json on server (re)connect + startup,
# NOT on the timer: the server reads GODOT_MCP_READ_ONLY from process.env once at
# its launch and never re-checks, so a live poll would claim read-only is active
# before the server applies it (a client→server relaunch is what takes effect).
var _read_only_active: bool = false


func _init(mcp_json_button: Button, toast: Callable, write_flow: MCPJsonWriteFlow) -> void:
	_mcp_json_btn = mcp_json_button
	_toast = toast
	_write_flow = write_flow

	# This PanelContainer is the shared warning panel — style + label built once;
	# text/visibility are mutated per-state by refresh()/sync_read_only_state().
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
	add_theme_stylebox_override("panel", warn_sb)
	visible = false

	_warning_label = Label.new()
	_warning_label.text = ""
	_warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_warning_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	_warning_label.add_theme_font_size_override("font_size", 12)
	add_child(_warning_label)

	# Bind the injected footer button to this panel's tri-mode action. Its initial
	# label/tooltip/colour are placeholders; refresh() owns them from here on.
	if _mcp_json_btn != null:
		_mcp_json_btn.text = "Open .mcp.json"
		_mcp_json_btn.tooltip_text = "Open .mcp.json in the system editor"
		_mcp_json_btn.pressed.connect(on_button_pressed)


# ---------------------------------------------------------------------------
# Refresh — file validity (dock-timer-driven FACT) + read-only (server-synced)
# ---------------------------------------------------------------------------


## Recompute the missing/malformed/read-only/normal state and repaint BOTH the
## warning panel and the tri-mode button from it — the one place that state
## machine lives (DRY). MUTATES the existing nodes only; never recreates them.
## Safe on the 1s timer: file presence + malformed are live FACTs; read-only uses
## the cached _read_only_active (server-synced, not a live read-only poll).
func refresh() -> void:
	var warn_text := ""
	var btn_text := "Open .mcp.json"
	var btn_tip := "Open .mcp.json in the system editor"
	var highlight := false
	if not MCPJsonSync.has_mcp_json():  # live file FACT — safe to show live
		warn_text = "⚠️ NO .mcp.json — the MCP client has nothing to connect with. Use the \"Write .mcp.json\" button below to create one from the bundled template."
		btn_text = "Write .mcp.json"
		btn_tip = "No .mcp.json found — write one from the bundled template"
		highlight = true
	elif MCPJsonSync.is_malformed():  # live file FACT — present but invalid JSON
		warn_text = "⚠️ .mcp.json isn't valid JSON — the MCP client can't read it, so it won't connect. Click \"Fix .mcp.json\" to repair it: overwrite with a clean template, or open the file to fix the JSON yourself."
		btn_text = "Fix .mcp.json"
		btn_tip = "Replace the malformed .mcp.json with a clean template (asks to confirm before overwriting)"
		highlight = true
	elif _read_only_active:  # cached, server-synced (NOT a live read-only poll)
		warn_text = "⚠️ READ-ONLY MODE — mutating tools are hidden. Remove GODOT_MCP_READ_ONLY from .mcp.json and reconnect the MCP client to restore full access."
		btn_text = "Open .mcp.json ⚠"
		btn_tip = "Open .mcp.json in the system editor (read-only mode active)"
		highlight = true
	# Warning panel (this PanelContainer; shared by all three states).
	visible = not warn_text.is_empty()
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


## Re-sync the cached read-only flag from .mcp.json, then refresh(). Called on
## startup, on server (re)connect, and after a dock write — NEVER on the timer:
## read-only takes effect server-side only when the MCP client relaunches the
## server (it reads GODOT_MCP_READ_ONLY from process.env once at startup), so
## polling would falsely show read-only before the server actually applies it.
func sync_read_only_state() -> void:
	_read_only_active = MCPJsonSync.has_mcp_json() and MCPJsonSync.is_read_only()
	refresh()


# ---------------------------------------------------------------------------
# Tri-mode button action (writes delegate to the shared write flow)
# ---------------------------------------------------------------------------


# Tri-mode footer button (label set by refresh()):
#   * present + valid   -> "Open"  : open .mcp.json in the system editor.
#   * missing           -> "Write" : shared write flow — a direct write (no file
#                                    to overwrite, so no confirm).
#   * present + invalid -> "Fix"   : shared write flow — the file EXISTS, so the
#                                    flow's overwrite-confirm fires before
#                                    replacing it with a clean template; a malformed
#                                    file is never silently clobbered (Cancel keeps
#                                    it for a manual fix).
# Re-checks state on press, so the action is always correct even if the label is
# momentarily stale.
func on_button_pressed() -> void:
	if MCPJsonSync.has_mcp_json() and not MCPJsonSync.is_malformed():
		OS.shell_open(MCPJsonSync.get_mcp_json_path())
	elif _write_flow != null:
		_write_flow.write(false, _on_mcp_json_write_result)


# Result sink this panel supplies to the shared write flow — maps the
# (ok, message, severity, tooltip) report straight onto a toast. `severity`
# already matches the _TOAST_* scale (0 info / 1 warning / 2 error). On success
# (e.g. a dock write of a missing file), re-sync the read-only + button state now
# so the dual-mode button flips "Write" -> "Open" immediately rather than on the
# next timer tick.
func _on_mcp_json_write_result(ok: bool, message: String, severity: int, tooltip: String) -> void:
	if _toast.is_valid():
		_toast.call(message, severity, tooltip)
	if ok:
		sync_read_only_state()
