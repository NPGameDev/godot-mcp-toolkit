@tool
extends Window
## In-editor extension catalog dialog — fetches and displays curated
## MCP Toolkit extensions from a public GitHub Gist. Discovery only.

const ExtensionCatalog := preload("res://addons/godot_mcp_toolkit/ui/dock/ext/extension_catalog.gd")
const EditorPopup := preload("res://addons/godot_mcp_toolkit/ui/editor_popup.gd")

var _http: HTTPRequest = null
var _list_vbox: VBoxContainer = null
var _search_box: LineEdit = null
var _status_label: Label = null
var _update_msg: Label = null
var _trust_dialog: ConfirmationDialog = null
var _entries: Array = []
var _toolkit_version: String = ""
var _godot_version: String = ""


func _ready() -> void:
	title = "MCP Toolkit Extensions"
	exclusive = false
	min_size = Vector2i(580, 460)
	close_requested.connect(hide)

	_toolkit_version = ExtensionCatalog.get_toolkit_version()
	_godot_version = ExtensionCatalog.get_godot_version()

	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)

	_build_ui()


func _exit_tree() -> void:
	if _http != null:
		_http.cancel_request()
	# The trust dialog is a base-control child (not in this dialog's subtree), so
	# it is not freed with this dialog. Free it immediately (not queue_free) if it
	# is still open, so its reference chain is released before ObjectDB's exit-time
	# leak check runs — same teardown convention as the dock/server.
	if _trust_dialog != null and is_instance_valid(_trust_dialog):
		_trust_dialog.free()
	_trust_dialog = null


## Public entry point — called from dock or submenu.
func show_catalog() -> void:
	# Open centered and raised — a non-exclusive dialog otherwise sinks behind the
	# viewport, leaving the "Extensions" button feeling dead on the next click.
	EditorPopup.present(self, Vector2i(640, 520))
	_fetch_catalog()


# -- UI construction ----------------------------------------------------------


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	margin.add_child(outer)

	# Header
	var header := Label.new()
	header.text = "Discover extensions that add new MCP tools to the Godot MCP Toolkit."
	header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(header)

	var assetlib_note := Label.new()
	assetlib_note.text = (
		"Extensions may also be available on the Godot Asset Library "
		+ "\u2014 search for \"MCP Toolkit\".")
	assetlib_note.add_theme_font_size_override("font_size", 11)
	assetlib_note.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	assetlib_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(assetlib_note)

	# Update message (hidden by default, shown when catalog format is newer)
	_update_msg = Label.new()
	_update_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_update_msg.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	_update_msg.visible = false
	outer.add_child(_update_msg)

	# Search box (hidden until list is populated)
	_search_box = LineEdit.new()
	_search_box.placeholder_text = "Search extensions..."
	_search_box.clear_button_enabled = true
	_search_box.text_changed.connect(_on_search_changed)
	_search_box.visible = false
	outer.add_child(_search_box)

	# Scrollable extension list
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	_list_vbox = VBoxContainer.new()
	_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_vbox.add_theme_constant_override("separation", 12)
	scroll.add_child(_list_vbox)

	# Build-your-own section — extend the toolkit, don't just browse the catalog.
	outer.add_child(HSeparator.new())
	var extend_label := Label.new()
	extend_label.text = (
		"Want more than the catalog? You can build your own extensions — "
		+ "addons that add custom MCP tools. Read the Extending guide, or use the "
		+ "'mcp-extension-creator' Companion Skill to scaffold one with your AI "
		+ "assistant.")
	extend_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	extend_label.add_theme_font_size_override("font_size", 11)
	outer.add_child(extend_label)

	var extend_btn := Button.new()
	extend_btn.text = "Open Extending Guide"
	var guide_path := "res://addons/godot_mcp_toolkit/docs/extending.md"
	extend_btn.pressed.connect(func(): OS.shell_open(ProjectSettings.globalize_path(guide_path)))
	outer.add_child(extend_btn)

	# Footer — cache status + refresh button
	var footer := HBoxContainer.new()
	outer.add_child(footer)

	_status_label = Label.new()
	_status_label.text = ""
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(_status_label)

	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh"
	refresh_btn.pressed.connect(_fetch_catalog)
	footer.add_child(refresh_btn)


# -- Fetch / parse / cache ----------------------------------------------------


func _fetch_catalog() -> void:
	if _http == null:
		return
	_http.cancel_request()
	_status_label.text = "Fetching catalog..."
	_update_msg.visible = false

	var err := _http.request(ExtensionCatalog.CATALOG_URL)
	if err != OK:
		push_warning("[MCPCatalog] HTTP request failed to start (err %d)" % err)
		_load_from_cache("Network error \u2014 showing cached catalog")


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		var code := response_code if result == HTTPRequest.RESULT_SUCCESS else result
		_load_from_cache("Fetch failed (%d) \u2014 showing cached catalog" % code)
		return

	var json_text := body.get_string_from_utf8()
	var parsed := ExtensionCatalog.parse_catalog(json_text)

	if not parsed["ok"]:
		if str(parsed["error"]) == "NEWER_VERSION":
			_update_msg.text = (
				"The catalog format has been updated. Please update the "
				+ "MCP Toolkit plugin to see the latest extensions.")
			_update_msg.visible = true
			# Do NOT cache incompatible response.
			_load_from_cache("Catalog format newer than supported \u2014 showing cached catalog")
			return
		_load_from_cache("Parse error \u2014 showing cached catalog")
		return

	# Success — cache the raw JSON and populate.
	var raw = JSON.parse_string(json_text)
	if raw is Dictionary:
		ExtensionCatalog.write_cache(raw)
	_entries = parsed["extensions"]
	_populate_list(_entries)
	_set_status("Catalog loaded \u2014 %d extension%s" % [
		_entries.size(), "" if _entries.size() == 1 else "s"], false)


func _load_from_cache(warning: String) -> void:
	var cached := ExtensionCatalog.read_cache()
	if cached.is_empty():
		_clear_list()
		_show_message("Catalog unavailable \u2014 check your internet connection and try again.")
		_set_status(warning if not warning.is_empty() else "No catalog available", true)
		return

	var parsed := ExtensionCatalog.parse_catalog(JSON.stringify(cached))
	if not parsed["ok"]:
		_clear_list()
		_show_message("Catalog unavailable \u2014 cached data is invalid.")
		_set_status("Cache error", true)
		return

	_entries = parsed["extensions"]
	_populate_list(_entries)
	var cached_at: String = str(cached.get("_cached_at", "unknown"))
	_set_status("%s (cached %s)" % [warning, cached_at], true)


func _set_status(text: String, is_warning: bool) -> void:
	_status_label.text = text
	if is_warning:
		_status_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	else:
		_status_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))


# -- List rendering -----------------------------------------------------------


func _clear_list() -> void:
	for child in _list_vbox.get_children():
		child.queue_free()
	_search_box.visible = false
	_search_box.text = ""


func _show_message(text: String) -> void:
	_clear_list()
	var lbl := Label.new()
	lbl.text = text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	_list_vbox.add_child(lbl)


func _populate_list(extensions: Array) -> void:
	_clear_list()

	if extensions.is_empty():
		_show_message("No extensions available yet. Check back later!")
		return

	_search_box.visible = true

	for ext in extensions:
		if not ext is Dictionary:
			continue
		_list_vbox.add_child(_build_entry_card(ext))


func _build_entry_card(ext: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.18, 0.18, 0.18)
	style.border_color = Color(0.3, 0.3, 0.3)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	card.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	card.add_child(vbox)

	# Row 1: Name + Author + Status badge
	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)

	var name_label := Label.new()
	name_label.text = str(ext.get("name", "Unknown"))
	name_label.add_theme_font_size_override("font_size", 14)
	title_row.add_child(name_label)

	var author_label := Label.new()
	author_label.text = "  by %s" % str(ext.get("author", "Unknown"))
	author_label.add_theme_font_size_override("font_size", 12)
	author_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	title_row.add_child(author_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(spacer)

	# Compat badge — next to name for immediate scan
	var compat := ExtensionCatalog.is_compatible(ext, _toolkit_version, _godot_version)
	var compat_label := Label.new()
	if compat:
		compat_label.text = "\u2713 Compatible"
		compat_label.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3))
	else:
		compat_label.text = "\u26a0 Check version"
		compat_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	compat_label.add_theme_font_size_override("font_size", 11)
	title_row.add_child(compat_label)

	# Status badge (green=official, blue=community, orange=experimental)
	var status: String = str(ext.get("status", "community"))
	var status_label := Label.new()
	status_label.text = "  %s" % status.capitalize()
	status_label.add_theme_font_size_override("font_size", 11)
	match status:
		"official":
			status_label.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3))
		"community":
			status_label.add_theme_color_override("font_color", Color(0.4, 0.7, 1.0))
		"experimental":
			status_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.3))
		_:
			status_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	title_row.add_child(status_label)

	# Description
	var desc_label := Label.new()
	desc_label.text = str(ext.get("description", ""))
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.add_theme_font_size_override("font_size", 12)
	vbox.add_child(desc_label)

	# Tools list (if present) — collapsible, collapsed by default
	var tools = ext.get("tools", [])
	if tools is Array and not tools.is_empty():
		var tools_toggle := Button.new()
		tools_toggle.flat = true
		tools_toggle.text = "\u25b6 Tools (%d)" % tools.size()
		tools_toggle.add_theme_font_size_override("font_size", 11)
		tools_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
		vbox.add_child(tools_toggle)

		var tools_container := VBoxContainer.new()
		tools_container.visible = false
		vbox.add_child(tools_container)

		for tool_entry in tools:
			if not tool_entry is Dictionary:
				continue
			var tool_line := Label.new()
			var tool_name: String = str(tool_entry.get("name", ""))
			var tool_desc: String = str(tool_entry.get("description", ""))
			if tool_desc.is_empty():
				tool_line.text = "    %s" % tool_name
			else:
				tool_line.text = "    %s \u2014 %s" % [tool_name, tool_desc]
			tool_line.add_theme_font_size_override("font_size", 11)
			tool_line.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
			tool_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			tools_container.add_child(tool_line)

		tools_toggle.pressed.connect(func():
			tools_container.visible = not tools_container.visible
			tools_toggle.text = "%s Tools (%d)" % [
				"\u25bc" if tools_container.visible else "\u25b6", tools.size()]
		)

	# Install instructions — expandable if present, fallback text if absent
	var raw_install = ext.get("install_instructions", null)
	var has_install: bool = raw_install != null and raw_install is String and not raw_install.strip_edges().is_empty()
	if has_install:
		var install_toggle := Button.new()
		install_toggle.flat = true
		install_toggle.text = "\u25b6 Install instructions"
		install_toggle.add_theme_font_size_override("font_size", 11)
		install_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
		vbox.add_child(install_toggle)

		var install_label := Label.new()
		install_label.text = str(raw_install)
		install_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		install_label.add_theme_font_size_override("font_size", 11)
		install_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
		install_label.visible = false
		vbox.add_child(install_label)

		install_toggle.pressed.connect(func():
			install_label.visible = not install_label.visible
			install_toggle.text = "%s Install instructions" % (
				"\u25bc" if install_label.visible else "\u25b6")
		)
	else:
		var install_note := Label.new()
		install_note.text = "See the repo's README for install instructions."
		install_note.add_theme_font_size_override("font_size", 11)
		install_note.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
		vbox.add_child(install_note)

	# "View on GitHub" button
	var repo_url: String = str(ext.get("repo_url", ""))
	if not repo_url.is_empty():
		var gh_btn := Button.new()
		gh_btn.text = "View on GitHub"
		gh_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		var s := status
		var url := repo_url
		gh_btn.pressed.connect(func(): _on_view_github(url, s))
		vbox.add_child(gh_btn)

	# Store metadata for search filtering
	card.set_meta("ext_name", str(ext.get("name", "")))
	card.set_meta("ext_description", str(ext.get("description", "")))
	card.set_meta("ext_author", str(ext.get("author", "")))
	card.set_meta("ext_tags", str(ext.get("tags", [])))

	return card


# -- Search filter ------------------------------------------------------------


func _on_search_changed(query: String) -> void:
	var q := query.strip_edges().to_lower()
	for child in _list_vbox.get_children():
		if not child is PanelContainer:
			continue
		if q.is_empty():
			child.visible = true
			continue
		var name_str: String = child.get_meta("ext_name", "").to_lower()
		var desc_str: String = child.get_meta("ext_description", "").to_lower()
		var author_str: String = child.get_meta("ext_author", "").to_lower()
		var tags_str: String = child.get_meta("ext_tags", "").to_lower()
		child.visible = (
			q in name_str or q in desc_str or q in author_str or q in tags_str)


# -- Trust warning + GitHub open ----------------------------------------------


## Surface a blocked-URL refusal through the footer status line (the dialog's
## existing visible feedback channel) and the editor log.
func _refuse_repo_url() -> void:
	var msg := "Refusing to open a non-https repository URL."
	push_warning("[MCPCatalog] %s" % msg)
	_set_status(msg, true)


func _on_view_github(repo_url: String, status: String) -> void:
	# repo_url comes from the remote catalog Gist (untrusted) and flows into a
	# shell sink — only open an https:// URL, for every status including official.
	if not ExtensionCatalog.is_allowed_repo_url(repo_url):
		_refuse_repo_url()
		return

	if status == "official":
		OS.shell_open(repo_url)
		return

	# Trust warning for community/experimental extensions.
	if _trust_dialog != null and is_instance_valid(_trust_dialog):
		_trust_dialog.queue_free()
		_trust_dialog = null

	_trust_dialog = ConfirmationDialog.new()
	_trust_dialog.exclusive = false
	_trust_dialog.title = "Open External Repository"

	var warn_text: String
	if status == "experimental":
		warn_text = (
			"This is an experimental extension and may be unstable, "
			+ "incomplete, or introduce breaking changes.\n\n"
			+ "Use at your own risk.")
	else:
		warn_text = (
			"This is a community extension and has not been fully vetted "
			+ "by the MCP Toolkit maintainers.\n\n"
			+ "Review the source code before installing.")

	_trust_dialog.dialog_text = warn_text
	_trust_dialog.ok_button_text = "Open Repo"
	var url := repo_url
	_trust_dialog.confirmed.connect(func():
		# Re-check at the sink (defence in depth): the scheme gate guards every
		# path to shell_open, not only the official fast-path above.
		if ExtensionCatalog.is_allowed_repo_url(url):
			OS.shell_open(url)
		else:
			_refuse_repo_url()
		_trust_dialog.queue_free()
		_trust_dialog = null
	)
	_trust_dialog.canceled.connect(func():
		_trust_dialog.queue_free()
		_trust_dialog = null
	)
	EditorInterface.get_base_control().add_child(_trust_dialog)
	_trust_dialog.popup_centered()
