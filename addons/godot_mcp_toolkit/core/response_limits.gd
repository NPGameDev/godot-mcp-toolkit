@tool
extends RefCounted
## The response limits: the caps on how much a tool may return, and the one place
## that resolves the value the toolkit enforces for each.
##
## A response limit has a project value (its [code]mcp_toolkit/limits/*[/code]
## setting, the one the dock and the Project Settings inspector edit) and at most
## one env override (pushed by the MCP server from an environment variable in the
## client's config). The effective value is the env override when one is active,
## else the project value, never below the limit's floor. The editor's readers of
## a limit ask this file for the effective value, so the floor is applied in one
## place.[br]
## [br]
## Env overrides are held here, in memory, for the editor session, and never
## written to [ProjectSettings]: anything that saves the project would otherwise
## copy one developer's environment into the shared [code]project.godot[/code].
## Each push from the server is its whole set and replaces the previous one, so
## an empty push clears them. GDScript has no static signals, so the change
## notification is a signal on one shared instance, reached through
## [method env_overrides_changed].[br]
## [br]
## Editor-side: the runtime autoload sizes its connections from the project value
## by design, so it reads that setting itself instead of using this file.

const SCRIPT_READ_CAP_KB := "script_read_cap_kb"
const SAVE_READ_CAP_KB := "save_read_cap_kb"
const WS_BUFFER_KB := "ws_buffer_kb"
## Every response limit, in the order the dock shows them.
const KEYS: Array[String] = [SCRIPT_READ_CAP_KB, SAVE_READ_CAP_KB, WS_BUFFER_KB]

const _SETTING_PREFIX := "mcp_toolkit/limits/"
# One entry per limit, in KB. "range" is [min, max, step] for the Project Settings
# inspector and the dock's spin box alike, so the two surfaces accept the same
# values. "variable" is the environment variable the server reads for the limit;
# the save cap has none, and only a direct meta.set_limits call can push it.
const _TABLE := {
	# Max script content returned by script.read.
	SCRIPT_READ_CAP_KB: {
		"default": 256,
		"floor": 64,
		"range": [64, 4096, 64],
		"variable": "GODOT_MCP_SCRIPT_READ_LIMIT",
	},
	# Max user-file content returned per save.read window.
	SAVE_READ_CAP_KB: {
		"default": 256,
		"floor": 64,
		"range": [64, 4096, 64],
		"variable": "",
	},
	# WebSocket per-peer buffer size, fixed for a connection when it is accepted.
	WS_BUFFER_KB: {
		"default": 1024,
		"floor": 256,
		"range": [256, 8192, 256],
		"variable": "GODOT_MCP_WS_BUFFER_LIMIT",
	},
}


# Carries the change signal: a static layer has no instance of its own to emit on.
# Declared above its first use, as a static variable's type must be.
class _ChangeNotifier extends RefCounted:
	signal changed


# Active env overrides, limit key -> KB as pushed (the floor is applied on read).
static var _env_overrides: Dictionary = {}
static var _change_notifier: _ChangeNotifier = null


## The [ProjectSettings] path that stores [param key]'s project value.
static func setting_path(key: String) -> String:
	return _SETTING_PREFIX + key


## The registered default of [param key], in KB.
static func default_kb(key: String) -> int:
	return int(_entry(key)["default"])


## The lowest value the toolkit enforces for [param key], in KB.
static func floor_kb(key: String) -> int:
	return int(_entry(key)["floor"])


## Returns [param key]'s editable range as [code][min, max, step][/code], in KB.
static func range_bounds(key: String) -> Array[int]:
	var bounds: Array[int] = []
	for bound in _entry(key)["range"]:
		bounds.append(int(bound))
	return bounds


## Returns [param key]'s editable range as a [code]PROPERTY_HINT_RANGE[/code] hint
## string, [code]"min,max,step"[/code].
static func range_hint(key: String) -> String:
	var bounds := range_bounds(key)
	return "%d,%d,%d" % [bounds[0], bounds[1], bounds[2]]


## The environment variable the server reads for [param key], or an empty string
## when the limit has none.
static func env_variable(key: String) -> String:
	return str(_entry(key)["variable"])


## [param key]'s project value in KB: the stored setting, or its default when the
## project stores none. Not floored; it is what the project says.
static func project_value(key: String) -> int:
	return int(ProjectSettings.get_setting(setting_path(key), default_kb(key)))


## True while the server has an env override active for [param key].
static func has_env_override(key: String) -> bool:
	return _env_overrides.has(key)


## [param key]'s env override in KB as pushed, or 0 when none is active.
static func env_override_kb(key: String) -> int:
	return int(_env_overrides.get(key, 0))


## The value the toolkit enforces for [param key], in KB: the env override when one
## is active, else the project value, raised to the limit's floor.
static func effective_value(key: String) -> int:
	var value_kb := env_override_kb(key) if has_env_override(key) else project_value(key)
	return maxi(value_kb, floor_kb(key))


## Replaces the whole env-override set with the limits [param pushed] carries.
## A limit counts when its key is present and not [code]null[/code]; its value is
## coerced to an int. A limit the push leaves out loses its env override, so an
## empty push clears them all. Unknown keys are ignored. Emits the change signal
## when the set differs from the previous one.
static func replace_env_overrides(pushed: Dictionary) -> void:
	var next_overrides := {}
	for key in KEYS:
		var pushed_value: Variant = pushed.get(key, null)
		if pushed_value != null:
			next_overrides[key] = int(pushed_value)
	if next_overrides == _env_overrides:
		return
	_env_overrides = next_overrides
	if _change_notifier != null:
		_change_notifier.changed.emit()


## Drops every env override, as an empty push does. Call it when the plugin tears
## down: this static state outlives a plugin reload, and the server pushes its set
## afresh once the next connection authenticates.
static func clear_env_overrides() -> void:
	replace_env_overrides({})


## The signal emitted when a push changes the env-override set. Connect to it, and
## disconnect from it, through the returned [Signal].
static func env_overrides_changed() -> Signal:
	if _change_notifier == null:
		_change_notifier = _ChangeNotifier.new()
	return _change_notifier.changed


static func _entry(key: String) -> Dictionary:
	return _TABLE[key]
