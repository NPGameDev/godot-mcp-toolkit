@tool
extends RefCounted
## Unit tests for the dock's theme-override writes: an unchanged override is never
## written again, so a repaint on the dock's timer queues no redraw.
##
## The headless runner never draws, so each group counts [code]theme_changed[/code]
## instead: an in-tree control emits it for every override write, the write that
## queues the redraw.

const DockThemeOverride := preload("res://addons/godot_mcp_toolkit/ui/dock/dock_theme_override.gd")
const DockMcpJsonPanel := preload("res://addons/godot_mcp_toolkit/ui/dock/mcp/dock_mcp_json_panel.gd")
const MCPJsonWriteFlow := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_write_flow.gd")

const _RED := Color(1.0, 0.0, 0.0)
const _BLUE := Color(0.0, 0.0, 1.0)


## run() is a coroutine: the runner's root joins the tree only after a frame, so the
## runner must [code]await[/code] it. [param tree] is the runner itself.
static func run(testing, tree: SceneTree) -> void:
	await tree.process_frame
	_test_set_color_skips_equal_write(testing, tree)
	_test_clear_color_skips_missing_override(testing, tree)
	_test_set_stylebox_skips_same_instance(testing, tree)
	_test_mcp_json_panel_refresh_rewrites_nothing(testing, tree)


static func _test_set_color_skips_equal_write(testing, tree: SceneTree) -> void:
	testing.begin("Dock theme override: set_color writes only a changed colour")
	var label := Label.new()
	tree.root.add_child(label)
	var writes := _count_theme_writes(label)
	DockThemeOverride.set_color(label, "font_color", _RED)
	testing.eq(writes[0], 1, "the first colour is written")
	testing.eq(label.get_theme_color("font_color"), _RED, "the label holds that colour")
	DockThemeOverride.set_color(label, "font_color", _RED)
	testing.eq(writes[0], 1, "the same colour again writes nothing")
	DockThemeOverride.set_color(label, "font_color", _BLUE)
	testing.eq(writes[0], 2, "a new colour is written")
	testing.eq(label.get_theme_color("font_color"), _BLUE, "the label holds the new colour")
	# A write made around the helper is read back from the label, not remembered.
	label.add_theme_color_override("font_color", _RED)
	DockThemeOverride.set_color(label, "font_color", _BLUE)
	testing.eq(writes[0], 4, "a colour changed elsewhere is written back")
	testing.eq(label.get_theme_color("font_color"), _BLUE, "the label holds the written colour")
	tree.root.remove_child(label)
	label.free()
	print("")


static func _test_clear_color_skips_missing_override(testing, tree: SceneTree) -> void:
	testing.begin("Dock theme override: clear_color removes only an override that is set")
	var label := Label.new()
	tree.root.add_child(label)
	var writes := _count_theme_writes(label)
	DockThemeOverride.clear_color(label, "font_color")
	testing.eq(writes[0], 0, "clearing with no override writes nothing")
	label.add_theme_color_override("font_color", _RED)
	DockThemeOverride.clear_color(label, "font_color")
	testing.eq(writes[0], 2, "clearing a set override writes once")
	testing.ok(not label.has_theme_color_override("font_color"), "the override is gone")
	DockThemeOverride.clear_color(label, "font_color")
	testing.eq(writes[0], 2, "clearing again writes nothing")
	tree.root.remove_child(label)
	label.free()
	print("")


static func _test_set_stylebox_skips_same_instance(testing, tree: SceneTree) -> void:
	testing.begin("Dock theme override: set_stylebox writes only another instance")
	var panel := PanelContainer.new()
	tree.root.add_child(panel)
	var writes := _count_theme_writes(panel)
	var first := StyleBoxFlat.new()
	var second := StyleBoxEmpty.new()
	DockThemeOverride.set_stylebox(panel, "panel", first)
	testing.eq(writes[0], 1, "the first stylebox is written")
	testing.ok(panel.get_theme_stylebox("panel") == first, "the panel holds that stylebox")
	DockThemeOverride.set_stylebox(panel, "panel", first)
	testing.eq(writes[0], 1, "the same instance again writes nothing")
	DockThemeOverride.set_stylebox(panel, "panel", second)
	testing.eq(writes[0], 2, "another instance is written")
	testing.ok(panel.get_theme_stylebox("panel") == second, "the panel holds the other stylebox")
	tree.root.remove_child(panel)
	panel.free()
	print("")


# The real .mcp.json panel and its footer button, refreshed twice on the same file
# state: the second refresh writes no theme override on either. The server-spec row
# reads the editor settings, which the headless runner does not have, so the panel's
# row reference is dropped and refresh() skips the row; the row's label colour goes
# through the same set_color the first group covers.
static func _test_mcp_json_panel_refresh_rewrites_nothing(testing, tree: SceneTree) -> void:
	testing.begin("Dock .mcp.json panel: a refresh on unchanged input rewrites no override")
	var button := Button.new()
	var panel := DockMcpJsonPanel.new(button, Callable(), MCPJsonWriteFlow.new())
	panel._pin_row = null
	tree.root.add_child(panel)
	tree.root.add_child(button)
	panel.refresh()
	var panel_writes := _count_theme_writes(panel)
	var button_writes := _count_theme_writes(button)
	panel.refresh()
	testing.eq(panel_writes[0], 0, "the second refresh writes no override on the panel")
	testing.eq(button_writes[0], 0, "the second refresh writes no override on the button")
	tree.root.remove_child(button)
	tree.root.remove_child(panel)
	button.free()
	panel.free()
	print("")


# Returns a one-element counter that grows by one on every theme_changed of
# [param control]. An array, because a lambda cannot reassign a captured local.
static func _count_theme_writes(control: Control) -> Array:
	var count := [0]
	control.theme_changed.connect(func() -> void: count[0] += 1)
	return count
