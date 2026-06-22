@tool
extends RefCounted
## Section-card factory for the dock — styled cards and collapsible sections.
##
## A stateless `static func` helper (no instance). The dock and its sub-panels
## build several visually-identical "section" blocks (a titled card holding a
## section's controls, or a collapsible variant with a toggle header); this is
## the single place that card shape — its stylebox, header, and content layout —
## lives.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")


## Build the theme-adaptive stylebox shared by every section card and the footer.
## Samples the editor's "Panel" stylebox for a base colour so cards read as a
## darker, bordered inset against the current editor theme. Returned fresh per
## call (a StyleBoxFlat is owned by the Control it overrides — see §B.7).
static func make_section_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	var scale := EditorInterface.get_editor_scale()
	# Sample the editor Panel stylebox for a theme-adaptive base color.
	var base := Color(0.22, 0.22, 0.22)
	var theme := Modules.EditorAccess.get_editor_theme()
	if theme:
		var sb = theme.get_stylebox("panel", "Panel")
		if sb is StyleBoxFlat:
			base = sb.bg_color
	style.bg_color = base.darkened(0.12)
	style.border_color = base.lightened(0.15)
	style.set_border_width_all(1)
	style.set_corner_radius_all(int(3 * scale))
	style.content_margin_left = 8.0 * scale
	style.content_margin_right = 8.0 * scale
	style.content_margin_top = 6.0 * scale
	style.content_margin_bottom = 6.0 * scale
	return style


## Build a styled section card with a header and content VBox.
## Access the content VBox via  section.get_meta("content").
static func make_section(title: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", make_section_style())
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var outer := VBoxContainer.new()
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(outer)

	var header := Label.new()
	header.text = title
	header.add_theme_font_size_override("font_size", 13)
	outer.add_child(header)
	outer.add_child(HSeparator.new())

	var content := VBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(content)
	panel.set_meta("content", content)
	return panel


## Build a collapsible section with a styled header bar and per-section
## ScrollContainer. The header is added to `parent` so it never scrolls away;
## only the section content scrolls. Returns the content VBoxContainer.
static func make_collapsible(parent: VBoxContainer, title: String, expanded: bool, min_height: float = 75.0) -> VBoxContainer:
	var header := PanelContainer.new()
	header.add_theme_stylebox_override("panel", make_section_style())
	parent.add_child(header)

	var toggle := Button.new()
	toggle.flat = true
	toggle.toggle_mode = true
	toggle.button_pressed = expanded
	toggle.text = "%s %s" % ["▼" if expanded else "▶", title]
	toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.add_child(toggle)

	var content_scroll := ScrollContainer.new()
	content_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_scroll.custom_minimum_size.y = int(min_height * EditorInterface.get_editor_scale())
	content_scroll.visible = expanded
	parent.add_child(content_scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_scroll.add_child(content)

	var t := title  # capture for lambda
	toggle.toggled.connect(func(pressed: bool):
		content_scroll.visible = pressed
		toggle.text = "%s %s" % ["▼" if pressed else "▶", t]
	)

	return content
