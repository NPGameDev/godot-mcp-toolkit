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

const InfoDialog := preload("res://addons/godot_mcp_toolkit/ui/dock/ext/info_dialog.gd")
const ExtensionCatalogDialog := preload("res://addons/godot_mcp_toolkit/ui/dock/ext/extension_catalog_dialog.gd")

# Created on first show, reused across shows; freed by dispose().
var _info_dialog: InfoDialog = null
var _catalog_dialog: ExtensionCatalogDialog = null


## Show the Info / Help dialog, re-reading live state from [param server] (the
## bound MCP server node) on every call.
func show_info(server: Node) -> void:
	if _info_dialog == null or not is_instance_valid(_info_dialog):
		_info_dialog = InfoDialog.new()
		EditorInterface.get_base_control().add_child(_info_dialog)
	_info_dialog.show_info(server)


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
