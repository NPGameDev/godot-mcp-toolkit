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
## It also owns the machine-local facts a write depends on and leaves behind: the
## local server path editor setting it passes to the write, and the record of the
## server spec it last wrote for this project (editor project metadata, never
## committed), which the dock compares with the file to tell a toolkit-written
## entry from a hand-set one.
##
## Editor-only: the confirmation dialog parents to the editor base control, so
## this script must never enter the runtime autoload's preload closure.

const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")
const DockConfirm := preload("res://addons/godot_mcp_toolkit/ui/dock/dock_confirm.gd")

## The EditorSettings key for a local server build's dist/index.js on this
## machine. Machine-level, so it never reaches project.godot.
const LOCAL_PATH_SETTING := "mcp_toolkit/server/local_path"

# Where the last written server spec is recorded: editor project metadata, which
# stays on this machine.
const _RECORD_SECTION := "mcp_toolkit"
const _RECORD_KEY := "last_written_server_spec"


## Write the toolkit's entry into .mcp.json, confirming first when that would
## change an entry the file already holds (skipped when [param force_overwrite],
## for a caller that already confirmed).
##
## A file that is not valid JSON is never written, even with
## [param force_overwrite]: the flow explains that and offers to open the file.
## Declining the update confirmation opens the file in the system editor instead
## of writing — the "don't change it, let me look at it" recovery — and reports
## nothing. A non-empty [param confirm_body] replaces the confirmation's generic
## text, for a caller that knows what the change is. After a write attempt
## [param on_result] receives one (ok, message, severity, tooltip) report; severity
## is the editor-toast scale (0 info / 1 warning / 2 error). Pass an empty Callable
## to fire and forget. A successful write records the written server spec.
func write(force_overwrite: bool = false, on_result: Callable = Callable(), confirm_body: String = "") -> void:
	# MCPJsonSync calls its on_result unconditionally, so a fire-and-forget
	# (empty) caller sink is wrapped in a validity guard rather than passed through.
	var report := func(ok: bool, message: String, severity: int, tooltip: String) -> void:
		if on_result.is_valid():
			on_result.call(ok, message, severity, tooltip)
	var record_section := _RECORD_SECTION
	var record_key := _RECORD_KEY
	var record := func(spec: String) -> void:
		EditorInterface.get_editor_settings().set_project_metadata(record_section, record_key, spec)

	# The lambdas below capture only locals (report, record, dest, local_path) — a
	# bare member reference inside a lambda is not use-self-marked on Godot 4.2 and
	# would look up on a Nil self.
	var dest := MCPJsonSync.get_mcp_json_path()
	var local_path := read_local_path_setting()
	if MCPJsonSync.is_malformed():
		DockConfirm.confirm(
			"Can't update .mcp.json",
			MCPJsonSync.MALFORMED_MESSAGE + "\n\n" + dest,
			"Open .mcp.json",
			func() -> void: OS.shell_open(dest),
			"Close",
		)
		return

	if not force_overwrite and MCPJsonSync.needs_overwrite_confirm(local_path):
		var body := confirm_body
		if body.is_empty():
			body = ("Update the " + MCPJsonSync.get_own_entry_key() + " entry in .mcp.json?\n\n" + dest
				+ "\n\nOnly this entry changes; other servers and your env keys are kept.")
		# "Cancel" is repurposed as "Open .mcp.json": declining the update opens the
		# file so the user can inspect it rather than have the entry changed. Esc/✕
		# route through the same path.
		DockConfirm.confirm(
			"Update the .mcp.json entry",
			body,
			"Update",
			func() -> void: MCPJsonSync.write_from_template(true, report, local_path, record),
			"Open .mcp.json",
			func() -> void: OS.shell_open(dest),
		)
		return

	MCPJsonSync.write_from_template(force_overwrite, report, local_path, record)


## The local server path this machine's editor settings name ("" when unset), which
## a write uses instead of the npm package.
static func read_local_path_setting() -> String:
	var editor_settings := EditorInterface.get_editor_settings()
	if not editor_settings.has_setting(LOCAL_PATH_SETTING):
		return ""
	return str(editor_settings.get_setting(LOCAL_PATH_SETTING)).strip_edges()


## True when a write on this machine builds the entry from a local server build: the
## local server path editor setting, else GODOT_MCP_DEV_SERVER_PATH, names one. The
## same source the write reads, so the version-check opt-out follows the setting and
## never the shape of the entry on disk.
static func uses_local_server() -> bool:
	return not MCPJsonSync.resolve_machine_dev_path(read_local_path_setting()).is_empty()


## The server spec (see [code]ServerPinPolicy.classify_server_entry[/code]) this machine
## last wrote into the project's .mcp.json, or "" when it has not written one.
static func read_last_written_spec() -> String:
	return str(EditorInterface.get_editor_settings().get_project_metadata(_RECORD_SECTION, _RECORD_KEY, ""))
