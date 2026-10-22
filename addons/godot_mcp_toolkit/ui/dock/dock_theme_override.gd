@tool
extends RefCounted
## Theme-override writes for dock controls that repaint on a timer: each write is
## skipped when the control already holds the value.
##
## Writing a theme override queues a redraw even when the value is unchanged, and
## in low-processor mode any rendering-server change draws a frame; on Godot
## 4.2–4.5 the queued redraw writes to the rendering server even for a hidden
## control. A repaint that re-applies an unchanged override every tick would keep
## an idle editor drawing, so every such write goes through here. Each check
## reads the control itself rather than a cache, so a write made on any other
## path is still seen.


## Set the [param name] colour override on [param control] to [param color],
## unless the control already overrides it with that colour.
static func set_color(control: Control, name: StringName, color: Color) -> void:
	if control.has_theme_color_override(name) and control.get_theme_color(name) == color:
		return
	control.add_theme_color_override(name, color)


## Remove the [param name] colour override from [param control], if it has one.
static func clear_color(control: Control, name: StringName) -> void:
	if control.has_theme_color_override(name):
		control.remove_theme_color_override(name)


## Set the [param name] stylebox override on [param control] to [param style],
## unless the control already overrides it with that same instance.
static func set_stylebox(control: Control, name: StringName, style: StyleBox) -> void:
	if control.has_theme_stylebox_override(name) and control.get_theme_stylebox(name) == style:
		return
	control.add_theme_stylebox_override(name, style)
