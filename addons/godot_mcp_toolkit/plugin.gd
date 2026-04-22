@tool
extends EditorPlugin

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPCommandRegistry = _Hub.MCPCommandRegistry
const MCPFeatureRegistry = _Hub.MCPFeatureRegistry
const MCPServer := preload("res://addons/godot_mcp_toolkit/mcp_server.gd")
const SceneCommands := preload("res://addons/godot_mcp_toolkit/commands/scene_commands.gd")
const NodeCommands := preload("res://addons/godot_mcp_toolkit/commands/node_commands.gd")
const ScriptCommands := preload("res://addons/godot_mcp_toolkit/commands/script_commands.gd")
const EditorCommands := preload("res://addons/godot_mcp_toolkit/commands/editor_commands.gd")
const ResourceCommands := preload("res://addons/godot_mcp_toolkit/commands/resource_commands.gd")
const FolderCommands := preload("res://addons/godot_mcp_toolkit/commands/folder_commands.gd")
const FileCommands := preload("res://addons/godot_mcp_toolkit/commands/file_commands.gd")
const SignalCommands := preload("res://addons/godot_mcp_toolkit/commands/signal_commands.gd")
const PlaytestCommands := preload("res://addons/godot_mcp_toolkit/commands/playtest_commands.gd")
const ProjectCommands := preload("res://addons/godot_mcp_toolkit/commands/project_commands.gd")
const InputMapCommands := preload("res://addons/godot_mcp_toolkit/commands/input_map_commands.gd")
const AnimationCommands := preload("res://addons/godot_mcp_toolkit/commands/animation_commands.gd")
const TilemapCommands := preload("res://addons/godot_mcp_toolkit/commands/tilemap_commands.gd")
const AssetCommands := preload("res://addons/godot_mcp_toolkit/commands/asset_commands.gd")
const SaveCommands := preload("res://addons/godot_mcp_toolkit/commands/save_commands.gd")
const ClassdbCommands := preload("res://addons/godot_mcp_toolkit/commands/classdb_commands.gd")
const MCPFileGuard = _Hub.MCPFileGuard
const MCPRegistryClient = _Hub.MCPRegistryClient
const MCPAuth := preload("res://addons/godot_mcp_toolkit/auth.gd")
const UserCommandsLoader := preload("res://addons/godot_mcp_toolkit/user_commands_loader.gd")

# Mode B — runtime autoload that hosts the game-side WS server on
# 127.0.0.1:6525. Registered/unregistered via add_autoload_singleton /
# remove_autoload_singleton so end-user installs pick it up when they
# tick the plugin. Idempotent: if project.godot already carries the entry
# (e.g., dogfood), Godot keeps the existing value rather than duplicating.
const RUNTIME_AUTOLOAD_NAME := "MCPRuntimeServer"
const RUNTIME_AUTOLOAD_PATH := "res://addons/godot_mcp_toolkit/runtime/mcp_runtime_server.gd"

var _server: Node = null
var _export_plugin: EditorExportPlugin = null
var _dock: Control = null
var _onboarding_wizard: AcceptDialog = null
# Playtest-end detection for runtime port cleanup.
var _was_playing: bool = false
# Power User polling — detect changes from ProjectSettings UI.
var _last_power_user: bool = false
# Per-feature polling — detect individual gate changes from ProjectSettings UI.
var _last_feature_states: Dictionary = {}  # { ps_key: bool }

# Menu item keys for teardown symmetry.
const _MENU_ITEMS: Array[String] = [
	"MCP Toolkit: Regenerate Token",
	"MCP Toolkit: Show Audit Log",
	"MCP Toolkit: Open Project Settings",
	"MCP Toolkit: Write .mcp.json",
	"MCP Toolkit: Power User Mode",
]

# Command Palette key names for teardown symmetry.
const _PALETTE_KEYS: Array[String] = [
	"mcp/regenerate_token",
	"mcp/show_audit_log",
	"mcp/open_settings",
	"mcp/write_mcp_json",
	"mcp/power_user_mode",
]


func _enter_tree() -> void:
	_migrate_user_data_paths()
	_migrate_stale_settings()
	_register_feature_gate_settings()
	_last_power_user = ProjectSettings.get_setting(
		"mcp_toolkit/feature_gates/power_user_mode", false)
	_snapshot_feature_states()

	var registry := MCPCommandRegistry.new()
	_server = MCPServer.new()
	_server.name = "MCPServer"
	_server.set_registry(registry)

	SceneCommands.register(registry, _server)
	NodeCommands.register(registry, _server)
	ScriptCommands.register(registry, _server)
	EditorCommands.register(registry, _server)
	ResourceCommands.register(registry, _server)
	FolderCommands.register(registry, _server)
	FileCommands.register(registry, _server)
	SignalCommands.register(registry, _server)
	PlaytestCommands.register(registry, _server)
	ProjectCommands.register(registry, _server)
	InputMapCommands.register(registry, _server)
	AnimationCommands.register(registry, _server)
	TilemapCommands.register(registry, _server)
	AssetCommands.register(registry, _server)
	SaveCommands.register(registry, _server)
	ClassdbCommands.register(registry, _server)

	# User command extensions — profile-exempt, always loaded.
	UserCommandsLoader.load_all(registry, _server)

	_validate_user_whitelist()

	_export_plugin = preload("res://addons/godot_mcp_toolkit/export_strip.gd").new()
	add_export_plugin(_export_plugin)

	add_child(_server)
	_server.start()

	# Register in the system-wide project registry so the TS bridge can
	# discover us by project path. Must come after start() — port unknown
	# until _scan_and_listen() runs.
	var bound_port: int = _server.get_bound_port()
	if bound_port > 0:
		MCPRegistryClient.register(bound_port, MCPAuth.get_token_path())

	# -- Bottom-panel dock --
	_dock = preload("res://addons/godot_mcp_toolkit/ui/dock.tscn").instantiate()
	_dock.bind(_server, "user://addons/godot_mcp_toolkit/mcp_audit.log")
	add_control_to_bottom_panel(_dock, "MCP Toolkit")

	# -- Menu items --
	add_tool_menu_item("MCP Toolkit: Regenerate Token", _on_regen_token)
	add_tool_menu_item("MCP Toolkit: Show Audit Log", _on_show_audit)
	add_tool_menu_item("MCP Toolkit: Open Project Settings", _on_open_settings)
	add_tool_menu_item("MCP Toolkit: Write .mcp.json", _on_write_mcp_json)
	add_tool_menu_item("MCP Toolkit: Power User Mode", _on_power_user_mode)

	# -- Command Palette --
	var palette := EditorInterface.get_command_palette()
	palette.add_command("MCP Toolkit: Regenerate Token", "mcp/regenerate_token", _on_regen_token)
	palette.add_command("MCP Toolkit: Show Audit Log", "mcp/show_audit_log", _on_show_audit)
	palette.add_command("MCP Toolkit: Open Project Settings", "mcp/open_settings", _on_open_settings)
	palette.add_command("MCP Toolkit: Write .mcp.json", "mcp/write_mcp_json", _on_write_mcp_json)
	palette.add_command("MCP Toolkit: Power User Mode", "mcp/power_user_mode", _on_power_user_mode)

	# -- Per-user EditorSettings --
	_register_editor_settings()

	call_deferred("_check_onboarding")


# -- Stale settings migration --------------------------------------------------


const MCPFeatureGate := preload("res://addons/godot_mcp_toolkit/feature_gate.gd")
const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")


func _migrate_user_data_paths() -> void:
	# Ensure the namespaced user:// directory exists.
	var dir := DirAccess.open("user://")
	if dir != null and not dir.dir_exists("addons/godot_mcp_toolkit"):
		dir.make_dir_recursive("addons/godot_mcp_toolkit")

	# Move files from user:// root to user://addons/godot_mcp_toolkit/.
	var migrations := [
		["user://mcp_audit.log", "user://addons/godot_mcp_toolkit/mcp_audit.log"],
		["user://mcp_power_user_cache.json", "user://addons/godot_mcp_toolkit/mcp_power_user_cache.json"],
		["user://mcp_onboarding_v35_shown", "user://addons/godot_mcp_toolkit/mcp_onboarding_v35_shown"],
		["user://mcp_onboarding_v35b_shown", "user://addons/godot_mcp_toolkit/mcp_onboarding_v35b_shown"],
	]
	# Token files are per-worktree (user://mcp_token_<hash>).
	var project_path := ProjectSettings.globalize_path("res://").replace("\\", "/").rstrip("/")
	var suffix := project_path.sha256_text().substr(0, 12)
	migrations.append([
		"user://mcp_token_%s" % suffix,
		"user://addons/godot_mcp_toolkit/mcp_token_%s" % suffix,
	])

	var moved := 0
	for pair in migrations:
		var old_path: String = pair[0]
		var new_path: String = pair[1]
		if FileAccess.file_exists(old_path) and not FileAccess.file_exists(new_path):
			var content := FileAccess.get_file_as_bytes(old_path)
			var out := FileAccess.open(new_path, FileAccess.WRITE)
			if out != null:
				out.store_buffer(content)
				out.close()
				DirAccess.remove_absolute(old_path)
				moved += 1
	if moved > 0:
		print("[MCP] Migrated %d file(s) to user://addons/godot_mcp_toolkit/" % moved)


func _migrate_stale_settings() -> void:
	# Remove leftover keys from previous namespace eras.
	var stale_keys := [
		"mcp/unsafe/allow_all",
		"mcp/unsafe/allow_game_eval",
		"mcp/unsafe/allow_os_execute",
		"mcp/unsafe/allow_user_scope",
		"mcp/unsafe/allow_outbound_http",
		"mcp/unsafe/allow_node_call_method",
		"mcp/unsafe/allow_project_set_setting",
		"mcp/unsafe/allow_input_map_write",
		"application/config/mcp_smoke_15d",
	]
	var removed := 0
	for key in stale_keys:
		if ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, null)
			removed += 1
	# Migrate unsafe/ → feature_gates/ per-feature keys.
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		var new_key: String = entry["ps_key"]  # already feature_gates/
		var old_key := new_key.replace("feature_gates/", "unsafe/")
		if ProjectSettings.has_setting(old_key):
			var val = ProjectSettings.get_setting(old_key, false)
			if val:
				ProjectSettings.set_setting(new_key, true)
			ProjectSettings.set_setting(old_key, null)
			removed += 1
	# Migrate old power_user_mode paths → current feature_gates/power_user_mode.
	for old_key in ["mcp_toolkit/unsafe/allow_all", "mcp_toolkit/unsafe/power_user_mode", "mcp_toolkit/power_user_mode"]:
		if ProjectSettings.has_setting(old_key):
			var val = ProjectSettings.get_setting(old_key, false)
			if val:
				ProjectSettings.set_setting("mcp_toolkit/feature_gates/power_user_mode", true)
			ProjectSettings.set_setting(old_key, null)
			removed += 1
	# Remove stale power_user_warning from old unsafe/ namespace.
	if ProjectSettings.has_setting("mcp_toolkit/unsafe/power_user_warning"):
		ProjectSettings.set_setting("mcp_toolkit/unsafe/power_user_warning", null)
		removed += 1
	# Remove internal cache from ProjectSettings — now stored in user:// file.
	if ProjectSettings.has_setting("mcp_toolkit/internal/pre_power_user_cache"):
		ProjectSettings.set_setting("mcp_toolkit/internal/pre_power_user_cache", null)
		removed += 1
	if removed > 0:
		ProjectSettings.save()
		print("[MCP] Migrated %d stale settings" % removed)


# -- user:// whitelist validation ----------------------------------------------


func _validate_user_whitelist() -> void:
	MCPFileGuard.reload_user_whitelist()
	var wl_path := "res://addons/godot_mcp_toolkit/user_scope_whitelist.json"
	if not FileAccess.file_exists(wl_path):
		push_warning("MCP: user_scope_whitelist.json not found at %s; save.* tools will return USER_SCOPE_DISABLED until the file is created" % wl_path)
		return
	var f := FileAccess.open(wl_path, FileAccess.READ)
	if f == null:
		push_warning("MCP: cannot open user_scope_whitelist.json (error %d); save.* tools will return USER_SCOPE_DISABLED" % FileAccess.get_open_error())
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("MCP: user_scope_whitelist.json is malformed (expected JSON object); save.* tools will return USER_SCOPE_DISABLED")
		return


# -- FeatureGate ProjectSettings registration ---------------------------------


func _register_feature_gate_settings() -> void:
	# power_user_mode — master switch, registered first so it displays first.
	_register_basic_bool("mcp_toolkit/feature_gates/power_user_mode", false,
		"WARNING: Enables ALL feature gates and grants the AI agent "
		+ "full control — code execution, OS commands, project settings writes, "
		+ "and file access outside res://. Individual gates sync automatically.")
	ProjectSettings.set_order("mcp_toolkit/feature_gates/power_user_mode", 0)

	var order_idx := 1
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		var ps_key: String = entry["ps_key"]
		var gate_label := "dual-gate: env AND PS" if entry["dual_gate"] else "single-gate: env OR PS"
		_register_basic_bool(ps_key, false,
			"DANGER: %s (%s). Default off." % [entry["risk"], gate_label])
		ProjectSettings.set_order(ps_key, order_idx)
		order_idx += 1

	# Power User warning — read-only status display at the end of Feature Gates.
	_register_power_user_warning()

	# Response-limit settings.
	_register_basic_int("mcp_toolkit/limits/script_read_cap_kb", 256,
		"Max script content returned by script.read, in KB. Minimum 64.")
	_register_basic_int("mcp_toolkit/limits/ws_buffer_kb", 1024,
		"WebSocket per-peer buffer size, in KB. Minimum 256.")

	# Audit log settings.
	_register_basic_bool("mcp_toolkit/audit/enabled", true,
		"Enable MCP audit log at user://addons/godot_mcp_toolkit/mcp_audit.log.")
	_register_basic_int("mcp_toolkit/audit/max_size_kb", 1024,
		"Max audit log size in KB. 0 = unlimited. Log truncates to 50% when exceeded.")


func _register_basic_bool(key: String, default_value: bool, hint: String) -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default_value)
	ProjectSettings.set_initial_value(key, default_value)
	ProjectSettings.set_as_basic(key, true)
	ProjectSettings.add_property_info({
		"name": key, "type": TYPE_BOOL,
		"hint": PROPERTY_HINT_NONE, "hint_string": hint,
	})


func _register_basic_int(key: String, default_value: int, hint: String) -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default_value)
	ProjectSettings.set_initial_value(key, default_value)
	ProjectSettings.set_as_basic(key, true)
	ProjectSettings.add_property_info({
		"name": key, "type": TYPE_INT,
		"hint": PROPERTY_HINT_NONE, "hint_string": hint,
	})



const _PU_WARNING_KEY := "mcp_toolkit/feature_gates/power_user_warning"
const _PU_WARNING_TEXT := (
	"POWER USER MODE ACTIVE — All feature gates enabled. "
	+ "The AI agent has full control: code execution, OS commands, "
	+ "project settings writes, and file access outside res://.")


func _register_power_user_warning() -> void:
	if not ProjectSettings.has_setting(_PU_WARNING_KEY):
		ProjectSettings.set_setting(_PU_WARNING_KEY, "")
	ProjectSettings.set_initial_value(_PU_WARNING_KEY, "")
	ProjectSettings.set_as_basic(_PU_WARNING_KEY, true)
	ProjectSettings.set_order(_PU_WARNING_KEY, 1000)
	ProjectSettings.add_property_info({
		"name": _PU_WARNING_KEY, "type": TYPE_STRING,
		"hint": PROPERTY_HINT_MULTILINE_TEXT,
		"hint_string": "Read-only status display — value is managed by the plugin.",
	})
	_update_power_user_warning()


func _update_power_user_warning() -> void:
	var enabled: bool = ProjectSettings.get_setting(
		"mcp_toolkit/feature_gates/power_user_mode", false)
	ProjectSettings.set_setting(_PU_WARNING_KEY, _PU_WARNING_TEXT if enabled else "")


# -- Guided onboarding wizard -------------------------------------------------


const _ONBOARDING_FLAG := "user://addons/godot_mcp_toolkit/mcp_onboarding_v35b_shown"
# Projects that already saw the v35 single-dialog onboarding skip the wizard.
const _ONBOARDING_FLAG_V35 := "user://addons/godot_mcp_toolkit/mcp_onboarding_v35_shown"

var _wizard_step: int = 0
var _wizard_buttons: Array = []  # Tracked custom buttons for per-step cleanup.
const _WIZARD_STEP_COUNT := 5


func _check_onboarding() -> void:
	if FileAccess.file_exists(_ONBOARDING_FLAG):
		return
	if FileAccess.file_exists(_ONBOARDING_FLAG_V35):
		_write_onboarding_flag()
		return

	_wizard_step = 0
	_wizard_buttons.clear()
	var dialog := AcceptDialog.new()
	dialog.exclusive = false
	dialog.min_size = Vector2i(480, 260)

	dialog.confirmed.connect(_wizard_advance.bind(dialog))
	dialog.custom_action.connect(_wizard_custom_action.bind(dialog))
	dialog.canceled.connect(func():
		_write_onboarding_flag()
		_free_wizard()
	)

	_onboarding_wizard = dialog
	_wizard_apply_step(dialog)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


func _wizard_apply_step(dialog: AcceptDialog) -> void:
	dialog.title = "MCP Toolkit — Setup Wizard (%d of %d)" % [
		_wizard_step + 1, _WIZARD_STEP_COUNT]

	# Free all tracked custom buttons from the previous step.
	for btn in _wizard_buttons:
		if is_instance_valid(btn):
			btn.queue_free()
	_wizard_buttons.clear()

	match _wizard_step:
		0:
			dialog.dialog_text = (
				"Welcome to the Godot MCP Toolkit!\n\n"
				+ "Your AI coding assistant sees tools based on the active profile.\n"
				+ "Choose your starting configuration:\n\n"
				+ "  Standard (default) — core tools, unsafe ops disabled\n"
				+ "  Power User — all tools, including code execution & OS commands\n\n"
				+ "You can change this anytime in the MCP dock.")
			dialog.ok_button_text = "Standard (Recommended)"
			_wizard_buttons.append(dialog.add_button("Power User Mode", true, "power_user"))

		1:
			dialog.dialog_text = (
				"This is your MCP control center — server status,\n"
				+ "feature gates, and audit log.\n\n"
				+ "The dock is now visible in the bottom panel.")
			dialog.ok_button_text = "Next"
			_wizard_buttons.append(dialog.add_button("Back", true, "back"))
			# Action: show the dock.
			if _dock != null:
				make_bottom_panel_item_visible(_dock)

		2:
			dialog.dialog_text = (
				"Toggle individual capabilities here. Dual-gate features\n"
				+ "need both a ProjectSettings toggle and an env var in .mcp.json.\n\n"
				+ "Open Project Settings to see Feature Gates.")
			dialog.ok_button_text = "Next"
			_wizard_buttons.append(dialog.add_button("Back", true, "back"))
			# Action: open Project Settings to Feature Gates.
			_on_open_settings()

		3:
			dialog.dialog_text = (
				"Your MCP client reads .mcp.json from the project root.\n"
				+ "Use 'Write .mcp.json' to create or update it.\n")
			var has_mcp_json := FileAccess.file_exists(
				ProjectSettings.globalize_path("res://") + ".mcp.json")
			if has_mcp_json:
				dialog.dialog_text += "\n.mcp.json already exists — you're all set."
			else:
				dialog.dialog_text += "\nNo .mcp.json found. Create one now?"
				_wizard_buttons.append(
					dialog.add_button("Create .mcp.json", true, "create_mcp"))
			dialog.ok_button_text = "Next"
			_wizard_buttons.append(dialog.add_button("Back", true, "back"))

		4:
			dialog.dialog_text = (
				"Use 'Info / Help' in the dock for connection status,\n"
				+ "tool list, and documentation links.\n\n"
				+ "You're all set! The Info panel is now open.")
			dialog.ok_button_text = "Finish"
			_wizard_buttons.append(dialog.add_button("Back", true, "back"))
			# Action: open the Info dialog.
			if _dock != null:
				_dock._show_info_dialog()

	# "Skip Tour" always last (rightmost).
	_wizard_buttons.append(dialog.add_button("Skip Tour", true, "skip"))


func _wizard_advance(dialog: AcceptDialog) -> void:
	if _wizard_step == 0:
		# Step 0 OK = "Standard (Recommended)" — no action needed, default profile.
		pass
	if _wizard_step >= _WIZARD_STEP_COUNT - 1:
		# Final step — finish.
		_write_onboarding_flag()
		_free_wizard()
		return
	_wizard_step += 1
	_wizard_apply_step(dialog)


func _wizard_custom_action(action: StringName, dialog: AcceptDialog) -> void:
	match str(action):
		"skip":
			_write_onboarding_flag()
			_free_wizard()
		"back":
			if _wizard_step > 0:
				_wizard_step -= 1
				_wizard_apply_step(dialog)
		"power_user":
			# Trigger Power User flow — the dock shows its own confirmation dialog.
			if _dock != null:
				_dock.toggle_power_user_mode()
			# Advance to step 1 after choosing.
			_wizard_step = 1
			_wizard_apply_step(dialog)
		"standard":
			# Explicit standard choice — advance.
			_wizard_step = 1
			_wizard_apply_step(dialog)
		"create_mcp":
			if _dock != null:
				_dock.write_mcp_json()


func _free_wizard() -> void:
	_wizard_buttons.clear()
	if _onboarding_wizard != null and is_instance_valid(_onboarding_wizard):
		_onboarding_wizard.queue_free()
	_onboarding_wizard = null


func _write_onboarding_flag() -> void:
	var f := FileAccess.open(_ONBOARDING_FLAG, FileAccess.WRITE)
	if f != null:
		f.store_string("1")
		f.close()


# Detect playtest end so we can clear runtime_port/runtime_pid from
# the registry (belt-and-suspenders with runtime's own _exit_tree cleanup).
func _process(_delta: float) -> void:
	var playing := EditorInterface.is_playing_scene()
	if _was_playing and not playing:
		MCPRegistryClient.clear_runtime()
	_was_playing = playing

	# Detect Power User toggle from ProjectSettings UI.
	var power_user: bool = ProjectSettings.get_setting(
		"mcp_toolkit/feature_gates/power_user_mode", false)
	if power_user != _last_power_user:
		_last_power_user = power_user
		_sync_power_user_mode(power_user)

	# Detect individual feature gate changes from ProjectSettings UI.
	_poll_feature_states()


func _sync_power_user_mode(enable: bool) -> void:
	_update_power_user_warning()
	# Guard: skip full sync if the dock already applied this change.
	if enable and MCPFeatureGate.has_power_user_cache():
		# Dock already snapshotted + set keys — just refresh UI.
		if _dock != null:
			_dock._refresh_features()
		return
	if not enable and not MCPFeatureGate.has_power_user_cache():
		# Dock already restored + cleared cache — just refresh UI.
		_snapshot_feature_states()
		if _dock != null:
			_dock._refresh_features()
		return
	if enable:
		MCPFeatureGate.snapshot_pre_power_user()
		for feature in MCPFeatureRegistry.all_features():
			var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
			ProjectSettings.set_setting(str(entry["ps_key"]), true)
		if MCPJsonSync.has_mcp_json():
			for feature in MCPFeatureRegistry.all_features():
				var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
				MCPJsonSync.set_env_var(str(entry["env_var"]), true)
	else:
		MCPFeatureGate.restore_pre_power_user()
		if MCPJsonSync.has_mcp_json():
			for feature in MCPFeatureRegistry.all_features():
				var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
				var ps_on: bool = ProjectSettings.get_setting(str(entry["ps_key"]), false)
				MCPJsonSync.set_env_var(str(entry["env_var"]), ps_on)
	_update_power_user_warning()
	ProjectSettings.save()
	_snapshot_feature_states()
	if _dock != null:
		_dock._refresh_features()
		_dock._notify_restart_required()


func _snapshot_feature_states() -> void:
	_last_feature_states.clear()
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		_last_feature_states[str(entry["ps_key"])] = ProjectSettings.get_setting(
			str(entry["ps_key"]), false)


func _poll_feature_states() -> void:
	# Enforce read-only warning text — revert any user edits immediately.
	var power_user: bool = ProjectSettings.get_setting(
		"mcp_toolkit/feature_gates/power_user_mode", false)
	var expected_warning := _PU_WARNING_TEXT if power_user else ""
	if ProjectSettings.get_setting(_PU_WARNING_KEY, "") != expected_warning:
		ProjectSettings.set_setting(_PU_WARNING_KEY, expected_warning)

	# If Power User Mode is active, revert any individual gate changes
	# made from the ProjectSettings UI and warn the user.
	if power_user:
		var reverted := false
		for feature in MCPFeatureRegistry.all_features():
			var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
			var ps_key: String = entry["ps_key"]
			var current: bool = ProjectSettings.get_setting(ps_key, false)
			if not current:
				ProjectSettings.set_setting(ps_key, true)
				_last_feature_states[ps_key] = true
				reverted = true
		if reverted:
			ProjectSettings.save()
			if _dock != null:
				_dock._warn_power_user_locked()
		return

	if not MCPJsonSync.has_mcp_json():
		return
	var changed := false
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		var ps_key: String = entry["ps_key"]
		var current: bool = ProjectSettings.get_setting(ps_key, false)
		var prev: bool = _last_feature_states.get(ps_key, false)
		if current != prev:
			_last_feature_states[ps_key] = current
			if entry["dual_gate"]:
				MCPJsonSync.set_env_var(str(entry["env_var"]), current)
				changed = true
	if changed:
		if _dock != null:
			_dock._refresh_features()
			_dock._notify_restart_required()


func _exit_tree() -> void:
	# Teardown symmetry — reverse order of _enter_tree registrations.
	# Onboarding wizard (if still open).
	_free_wizard()

	# Command Palette.
	var palette := EditorInterface.get_command_palette()
	for key in _PALETTE_KEYS:
		palette.remove_command(key)

	# Menu items.
	for item in _MENU_ITEMS:
		remove_tool_menu_item(item)

	# Dock (remove + free).
	if _dock != null:
		remove_control_from_bottom_panel(_dock)
		_dock.queue_free()
		_dock = null

	# Export plugin (RefCounted — do NOT queue_free, just null).
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null

	# Server + registry.
	if _server != null:
		_server.stop()
		MCPRegistryClient.deregister()
		_server.queue_free()
		_server = null


func _enable_plugin() -> void:
	add_autoload_singleton(RUNTIME_AUTOLOAD_NAME, RUNTIME_AUTOLOAD_PATH)


func _disable_plugin() -> void:
	remove_autoload_singleton(RUNTIME_AUTOLOAD_NAME)

	# Warn about orphaned .mcp.json.
	var mcp_json_path := ProjectSettings.globalize_path("res://") + ".mcp.json"
	if FileAccess.file_exists(mcp_json_path):
		var dialog := ConfirmationDialog.new()
		dialog.title = "MCP Plugin Disabled"
		dialog.dialog_text = (
			"The .mcp.json configuration file is still at your project root:\n"
			+ mcp_json_path + "\n\n"
			+ "If you're uninstalling the plugin, you may want to remove it.\n"
			+ "If you're just disabling temporarily, keep it.")
		dialog.ok_button_text = "Delete .mcp.json"
		dialog.cancel_button_text = "Keep"
		dialog.confirmed.connect(func():
			DirAccess.remove_absolute(mcp_json_path)
			print("[MCP] Deleted .mcp.json at %s" % mcp_json_path)
			dialog.queue_free()
		)
		dialog.canceled.connect(func():
			print("[MCP] .mcp.json kept at %s" % mcp_json_path)
			dialog.queue_free()
		)
		EditorInterface.get_base_control().add_child(dialog)
		dialog.popup_centered()


# -- EditorSettings registration (per-user, not committed to VCS) --------


func _register_editor_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	var settings := {
		"mcp_toolkit/personal/dock_default_visible": [TYPE_BOOL, true],
	}
	for key in settings:
		if not es.has_setting(key):
			es.set_setting(key, settings[key][1])
		es.add_property_info({"name": key, "type": settings[key][0]})


# -- Menu / Command Palette handlers --------------------------------------


func _on_regen_token() -> void:
	if _server != null:
		_server.regenerate_token()
		print("[MCP] Token rotated")
		var toaster = EditorInterface.get_editor_toaster()
		if toaster != null:
			toaster.push_toast("MCP token rotated", 0)


func _on_show_audit() -> void:
	if _dock != null:
		_dock.show_audit_dialog()
	else:
		var global_path := ProjectSettings.globalize_path("user://addons/godot_mcp_toolkit/mcp_audit.log")
		OS.shell_open(global_path)


func _on_open_settings() -> void:
	var root := EditorInterface.get_base_control().get_tree().root
	var dialog := _find_node_by_class(root, "ProjectSettingsEditor")
	if not dialog is Window:
		var toaster = EditorInterface.get_editor_toaster()
		if toaster != null:
			toaster.push_toast(
				"Project -> Project Settings -> Mcp Toolkit -> Feature Gates", 0)
		return

	# Try the C++ fast-path: popup_project_settings() refreshes the section
	# tree internally, then set_general_page() selects the section directly.
	if dialog.has_method("popup_project_settings"):
		dialog.call("popup_project_settings", false)
		if dialog.has_method("set_general_page"):
			dialog.call("set_general_page", "Mcp Toolkit/Feature Gates")
			return
	else:
		dialog.popup_centered_clamped(Vector2i(900, 700))

	# Fallback: toggle Advanced Settings (custom plugin settings are hidden
	# behind it) then select the section via tree traversal.
	# update_category_list() from the toggle is synchronous — one process
	# frame is enough for the tree items to exist.
	_enable_advanced_settings(dialog)
	get_tree().create_timer(0.05).timeout.connect(
		_select_mcp_section.bind(dialog))


func _enable_advanced_settings(dialog: Window) -> void:
	var buttons: Array = []
	_collect_nodes_by_class(dialog, "CheckButton", buttons)
	for btn in buttons:
		var cb := btn as CheckButton
		if cb.text.to_lower().contains("advanced") and not cb.button_pressed:
			# set_pressed (button_pressed=) already emits toggled internally,
			# which triggers SectionedInspector.update_category_list().
			cb.button_pressed = true
			return


func _select_mcp_section(dialog: Window) -> void:
	# Ensure the General tab is active (tab 0).
	var tab := _find_node_by_class(dialog, "TabContainer") as TabContainer
	if tab != null:
		tab.current_tab = 0
	var trees: Array = []
	_collect_nodes_by_class(dialog, "Tree", trees)
	for tree_node in trees:
		var tree: Tree = tree_node as Tree
		var root_item := tree.get_root()
		if root_item == null:
			continue
		# Try "Feature Gates" first (child), then "Mcp Toolkit" (parent),
		# then any item containing "mcp".
		var target := _find_tree_item(root_item, "Feature Gates")
		if target == null:
			target = _find_tree_item(root_item, "Mcp Toolkit")
		if target == null:
			target = _find_tree_item_contains(root_item, "mcp")
		if target != null:
			var parent := target.get_parent()
			while parent != null:
				parent.collapsed = false
				parent = parent.get_parent()
			target.select(0)
			tree.item_selected.emit()
			return


static func _collect_nodes_by_class(node: Node, cls: String, result: Array, depth: int = 15) -> void:
	if node.get_class() == cls:
		result.append(node)
	if depth <= 0:
		return
	for child in node.get_children():
		_collect_nodes_by_class(child, cls, result, depth - 1)


static func _find_tree_item(item: TreeItem, text: String) -> TreeItem:
	if item.get_text(0).to_lower() == text.to_lower():
		return item
	var child := item.get_first_child()
	while child != null:
		var found := _find_tree_item(child, text)
		if found != null:
			return found
		child = child.get_next()
	return null


static func _find_tree_item_contains(item: TreeItem, substr: String) -> TreeItem:
	if item.get_text(0).to_lower().contains(substr.to_lower()):
		return item
	var child := item.get_first_child()
	while child != null:
		var found := _find_tree_item_contains(child, substr)
		if found != null:
			return found
		child = child.get_next()
	return null


static func _find_node_by_class(node: Node, cls: String, depth: int = 15) -> Node:
	if node.get_class() == cls:
		return node
	if depth <= 0:
		return null
	for child in node.get_children():
		var found := _find_node_by_class(child, cls, depth - 1)
		if found != null:
			return found
	return null


func _on_write_mcp_json() -> void:
	if _dock != null:
		_dock.write_mcp_json()


func _on_power_user_mode() -> void:
	if _dock != null:
		_dock.toggle_power_user_mode()
