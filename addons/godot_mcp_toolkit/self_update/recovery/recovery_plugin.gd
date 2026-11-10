@tool
extends EditorPlugin
## The recovery plugin: a second editor plugin that exists only while a toolkit update is in
## flight, and at the next start sets the toolkit right when that update left it unable to
## load.
##
## It runs from its copy at [code]res://addons/.godot_mcp_toolkit_recovery/[/code], a folder
## the scanner and the Plugins list skip, and loads nothing from the toolkit's folder.
## Anywhere else, the template inside the toolkit included, it does nothing. A settle delay
## after the editor's first scan it reads the journal, asks [code]recovery_journal.gd[/code]
## what to do and acts once: it rolls an interrupted apply forward or back, or puts the
## backup back over a version that did not load, and asks for a restart; it asks for one more
## restart when the toolkit is enabled but never started (Godot 4.2, after an update that moves
## a global class); it shows the manual steps when it cannot set the toolkit right, or takes
## itself out when no update is left.
## The file work is [code]recovery_actions.gd[/code]'s.

const RecoveryJournal := preload("recovery_journal.gd")
const RecoveryActions := preload("recovery_actions.gd")

# Long enough after the last scan for the toolkit's own enable, which Godot 4.2 holds until
# the class list updates when a script it needs was new.
const _SETTLE_SEC := 3.0
const _PROJECT_FILE := "res://project.godot"
const _TITLE := "Godot MCP Toolkit update"
const _FINISHED_TEXT := (
	"The update to version %s stopped partway, and it is now finished. Restart the editor to load it.\n\n"
	+ "Until the restart, the toolkit stays off.")
const _ROLLED_BACK_TEXT := (
	"The update to version %s stopped partway and could not be finished, so %s was put back. "
	+ "Restart the editor to load it.\n\nUntil the restart, the toolkit stays off.")
const _ONE_MORE_RESTART_TEXT := (
	"Version %s is installed, and Godot %s needs one more restart to load it.\n\n"
	+ "Until the restart, the toolkit does not run.")
const _RESTORED_TEXT := (
	"Version %s did not load in Godot %s, so %s was put back. Restart the editor to load it.\n\n"
	+ "Until the restart, the toolkit stays off.")
const _NOT_SAVED_TEXT := (
	"\n\nproject.godot could not be saved, so after the restart turn the toolkit on in "
	+ "Project Settings > Plugins.")
const _MANUAL_TEXT := (
	"The toolkit update from %s to %s left the toolkit off, and the editor cannot set it "
	+ "right by itself.\n\nClose Godot and follow \"The toolkit is off after an update\" in "
	+ "the toolkit's troubleshooting guide (docs/troubleshooting.md). install.log in "
	+ "addons/.godot_mcp_toolkit_update/ says what the update did.")

var _settle_timer: Timer = null
var _dialog: AcceptDialog = null
var _decided := false


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		return
	var own_cfg := (get_script() as Script).resource_path.get_base_dir().path_join("plugin.cfg")
	if own_cfg != RecoveryActions.PLUGIN_CFG:
		return
	_settle_timer = Timer.new()
	_settle_timer.one_shot = true
	_settle_timer.timeout.connect(_on_settle_timeout)
	add_child(_settle_timer)
	EditorInterface.get_resource_filesystem().script_classes_updated.connect(_on_script_classes_updated)
	# Armed now, not on script_classes_updated: the editor emits that signal only when a scan
	# queued a script (4.2's _update_pending_script_classes and 4.3+'s _update_script_classes
	# alike), and a start whose scan skips this folder and finds the toolkit's scripts cached
	# queues none. From 4.3 is_scanning() also covers the first scan, inside which plugins
	# load, and the timeout waits a scan out; the signal, when it comes, restarts the delay.
	_settle_timer.start(_SETTLE_SEC)


func _exit_tree() -> void:
	if not Engine.is_editor_hint():
		return
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem.script_classes_updated.is_connected(_on_script_classes_updated):
		filesystem.script_classes_updated.disconnect(_on_script_classes_updated)
	if ProjectSettings.settings_changed.is_connected(_on_settings_changed):
		ProjectSettings.settings_changed.disconnect(_on_settings_changed)
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.free()
	_dialog = null
	if _settle_timer != null:
		_settle_timer.free()
	_settle_timer = null


func _on_script_classes_updated() -> void:
	if not _decided:
		_settle_timer.start(_SETTLE_SEC)


func _on_settle_timeout() -> void:
	if EditorInterface.get_resource_filesystem().is_scanning():
		_settle_timer.start(_SETTLE_SEC)
		return
	var journal := RecoveryJournal.read(RecoveryActions.UPDATE_FOLDER)
	var facts := RecoveryActions.file_facts(journal, RecoveryActions.UPDATE_FOLDER, RecoveryActions.TOOLKIT_FOLDER)
	facts["stays_out"] = RecoveryJournal.stays_out(DisplayServer.get_name() == "headless", OS.get_cmdline_args())
	facts["toolkit_enabled"] = EditorInterface.is_plugin_enabled(RecoveryActions.TOOLKIT_CFG)
	facts["restart_asked"] = RecoveryActions.restart_asked(_own_folder(), str(journal["to"]))
	var verdict := RecoveryJournal.decide(journal, facts, int(Time.get_unix_time_from_system()))
	var action := str(verdict["action"])
	if action == RecoveryJournal.WAIT:
		_settle_timer.start(float(int(verdict["seconds"])))
		return
	_decided = true
	if action == RecoveryJournal.ROLL_FORWARD or action == RecoveryJournal.ROLL_BACK:
		_roll(journal, action == RecoveryJournal.ROLL_FORWARD)
	elif action == RecoveryJournal.RESTORE or action == RecoveryJournal.FINISH_RESTORE:
		_restore(journal, action == RecoveryJournal.FINISH_RESTORE)
	elif action == RecoveryJournal.RESTART_NEEDED:
		_ask_one_more_restart(journal)
	elif action == RecoveryJournal.MANUAL:
		_show_manual(journal)
	elif action == RecoveryJournal.REMOVE_SELF:
		_remove_self()


# A stage that cannot move in falls back to the backup; with neither, the steps are manual.
# The toolkit is not enabled in this session: from Godot 4.3 the first scan drops the global
# classes of a folder that is not there before it enables plugins, so the toolkit would
# compile against class names this session no longer has.
func _roll(journal: Dictionary, forward: bool) -> void:
	var update_folder := RecoveryActions.UPDATE_FOLDER
	var toolkit_folder := RecoveryActions.TOOLKIT_FOLDER
	if forward and RecoveryActions.roll_forward(update_folder, toolkit_folder):
		_ask_restart(_FINISHED_TEXT % [journal["to"]])
	elif RecoveryActions.roll_back(update_folder, toolkit_folder):
		_ask_restart(_ROLLED_BACK_TEXT % [journal["to"], journal["from"]])
	else:
		_show_manual(journal)


# No enable in this session: the editor already dropped the toolkit as broken, and a
# restart loads the version put back from the saved entry. A restore that a crash stopped
# once the backup was in ends the same way, since the start that dropped the toolkit may
# have saved the list without it.
func _restore(journal: Dictionary, finishing: bool) -> void:
	var engine_version := _engine_version()
	var update_folder := RecoveryActions.UPDATE_FOLDER
	var toolkit_folder := RecoveryActions.TOOLKIT_FOLDER
	var result: String = (RecoveryActions.finish_restore(update_folder, toolkit_folder, engine_version) if finishing
			else RecoveryActions.restore(update_folder, toolkit_folder, engine_version))
	if result == RecoveryActions.FAILED:
		_show_manual(journal)
		return
	if result != RecoveryActions.RESTORED:
		return
	_ask_restart(_RESTORED_TEXT % [journal["to"], engine_version, journal["from"]])


# The toolkit's folder now holds the version to load, which only the next start enables, so
# its entry is saved for that start and kept while this session runs on.
func _ask_restart(text: String) -> void:
	var saved := _keep_toolkit_entry()
	if not ProjectSettings.settings_changed.is_connected(_on_settings_changed):
		ProjectSettings.settings_changed.connect(_on_settings_changed)
	_show_dialog(ConfirmationDialog.new(), text + ("" if saved else _NOT_SAVED_TEXT))


# The toolkit is enabled but never started, so its entry is already saved and the editor
# keeps it through any list rebuild; nothing is saved or moved. The marker's write is not
# checked: if it fails, the next start asks for the restart again.
func _ask_one_more_restart(journal: Dictionary) -> void:
	RecoveryActions.mark_restart_asked(_own_folder(), str(journal["to"]))
	_show_dialog(ConfirmationDialog.new(), _ONE_MORE_RESTART_TEXT % [journal["to"], _engine_version()])


# Writes the setting itself before saving: the editor rebuilds and saves the list only from
# the plugins it has loaded, and the toolkit is not one of them until the restart.
func _keep_toolkit_entry() -> bool:
	ProjectSettings.set_setting(RecoveryActions.ENABLED_SETTING,
			RecoveryActions.with_toolkit_entry(_enabled_list(), RecoveryActions.TOOLKIT_FOLDER))
	ProjectSettings.save()
	return RecoveryActions.saved_list_holds(_PROJECT_FILE, RecoveryActions.TOOLKIT_CFG)


# Until the restart the toolkit is not loaded, so any plugin toggled before it rebuilds the
# list without it; it goes back in while the journal still waits on that restart.
func _on_settings_changed() -> void:
	if not RecoveryJournal.awaits_restart(RecoveryJournal.read(RecoveryActions.UPDATE_FOLDER)):
		ProjectSettings.settings_changed.disconnect(_on_settings_changed)
		return
	if not _enabled_list().has(RecoveryActions.TOOLKIT_CFG):
		_keep_toolkit_entry()


# Nothing is left to recover: the entry and the folder go, then the plugin itself, last and
# deferred, since the editor frees a disabled plugin at once and a call from this plugin's
# own frame would return into freed memory.
func _remove_self() -> void:
	ProjectSettings.set_setting(RecoveryActions.ENABLED_SETTING,
			RecoveryActions.without_entry(_enabled_list(), RecoveryActions.PLUGIN_CFG))
	ProjectSettings.save()
	RecoveryActions.remove_tree(ProjectSettings.globalize_path(RecoveryActions.PLUGIN_CFG.get_base_dir()))
	EditorInterface.set_plugin_enabled.call_deferred(RecoveryActions.PLUGIN_CFG, false)


func _show_manual(journal: Dictionary) -> void:
	_show_dialog(AcceptDialog.new(), _MANUAL_TEXT % [journal["from"], journal["to"]])


# One dialog, not exclusive, so the editor stays usable. A ConfirmationDialog's OK restarts the editor;
# every other way out (Later, Esc, the close button) only closes it.
func _show_dialog(dialog: AcceptDialog, text: String) -> void:
	dialog.exclusive = false
	dialog.title = _TITLE
	dialog.dialog_text = text
	if dialog is ConfirmationDialog:
		dialog.ok_button_text = "Restart now"
		(dialog as ConfirmationDialog).cancel_button_text = "Later"
		dialog.confirmed.connect(_on_restart_pressed)
	else:
		dialog.confirmed.connect(_close_dialog)
	dialog.canceled.connect(_close_dialog)
	_dialog = dialog
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


func _on_restart_pressed() -> void:
	_close_dialog()
	EditorInterface.restart_editor(true)


func _close_dialog() -> void:
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.queue_free()
	_dialog = null


# The Godot version as "major.minor", the way the dialogs and the journal's reason name it.
func _engine_version() -> String:
	var version: Dictionary = Engine.get_version_info()
	return "%d.%d" % [int(version["major"]), int(version["minor"])]


func _own_folder() -> String:
	return RecoveryActions.PLUGIN_CFG.get_base_dir()


func _enabled_list() -> PackedStringArray:
	var enabled: Variant = ProjectSettings.get_setting(RecoveryActions.ENABLED_SETTING, PackedStringArray())
	if enabled is PackedStringArray:
		return enabled
	return PackedStringArray()
