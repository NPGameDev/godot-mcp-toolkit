@tool
extends RefCounted
## Enable-time .mcp.json offer — a transient Write/Skip prompt.
##
## Shown when the plugin is toggled ON and no .mcp.json exists at the project
## root (deleted, or a fresh checkout that omitted it): without the file the
## MCP client has nothing to connect with, and the dock's passive warning is
## easy to miss. Suppressed until the setup wizard's .mcp.json step has been
## seen: that step owns the file until then. Asked on every enable
## by design: enable is infrequent, so there is no "don't ask again" state to
## manage (symmetric with the disable-time orphan prompt).
##
## Editor-only: the dialog parents to the editor base control, so this script
## must never enter the runtime autoload's preload closure.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const MCPJsonSync = Modules.MCPJsonSync
const MCPJsonWriteFlow := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_write_flow.gd")
const SetupSteps = Modules.SetupSteps
const SetupStepTracker = Modules.SetupStepTracker
const DockConfirm := preload("res://addons/godot_mcp_toolkit/ui/dock/dock_confirm.gd")


## Offer to write .mcp.json when it is missing and the setup wizard's .mcp.json
## step has been seen.
## The prompt dialog is transient — base-control-parented and freed on every
## dismissal (the confirm factory's self-free). Write delegates to
## [param write_flow]; with no file present the flow writes straight from the
## template, no overwrite confirm. Skip just dismisses.
static func show_if_needed(write_flow: MCPJsonWriteFlow) -> void:
	if write_flow == null:
		return
	if not should_offer(MCPJsonSync.has_mcp_json(), SetupStepTracker.has_seen(SetupSteps.MCP_JSON)):
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


## Whether to offer the write: [param mcp_json_present] is false and
## [param mcp_json_step_seen] is true. Until the user has seen the setup wizard's
## .mcp.json step, that step is where the file gets written.
static func should_offer(mcp_json_present: bool, mcp_json_step_seen: bool) -> bool:
	return not mcp_json_present and mcp_json_step_seen
