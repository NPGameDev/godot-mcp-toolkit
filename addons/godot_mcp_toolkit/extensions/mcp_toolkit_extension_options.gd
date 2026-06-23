@tool
class_name MCPToolkitExtensionOptions
extends MCPToolkitCommandOptions
## Options builder for an EXTENSION command, with a required description.
##
## A subclass of [MCPToolkitCommandOptions] that takes the tool's description in
## its constructor instead of via [method MCPToolkitCommandOptions.with_description].
## Extension tools are public-facing — the LLM needs a description to know what the
## tool does — so prefer this over the base builder when registering extension
## commands. Every chainable setter inherited from [MCPToolkitCommandOptions]
## (e.g. [method MCPToolkitCommandOptions.mark_read_only]) works the same way.[br]
## [br]
## Example:
## [codeblock]
## registry.add("physics_list_bodies", _on_list_bodies,
##     MCPToolkitExtensionOptions.new("List all physics bodies") \
##         .mark_read_only() \
##         .mark_idempotent() \
##         .with_group("physics_tools", "Physics inspection", ["physics", "force"]))
## [/codeblock]


## Constructs the options with the required [param description]. The description is
## requested, not enforced: an empty (or whitespace-only) [param description]
## pushes an error and leaves the description empty, but the object is still
## constructed — registration proceeds. Pass a concise, action-oriented sentence
## describing what the tool does.
func _init(description: String) -> void:
	if description.strip_edges() == "":
		push_error("[MCPExtensions] Extension options require a non-empty description")
		return
	_description = description
