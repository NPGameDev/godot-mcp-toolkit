@tool
extends RefCounted
## Unit tests for finding a main screen in the editor's two shapes: tab buttons on
## Godot 4.2-4.7, docks on 4.8. A stand-in takes the place of the EditorInterface
## singleton in each; the switch itself needs a real editor, so the QA run covers it.

const Testing := preload("res://test/units/testing.gd")
const EditorAccess := preload("res://addons/godot_mcp_toolkit/core/editor_access.gd")

const _SCREEN := "Asset Store"
const _BUTTON_VARIATION := &"MainScreenButton"
const _TABS_VARIATION := &"MainScreenContainer"


## run() is a coroutine: the runner's root joins the tree only after a frame, so the
## runner must [code]await[/code] it. [param tree] is the runner itself.
static func run(testing: Testing, tree: SceneTree) -> void:
	await tree.process_frame
	_test_tab_button_states(testing)
	_test_tab_button_absent(testing)
	_test_dock_states(testing, tree)
	_test_dock_current_under_a_hidden_ancestor(testing, tree)
	_test_dock_missing(testing)
	_test_dock_outside_the_main_screen_tabs(testing, tree)
	_test_dock_shape_check(testing)


static func _test_tab_button_states(testing: Testing) -> void:
	testing.begin("Main screen, tab buttons: the pressed state tells shown from available")
	var base := _make_base(_SCREEN, _BUTTON_VARIATION)
	var interface := _TabButtonsInterface.new(base)
	testing.eq(EditorAccess.main_screen_state(interface, _SCREEN),
			EditorAccess.MainScreenState.AVAILABLE, "an unpressed tab is available")
	(base.get_child(0) as Button).button_pressed = true
	testing.eq(EditorAccess.main_screen_state(interface, _SCREEN),
			EditorAccess.MainScreenState.SHOWN, "a pressed tab is shown")
	base.free()


static func _test_tab_button_absent(testing: Testing) -> void:
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
static func _test_dock_states(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Main screen, docks: a dock in the main-screen tabs is found")
	var base := _make_base(_SCREEN, &"")
	var tabs := _make_main_screen_tabs()
	var dock := tabs.get_child(1) as Control
	tree.root.add_child(tabs)
	var interface := _DocksInterface.new(base, dock)
	tabs.current_tab = 0
	testing.eq(EditorAccess.main_screen_state(interface, _SCREEN),
			EditorAccess.MainScreenState.AVAILABLE, "a dock behind another tab is available")
	tabs.current_tab = 1
	testing.eq(EditorAccess.main_screen_state(interface, _SCREEN),
			EditorAccess.MainScreenState.SHOWN, "the dock on show is shown")
	tree.root.remove_child(tabs)
	tabs.free()
	base.free()


# An expanded bottom panel hides the ancestor of the main-screen tabs. The current tab
# stays current, and asking the editor to switch to it changes nothing and confirms
# nothing, so a read of visibility would answer that the switch is still to come.
static func _test_dock_current_under_a_hidden_ancestor(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Main screen, docks: a hidden ancestor does not change which tab is current")
	var base := _make_base(_SCREEN, &"")
	var ancestor := Control.new()
	ancestor.visible = false
	var tabs := _make_main_screen_tabs()
	var dock := tabs.get_child(1) as Control
	ancestor.add_child(tabs)
	tree.root.add_child(ancestor)
	var interface := _DocksInterface.new(base, dock)
	tabs.current_tab = 1
	testing.ok(not dock.is_visible_in_tree(), "the current dock is hidden by its ancestor")
	testing.eq(EditorAccess.main_screen_state(interface, _SCREEN),
			EditorAccess.MainScreenState.SHOWN, "the current dock is shown")
	tabs.current_tab = 0
	testing.eq(EditorAccess.main_screen_state(interface, _SCREEN),
			EditorAccess.MainScreenState.AVAILABLE, "a dock behind another tab is available")
	tree.root.remove_child(ancestor)
	ancestor.free()
	base.free()


static func _test_dock_missing(testing: Testing) -> void:
	testing.begin("Main screen, docks: no dock of that title is absent")
	var base := _make_base(_SCREEN, &"")
	testing.eq(EditorAccess.main_screen_state(_DocksInterface.new(base, null), _SCREEN),
			EditorAccess.MainScreenState.ABSENT, "the lookup finds nothing")
	base.free()


# set_main_screen_editor reads only the main-screen tabs, so any other home would make
# it report an engine error. The dock stays visible where it can, to show that
# visibility alone does not count it as shown.
static func _test_dock_outside_the_main_screen_tabs(testing: Testing, tree: SceneTree) -> void:
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

	var plain_parent := Control.new()
	plain_parent.theme_type_variation = _TABS_VARIATION
	var plain_child := Control.new()
	plain_parent.add_child(plain_child)
	testing.eq(EditorAccess.main_screen_state(_DocksInterface.new(base, plain_child), _SCREEN),
			EditorAccess.MainScreenState.ABSENT,
			"a parent with the variation that is no tab container is absent")
	plain_parent.free()
	base.free()


static func _test_dock_shape_check(testing: Testing) -> void:
	testing.begin("Main screen shape: the dock lookup tells docks from tab buttons")
	testing.ok(EditorAccess.main_screens_are_docks(_DocksInterface.new(null, null)),
			"an interface with the lookup holds them as docks")
	testing.ok(not EditorAccess.main_screens_are_docks(_TabButtonsInterface.new(null)),
			"an interface without it holds them as tab buttons")


static func _make_base(button_text: String, variation: StringName) -> Control:
	var base := Control.new()
	var button := Button.new()
	button.text = button_text
	button.toggle_mode = true
	button.theme_type_variation = variation
	base.add_child(button)
	return base


# The editor's main-screen tabs on Godot 4.8, with two docks in them.
static func _make_main_screen_tabs() -> TabContainer:
	var tabs := TabContainer.new()
	tabs.theme_type_variation = _TABS_VARIATION
	tabs.add_child(Control.new())
	tabs.add_child(Control.new())
	return tabs


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
