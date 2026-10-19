@tool
extends RefCounted
## Unit tests for the dock's section layout: one scroll area takes the spare height,
## and the sections inside it stay as tall as their content, so an open section shows
## no padding of its own. Everything is built off the tree into a plain VBoxContainer
## and freed at the end of each group.
##
## Also covers the floor that keeps a short dock's section headers in view, and the
## size limits that keep the Info dialog inside the editor window.
## The in-tree groups build the same shape into the runner's root, request a short
## height and check the sorted rects.

const DockSectionCard := preload("res://addons/godot_mcp_toolkit/ui/dock/dock_section_card.gd")
const InfoDialog := preload("res://addons/godot_mcp_toolkit/ui/dock/ext/info_dialog.gd")

# Wide enough for the section titles; the in-tree groups compare rects, so any
# realistic dock width gives the same relations.
const _DOCK_WIDTH := 320.0
# Enough lines that an open section's content is taller than the collapsed headers.
const _OPEN_SECTION_LINES := 8


## run() is a coroutine: the in-tree groups await frames, so the runner must
## [code]await[/code] it. [param tree] is the runner itself: Engine.get_main_loop() is still
## null while the runner's _init runs.
static func run(testing, tree: SceneTree) -> void:
	_test_scroll_area(testing)
	_test_collapsibles_in_scroll_area(testing)
	_test_section_card(testing)
	_test_header_floor(testing)
	_test_info_dialog_window_cap(testing)
	await _test_short_dock_keeps_headers_in_view(testing, tree)
	await _test_open_section_scrolls(testing, tree)


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


# The floor keeps the scroll area at least as tall as its collapsed headers, so a short
# dock still shows them; a scroll area without the floor keeps no minimum height.
static func _test_header_floor(testing) -> void:
	testing.begin("Dock layout: the header floor holds the collapsed headers")
	var root := VBoxContainer.new()
	var box := DockSectionCard.make_scroll_area(root)
	DockSectionCard.make_collapsible(box, "First", true)
	DockSectionCard.make_collapsible(box, "Second", false)
	# Each collapsible adds its header, then its content box.
	var headers_height := (
			(box.get_child(0) as Control).get_combined_minimum_size().y
			+ (box.get_child(2) as Control).get_combined_minimum_size().y)
	testing.ok(headers_height > 0.0, "the headers report a height")
	DockSectionCard.apply_header_floor(box)
	var scroll := box.get_parent() as ScrollContainer
	testing.ok(scroll.custom_minimum_size.y >= headers_height,
			"the scroll is at least as tall as both headers")

	var bare_root := VBoxContainer.new()
	var bare_box := DockSectionCard.make_scroll_area(bare_root)
	DockSectionCard.make_collapsible(bare_box, "Only", false)
	var bare_scroll := bare_box.get_parent() as ScrollContainer
	testing.eq(bare_scroll.custom_minimum_size.y, 0.0, "a scroll without the floor keeps no minimum height")
	root.free()
	bare_root.free()
	print("")


# The Info dialog opens at its default size, at most 90% of the editor window per axis,
# and its minimum never exceeds its maximum.
static func _test_info_dialog_window_cap(testing) -> void:
	testing.begin("Info dialog: the size stays inside the editor window")
	var requested := Vector2i(520, 460)

	var large := InfoDialog.fit_to_window(requested, Vector2i(2000, 1000))
	testing.eq(large["open"], Vector2i(520, 460), "a large window opens the default size")
	testing.eq(large["min_size"], Vector2i(520, 460), "a large window keeps the default minimum")
	testing.eq(large["max_size"], Vector2i(1800, 900), "the maximum is 90% of a large window")

	var small := InfoDialog.fit_to_window(requested, Vector2i(500, 500))
	testing.eq(small["open"], Vector2i(450, 450), "a small window opens at 90% of it")
	testing.eq(small["min_size"], Vector2i(450, 450), "a small window lowers the minimum to 90% of it")
	testing.eq(small["max_size"], Vector2i(450, 450), "the maximum is 90% of a small window")

	var short := InfoDialog.fit_to_window(requested, Vector2i(1000, 400))
	testing.eq(short["open"], Vector2i(520, 360), "a short window opens at 90% of its height")
	testing.eq(short["min_size"], Vector2i(520, 360), "a short window lowers the minimum height to the cap")
	testing.eq(short["max_size"], Vector2i(900, 360), "the maximum is 90% of a short window")
	var short_min: Vector2i = short["min_size"]
	var short_max: Vector2i = short["max_size"]
	testing.ok(short_min.x <= short_max.x and short_min.y <= short_max.y,
			"the minimum is never above the maximum")
	print("")


# A bottom panel dragged short gives the dock its minimum height. With every
# section collapsed, the scroll area must still be tall enough to show each
# header whole.
static func _test_short_dock_keeps_headers_in_view(testing, tree: SceneTree) -> void:
	testing.begin("Dock layout in the tree: a short dock keeps every header in view")
	var dock := await _build_short_dock_in_tree(tree, false)
	var root: VBoxContainer = dock["root"]
	var scroll: ScrollContainer = dock["scroll"]
	var box: VBoxContainer = dock["box"]
	# Each collapsible adds its header, then its content box.
	var headers: Array[Control] = [box.get_child(0) as Control, box.get_child(2) as Control]
	var headers_height := 0.0
	for header in headers:
		headers_height += header.get_combined_minimum_size().y
	var separations := float((headers.size() - 1) * box.get_theme_constant("separation"))
	var view := Rect2(Vector2.ZERO, scroll.size)

	testing.ok(scroll.size.y > 0.0, "the scroll keeps some height in a short dock")
	testing.ok(scroll.size.y >= headers_height + separations,
			"the scroll is at least as tall as both headers and the gap between them")
	testing.ok(view.encloses(_rect_in(headers[0], scroll)), "the first header lies inside the scroll")
	testing.ok(view.encloses(_rect_in(headers[1], scroll)), "the second header lies inside the scroll")
	tree.root.remove_child(root)
	root.free()
	print("")


# Opening a section in a short dock must scroll its content, not squeeze the
# scroll area: the scroll keeps the collapsed dock's height and the box grows
# past it.
static func _test_open_section_scrolls(testing, tree: SceneTree) -> void:
	testing.begin("Dock layout in the tree: an open section scrolls instead of shrinking")
	var collapsed := await _build_short_dock_in_tree(tree, false)
	var collapsed_root: VBoxContainer = collapsed["root"]
	var collapsed_scroll: ScrollContainer = collapsed["scroll"]
	var collapsed_height := collapsed_scroll.size.y
	tree.root.remove_child(collapsed_root)
	collapsed_root.free()

	var dock := await _build_short_dock_in_tree(tree, true)
	var root: VBoxContainer = dock["root"]
	var scroll: ScrollContainer = dock["scroll"]
	var box: VBoxContainer = dock["box"]
	var first_header := box.get_child(0) as Control
	var second_header := box.get_child(2) as Control

	testing.ok(Rect2(Vector2.ZERO, scroll.size).encloses(_rect_in(first_header, scroll)),
			"the first header stays in view")
	testing.eq(scroll.size.y, collapsed_height, "the scroll keeps the collapsed dock's height")
	testing.ok(box.size.y > scroll.size.y, "the box is taller than the scroll, so the open section scrolls")
	testing.ok(Rect2(Vector2.ZERO, box.size).encloses(_rect_in(second_header, box)),
			"the second header still lies inside the box")
	tree.root.remove_child(root)
	root.free()
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


# Builds the dock's shape from the section factories, in the dock's order: a pinned
# status card, the scroll area with two collapsible sections and the header floor,
# and a footer pinned at the bottom. The root is added to the runner's root and
# asked for a height below any minimum, so it is clamped to its combined minimum,
# as the bottom panel's split clamps the dock. Returns the root, the scroll and the
# box the sections sit in; the caller removes the root from the tree and frees it.
static func _build_short_dock_in_tree(tree: SceneTree, first_open: bool) -> Dictionary:
	# The runner's root becomes usable once its main loop has started.
	await tree.process_frame
	var root := VBoxContainer.new()
	var status_card := DockSectionCard.make_section("Server Status")
	root.add_child(status_card)
	var status_content: VBoxContainer = status_card.get_meta("content")
	status_content.add_child(_make_label("Listening"))

	var box := DockSectionCard.make_scroll_area(root)
	var first_content := DockSectionCard.make_collapsible(box, "First", first_open)
	for line in _OPEN_SECTION_LINES:
		first_content.add_child(_make_label("Line %d" % line))
	var second_content := DockSectionCard.make_collapsible(box, "Second", false)
	second_content.add_child(_make_label("Line"))
	DockSectionCard.apply_header_floor(box)

	var footer := PanelContainer.new()
	footer.add_theme_stylebox_override("panel", DockSectionCard.make_section_style())
	footer.size_flags_vertical = Control.SIZE_SHRINK_END
	footer.add_child(_make_label("Footer"))
	root.add_child(footer)

	tree.root.add_child(root)
	root.size = Vector2(_DOCK_WIDTH, 1.0)
	await tree.process_frame
	await tree.process_frame
	return {
		"root": root,
		"scroll": box.get_parent() as ScrollContainer,
		"box": box,
	}


static func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


# The rect of control in ancestor's coordinates. Neither is rotated or scaled, so
# the global positions differ by a translation only.
static func _rect_in(control: Control, ancestor: Control) -> Rect2:
	return Rect2(control.global_position - ancestor.global_position, control.size)
