@tool
extends AcceptDialog
## In-editor Info / Help dialog — read-only presentation of connection state,
## plugin/engine versions, the registered-tool summary, multi-instance support,
## read-only mode, version compatibility, Companion Skills, and reference links.
##
## Lazy-created and owned by the dialog presenter. Each show_info() re-reads live
## server state and fully rebuilds the content, so a reused instance always
## reflects the current connection. The read-only Mode row shows the state the
## caller passes (the dock badge's), so the dialog and the badge agree.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const MCPJsonSync = Modules.MCPJsonSync
const DockSectionCard := preload("res://addons/godot_mcp_toolkit/ui/dock/dock_section_card.gd")
const EditorPopup := preload("res://addons/godot_mcp_toolkit/ui/editor_popup.gd")

const _DEFAULT_SIZE := Vector2i(520, 460)
# The share of the editor window, per axis, the dialog may cover.
const _WINDOW_FRACTION := 0.9

# One-time dialog chrome (title/buttons) is installed on first show; the
# content is cleared and rebuilt on every call.
var _built: bool = false
var _content_root: VBoxContainer = null


## Re-reads live state from the passed server and renders the info panel, then
## pops the dialog centered. Pass the dock's bound MCP server node, and in
## [param read_only_applied] whether the running MCP server applies read-only
## mode (the state the dock's badge shows).
func show_info(server: Node, read_only_applied: bool) -> void:
	_ensure_built()

	# Clear prior content immediately — remove_child (not just queue_free) so the
	# rebuilt dialog's contents-minimum-size reflects only the new content.
	# queue_free alone leaves the old subtree in the tree for the current frame,
	# inflating popup_centered's size on every reopen (the window is grow-only).
	for child in _content_root.get_children():
		_content_root.remove_child(child)
		child.queue_free()

	# Fixed header — Connection + plugin/engine versions, always visible above
	# the collapsible middle.
	var connection := DockSectionCard.make_section("Connection")
	_content_root.add_child(connection)
	var conn: VBoxContainer = connection.get_meta("content")
	if server != null and server.is_listening():
		var port: int = server.get_bound_port()
		var peers: int = server.get_authed_peer_count()
		_add_info_row(conn, "Address", "127.0.0.1:%d" % port)
		_add_info_row(conn, "Peers", "%d connected" % peers)
	else:
		_add_info_row(conn, "Address", "not listening")
	var read_only_lines := describe_read_only_mode(read_only_applied, MCPJsonSync.is_read_only())
	var mode_text := str(read_only_lines["mode"])
	var pending_text := str(read_only_lines["pending"])
	if not mode_text.is_empty():
		_add_info_row(conn, "Mode", mode_text)
	if not pending_text.is_empty():
		# Unwrapped: the Connection card sits outside the scroll, so its height sets
		# the dialog's. A wrapped label measures its height at its width before the
		# first layout, a few pixels, one word per line, and the dialog would open
		# that tall.
		conn.add_child(_make_note_label(pending_text))
	var plugin_ver := Modules.VersionUtils.read_plugin_version()
	var vi := Engine.get_version_info()
	var godot_ver := "%d.%d.%d" % [vi["major"], vi["minor"], vi["patch"]]
	_add_info_row(conn, "Plugin", "v%s" % plugin_ver)
	_add_info_row(conn, "Godot", godot_ver)

	# Collapsible middle — one scroll area between the header and the footer, so
	# an open section is as tall as its content and a long one (Registered Tools)
	# scrolls with the rest. All start collapsed: the header shows the primary state.
	var mid := DockSectionCard.make_scroll_area(_content_root)

	var tools_content := DockSectionCard.make_collapsible(mid, "Registered Tools", false)
	if server != null and server.has_method("get_command_methods"):
		var methods: Array = server.get_command_methods()
		methods.sort()
		var groups: Dictionary = {}
		for method in methods:
			var parts := str(method).split(".", true, 1)
			var domain: String = parts[0] if parts.size() > 0 else "other"
			if not groups.has(domain):
				groups[domain] = []
			groups[domain].append(str(method))
		var domain_keys: Array = groups.keys()
		domain_keys.sort()
		_add_info_row(tools_content, "Total", "%d plugin-side commands" % methods.size())
		_add_note_label(tools_content, (
			"These are the plugin-side commands. The agent-facing tool count is "
			+ "larger and lives in the MCP server (which adds LSP, discover_tools, "
			+ "and extension tools)."), true)
		for domain in domain_keys:
			var tools: Array = groups[domain]
			_add_note_label(tools_content, "  %s (%d): %s" % [
				str(domain).capitalize(), tools.size(),
				", ".join(PackedStringArray(tools))])
	else:
		_add_info_row(tools_content, "Status", "server not ready")

	var multi_content := DockSectionCard.make_collapsible(mid, "Multi-Instance Multiplayer", false)
	_add_note_label(multi_content, (
		"A:  Two copies via git worktree — FULLY SUPPORTED\n"
		+ "     Each editor gets its own project root, registry entry, and port.\n\n"
		+ "B:  Built-in multi-instance run (F5 + multiple windows) — MOSTLY SUPPORTED\n"
		+ "     Runtime server available; editor MCP commands limited to the host.\n\n"
		+ "C:  Same directory, two editors — NOT SUPPORTED\n"
		+ "     Port collision and registry overwrite; use Pattern A instead.\n\n"
		+ "See addons/godot_mcp_toolkit/docs/multi-instance.md for full details."))

	var readonly_content := DockSectionCard.make_collapsible(mid, "Read-Only Mode", false)
	_add_note_label(readonly_content, (
		"For supervised environments (classrooms, CI, demos).\n"
		+ "Set GODOT_MCP_READ_ONLY=1 in your .mcp.json env to restrict\n"
		+ "the toolkit to read-only tools only. All mutating tools\n"
		+ "(create, delete, write, execute) are hidden from the AI agent.\n"
		+ "Remove GODOT_MCP_READ_ONLY from .mcp.json and reconnect the\n"
		+ "MCP client to restore full access.\n"
		+ "Read-only is applied when the MCP server launches, so changing\n"
		+ "it requires reconnecting the MCP client — existing connections\n"
		+ "keep their current setting until then."))

	var compat_content := DockSectionCard.make_collapsible(mid, "Compatibility", false)
	_add_note_label(compat_content, (
		"Supports Godot 4.2 through 4.7 (untested newer versions run\n"
		+ "with a startup warning). Some tools are version-gated, so\n"
		+ "older versions expose fewer. The shipped guide covers\n"
		+ "per-version behavior, headless mode, C# (.NET) requirements,\n"
		+ "and export stripping."))
	var open_compat_btn := Button.new()
	open_compat_btn.text = "Open Compatibility Guide"
	var compat_doc := "res://addons/godot_mcp_toolkit/docs/compatibility.md"
	open_compat_btn.pressed.connect(func(): OS.shell_open(ProjectSettings.globalize_path(compat_doc)))
	compat_content.add_child(open_compat_btn)

	var skills_content := DockSectionCard.make_collapsible(mid, "Companion Skills", false)
	_add_note_label(skills_content, (
		"Companion Skills are SKILL.md 'Agent Skills' — an open standard\n"
		+ "supported by Claude Code, OpenAI Codex, Cursor, and Gemini CLI.\n"
		+ "The plugin bundles skills for common toolkit workflows. Copy a\n"
		+ "skill folder into your client's skills directory:\n"
		+ "    Claude Code: .claude/skills/\n"
		+ "    OpenAI Codex: ~/.agents/skills/\n"
		+ "    Cursor: .cursor/skills/\n"
		+ "    Gemini CLI: .gemini/skills/  (or .agents/skills/)\n"
		+ "Paths follow each client's own docs and can change over time.\n"
		+ "The dock's 'Companion Skills' button opens this same folder."))
	var open_skills_btn := Button.new()
	open_skills_btn.text = "Open Skills Folder"
	var skills_dir := "res://addons/godot_mcp_toolkit/CompanionSkills"
	open_skills_btn.pressed.connect(func(): OS.shell_open(ProjectSettings.globalize_path(skills_dir)))
	skills_content.add_child(open_skills_btn)

	# Fixed footer — reference links, always visible below the middle regardless
	# of scroll position (mirrors the dock footer).
	var footer := PanelContainer.new()
	footer.add_theme_stylebox_override("panel", DockSectionCard.make_section_style())
	footer.size_flags_vertical = Control.SIZE_SHRINK_END
	_content_root.add_child(footer)
	var links_row := HBoxContainer.new()
	footer.add_child(links_row)
	for pair in [
		["Toolkit Repo", "https://github.com/NPGameDev/godot-mcp-toolkit"],
		["Issues", "https://github.com/NPGameDev/godot-mcp-toolkit/issues"],
		["Troubleshooting", "https://github.com/NPGameDev/godot-mcp-toolkit/blob/main/docs/troubleshooting.md"],
		["Contributing", "https://github.com/NPGameDev/godot-mcp-toolkit/blob/main/CONTRIBUTING.md"],
		["Server Repo", "https://github.com/NPGameDev/godot-mcp-server"],
	]:
		var btn := Button.new()
		btn.text = pair[0]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var url: String = pair[1]
		btn.pressed.connect(func(): OS.shell_open(url))
		links_row.add_child(btn)

	# Open at an explicit size and raised (see EditorPopup). The explicit size is
	# load-bearing: a no-arg popup_centered on a reused dialog reuses the window's
	# current size and only grows, so sizing drifts across reopens. The size limits
	# are set on every show, from the editor window's current size, so the Close
	# button stays on screen even when the content asks for more height.
	var limits := fit_to_window(_DEFAULT_SIZE, EditorInterface.get_base_control().get_window().size)
	min_size = limits["min_size"]
	max_size = limits["max_size"]
	EditorPopup.present(self, limits["open"])


## The sizes that keep a dialog wanting [param requested] inside an editor window
## of [param window_size]: at most 90% of the window on each axis. Returns
## [code]{"open": Vector2i, "min_size": Vector2i, "max_size": Vector2i}[/code]:
## the size to open at, and the dialog's minimum and maximum sizes. The minimum is
## never above the maximum, because a window ignores a maximum below its minimum.
static func fit_to_window(requested: Vector2i, window_size: Vector2i) -> Dictionary:
	var cap := Vector2i(int(window_size.x * _WINDOW_FRACTION), int(window_size.y * _WINDOW_FRACTION))
	var open := Vector2i(mini(requested.x, cap.x), mini(requested.y, cap.y))
	return {"open": open, "min_size": open, "max_size": cap}


## The Connection section's read-only lines, from [param applied] (whether the
## running MCP server applies read-only mode, as the dock's badge shows) and
## [param in_file] (whether [code].mcp.json[/code] sets it now). Returns
## [code]{"mode": String, "pending": String}[/code]: the Mode row's text, empty
## for the plain full-access case so the row is left out, and, when the two
## differ, the line saying which way the file changed and when it applies.
## The server reads the setting only at launch, so the file can lead the badge.
static func describe_read_only_mode(applied: bool, in_file: bool) -> Dictionary:
	var mode := ""
	if applied:
		mode = "Read-only (GODOT_MCP_READ_ONLY=1)"
	elif in_file:
		mode = "Full access"
	var pending := ""
	if applied != in_file:
		pending = ".mcp.json now turns read-only mode %s. It takes effect when the MCP client restarts." % (
				"on" if in_file else "off")
	return {"mode": mode, "pending": pending}


# Installs the dialog chrome once: title, Close button, and the content
# root that show_info() repopulates on every call.
func _ensure_built() -> void:
	if _built:
		return
	title = "MCP Toolkit — Info / Help"
	ok_button_text = "Close"
	exclusive = false

	_content_root = VBoxContainer.new()
	_content_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_content_root)

	_built = true


# Adds a small wrapped note label. `dim` renders it at half alpha for a
# secondary aside beneath a primary line.
func _add_note_label(parent: VBoxContainer, text: String, dim := false) -> void:
	var lbl := _make_note_label(text, dim)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(lbl)


# Builds a small note label that keeps its text on unwrapped lines. `dim` renders
# it at half alpha.
func _make_note_label(text: String, dim := false) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 11)
	if dim:
		lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	return lbl


func _add_info_row(parent: VBoxContainer, key: String, value: String) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var k := Label.new()
	k.text = key + ":"
	k.custom_minimum_size.x = 80
	k.add_theme_font_size_override("font_size", 12)
	row.add_child(k)
	var v := Label.new()
	v.text = value
	v.add_theme_font_size_override("font_size", 12)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(v)
