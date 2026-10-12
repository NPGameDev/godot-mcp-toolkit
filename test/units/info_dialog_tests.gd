@tool
extends RefCounted
## Unit tests for the Info dialog's read-only lines: the Mode row follows the state the
## running MCP server applies (the dock badge's), and a second line appears only when
## .mcp.json now says otherwise. Only the static helper runs here; show_info builds
## styled sections that sample the editor theme, which the headless runner lacks.

const InfoDialog := preload("res://addons/godot_mcp_toolkit/ui/dock/ext/info_dialog.gd")

const _READ_ONLY_MODE := "Read-only (GODOT_MCP_READ_ONLY=1)"


static func run(testing) -> void:
	_test_both_read_only(testing)
	_test_both_full_access(testing)
	_test_file_turns_read_only_on(testing)
	_test_file_turns_read_only_off(testing)


# The server and the file agree on read-only: the Mode row says so, with no second line.
static func _test_both_read_only(testing) -> void:
	testing.begin("Info dialog read-only lines: applied and in the file")
	var lines := InfoDialog.describe_read_only_mode(true, true)
	testing.eq(lines["mode"], _READ_ONLY_MODE, "the Mode row shows read-only")
	testing.eq(lines["pending"], "", "no pending-change line")
	print("")


# Neither sets read-only: the dialog keeps its plain shape, with no Mode row at all.
static func _test_both_full_access(testing) -> void:
	testing.begin("Info dialog read-only lines: neither applied nor in the file")
	var lines := InfoDialog.describe_read_only_mode(false, false)
	testing.eq(lines["mode"], "", "no Mode row")
	testing.eq(lines["pending"], "", "no pending-change line")
	print("")


# The file sets read-only but the running server does not apply it yet: the Mode row
# shows the server's full access, and the second line says the file turns it on.
static func _test_file_turns_read_only_on(testing) -> void:
	testing.begin("Info dialog read-only lines: the file turns read-only on")
	var lines := InfoDialog.describe_read_only_mode(false, true)
	testing.eq(lines["mode"], "Full access", "the Mode row shows the applied full access")
	testing.eq(lines["pending"],
			".mcp.json now turns read-only mode on. It takes effect when the MCP client restarts.",
			"the pending-change line says the file turns it on")
	print("")


# The server applies read-only but the file no longer sets it: the Mode row still shows
# read-only, and the second line says the file turns it off.
static func _test_file_turns_read_only_off(testing) -> void:
	testing.begin("Info dialog read-only lines: the file turns read-only off")
	var lines := InfoDialog.describe_read_only_mode(true, false)
	testing.eq(lines["mode"], _READ_ONLY_MODE, "the Mode row shows the applied read-only")
	testing.eq(lines["pending"],
			".mcp.json now turns read-only mode off. It takes effect when the MCP client restarts.",
			"the pending-change line says the file turns it off")
	print("")
