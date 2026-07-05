@tool
extends RefCounted
## Registers and removes the toolkit's runtime autoload(s) in ProjectSettings — the
## shared path behind both first-enable and the on-load self-heal, so the two can
## never diverge.
##
## Writes autoloads with ProjectSettings.set_setting + save rather than
## EditorPlugin.add_autoload_singleton, on purpose. add_autoload_singleton updates
## only the editor's in-memory state and pushes a startup undo entry, whereas the
## game reads project.godot at F5: the direct path persists to disk by construction
## (surviving to the build) and leaves no undo entry (a stray Ctrl+Z can't undo the
## registration). A has_setting guard means a present value is never clobbered, so a
## healthy project takes no write and shows no project.godot diff. Removal stays
## asymmetric — [method unregister] uses remove_autoload_singleton, a genuine editor
## action with no disk-persistence need (the concern is restoring an absent autoload,
## not undoing the enable toggle).
##
## Editor-only: takes an EditorPlugin and drives ProjectSettings; it is preloaded
## only by the editor-only plugin.gd, never by the runtime autoload. The autoload
## identity (name/path pairs + key/value derivation) comes from the shared
## autoload_identity leaf so the export-strip domain reads the same source without
## coupling to this module. No [code]class_name[/code]: consumers reach it as
## [code]const AutoloadRegistration := preload(...)[/code].

const Identity := preload("res://addons/godot_mcp_toolkit/core/autoload_identity.gd")


## Guarantee every required autoload is present in ProjectSettings, writing only what
## is missing.
##
## Probes each required entry, writes the absent ones with set_setting, then — once
## after the loop and only if something was written — save()s (persists for the next
## F5) and emits settings_changed (refreshes the editor's in-memory autoload view
## after the disk write). Callers that must avoid a premature settings_changed poke
## should invoke this before wiring their own settings_changed listeners.
static func ensure_registered() -> void:
	var present: PackedStringArray = PackedStringArray()
	for entry in Identity.REQUIRED_AUTOLOADS:
		var autoload_name: String = entry[0]
		var key := Identity.settings_key(autoload_name)
		if ProjectSettings.has_setting(key):
			present.append(key)

	var missing: Array = compute_missing(present, Identity.REQUIRED_AUTOLOADS)
	for entry in missing:
		var autoload_name: String = entry[0]
		var script_path: String = entry[1]
		ProjectSettings.set_setting(
				Identity.settings_key(autoload_name), Identity.settings_value(script_path))

	if not missing.is_empty():
		ProjectSettings.save()
		ProjectSettings.emit_signal("settings_changed")


## Remove the required autoload(s) via [param plugin]'s remove_autoload_singleton.
## The teardown counterpart of the enable path; removal is a genuine editor action
## with no disk-persistence need, hence the deliberate asymmetry with registration.
static func unregister(plugin: EditorPlugin) -> void:
	for entry in Identity.REQUIRED_AUTOLOADS:
		var autoload_name: String = entry[0]
		plugin.remove_autoload_singleton(autoload_name)


## Pure decision: of the [name, path] pairs in [param required], return those whose
## "autoload/<name>" key is absent from [param present] (the already-probed set of
## present autoload keys).
##
## Plain-data-in, plain-data-out — the side-effecting shell does the ProjectSettings
## probing and writing, so this stays unit-testable headless. Kept a plain static
## (no Callable) so a bare-static-method reference can't hit Godot 4.2's NIL-self
## bind on an unbound static Callable.
static func compute_missing(present: PackedStringArray, required: Array) -> Array:
	var missing: Array = []
	for entry in required:
		var autoload_name: String = entry[0]
		if not present.has(Identity.settings_key(autoload_name)):
			missing.append(entry)
	return missing
