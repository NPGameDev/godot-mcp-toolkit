@tool
extends RefCounted
## Shared confirm-then-write flow for the project-root .mcp.json.
##
## The one place the "write .mcp.json" user action lives: refuses a malformed
## file, checks whether the write would change an existing toolkit entry, shows
## the update confirmation when it would, delegates the file I/O to [code]MCPJsonSync.write_from_template[/code]
## (which stays pure I/O), and reports the outcome through the caller's result
## callback. Built by the composer and injected into every surface that offers
## the write, so no surface owns the flow and none reaches through the dock for
## it — the dock is a UI surface, not a service locator.
##
## Editor-only: the confirmation dialog parents to the editor base control, so
## this script must never enter the runtime autoload's preload closure.

const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")
const DockConfirm := preload("res://addons/godot_mcp_toolkit/ui/dock/dock_confirm.gd")


## Write the toolkit's entry into .mcp.json, confirming first when that would
## change an entry the file already holds (skipped when [param force_overwrite],
## for a caller that already confirmed).
##
## A file that is not valid JSON is never written, even with
## [param force_overwrite]: the flow explains that and offers to open the file.
## Declining the update confirmation opens the file in the system editor instead
## of writing — the "don't change it, let me look at it" recovery — and reports
## nothing. After a write attempt [param on_result] receives one
## (ok, message, severity, tooltip) report; severity is the editor-toast scale
## (0 info / 1 warning / 2 error). Pass an empty Callable to fire and forget.
func write(force_overwrite: bool = false, on_result: Callable = Callable()) -> void:
	# MCPJsonSync calls its on_result unconditionally, so a fire-and-forget
	# (empty) caller sink is wrapped in a validity guard rather than passed through.
	var report := func(ok: bool, message: String, severity: int, tooltip: String) -> void:
		if on_result.is_valid():
			on_result.call(ok, message, severity, tooltip)

	# The lambdas below capture only locals (report, dest) — a bare member
	# reference inside a lambda is not use-self-marked on Godot 4.2 and would look
	# up on a Nil self.
	var dest := MCPJsonSync.get_mcp_json_path()
	if MCPJsonSync.is_malformed():
		DockConfirm.confirm(
			"Can't update .mcp.json",
			MCPJsonSync.MALFORMED_MESSAGE + "\n\n" + dest,
			"Open .mcp.json",
			func() -> void: OS.shell_open(dest),
			"Close",
		)
		return

	if not force_overwrite and MCPJsonSync.needs_overwrite_confirm():
		# "Cancel" is repurposed as "Open .mcp.json": declining the update opens the
		# file so the user can inspect it rather than have the entry changed. Esc/✕
		# route through the same path.
		DockConfirm.confirm(
			"Update the .mcp.json entry",
			"Update the " + MCPJsonSync.get_own_entry_key() + " entry in .mcp.json?\n\n" + dest
				+ "\n\nOnly this entry changes; other servers and your env keys are kept.",
			"Update",
			func() -> void: MCPJsonSync.write_from_template(true, report),
			"Open .mcp.json",
			func() -> void: OS.shell_open(dest),
		)
		return

	MCPJsonSync.write_from_template(force_overwrite, report)
