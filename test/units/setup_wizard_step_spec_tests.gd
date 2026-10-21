@tool
extends RefCounted
## Pinning tests for the setup wizard's step copy: every step's spec dictionary,
## verbatim, as the wizard's dispatch returns it, and the .mcp.json step's pin-choice
## control for each pin mode. The specs are compared whole, so a move of the copy
## keeps every string, label, action and flag.

const OnboardingWizard := preload("res://addons/godot_mcp_toolkit/ui/onboarding_wizard.gd")
const StepSpecs := preload("res://addons/godot_mcp_toolkit/ui/setup_wizard/step_specs.gd")
const SetupSteps := preload("res://addons/godot_mcp_toolkit/core/setup_steps.gd")

const _VERSION_SETTING := "mcp_toolkit/server/version"

const _WELCOME_TEXT := (
	"Welcome to the Godot MCP Toolkit!\n\n"
	+ "This plugin exposes your Godot editor to AI agents via MCP.\n"
	+ "Some tools can modify your project or execute arbitrary code.\n\n"
	+ "Risk is communicated per-tool via MCP annotations.\n"
	+ "For details and copy-pasteable agent blocking configs, see:\n"
	+ "  addons/godot_mcp_toolkit/docs/security-recommendations.md\n\n"
	+ "All tools are available by default. Use your agent's\n"
	+ "allowlist/blocklist to restrict specific tools if needed.")
const _MCP_JSON_INTRO := (
	"Your MCP client reads .mcp.json from the project root "
	+ "to locate and configure the server.\n\n"
	+ "The MCP server bridge requires Node.js 22+ to run. "
	+ "Download it from https://nodejs.org if not installed.\n\n")
const _MCP_JSON_EXISTS_TEXT := (
	"An .mcp.json already exists in your project. The server choice "
	+ "below applies only if you press Write .mcp.json.")
const _MCP_JSON_MISSING_TEXT := (
	"No .mcp.json was found — this file is required for your "
	+ "MCP client to connect to the toolkit.")
const _OPTIONAL_STEPS_TEXT := (
	"Toolkit updates sometimes add steps to this wizard. When one does, the next time "
	+ "you start the editor you'll see only the new steps.\n\n"
	+ "Some steps are required because you lose something by skipping them: without "
	+ ".mcp.json your AI client won't find the toolkit on its own, and the update check "
	+ "only starts once you've seen the update-check step. Required steps come back at "
	+ "every editor start until you've seen them. \"Remind me later\" puts them off until "
	+ "the next start.\n\n"
	+ "The other steps are optional. Untick the box below and optional steps that future "
	+ "updates add won't show, in any project on this machine. Required steps still show.")
const _UPDATES_TEXT := (
	"At most once a day, the toolkit asks GitHub whether a newer version is out. If one "
	+ "is, it also asks the Asset Store whether it lists that version yet. When there's a "
	+ "newer version, a closable badge at the top of the MCP Toolkit dock links to it. The "
	+ "toolkit never installs anything by itself.\n\n"
	+ "These requests carry no identifier and nothing about your project. Untick the box "
	+ "below and the toolkit sends no requests at all.\n\n"
	+ "You can change this later in Project Settings under Mcp Toolkit > Updates. It's "
	+ "saved in project.godot, so it applies to everyone who works on this project.")
const _DOCK_TEXT := (
	"The MCP Toolkit dock is in the bottom panel (next to Output and Debugger). "
	+ "From here you can:\n\n"
	+ "  • Monitor server status — connection state, peer count, runtime port\n"
	+ "  • Review the audit log — see what the AI agent did\n"
	+ "  • Adjust security settings — token rotation, response limits\n\n"
	+ "The 'Info / Help' button shows tool list and documentation links.\n"
	+ "Companion Skills for Claude Code are in the dock footer.\n\n"
	+ "For supervised environments, set GODOT_MCP_READ_ONLY=1 in\n"
	+ ".mcp.json to restrict the toolkit to read-only tools.\n\n"
	+ "The toolkit keeps the editor responsive while it's unfocused during\n"
	+ "MCP sessions (ON by default; raises background CPU). Toggle it in the\n"
	+ "dock's Server Status, or in Editor Settings → Mcp Toolkit → Performance.\n\n"
	+ "The dock's limits and audit controls are shortcuts into\n"
	+ "Project Settings → Mcp Toolkit, where all per-project options\n"
	+ "live (including advanced ones the dock doesn't surface).\n\n"
	+ "You're all set!")
const _PINNED_DETAIL := "Uses the server version this toolkit was tested with. Updating the toolkit updates the server."
const _LATEST_DETAIL := "Downloads the newest server on every launch; may show a version warning until you update the toolkit."


static func run(testing) -> void:
	_test_step_specs(testing)
	_test_mcp_json_specs(testing)
	_test_pin_choice_control(testing)


static func _test_step_specs(testing) -> void:
	testing.begin("Setup wizard copy: every step's spec, verbatim")
	var wizard := OnboardingWizard.new(null, null, null, null)
	testing.eq(wizard._spec_for_step(SetupSteps.WELCOME), {
		"text": _WELCOME_TEXT,
		"ok_label": "Next",
		"buttons": [{"label": "Open Security Doc", "action": "open_security"}],
	}, "welcome")
	testing.eq(wizard._spec_for_step(SetupSteps.OPTIONAL_STEPS), {
		"text": _OPTIONAL_STEPS_TEXT,
		"ok_label": "Next",
		"buttons": [{"label": "Back", "action": "back"}],
		"check_box": "Show optional steps added by toolkit updates",
	}, "optional_steps")
	testing.eq(wizard._spec_for_step(SetupSteps.UPDATES), {
		"text": _UPDATES_TEXT,
		"ok_label": "Next",
		"buttons": [{"label": "Back", "action": "back"}],
		"check_box": "Check for updates",
	}, "updates")
	var dock: Dictionary = wizard._spec_for_step(SetupSteps.DOCK)
	var on_enter: Variant = dock.get("on_enter")
	testing.ok(on_enter is Callable, "dock → an on_enter that reveals the dock")
	if on_enter is Callable:
		var reveal: Callable = on_enter
		testing.ok(reveal.is_valid(), "dock → the reveal is callable")
		# With no plugin the reveal does nothing, so it is safe to run here.
		reveal.call()
	var dock_data := dock.duplicate()
	dock_data.erase("on_enter")
	testing.eq(dock_data, {
		"text": _DOCK_TEXT,
		"ok_label": "Close",
		"buttons": [
			{"label": "Back", "action": "back"},
			{"label": "Open Info", "action": "open_info"},
		],
	}, "dock")
	testing.eq(wizard._spec_for_step(&"no_such_step"), {}, "an unknown step → no spec")
	print("")


# The .mcp.json step has a variant per file state; the dispatch picks the one that
# matches whether the project root holds the file now.
static func _test_mcp_json_specs(testing) -> void:
	testing.begin("Setup wizard copy: the .mcp.json step's two variants")
	var wizard := OnboardingWizard.new(null, null, null, null)
	var existing := {
		"text": _MCP_JSON_INTRO + _MCP_JSON_EXISTS_TEXT,
		"ok_label": "Continue (keep existing .mcp.json)",
		"buttons": [{"label": "Write .mcp.json", "action": "overwrite_mcp"}],
		"pin_choice": true,
	}
	var missing := {
		"text": _MCP_JSON_INTRO + _MCP_JSON_MISSING_TEXT,
		"ok_label": "Create .mcp.json",
		"buttons": [],
		"pin_choice": true,
	}
	testing.eq(StepSpecs.mcp_json(true), existing, "a file exists → keep or write")
	testing.eq(StepSpecs.mcp_json(false), missing, "no file → create")
	var file_exists := FileAccess.file_exists(ProjectSettings.globalize_path("res://") + ".mcp.json")
	testing.eq(wizard._spec_for_step(SetupSteps.MCP_JSON), existing if file_exists else missing,
			"the dispatch → the variant for the file on disk")
	print("")


# The control reads the project's version setting in memory only; the previous
# value is put back before any check runs.
static func _test_pin_choice_control(testing) -> void:
	testing.begin("Setup wizard: the pin-choice control per mode")
	var had_value: bool = ProjectSettings.has_setting(_VERSION_SETTING)
	var previous: Variant = ProjectSettings.get_setting(_VERSION_SETTING) if had_value else null
	var shapes := {}
	for setting in ["", " Latest ", " next "]:
		ProjectSettings.set_setting(_VERSION_SETTING, setting)
		var wizard := OnboardingWizard.new(null, null, null, null)
		var box: VBoxContainer = wizard._build_pin_choice("the step text")
		shapes[setting] = _describe(box)
		box.free()
	ProjectSettings.set_setting(_VERSION_SETTING, previous if had_value else null)
	var choices := [
		["Label", "the step text"],
		["CheckBox", "Pinned (recommended)"],
		["Label", "      " + _PINNED_DETAIL],
		["CheckBox", "Latest"],
		["Label", "      " + _LATEST_DETAIL],
	]
	testing.eq(shapes[""], {"rows": choices, "pressed": [true, false]}, "empty setting → Pinned checked")
	testing.eq(shapes[" Latest "], {"rows": choices, "pressed": [false, true]}, "latest setting → Latest checked")
	var custom_rows := choices.duplicate()
	custom_rows.append(["Label", "Project Settings names a custom server version (next); pick one above to replace it."])
	testing.eq(shapes[" next "], {"rows": custom_rows, "pressed": [false, false]},
			"custom setting → neither checked, and a note naming it")
	print("")


# Each child as [class, text], plus the pressed state of each check box in order.
static func _describe(box: VBoxContainer) -> Dictionary:
	var rows := []
	var pressed := []
	for child in box.get_children():
		if child is CheckBox:
			var check_box: CheckBox = child
			rows.append(["CheckBox", check_box.text])
			pressed.append(check_box.button_pressed)
		elif child is Label:
			var label: Label = child
			rows.append(["Label", label.text])
		else:
			rows.append([child.get_class(), ""])
	return {"rows": rows, "pressed": pressed}
