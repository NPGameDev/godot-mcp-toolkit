@tool
extends HBoxContainer
## Dock "Responsive when unfocused" sub-panel — opt-in editor throttle toggle.
##
## A dock sub-panel. Constructed and owned by dock.gd; added into the dock's
## tree (so the editor frees it with the dock). Builds its checkbox + 3-state
## indicator once and owns the opt-in EditorSetting read/write. Toggling applies
## the setting immediately via the bound server (conflict-aware / crash-safe
## restore lives server-side — notify_unfocused_responsive_setting_changed());
## refresh() repaints the indicator from live server state without rebuilding.
## Subscribes itself to EditorSettings.settings_changed while in the tree, so a
## toggle made in the Editor Settings dialog repaints the checkbox + label
## immediately instead of waiting for the next connect/disconnect.

const _SETTING_KEY := "mcp_toolkit/performance/keep_editor_responsive_unfocused"

# Server is read for the live indicator (fps + connected) and to apply the
# setting on toggle; held so refresh() can repaint without the dock re-passing it.
var _server: Node = null

var _check: CheckBox = null
var _state_label: Label = null


func _init(server: Node) -> void:
	_server = server

	_check = CheckBox.new()
	_check.text = "Responsive when unfocused"
	var resp_enabled := true
	var resp_es := EditorInterface.get_editor_settings()
	if resp_es != null and resp_es.has_setting(_SETTING_KEY):
		resp_enabled = bool(resp_es.get_setting(_SETTING_KEY))
	_check.set_pressed_no_signal(resp_enabled)
	_check.toggled.connect(_on_toggled)
	add_child(_check)

	_state_label = Label.new()
	_state_label.add_theme_font_size_override("font_size", 11)
	_state_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_state_label)


func _enter_tree() -> void:
	# Live-sync with Editor Settings: an external toggle (the Editor Settings
	# dialog) never routes through this control, so subscribe and repaint. The
	# signal is keyless — no per-key filter exists — and refresh() is cheap and
	# idempotent, so repainting on every settings change is fine. No feedback
	# loop: _on_toggled writes the setting, the resulting signal re-calls
	# refresh(), which re-reads the same value and repaints identically.
	var es := EditorInterface.get_editor_settings()
	if es != null and not es.settings_changed.is_connected(refresh):
		es.settings_changed.connect(refresh)
	# Initial paint — _init builds the label with no text, so without this the
	# indicator stays blank (or stale) until the first connect/disconnect.
	refresh()


func _exit_tree() -> void:
	# The EditorSettings singleton outlives this control — an undisconnected
	# callback would go zombie after the dock is freed.
	var es := EditorInterface.get_editor_settings()
	if es != null and es.settings_changed.is_connected(refresh):
		es.settings_changed.disconnect(refresh)


func _on_toggled(enabled: bool) -> void:
	var es := EditorInterface.get_editor_settings()
	if es != null:
		es.set_setting(_SETTING_KEY, enabled)
	# Apply immediately: on while connected → boost now; off while active →
	# conflict-aware restore now (instead of waiting for the next connect/disconnect).
	if _server != null:
		_server.notify_unfocused_responsive_setting_changed()
	refresh()


## Always-honest 3-state indicator: Off / On (idle) / On · active · {fps} fps.
## Repaints the existing label + keeps the checkbox in sync; mutates only — never
## rebuilds, so it is safe on every refresh trigger and connection edge.
func refresh() -> void:
	if _state_label == null or _check == null:
		return
	var enabled := true
	var es := EditorInterface.get_editor_settings()
	if es != null and es.has_setting(_SETTING_KEY):
		enabled = bool(es.get_setting(_SETTING_KEY))
	# Keep the checkbox in sync if the setting was changed in Editor Settings.
	if _check.button_pressed != enabled:
		_check.set_pressed_no_signal(enabled)
	var fps: int = _server.get_unfocused_responsive_fps() if _server != null else 60
	var connected: bool = _server != null and _server.get_authed_peer_count() > 0
	_check.tooltip_text = (
		"Editor stays ~%d fps while unfocused so MCP commands stay responsive "
		+ "while a client is connected — raises background CPU. Off uses Godot's "
		+ "default low-power unfocused throttle. Configure the rate in "
		+ "Editor Settings → Mcp Toolkit → Performance.") % fps
	if not enabled:
		_state_label.text = "Off"
		_state_label.remove_theme_color_override("font_color")
	elif not connected:
		_state_label.text = "On (idle)"
		_state_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	else:
		_state_label.text = "On · active · %d fps" % fps
		_state_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
