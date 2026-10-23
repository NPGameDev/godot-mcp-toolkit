@tool
extends RefCounted
## The setup wizard's step copy: one plain-data spec per step, giving its text, its
## buttons, its body control, for the wizard's renderer to show.
##
## Spec shape (all values plain data except [code]on_enter[/code]):[br]
## - [code]text[/code]: String, the dialog body.[br]
## - [code]ok_label[/code]: String, the OK button caption.[br]
## - [code]buttons[/code]: Array of [code]{ label: String, action: String }[/code],
##   in order.[br]
## - [code]on_enter[/code]: Callable, optional; a side effect run as the step is
##   shown.[br]
## - [code]pin_choice[/code]: bool, optional; show the server pin choice under the
##   text.[br]
## - [code]check_box[/code]: String, optional; a checkbox with this label under the
##   text, showing and applying the step's setting.[br]
## [br]
## A spec describes its step alone; the wizard fits it to its place in a run.

## The OK caption of a step that moves on to the next one.
const NEXT_LABEL := "Next"
## The action of a step's Back button.
const BACK_ACTION := "back"


## The welcome step's spec: what the toolkit exposes, with a link to the security
## doc.
static func welcome() -> Dictionary:
	return {
		"text": (
			"Welcome to the Godot MCP Toolkit!\n\n"
			+ "This plugin exposes your Godot editor to AI agents via MCP.\n"
			+ "Some tools can modify your project or execute arbitrary code.\n\n"
			+ "Risk is communicated per-tool via MCP annotations.\n"
			+ "For details and copy-pasteable agent blocking configs, see:\n"
			+ "  addons/godot_mcp_toolkit/docs/security-recommendations.md\n\n"
			+ "All tools are available by default. Use your agent's\n"
			+ "allowlist/blocklist to restrict specific tools if needed."),
		"ok_label": NEXT_LABEL,
		"buttons": [{"label": "Open Security Doc", "action": "open_security"}],
	}


## The .mcp.json step's spec: [param mcp_exists] picks the variant for a project
## that already has the file (keep it, or write it over) or one that lacks it
## (create it). Both carry the pin choice.
static func mcp_json(mcp_exists: bool) -> Dictionary:
	var intro := (
		"Your MCP client reads .mcp.json from the project root "
		+ "to locate and configure the server.\n\n"
		+ "The MCP server bridge requires Node.js 22+ to run. "
		+ "Download it from https://nodejs.org if not installed.\n\n")
	if mcp_exists:
		return {
			# Continue keeps the file as it is, so the choice must say it takes
			# effect only through a write.
			"text": intro + (
				"An .mcp.json already exists in your project. The server choice "
				+ "below applies only if you press Write .mcp.json."),
			"ok_label": "Continue (keep existing .mcp.json)",
			"buttons": [{
				"label": "Write .mcp.json",
				"action": "overwrite_mcp",
			}],
			"pin_choice": true,
		}
	return {
		"text": intro + (
			"No .mcp.json was found — this file is required for your "
			+ "MCP client to connect to the toolkit."),
		"ok_label": "Create .mcp.json",
		"buttons": [],
		"pin_choice": true,
	}


## The optional-steps step's spec: which steps come back after an update, with a
## checkbox for the optional ones.
static func optional_steps() -> Dictionary:
	return {
		"text": (
			"Toolkit updates sometimes add steps to this wizard. When one does, the next "
			+ "time you start the editor you'll see only the new steps.\n\n"
			+ "Some steps are required because you lose something by skipping them: "
			+ "without .mcp.json your AI client won't find the toolkit on its own, and the "
			+ "update check only starts once you've seen the update-check step. Required "
			+ "steps come back at every editor start until you've seen them. \"Remind me "
			+ "later\" puts them off until the next start.\n\n"
			+ "The other steps are optional. Untick the box below and optional steps that "
			+ "future updates add won't show, in any project on this machine. Required "
			+ "steps still show."),
		"ok_label": NEXT_LABEL,
		"buttons": [{"label": "Back", "action": BACK_ACTION}],
		"check_box": "Show optional steps added by toolkit updates",
	}


## The update-check step's spec: what the check asks and sends, with a checkbox
## that turns it off.
static func updates() -> Dictionary:
	return {
		"text": (
			"At most once a day, the toolkit asks GitHub whether a newer version is out. "
			+ "If one is, it also asks the Asset Store whether it lists that version yet. "
			+ "When there's a newer version, a closable badge at the top of the MCP Toolkit "
			+ "dock links to it. The toolkit never installs anything by itself.\n\n"
			+ "These requests carry no identifier and nothing about your project. Untick "
			+ "the box below and the toolkit sends no requests at all.\n\n"
			+ "You can change this later in Project Settings under Mcp Toolkit > Updates. "
			+ "It's saved in project.godot, so it applies to everyone who works on this "
			+ "project."),
		"ok_label": NEXT_LABEL,
		"buttons": [{"label": "Back", "action": BACK_ACTION}],
		"check_box": "Check for updates",
	}


## The dock overview step's spec. [param reveal_dock] surfaces the dock; it rides
## as the spec's [code]on_enter[/code], since showing the dock is a side effect
## the copy does not own.
static func dock_overview(reveal_dock: Callable) -> Dictionary:
	return {
		"text": (
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
			+ "You're all set!"),
		"ok_label": "Close",
		"buttons": [
			{"label": "Back", "action": BACK_ACTION},
			{"label": "Open Info", "action": "open_info"},
		],
		"on_enter": reveal_dock,
	}
