@tool
extends RefCounted
## Enable-time .mcp.json offer — a transient Write/Skip prompt.
##
## Shown when the plugin is toggled ON and no .mcp.json exists at the project
## root (deleted, or a fresh checkout that omitted it): without the file the
## MCP client has nothing to connect with, and the dock's passive warning is
## easy to miss. Suppressed while onboarding is still pending — the wizard's
## own .mcp.json step owns the file on first activation. Asked on every enable
## by design: enable is infrequent, so there is no "don't ask again" state to
## manage (symmetric with the disable-time orphan prompt).
##
## Editor-only: the dialog parents to the editor base control, so this script
## must never enter the runtime autoload's preload closure.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const MCPJsonSync = Modules.MCPJsonSync
const MCPJsonWriteFlow := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_write_flow.gd")
const OnboardingWizard := preload("res://addons/godot_mcp_toolkit/ui/onboarding_wizard.gd")
const DockConfirm := preload("res://addons/godot_mcp_toolkit/ui/dock/dock_confirm.gd")


## Offer to write .mcp.json when it is missing and onboarding is already done.
## The prompt dialog is transient — base-control-parented and freed on every
## dismissal (the confirm factory's self-free). Write delegates to
## [param write_flow]; with no file present the flow writes straight from the
## template, no overwrite confirm. Skip just dismisses.
static func show_if_needed(write_flow: MCPJsonWriteFlow) -> void:
	if write_flow == null or MCPJsonSync.has_mcp_json():
		return
	if not OnboardingWizard.is_onboarding_complete():
		return
	DockConfirm.confirm(
		".mcp.json missing",
		"No .mcp.json was found at the project root — your MCP client reads it "
			+ "to locate and launch the toolkit's MCP server.\n\n"
			+ "Write one from the bundled template?",
		"Write .mcp.json",
		func() -> void: write_flow.write(),
		"Skip",
	)
