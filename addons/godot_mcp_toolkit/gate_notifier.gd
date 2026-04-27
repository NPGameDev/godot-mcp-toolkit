@tool
extends RefCounted
## Broadcasts config_reloaded to the MCP server and shows gate-toggle
## toasts via EditorToaster.  Dock-independent — works even when the
## dock panel is hidden or the user is toggling from PS Inspector.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPFeatureRegistry = _Hub.MCPFeatureRegistry
const MCPStateFile = _Hub.MCPStateFile

const INFO := 0
const WARNING := 1

var _server: Node = null
var _events: RefCounted = null
var _wizard_active: bool = false
var _broadcast_pending := false


func bind(server: Node, events: RefCounted) -> void:
	_server = server
	_events = events
	if _events != null:
		_events.config_reloaded.connect(broadcast_config_reloaded)


func broadcast_config_reloaded() -> void:
	if _broadcast_pending:
		return
	_broadcast_pending = true
	_deferred_broadcast.call_deferred()


func _deferred_broadcast() -> void:
	_broadcast_pending = false
	if _server == null:
		return
	var profile: int = ProjectSettings.get_setting(
		"mcp_toolkit/feature_gates/profile", MCPFeatureRegistry.PROFILE_STANDARD)
	var profile_str: String
	match profile:
		MCPFeatureRegistry.PROFILE_MINIMAL: profile_str = "minimal"
		MCPFeatureRegistry.PROFILE_POWER_USER: profile_str = "power_user"
		_: profile_str = "standard"
	var sidecar := MCPStateFile.read()
	var gates: Dictionary = sidecar.get("gates", {})
	if gates.is_empty():
		# Fallback: build from PS bools if sidecar not yet populated.
		gates = MCPStateFile.gates_from_ps()
	_server.broadcast_notification("config_reloaded", {
		"profile": profile_str,
		"gates": gates,
	})
	if _wizard_active:
		return
	if _server.get_authed_peer_count() > 0:
		_show_toast("Config sent to MCP server. If tools appear stale, re-run ToolSearch or /mcp.")
	else:
		_show_toast("Gate config updated.")


func _show_toast(msg: String, severity: int = INFO) -> void:
	if not Engine.is_editor_hint():
		return
	if severity >= WARNING:
		push_warning("[MCP] %s" % msg)
	else:
		print("[MCP] %s" % msg)
