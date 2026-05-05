@tool
class_name MCPToolkitExtension
extends RefCounted
## Base class for third-party MCP toolkit extensions.
##
## To create an extension, extend this class in your own addon directory
## with a class_name starting with "MCPToolkit" (e.g., MCPToolkitPhysicsTools).
## Override register() to add your commands via registry.add().
##
## See addons/godot_mcp_toolkit/docs/extending.md for full documentation.


func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:
	push_warning("MCPToolkitExtension: register() not overridden in %s"
		% get_script().resource_path)
