@tool
extends RefCounted
## Discovers and loads third-party MCP toolkit extensions via reflection.
##
## Extensions are discovered by scanning ProjectSettings.get_global_class_list()
## for classes whose name starts with "MCPToolkit" and whose script lives outside
## res://addons/godot_mcp_toolkit/. GDScript extensions must extend
## MCPToolkitExtension; C# extensions use duck typing (has_method("Register")).

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError

const _ADDON_PATH := "res://addons/godot_mcp_toolkit/"
const _PREFIX := "MCPToolkit"

# Built-in namespaces that extensions cannot override.
const RESERVED_PREFIXES: Array[String] = [
	"scene.", "script.", "editor.", "node.", "runtime.", "server.",
	"resource.", "folder.", "file.", "signal.", "playtest.", "project.",
	"input_map.", "animation.", "tilemap.", "asset.", "save.", "meta.",
	"game.", "diff.", "extensions.",
]

# Retain references to C# extension instances to prevent GC from
# invalidating registered Callables.
var _instances: Array = []


static func load_all(registry: MCPToolkitCommandRegistry, server: Node) -> int:
	var loader := new()
	var loaded := loader._discover_and_register(registry, server)
	if loaded > 0:
		print("[MCP] Discovered %d extension(s) via reflection" % loaded)
	# Register the meta command for bridge discovery.
	_register_meta(registry)
	# Transfer instance ownership to the registry so they outlive this call.
	if not loader._instances.is_empty():
		registry.set_meta("_extension_instances", loader._instances)
	return loaded


func _discover_and_register(registry: MCPToolkitCommandRegistry, server: Node) -> int:
	var classes: Array = ProjectSettings.get_global_class_list()
	var loaded := 0
	for entry in classes:
		var class_name_str: String = entry.get("class", "")
		if not class_name_str.begins_with(_PREFIX):
			continue
		var script_path: String = entry.get("path", "")
		# Skip classes inside the toolkit addon itself.
		if script_path.begins_with(_ADDON_PATH):
			continue
		if _load_extension(class_name_str, script_path, registry, server):
			loaded += 1
	return loaded


func _load_extension(class_name_str: String, script_path: String, registry: MCPToolkitCommandRegistry, server: Node) -> bool:
	var script: Script = ResourceLoader.load(script_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if script == null:
		push_warning("[MCP] Extension '%s': failed to load script at %s" % [class_name_str, script_path])
		return false

	var is_csharp := script_path.ends_with(".cs")
	var instance = script.new()
	if instance == null:
		push_warning("[MCP] Extension '%s': script.new() returned null" % class_name_str)
		return false

	# Validate extension contract.
	if is_csharp:
		# C# cannot extend GDScript classes — use duck typing.
		if not instance.has_method("Register") and not instance.has_method("register"):
			push_warning("[MCP] Extension '%s': C# class missing Register() method — skipped" % class_name_str)
			return false
	else:
		# GDScript must extend MCPToolkitExtension.
		if not (instance is MCPToolkitExtension):
			push_warning("[MCP] Extension '%s': GDScript class does not extend MCPToolkitExtension — skipped" % class_name_str)
			return false

	# Record methods before registration to detect new ones.
	var before: Array = registry.get_all_methods()

	# Call register — handle both GDScript (snake_case) and C# (PascalCase).
	if instance.has_method("Register"):
		instance.Register(registry, server)
	elif instance.has_method("register"):
		instance.register(registry, server)

	# Validate newly registered methods.
	var after: Array = registry.get_all_methods()
	var new_count := 0
	for method: String in after:
		if method in before:
			continue
		var rejected := false
		for prefix: String in RESERVED_PREFIXES:
			if method.begins_with(prefix):
				registry.remove(method)
				push_warning("[MCP] Extension '%s': '%s' uses reserved namespace '%s*' — rejected" % [class_name_str, method, prefix])
				rejected = true
				break
		if not rejected:
			registry.mark_extension(method)
			var meta := registry.get_command_metadata(method)
			var group_name: String = meta.get("group", {}).get("name", "")
			if group_name:
				print("[MCP]   + %s (group: %s)" % [method, group_name])
			else:
				print("[MCP]   + %s" % method)
			new_count += 1

	if new_count == 0:
		push_warning("[MCP] Extension '%s': registered zero new commands" % class_name_str)
		return false

	# Retain the instance reference (critical for C# — prevents GC from
	# invalidating Callables).
	_instances.append(instance)
	return true


static func _register_meta(registry: MCPToolkitCommandRegistry) -> void:
	var handler := func(params: Dictionary) -> Dictionary:
		return _cmd_extensions_list(registry, params)
	registry.add("extensions.list", handler, {
		"description": "List all discovered third-party extensions and their commands",
		"annotations": {"readOnlyHint": true, "idempotentHint": true},
	})


static func _cmd_extensions_list(registry: MCPToolkitCommandRegistry, _params: Dictionary) -> Dictionary:
	var methods := registry.get_extension_methods()
	var result: Array[Dictionary] = []
	for method: String in methods:
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
		result.append(entry)
	return {"success": true, "commands": result}
