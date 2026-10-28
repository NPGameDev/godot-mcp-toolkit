@tool
extends PanelContainer
## Dock update badge: the closable notice that a newer toolkit version is published,
## with the install actions the install mode allows, and the result of the last
## install.
##
## A dock sub-panel, the dock's first child. It renders what the injected update
## check runner and update installer report and is hidden while there is nothing to
## show (no newer version, the version dismissed, or the check turned off). A minor
## or patch release gets a blue panel; a major release a green one with a bold title
## and an editor icon. It offers two places to get the version and a close button
## that hides it until a newer one.[br]
## [br]
## When the installer has a verified release, the badge adds Update; once the
## release is staged, Restart now and Don't install, and the line saying the
## editor's exit installs it. A release that becomes installable during the session
## is also announced once by a toast. After an editor start that installed or failed
## to install a release, the badge shows that result until it is closed, in place of
## the version notice; when the new version is tested with another server than the
## one this toolkit wrote into .mcp.json, the notice offers to update it.[br]
## [br]
## "Get it on the Asset Store" switches to the editor's Asset Store tab where the
## editor has one (Godot 4.7+), confirmed through
## [signal EditorPlugin.main_screen_changed], and otherwise opens the store listing
## in the browser. The tab's button text is the untranslated plugin name, so the
## lookup also holds in a translated editor; a missing or hidden tab falls back to
## the browser. Every link is built locally from the version, never taken from a
## reply.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const UpdateCheck = Modules.UpdateCheck
const UpdateCheckRunner = Modules.UpdateCheckRunner
const UpdateInstaller = Modules.UpdateInstaller
const VersionUtils = Modules.VersionUtils
const MCPJsonWriteFlow := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_write_flow.gd")

const _MINOR_TITLE := "Godot MCP Toolkit %s is available."
const _MAJOR_TITLE := "Godot MCP Toolkit %s is out. It's a major release, so see what's new before you update."
const _UPDATED_TITLE := "Godot MCP Toolkit was updated to %s."
const _FAILED_TITLE := "Godot MCP Toolkit %s was not installed."
const _GITHUB_TEXT := "Get it on GitHub"
const _WHATS_NEW_TEXT := "What's new"
const _STORE_TEXT := "Get it on the Asset Store"
const _STORE_UNLISTED_TEXT := "Asset Store (not listed yet)"
const _STORE_UNLISTED_TOOLTIP := "The Asset Store doesn't list this version yet. Use GitHub for now, or check back later."
const _STORE_TAB_TOAST := "Search for \"Godot MCP Toolkit\" in the Asset Store tab."
const _UPDATE_TEXT := "Update"
const _RETRY_TEXT := "Try again"
const _RESTART_TEXT := "Restart now"
const _DISCARD_TEXT := "Don't install"
const _DISMISS_TOOLTIP := "Hide until the next version."
const _NOTICE_DISMISS_TOOLTIP := "Close."
const _LAST_CHECKED_TOOLTIP := "Last checked: %s. The toolkit checks at most once a day."
const _DOWNLOADING_TEXT := "Downloading %s…"
const _READY_TEXT := "%s installs when you close the editor. Restart now to install it at once."
const _FAILED_TEXT := "Couldn't install: %s."
const _CHANGED_TEXT := "%d toolkit files were changed in this project; installing replaces them (a copy is kept until the new version starts)."
const _SERVER_CHANGED_TEXT := "It's tested with server %s, which .mcp.json doesn't run yet. Update .mcp.json, then restart your MCP client."
const _UPDATE_MCP_JSON_TEXT := "Update .mcp.json"
const _UPDATE_SERVER_QUESTION := "Update the server to %s"
const _AVAILABLE_TOAST := "Godot MCP Toolkit %s is available. Update it from the MCP Toolkit dock."
const _READY_TOAST := "Godot MCP Toolkit %s installs when you close the editor."
const _NOT_INSTALLED_TEXT := "%s. Version %s is still installed. Install log: %s"
const _RESTART_TOOLTIP := "Saves the open scenes and restarts the editor, which installs the update on its way out."

# The main-screen tab the 4.7+ editor names its store.
const _STORE_SCREEN := "Asset Store"

const _MINOR_COLOR := Color(0.13, 0.25, 0.42)
const _MAJOR_COLOR := Color(0.11, 0.32, 0.17)
const _FAILED_COLOR := Color(0.42, 0.14, 0.13)
const _TEXT_COLOR := Color(0.95, 0.95, 0.95)

var _runner: UpdateCheckRunner = null
var _installer: UpdateInstaller = null
var _write_flow: MCPJsonWriteFlow = null
# Dock-supplied toast sink (msg, severity, tooltip), so the badge needs no toaster.
var _toast: Callable = Callable()
# The version on display; the close button dismisses exactly this one.
var _shown_version: String = ""
# Whether the badge shows the last install's result rather than a version.
var _showing_notice: bool = false
# The last version the badge showed as installable, so each release is announced
# once, and never one the badge already showed.
var _announced_version: String = ""

var _minor_style: StyleBoxFlat = null
var _major_style: StyleBoxFlat = null
var _failed_style: StyleBoxFlat = null
var _major_icon: TextureRect = null
var _title: Label = null
var _status: Label = null
var _update_btn: Button = null
var _restart_btn: Button = null
var _discard_btn: Button = null
var _update_mcp_json_btn: Button = null
var _github_btn: Button = null
var _store_btn: Button = null
var _dismiss_btn: Button = null
var _regular_font: Font = null
var _bold_font: Font = null


## [param installer] may be [code]null[/code]: the badge then only links, as before
## the installer existed. [param write_flow] is the shared .mcp.json write flow, or
## [code]null[/code] to leave .mcp.json to the dock's section.
func _init(
		runner: UpdateCheckRunner, installer: UpdateInstaller, write_flow: MCPJsonWriteFlow,
		toast: Callable) -> void:
	_runner = runner
	_installer = installer
	_write_flow = write_flow
	_toast = toast
	name = "UpdateBadge"
	visible = false
	# Outside the editor, as in a headless run, EditorInterface is unavailable; the
	# badge then goes without the editor's icons and fonts.
	var editor_theme: Theme = Modules.EditorAccess.get_editor_theme() if Engine.is_editor_hint() else null
	_minor_style = _make_style(_MINOR_COLOR)
	_major_style = _make_style(_MAJOR_COLOR)
	_failed_style = _make_style(_FAILED_COLOR)
	add_theme_stylebox_override("panel", _minor_style)

	var content := VBoxContainer.new()
	content.name = "Content"
	add_child(content)

	var title_row := HBoxContainer.new()
	title_row.name = "TitleRow"
	content.add_child(title_row)

	_major_icon = TextureRect.new()
	_major_icon.name = "MajorIcon"
	_major_icon.texture = _editor_icon(editor_theme, "Favorites")
	_major_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_major_icon.visible = false
	title_row.add_child(_major_icon)

	_title = Label.new()
	_title.name = "Title"
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.add_theme_color_override("font_color", _TEXT_COLOR)
	title_row.add_child(_title)
	if editor_theme != null:
		_regular_font = editor_theme.get_font("main", "EditorFonts")
		_bold_font = editor_theme.get_font("bold", "EditorFonts")

	_dismiss_btn = Button.new()
	_dismiss_btn.name = "DismissButton"
	_dismiss_btn.flat = true
	_dismiss_btn.icon = _editor_icon(editor_theme, "Close")
	_dismiss_btn.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_dismiss_btn.pressed.connect(_on_dismiss_pressed)
	title_row.add_child(_dismiss_btn)

	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", _TEXT_COLOR)
	_status.visible = false
	content.add_child(_status)

	# A flow container wraps the buttons onto more lines in a narrow dock.
	var buttons := HFlowContainer.new()
	buttons.name = "Buttons"
	content.add_child(buttons)

	_update_btn = _add_button(buttons, "UpdateButton", _UPDATE_TEXT, _on_update_pressed)
	_restart_btn = _add_button(buttons, "RestartButton", _RESTART_TEXT, _on_restart_pressed)
	_restart_btn.tooltip_text = _RESTART_TOOLTIP
	_discard_btn = _add_button(buttons, "DiscardButton", _DISCARD_TEXT, _on_discard_pressed)
	_update_mcp_json_btn = _add_button(
			buttons, "UpdateMcpJsonButton", _UPDATE_MCP_JSON_TEXT, _on_update_mcp_json_pressed)
	_github_btn = _add_button(buttons, "GitHubButton", _GITHUB_TEXT, _on_github_pressed)
	_store_btn = _add_button(buttons, "AssetStoreButton", _STORE_TEXT, _on_store_pressed)


func _enter_tree() -> void:
	# Connected on every tree entry, not once in _ready, so the badge keeps listening
	# after the editor moves the dock to another slot.
	if _runner != null and not _runner.state_changed.is_connected(refresh):
		_runner.state_changed.connect(refresh)
	if _installer != null and not _installer.state_changed.is_connected(_on_installer_state_changed):
		_installer.state_changed.connect(_on_installer_state_changed)
	# Catch anything that changed while the badge was out of the tree; a release
	# already installable here was shown before, so it gets no toast.
	refresh()
	_note_installable(false)


# The runner and the installer outlive the badge; a callback left connected would
# keep repainting a badge that has left the dock.
func _exit_tree() -> void:
	if _runner != null and is_instance_valid(_runner) and _runner.state_changed.is_connected(refresh):
		_runner.state_changed.disconnect(refresh)
	if _installer != null and is_instance_valid(_installer) and _installer.state_changed.is_connected(_on_installer_state_changed):
		_installer.state_changed.disconnect(_on_installer_state_changed)


## Re-renders the badge: the last install's result, the newer version, or hidden.
func refresh() -> void:
	var notice: Dictionary = _installer.notice() if _installer != null else {}
	_showing_notice = not notice.is_empty()
	if _showing_notice:
		_render_notice(notice)
		return
	_shown_version = _runner.badge_version() if _runner != null else ""
	visible = not _shown_version.is_empty()
	if not visible:
		return
	_render_version()


func _render_version() -> void:
	var major := _runner.is_major()
	add_theme_stylebox_override("panel", _major_style if major else _minor_style)
	_major_icon.visible = major
	_set_title((_MAJOR_TITLE if major else _MINOR_TITLE) % _shown_version, major)
	_dismiss_btn.tooltip_text = _DISMISS_TOOLTIP
	_github_btn.text = _GITHUB_TEXT
	_github_btn.visible = true
	_store_btn.visible = true

	var listed := _runner.is_store_listed()
	_store_btn.disabled = not listed
	_store_btn.text = _STORE_TEXT if listed else _STORE_UNLISTED_TEXT
	_store_btn.tooltip_text = "" if listed else _STORE_UNLISTED_TOOLTIP

	var last_check := _runner.last_check_unix()
	tooltip_text = _LAST_CHECKED_TOOLTIP % _local_date(last_check) if last_check > 0 else ""
	_render_install_state()


# The install row for the version on display: what the installer is doing with it.
func _render_install_state() -> void:
	var state: String = _installer.state() if _installer != null else UpdateInstaller.IDLE
	var about_shown: bool = _installer != null and _installer.version() == _shown_version
	if not about_shown:
		state = UpdateInstaller.IDLE
	var status := ""
	match state:
		UpdateInstaller.AVAILABLE:
			var changed: PackedStringArray = _installer.changed_files()
			if not changed.is_empty():
				status = _CHANGED_TEXT % changed.size()
		UpdateInstaller.DOWNLOADING:
			status = _DOWNLOADING_TEXT % _shown_version
		UpdateInstaller.READY:
			status = _READY_TEXT % _shown_version
		UpdateInstaller.FAILED:
			status = _FAILED_TEXT % _installer.error_text()
		_:
			status = _installer.note_text() if about_shown else ""
	_set_status(status)
	_update_btn.visible = state == UpdateInstaller.AVAILABLE or state == UpdateInstaller.FAILED
	_update_btn.text = _RETRY_TEXT if state == UpdateInstaller.FAILED else _UPDATE_TEXT
	_restart_btn.visible = state == UpdateInstaller.READY
	_discard_btn.visible = state == UpdateInstaller.READY
	_update_mcp_json_btn.visible = false


func _render_notice(notice: Dictionary) -> void:
	visible = true
	var updated := str(notice.get("kind", "")) == UpdateInstaller.NOTICE_UPDATED
	_shown_version = str(notice.get("version", ""))
	add_theme_stylebox_override("panel", _minor_style if updated else _failed_style)
	_major_icon.visible = false
	_set_title((_UPDATED_TITLE if updated else _FAILED_TITLE) % _shown_version, false)
	var mcp_json_behind := updated and bool(notice.get("server_changed", false)) \
			and _write_flow != null and _write_flow.written_entry_outdated()
	if updated:
		_set_status(_SERVER_CHANGED_TEXT % VersionUtils.COMPATIBLE_SERVER_VERSION if mcp_json_behind else "")
	else:
		_set_status(_NOT_INSTALLED_TEXT % [_sentence(str(notice.get("reason", ""))),
				str(notice.get("from_version", "")), _installer.log_path()])
	_dismiss_btn.tooltip_text = _NOTICE_DISMISS_TOOLTIP
	tooltip_text = ""
	_github_btn.text = _WHATS_NEW_TEXT
	_github_btn.visible = updated
	_store_btn.visible = false
	_update_btn.visible = false
	_restart_btn.visible = false
	_discard_btn.visible = false
	_update_mcp_json_btn.visible = mcp_json_behind


func _set_title(text: String, bold: bool) -> void:
	_title.text = text
	var font := _bold_font if bold else _regular_font
	if font != null:
		_title.add_theme_font_override("font", font)


func _set_status(text: String) -> void:
	_status.text = text
	_status.visible = not text.is_empty()


func _on_update_pressed() -> void:
	if _installer != null:
		_installer.install()


func _on_restart_pressed() -> void:
	if _installer != null:
		_installer.restart_now()


func _on_discard_pressed() -> void:
	if _installer != null:
		_installer.discard()


func _on_update_mcp_json_pressed() -> void:
	if _write_flow != null:
		_write_flow.write(false, _on_mcp_json_written, MCPJsonWriteFlow.server_change_body(
				_UPDATE_SERVER_QUESTION % VersionUtils.COMPATIBLE_SERVER_VERSION))


# The write flow's (ok, message, severity, tooltip) report: a toast, and on success
# the notice drops its server line.
func _on_mcp_json_written(ok: bool, message: String, severity: int, tooltip: String) -> void:
	if _toast.is_valid():
		_toast.call(message, severity, tooltip)
	if ok:
		refresh()


func _on_installer_state_changed() -> void:
	refresh()
	# Deferred, so a state the installer passes through on its way (a verified
	# release the automatic mode downloads at once) is not announced. A release an
	# earlier session found gets no toast: the editor-start window covers it.
	call_deferred("_note_installable", _installer.found_this_session())


# Marks the version on display as announced once the installer can install it, with
# a toast when `announce` is set.
func _note_installable(announce: bool) -> void:
	if _showing_notice or _installer == null or _shown_version.is_empty():
		return
	if _installer.version() != _shown_version or _announced_version == _shown_version:
		return
	var text := ""
	match _installer.state():
		UpdateInstaller.AVAILABLE:
			text = _AVAILABLE_TOAST % _shown_version
		UpdateInstaller.READY:
			text = _READY_TOAST % _shown_version
		_:
			return
	_announced_version = _shown_version
	if announce and _toast.is_valid():
		_toast.call(text)


func _on_github_pressed() -> void:
	var url := UpdateCheck.release_page_url(_shown_version)
	if url.begins_with("https://"):
		OS.shell_open(url)


func _on_store_pressed() -> void:
	if Modules.EditorAccess.select_main_screen(_STORE_SCREEN):
		if _toast.is_valid():
			_toast.call(_STORE_TAB_TOAST)
		return
	OS.shell_open(UpdateCheck.STORE_LISTING_URL)


func _on_dismiss_pressed() -> void:
	if _showing_notice:
		_installer.clear_notice()
		return
	if _shown_version.is_empty():
		return
	# Closing a staged update gives it up: the version stays hidden, nothing installs.
	if _installer != null and _installer.state() == UpdateInstaller.READY and _installer.version() == _shown_version:
		_installer.discard()
		return
	if _runner != null:
		_runner.dismiss(_shown_version)


static func _add_button(parent: Control, button_name: String, text: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.name = button_name
	button.text = text
	button.pressed.connect(on_pressed)
	parent.add_child(button)
	return button


# A reason from the installer or the applier starts lowercase; the badge shows it as
# a sentence.
static func _sentence(reason: String) -> String:
	if reason.is_empty():
		return "The update did not install"
	return reason.left(1).to_upper() + reason.substr(1)


static func _editor_icon(editor_theme: Theme, icon_name: String) -> Texture2D:
	return editor_theme.get_icon(icon_name, "EditorIcons") if editor_theme != null else null


static func _make_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 8
	style.content_margin_right = 4
	style.content_margin_top = 4
	style.content_margin_bottom = 6
	return style


# The check's date in the machine's time zone, as YYYY-MM-DD.
static func _local_date(unix_seconds: int) -> String:
	var bias_minutes := int(Time.get_time_zone_from_system().get("bias", 0))
	return Time.get_date_string_from_unix_time(unix_seconds + bias_minutes * 60)
