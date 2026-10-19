@tool
extends SceneTree
## Prints the .mcp.json server entry that "Write .mcp.json" would emit on this
## machine, as one marked JSON line, then quits.
##
## It calls the same builder the write uses, with no editor settings, so the entry
## is the one a fresh install writes for this OS. The engine prints its own lines
## around it, so the entry sits on the line that starts with [constant ENTRY_MARKER].
## [codeblock]
## godot --headless --path . --script res://test/tools/print_mcp_entry.gd
## [/codeblock]
## [code]test/tools/launch_mcp_entry.mjs[/code] reads that line, starts the entry
## and checks which server version answers.

const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")

## Prefix of the output line that carries the entry JSON.
const ENTRY_MARKER := "MCP_ENTRY_JSON "


func _init() -> void:
	print(ENTRY_MARKER + JSON.stringify(MCPJsonSync._build_entry()))
	quit(0)
