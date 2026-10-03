@tool
extends RefCounted
## Dock ↔ Project Settings sync unit tests: the dock's limits and audit sections
## repaint every control from its ProjectSetting, the audit checkbox without
## firing toggled; they keep their settings_changed hook connected only while in
## the tree; and the four dock-backed keys register the same ranges as the dock's
## spin boxes. Settings change in memory only and are restored; nothing calls
## ProjectSettings.save().

const DockLimitsSection := preload("res://addons/godot_mcp_toolkit/ui/dock/limits/dock_limits_section.gd")
const DockAuditSection := preload("res://addons/godot_mcp_toolkit/ui/dock/security/dock_audit_section.gd")
const SettingsRegistration := preload("res://addons/godot_mcp_toolkit/core/settings_registration.gd")

const _SCRIPT_CAP_KEY := "mcp_toolkit/limits/script_read_cap_kb"
const _SAVE_CAP_KEY := "mcp_toolkit/limits/save_read_cap_kb"
const _WS_BUFFER_KEY := "mcp_toolkit/limits/ws_buffer_kb"
const _AUDIT_ENABLED_KEY := "mcp_toolkit/audit/enabled"
const _AUDIT_MAX_SIZE_KEY := "mcp_toolkit/audit/max_size_kb"


static func run(testing) -> void:
	# The plugin registers its keys before it builds the dock; the headless runner
	# loads no plugin, so register them here. register_all() never saves, so
	# project.godot is untouched.
	SettingsRegistration.register_all()
	_test_refresh_follows_settings(testing)
	_test_settings_changed_hook(testing)
	_test_range_hints(testing)


# --- refresh() repaints every control; the checkbox fires no toggled ---------
# An edit made in the Project Settings inspector reaches the dock only through
# refresh(), which must assign through the no-signal setters: each control's write
# handler saves project.godot, so a refresh that fired one would turn into a save.
# Off the tree a Range never emits value_changed, but BaseButton.set_pressed emits
# toggled anyway, so a counter on the audit checkbox's toggled is the regression
# guard. The spin boxes' no-signal repaint is not observable off the tree; for
# them this group pins only the refreshed values. Both sections stay off the tree,
# so their live settings_changed hook never connects and each refresh() call below
# is the only refresh. A regression that does fire the handler rewrites the
# dogfood project.godot; `git restore project.godot` undoes it.

static func _test_refresh_follows_settings(testing) -> void:
	testing.begin("Dock refresh() repaints every control; the checkbox repaint fires no toggled")
	# Coerced, not inferred: get_setting returns a Variant.
	var orig_script_cap: int = int(ProjectSettings.get_setting(_SCRIPT_CAP_KEY, 256))
	var orig_save_cap: int = int(ProjectSettings.get_setting(_SAVE_CAP_KEY, 256))
	var orig_ws_buffer: int = int(ProjectSettings.get_setting(_WS_BUFFER_KEY, 1024))
	var orig_audit_enabled: bool = bool(ProjectSettings.get_setting(_AUDIT_ENABLED_KEY, true))
	var orig_audit_max_size: int = int(ProjectSettings.get_setting(_AUDIT_MAX_SIZE_KEY, 1024))

	var limits := DockLimitsSection.new()
	var audit := DockAuditSection.new("", Callable())
	var toggled_count := [0]
	audit._enabled_checkbox.toggled.connect(func(_pressed: bool) -> void: toggled_count[0] += 1)

	# In range, on step, and different from the stored value, so each refresh()
	# has something to repaint.
	var new_script_cap := 1024 if orig_script_cap != 1024 else 2048
	var new_save_cap := 512 if orig_save_cap != 512 else 1024
	var new_ws_buffer := 2048 if orig_ws_buffer != 2048 else 4096
	var new_audit_enabled := not orig_audit_enabled
	var new_audit_max_size := 2048 if orig_audit_max_size != 2048 else 4096
	ProjectSettings.set_setting(_SCRIPT_CAP_KEY, new_script_cap)
	ProjectSettings.set_setting(_SAVE_CAP_KEY, new_save_cap)
	ProjectSettings.set_setting(_WS_BUFFER_KEY, new_ws_buffer)
	ProjectSettings.set_setting(_AUDIT_ENABLED_KEY, new_audit_enabled)
	ProjectSettings.set_setting(_AUDIT_MAX_SIZE_KEY, new_audit_max_size)

	limits.refresh()
	audit.refresh()
	var shown_script_cap := int(limits._script_cap_spinbox.value)
	var shown_save_cap := int(limits._save_cap_spinbox.value)
	var shown_ws_buffer := int(limits._ws_buffer_spinbox.value)
	var shown_audit_enabled := audit._enabled_checkbox.button_pressed
	var shown_audit_max_size := int(audit._max_size_spinbox.value)
	var toggles_after_first: int = toggled_count[0]
	# A second refresh has nothing new to repaint.
	limits.refresh()
	audit.refresh()
	var toggles_after_second: int = toggled_count[0]

	# Restore before asserting, so a failed check never leaves the settings changed
	# for the modules that run after this one.
	ProjectSettings.set_setting(_SCRIPT_CAP_KEY, orig_script_cap)
	ProjectSettings.set_setting(_SAVE_CAP_KEY, orig_save_cap)
	ProjectSettings.set_setting(_WS_BUFFER_KEY, orig_ws_buffer)
	ProjectSettings.set_setting(_AUDIT_ENABLED_KEY, orig_audit_enabled)
	ProjectSettings.set_setting(_AUDIT_MAX_SIZE_KEY, orig_audit_max_size)
	limits.free()
	audit.free()

	testing.eq(shown_script_cap, new_script_cap, "script cap spin box shows the new setting")
	testing.eq(shown_save_cap, new_save_cap, "save cap spin box shows the new setting")
	testing.eq(shown_ws_buffer, new_ws_buffer, "WS buffer spin box shows the new setting")
	testing.eq(shown_audit_enabled, new_audit_enabled,
			"audit Enabled checkbox shows the new setting")
	testing.eq(shown_audit_max_size, new_audit_max_size,
			"audit Max KB spin box shows the new setting")
	testing.eq(toggles_after_first, 0, "refresh() fires no toggled (no-signal setter)")
	testing.eq(toggles_after_second, 0, "a second refresh() still fires no toggled")
	print("")


# --- The settings_changed hook is connected only while in the tree ---------
# ProjectSettings outlives the dock, so each section connects refresh() on tree
# entry, behind an is_connected guard, and disconnects it on exit: a missed
# disconnect leaves the singleton calling into a panel that has left the dock. The
# hooks are called directly, as the scene tree would call them on entry and exit.
# No frame passes between the calls, so the deferred signal never fires here.

static func _test_settings_changed_hook(testing) -> void:
	testing.begin("Dock settings_changed hook connects on enter, disconnects on exit")
	var limits := DockLimitsSection.new()
	var audit := DockAuditSection.new("", Callable())

	limits._enter_tree()
	audit._enter_tree()
	var limits_connected := ProjectSettings.settings_changed.is_connected(limits.refresh)
	var audit_connected := ProjectSettings.settings_changed.is_connected(audit.refresh)
	limits._exit_tree()
	audit._exit_tree()
	var limits_still_connected := ProjectSettings.settings_changed.is_connected(limits.refresh)
	var audit_still_connected := ProjectSettings.settings_changed.is_connected(audit.refresh)
	limits.free()
	audit.free()

	testing.ok(limits_connected, "limits section: entering the tree connects refresh()")
	testing.ok(not limits_still_connected,
			"limits section: leaving the tree disconnects refresh()")
	testing.ok(audit_connected, "audit section: entering the tree connects refresh()")
	testing.ok(not audit_still_connected,
			"audit section: leaving the tree disconnects refresh()")
	print("")


# --- The four dock-backed keys register the dock's ranges ------------------
# An unhinted int setting gets an unbounded inspector editor while the dock clamps
# and snaps, so the two surfaces would disagree on what a value may be. Each
# dock-backed key registers PROPERTY_HINT_RANGE with its spin box's exact range.
# The concurrency keys stay unhinted: "not clamped" is their documented contract.

static func _test_range_hints(testing) -> void:
	testing.begin("Dock-backed settings register the dock's spin-box ranges")
	var limits := DockLimitsSection.new()
	var audit := DockAuditSection.new("", Callable())
	var script_cap_range := _spinbox_range(limits._script_cap_spinbox)
	var save_cap_range := _spinbox_range(limits._save_cap_spinbox)
	var ws_buffer_range := _spinbox_range(limits._ws_buffer_spinbox)
	var audit_max_size_range := _spinbox_range(audit._max_size_spinbox)
	limits.free()
	audit.free()

	_check_range_hint(testing, _SCRIPT_CAP_KEY, "64,4096,64", script_cap_range)
	_check_range_hint(testing, _SAVE_CAP_KEY, "64,4096,64", save_cap_range)
	_check_range_hint(testing, _WS_BUFFER_KEY, "256,8192,256", ws_buffer_range)
	_check_range_hint(testing, _AUDIT_MAX_SIZE_KEY, "0,10240,128", audit_max_size_range)

	var scan_timeout_info := _property_info("mcp_toolkit/concurrency/scan_idle_timeout_ms")
	testing.eq(int(scan_timeout_info.get("hint", -1)), PROPERTY_HINT_NONE,
			"scan_idle_timeout_ms stays unhinted (not clamped)")
	var watchdog_grace_info := _property_info("mcp_toolkit/concurrency/mutation_watchdog_grace_ms")
	testing.eq(int(watchdog_grace_info.get("hint", -1)), PROPERTY_HINT_NONE,
			"mutation_watchdog_grace_ms stays unhinted (not clamped)")
	print("")


# Asserts that `key` registers PROPERTY_HINT_RANGE with exactly `expected_hint`,
# and that the dock spin box editing it, whose bounds are `dock_range`, accepts the
# same range.
static func _check_range_hint(
		testing, key: String, expected_hint: String, dock_range: String) -> void:
	var info := _property_info(key)
	testing.eq(int(info.get("hint", -1)), PROPERTY_HINT_RANGE,
			"%s → PROPERTY_HINT_RANGE" % key)
	testing.eq(str(info.get("hint_string", "")), expected_hint,
			"%s → hint string \"%s\"" % [key, expected_hint])
	testing.eq(dock_range, expected_hint,
			"%s → the dock spin box accepts the same range" % key)


# Formats a spin box's bounds the way a PROPERTY_HINT_RANGE hint string does.
static func _spinbox_range(spinbox: SpinBox) -> String:
	return "%d,%d,%d" % [int(spinbox.min_value), int(spinbox.max_value), int(spinbox.step)]


# Returns the ProjectSettings property-list entry for `key`, or {} if absent.
static func _property_info(key: String) -> Dictionary:
	for entry in ProjectSettings.get_property_list():
		var info: Dictionary = entry
		if str(info.get("name", "")) == key:
			return info
	return {}
