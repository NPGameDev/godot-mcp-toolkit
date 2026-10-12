@tool
extends RefCounted
## Response-limits unit tests: the env-override layer never writes ProjectSettings;
## each push replaces the whole set; every limit has a floor; the effective value is
## the env override, else the project value; the default limits and the shared
## range table hold; the dock shows the project value plus an override line, and
## follows the layer's change signal; the retired note key is dropped; and the WS
## transport sizes an accepted peer from its owner.
##
## run() is a coroutine: the in-tree and transport groups await frames, so the
## orchestrator must `await` it. Settings change in memory only and are restored,
## nothing calls ProjectSettings.save(), and every group clears the env-override
## layer before it returns, so the modules after this one see project values only.

const ResponseLimits := preload("res://addons/godot_mcp_toolkit/core/response_limits.gd")
const MetaCommands := preload("res://addons/godot_mcp_toolkit/commands/meta_commands.gd")
const SaveCommands := preload("res://addons/godot_mcp_toolkit/commands/save_commands.gd")
const ScriptCommands := preload("res://addons/godot_mcp_toolkit/commands/script_commands.gd")
const SettingsRegistration := preload("res://addons/godot_mcp_toolkit/core/settings_registration.gd")
const DockLimitsSection := preload("res://addons/godot_mcp_toolkit/ui/dock/limits/dock_limits_section.gd")
const WsTransport := preload("res://addons/godot_mcp_toolkit/transport/ws_transport.gd")

const _SCRIPT := ResponseLimits.SCRIPT_READ_CAP_KB
const _SAVE := ResponseLimits.SAVE_READ_CAP_KB
const _WS := ResponseLimits.WS_BUFFER_KB
const _RETIRED_NOTE_KEY := "mcp_toolkit/limits/env_override_note"


## [param tree] is the runner itself: Engine.get_main_loop() is still null while the
## runner's _init runs.
static func run(testing, tree: SceneTree) -> void:
	# The plugin registers its keys at startup; the headless runner loads no plugin,
	# so register them here. register_all() never saves.
	SettingsRegistration.register_all()
	_test_push_never_touches_project_settings(testing)
	_test_push_replaces_the_set(testing)
	_test_floors(testing)
	_test_effective_value_and_reply(testing)
	_test_save_read_uses_effective_cap(testing)
	_test_script_read_uses_effective_cap(testing)
	_test_default_limits(testing)
	_test_shared_range_table(testing)
	_test_dock_override_lines(testing)
	_test_dock_follows_env_overrides(testing)
	_test_retired_note_key(testing)
	await _test_in_tree_refresh_fires_no_value_changed(testing, tree)
	await _test_transport_sizes_peer_from_caller(testing, tree)


# --- A push never writes ProjectSettings ---------------------------------------
# The leak this layer closes: a pushed value set in ProjectSettings is saved into
# project.godot by the next save from any source. After a push, every limit's
# setting is unchanged and the property list has no new entry.

static func _test_push_never_touches_project_settings(testing) -> void:
	testing.begin("meta.set_limits never writes ProjectSettings")
	ResponseLimits.clear_env_overrides()
	var values_before := _limit_settings()
	var names_before := _property_names()
	# Each pushed value differs from its project value, so a write would show.
	var pushed := {}
	for key in ResponseLimits.KEYS:
		pushed[key] = ResponseLimits.project_value(key) + 64
	MetaCommands._cmd_set_limits(pushed)
	var values_after := _limit_settings()
	var names_after := _property_names()
	ResponseLimits.clear_env_overrides()

	for key in ResponseLimits.KEYS:
		testing.eq(values_after[key], values_before[key],
				"%s: the project value is unchanged after a push" % key)
	testing.ok(names_after == names_before, "the ProjectSettings property list has no new entry")
	print("")


# --- Each push replaces the whole set ------------------------------------------
# The server pushes its whole set after every auth, so a limit missing from a push
# has lost its variable: its env override must go, and an empty push clears all.

static func _test_push_replaces_the_set(testing) -> void:
	testing.begin("A push replaces the env-override set")
	ResponseLimits.clear_env_overrides()
	var notifications := [0]
	var count_notification := func() -> void: notifications[0] += 1
	var env_overrides_changed: Signal = ResponseLimits.env_overrides_changed()
	env_overrides_changed.connect(count_notification)

	ResponseLimits.replace_env_overrides({_SCRIPT: 512, _SAVE: 512, _WS: 2048})
	var full_set := _active_overrides()
	var notified_on_change: int = notifications[0]
	ResponseLimits.replace_env_overrides({_SCRIPT: 512, _SAVE: 512, _WS: 2048})
	var notified_on_same_set: int = notifications[0]
	ResponseLimits.replace_env_overrides({_SCRIPT: 1024})
	var partial_set := _active_overrides()
	var script_override_kb := ResponseLimits.env_override_kb(_SCRIPT)
	ResponseLimits.replace_env_overrides({_SCRIPT: 1024, _SAVE: null, _WS: null})
	var null_set := _active_overrides()
	ResponseLimits.replace_env_overrides({})
	var empty_set := _active_overrides()
	env_overrides_changed.disconnect(count_notification)
	ResponseLimits.clear_env_overrides()

	testing.eq(full_set, [_SCRIPT, _SAVE, _WS], "a push of all three sets all three")
	testing.eq(notified_on_change, 1, "a push that changes the set notifies once")
	testing.eq(notified_on_same_set, 1, "a push of the same set does not notify")
	testing.eq(partial_set, [_SCRIPT], "a partial push clears the absent keys")
	testing.eq(script_override_kb, 1024, "the pushed key carries the new value")
	testing.eq(null_set, [_SCRIPT], "a null value counts as absent")
	testing.eq(empty_set, [], "an empty push clears every env override")
	print("")


# --- Floors ----------------------------------------------------------------------
# A limit never goes below its floor, whether the low value was pushed or stored.

static func _test_floors(testing) -> void:
	testing.begin("Below-floor pushes and project values come back at the floor")
	ResponseLimits.clear_env_overrides()
	var reply: Dictionary = MetaCommands._cmd_set_limits({_SCRIPT: 1, _SAVE: 1, _WS: 1})
	ResponseLimits.clear_env_overrides()

	var originals := _limit_settings()
	for key in ResponseLimits.KEYS:
		ProjectSettings.set_setting(ResponseLimits.setting_path(key), 1)
	var floored_project := _effective_values()
	_restore_limit_settings(originals)

	testing.eq(int(reply.get(_SCRIPT, -1)), 64, "pushed script cap 1 → 64")
	testing.eq(int(reply.get(_SAVE, -1)), 64, "pushed save cap 1 → 64")
	testing.eq(int(reply.get(_WS, -1)), 256, "pushed WS buffer 1 → 256")
	testing.eq(floored_project, [64, 64, 256], "project values of 1 → 64 / 64 / 256")
	print("")


# --- Effective value -------------------------------------------------------------
# The env override wins where one is active; every other limit reads its project
# value. meta.set_limits replies with the three effective values.

static func _test_effective_value_and_reply(testing) -> void:
	testing.begin("Effective value = env override, else project value; the reply carries all three")
	ResponseLimits.clear_env_overrides()
	var originals := _limit_settings()
	ProjectSettings.set_setting(ResponseLimits.setting_path(_SCRIPT), 512)
	ProjectSettings.set_setting(ResponseLimits.setting_path(_SAVE), 1024)
	ProjectSettings.set_setting(ResponseLimits.setting_path(_WS), 2048)
	var without_override := _effective_values()
	var reply: Dictionary = MetaCommands._cmd_set_limits({_SCRIPT: 1536})
	var with_override := _effective_values()
	ResponseLimits.clear_env_overrides()
	_restore_limit_settings(originals)

	testing.eq(without_override, [512, 1024, 2048], "no env override → the project values")
	testing.eq(with_override, [1536, 1024, 2048], "the script cap's env override wins; the rest stay")
	testing.ok(bool(reply.get("success", false)), "meta.set_limits succeeds")
	testing.eq(int(reply.get(_SCRIPT, -1)), 1536, "reply: script cap = its env override")
	testing.eq(int(reply.get(_SAVE, -1)), 1024, "reply: save cap = its project value")
	testing.eq(int(reply.get(_WS, -1)), 2048, "reply: WS buffer = its project value")
	print("")


# --- The command readers enforce the effective value -----------------------------
# save.read checks max_bytes against the save cap before it touches the file, so an
# env override below the project value must reject a window the project allows.

static func _test_save_read_uses_effective_cap(testing) -> void:
	testing.begin("save.read enforces the effective save cap")
	ResponseLimits.clear_env_overrides()
	var originals := _limit_settings()
	ProjectSettings.set_setting(ResponseLimits.setting_path(_SAVE), 256)
	# No such file: the cap check runs before the file is opened, so a window that
	# passes it fails later on the missing file instead.
	var window := {"path": "user://response_limits_missing.txt", "max_bytes": 100 * 1024}
	var under_project_value: Dictionary = SaveCommands._cmd_save_read(window)
	ResponseLimits.replace_env_overrides({_SAVE: 64})
	var under_override: Dictionary = SaveCommands._cmd_save_read(window)
	ResponseLimits.clear_env_overrides()
	_restore_limit_settings(originals)

	testing.ok(not str(under_project_value.get("error", "")).contains("max_bytes must be"),
			"a 100 KB window passes the 256 KB project value")
	testing.eq(str(under_override.get("code", "")), "INVALID_PARAMS",
			"a 100 KB window fails a 64 KB env override")
	testing.ok(str(under_override.get("error", "")).contains("1..65536"),
			"the error names the effective cap in bytes")
	print("")


# script.read checks the whole file against the script cap. A 200 KB res:// fixture
# sits between a 128 KB project value and a 256 KB env override, so the full read
# succeeds only while the env override is active; a project value of 1 KB shows the
# floor. The fixture is removed before the case returns.

static func _test_script_read_uses_effective_cap(testing) -> void:
	testing.begin("script.read enforces the effective script cap")
	ResponseLimits.clear_env_overrides()
	var fixture := "res://response_limits_script_read_fixture.gd"
	var fixture_file := FileAccess.open(fixture, FileAccess.WRITE)
	testing.ok(fixture_file != null, "the 200 KB fixture opened for write")
	if fixture_file == null:
		return
	# 3200 comment lines of 63 bytes: 204,799 bytes, still valid GDScript.
	var fixture_line := "#" + "x".repeat(62)
	var fixture_lines := PackedStringArray()
	for _line_index in 3200:
		fixture_lines.append(fixture_line)
	fixture_file.store_string("\n".join(fixture_lines))
	fixture_file.close()
	var read_request := {"file_path": fixture}

	var originals := _limit_settings()
	ProjectSettings.set_setting(ResponseLimits.setting_path(_SCRIPT), 128)
	ResponseLimits.replace_env_overrides({_SCRIPT: 256})
	var under_override: Dictionary = ScriptCommands._cmd_script_read(read_request)
	ResponseLimits.clear_env_overrides()
	var under_project_value: Dictionary = ScriptCommands._cmd_script_read(read_request)
	ProjectSettings.set_setting(ResponseLimits.setting_path(_SCRIPT), 1)
	var under_floor: Dictionary = ScriptCommands._cmd_script_read(read_request)
	_restore_limit_settings(originals)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(fixture))
	var fixture_removed := not FileAccess.file_exists(fixture)

	testing.ok(bool(under_override.get("success", false)),
			"a 200 KB script reads whole under a 256 KB env override")
	testing.eq(str(under_project_value.get("code", "")), "FILE_TOO_LARGE",
			"with the layer cleared, the 128 KB project value rejects it")
	testing.ok(str(under_project_value.get("error", "")).contains("exceeds 128 KB"),
			"the error names the project value")
	testing.ok(str(under_floor.get("error", "")).contains("exceeds 64 KB"),
			"a project value of 1 KB is raised to the 64 KB floor")
	testing.ok(fixture_removed, "the fixture is removed")
	print("")


# --- The toolkit's default limits ------------------------------------------------

static func _test_default_limits(testing) -> void:
	testing.begin("The toolkit's default limits are 256 / 256 / 1024 KB")
	testing.eq(ResponseLimits.default_kb(_SCRIPT), 256, "script cap default 256 KB")
	testing.eq(ResponseLimits.default_kb(_SAVE), 256, "save cap default 256 KB")
	testing.eq(ResponseLimits.default_kb(_WS), 1024, "WS buffer default 1024 KB")
	print("")


# --- One range table for the inspector and the dock ------------------------------

static func _test_shared_range_table(testing) -> void:
	testing.begin("The response-limits table drives the registered hints and the spin boxes")
	var limits := DockLimitsSection.new()
	var spinbox_ranges := {}
	for key in ResponseLimits.KEYS:
		var spinbox: SpinBox = limits._spinboxes[key]
		spinbox_ranges[key] = "%d,%d,%d" % [
				int(spinbox.min_value), int(spinbox.max_value), int(spinbox.step)]
	limits.free()

	for key in ResponseLimits.KEYS:
		var table_hint := ResponseLimits.range_hint(key)
		var info := _property_info(ResponseLimits.setting_path(key))
		testing.eq(str(info.get("hint_string", "")), table_hint,
				"%s: the registered hint is the table's range" % key)
		testing.eq(str(spinbox_ranges[key]), table_hint,
				"%s: the spin box range is the table's range" % key)
	print("")


# --- The dock: project value plus the field's override line ----------------------
# Off the tree; refresh() is called directly. The line shows the exact value in
# use (1000 is off the spin box's 64 KB step) and names the variable; the save cap
# has no variable, so its line names none.

static func _test_dock_override_lines(testing) -> void:
	testing.begin("Dock: the project value in the spin box, an override line per env override")
	ResponseLimits.clear_env_overrides()
	var originals := _limit_settings()
	ProjectSettings.set_setting(ResponseLimits.setting_path(_SCRIPT), 512)
	ProjectSettings.set_setting(ResponseLimits.setting_path(_SAVE), 512)
	ProjectSettings.set_setting(ResponseLimits.setting_path(_WS), 2048)
	var limits := DockLimitsSection.new()
	limits.refresh()
	var lines_without_override := _visible_lines(limits)

	ResponseLimits.replace_env_overrides({_SCRIPT: 1000, _SAVE: 100, _WS: 3000})
	limits.refresh()
	var shown := [
		int(limits._script_cap_spinbox.value),
		int(limits._save_cap_spinbox.value),
		int(limits._ws_buffer_spinbox.value),
	]
	var lines_with_override := _visible_lines(limits)
	var script_line := str(limits._override_lines[_SCRIPT].text)
	var save_line := str(limits._override_lines[_SAVE].text)
	var ws_line := str(limits._override_lines[_WS].text)

	ResponseLimits.replace_env_overrides({_WS: 3000})
	limits.refresh()
	var lines_after_partial := _visible_lines(limits)
	ResponseLimits.clear_env_overrides()
	limits.refresh()
	var lines_after_clear := _visible_lines(limits)
	limits.free()
	_restore_limit_settings(originals)

	testing.eq(lines_without_override, [], "no env override → no override line")
	testing.eq(shown, [512, 512, 2048], "the spin boxes keep showing the project values")
	testing.eq(lines_with_override, [_SCRIPT, _SAVE, _WS], "one override line per env override")
	testing.ok(script_line.contains("1000 KB"), "script line shows the exact KB in use")
	testing.ok(script_line.contains("GODOT_MCP_SCRIPT_READ_LIMIT"), "script line names its variable")
	testing.ok(save_line.contains("100 KB"), "save line shows the exact KB in use")
	testing.ok(not save_line.contains("GODOT_MCP_"), "save line names no variable")
	testing.ok(ws_line.contains("3000 KB"), "WS line shows the exact KB in use")
	testing.ok(ws_line.contains("GODOT_MCP_WS_BUFFER_LIMIT"), "WS line names its variable")
	testing.eq(lines_after_partial, [_WS], "a push without a limit removes its line")
	testing.eq(lines_after_clear, [], "an empty push removes every line")
	print("")


# --- The dock follows the layer's change signal only while in the tree ------------

static func _test_dock_follows_env_overrides(testing) -> void:
	testing.begin("Dock env-override hook connects on enter, disconnects on exit")
	var limits := DockLimitsSection.new()
	var env_overrides_changed: Signal = ResponseLimits.env_overrides_changed()
	limits._enter_tree()
	var connected := env_overrides_changed.is_connected(limits.refresh)
	limits._exit_tree()
	var still_connected := env_overrides_changed.is_connected(limits.refresh)
	limits.free()

	testing.ok(connected, "entering the tree connects refresh() to the change signal")
	testing.ok(not still_connected, "leaving the tree disconnects it")
	print("")


# --- The retired env_override_note key ----------------------------------------------

static func _test_retired_note_key(testing) -> void:
	testing.begin("env_override_note is not registered, and a stored copy is dropped")
	SettingsRegistration.register_all()
	var registered := ProjectSettings.has_setting(_RETIRED_NOTE_KEY)
	var listed := not _property_info(_RETIRED_NOTE_KEY).is_empty()
	# A copy an earlier version saved into project.godot.
	ProjectSettings.set_setting(_RETIRED_NOTE_KEY, "stored by an earlier version")
	SettingsRegistration.register_all()
	var kept := ProjectSettings.has_setting(_RETIRED_NOTE_KEY)

	testing.ok(not registered, "register_all() does not register the note")
	testing.ok(not listed, "the note is not in the property list")
	testing.ok(not kept, "register_all() nulls a stored copy")
	print("")


# --- Inside the tree, refresh() fires no value_changed ------------------------------
# Off the tree a Range never emits value_changed, so only an in-tree run can show
# that refresh() repaints through the no-signal setter. The dock's write handlers
# are disconnected first, so a regression cannot save project.godot; a direct
# assignment afterwards is the control that proves the counter sees an emission.

static func _test_in_tree_refresh_fires_no_value_changed(testing, tree: SceneTree) -> void:
	testing.begin("Dock in the tree: refresh() and a push repaint without value_changed")
	# The runner's root becomes usable once its main loop has started.
	await tree.process_frame
	ResponseLimits.clear_env_overrides()
	var originals := _limit_settings()
	var limits := DockLimitsSection.new()
	limits._script_cap_spinbox.value_changed.disconnect(limits._on_script_cap_changed)
	limits._save_cap_spinbox.value_changed.disconnect(limits._on_save_cap_changed)
	limits._ws_buffer_spinbox.value_changed.disconnect(limits._on_ws_buffer_changed)
	var emissions := [0]
	var count_emission := func(_value: float) -> void: emissions[0] += 1
	for key in ResponseLimits.KEYS:
		var spinbox: SpinBox = limits._spinboxes[key]
		spinbox.value_changed.connect(count_emission)
	tree.root.add_child(limits)
	var in_tree := limits.is_inside_tree()

	var new_values := []
	for key in ResponseLimits.KEYS:
		var project_kb := ResponseLimits.project_value(key)
		var bounds := ResponseLimits.range_bounds(key)
		var new_kb := bounds[0] * 2 if project_kb != bounds[0] * 2 else bounds[0] * 4
		new_values.append(new_kb)
		ProjectSettings.set_setting(ResponseLimits.setting_path(key), new_kb)
	limits.refresh()
	var shown := [
		int(limits._script_cap_spinbox.value),
		int(limits._save_cap_spinbox.value),
		int(limits._ws_buffer_spinbox.value),
	]
	var emissions_after_refresh: int = emissions[0]
	# No refresh() call: the change signal alone repaints the lines.
	ResponseLimits.replace_env_overrides({_SCRIPT: 2048})
	var line_after_push := _visible_lines(limits)
	ResponseLimits.clear_env_overrides()
	var line_after_clear := _visible_lines(limits)
	var emissions_after_push: int = emissions[0]
	limits._script_cap_spinbox.value = limits._script_cap_spinbox.value + 64
	var control_emissions: int = emissions[0] - emissions_after_push

	tree.root.remove_child(limits)
	limits.free()
	_restore_limit_settings(originals)

	testing.ok(in_tree, "the section is inside the tree")
	testing.eq(shown, new_values, "the spin boxes show the new project values")
	testing.eq(emissions_after_refresh, 0, "refresh() fires no value_changed in the tree")
	testing.eq(line_after_push, [_SCRIPT], "a push shows the override line without a refresh() call")
	testing.eq(line_after_clear, [], "an empty push hides it again")
	testing.eq(emissions_after_push, 0, "the push repaint fires no value_changed")
	testing.eq(control_emissions, 1, "control: a direct assignment in the tree does emit")
	print("")


# --- The transport sizes a peer from its owner -------------------------------------
# A real loopback connection: the transport accepts it and sizes both buffers from
# the source its owner injected, asked once for the one peer.

static func _test_transport_sizes_peer_from_caller(testing, tree: SceneTree) -> void:
	testing.begin("Transport sizes an accepted peer from its owner's buffer size")
	var transport := WsTransport.new()
	transport.configure("[TestBuffer]", 18850, 40, "127.0.0.1", 1, 2000, false,
		"no free port in %d-%d", false, "")
	transport.set_handlers(Callable(), Callable(), Callable(), Callable())
	var asked := [0]
	var buffer_kb_source := func() -> int:
		asked[0] += 1
		return 384
	transport.set_buffer_kb_source(buffer_kb_source)
	transport.ensure_listening()
	var port := transport.get_bound_port()
	if port < 0:
		testing.ok(false, "environment: no free port in 18850-18889 to run the accept test")
		return
	var client := StreamPeerTCP.new()
	client.connect_to_host("127.0.0.1", port)
	var deadline := Time.get_ticks_msec() + 3000
	while transport._peers.is_empty() and Time.get_ticks_msec() < deadline:
		client.poll()
		transport.accept_pending()
		if transport._peers.is_empty():
			await tree.process_frame
	var accepted: int = transport._peers.size()
	var inbound := -1
	var outbound := -1
	if accepted > 0:
		var peer: WebSocketPeer = transport._peers[0]
		inbound = peer.inbound_buffer_size
		outbound = peer.outbound_buffer_size
	client.disconnect_from_host()
	transport.close_all(1000, "")
	transport.shutdown_listener()

	testing.eq(accepted, 1, "the loopback connection is accepted")
	testing.eq(inbound, 384 * 1024, "inbound buffer = the owner's size")
	testing.eq(outbound, 384 * 1024, "outbound buffer = the owner's size")
	testing.eq(asked[0], 1, "the size is asked once for the peer")
	print("")


# --- Helpers ------------------------------------------------------------------------

# Each limit's stored setting, as the raw Variant, keyed by limit.
static func _limit_settings() -> Dictionary:
	var values := {}
	for key in ResponseLimits.KEYS:
		values[key] = ProjectSettings.get_setting(ResponseLimits.setting_path(key))
	return values


static func _restore_limit_settings(values: Dictionary) -> void:
	for key in ResponseLimits.KEYS:
		ProjectSettings.set_setting(ResponseLimits.setting_path(key), values[key])


# The three effective values, in table order.
static func _effective_values() -> Array:
	var values := []
	for key in ResponseLimits.KEYS:
		values.append(ResponseLimits.effective_value(key))
	return values


# The keys with an active env override, in table order.
static func _active_overrides() -> Array:
	var keys := []
	for key in ResponseLimits.KEYS:
		if ResponseLimits.has_env_override(key):
			keys.append(key)
	return keys


# The keys whose override line the dock shows, in table order.
static func _visible_lines(limits: DockLimitsSection) -> Array:
	var keys := []
	for key in ResponseLimits.KEYS:
		var override_line: Label = limits._override_lines[key]
		if override_line.visible:
			keys.append(key)
	return keys


static func _property_names() -> PackedStringArray:
	var names := PackedStringArray()
	for entry in ProjectSettings.get_property_list():
		names.append(str(entry.get("name", "")))
	return names


# Returns the ProjectSettings property-list entry for `key`, or {} if absent.
static func _property_info(key: String) -> Dictionary:
	for entry in ProjectSettings.get_property_list():
		var info: Dictionary = entry
		if str(info.get("name", "")) == key:
			return info
	return {}
