@tool
extends AcceptDialog
## In-editor Info / Help dialog — read-only presentation of connection state,
## plugin/engine versions, the registered-tool summary, multi-instance support,
## read-only mode, version compatibility, Companion Skills, and reference links.
##
## Lazy-created and owned by the dock. Each show_info() re-reads live server
## state and fully rebuilds the content, so a reused instance always reflects
## the current connection.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const MCPJsonSync = Modules.MCPJsonSync
const DockSectionCard := preload("res://addons/godot_mcp_toolkit/ui/dock/dock_section_card.gd")
const EditorPopup := preload("res://addons/godot_mcp_toolkit/ui/editor_popup.gd")

# One-time dialog chrome (title/buttons) is installed on first show; the
# content is cleared and rebuilt on every call.
var _built: bool = false
var _content_root: VBoxContainer = null


## Re-reads live state from the passed server and renders the info panel, then
## pops the dialog centered. Pass the dock's bound MCP server node.
func show_info(server: Node) -> void:
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
	# Pin the header at a fixed height — make_section returns SIZE_EXPAND_FILL,
	# which would let the header expand and swallow the collapsible middle.
	connection.size_flags_vertical = 0
	_content_root.add_child(connection)
	var conn: VBoxContainer = connection.get_meta("content")
	if server != null and server.is_listening():
		var port: int = server.get_bound_port()
		var peers: int = server.get_authed_peer_count()
		_add_info_row(conn, "Address", "127.0.0.1:%d" % port)
		_add_info_row(conn, "Peers", "%d connected" % peers)
	else:
		_add_info_row(conn, "Address", "not listening")
	if MCPJsonSync.is_read_only():
		_add_info_row(conn, "Mode", "Read-only (GODOT_MCP_READ_ONLY=1)")
	var plugin_ver := Modules.VersionUtils.read_plugin_version()
	var vi := Engine.get_version_info()
	var godot_ver := "%d.%d.%d" % [vi["major"], vi["minor"], vi["patch"]]
	_add_info_row(conn, "Plugin", "v%s" % plugin_ver)
	_add_info_row(conn, "Godot", godot_ver)

	# Collapsible middle — each section owns its own scroll; all start collapsed
	# (the fixed header already shows the primary state), so no outer scroll.
	var mid := VBoxContainer.new()
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_root.add_child(mid)

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
	# current size and only grows, so sizing drifts across reopens.
	EditorPopup.present(self, Vector2i(520, 460))


# Installs the dialog chrome once: title, Close button, and the content
# root that show_info() repopulates on every call.
func _ensure_built() -> void:
	if _built:
		return
	title = "MCP Toolkit — Info / Help"
	ok_button_text = "Close"
	exclusive = false
	min_size = Vector2i(520, 460)

	_content_root = VBoxContainer.new()
	_content_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_content_root)

	_built = true


# Adds a small wrapped note label. `dim` renders it at half alpha for a
# secondary aside beneath a primary line.
func _add_note_label(parent: VBoxContainer, text: String, dim := false) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 11)
	if dim:
		lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(lbl)


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
