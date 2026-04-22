@tool
extends VBoxContainer
## MCP bottom-panel dock — signal-driven status, polled audit log.
##
## Created and bound by plugin.gd. Signal-driven for server status
## (no polling delay); visibility-gated Timer for audit log tail.

const MCPFeatureRegistry := preload("res://addons/godot_mcp_toolkit/feature_registry.gd")
const MCPFeatureGate := preload("res://addons/godot_mcp_toolkit/feature_gate.gd")
const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")

# Toast severity constants (match EditorToaster.Severity).
const _TOAST_INFO := 0
const _TOAST_WARNING := 1
const _TOAST_ERROR := 2

var _server: Node = null
var _audit_path: String = ""
var _audit_timer: Timer = null

# Status widgets.
var _status_label: Label = null
var _peer_label: Label = null
var _activity_label: Label = null

# Feature rows: { feature_name: { check: CheckBox, sync_icon: Label } }
var _feature_rows: Dictionary = {}
var _power_user_btn: Button = null

# Power User warning.
var _power_user_warning: Label = null


# Settings widgets.
var _script_cap_spinbox: SpinBox = null
var _ws_buffer_spinbox: SpinBox = null

# Info/Help panel widgets.
var _info_scroll: ScrollContainer = null
var _info_container: VBoxContainer = null
var _info_toggle_btn: Button = null
var _connection_label: Label = null
var _profile_label: Label = null
var _tool_count_label: Label = null
var _version_label: Label = null
var _tool_list_container: VBoxContainer = null

# Audit widgets.
var _audit_container: VBoxContainer = null
var _audit_scroll: ScrollContainer = null


func bind(server: Node, audit_path: String) -> void:
	_server = server
	_audit_path = audit_path
	_server.client_connected.connect(_on_client_connected)
	_server.client_disconnected.connect(_on_client_disconnected)
	_server.command_received.connect(_on_command_received)
	_refresh_status()
	_refresh_features()


func _ready() -> void:
	_build_ui()
	visibility_changed.connect(_on_visibility_changed)
	# bind() runs before _ready (node not yet in tree), so its refresh
	# calls exit early on null widgets. Re-run now that UI exists.
	_refresh_features()
	_refresh_status()


func _exit_tree() -> void:
	if _audit_timer != null:
		_audit_timer.stop()


# ---------------------------------------------------------------------------
# UI construction (programmatic — all dynamic content)
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	# -- Status section --
	var status_header := Label.new()
	status_header.text = "Server Status"
	status_header.add_theme_font_size_override("font_size", 14)
	add_child(status_header)

	var status_row := HBoxContainer.new()
	add_child(status_row)

	_status_label = Label.new()
	_status_label.text = "... starting"
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_status_label)

	_peer_label = Label.new()
	_peer_label.text = "0 peers"
	status_row.add_child(_peer_label)

	_activity_label = Label.new()
	_activity_label.text = "Last activity: —"
	add_child(_activity_label)

	_power_user_warning = Label.new()
	_power_user_warning.text = (
		"WARNING: Power User profile active — includes tools that can "
		+ "modify project settings, execute code, and write outside res://.")
	_power_user_warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_power_user_warning.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	_power_user_warning.add_theme_font_size_override("font_size", 11)
	_power_user_warning.visible = false
	add_child(_power_user_warning)

	add_child(HSeparator.new())

	# -- Features section --
	var feat_header := Label.new()
	feat_header.text = "Feature Gates"
	feat_header.add_theme_font_size_override("font_size", 14)
	add_child(feat_header)

	var feat_scroll := ScrollContainer.new()
	feat_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	feat_scroll.custom_minimum_size.y = 120
	add_child(feat_scroll)

	var feat_vbox := VBoxContainer.new()
	feat_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	feat_scroll.add_child(feat_vbox)

	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		var row := HBoxContainer.new()
		feat_vbox.add_child(row)

		var check := CheckBox.new()
		check.text = feature
		check.tooltip_text = str(entry["risk"])
		check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		check.toggled.connect(_on_feature_toggled.bind(feature))
		row.add_child(check)

		var badge := Label.new()
		badge.text = "(dual)" if entry["dual_gate"] else "(single)"
		badge.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		row.add_child(badge)

		var sync_icon := Label.new()
		sync_icon.text = "!"
		sync_icon.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
		sync_icon.visible = false
		sync_icon.tooltip_text = ""
		row.add_child(sync_icon)

		_feature_rows[feature] = {"check": check, "sync_icon": sync_icon}

	_power_user_btn = Button.new()
	_power_user_btn.text = "Enable All (Power User)"
	_power_user_btn.pressed.connect(_on_power_user_pressed)
	feat_vbox.add_child(_power_user_btn)

	add_child(HSeparator.new())

	# -- Settings section (response limits) --
	var settings_header := Label.new()
	settings_header.text = "Response Limits"
	settings_header.add_theme_font_size_override("font_size", 14)
	add_child(settings_header)

	var cap_row := HBoxContainer.new()
	add_child(cap_row)
	var cap_label := Label.new()
	cap_label.text = "Script read cap (KB):"
	cap_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cap_row.add_child(cap_label)
	_script_cap_spinbox = SpinBox.new()
	_script_cap_spinbox.min_value = 64
	_script_cap_spinbox.max_value = 4096
	_script_cap_spinbox.step = 64
	_script_cap_spinbox.value = ProjectSettings.get_setting(
		"mcp_toolkit/limits/script_read_cap_kb", 256)
	_script_cap_spinbox.value_changed.connect(_on_script_cap_changed)
	cap_row.add_child(_script_cap_spinbox)

	var ws_row := HBoxContainer.new()
	add_child(ws_row)
	var ws_label := Label.new()
	ws_label.text = "WebSocket buffer (KB):"
	ws_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ws_row.add_child(ws_label)
	_ws_buffer_spinbox = SpinBox.new()
	_ws_buffer_spinbox.min_value = 256
	_ws_buffer_spinbox.max_value = 8192
	_ws_buffer_spinbox.step = 256
	_ws_buffer_spinbox.value = ProjectSettings.get_setting(
		"mcp_toolkit/limits/ws_buffer_kb", 1024)
	_ws_buffer_spinbox.value_changed.connect(_on_ws_buffer_changed)
	ws_row.add_child(_ws_buffer_spinbox)

	add_child(HSeparator.new())

	# -- Audit section --
	var audit_header := Label.new()
	audit_header.text = "Audit Log (recent)"
	audit_header.add_theme_font_size_override("font_size", 14)
	add_child(audit_header)

	var audit_settings_row := HBoxContainer.new()
	add_child(audit_settings_row)

	var audit_enabled_check := CheckBox.new()
	audit_enabled_check.text = "Enabled"
	audit_enabled_check.button_pressed = ProjectSettings.get_setting(
		"mcp_toolkit/audit/enabled", true)
	audit_enabled_check.toggled.connect(_on_audit_enabled_toggled)
	audit_settings_row.add_child(audit_enabled_check)

	var audit_size_label := Label.new()
	audit_size_label.text = "  Max KB:"
	audit_settings_row.add_child(audit_size_label)

	var audit_size_spin := SpinBox.new()
	audit_size_spin.min_value = 0
	audit_size_spin.max_value = 10240
	audit_size_spin.step = 128
	audit_size_spin.value = ProjectSettings.get_setting(
		"mcp_toolkit/audit/max_size_kb", 1024)
	audit_size_spin.tooltip_text = "0 = unlimited"
	audit_size_spin.value_changed.connect(_on_audit_max_size_changed)
	audit_settings_row.add_child(audit_size_spin)

	_audit_scroll = ScrollContainer.new()
	_audit_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_audit_scroll.custom_minimum_size.y = 80
	add_child(_audit_scroll)

	_audit_container = VBoxContainer.new()
	_audit_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_audit_scroll.add_child(_audit_container)

	var audit_btns := HBoxContainer.new()
	add_child(audit_btns)

	var open_log_btn := Button.new()
	open_log_btn.text = "Open Full Log"
	open_log_btn.pressed.connect(_on_open_audit_log)
	audit_btns.add_child(open_log_btn)

	var clear_btn := Button.new()
	clear_btn.text = "Clear View"
	clear_btn.pressed.connect(_on_clear_audit_view)
	audit_btns.add_child(clear_btn)

	add_child(HSeparator.new())

	# -- Action buttons --
	var action_row := HBoxContainer.new()
	add_child(action_row)

	var regen_btn := Button.new()
	regen_btn.text = "Regenerate Token"
	regen_btn.pressed.connect(_on_regen_token)
	action_row.add_child(regen_btn)

	add_child(HSeparator.new())

	# -- Info / Help section (collapsible) --
	_info_toggle_btn = Button.new()
	_info_toggle_btn.text = "Info / Help [+]"
	_info_toggle_btn.pressed.connect(_on_info_toggle_pressed)
	add_child(_info_toggle_btn)

	_info_scroll = ScrollContainer.new()
	_info_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_info_scroll.visible = false
	add_child(_info_scroll)

	_info_container = VBoxContainer.new()
	_info_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info_scroll.add_child(_info_container)

	_connection_label = Label.new()
	_connection_label.text = "Connection: ..."
	_connection_label.add_theme_font_size_override("font_size", 11)
	_info_container.add_child(_connection_label)

	_profile_label = Label.new()
	_profile_label.text = "Profile: ..."
	_profile_label.add_theme_font_size_override("font_size", 11)
	_info_container.add_child(_profile_label)

	_tool_count_label = Label.new()
	_tool_count_label.text = "Tools: ..."
	_tool_count_label.add_theme_font_size_override("font_size", 11)
	_info_container.add_child(_tool_count_label)

	_version_label = Label.new()
	_version_label.text = "Version: ..."
	_version_label.add_theme_font_size_override("font_size", 11)
	_info_container.add_child(_version_label)

	var multi_header := Label.new()
	multi_header.text = "Multi-Instance Multiplayer"
	multi_header.add_theme_font_size_override("font_size", 12)
	_info_container.add_child(multi_header)

	var multi_info := Label.new()
	multi_info.text = (
		"A: Two copies (git worktree) - SUPPORTED\n"
		+ "B: Built-in multi-instance run - MOSTLY SUPPORTED\n"
		+ "C: Same dir, two editors - NOT SUPPORTED\n"
		+ "See addons/godot_mcp_toolkit/docs/multi-instance.md for full details.")
	multi_info.add_theme_font_size_override("font_size", 11)
	multi_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_container.add_child(multi_info)

	var tool_header := Label.new()
	tool_header.text = "Registered Tools"
	tool_header.add_theme_font_size_override("font_size", 12)
	_info_container.add_child(tool_header)

	var tool_scroll := ScrollContainer.new()
	tool_scroll.custom_minimum_size.y = 100
	_info_container.add_child(tool_scroll)
	_tool_list_container = VBoxContainer.new()
	_tool_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tool_scroll.add_child(_tool_list_container)

	var links_row := HBoxContainer.new()
	_info_container.add_child(links_row)

	var github_btn := Button.new()
	github_btn.text = "GitHub"
	github_btn.pressed.connect(func():
		OS.shell_open("https://github.com/NPGameDev/godot-mcp-toolkit"))
	links_row.add_child(github_btn)

	var issues_btn := Button.new()
	issues_btn.text = "Issues"
	issues_btn.pressed.connect(func():
		OS.shell_open("https://github.com/NPGameDev/godot-mcp-toolkit/issues"))
	links_row.add_child(issues_btn)

	var server_btn := Button.new()
	server_btn.text = "Server Repo"
	server_btn.pressed.connect(func():
		OS.shell_open("https://github.com/NPGameDev/godot-mcp-server"))
	links_row.add_child(server_btn)

	var contrib_btn := Button.new()
	contrib_btn.text = "Contributing"
	contrib_btn.pressed.connect(func():
		OS.shell_open("https://github.com/NPGameDev/godot-mcp-toolkit/blob/main/CONTRIBUTING.md"))
	links_row.add_child(contrib_btn)

	# -- Audit poll timer (visibility-gated) --
	_audit_timer = Timer.new()
	_audit_timer.wait_time = 0.5
	_audit_timer.timeout.connect(_refresh_audit_tail)
	add_child(_audit_timer)
	if visible:
		_audit_timer.start()


# ---------------------------------------------------------------------------
# Signal handlers — server events (no polling)
# ---------------------------------------------------------------------------

func _on_client_connected(peer_count: int) -> void:
	_peer_label.text = "%d peer%s" % [peer_count, "" if peer_count == 1 else "s"]
	_activity_label.text = "Last activity: client connected"
	_toast("MCP client connected (%d peer%s)" % [
		peer_count, "" if peer_count == 1 else "s"])


func _on_client_disconnected(peer_count: int) -> void:
	_peer_label.text = "%d peer%s" % [peer_count, "" if peer_count == 1 else "s"]
	_activity_label.text = "Last activity: client disconnected"
	if peer_count == 0:
		_toast("MCP client lost connection", _TOAST_WARNING)


func _on_command_received(method: String) -> void:
	if _activity_label != null:
		_activity_label.text = "Last activity: %s" % method


func _on_visibility_changed() -> void:
	if _audit_timer == null:
		return
	if visible:
		_audit_timer.start()
		_refresh_audit_tail()
	else:
		_audit_timer.stop()


# ---------------------------------------------------------------------------
# Status refresh
# ---------------------------------------------------------------------------

func _refresh_status() -> void:
	if _server == null or _status_label == null:
		return
	var profile := _read_mcp_profile()
	var display := _display_profile_name(profile)
	var port: int = _server.get_bound_port()
	var port_str := str(port) if port > 0 else "6505"
	if _server.is_listening():
		_status_label.text = "Listening on 127.0.0.1:%s · %s" % [port_str, display]
	else:
		_status_label.text = "Not listening · %s" % display
	var count: int = _server.get_authed_peer_count()
	_peer_label.text = "%d peer%s" % [count, "" if count == 1 else "s"]
	if _power_user_warning != null:
		_power_user_warning.visible = (profile == "full")
	_refresh_info_panel()


## Read GODOT_MCP_PROFILE from .mcp.json env block (server-side setting).
func _read_mcp_profile() -> String:
	if not MCPJsonSync.has_mcp_json():
		return "standard"
	var env := MCPJsonSync.get_all_env_vars()
	var p: String = str(env.get("GODOT_MCP_PROFILE", "standard")).to_lower()
	if p in ["minimal", "standard", "full", "custom"]:
		return p
	return "standard"


# ---------------------------------------------------------------------------
# Feature toggle + .mcp.json sync
# ---------------------------------------------------------------------------

func _refresh_features() -> void:
	if _power_user_btn == null:
		return
	var allow_all: bool = ProjectSettings.get_setting("mcp_toolkit/unsafe/power_user_mode", false)
	_power_user_btn.text = "Disable Power User Mode" if allow_all else "Enable All (Power User)"

	for feature in _feature_rows:
		var row: Dictionary = _feature_rows[feature]
		var check: CheckBox = row["check"]
		var sync_icon: Label = row["sync_icon"]
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)

		check.set_pressed_no_signal(true if allow_all else MCPFeatureGate.is_enabled(feature))

		var ps_ok: bool = allow_all or ProjectSettings.get_setting(str(entry["ps_key"]), false)
		var env_ok: bool = OS.get_environment(str(entry["env_var"])) == "1"
		var has_env_in_json := MCPJsonSync.has_env_var(str(entry["env_var"])) \
			if MCPJsonSync.has_mcp_json() else false

		sync_icon.visible = false
		if entry["dual_gate"]:
			if ps_ok and not env_ok and not has_env_in_json:
				sync_icon.visible = true
				sync_icon.tooltip_text = (
					"ProjectSettings enabled but %s not found in .mcp.json"
					+ " — feature won't activate until the env var is also set"
				) % entry["env_var"]
			elif (has_env_in_json or env_ok) and not ps_ok:
				sync_icon.visible = true
				sync_icon.tooltip_text = (
					"Env var set but ProjectSettings disabled"
					+ " — enable in Project Settings -> mcp_toolkit/unsafe/"
				)


func _on_feature_toggled(enabled: bool, feature: String) -> void:
	var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
	if entry == null:
		return

	ProjectSettings.set_setting(str(entry["ps_key"]), enabled)
	ProjectSettings.save()

	var state_str := "enabled" if enabled else "disabled"
	_toast("MCP: %s %s" % [feature, state_str])

	if entry["dual_gate"] and MCPJsonSync.has_mcp_json():
		var env_var: String = entry["env_var"]
		var has_env := MCPJsonSync.has_env_var(env_var)
		if enabled and not has_env:
			_confirm_env_var_add(env_var)
		elif not enabled and has_env:
			_confirm_env_var_remove(env_var)
	elif entry["dual_gate"] and not MCPJsonSync.has_mcp_json() and enabled:
		_toast(
			"No .mcp.json found — use MCP: Write .mcp.json or add %s=1 manually"
			% entry["env_var"], _TOAST_WARNING)

	_refresh_features()


func _confirm_env_var_add(env_var: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Add env var to .mcp.json?"
	dialog.dialog_text = (
		"Also add %s=1 to .mcp.json?\n(Restart your MCP client to apply)" % env_var)
	dialog.confirmed.connect(func():
		MCPJsonSync.set_env_var(env_var, true)
		_toast("MCP: .mcp.json updated — restart your MCP client")
		_refresh_features()
		dialog.queue_free()
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


func _confirm_env_var_remove(env_var: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Remove env var from .mcp.json?"
	dialog.dialog_text = (
		"Also remove %s from .mcp.json?\n(Restart your MCP client to apply)" % env_var)
	dialog.confirmed.connect(func():
		MCPJsonSync.set_env_var(env_var, false)
		_toast("MCP: .mcp.json updated — restart your MCP client")
		_refresh_features()
		dialog.queue_free()
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


# ---------------------------------------------------------------------------
# Power User Mode
# ---------------------------------------------------------------------------

func _on_power_user_pressed() -> void:
	var allow_all: bool = ProjectSettings.get_setting("mcp_toolkit/unsafe/power_user_mode", false)
	if allow_all:
		_confirm_disable_power_user()
	else:
		_confirm_enable_power_user()


## Public entry point — also called from plugin.gd menu item / onboarding.
func toggle_power_user_mode() -> void:
	_on_power_user_pressed()


func _confirm_enable_power_user() -> void:
	var features := MCPFeatureRegistry.all_features()
	var lines := PackedStringArray()
	for feature in features:
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		lines.append("  - %s: %s" % [feature, entry["risk"]])

	var dialog := ConfirmationDialog.new()
	dialog.title = "Enable Power User Mode?"
	dialog.dialog_text = (
		"This enables ALL gated features:\n\n"
		+ "\n".join(lines)
		+ "\n\nThis gives the AI agent full control over your editor\n"
		+ "and project. Only enable if you trust the AI context.")
	dialog.ok_button_text = "I Understand — Enable All"
	dialog.confirmed.connect(func():
		_apply_power_user_mode(true)
		dialog.queue_free()
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


func _confirm_disable_power_user() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Disable Power User Mode?"
	dialog.dialog_text = "All features will revert to their individual settings."
	dialog.confirmed.connect(func():
		_apply_power_user_mode(false)
		dialog.queue_free()
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


func _apply_power_user_mode(enable: bool) -> void:
	if enable:
		# Snapshot current per-feature PS state (persisted via ProjectSettings).
		MCPFeatureGate.snapshot_pre_power_user()

	ProjectSettings.set_setting("mcp_toolkit/unsafe/power_user_mode", enable)

	if enable:
		for feature in MCPFeatureRegistry.all_features():
			var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
			ProjectSettings.set_setting(str(entry["ps_key"]), true)
		if MCPJsonSync.has_mcp_json():
			for feature in MCPFeatureRegistry.all_features():
				var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
				MCPJsonSync.set_env_var(str(entry["env_var"]), true)
		else:
			_offer_create_mcp_json_for_power_user()
	else:
		# Restore previous per-feature PS state from persistent cache.
		MCPFeatureGate.restore_pre_power_user()
		if MCPJsonSync.has_mcp_json():
			# Env vars not cached — clear all; user re-enables individually.
			for feature in MCPFeatureRegistry.all_features():
				var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
				var ps_on: bool = ProjectSettings.get_setting(str(entry["ps_key"]), false)
				MCPJsonSync.set_env_var(str(entry["env_var"]), ps_on)

	ProjectSettings.save()
	_refresh_features()

	if enable:
		_toast("MCP: Power User Mode — all features enabled", _TOAST_WARNING,
			"Restart your MCP client to apply env var changes")
	else:
		_toast("MCP: Power User Mode disabled")


func _offer_create_mcp_json_for_power_user() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "No .mcp.json found"
	dialog.dialog_text = "No .mcp.json found at project root.\nCreate it now?"
	dialog.confirmed.connect(func():
		write_mcp_json()
		for feature in MCPFeatureRegistry.all_features():
			var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
			MCPJsonSync.set_env_var(str(entry["env_var"]), true)
		dialog.queue_free()
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


# ---------------------------------------------------------------------------
# Audit log (polled — visibility-gated via Timer)
# ---------------------------------------------------------------------------

func _refresh_audit_tail() -> void:
	if _audit_container == null:
		return
	var path := _audit_path
	if path.is_empty():
		path = "user://mcp_audit.log"
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var size := file.get_length()
	if size > 4096:
		file.seek(size - 4096)
		file.get_line()  # skip partial first line
	var lines := PackedStringArray()
	while not file.eof_reached():
		var line := file.get_line()
		if not line.is_empty():
			lines.append(line)
	file.close()

	var start_idx := maxi(0, lines.size() - 10)
	var display_lines := lines.slice(start_idx)

	for child in _audit_container.get_children():
		child.queue_free()
	for line in display_lines:
		var lbl := Label.new()
		lbl.text = line
		lbl.add_theme_font_size_override("font_size", 11)
		_audit_container.add_child(lbl)


func _on_open_audit_log() -> void:
	var path := _audit_path
	if path.is_empty():
		path = "user://mcp_audit.log"
	var global_path := ProjectSettings.globalize_path(path)
	OS.shell_open(global_path)


func _on_clear_audit_view() -> void:
	if _audit_container == null:
		return
	for child in _audit_container.get_children():
		child.queue_free()


# ---------------------------------------------------------------------------
# Token regeneration
# ---------------------------------------------------------------------------

func _on_regen_token() -> void:
	if _server != null and _server.has_method("regenerate_token"):
		_server.regenerate_token()
		_toast("MCP token rotated")


# ---------------------------------------------------------------------------
# Write .mcp.json (public — also called from plugin.gd menu item)
# ---------------------------------------------------------------------------

func write_mcp_json() -> void:
	var template_path := "res://addons/godot_mcp_toolkit/.mcp.json.template"
	if not FileAccess.file_exists(template_path):
		_toast("Template not found: " + template_path, _TOAST_ERROR)
		return
	var content := FileAccess.get_file_as_string(template_path)
	var dest := MCPJsonSync.get_mcp_json_path()

	if FileAccess.file_exists(dest):
		var dialog := ConfirmationDialog.new()
		dialog.title = ".mcp.json already exists"
		dialog.dialog_text = (
			"Overwrite existing .mcp.json at:\n" + dest
			+ "\n\nThis will replace any custom env vars you have set.")
		dialog.ok_button_text = "Overwrite"
		dialog.confirmed.connect(func():
			_do_write_mcp_json(dest, content)
			dialog.queue_free()
		)
		dialog.canceled.connect(func(): dialog.queue_free())
		EditorInterface.get_base_control().add_child(dialog)
		dialog.popup_centered()
		return

	_do_write_mcp_json(dest, content)


func _do_write_mcp_json(dest: String, content: String) -> void:
	var file := FileAccess.open(dest, FileAccess.WRITE)
	if file == null:
		_toast("Failed to write .mcp.json (err %d)" % FileAccess.get_open_error(),
			_TOAST_ERROR)
		return
	file.store_string(content)
	file.close()
	_toast("MCP: .mcp.json updated — restart your MCP client", _TOAST_INFO,
		"Wrote to " + dest)


# ---------------------------------------------------------------------------
# Display name helper
# ---------------------------------------------------------------------------

func _display_profile_name(profile: String) -> String:
	match profile:
		"full":
			return "Power User"
		_:
			return profile.capitalize()


# ---------------------------------------------------------------------------
# Settings handlers
# ---------------------------------------------------------------------------

func _on_script_cap_changed(value: float) -> void:
	var clamped := maxi(64, int(value))
	ProjectSettings.set_setting("mcp_toolkit/limits/script_read_cap_kb", clamped)
	ProjectSettings.save()


func _on_ws_buffer_changed(value: float) -> void:
	var clamped := maxi(256, int(value))
	ProjectSettings.set_setting("mcp_toolkit/limits/ws_buffer_kb", clamped)
	ProjectSettings.save()


func _on_audit_enabled_toggled(enabled: bool) -> void:
	ProjectSettings.set_setting("mcp_toolkit/audit/enabled", enabled)
	ProjectSettings.save()


func _on_audit_max_size_changed(value: float) -> void:
	ProjectSettings.set_setting("mcp_toolkit/audit/max_size_kb", int(value))
	ProjectSettings.save()


# ---------------------------------------------------------------------------
# Info / Help panel
# ---------------------------------------------------------------------------

func _on_info_toggle_pressed() -> void:
	if _info_scroll == null:
		return
	_info_scroll.visible = not _info_scroll.visible
	if _info_toggle_btn != null:
		_info_toggle_btn.text = "Info / Help [-]" \
			if _info_scroll.visible else "Info / Help [+]"
	if _info_scroll.visible:
		_refresh_info_panel()


func _refresh_info_panel() -> void:
	if _info_scroll == null or not _info_scroll.visible:
		return
	var profile := _read_mcp_profile()
	var display := _display_profile_name(profile)

	if _server != null and _server.is_listening():
		var port: int = _server.get_bound_port()
		var peers: int = _server.get_authed_peer_count()
		_connection_label.text = "Connection: 127.0.0.1:%d · %d peer%s" % [
			port, peers, "" if peers == 1 else "s"]
	else:
		_connection_label.text = "Connection: not listening"

	_profile_label.text = "Profile: %s" % display

	if _server != null and _server.has_method("get_command_methods"):
		var methods: Array = _server.get_command_methods()
		_tool_count_label.text = "Tools: %d registered (plugin-side)" % methods.size()
	else:
		_tool_count_label.text = "Tools: (server not ready)"

	var plugin_ver := _get_plugin_version()
	var vi := Engine.get_version_info()
	var godot_ver := "%d.%d.%d" % [vi["major"], vi["minor"], vi["patch"]]
	_version_label.text = "Plugin: v%s · Godot %s" % [plugin_ver, godot_ver]

	_refresh_tool_list()


func _refresh_tool_list() -> void:
	if _tool_list_container == null:
		return
	for child in _tool_list_container.get_children():
		child.queue_free()
	if _server == null or not _server.has_method("get_command_methods"):
		return
	var methods: Array = _server.get_command_methods()
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
	for domain in domain_keys:
		var tools: Array = groups[domain]
		var lbl := Label.new()
		lbl.text = "%s: %s" % [str(domain).capitalize(), ", ".join(
			PackedStringArray(tools))]
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_tool_list_container.add_child(lbl)


func _get_plugin_version() -> String:
	var cfg := ConfigFile.new()
	var err := cfg.load("res://addons/godot_mcp_toolkit/plugin.cfg")
	if err != OK:
		return "unknown"
	return cfg.get_value("plugin", "version", "unknown")


# ---------------------------------------------------------------------------
# Toast helper
# ---------------------------------------------------------------------------

func _toast(msg: String, severity: int = _TOAST_INFO, tooltip_text: String = "") -> void:
	if not Engine.is_editor_hint():
		return
	print("[MCP] %s" % msg)
	# EditorToaster available in Godot 4.5+.
	var toaster = EditorInterface.get_editor_toaster()
	if toaster != null:
		toaster.push_toast(msg, severity, tooltip_text)
