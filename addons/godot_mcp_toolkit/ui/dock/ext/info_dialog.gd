@tool
extends AcceptDialog
## In-editor Info / Help dialog — read-only presentation of connection state,
## plugin/engine versions, the registered-tool summary, multi-instance support,
## read-only mode, Companion Skills, and reference links.
##
## Lazy-created and owned by the dock. Each show_info() re-reads live server
## state and fully rebuilds the content, so a reused instance always reflects
## the current connection.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const McpJsonSync = Modules.McpJsonSync

# One-time dialog chrome (title/buttons) is installed on first show; the
# scrollable content is cleared and rebuilt on every call.
var _built: bool = false
var _content_root: VBoxContainer = null


## Re-reads live state from the passed server and renders the info panel, then
## pops the dialog centered. Pass the dock's bound MCP server node.
func show_info(server: Node) -> void:
	_ensure_built()

	# Clear any prior content so a reused dialog never stacks old renders.
	for child in _content_root.get_children():
		child.queue_free()

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(500, 400)
	_content_root.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	# -- Connection info --
	_add_info_header(vbox, "Connection")
	if server != null and server.is_listening():
		var port: int = server.get_bound_port()
		var peers: int = server.get_authed_peer_count()
		_add_info_row(vbox, "Address", "127.0.0.1:%d" % port)
		_add_info_row(vbox, "Peers", "%d connected" % peers)
	else:
		_add_info_row(vbox, "Address", "not listening")
	if McpJsonSync.is_read_only():
		_add_info_row(vbox, "Mode", "Read-only (GODOT_MCP_READ_ONLY=1)")

	# -- Version --
	var plugin_ver := Modules.VersionUtils.read_plugin_version()
	var vi := Engine.get_version_info()
	var godot_ver := "%d.%d.%d" % [vi["major"], vi["minor"], vi["patch"]]
	_add_info_row(vbox, "Plugin", "v%s" % plugin_ver)
	_add_info_row(vbox, "Godot", godot_ver)

	# -- Registered tools --
	_add_info_header(vbox, "Registered Tools")
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
		_add_info_row(vbox, "Total", "%d+ tools (plugin-side)" % methods.size())
		var extra_note := Label.new()
		extra_note.text = (
			"Additional tools (LSP, discover_tools, extensions) live in "
			+ "the MCP server and are not listed here.")
		extra_note.add_theme_font_size_override("font_size", 11)
		extra_note.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
		extra_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(extra_note)
		for domain in domain_keys:
			var tools: Array = groups[domain]
			var lbl := Label.new()
			lbl.text = "  %s (%d): %s" % [
				str(domain).capitalize(), tools.size(),
				", ".join(PackedStringArray(tools))]
			lbl.add_theme_font_size_override("font_size", 11)
			lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			vbox.add_child(lbl)
	else:
		_add_info_row(vbox, "Status", "server not ready")

	# -- Multi-instance support --
	_add_info_header(vbox, "Multi-Instance Multiplayer")
	var multi := Label.new()
	multi.text = (
		"A:  Two copies via git worktree — FULLY SUPPORTED\n"
		+ "     Each editor gets its own project root, registry entry, and port.\n\n"
		+ "B:  Built-in multi-instance run (F5 + multiple windows) — MOSTLY SUPPORTED\n"
		+ "     Runtime server available; editor MCP commands limited to the host.\n\n"
		+ "C:  Same directory, two editors — NOT SUPPORTED\n"
		+ "     Port collision and registry overwrite; use Pattern A instead.\n\n"
		+ "See addons/godot_mcp_toolkit/docs/multi-instance.md for full details.")
	multi.add_theme_font_size_override("font_size", 11)
	multi.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(multi)

	# -- Read-only mode --
	_add_info_header(vbox, "Read-Only Mode")
	var readonly_note := Label.new()
	readonly_note.text = (
		"For supervised environments (classrooms, CI, demos).\n"
		+ "Set GODOT_MCP_READ_ONLY=1 in your .mcp.json env to restrict\n"
		+ "the toolkit to read-only tools only. All mutating tools\n"
		+ "(create, delete, write, execute) are hidden from the AI agent.\n"
		+ "Remove GODOT_MCP_READ_ONLY from .mcp.json and reconnect the\n"
		+ "MCP client to restore full access.\n"
		+ "Read-only is applied when the MCP server launches, so changing\n"
		+ "it requires reconnecting the MCP client — existing connections\n"
		+ "keep their current setting until then.")
	readonly_note.add_theme_font_size_override("font_size", 11)
	readonly_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(readonly_note)

	# -- Companion Skills --
	_add_info_header(vbox, "Companion Skills")
	var skills_note := Label.new()
	skills_note.text = (
		"Claude Code skills for common toolkit workflows are bundled\n"
		+ "with the plugin. Click the 'Companion Skills' button in the\n"
		+ "dock to browse them, then copy any skill you want into your\n"
		+ "project's .claude/skills/ directory.")
	skills_note.add_theme_font_size_override("font_size", 11)
	skills_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(skills_note)

	# -- Links --
	_add_info_header(vbox, "Links")
	var links_row := HBoxContainer.new()
	vbox.add_child(links_row)
	for pair in [
		["GitHub", "https://github.com/NPGameDev/godot-mcp-toolkit"],
		["Issues", "https://github.com/NPGameDev/godot-mcp-toolkit/issues"],
		["Server Repo", "https://github.com/NPGameDev/godot-mcp-server"],
		["Contributing", "https://github.com/NPGameDev/godot-mcp-toolkit/blob/main/CONTRIBUTING.md"],
	]:
		var btn := Button.new()
		btn.text = pair[0]
		var url: String = pair[1]
		btn.pressed.connect(func(): OS.shell_open(url))
		links_row.add_child(btn)

	popup_centered()


# Installs the dialog chrome once: title, Close button, and the scrollable
# content root that show_info() repopulates on every call.
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


func _add_info_header(parent: VBoxContainer, title: String) -> void:
	parent.add_child(HSeparator.new())
	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 13)
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
