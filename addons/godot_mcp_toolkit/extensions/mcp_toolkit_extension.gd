@tool
class_name MCPToolkitExtension
extends RefCounted
## Base class for third-party MCP toolkit extensions.
##
## To create an extension in GDScript, declare a [code]class_name[/code] that
## extends this class directly and override [method register]. Discovery is by base
## class — any direct subclass in the project's global class list is found and
## loaded, with no naming restriction and no requirement to live in any particular
## directory. The [code]MCPToolkit[/code] name prefix is a [b]recommended[/b]
## convention for GDScript (namespace hygiene, so your class never collides with
## user code); it is [b]required only for C#[/b], where an extension is a
## [code][GlobalClass][/code] whose name starts with [code]MCPToolkit[/code]
## (C# cannot inherit this GDScript base). Only direct subclasses are discovered —
## multi-level inheritance is intentionally unsupported.[br]
## [br]
## See [code]addons/godot_mcp_toolkit/docs/extending.md[/code] for full
## documentation.


## Override point: register this extension's commands. Called once at load with the
## live [param registry] (call [method MCPToolkitCommandRegistry.add] on it to add
## each command) and the [param server], the MCP server node, which a cancellable
## handler may use but must not store beyond the call. The base implementation only
## warns that it was not overridden, so a subclass that adds no commands is a bug.
func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:
	push_warning("MCPToolkitExtension: register() not overridden in %s"
		% get_script().resource_path)
