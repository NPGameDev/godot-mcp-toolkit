@tool
extends RefCounted
## Version adapter that hosts the toolkit's dock in the editor across the 4.2–4.7 split.
##
## Godot 4.6 reworked editor docks: the bottom-panel tab bar moved into a
## collapsible split, so the legacy [code]add_control_to_bottom_panel[/code] path
## renders an invisible panel on 4.7. The modern [code]EditorDock[/code] +
## [code]EditorPlugin.add_dock[/code] API (new in 4.6) replaces it. This adapter
## isolates that seam behind one capability gate —
## [code]ClassDB.class_exists("EditorDock")[/code], true on 4.6+ — so the composer
## and wizard stay version-agnostic: 4.6+ routes through [code]add_dock[/code],
## 4.2–4.5 through the deprecated bottom-panel calls.
##
## The [code]EditorDock[/code] wrapper is never named as a type (the class is absent
## on 4.2–4.5, so a static reference would parse-error there); it is created via
## [code]ClassDB.instantiate[/code], stored untyped, and driven by dynamic
## [code]call(...)[/code] dispatch. Editor-only: names [code]EditorPlugin[/code], so
## it is preloaded only by editor code and never reaches the runtime autoload.

# EditorDock.DOCK_SLOT_BOTTOM as its integer ordinal. A symbolic
# EditorDock.DOCK_SLOT_BOTTOM would parse-error on 4.2–4.5 (class absent) even in a
# dead branch, so the ordinal is hard-coded — value verified identical in the 4.6
# and 4.7 engine source (editor/docks/dock_constants.h).
const _DOCK_SLOT_BOTTOM := 8

# EditorDock.DOCK_LAYOUT_HORIZONTAL as its integer ordinal (same parse-safety
# reason), matching the horizontal layout the engine's own bottom-panel docks use.
const _DOCK_LAYOUT_HORIZONTAL := 2


## Host [param control] as the toolkit's dock titled [param title]; returns the host
## the other two functions need.
##
## On 4.6+ wraps [param control] in an [code]EditorDock[/code] pinned to the bottom
## slot — mirroring the engine's own bottom-panel docks (non-global, transient,
## horizontal layout) — and registers it via [code]add_dock[/code]; the returned
## [code]EditorDock[/code] is passed back to [method remove] and [method reveal]. On
## 4.2–4.5 adds [param control] through the deprecated
## [code]add_control_to_bottom_panel[/code] and returns [code]null[/code]: there is
## no wrapper, and [param control] itself is the teardown/reveal handle.
static func add(plugin: EditorPlugin, control: Control, title: String) -> Object:
	if _has_editor_dock():
		var dock: Object = ClassDB.instantiate("EditorDock")
		dock.call("add_child", control)
		dock.call("set_title", title)
		# Reproduce the engine's own bottom-panel dock setup (editor_bottom_panel.cpp
		# add_item): non-global + transient so the dock is neither saved to the editor
		# layout nor listed in the docks menu, pinned to the bottom slot with a
		# horizontal layout. The bottom slot is load-bearing — without it add_dock
		# adds the dock hidden and reveal() opens a floating window, not the panel.
		dock.call("set_global", false)
		dock.call("set_transient", true)
		dock.call("set_default_slot", _DOCK_SLOT_BOTTOM)
		dock.call("set_available_layouts", _DOCK_LAYOUT_HORIZONTAL)
		plugin.call("add_dock", dock)
		return dock
	plugin.add_control_to_bottom_panel(control, title)
	return null


## Remove the dock created by [method add]. [param host] is that call's return value
## (the [code]EditorDock[/code] wrapper on 4.6+, [code]null[/code] on 4.2–4.5).
##
## Unparents only — neither [param control] nor the wrapper is freed (the caller
## owns teardown; see the composer's dispose()).
static func remove(plugin: EditorPlugin, control: Control, host: Object) -> void:
	if _has_editor_dock():
		plugin.call("remove_dock", host)
		return
	plugin.remove_control_from_bottom_panel(control)


## Reveal the dock: select its tab and expand the bottom panel. [param host] is
## [method add]'s return value.
##
## On 4.6+ [code]EditorDock.make_visible[/code] both selects the tab and expands the
## collapsed split; the raw [code]make_bottom_panel_item_visible[/code] only sets a
## visibility flag, leaving the panel collapsed. On 4.2–4.5 the legacy call is the
## correct reveal.
static func reveal(plugin: EditorPlugin, control: Control, host: Object) -> void:
	if _has_editor_dock():
		host.call("make_visible")
		return
	plugin.make_bottom_panel_item_visible(control)


# True on Godot 4.6+, where the EditorDock + add_dock API exists; false on 4.2–4.5.
# The single capability probe the three public functions branch on.
static func _has_editor_dock() -> bool:
	return ClassDB.class_exists("EditorDock")
