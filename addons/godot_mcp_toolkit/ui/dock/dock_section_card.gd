@tool
extends RefCounted
## Section-card factory for the dock — styled cards, collapsible sections, and
## the scroll area that holds them.
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
	# Read the editor's scale and sample its Panel stylebox for a theme-adaptive
	# base colour only inside the editor. Outside it, as in a headless run, the
	# scale call is a script error and the theme lookup crashes the engine, so the
	# card keeps scale 1 and the fallback colour.
	var scale := 1.0
	var base := Color(0.22, 0.22, 0.22)
	if Engine.is_editor_hint():
		scale = EditorInterface.get_editor_scale()
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

	var outer := VBoxContainer.new()
	panel.add_child(outer)

	var header := Label.new()
	header.text = title
	header.add_theme_font_size_override("font_size", 13)
	outer.add_child(header)
	outer.add_child(HSeparator.new())

	var content := VBoxContainer.new()
	outer.add_child(content)
	panel.set_meta("content", content)
	return panel


## Build the scroll area that holds a surface's collapsible sections, and add it
## to [param parent]. The scroll takes the parent's spare height; the returned
## box fills its width but stays as tall as its content, so the sections stack
## at the top and the spare height sits below the last one. Returns the
## VBoxContainer to build the sections into.
static func make_scroll_area(parent: Control) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(scroll)

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	return box


## Build a collapsible section into [param parent]: a styled header bar whose
## toggle shows or hides the content box below it. Both go straight into
## [param parent], so an open section is as tall as its content and scrolls
## with the surface's scroll area (see [method make_scroll_area]). Returns the
## content VBoxContainer.
static func make_collapsible(parent: VBoxContainer, title: String, expanded: bool) -> VBoxContainer:
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

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.visible = expanded
	parent.add_child(content)

	var t := title  # capture for lambda
	toggle.toggled.connect(func(pressed: bool):
		content.visible = pressed
		toggle.text = "%s %s" % ["▼" if pressed else "▶", t]
	)

	return content
