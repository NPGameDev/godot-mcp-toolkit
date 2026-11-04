@tool
extends RefCounted
## Unit tests for the editor screenshot's main-screen switch decisions: whether to ask
## for the switch, whether to go back to a running game's screen, and what the response
## discloses. Stand-ins take the place of the EditorInterface singleton in both of the
## editor's shapes and of the switch back.

const Testing := preload("res://test/units/testing.gd")
const EditorAccess := preload("res://addons/godot_mcp_toolkit/core/editor_access.gd")
const EditorScreenshot := preload("res://addons/godot_mcp_toolkit/commands/editor/editor_screenshot.gd")

const _SCREEN_2D := "2D"
const _SCREEN_GAME := "Game"
const _SWITCHED := "switched_main_screen"
const _FOREGROUNDED := "foregrounded_editor"
const _TABS_VARIATION := &"MainScreenContainer"
const _BUTTON_VARIATION := &"MainScreenButton"


## run() is a coroutine: a tab container takes a new current tab only inside the tree,
## and the runner's root joins it only after a frame, so the runner must
## [code]await[/code] it. [param tree] is the runner itself.
static func run(testing: Testing, tree: SceneTree) -> void:
	await tree.process_frame
	_test_restore_on_docks(testing, tree)
	_test_no_restore_on_tab_buttons(testing)
	_test_switch_request_on_docks(testing, tree)
	_test_switch_request_on_tab_buttons(testing)
	_test_disclosure(testing)
	_test_switch_back_success(testing)


# Only a playing scene with the Game screen current gets its screen back.
static func _test_restore_on_docks(testing: Testing, tree: SceneTree) -> void:
	testing.begin("should_restore_game_screen, docks: only while playing on the Game screen")
	var tabs := _make_main_screen_tabs()
	tree.root.add_child(tabs)
	var game_dock := tabs.get_child(1) as Control
	var other_dock := tabs.get_child(0) as Control
	var docks := {_SCREEN_GAME: game_dock, _SCREEN_2D: other_dock}

	tabs.current_tab = 1
	testing.ok(EditorScreenshot.should_restore_game_screen(_DocksInterface.new(docks, true)),
			"playing, Game current: restore")
	testing.ok(not EditorScreenshot.should_restore_game_screen(_DocksInterface.new(docks, false)),
			"not playing, Game current: no restore")
	tabs.current_tab = 0
	testing.ok(not EditorScreenshot.should_restore_game_screen(_DocksInterface.new(docks, true)),
			"playing, another screen current: no restore")
	testing.ok(not EditorScreenshot.should_restore_game_screen(_DocksInterface.new({}, true)),
			"playing, no Game dock: no restore")

	var floating_parent := Control.new()
	var floating_dock := Control.new()
	floating_parent.add_child(floating_dock)
	testing.ok(not EditorScreenshot.should_restore_game_screen(
			_DocksInterface.new({_SCREEN_GAME: floating_dock}, true)),
			"playing, Game dock outside the main-screen tabs: no restore")
	floating_parent.free()
	tree.root.remove_child(tabs)
	tabs.free()


# Godot 4.2-4.7 keep the one-way switch, even for a user who embeds the game by choice.
static func _test_no_restore_on_tab_buttons(testing: Testing) -> void:
	testing.begin("should_restore_game_screen, tab buttons: never")
	var base := _make_tab_button_base(_SCREEN_GAME, _BUTTON_VARIATION)
	(base.get_child(0) as Button).button_pressed = true
	var interface := _TabButtonsInterface.new(base, true)
	testing.eq(EditorAccess.main_screen_state(interface, _SCREEN_GAME),
			EditorAccess.MainScreenState.SHOWN, "the Game tab reads as shown")
	testing.ok(not EditorScreenshot.should_restore_game_screen(interface),
			"playing, Game tab pressed: no restore")
	base.free()


# Godot 4.8 reports a switch to a screen outside the main-screen tabs as an engine error.
static func _test_switch_request_on_docks(testing: Testing, tree: SceneTree) -> void:
	testing.begin("can_request_switch, docks: not for a screen outside the main-screen tabs")
	var tabs := _make_main_screen_tabs()
	tree.root.add_child(tabs)
	var docks := {_SCREEN_2D: tabs.get_child(1) as Control}
	var interface := _DocksInterface.new(docks, false)
	tabs.current_tab = 0
	testing.ok(EditorScreenshot.can_request_switch(interface, _SCREEN_2D), "a dock behind another tab")
	tabs.current_tab = 1
	testing.ok(EditorScreenshot.can_request_switch(interface, _SCREEN_2D), "the current dock")
	testing.ok(not EditorScreenshot.can_request_switch(interface, "3D"), "no dock of that title")

	var closed_parent := Control.new()
	var closed_dock := Control.new()
	closed_parent.add_child(closed_dock)
	testing.ok(not EditorScreenshot.can_request_switch(
			_DocksInterface.new({_SCREEN_2D: closed_dock}, false), _SCREEN_2D), "a closed dock")
	closed_parent.free()
	tree.root.remove_child(tabs)
	tabs.free()


# Earlier versions are silent for a hidden tab, and on Godot 4.2 every screen reads absent
# though the editor can switch, so a read of the state must not stop it.
static func _test_switch_request_on_tab_buttons(testing: Testing) -> void:
	testing.begin("can_request_switch, tab buttons: always")
	var marked := _make_tab_button_base(_SCREEN_2D, _BUTTON_VARIATION)
	testing.ok(EditorScreenshot.can_request_switch(_TabButtonsInterface.new(marked, false), _SCREEN_2D),
			"a tab found by its theme variation")
	(marked.get_child(0) as Button).visible = false
	testing.ok(EditorScreenshot.can_request_switch(_TabButtonsInterface.new(marked, false), _SCREEN_2D),
			"a hidden tab")
	marked.free()

	var unmarked := _make_tab_button_base(_SCREEN_2D, &"")
	var interface := _TabButtonsInterface.new(unmarked, false)
	testing.eq(EditorAccess.main_screen_state(interface, _SCREEN_2D),
			EditorAccess.MainScreenState.ABSENT, "a tab without the variation reads absent, as on 4.2")
	testing.ok(EditorScreenshot.can_request_switch(interface, _SCREEN_2D),
			"a tab that reads absent is still asked for")
	unmarked.free()


# The runner has no plugin, so select_main_screen fails here as a failed switch back does.
static func _test_disclosure(testing: Testing) -> void:
	testing.begin("finish_switch: a switch that stays is disclosed")
	testing.ok(not EditorAccess.has_plugin(), "the runner holds no plugin")
	var attempts := [0]
	var count_attempt := func() -> bool:
		attempts[0] += 1
		return true
	var no_restore: Array[String] = [_FOREGROUNDED]
	EditorScreenshot.finish_switch(false, no_restore, count_attempt)
	testing.eq(str(no_restore), str([_FOREGROUNDED, _SWITCHED]), "no switch back asked for: disclosed")
	testing.eq(attempts[0], 0, "no switch back asked for: none attempted")
	var failed_restore: Array[String] = []
	var select_game_screen := func() -> bool: return EditorAccess.select_main_screen(_SCREEN_GAME)
	EditorScreenshot.finish_switch(true, failed_restore, select_game_screen)
	testing.eq(str(failed_restore), str([_SWITCHED]), "the switch back failed: disclosed")


static func _test_switch_back_success(testing: Testing) -> void:
	testing.begin("finish_switch: a switch back that succeeds is not disclosed")
	var remediation: Array[String] = [_FOREGROUNDED]
	var succeed := func() -> bool: return true
	EditorScreenshot.finish_switch(true, remediation, succeed)
	testing.eq(str(remediation), str([_FOREGROUNDED]), "only the entry already there remains")


# The editor's main-screen tabs on Godot 4.8, with two docks in them.
static func _make_main_screen_tabs() -> TabContainer:
	var tabs := TabContainer.new()
	tabs.theme_type_variation = _TABS_VARIATION
	tabs.add_child(Control.new())
	tabs.add_child(Control.new())
	return tabs


static func _make_tab_button_base(button_text: String, variation: StringName) -> Control:
	var base := Control.new()
	var button := Button.new()
	button.text = button_text
	button.toggle_mode = true
	button.theme_type_variation = variation
	base.add_child(button)
	return base


# EditorInterface on Godot 4.2-4.7: the base control, and whether a scene is playing.
class _TabButtonsInterface extends RefCounted:
	var _base: Control = null
	var _playing: bool = false

	func _init(base: Control, playing: bool) -> void:
		_base = base
		_playing = playing

	func get_base_control() -> Control:
		return _base

	func is_playing_scene() -> bool:
		return _playing


# EditorInterface on Godot 4.8: the lookup across all docks, and whether a scene is playing.
class _DocksInterface extends RefCounted:
	var _docks: Dictionary = {}
	var _playing: bool = false

	func _init(docks: Dictionary, playing: bool) -> void:
		_docks = docks
		_playing = playing

	func get_dock_by_name(title: String) -> Control:
		return _docks.get(title, null)

	func is_playing_scene() -> bool:
		return _playing
