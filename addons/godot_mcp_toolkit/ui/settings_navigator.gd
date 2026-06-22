@tool
extends RefCounted
## Navigates to the Mcp Toolkit section in the ProjectSettings dialog.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")


static func open_mcp_settings() -> void:
	var root := EditorInterface.get_base_control().get_tree().root
	var dialog := _find_node_by_class(root, "ProjectSettingsEditor")
	if not dialog is Window:
		var toaster = Modules.EditorAccess.get_toaster()
		if toaster != null:
			toaster.push_toast(
				"Project -> Project Settings -> Mcp Toolkit", 0)
		return

	# Try the C++ fast-path: popup_project_settings() refreshes the section
	# tree internally, then set_general_page() selects the section directly.
	if dialog.has_method("popup_project_settings"):
		dialog.call("popup_project_settings", false)
		if dialog.has_method("set_general_page"):
			dialog.call("set_general_page", "Mcp Toolkit")
			return
	else:
		dialog.popup_centered_clamped(Vector2i(900, 700))

	# Fallback: temporarily enable Advanced so the custom section is visible,
	# select it, then disable Advanced again so the user doesn't see the clutter.
	_enable_advanced_settings(dialog)
	EditorInterface.get_base_control().get_tree().create_timer(0.05).timeout.connect(func():
		_select_mcp_section(dialog)
		_disable_advanced_settings(dialog)
	)


static func _enable_advanced_settings(dialog: Window) -> void:
	var buttons: Array = []
	_collect_nodes_by_class(dialog, "CheckButton", buttons)
	for btn in buttons:
		var cb := btn as CheckButton
		if cb.text.to_lower().contains("advanced") and not cb.button_pressed:
			cb.button_pressed = true
			return


static func _disable_advanced_settings(dialog: Window) -> void:
	var buttons: Array = []
	_collect_nodes_by_class(dialog, "CheckButton", buttons)
	for btn in buttons:
		var cb := btn as CheckButton
		if cb.text.to_lower().contains("advanced") and cb.button_pressed:
			cb.button_pressed = false
			return


static func _select_mcp_section(dialog: Window) -> void:
	# Ensure the General tab is active (tab 0).
	var tab := _find_node_by_class(dialog, "TabContainer") as TabContainer
	if tab != null:
		tab.current_tab = 0
	var trees: Array = []
	_collect_nodes_by_class(dialog, "Tree", trees)
	for tree_node in trees:
		var tree: Tree = tree_node as Tree
		var root_item := tree.get_root()
		if root_item == null:
			continue
		# Try "Mcp Toolkit" first, then any item containing "mcp".
		var target := _find_tree_item(root_item, "Mcp Toolkit")
		if target == null:
			target = _find_tree_item_contains(root_item, "mcp")
		if target != null:
			var parent := target.get_parent()
			while parent != null:
				parent.collapsed = false
				parent = parent.get_parent()
			target.select(0)
			tree.item_selected.emit()
			return


static func _collect_nodes_by_class(node: Node, cls: String, result: Array, depth: int = 15) -> void:
	if node.get_class() == cls:
		result.append(node)
	if depth <= 0:
		return
	for child in node.get_children():
		_collect_nodes_by_class(child, cls, result, depth - 1)


static func _find_tree_item(item: TreeItem, text: String) -> TreeItem:
	if item.get_text(0).to_lower() == text.to_lower():
		return item
	var child := item.get_first_child()
	while child != null:
		var found := _find_tree_item(child, text)
		if found != null:
			return found
		child = child.get_next()
	return null


static func _find_tree_item_contains(item: TreeItem, substr: String) -> TreeItem:
	if item.get_text(0).to_lower().contains(substr.to_lower()):
		return item
	var child := item.get_first_child()
	while child != null:
		var found := _find_tree_item_contains(child, substr)
		if found != null:
			return found
		child = child.get_next()
	return null


static func _find_node_by_class(node: Node, cls: String, depth: int = 15) -> Node:
	if node.get_class() == cls:
		return node
	if depth <= 0:
		return null
	for child in node.get_children():
		var found := _find_node_by_class(child, cls, depth - 1)
		if found != null:
			return found
	return null
