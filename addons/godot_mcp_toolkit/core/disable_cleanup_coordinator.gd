@tool
extends RefCounted
## Runs the on-disable cleanup dialog sequence detached from the plugin instance.
##
## When the user disables the plugin, the editor frees the [EditorPlugin] the
## instant [code]_disable_plugin()[/code] returns and [code]_exit_tree()[/code]
## runs — BEFORE the user answers the cleanup prompts. Callbacks bound to the
## plugin therefore fire into a freed object and silently no-op (the prompts do
## nothing). So the cleanup sequence lives here instead: an instance is created
## and [method start]ed from [code]_disable_plugin()[/code], and it outlives the
## plugin on its own. Its dialog callbacks reference THIS coordinator (alive),
## never the freed plugin.
##
## Lifetime: the coordinator keeps a reference to itself ([member _self_ref])
## that it clears only when the sequence terminates, so it survives the plugin
## free and the user's async dialog interaction regardless of how the dialogs
## are parented. (Belt-and-suspenders: a self-lambda bound to a RefCounted also
## holds a strong Ref to it — see GDScriptLambdaSelfCallable — but the explicit
## self-ref makes liveness obvious and owned by the coordinator.)

# Machine-wide EditorSettings keys this plugin registers (mirror of the keys in
# plugin.gd::_register_editor_settings). These are PER-USER, MACHINE-WIDE prefs
# shared across every project that uses the toolkit, so — unlike the
# project-local ProjectSettings — they are NEVER scrubbed silently: removing them
# affects the user's other projects, which is why their removal is confirmed.
const _EDITOR_SETTING_KEYS := [
	"mcp_toolkit/personal/dock_default_visible",
	"mcp_toolkit/performance/keep_editor_responsive_unfocused",
	"mcp_toolkit/performance/unfocused_responsive_sleep_usec",
]

# Self-reference that keeps this RefCounted alive across the async dialog flow,
# independent of the plugin (which is freed before the user clicks). Cleared in
# _done(), at which point the coordinator is collected.
var _self_ref: RefCounted = null

# Absolute path to the orphaned .mcp.json, captured up front so the delete
# callback needs nothing from the plugin.
var _mcp_json_path: String = ""


## Begin the cleanup sequence. Prompts about an orphaned [code].mcp.json[/code]
## first (if present), then chains the machine-wide EditorSettings cleanup prompt
## off its resolution (both confirm and cancel); when there is no
## [code].mcp.json[/code] to prompt about, shows the EditorSettings prompt
## directly. The two prompts are shown SEQUENTIALLY — never two popups at once.
func start() -> void:
	_self_ref = self
	_mcp_json_path = ProjectSettings.globalize_path("res://") + ".mcp.json"
	if FileAccess.file_exists(_mcp_json_path):
		_prompt_mcp_json_orphan()
	else:
		_prompt_editor_settings_cleanup()


# Warn about the orphaned .mcp.json and offer to delete it. Either resolution
# chains to the EditorSettings prompt.
func _prompt_mcp_json_orphan() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.exclusive = false
	dialog.title = "MCP Plugin Disabled"
	dialog.dialog_text = (
		"The .mcp.json configuration file is still at your project root:\n"
		+ _mcp_json_path + "\n\n"
		+ "If you're uninstalling the plugin, you may want to remove it.\n"
		+ "If you're just disabling temporarily, keep it.")
	dialog.ok_button_text = "Delete .mcp.json"
	dialog.cancel_button_text = "Keep"
	dialog.confirmed.connect(func() -> void:
		DirAccess.remove_absolute(_mcp_json_path)
		print("[MCP] Deleted .mcp.json at %s" % _mcp_json_path)
		_advance_to_editor_settings_prompt.call_deferred(dialog)
	)
	dialog.canceled.connect(func() -> void:
		print("[MCP] .mcp.json kept at %s" % _mcp_json_path)
		_advance_to_editor_settings_prompt.call_deferred(dialog)
	)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


# Chain continuation between the two prompts — deferred close-then-show, never
# inline from the first prompt's signal callbacks. The prompts are non-exclusive
# (the Project Settings window, still open during a plugin toggle, holds the
# editor root's single exclusive-child slot), and a non-exclusive dialog gets no
# OS-level owner — nothing structurally keeps it above the editor window, so its
# z-order is decided purely by activation order. Showing prompt 2 inline left
# prompt 1's engine-deferred hide still pending; when that hide destroyed
# prompt 1's native window, the OS re-activated the editor OVER the just-shown
# prompt 2. Since Godot 4.6 that re-activation is processed synchronously
# (pre-4.6 it was timer-deferred and superseded before taking effect), which is
# why the buried prompt only manifests on 4.6+. Deferring this continuation
# queues it AFTER the engine's queued hide: prompt 1 is fully closed and the
# editor's re-activation has settled before prompt 2 pops — front and focused on
# every supported version (on <=4.5 the only delta is prompt 2 appearing one
# message-queue flush later). free() is safe here: running deferred means we are
# outside prompt 1's signal emission.
func _advance_to_editor_settings_prompt(finished_dialog: ConfirmationDialog) -> void:
	if is_instance_valid(finished_dialog):
		finished_dialog.free()
	_prompt_editor_settings_cleanup()


# Confirm-then-erase the machine-wide EditorSettings keys this plugin registers.
# This is the terminal step — either resolution frees the dialog and calls
# _done(), which releases the coordinator.
func _prompt_editor_settings_cleanup() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.exclusive = false
	dialog.title = "MCP Plugin Disabled — Editor Preferences"
	dialog.dialog_text = (
		"The MCP Toolkit also stored per-user editor preferences (dock "
		+ "visibility and the unfocused-responsive setting).\n\n"
		+ "These live in your EDITOR settings — they are machine-wide and "
		+ "SHARED across every project that uses the toolkit, so removing them "
		+ "affects your other projects too.\n\n"
		+ "If you're uninstalling everywhere, you may want to remove them.\n"
		+ "If you still use the MCP Toolkit in another project, keep them.")
	dialog.ok_button_text = "Remove editor preferences"
	dialog.cancel_button_text = "Keep"
	dialog.confirmed.connect(func() -> void:
		var editor_settings := EditorInterface.get_editor_settings()
		for key in _EDITOR_SETTING_KEYS:
			editor_settings.erase(key)
		print("[MCP] Removed machine-wide editor preferences")
		dialog.queue_free()
		_done()
	)
	dialog.canceled.connect(func() -> void:
		print("[MCP] Kept machine-wide editor preferences")
		dialog.queue_free()
		_done()
	)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()
	# Explicit raise-and-focus: with no OS owner (non-exclusive, see the chain
	# continuation above) a stray late activation of the editor window could still
	# bury this prompt; a no-op when the prompt is already foreground.
	dialog.grab_focus()


# Release the self-reference now the sequence is complete. With no other refs
# held, the coordinator is collected here.
func _done() -> void:
	_self_ref = null
