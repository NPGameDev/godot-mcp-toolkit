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

	# -- Audit section --
	var audit_header := Label.new()
	audit_header.text = "Audit Log (recent)"
	audit_header.add_theme_font_size_override("font_size", 14)
	add_child(audit_header)

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
	if _server.is_listening():
		_status_label.text = "Listening on 127.0.0.1:6505 · %s" % profile
	else:
		_status_label.text = "Not listening · %s" % profile
	var count: int = _server.get_authed_peer_count()
	_peer_label.text = "%d peer%s" % [count, "" if count == 1 else "s"]


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
	var allow_all: bool = ProjectSettings.get_setting("mcp/unsafe/allow_all", false)
	_power_user_btn.text = "Disable Power User Mode" if allow_all else "Enable All (Power User)"

	for feature in _feature_rows:
		var row: Dictionary = _feature_rows[feature]
		var check: CheckBox = row["check"]
		var sync_icon: Label = row["sync_icon"]
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)

		check.set_pressed_no_signal(MCPFeatureGate.is_enabled(feature))

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
					+ " — enable in Project Settings -> mcp/unsafe/"
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
	var allow_all: bool = ProjectSettings.get_setting("mcp/unsafe/allow_all", false)
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
	ProjectSettings.set_setting("mcp/unsafe/allow_all", enable)

	if enable and MCPJsonSync.has_mcp_json():
		for feature in MCPFeatureRegistry.all_features():
			var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
			MCPJsonSync.set_env_var(str(entry["env_var"]), true)
	elif enable and not MCPJsonSync.has_mcp_json():
		_offer_create_mcp_json_for_power_user()
	elif not enable and MCPJsonSync.has_mcp_json():
		for feature in MCPFeatureRegistry.all_features():
			var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
			MCPJsonSync.set_env_var(str(entry["env_var"]), false)

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
