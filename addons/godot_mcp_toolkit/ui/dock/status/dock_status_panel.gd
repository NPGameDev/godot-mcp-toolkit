@tool
extends VBoxContainer
## Dock "Server Status" sub-panel — the live server/runtime/LSP/activity labels.
##
## A dock sub-panel. Constructed and owned by dock.gd; added into the dock's
## status card (so the editor frees it with the dock). Builds its status labels
## once and owns their update logic: listening address + source (or the
## not-listening warning state), peer count, runtime port (polled during
## playtests, with a not-reachable escalation), LSP endpoint/conflict, and the
## last-activity line. Reads the bound server for every value; mutates the
## existing labels on each refresh — never rebuilds them (it repaints on the
## dock's 1s timer and on every server event, so build-once matters).
##
## The DOCK keeps the orchestration: it routes server signals here for the label
## updates (refresh / refresh_runtime / refresh_lsp / set_peer_count /
## set_activity) while it owns the connect/disconnect toasts and the fan-out to
## the other sub-panels (.mcp.json + unfocused). The shared .mcp.json warning
## panel lives visually between the status row and the runtime label, so the dock
## parents it here via insert_warning_panel() — placement is this panel's, but the
## warning's behavior stays with the dock + the .mcp.json panel.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const RegistryClient = Modules.RegistryClient

# Shared label colors: amber for any warning state, gray for idle/informational.
const _WARN_COLOR := Color(1.0, 0.8, 0.2)
const _IDLE_COLOR := Color(0.6, 0.6, 0.6)
# How long a running playtest may go without a published runtime port before the
# runtime label escalates from "waiting" to "not reachable". Covers game boot +
# autoload bind + registry write, plus the pinned-port grace (~5 s) — the editor
# cannot see the child's bind failure directly (no IPC), so absence-after-grace
# is the cheap proxy.
const _RUNTIME_REACH_GRACE_MS := 10000

# Server is read for every label (listening/port/peer/runtime/LSP); held so the
# refreshers can repaint without the dock re-passing it.
var _server: Node = null

# Status labels — built once in _init(), mutated by the refreshers below.
var _status_label: Label = null
var _peer_label: Label = null
var _activity_label: Label = null
var _runtime_label: Label = null
var _lsp_label: Label = null
# Not-listening warning — a pinned-port conflict, an exhausted scan band, or a
# port-config error. Repainted by refresh() from the server's get_port_warning();
# hidden until active.
var _port_warning_label: Label = null
# First tick (ms) at which the current playtest was seen running — drives the
# runtime label's waiting→not-reachable escalation. -1 while no playtest runs.
var _playtest_seen_ms: int = -1


func _init(server: Node) -> void:
	_server = server

	var status_row := HBoxContainer.new()
	add_child(status_row)

	_status_label = Label.new()
	_status_label.text = "... starting"
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_status_label)

	_peer_label = Label.new()
	_peer_label.text = "0 peers"
	status_row.add_child(_peer_label)

	# Not-listening warning — placed just under the status row so a bind failure
	# (pinned port occupied, band exhausted, or a bad port env var) is visible
	# without scrolling.
	_port_warning_label = Label.new()
	_port_warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_port_warning_label.add_theme_color_override("font_color", Color(1.0, 0.6, 0.3))
	_port_warning_label.add_theme_font_size_override("font_size", 12)
	_port_warning_label.visible = false
	add_child(_port_warning_label)

	# The .mcp.json warning panel is inserted here (index 1) by the dock via
	# insert_warning_panel(), so it sits between the status row and the labels
	# below — the dock owns its behavior, this panel only hosts its placement.

	_runtime_label = Label.new()
	_runtime_label.text = "Runtime: not running"
	_runtime_label.add_theme_font_size_override("font_size", 13)
	add_child(_runtime_label)

	# GDScript LSP endpoint the server discovers for this editor (best-effort;
	# the server is authoritative for conflicts).
	_lsp_label = Label.new()
	_lsp_label.text = "LSP: —"
	_lsp_label.add_theme_font_size_override("font_size", 12)
	_lsp_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	add_child(_lsp_label)

	_activity_label = Label.new()
	_activity_label.text = "Last activity: —"
	_activity_label.add_theme_font_size_override("font_size", 12)
	_activity_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	add_child(_activity_label)


## Host the dock's shared .mcp.json warning panel between the status row and the
## runtime label (its original position). The dock creates + drives the panel;
## this method only places it (index 1) so the editor frees it with the dock.
func insert_warning_panel(panel: Control) -> void:
	add_child(panel)
	move_child(panel, 1)


# ---------------------------------------------------------------------------
# Refresh — status + peer + runtime + LSP (all read the server, mutate labels)
# ---------------------------------------------------------------------------


## Repaint every status label from current server/registry state — including the
## listening-vs-not style of the main status row and the not-listening warning
## (both derived from the server's live listen state, so any unbound phase shows).
## Idempotent repaint — cheap enough to run on every refresh trigger.
## Safe to call before the panel is in the tree — exits early on null.
func refresh() -> void:
	if _server == null or _status_label == null:
		return
	if _server.is_listening():
		var port: int = _server.get_bound_port()
		var source: String = _server.get_port_source()
		var source_suffix := " (%s)" % source if not source.is_empty() else ""
		_status_label.text = "Listening on 127.0.0.1:%d%s" % [port, source_suffix]
		_status_label.remove_theme_color_override("font_color")
	else:
		# Not listening — warning style, with the concise reason when one is known
		# (pinned port occupied / band exhausted / invalid config).
		var warning: Dictionary = _server.get_port_warning()
		if bool(warning.get("active", false)):
			_status_label.text = "Not listening — %s" % str(warning.get("label", ""))
		else:
			_status_label.text = "Not listening"
		_status_label.add_theme_color_override("font_color", _WARN_COLOR)
	_update_port_warning()
	var count: int = _server.get_authed_peer_count()
	_peer_label.text = "%d peer%s" % [count, "" if count == 1 else "s"]
	refresh_runtime()
	refresh_lsp()


## Repaint the runtime label from the playtest/runtime-port state. Called on the
## dock's 1s timer so it updates during playtests without server events. The
## editor cannot see the child game's bind failure (no IPC), so a playtest that
## runs past the grace with no published runtime port escalates to a "not
## reachable" warning steering to the game console (where the child's own
## push_error lands).
func refresh_runtime() -> void:
	if _runtime_label == null:
		return
	if EditorInterface.is_playing_scene():
		if _playtest_seen_ms < 0:
			_playtest_seen_ms = Time.get_ticks_msec()
		var rt_port := RegistryClient.get_runtime_port()
		if rt_port > 0:
			_runtime_label.text = "Runtime: listening on 127.0.0.1:%d" % rt_port
			_runtime_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
		elif Time.get_ticks_msec() - _playtest_seen_ms > _RUNTIME_REACH_GRACE_MS:
			_runtime_label.text = "Runtime: not reachable — check the game console"
			_runtime_label.add_theme_color_override("font_color", _WARN_COLOR)
		else:
			_runtime_label.text = "Runtime: game running, waiting for port..."
			_runtime_label.add_theme_color_override("font_color", _WARN_COLOR)
	else:
		_playtest_seen_ms = -1
		_runtime_label.text = "Runtime: not running (start playtest with F5)"
		_runtime_label.add_theme_color_override("font_color", _IDLE_COLOR)


## LSP status indicator. The MCP server reports the authoritative verdict
## (editor.set_lsp_status) — the editor can't read its own LSP bind status, and
## in-engine cross-process liveness is unreliable on Windows, so the dock renders
## what the server determined. Falls back to the configured (published) endpoint
## until an MCP server connects. The dock routes server.lsp_status_changed here.
func refresh_lsp() -> void:
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
# Targeted label updates — the dock routes specific server signals here so a
# connect/disconnect/command updates peer + activity without a full refresh
# (preserving today's signal-driven behavior). The dock keeps the toasts.
# ---------------------------------------------------------------------------


## Set the peer-count label (dock routes client_connected/disconnected here).
func set_peer_count(peer_count: int) -> void:
	if _peer_label != null:
		_peer_label.text = "%d peer%s" % [peer_count, "" if peer_count == 1 else "s"]


## Set the last-activity label (dock routes connect/disconnect/command here).
func set_activity(text: String) -> void:
	if _activity_label != null:
		_activity_label.text = text


# Show or hide the not-listening warning from the server's get_port_warning()
# result — a pinned-port conflict, an exhausted scan band, or a port-config
# error. Part of refresh() so the warning and the status-row style always derive
# from the same server state in the same pass.
func _update_port_warning() -> void:
	if _port_warning_label == null or _server == null:
		return
	var state: Dictionary = _server.get_port_warning()
	var active := bool(state.get("active", false))
	_port_warning_label.visible = active
	if active:
		_port_warning_label.text = "⚠️ " + str(state.get("message", ""))
