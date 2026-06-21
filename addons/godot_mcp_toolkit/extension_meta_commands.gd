@tool
extends RefCounted
## Serves the extensions.list read command and owns the single per-command
## wire-entry builder the MCP bridge contract depends on.
##
## extensions.list is a stateless read of the registry's extension methods.
## build_command_entry() is the one place the per-command wire shape is defined —
## see its doc comment for the contract it pins.
##
## Stateless: every function takes the registry as a parameter; no instance state.


## Build the per-command wire entry the MCP bridge reads. This is the single
## source of the Published-Language shape consumed by extensions.list,
## extensions.refresh, and extensions.changed — keep all three building it here so
## the bridge-facing contract cannot drift between them. A field is included only
## when non-empty/present, mirroring what registry.get_command_metadata() omits.
static func build_command_entry(registry: MCPToolkitCommandRegistry, method: String) -> Dictionary:
	var meta := registry.get_command_metadata(method)
	var entry: Dictionary = {"method": method}
	if meta.get("description", "") != "":
		entry["description"] = meta["description"]
	if not meta.get("input_schema", {}).is_empty():
		entry["input_schema"] = meta["input_schema"]
	if not meta.get("annotations", {}).is_empty():
		entry["annotations"] = meta["annotations"]
	if not meta.get("group", {}).is_empty():
		entry["group"] = meta["group"]
	if meta.has("timeout_ms"):
		entry["timeout_ms"] = meta["timeout_ms"]
	return entry


## Register the extensions.list meta command for bridge discovery.
static func register_list_command(registry: MCPToolkitCommandRegistry) -> void:
	var handler := func(params: Dictionary) -> Dictionary:
		return cmd_extensions_list(registry, params)
	registry.add("extensions.list", handler, MCPToolkitCommandOptions.new()
		.with_description("List all discovered third-party extensions and their commands")
		.mark_read_only()
		.mark_idempotent()
		.mark_scene_independent())


## List every discovered extension command with its full wire metadata.
static func cmd_extensions_list(registry: MCPToolkitCommandRegistry, _params: Dictionary) -> Dictionary:
	var methods := registry.get_extension_methods()
	var result: Array[Dictionary] = []
	for method: String in methods:
		result.append(build_command_entry(registry, method))
	return {"success": true, "commands": result}
