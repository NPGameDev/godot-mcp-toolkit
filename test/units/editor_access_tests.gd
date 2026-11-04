@tool
extends RefCounted
## Unit tests for finding a main screen in the editor's two shapes: tab buttons on
## Godot 4.2-4.7, docks on 4.8. A stand-in takes the place of the EditorInterface
## singleton in each; the switch itself needs a real editor, so the QA run covers it.

const EditorAccess := preload("res://addons/godot_mcp_toolkit/core/editor_access.gd")

const _SCREEN := "Asset Store"
const _BUTTON_VARIATION := &"MainScreenButton"
const _TABS_VARIATION := &"MainScreenContainer"


## run() is a coroutine: the runner's root joins the tree only after a frame, so the
## runner must [code]await[/code] it. [param tree] is the runner itself.
static func run(testing, tree: SceneTree) -> void:
	await tree.process_frame
	_test_tab_button_states(testing)
	_test_tab_button_absent(testing)
	_test_dock_states(testing, tree)
	_test_dock_missing(testing)
	_test_dock_outside_the_main_screen_tabs(testing, tree)


static func _test_tab_button_states(testing) -> void:
	testing.begin("Main screen, tab buttons: the pressed state tells shown from available")
	var base := _make_base(_SCREEN, _BUTTON_VARIATION)
	var interface := _TabButtonsInterface.new(base)
	testing.eq(EditorAccess.main_screen_state(interface, _SCREEN),
			EditorAccess.MainScreenState.AVAILABLE, "an unpressed tab is available")
	(base.get_child(0) as Button).button_pressed = true
	testing.eq(EditorAccess.main_screen_state(interface, _SCREEN),
			EditorAccess.MainScreenState.SHOWN, "a pressed tab is shown")
	base.free()


static func _test_tab_button_absent(testing) -> void:
	testing.begin("Main screen, tab buttons: no matching visible tab is absent")
	var base := _make_base(_SCREEN, _BUTTON_VARIATION)
	var interface := _TabButtonsInterface.new(base)
	testing.eq(EditorAccess.main_screen_state(interface, "Other"),
			EditorAccess.MainScreenState.ABSENT, "another title is absent")
	(base.get_child(0) as Button).visible = false
	testing.eq(EditorAccess.main_screen_state(interface, _SCREEN),
			EditorAccess.MainScreenState.ABSENT, "a hidden tab is absent")
	base.free()

	var unmarked := _make_base(_SCREEN, &"")
	testing.eq(EditorAccess.main_screen_state(_TabButtonsInterface.new(unmarked), _SCREEN),
			EditorAccess.MainScreenState.ABSENT,
			"a button without the theme variation is absent, as every tab is on Godot 4.2")
	unmarked.free()

	testing.eq(EditorAccess.main_screen_state(_TabButtonsInterface.new(null), _SCREEN),
			EditorAccess.MainScreenState.ABSENT, "no base control is absent")


# The base holds no button with the variation, as on Godot 4.8: a lookup that reads
# only the tab buttons reports the screen absent here, and the badge opens the browser.
static func _test_dock_states(testing, tree: SceneTree) -> void:
	testing.begin("Main screen, docks: a dock in the main-screen tabs is found")
	var base := _make_base(_SCREEN, &"")
	var tabs := Control.new()
	tabs.theme_type_variation = _TABS_VARIATION
	var dock := Control.new()
	tabs.add_child(dock)
	tree.root.add_child(tabs)
	var interface := _DocksInterface.new(base, dock)
	dock.visible = false
	testing.eq(EditorAccess.main_screen_state(interface, _SCREEN),
			EditorAccess.MainScreenState.AVAILABLE, "a dock behind another tab is available")
	dock.visible = true
	testing.eq(EditorAccess.main_screen_state(interface, _SCREEN),
			EditorAccess.MainScreenState.SHOWN, "the dock on show is shown")
	tree.root.remove_child(tabs)
	tabs.free()
	base.free()


static func _test_dock_missing(testing) -> void:
	testing.begin("Main screen, docks: no dock of that title is absent")
	var base := _make_base(_SCREEN, &"")
	testing.eq(EditorAccess.main_screen_state(_DocksInterface.new(base, null), _SCREEN),
			EditorAccess.MainScreenState.ABSENT, "the lookup finds nothing")
	base.free()


# set_main_screen_editor reads only the main-screen tabs, so any other home would make
# it report an engine error. The dock stays visible where it can, to show that
# visibility alone does not count it as shown.
static func _test_dock_outside_the_main_screen_tabs(testing, tree: SceneTree) -> void:
	testing.begin("Main screen, docks: a dock outside the main-screen tabs is absent")
	var base := _make_base(_SCREEN, &"")
	var closed_parent := Control.new()
	closed_parent.visible = false
	var closed_dock := Control.new()
	closed_parent.add_child(closed_dock)
	tree.root.add_child(closed_parent)
	testing.eq(EditorAccess.main_screen_state(_DocksInterface.new(base, closed_dock), _SCREEN),
			EditorAccess.MainScreenState.ABSENT, "a closed dock is absent")
	tree.root.remove_child(closed_parent)
	closed_parent.free()

	var side_slot := TabContainer.new()
	var side_dock := Control.new()
	side_slot.add_child(side_dock)
	tree.root.add_child(side_slot)
	testing.eq(EditorAccess.main_screen_state(_DocksInterface.new(base, side_dock), _SCREEN),
			EditorAccess.MainScreenState.ABSENT, "a dock in another tab container is absent")
	tree.root.remove_child(side_slot)
	side_slot.free()

	var loose_dock := Control.new()
	testing.eq(EditorAccess.main_screen_state(_DocksInterface.new(base, loose_dock), _SCREEN),
			EditorAccess.MainScreenState.ABSENT, "a dock with no parent is absent")
	loose_dock.free()
	base.free()


static func _make_base(button_text: String, variation: StringName) -> Control:
	var base := Control.new()
	var button := Button.new()
	button.text = button_text
	button.toggle_mode = true
	button.theme_type_variation = variation
	base.add_child(button)
	return base


# EditorInterface on Godot 4.2-4.7: the base control only.
class _TabButtonsInterface extends RefCounted:
	var _base: Control = null

	func _init(base: Control) -> void:
		_base = base

	func get_base_control() -> Control:
		return _base


# EditorInterface on Godot 4.8: the base control and the lookup across all docks.
class _DocksInterface extends _TabButtonsInterface:
	var _dock: Control = null

	func _init(base: Control, dock: Control) -> void:
		super(base)
		_dock = dock

	func get_dock_by_name(title: String) -> Control:
		return _dock if title == _SCREEN else null
