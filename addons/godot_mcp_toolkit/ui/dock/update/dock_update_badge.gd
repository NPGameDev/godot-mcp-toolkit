@tool
extends PanelContainer
## Dock update badge: the closable dock notice that puts what the update check runner
## and the update installer report in front of the user, with the buttons that act on it.
##
## A dock sub-panel, the dock's first child. It shows a newer toolkit version with the
## install actions the install mode allows, or the result of the last install, and is
## hidden while there is nothing to show (no newer version, the version dismissed, or
## the check turned off). Its status line comes from the badge status module, which
## picks the line for each installer state; the badge renders it. A minor or patch
## release gets a blue panel; a major release a green one with a bold title and an
## editor icon. It offers What's in this update, which opens the version's changelog,
## two places to get the version (neither after a failed security check) and a
## close button that hides it until a newer one, giving up a download or a stage under
## way. On a staged release the close button hides it until the next editor start
## instead, and the exit still installs it.[br]
## [br]
## When the installer has a verified release, the badge adds Update; once the
## release is staged, Restart now and Don't install, and the line saying the
## editor's exit installs it, with the reason when the last exit tried and could not.
## While the installer's ready view is open, the badge shows that view instead: what a
## restart now would lose, Restart and Not now. A release that becomes installable
## during the session is also announced once by a toast. After an editor start that
## installed or failed to install a release, the badge shows that result until it is
## closed, in place of the version notice, with Release notes after an install. When the
## install moved the toolkit's server pin in .mcp.json (see
## [code]ui/mcp_json/server_pin_move.gd[/code]), the notice says so and offers Undo while
## the entry is unchanged; when the move's write failed, it says why and offers Update
## .mcp.json.[br]
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
const UpdateNotice = UpdateInstaller.UpdateNotice
const VersionUtils = Modules.VersionUtils
const MCPJsonWriteFlow := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_write_flow.gd")
const DockUpdateBadgeStatus := preload("res://addons/godot_mcp_toolkit/ui/dock/update/dock_update_badge_status.gd")
const ServerPinMove := preload("res://addons/godot_mcp_toolkit/ui/mcp_json/server_pin_move.gd")

const _MINOR_TITLE := "Godot MCP Toolkit %s is available."
const _MAJOR_TITLE := "Godot MCP Toolkit %s is out. It's a major release, so see what's new before you update."
const _UPDATED_TITLE := "Godot MCP Toolkit was updated to %s."
const _FAILED_TITLE := "Godot MCP Toolkit %s was not installed."
const _GITHUB_TEXT := "Get it on GitHub"
const _DOWNLOAD_TEXT := "Download from GitHub"
const _CHANGELOG_TEXT := "What's in this update"
const _RELEASE_NOTES_TEXT := "Release notes"
const _STORE_TEXT := "Get it on the Asset Store"
const _STORE_UNLISTED_TEXT := "Asset Store (not listed yet)"
const _STORE_UNLISTED_TOOLTIP := "The Asset Store doesn't list this version yet. Use GitHub for now, or check back later."
const _STORE_TAB_TOAST := "Search for \"Godot MCP Toolkit\" in the Asset Store tab."
const _UPDATE_TEXT := "Update"
const _RETRY_TEXT := "Try again"
const _RESTART_TEXT := "Restart now"
const _RESTART_VIEW_TEXT := "Restart"
const _NOT_NOW_TEXT := "Not now"
const _DISCARD_TEXT := "Don't install"
const _DISMISS_TOOLTIP := "Hide until the next version."
const _STAGED_DISMISS_TOOLTIP := "Hide until you next open the editor. The update still installs when you close it."
const _NOTICE_DISMISS_TOOLTIP := "Close."
const _LAST_CHECKED_TOOLTIP := "Last checked: %s. The toolkit checks at most once a day."
const _UPDATE_MCP_JSON_TEXT := "Update .mcp.json"
const _UPDATE_SERVER_QUESTION := "Update the server to %s"
const _UNDO_PIN_MOVE_TEXT := "Undo"
const _UNDO_PIN_MOVE_TOOLTIP := "Put .mcp.json back to server %s. Only works until the file is changed."
const _AVAILABLE_TOAST := "Godot MCP Toolkit %s is available. Update it from the MCP Toolkit dock."
const _READY_TOAST := "Godot MCP Toolkit %s installs when you close the editor."
const _RESTART_TOOLTIP := "Restarts the editor, which installs the update on its way out. Save your work first."

# The main-screen tab the 4.7+ editor names its store.
const _STORE_SCREEN := "Asset Store"

const _MINOR_COLOR := Color(0.13, 0.25, 0.42)
const _MAJOR_COLOR := Color(0.11, 0.32, 0.17)
const _FAILED_COLOR := Color(0.42, 0.14, 0.13)
const _TEXT_COLOR := Color(0.95, 0.95, 0.95)

var _runner: UpdateCheckRunner = null
var _installer: UpdateInstaller = null
var _write_flow: MCPJsonWriteFlow = null
var _pin_move: ServerPinMove = null
# Dock-supplied toast sink (msg, severity, tooltip), so the badge needs no toaster.
var _toast: Callable = Callable()
# The version on display; the close button dismisses exactly this one.
var _shown_version: String = ""
# Whether the badge shows the last install's result rather than a version.
var _showing_notice: bool = false
# The last version the badge showed as installable, so each release is announced
# once, and never one the badge already showed.
var _announced_version: String = ""
# The staged version the close button hid. It lives only as long as the badge, so the
# notice is back at the next editor start, when the exit has not installed it.
var _hidden_staged_version: String = ""

var _minor_style: StyleBoxFlat = null
var _major_style: StyleBoxFlat = null
var _failed_style: StyleBoxFlat = null
var _major_icon: TextureRect = null
var _title: Label = null
var _status: Label = null
var _update_btn: Button = null
var _restart_btn: Button = null
var _not_now_btn: Button = null
var _discard_btn: Button = null
var _update_mcp_json_btn: Button = null
var _undo_pin_move_btn: Button = null
var _changelog_btn: Button = null
var _github_btn: Button = null
var _store_btn: Button = null
var _dismiss_btn: Button = null
var _regular_font: Font = null
var _bold_font: Font = null


## [param installer] may be [code]null[/code]: the badge then only links, as before
## the installer existed. [param write_flow] is the shared .mcp.json write flow, or
## [code]null[/code] to leave .mcp.json to the dock's section. [param pin_move] is this
## start's .mcp.json pin move, or [code]null[/code] when the notice reports none.
func _init(
		runner: UpdateCheckRunner, installer: UpdateInstaller, write_flow: MCPJsonWriteFlow,
		toast: Callable, pin_move: ServerPinMove = null) -> void:
	_runner = runner
	_installer = installer
	_write_flow = write_flow
	_toast = toast
	_pin_move = pin_move
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
	_not_now_btn = _add_button(buttons, "NotNowButton", _NOT_NOW_TEXT, _on_not_now_pressed)
	_discard_btn = _add_button(buttons, "DiscardButton", _DISCARD_TEXT, _on_discard_pressed)
	_update_mcp_json_btn = _add_button(
			buttons, "UpdateMcpJsonButton", _UPDATE_MCP_JSON_TEXT, _on_update_mcp_json_pressed)
	_undo_pin_move_btn = _add_button(
			buttons, "UndoPinMoveButton", _UNDO_PIN_MOVE_TEXT, _on_undo_pin_move_pressed)
	_changelog_btn = _add_button(buttons, "ChangelogButton", _CHANGELOG_TEXT, _on_changelog_pressed)
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
	_shown_version = _version_to_show()
	visible = not _shown_version.is_empty()
	if not visible:
		return
	_render_version()


# A staged release is what the editor's exit installs, so it is what the badge is about,
# whichever newer version the runner reports.
func _version_to_show() -> String:
	if _installer != null and _installer.state() == UpdateInstaller.READY:
		if _installer.version() == _hidden_staged_version:
			return ""
		return _installer.version()
	return _runner.badge_version() if _runner != null else ""


# Whether the version on display is the staged one, which the close button hides for
# this session only.
func _staged_on_display() -> bool:
	return _installer != null and _installer.state() == UpdateInstaller.READY \
			and _installer.version() == _shown_version


# Whether the installer is downloading or staging the version on display.
func _attempt_on_display() -> bool:
	if _installer == null or _installer.version() != _shown_version:
		return false
	var state: String = _installer.state()
	return state == UpdateInstaller.DOWNLOADING or state == UpdateInstaller.PREPARING


func _render_version() -> void:
	var major := _runner.is_major() and _shown_version == _runner.badge_version()
	add_theme_stylebox_override("panel", _major_style if major else _minor_style)
	_major_icon.visible = major
	_set_title((_MAJOR_TITLE if major else _MINOR_TITLE) % _shown_version, major)
	_dismiss_btn.tooltip_text = _STAGED_DISMISS_TOOLTIP if _staged_on_display() else _DISMISS_TOOLTIP
	_changelog_btn.visible = true
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
	var view: Dictionary = _installer.ready_view() if state == UpdateInstaller.READY else {}
	var facts := {DockUpdateBadgeStatus.VIEW: view}
	if about_shown:
		facts[DockUpdateBadgeStatus.CHANGED] = _installer.changed_files().size()
		facts[DockUpdateBadgeStatus.ERROR] = _installer.error_text()
		facts[DockUpdateBadgeStatus.NOTE] = _installer.note_text()
		facts[DockUpdateBadgeStatus.POSTPONED] = _installer.postponed_reason()
	_set_status(DockUpdateBadgeStatus.install_line(state, _shown_version, facts))
	var check_failed: bool = about_shown and state == UpdateInstaller.IDLE and _installer.check_failed()
	_update_btn.visible = state == UpdateInstaller.AVAILABLE or state == UpdateInstaller.FAILED \
			or (check_failed and _installer.can_retry_check())
	_update_btn.text = _RETRY_TEXT if state == UpdateInstaller.FAILED else _UPDATE_TEXT
	_github_btn.text = _DOWNLOAD_TEXT if check_failed else _GITHUB_TEXT
	var refused: bool = check_failed and _installer.security_check_failed()
	# The sentence says it won't install; these would open the release it refused or the
	# store's copy of it, which the chain did not check.
	_github_btn.visible = not refused
	_store_btn.visible = not refused
	_restart_btn.visible = state == UpdateInstaller.READY
	# The view's lines say "click Restart", so the button they name reads the same.
	_restart_btn.text = _RESTART_TEXT if view.is_empty() else _RESTART_VIEW_TEXT
	_not_now_btn.visible = not view.is_empty()
	_discard_btn.visible = state == UpdateInstaller.READY
	_update_mcp_json_btn.visible = false
	_undo_pin_move_btn.visible = false


func _render_notice(notice: Dictionary) -> void:
	visible = true
	var updated := str(notice.get(UpdateNotice.KIND, "")) == UpdateNotice.UPDATED
	_shown_version = str(notice.get(UpdateNotice.VERSION, ""))
	add_theme_stylebox_override("panel", _minor_style if updated else _failed_style)
	_major_icon.visible = false
	_set_title((_UPDATED_TITLE if updated else _FAILED_TITLE) % _shown_version, false)
	var pin_move := _pin_move_to_report(notice)
	var pin_state := str(pin_move.get("state", ServerPinMove.NONE))
	_set_status(DockUpdateBadgeStatus.notice_line(notice, _installer.log_path(), pin_move))
	_dismiss_btn.tooltip_text = _NOTICE_DISMISS_TOOLTIP
	tooltip_text = ""
	_changelog_btn.visible = false
	_github_btn.text = _RELEASE_NOTES_TEXT
	_github_btn.visible = updated
	_store_btn.visible = false
	_update_btn.visible = false
	_restart_btn.visible = false
	_not_now_btn.visible = false
	_discard_btn.visible = false
	_update_mcp_json_btn.visible = pin_state == ServerPinMove.WRITE_FAILED and _write_flow != null
	_undo_pin_move_btn.visible = pin_state == ServerPinMove.MOVED and _pin_move.can_undo()
	_undo_pin_move_btn.tooltip_text = _UNDO_PIN_MOVE_TOOLTIP % str(pin_move.get("from_version", ""))


# The pin move outcome the notice reports: the move after an install that changed the
# recommended server, or its failed write while writing the entry is still the fix;
# an empty dictionary otherwise.
func _pin_move_to_report(notice: Dictionary) -> Dictionary:
	if _pin_move == null or str(notice.get(UpdateNotice.KIND, "")) != UpdateNotice.UPDATED \
			or not bool(notice.get(UpdateNotice.SERVER_CHANGED, false)):
		return {}
	var outcome := _pin_move.outcome()
	if str(outcome["state"]) == ServerPinMove.WRITE_FAILED and not _pin_move.can_retry():
		return {}
	return outcome


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


func _on_not_now_pressed() -> void:
	if _installer != null:
		_installer.close_ready_view()


func _on_discard_pressed() -> void:
	if _installer != null:
		_installer.discard()


func _on_update_mcp_json_pressed() -> void:
	if _write_flow != null:
		_write_flow.write(false, _on_mcp_json_written, MCPJsonWriteFlow.server_change_body(
				_UPDATE_SERVER_QUESTION % VersionUtils.COMPATIBLE_SERVER_VERSION))


# A done Undo re-renders through its report; a refused one reports ok = false, which
# does not, so this re-render is what hides Undo once the entry changed.
func _on_undo_pin_move_pressed() -> void:
	if _pin_move == null:
		return
	_pin_move.undo(_on_mcp_json_written)
	refresh()


# A .mcp.json write's (ok, message, severity, tooltip) report: a toast, and on success
# the notice drops its server line.
func _on_mcp_json_written(ok: bool, message: String, severity: int, tooltip: String) -> void:
	if _toast.is_valid():
		_toast.call(message, severity, tooltip)
	if ok:
		refresh()


func _on_installer_state_changed() -> void:
	# The close button hides one staged update. Once that stage is gone, a later stage of
	# the same version is one the user asked for again, so it shows.
	if _installer.state() != UpdateInstaller.READY:
		_hidden_staged_version = ""
	refresh()
	# Deferred, so a state the installer passes through on its way is not announced.
	# A release an earlier session found gets no toast: the editor-start window
	# covers it.
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


func _on_changelog_pressed() -> void:
	_open_link(UpdateCheck.changelog_url(_shown_version))


func _on_github_pressed() -> void:
	_open_link(UpdateCheck.release_page_url(_shown_version))


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
	# The editor's exit still installs a staged update, so closing it only hides it for
	# this session. Dismissing the version in the runner would keep the badge away after
	# the next start too, and Don't install is the way to give the update up.
	if _staged_on_display():
		_hidden_staged_version = _shown_version
		refresh()
		return
	# Closing during an attempt gives the attempt up, so the close keeps its word: hidden
	# until the next version. discard() also dismisses the version at the runner.
	if _attempt_on_display():
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


# Opens a link built from the version on display; a version that names no release
# gives an empty one, which opens nothing.
static func _open_link(url: String) -> void:
	if url.begins_with("https://"):
		OS.shell_open(url)


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
