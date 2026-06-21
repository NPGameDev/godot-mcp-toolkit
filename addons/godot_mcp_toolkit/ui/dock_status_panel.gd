@tool
extends VBoxContainer
## Dock "Server Status" sub-panel — the live server/runtime/LSP/activity labels.
##
## A dock sub-panel. Constructed and owned by dock.gd; added into the dock's
## status card (so the editor frees it with the dock). Builds its five status
## labels once and owns their update logic: listening address + peer count,
## runtime port (polled during playtests), LSP endpoint/conflict, and the
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

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const RegistryClient = _Hub.RegistryClient

# Server is read for every label (listening/port/peer/runtime/LSP); held so the
# refreshers can repaint without the dock re-passing it.
var _server: Node = null

# Status labels — built once in _init(), mutated by the refreshers below.
var _status_label: Label = null
var _peer_label: Label = null
var _activity_label: Label = null
var _runtime_label: Label = null
var _lsp_label: Label = null


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

	# The .mcp.json warning panel is inserted here (index 1) by the dock via
	# insert_warning_panel(), so it sits between the status row and the labels
	# below — the dock owns its behavior, this panel only hosts its placement.

	_runtime_label = Label.new()
	_runtime_label.text = "Runtime: not running"
	_runtime_label.add_theme_font_size_override("font_size", 13)
	add_child(_runtime_label)

	# GDScript LSP endpoint the server discovers for this editor (best-effort;
	# the server is authoritative for conflicts). See Fix 3, 41l-tertricies.
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


## Repaint every status label from current server/registry state. Called by the
## dock's _refresh_status fan-out (and indirectly the runtime/LSP refreshers it
## chains). Safe to call before the panel is in the tree — exits early on null.
func refresh() -> void:
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
	refresh_runtime()
	refresh_lsp()


## Repaint the runtime label from the playtest/runtime-port state. Called on the
## dock's 1s timer so it updates during playtests without server events.
func refresh_runtime() -> void:
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
