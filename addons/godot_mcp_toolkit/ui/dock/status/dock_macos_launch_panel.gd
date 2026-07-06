@tool
extends PanelContainer
## Dock macOS "listening, but no client connected" guidance panel.
##
## A persistent, all-version (4.2-4.7) warning surface shown when the toolkit is
## listening and a valid .mcp.json is present but no MCP client has connected after
## a grace period — a calm nudge naming what to check. Unlike a toast (4.4+ only,
## transient), this is a pure PanelContainer/Label that renders on every supported
## editor. The dock owns the connection-state gate (MacosLaunchHint.should_show) and
## drives visibility via set_shown(); this panel only renders the message and a
## session dismiss control.
##
## State-driven: the dock re-evaluates the gate on its 1s timer and on client
## connect, so the panel reflects the current state no matter what changed it (a
## client connecting, the config being fixed). The close control dismisses it for
## the session — the dock latches the flag and stops re-showing.

## Emitted when the user clicks the close control — the dock latches a session
## dismiss flag so the guidance stays hidden until the next editor session.
signal dismissed

# The guidance label (this PanelContainer is the warning surface). Built once in
# _init(); its text is the injected message and never changes at runtime.
var _message_label: Label = null


func _init(message: String) -> void:
	# Amber warning card matching the .mcp.json health panel's style so the two
	# dock warnings read as one visual family.
	var warn_sb := StyleBoxFlat.new()
	warn_sb.bg_color = Color(0.35, 0.22, 0.0)
	warn_sb.corner_radius_top_left = 4
	warn_sb.corner_radius_top_right = 4
	warn_sb.corner_radius_bottom_left = 4
	warn_sb.corner_radius_bottom_right = 4
	warn_sb.content_margin_left = 8
	warn_sb.content_margin_right = 8
	warn_sb.content_margin_top = 6
	warn_sb.content_margin_bottom = 6
	add_theme_stylebox_override("panel", warn_sb)
	visible = false

	var row := HBoxContainer.new()
	add_child(row)

	_message_label = Label.new()
	_message_label.text = message
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	_message_label.add_theme_font_size_override("font_size", 12)
	_message_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_message_label)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.tooltip_text = "Dismiss for this session"
	close_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	close_btn.pressed.connect(_on_close_pressed)
	row.add_child(close_btn)


## Show or hide the guidance. The dock computes the gate and calls this on every
## refresh, so the panel is fully state-driven: it hides again the moment a client
## connects, the config is fixed, or the user dismisses it.
func set_shown(shown: bool) -> void:
	visible = shown


func _on_close_pressed() -> void:
	dismissed.emit()
