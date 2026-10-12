@tool
extends RefCounted
## Unit tests for the dock's section layout: one scroll area takes the spare height,
## and the sections inside it stay as tall as their content, so an open section shows
## no padding of its own. Everything is built off the tree into a plain VBoxContainer
## and freed at the end of each group.

const DockSectionCard := preload("res://addons/godot_mcp_toolkit/ui/dock/dock_section_card.gd")


static func run(testing) -> void:
	_test_scroll_area(testing)
	_test_collapsibles_in_scroll_area(testing)
	_test_section_card(testing)


# The factory adds one scroll that expands vertically; the box it returns does not, so
# the sections stack at the top of the scroll.
static func _test_scroll_area(testing) -> void:
	testing.begin("Dock layout: the scroll area takes the spare height")
	var root := VBoxContainer.new()
	var box := DockSectionCard.make_scroll_area(root)
	testing.eq(root.get_child_count(), 1, "the factory adds one child to the parent")
	var scroll := root.get_child(0) as ScrollContainer
	testing.ok(scroll != null, "that child is a ScrollContainer")
	if scroll != null:
		testing.ok(_expands_vertically(scroll), "the scroll expands vertically")
		testing.ok(box.get_parent() == scroll, "the returned box sits in the scroll")
	testing.ok(not _expands_vertically(box), "the returned box does not expand vertically")
	root.free()
	print("")


# Two collapsibles, one open: nothing in the scroll area expands, and no section brings
# a scroll of its own.
static func _test_collapsibles_in_scroll_area(testing) -> void:
	testing.begin("Dock layout: collapsible sections take their content's height")
	var root := VBoxContainer.new()
	var box := DockSectionCard.make_scroll_area(root)
	DockSectionCard.make_collapsible(box, "First", true)
	DockSectionCard.make_collapsible(box, "Second", false)
	testing.ok(box.get_child_count() > 0, "the sections are built into the box")
	var expanding := 0
	for child in box.get_children():
		var control := child as Control
		if control != null and _expands_vertically(control):
			expanding += 1
	testing.eq(expanding, 0, "no section part expands vertically")
	testing.eq(_count_scrolls(box), 0, "no ScrollContainer sits under the scroll area")
	root.free()
	print("")


# A section card is as tall as its content, so a pinned card needs no fixed-height override.
static func _test_section_card(testing) -> void:
	testing.begin("Dock layout: a section card does not expand")
	var panel := DockSectionCard.make_section("Card")
	testing.ok(not _expands_vertically(panel), "the card's panel does not expand vertically")
	panel.free()
	print("")


static func _expands_vertically(control: Control) -> bool:
	return (control.size_flags_vertical & Control.SIZE_EXPAND) != 0


# Counts the ScrollContainers under node, at any depth.
static func _count_scrolls(node: Node) -> int:
	var count := 0
	for child in node.get_children():
		if child is ScrollContainer:
			count += 1
		count += _count_scrolls(child)
	return count
