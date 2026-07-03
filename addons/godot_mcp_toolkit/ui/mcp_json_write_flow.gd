@tool
extends RefCounted
## Shared confirm-then-write flow for the project-root .mcp.json.
##
## The one place the "write .mcp.json" user action lives: checks whether the
## write would overwrite an existing file, shows the overwrite confirmation when
## it would, delegates the file I/O to [code]MCPJsonSync.write_from_template[/code]
## (which stays pure I/O), and reports the outcome through the caller's result
## callback. Built by the composer and injected into every surface that offers
## the write, so no surface owns the flow and none reaches through the dock for
## it — the dock is a UI surface, not a service locator.
##
## Editor-only: the confirmation dialog parents to the editor base control, so
## this script must never enter the runtime autoload's preload closure.

const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")
const DockConfirm := preload("res://addons/godot_mcp_toolkit/ui/dock/dock_confirm.gd")


## Write .mcp.json from the bundled template, confirming first when a file
## already exists (skipped when [param force_overwrite]).
##
## Declining the confirmation opens the existing file in the system editor
## instead of writing — the "don't overwrite, let me look at it" recovery — and
## reports nothing. After a write attempt [param on_result] receives one
## (ok, message, severity, tooltip) report; severity is the editor-toast scale
## (0 info / 1 warning / 2 error). Pass an empty Callable to fire and forget.
func write(force_overwrite: bool = false, on_result: Callable = Callable()) -> void:
	# MCPJsonSync calls its on_result unconditionally, so a fire-and-forget
	# (empty) caller sink is wrapped in a validity guard rather than passed through.
	var report := func(ok: bool, message: String, severity: int, tooltip: String) -> void:
		if on_result.is_valid():
			on_result.call(ok, message, severity, tooltip)

	if not force_overwrite and MCPJsonSync.needs_overwrite_confirm():
		var dest := MCPJsonSync.get_mcp_json_path()
		# "Cancel" is repurposed as "Open .mcp.json": declining the overwrite opens
		# the file so the user can edit it (fix a malformed file, or inspect a valid
		# one) rather than lose it. Esc/✕ route through the same path — the intended
		# "don't overwrite, let me look at it" recovery. The lambdas capture only
		# locals (report, dest) — a bare member reference inside a lambda is not
		# use-self-marked on Godot 4.2 and would look up on a Nil self.
		DockConfirm.confirm(
			".mcp.json already exists",
			"Overwrite .mcp.json with a clean template?\n\n" + dest
				+ "\n\nThis replaces your current content — choose \"Open .mcp.json\" instead to edit the file yourself.",
			"Overwrite",
			func() -> void: MCPJsonSync.write_from_template(true, report),
			"Open .mcp.json",
			func() -> void: OS.shell_open(dest),
		)
		return

	MCPJsonSync.write_from_template(force_overwrite, report)
