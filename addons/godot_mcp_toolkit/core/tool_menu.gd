@tool
extends RefCounted
## Owns the Tools > MCP Toolkit submenu + command-palette surface and routes its
## actions.
##
## Builds the data-driven submenu and the matching command-palette commands from
## one _ACTIONS table, then routes each chosen action to its collaborator: the
## server (token regen), the dock (audit log — a dock section), the shared write
## flow (.mcp.json), the dialog presenter (extension catalog), or the editor
## settings (open Project Settings). Constructed by the orchestrator (plugin.gd)
## with the collaborators its actions need; install() during _enter_tree,
## uninstall() during _exit_tree.
##
## Editor-only: names EditorInterface (command palette) and the EditorPlugin host,
## so it is constructed by the editor-only plugin.gd and never reached by the
## runtime autoload.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const SettingsNavigator := preload("res://addons/godot_mcp_toolkit/ui/settings_navigator.gd")
const MCPJsonWriteFlow := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_write_flow.gd")
const ToolkitDialogPresenter := preload("res://addons/godot_mcp_toolkit/ui/toolkit_dialog_presenter.gd")

# Toast severity for a failed write (matches EditorToaster.Severity / the
# write flow's result scale: 0 info / 1 warning / 2 error).
const _TOAST_WARNING := 1

# Data-driven menu / command-palette registration.
# "label" is the command-palette name (prefixed for discoverability);
# "menu_label" is the short name shown inside the Tools > MCP Toolkit submenu.
const _ACTIONS := [
	{"label": "MCP Toolkit: Regenerate Token", "menu_label": "Regenerate Token", "key": "mcp/regenerate_token", "method": "_on_regen_token"},
	{"label": "MCP Toolkit: Show Audit Log", "menu_label": "Show Audit Log", "key": "mcp/show_audit_log", "method": "_on_show_audit"},
	{"label": "MCP Toolkit: Open Project Settings", "menu_label": "Open Project Settings", "key": "mcp/open_settings", "method": "_on_open_settings"},
	{"label": "MCP Toolkit: Write .mcp.json", "menu_label": "Write .mcp.json", "key": "mcp/write_mcp_json", "method": "_on_write_mcp_json"},
	{"label": "MCP Toolkit: Extension Catalog", "menu_label": "Extension Catalog...", "key": "mcp/extension_catalog", "method": "_on_extension_catalog"},
]

var _plugin: EditorPlugin = null
var _server: Node = null
# Kept for the audit-log action only — the audit viewer is a dock section, so the
# dock stays its owner; every other action routes to an injected collaborator.
var _dock: Control = null
var _write_flow: MCPJsonWriteFlow = null
var _dialog_presenter: ToolkitDialogPresenter = null
var _tool_submenu: PopupMenu = null


func _init(
		plugin: EditorPlugin, server: Node, dock: Control,
		write_flow: MCPJsonWriteFlow, dialog_presenter: ToolkitDialogPresenter) -> void:
	_plugin = plugin
	_server = server
	_dock = dock
	_write_flow = write_flow
	_dialog_presenter = dialog_presenter


# -- Menu registration ---------------------------------------------------------


func install() -> void:
	# Tools > MCP Toolkit submenu.
	_tool_submenu = PopupMenu.new()
	_tool_submenu.name = "MCPToolkitMenu"
	for i in _ACTIONS.size():
		_tool_submenu.add_item(_ACTIONS[i]["menu_label"], i)
	_tool_submenu.id_pressed.connect(_on_submenu_id_pressed)
	_plugin.add_tool_submenu_item("MCP Toolkit", _tool_submenu)
	# -- Command Palette (4.0+; guard anyway for safety) --
	if EditorInterface.has_method("get_command_palette"):
		var palette = EditorInterface.call("get_command_palette")
		if palette != null:
			for action in _ACTIONS:
				palette.add_command(
					action["label"], action["key"],
					Callable(self, action["method"]))


func uninstall() -> void:
	# Command Palette.
	if EditorInterface.has_method("get_command_palette"):
		var palette = EditorInterface.call("get_command_palette")
		if palette != null:
			for action in _ACTIONS:
				palette.remove_command(action["key"])
	# Submenu — immediate free(), not queue_free(): uninstall runs on the plugin's
	# _exit_tree teardown path, and a deferred delete would hold the submenu's
	# id_pressed connection (and this instance's preload chain) past ObjectDB's
	# exit-time leak check → spurious "resources still in use at exit". The submenu
	# was removed from the menu above, so nothing is iterating it.
	_plugin.remove_tool_menu_item("MCP Toolkit")
	if _tool_submenu != null and is_instance_valid(_tool_submenu):
		_tool_submenu.free()
	_tool_submenu = null


# -- Submenu router ------------------------------------------------------------


func _on_submenu_id_pressed(id: int) -> void:
	if id >= 0 and id < _ACTIONS.size():
		Callable(self, _ACTIONS[id]["method"]).call()


# -- Menu handlers -------------------------------------------------------------


func _on_regen_token() -> void:
	if _server != null:
		_server.regenerate_token()
		print("[MCP] Token rotated")
		var toaster = Modules.EditorAccess.get_toaster()
		if toaster != null:
			toaster.push_toast("MCP token rotated", 0)


func _on_show_audit() -> void:
	if _dock != null:
		_dock.show_audit_dialog()
	else:
		var global_path := ProjectSettings.globalize_path(Modules.Audit.get_log_path())
		OS.shell_open(global_path)


func _on_open_settings() -> void:
	SettingsNavigator.open_mcp_settings()


func _on_write_mcp_json() -> void:
	if _write_flow != null:
		_write_flow.write(false, _on_write_mcp_json_result)


# The menu's own feedback sink for the shared write flow — a Tools-menu write
# does not involve the dock panel, so the menu toasts (and console-logs) the
# outcome itself.
func _on_write_mcp_json_result(_ok: bool, message: String, severity: int, tooltip: String) -> void:
	if severity >= _TOAST_WARNING:
		push_warning("[MCP] %s" % message)
	else:
		print("[MCP] %s" % message)
	var toaster = Modules.EditorAccess.get_toaster()
	if toaster != null:
		toaster.push_toast(message, severity, tooltip)


func _on_extension_catalog() -> void:
	if _dialog_presenter != null:
		_dialog_presenter.show_extension_catalog()
