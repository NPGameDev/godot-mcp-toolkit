@tool
extends PanelContainer
## Dock ".mcp.json health" sub-panel — the shared missing/malformed/read-only
## warning, the server-spec row, the write-or-open footer button, and the
## write/open flow.
##
## A dock sub-panel. Constructed and owned by dock.gd; this PanelContainer IS the
## shared warning panel and is added into the dock's status card (so the editor
## frees it with the dock). It owns the dock's .mcp.json UX cluster: the warning
## panel + label (built once here), the server-spec row (which server the file
## runs, and one button that switches the pin mode or brings a drifted entry back
## in line), the write-or-open footer button (built by the footer and injected, so
## the footer owns placement while this panel owns the button's meaning), the
## server-synced read-only cache, and the periodic file-validity poll. Writes
## delegate to the injected shared write flow (which owns the update-confirm and
## its "Open .mcp.json" recovery); this panel keeps only its result sink (toast +
## read-only re-sync).
##
## Two refresh triggers, deliberately distinct (preserves 68fb6eb's model):
##   * file VALIDITY/presence and the server spec are live FACTS — refreshed by the
##     dock's 1s timer fan-out (refresh(): Write-vs-Open button mode,
##     missing/malformed warning, the server-spec row).
##   * read-only is SERVER STATE — synced only on server (re)connect + startup +
##     after a dock write (sync_read_only_state()), NEVER on the timer: the server
##     reads GODOT_MCP_READ_ONLY once at launch, so a live poll would claim
##     read-only before the server actually applies it.
## Both refresh paths MUTATE the nodes built in _init(); they never recreate
## nodes. Toasts go through an injected Callable so the panel never touches the
## dock's private toaster.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const MCPJsonSync = Modules.MCPJsonSync
const ServerPinPolicy = Modules.ServerPinPolicy
const VersionUtils = Modules.VersionUtils
const DockThemeOverride = Modules.DockThemeOverride
const MCPJsonWriteFlow := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_write_flow.gd")

# Toast severity constants (match EditorToaster.Severity / the dock's _TOAST_*).
const _TOAST_INFO := 0
const _TOAST_WARNING := 1
const _TOAST_ERROR := 2

# Text colours: amber for a state that wants the user's attention, grey for one
# that only states a fact.
const _AMBER := Color(1.0, 0.8, 0.2)
const _GREY := Color(0.7, 0.7, 0.7)

# What the server-spec row's button does: switch the project to the latest server,
# pin it to the compatible version, or rewrite the entry to the desired spec
# without touching the project setting.
const _ACTION_USE_LATEST := "use_latest"
const _ACTION_PIN := "pin"
const _ACTION_UPDATE := "update"
const _ACTION_RESTORE := "restore"

# Write-or-open footer button — built + placed by the footer (dock owns placement),
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

# The server-spec row: its label, and the button the harness and users press
# (named PinModeButton). Shown whenever the file has a server entry to describe.
var _pin_row: HBoxContainer = null
var _pin_label: Label = null
var _pin_btn: Button = null
# What the row's button does and the spec it names, both set by refresh().
var _pin_action: String = ""
var _pin_target: String = ""

# This panel's backgrounds: the warning box, or none while only the row shows.
var _warning_style: StyleBoxFlat = null
var _plain_style: StyleBoxEmpty = null

# Cached read-only state — synced from .mcp.json on server (re)connect + startup,
# NOT on the timer: the server reads GODOT_MCP_READ_ONLY from process.env once at
# its launch and never re-checks, so a live poll would claim read-only is active
# before the server applies it (a client→server relaunch is what takes effect).
var _read_only_active: bool = false

# The spec this machine last wrote (MCPJsonWriteFlow.read_last_written_spec),
# cached because Godot 4.2 reloads the editor's project metadata file on every
# read. Re-read when the file's spec or the desired spec moves away from
# _record_basis ([on_disk, desired] at the last read: any surface's write, a hand
# edit or a setting change), and on every read-only sync, which follows a dock
# write; an empty basis forces the next read. A missed re-read is harmless: a
# write always lands the entry on the desired spec, where the row never reads
# the record.
var _last_written_spec: String = ""
var _record_basis: Array = []


func _init(mcp_json_button: Button, toast: Callable, write_flow: MCPJsonWriteFlow) -> void:
	_mcp_json_btn = mcp_json_button
	_toast = toast
	_write_flow = write_flow

	# This PanelContainer is the shared warning panel — styles + nodes built once;
	# text/visibility are mutated per-state by refresh()/sync_read_only_state().
	_warning_style = StyleBoxFlat.new()
	_warning_style.bg_color = Color(0.35, 0.22, 0.0)
	_warning_style.corner_radius_top_left = 4
	_warning_style.corner_radius_top_right = 4
	_warning_style.corner_radius_bottom_left = 4
	_warning_style.corner_radius_bottom_right = 4
	_warning_style.content_margin_left = 8
	_warning_style.content_margin_right = 8
	_warning_style.content_margin_top = 6
	_warning_style.content_margin_bottom = 6
	_plain_style = StyleBoxEmpty.new()
	add_theme_stylebox_override("panel", _warning_style)
	visible = false

	var content := VBoxContainer.new()
	add_child(content)

	_warning_label = Label.new()
	_warning_label.text = ""
	_warning_label.visible = false
	_warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_warning_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	_warning_label.add_theme_font_size_override("font_size", 12)
	content.add_child(_warning_label)

	_pin_row = HBoxContainer.new()
	_pin_row.visible = false
	content.add_child(_pin_row)
	_pin_label = Label.new()
	_pin_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pin_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pin_label.add_theme_font_size_override("font_size", 12)
	_pin_row.add_child(_pin_label)
	_pin_btn = Button.new()
	_pin_btn.name = "PinModeButton"
	_pin_btn.pressed.connect(_on_pin_button_pressed)
	_pin_row.add_child(_pin_btn)

	# Bind the injected footer button to this panel's write-or-open action. Its initial
	# label/tooltip/colour are placeholders; refresh() owns them from here on.
	if _mcp_json_btn != null:
		_mcp_json_btn.text = "Open .mcp.json"
		_mcp_json_btn.tooltip_text = "Open .mcp.json in the system editor"
		_mcp_json_btn.pressed.connect(on_button_pressed)


# ---------------------------------------------------------------------------
# Refresh — file validity (dock-timer-driven FACT) + read-only (server-synced)
# ---------------------------------------------------------------------------


## Recompute the missing/malformed/read-only/normal state and repaint BOTH the
## warning panel and the write-or-open button from it — the one place that state
## machine lives (DRY) — then the server-spec row. MUTATES the existing nodes only;
## never recreates them. Safe on the 1s timer: file presence, malformed and the
## server spec are live FACTs; read-only uses the cached _read_only_active
## (server-synced, not a live read-only poll).
func refresh() -> void:
	var warn_text := ""
	var btn_text := "Open .mcp.json"
	var btn_tip := "Open .mcp.json in the system editor"
	var highlight := false
	var readable := false
	# One parse per tick serves the presence, validity and server-spec checks.
	var file_state := MCPJsonSync.read_file_state()
	if not bool(file_state["present"]):  # live file FACT — safe to show live
		warn_text = "⚠️ NO .mcp.json — the MCP client has nothing to connect with. Use the \"Write .mcp.json\" button below to create one from the bundled template."
		btn_text = "Write .mcp.json"
		btn_tip = "No .mcp.json found — write one from the bundled template"
		highlight = true
	elif bool(file_state["malformed"]):  # live file FACT — present but invalid JSON
		warn_text = "⚠️ .mcp.json isn't valid JSON, or its mcpServers isn't an object — the MCP client can't read it, so it won't connect. Open it to fix it, or delete it and click Write."
		btn_tip = "Open .mcp.json in the system editor to fix the JSON (or delete it, then write a new one)"
		highlight = true
	else:
		readable = true
		if _read_only_active:  # cached, server-synced (NOT a live read-only poll)
			warn_text = "⚠️ READ-ONLY MODE — mutating tools are hidden. Remove GODOT_MCP_READ_ONLY from .mcp.json and reconnect the MCP client to restore full access."
			btn_text = "Open .mcp.json ⚠"
			btn_tip = "Open .mcp.json in the system editor (read-only mode active)"
			highlight = true
	# Warning text (shared by all three states).
	var has_warning := not warn_text.is_empty()
	if _warning_label != null:
		_warning_label.visible = has_warning
		if has_warning:
			_warning_label.text = warn_text
	_refresh_pin_row(readable, str(file_state["spec"]))
	# This panel shows for a warning or for the row alone; only a warning gets the box.
	visible = has_warning or (_pin_row != null and _pin_row.visible)
	DockThemeOverride.set_stylebox(self, "panel", _warning_style if has_warning else _plain_style)
	# Write-or-open button (shared amber highlight).
	if _mcp_json_btn != null:
		_mcp_json_btn.text = btn_text
		_mcp_json_btn.tooltip_text = btn_tip
		if highlight:
			DockThemeOverride.set_color(_mcp_json_btn, "font_color", _AMBER)
		else:
			DockThemeOverride.clear_color(_mcp_json_btn, "font_color")


## Re-sync the cached read-only flag from .mcp.json, then refresh(). Called on
## startup, on server (re)connect, and after a dock write — NEVER on the timer:
## read-only takes effect server-side only when the MCP client relaunches the
## server (it reads GODOT_MCP_READ_ONLY from process.env once at startup), so
## polling would falsely show read-only before the server actually applies it.
func sync_read_only_state() -> void:
	_read_only_active = MCPJsonSync.has_mcp_json() and MCPJsonSync.is_read_only()
	_record_basis = []
	refresh()


## The cached read-only state the badge shows (synced by
## [method sync_read_only_state]), not what [code].mcp.json[/code] says now. The
## Info dialog reads it through the dialog presenter so the two always agree.
func is_read_only_active() -> bool:
	return _read_only_active


## The server-spec row's content for the file's spec [param on_disk], the spec this
## machine last wrote [param last_written] ("" for none), the spec a write would
## produce [param desired] (see [code]ServerPinPolicy.desired_classification[/code]),
## the project's [param version_setting] and the [param compatible] server version.
## Pure. Returns {text, button, action, target, amber}: the label, the button's
## caption ("" hides it), what it does, the spec it names, and whether the state
## wants attention.
static func pin_row_state(
		on_disk: String, last_written: String, desired: String,
		version_setting: String, compatible: String) -> Dictionary:
	var state := {"text": "", "button": "", "action": "", "target": "", "amber": false}
	if desired.begins_with(ServerPinPolicy.SPEC_LOCAL_PREFIX):
		state["text"] = "Server: local build (%s)" % desired.substr(ServerPinPolicy.SPEC_LOCAL_PREFIX.length())
		if not ServerPinPolicy.same_spec(on_disk, desired):
			state["text"] += " not in .mcp.json yet: use Write .mcp.json"
			state["amber"] = true
		return state
	var pin_text := "Pin to %s" % compatible
	var nudge := ServerPinPolicy.nudge_state(on_disk, last_written, desired)
	var mode := ServerPinPolicy.pin_mode(version_setting)
	if nudge == ServerPinPolicy.NUDGE_UNPINNED and mode == ServerPinPolicy.MODE_PINNED:
		state["text"] = ("Server: unpinned — it downloads every new release. Pin it to %s, "
			+ "the version this toolkit was tested with.") % compatible
		_set_button(state, pin_text, _ACTION_PIN, compatible)
		state["amber"] = true
	elif nudge == ServerPinPolicy.NUDGE_DIFFERS or nudge == ServerPinPolicy.NUDGE_UNPINNED:
		# An unpinned entry under an exact Custom version is brought to that version;
		# offering the compatible pin would clear the team's setting.
		var wanted := _spec_label(desired)
		state["text"] = ".mcp.json runs server %s; this project wants %s." % [_spec_label(on_disk), wanted]
		_set_button(state, "Update to %s" % wanted, _ACTION_UPDATE, wanted)
		state["amber"] = true
	elif nudge == ServerPinPolicy.NUDGE_FOREIGN:
		var recommended := _spec_label(desired)
		state["text"] = "Server spec set by hand (%s)." % _spec_label(on_disk)
		_set_button(state, "Restore recommended (%s)" % recommended, _ACTION_RESTORE, recommended)
	elif mode == ServerPinPolicy.MODE_PINNED:
		state["text"] = "Server: %s (pinned)" % compatible
		_set_button(state, "Use latest", _ACTION_USE_LATEST, ServerPinPolicy.LATEST_SETTING_VALUE)
	elif mode == ServerPinPolicy.MODE_LATEST:
		state["text"] = "Server: latest (updates on every launch)"
		_set_button(state, pin_text, _ACTION_PIN, compatible)
	else:
		state["text"] = "Server: %s (custom, Project Settings)" % version_setting.strip_edges()
		_set_button(state, pin_text, _ACTION_PIN, compatible)
	return state


static func _set_button(state: Dictionary, caption: String, action: String, target: String) -> void:
	state["button"] = caption
	state["action"] = action
	state["target"] = target


# A classification as the row names it: the version part of an npx spec, "latest"
# for the unversioned form npx resolves alike, "local build" for a node path.
static func _spec_label(spec: String) -> String:
	if spec.begins_with(ServerPinPolicy.SPEC_NPX_PREFIX):
		return spec.substr(ServerPinPolicy.SPEC_NPX_PREFIX.length())
	if spec == ServerPinPolicy.SPEC_NPX_BARE:
		return ServerPinPolicy.LATEST_SETTING_VALUE
	if spec.begins_with(ServerPinPolicy.SPEC_LOCAL_PREFIX):
		return "local build"
	return spec


# Repaints the server-spec row from the file's spec on_disk, this machine's
# record and settings, and the project setting. Hidden while the file is missing
# or unreadable (the warning owns those states) or has no toolkit entry, unless
# a local build is wanted, which the row then says is not in the file yet.
func _refresh_pin_row(readable: bool, on_disk: String) -> void:
	if _pin_row == null:
		return
	var desired := MCPJsonSync.get_desired_spec(MCPJsonWriteFlow.read_local_path_setting())
	var wants_local := desired.begins_with(ServerPinPolicy.SPEC_LOCAL_PREFIX)
	_pin_row.visible = readable and (on_disk != ServerPinPolicy.SPEC_UNKNOWN or wants_local)
	if not _pin_row.visible:
		return
	var basis := [on_disk, desired]
	if basis != _record_basis:
		_last_written_spec = MCPJsonWriteFlow.read_last_written_spec()
		_record_basis = basis
	var state := pin_row_state(
			on_disk, _last_written_spec, desired,
			ServerPinPolicy.read_version_setting(),
			VersionUtils.COMPATIBLE_SERVER_VERSION)
	_pin_label.text = str(state["text"])
	DockThemeOverride.set_color(_pin_label, "font_color", _AMBER if bool(state["amber"]) else _GREY)
	_pin_action = str(state["action"])
	_pin_target = str(state["target"])
	_pin_btn.text = str(state["button"])
	_pin_btn.visible = not _pin_btn.text.is_empty()


# ---------------------------------------------------------------------------
# Write-or-open button action (writes delegate to the shared write flow)
# ---------------------------------------------------------------------------


# Footer button (label set by refresh()):
#   * present (valid or not) -> "Open"  : open .mcp.json in the system editor; a
#                                         malformed file is never rewritten, the
#                                         user fixes or deletes it.
#   * missing                -> "Write" : shared write flow — a direct write (no
#                                         file, so no confirm).
# Re-checks state on press, so the action is always correct even if the label is
# momentarily stale.
func on_button_pressed() -> void:
	if MCPJsonSync.has_mcp_json():
		OS.shell_open(MCPJsonSync.get_mcp_json_path())
	elif _write_flow != null:
		_write_flow.write(false, _on_mcp_json_write_result)


# The server-spec row's button. A mode switch saves the project setting first
# (the mode is a team-shared project choice), then every action rewrites the entry
# through the shared flow, which confirms before changing it.
func _on_pin_button_pressed() -> void:
	if _write_flow == null:
		return
	var question := ""
	match _pin_action:
		_ACTION_USE_LATEST:
			ServerPinPolicy.save_version_setting(ServerPinPolicy.LATEST_SETTING_VALUE)
			question = "Use the latest server"
		_ACTION_PIN:
			ServerPinPolicy.save_version_setting("")
			question = "Pin the server to %s" % _pin_target
		_ACTION_UPDATE:
			question = "Update the server to %s" % _pin_target
		_ACTION_RESTORE:
			question = "Restore the recommended server (%s)" % _pin_target
		_:
			return
	var body := ("%s in .mcp.json?\n\nOnly the %s entry changes; other servers and your env keys are kept.\n"
		+ "Restart your MCP client afterwards — the first launch after a version change downloads the server.") % [
			question, MCPJsonSync.get_own_entry_key()]
	_write_flow.write(false, _on_mcp_json_write_result, body)


# Result sink this panel supplies to the shared write flow — maps the
# (ok, message, severity, tooltip) report straight onto a toast. `severity`
# already matches the _TOAST_* scale (0 info / 1 warning / 2 error). On success
# (e.g. a dock write of a missing file), re-sync the read-only + button state now
# so the write-or-open button flips "Write" -> "Open" immediately rather than on the
# next timer tick.
func _on_mcp_json_write_result(ok: bool, message: String, severity: int, tooltip: String) -> void:
	if _toast.is_valid():
		_toast.call(message, severity, tooltip)
	if ok:
		sync_read_only_state()
