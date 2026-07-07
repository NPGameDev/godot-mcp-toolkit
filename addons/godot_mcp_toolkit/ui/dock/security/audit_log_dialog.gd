@tool
extends AcceptDialog
## In-editor audit-log viewer — reads the audit log tail (last 100 lines) and
## renders it scrollable. "Open File" shells out to the full log on disk.
##
## Lazy-created and owned by the dock. Each show_log() re-reads the tail and
## fully rebuilds the content, so a reused instance shows the latest log.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const EditorPopup := preload("res://addons/godot_mcp_toolkit/ui/editor_popup.gd")

# One-time dialog chrome (title/buttons/handlers) is installed on first show;
# the scrollable content is cleared and rebuilt on every call.
var _built: bool = false
var _content_root: VBoxContainer = null
# Path the "Open File" action opens — refreshed each show_log() so the button
# always targets the log the dialog is currently displaying.
var _current_path: String = ""


## Reads the audit log tail and renders it, then pops the dialog centered and
## scrolled to the bottom. Pass the dock's audit path; an empty path falls back
## to the canonical log location.
func show_log(audit_path: String) -> void:
	# Read the log file.
	var path := audit_path
	if path.is_empty():
		path = Modules.Audit.get_log_path()
	_current_path = path
	var log_text := ""
	if FileAccess.file_exists(path):
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			var full_text := file.get_as_text()
			file.close()
			var lines := full_text.split("\n")
			if lines.size() > 100:
				var tail := lines.slice(lines.size() - 100)
				log_text = "\n".join(tail)
				log_text += "\n\n... Showing last 100 lines. Open the file to view the full log."
			else:
				log_text = full_text
	if log_text.strip_edges().is_empty():
		log_text = "(audit log is empty)"

	_ensure_built()

	# Clear prior content immediately — remove_child (not just queue_free) so the
	# rebuilt dialog's contents-minimum-size reflects only the new content.
	# queue_free alone leaves the old subtree in the tree for the current frame,
	# inflating popup_centered's size on every reopen (the window is grow-only).
	for child in _content_root.get_children():
		_content_root.remove_child(child)
		child.queue_free()

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(600, 400)
	_content_root.add_child(scroll)

	var text_label := RichTextLabel.new()
	text_label.bbcode_enabled = false
	text_label.fit_content = true
	text_label.scroll_active = false  # scroll handled by parent ScrollContainer
	text_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_label.selection_enabled = true
	text_label.text = log_text
	text_label.add_theme_font_size_override("normal_font_size", 11)
	scroll.add_child(text_label)

	# Open at an explicit size and raised (see EditorPopup), then scroll to bottom
	# after a layout pass. The explicit size stops a reused dialog from drifting (a
	# no-arg popup reuses the window's current size); raising keeps the "View Audit
	# Log" button responsive when the dialog sinks behind the viewport.
	EditorPopup.present(self, Vector2i(620, 480))
	await get_tree().process_frame
	scroll.scroll_vertical = scroll.get_v_scroll_bar().max_value


# Installs the dialog chrome once: title, Close/Open File buttons, and the
# custom-action handler (which opens whatever _current_path points at).
func _ensure_built() -> void:
	if _built:
		return
	title = "MCP Toolkit — Audit Log"
	ok_button_text = "Close"
	exclusive = false
	min_size = Vector2i(620, 480)

	add_button("Open File", true, "open_file")
	custom_action.connect(func(action: StringName):
		if action == "open_file":
			var global_path := ProjectSettings.globalize_path(_current_path)
			OS.shell_open(global_path)
	)

	_content_root = VBoxContainer.new()
	_content_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_content_root)

	_built = true
