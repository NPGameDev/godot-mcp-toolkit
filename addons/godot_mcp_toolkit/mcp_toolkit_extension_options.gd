@tool
class_name MCPToolkitExtensionOptions
extends MCPToolkitCommandOptions
## Builder for MCP extension command registration options.
##
## Extends MCPToolkitCommandOptions with a mandatory description parameter.
## Extension tools are public-facing — the LLM needs a description to know
## what the tool does.
##
## Usage:
##   var opts = MCPToolkitExtensionOptions.new("List all physics bodies") \
##       .mark_read_only() \
##       .mark_idempotent() \
##       .with_group("physics_tools", "Physics inspection", ["physics", "force"])


func _init(description: String) -> void:
	if description.strip_edges() == "":
		push_error("[MCPExtensions] Extension options require a non-empty description")
		return
	_description = description
