@tool
extends PanelContainer
## Dock update badge: the closable notice that a newer toolkit version is published.
##
## A dock sub-panel, the dock's first child. It renders what the injected update
## check runner reports and is hidden while there is nothing to show (no newer
## version, the version dismissed, or the check turned off). A minor or patch
## release gets a blue panel; a major release a green one with a bold title and an
## editor icon. It offers two places to get the version and a close button that
## hides it until a newer one. It only points at a release: it never downloads or
## installs anything.
##
## "Get it on the Asset Store" switches to the editor's Asset Store tab where the
## editor has one (Godot 4.7+), confirmed through
## [signal EditorPlugin.main_screen_changed], and otherwise opens the store listing
## in the browser. The tab is found by its title, so a translated editor falls back
## to the browser too. Both links are built locally from the version, never taken
## from a reply.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")
const UpdateCheckRunner := preload("res://addons/godot_mcp_toolkit/versioning/update_check_runner.gd")

const _MINOR_TITLE := "Godot MCP Toolkit %s is available."
const _MAJOR_TITLE := "Godot MCP Toolkit %s is out. It's a major release, so see what's new before you update."
const _GITHUB_TEXT := "Get it on GitHub"
const _STORE_TEXT := "Get it on the Asset Store"
const _STORE_UNLISTED_TEXT := "Asset Store (not listed yet)"
const _STORE_UNLISTED_TOOLTIP := "The Asset Store doesn't list this version yet. Use GitHub for now, or check back later."
const _STORE_TAB_TOAST := "Search for \"Godot MCP Toolkit\" in the Asset Store tab."
const _DISMISS_TOOLTIP := "Hide until the next version."
const _LAST_CHECKED_TOOLTIP := "Last checked: %s. The toolkit checks at most once a day."

# The main-screen tab the 4.7+ editor names its store, and the theme variation the
# editor gives its main-screen buttons. set_main_screen_editor reports an unknown
# name as an engine error, so the tab is looked for before the call.
const _STORE_SCREEN := "Asset Store"
const _MAIN_SCREEN_BUTTON_VARIATION := &"MainScreenButton"

const _MINOR_COLOR := Color(0.13, 0.25, 0.42)
const _MAJOR_COLOR := Color(0.11, 0.32, 0.17)
const _TEXT_COLOR := Color(0.95, 0.95, 0.95)

var _runner: UpdateCheckRunner = null
# Dock-supplied toast sink (msg, severity, tooltip), so the badge needs no toaster.
var _toast: Callable = Callable()
# The version on display; the close button dismisses exactly this one.
var _shown_version: String = ""

var _minor_style: StyleBoxFlat = null
var _major_style: StyleBoxFlat = null
var _major_icon: TextureRect = null
var _title: Label = null
var _github_btn: Button = null
var _store_btn: Button = null
var _dismiss_btn: Button = null
var _regular_font: Font = null
var _bold_font: Font = null


func _init(runner: UpdateCheckRunner, toast: Callable) -> void:
	_runner = runner
	_toast = toast
	name = "UpdateBadge"
	visible = false
	var editor_theme := Modules.EditorAccess.get_editor_theme()
	_minor_style = _make_style(_MINOR_COLOR)
	_major_style = _make_style(_MAJOR_COLOR)
	add_theme_stylebox_override("panel", _minor_style)

	var content := VBoxContainer.new()
	content.name = "Content"
	add_child(content)

	var title_row := HBoxContainer.new()
	title_row.name = "TitleRow"
	content.add_child(title_row)

	_major_icon = TextureRect.new()
	_major_icon.name = "MajorIcon"
	_major_icon.texture = editor_theme.get_icon("Favorites", "EditorIcons")
	_major_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_major_icon.visible = false
	title_row.add_child(_major_icon)

	_title = Label.new()
	_title.name = "Title"
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.add_theme_color_override("font_color", _TEXT_COLOR)
	title_row.add_child(_title)
	_regular_font = editor_theme.get_font("main", "EditorFonts")
	_bold_font = editor_theme.get_font("bold", "EditorFonts")

	_dismiss_btn = Button.new()
	_dismiss_btn.name = "DismissButton"
	_dismiss_btn.flat = true
	_dismiss_btn.icon = editor_theme.get_icon("Close", "EditorIcons")
	_dismiss_btn.tooltip_text = _DISMISS_TOOLTIP
	_dismiss_btn.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_dismiss_btn.pressed.connect(_on_dismiss_pressed)
	title_row.add_child(_dismiss_btn)

	# A flow container wraps the two buttons onto two lines in a narrow dock.
	var buttons := HFlowContainer.new()
	buttons.name = "Buttons"
	content.add_child(buttons)

	_github_btn = Button.new()
	_github_btn.name = "GitHubButton"
	_github_btn.text = _GITHUB_TEXT
	_github_btn.pressed.connect(_on_github_pressed)
	buttons.add_child(_github_btn)

	_store_btn = Button.new()
	_store_btn.name = "AssetStoreButton"
	_store_btn.pressed.connect(_on_store_pressed)
	buttons.add_child(_store_btn)


func _ready() -> void:
	if _runner != null and not _runner.state_changed.is_connected(refresh):
		_runner.state_changed.connect(refresh)
	refresh()


func _exit_tree() -> void:
	if _runner != null and is_instance_valid(_runner) and _runner.state_changed.is_connected(refresh):
		_runner.state_changed.disconnect(refresh)


## Re-renders the badge from the runner: shown with the newer version, or hidden.
func refresh() -> void:
	_shown_version = _runner.badge_version() if _runner != null else ""
	visible = not _shown_version.is_empty()
	if not visible:
		return
	var major := _runner.is_major()
	add_theme_stylebox_override("panel", _major_style if major else _minor_style)
	_major_icon.visible = major
	_title.text = (_MAJOR_TITLE if major else _MINOR_TITLE) % _shown_version
	var font := _bold_font if major else _regular_font
	if font != null:
		_title.add_theme_font_override("font", font)

	var listed := _runner.is_store_listed()
	_store_btn.disabled = not listed
	_store_btn.text = _STORE_TEXT if listed else _STORE_UNLISTED_TEXT
	_store_btn.tooltip_text = "" if listed else _STORE_UNLISTED_TOOLTIP

	var last_check := _runner.last_check_unix()
	tooltip_text = _LAST_CHECKED_TOOLTIP % _local_date(last_check) if last_check > 0 else ""


func _on_github_pressed() -> void:
	var url := UpdateCheck.release_page_url(_shown_version)
	if url.begins_with("https://"):
		OS.shell_open(url)


func _on_store_pressed() -> void:
	if _switch_to_store_tab():
		if _toast.is_valid():
			_toast.call(_STORE_TAB_TOAST)
		return
	OS.shell_open(UpdateCheck.STORE_LISTING_URL)


func _on_dismiss_pressed() -> void:
	if _runner != null and not _shown_version.is_empty():
		_runner.dismiss(_shown_version)


# True when the editor now shows its Asset Store tab. Calls set_main_screen_editor
# only when such a tab exists and is not already open, and trusts the switch only
# when main_screen_changed names the tab.
func _switch_to_store_tab() -> bool:
	var plugin := Modules.EditorAccess.get_plugin()
	if plugin == null:
		return false
	var tab_button := _find_store_tab_button()
	if tab_button == null:
		return false
	if tab_button.button_pressed:
		return true
	var switched := [false]
	var on_screen_changed := func(screen_name: String) -> void:
		if screen_name == _STORE_SCREEN:
			switched[0] = true
	plugin.main_screen_changed.connect(on_screen_changed)
	EditorInterface.set_main_screen_editor(_STORE_SCREEN)
	plugin.main_screen_changed.disconnect(on_screen_changed)
	return switched[0]


# The editor's visible main-screen button titled "Asset Store", or null.
func _find_store_tab_button() -> Button:
	var base := EditorInterface.get_base_control()
	if base == null:
		return null
	for node in base.find_children("*", "Button", true, false):
		var button: Button = node
		if (button.text == _STORE_SCREEN and button.visible
				and button.theme_type_variation == _MAIN_SCREEN_BUTTON_VARIATION):
			return button
	return null


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
