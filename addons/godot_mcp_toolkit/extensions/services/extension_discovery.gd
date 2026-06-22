@tool
extends RefCounted
## One-shot startup discovery: load every enabled extension candidate found by
## reflection over the global class list into the live command registry, once.
##
## Stateless. discover_and_register() enumerates ProjectSettings.get_global_class_list(),
## filters to enabled candidates via the shared support leaf, loads each, and stores
## the retained instances on the registry as a meta so they outlive this call (the C#
## GC-safety reference that keeps registered Callables alive). The watcher (a separate
## module) takes over live hot-reload after this pass; this module never runs again.

const _Support := preload("res://addons/godot_mcp_toolkit/extensions/services/extension_support.gd")


## Discover and register every enabled extension candidate into the live registry.
## Returns the number of extensions loaded. The retained C# instances are stored on
## the registry under "_extension_instances" so they survive past this call.
static func discover_and_register(registry: MCPToolkitCommandRegistry, server: Node) -> int:
	var classes: Array = ProjectSettings.get_global_class_list()
	var instances: Array = []
	for entry in classes:
		if not _Support.is_extension_candidate(entry):
			continue
		var script_path: String = entry.get("path", "")
		if not _Support.is_addon_enabled(script_path):
			continue
		var class_name_str: String = entry.get("class", "")
		# Retain the returned instance (C# GC-safety) — load_extension does not hold
		# it; the caller owns retention.
		var instance := _Support.load_extension(class_name_str, script_path, registry, server)
		if instance != null:
			instances.append(instance)
	# Transfer instance ownership to the registry so they outlive this call.
	if not instances.is_empty():
		registry.set_meta("_extension_instances", instances)
	return instances.size()
