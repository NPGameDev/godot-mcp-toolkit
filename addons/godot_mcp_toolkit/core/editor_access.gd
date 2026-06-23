@tool
extends RefCounted
## Access layer to editor services, anchored on the stored EditorPlugin reference.
##
## Wraps the editor singletons (undo/redo, toaster, theme) the plugin needs so
## callers reach them through one place. Editor-only by design — only ever used
## from editor code via the hub const Modules.EditorAccess.

## Stores the EditorPlugin instance so that EditorUndoRedoManager is accessible
## on ALL Godot 4.x versions via plugin.get_undo_redo() — not just 4.4+ where
## EditorInterface.get_editor_undo_redo() was added.
static var _plugin: EditorPlugin


## Inject the EditorPlugin instance to enable editor-service access (pair with [method clear_plugin]).
static func set_plugin(plugin: EditorPlugin) -> void:
	_plugin = plugin


## Clear the stored plugin reference at teardown (pairs with [method set_plugin]).
static func clear_plugin() -> void:
	_plugin = null


## True once the plugin reference has been injected (editor context, plugin loaded).
static func has_plugin() -> bool:
	return _plugin != null


## Get EditorUndoRedoManager via the stored plugin reference.
## Returns the singleton on ALL Godot 4.x versions in editor context.
## Returns null only in headless mode (no plugin loaded).
static func get_undo_redo():
	if _plugin != null:
		return _plugin.get_undo_redo()
	return null


## Safely get EditorToaster via dynamic dispatch.
## The editor toaster is only available on Godot 4.4+, so guard the call and
## return null on earlier versions where the method doesn't exist.
static func get_toaster():
	if EditorInterface.has_method("get_editor_toaster"):
		return EditorInterface.call("get_editor_toaster")
	return null


## Get the editor Theme.
## EditorInterface.get_editor_theme() is bound on every supported version (4.2+),
## so no guard is needed.
static func get_editor_theme() -> Theme:
	return EditorInterface.get_editor_theme()
