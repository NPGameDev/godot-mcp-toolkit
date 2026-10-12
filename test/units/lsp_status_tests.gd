@tool
extends RefCounted
## Unit tests for editor.set_lsp_status — the wire-only command through which the
## MCP server pushes its authoritative GDScript-LSP verdict to the editor (which
## cannot read its own LSP bind status). The handler is a pure two-line forward:
## it hands the params to the server's set_reported_lsp_status and returns a
## {"reported": true} acknowledgement. Both halves — verbatim forwarding and the
## stamped acknowledgement — are pinned here against a stub server double, so no
## editor context is needed.
##
## A second group pins what the LSP publisher does after an endpoint re-publish: it
## drops the reported verdict only when the endpoint changed, and notifies the dock
## either way. It drives the step after the registry write, so no registry is touched.

const EditorCommands := preload("res://addons/godot_mcp_toolkit/commands/editor/editor_commands.gd")
const LspPublisher := preload("res://addons/godot_mcp_toolkit/paths/lsp_publisher.gd")


# Captures the status dict handed to set_reported_lsp_status. Extends Node because
# the handler types its server as Node (the real server is a Node), so the static
# type-check rejects a RefCounted double. Node — not an editor-only class — keeps
# the module loadable under a headless --script run.
class _StubServer extends Node:
	var captured: Dictionary = {}

	func set_reported_lsp_status(status: Dictionary) -> void:
		captured = status


# Counts how often the publisher notifies its status-changed handler, standing in for
# the server's lsp_status_changed re-emit.
class _NotifyCounter extends RefCounted:
	var calls: int = 0

	func on_status_changed() -> void:
		calls += 1


static func run(testing) -> void:
	_test_forwards_and_acknowledges(testing)
	_test_republish_settles_reported_status(testing)


static func _test_forwards_and_acknowledges(testing) -> void:
	testing.begin("editor.set_lsp_status forwards to the server and acknowledges")
	var stub := _StubServer.new()
	var result := EditorCommands._cmd_set_lsp_status(stub, {"available": true, "port": 6005})
	testing.eq(stub.captured, {"available": true, "port": 6005}, "forwards params verbatim")
	testing.eq(result.get("reported", null), true, "returns reported true")
	testing.ok(result.get("success", false), "wraps the response in MCPToolkitSuccess.ok")
	stub.free()
	print("")


static func _test_republish_settles_reported_status(testing) -> void:
	testing.begin("LSP publisher re-publish drops a stale verdict and notifies the dock")
	var reported := {"state": "active", "port": 6005}

	var changed_counter := _NotifyCounter.new()
	var changed := LspPublisher.new()
	changed.set_status_changed_handler(changed_counter.on_status_changed)
	changed.set_reported_lsp_status(reported)
	testing.eq(changed_counter.calls, 1, "a reported status notifies once")
	changed._after_republish(true)
	testing.eq(changed.get_reported_lsp_status(), {}, "an endpoint change drops the reported status")
	testing.eq(changed_counter.calls, 2, "an endpoint change notifies again")

	var same_counter := _NotifyCounter.new()
	var same := LspPublisher.new()
	same.set_status_changed_handler(same_counter.on_status_changed)
	same.set_reported_lsp_status(reported)
	same._after_republish(false)
	testing.eq(same.get_reported_lsp_status(), reported, "an unchanged endpoint keeps the reported status")
	testing.eq(same_counter.calls, 2, "an unchanged endpoint still notifies")
	print("")
