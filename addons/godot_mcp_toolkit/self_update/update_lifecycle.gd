@tool
extends RefCounted
## Runs what the editor's own start and exit do to an update, in the editors that may.
##
## A headless editor is a build or an import, not someone's session, and it installs
## nothing. Left to run there, the applier's refusal would delete the stage and the zip of
## an update waiting for the next real exit, so such an editor calls neither the settle nor
## the apply, and the update folder stays as it found it. The override in
## [constant InstallGuards.HEADLESS_OVERRIDE_ENV] lets the integration tests through.

# Direct preloads: core/modules.gd does not list this folder's scripts.
const InstallGuards := preload("res://addons/godot_mcp_toolkit/self_update/install_guards.gd")
const UpdateApplier := preload("res://addons/godot_mcp_toolkit/self_update/update_applier.gd")
const UpdateSettler := preload("res://addons/godot_mcp_toolkit/self_update/update_settler.gd")


## Whether this editor must leave the update folder alone. [param options] is what
## [method UpdateApplier.apply_pending] takes, read here only for its
## [code]guard_facts[/code]; without them, this looks at the running editor.
static func stays_out(options: Dictionary = {}) -> bool:
	var injected: Dictionary = options.get("guard_facts", {})
	return InstallGuards.headless_refused(injected if not injected.is_empty() else InstallGuards.headless_facts())


## Settles what the last exit left, unless this editor stays out.
##
## Returns what [method UpdateSettler.settle] returns, or an empty dictionary when nothing
## ran.
static func settle_at_start(options: Dictionary = {}) -> Dictionary:
	return {} if stays_out(options) else UpdateSettler.settle(options)


## Applies the staged update, unless this editor stays out.
##
## Returns what [method UpdateApplier.apply_pending] returns, or an empty dictionary when
## nothing ran.
static func apply_at_exit(options: Dictionary = {}) -> Dictionary:
	return {} if stays_out(options) else UpdateApplier.apply_pending(options)
