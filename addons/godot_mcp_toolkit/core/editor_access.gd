@tool
extends RefCounted
## Access layer to editor services, anchored on the stored EditorPlugin reference.
##
## Wraps the editor singletons (undo/redo, toaster, theme) and the main-screen switch
## the plugin needs so callers reach them through one place. Editor-only by design — only ever used
## from editor code via the hub const Modules.EditorAccess.

# The theme variation the editor gives its main-screen tab buttons.
const _MAIN_SCREEN_BUTTON_VARIATION := &"MainScreenButton"

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


## Switches the editor to the main screen named [param screen_name], the title of
## its tab in the editor's top bar.
##
## The switch is asked for only when such a tab exists and is visible, because
## [method EditorInterface.set_main_screen_editor] reports an unknown name as an
## engine error. Returns [code]true[/code] when that screen is now shown: it already
## was, or [signal EditorPlugin.main_screen_changed] named it during the switch.
## Returns [code]false[/code] before [method set_plugin], when there is no such
## visible tab, or when the editor did not confirm the switch.
##
## The tab is found by the [code]"MainScreenButton"[/code] theme variation, which
## the editor gives its main-screen tabs from Godot 4.3 on. On 4.2 no tab carries
## it, so this always returns [code]false[/code] there.
static func select_main_screen(screen_name: String) -> bool:
	if _plugin == null:
		return false
	var tab_button := _find_main_screen_button(screen_name)
	if tab_button == null:
		return false
	if tab_button.button_pressed:
		return true
	var switched := [false]
	var on_screen_changed := func(changed_name: String) -> void:
		if changed_name == screen_name:
			switched[0] = true
	_plugin.main_screen_changed.connect(on_screen_changed)
	EditorInterface.set_main_screen_editor(screen_name)
	_plugin.main_screen_changed.disconnect(on_screen_changed)
	return switched[0]


# The editor's visible main-screen tab button titled screen_name, or null. The
# button text is the main-screen plugin's untranslated name, which is also what
# set_main_screen_editor matches, so the lookup holds in a translated editor. The
# theme variation exists from Godot 4.3, so on 4.2 this finds nothing.
static func _find_main_screen_button(screen_name: String) -> Button:
	var base := EditorInterface.get_base_control()
	if base == null:
		return null
	for node in base.find_children("*", "Button", true, false):
		var button: Button = node
		if (button.text == screen_name and button.visible
				and button.theme_type_variation == _MAIN_SCREEN_BUTTON_VARIATION):
			return button
	return null
