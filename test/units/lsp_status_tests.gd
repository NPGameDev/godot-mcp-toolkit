@tool
extends RefCounted
## Unit tests for editor.set_lsp_status — the wire-only command through which the
## MCP server pushes its authoritative GDScript-LSP verdict to the editor (which
## cannot read its own LSP bind status). The handler is a pure two-line forward:
## it hands the params to the server's set_reported_lsp_status and returns a
## {"reported": true} acknowledgement. Both halves — verbatim forwarding and the
## stamped acknowledgement — are pinned here against a stub server double, so no
## editor context is needed.

const EditorCommands := preload("res://addons/godot_mcp_toolkit/commands/editor/editor_commands.gd")


# Captures the status dict handed to set_reported_lsp_status. Extends Node because
# the handler types its server as Node (the real server is a Node), so the static
# type-check rejects a RefCounted double. Node — not an editor-only class — keeps
# the module loadable under a headless --script run.
class _StubServer extends Node:
	var captured: Dictionary = {}

	func set_reported_lsp_status(status: Dictionary) -> void:
		captured = status


static func run(testing) -> void:
	_test_forwards_and_acknowledges(testing)


static func _test_forwards_and_acknowledges(testing) -> void:
	testing.begin("editor.set_lsp_status forwards to the server and acknowledges")
	var stub := _StubServer.new()
	var result := EditorCommands._cmd_set_lsp_status(stub, {"available": true, "port": 6005})
	testing.eq(stub.captured, {"available": true, "port": 6005}, "forwards params verbatim")
	testing.eq(result.get("reported", null), true, "returns reported true")
	testing.ok(result.get("success", false), "wraps the response in MCPToolkitSuccess.ok")
	stub.free()
	print("")
