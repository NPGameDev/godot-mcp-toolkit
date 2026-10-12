@tool
extends RefCounted
## Presenter for the toolkit's two editor-global dialogs — Info / Help and the
## extension catalog.
##
## Editor-global means the dialogs parent to the editor base control, not to the
## dock: they are reachable from any surface (dock footer, Tools menu, onboarding
## wizard), so their creation, reuse, and teardown belong to this shared
## presenter, not to the dock — the dock is a UI surface, not a service locator.
## Each dialog is created on first show and reused afterwards (a reopened dialog
## keeps its window state); the owner must call [method dispose] during teardown.
##
## Editor-only: names EditorInterface, so this script must never enter the
## runtime autoload's preload closure.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const MCPJsonSync = Modules.MCPJsonSync
const InfoDialog := preload("res://addons/godot_mcp_toolkit/ui/dock/ext/info_dialog.gd")
const ExtensionCatalogDialog := preload("res://addons/godot_mcp_toolkit/ui/dock/ext/extension_catalog_dialog.gd")

# Created on first show, reused across shows; freed by dispose().
var _info_dialog: InfoDialog = null
var _catalog_dialog: ExtensionCatalogDialog = null

# Returns whether the running MCP server applies read-only mode, the state the
# dock's read-only badge shows. Set by the dock; invalid when no dock is bound.
var _read_only_source: Callable = Callable()


## Set where [method show_info] reads the read-only state the MCP server
## applies: a no-argument [Callable] returning [code]bool[/code]. The dock passes
## its badge's cached state, so the dialog and the badge always agree.
func set_read_only_source(source: Callable) -> void:
	_read_only_source = source


## Show the Info / Help dialog, re-reading live state from [param server] (the
## bound MCP server node) on every call. The read-only state comes from the
## source the dock set, or, with no dock, from [code].mcp.json[/code] the way
## the badge reads it.
func show_info(server: Node) -> void:
	if _info_dialog == null or not is_instance_valid(_info_dialog):
		_info_dialog = InfoDialog.new()
		EditorInterface.get_base_control().add_child(_info_dialog)
	_info_dialog.show_info(server, _read_only_applied())


# The read-only state the running MCP server applies, as the badge shows it.
func _read_only_applied() -> bool:
	if _read_only_source.is_valid():
		return bool(_read_only_source.call())
	return MCPJsonSync.has_mcp_json() and MCPJsonSync.is_read_only()


## Show the extension catalog dialog.
func show_extension_catalog() -> void:
	if _catalog_dialog == null or not is_instance_valid(_catalog_dialog):
		_catalog_dialog = ExtensionCatalogDialog.new()
		EditorInterface.get_base_control().add_child(_catalog_dialog)
	_catalog_dialog.show_catalog()


## Free both dialogs and drop the references. Must run during the plugin's
## synchronous teardown, and must free immediately (never queue_free): the
## dialogs are base-control children nothing else frees, and a deferred free at
## process exit may not flush before ObjectDB's exit-time leak check runs.
func dispose() -> void:
	for dialog in [_info_dialog, _catalog_dialog]:
		if dialog != null and is_instance_valid(dialog):
			dialog.free()
	_info_dialog = null
	_catalog_dialog = null
