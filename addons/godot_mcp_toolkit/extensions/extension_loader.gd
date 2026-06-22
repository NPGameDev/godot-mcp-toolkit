@tool
extends RefCounted
## Sequences the extension subsystem lifecycle and presents the load_all /
## start_watcher façade the composer binds to.
##
## load_all() runs the one-shot startup discovery and registers the
## extensions.list meta command. start_watcher() creates the live hot-reload
## watcher and hands it the registry + server. This owns wiring, not domain logic:
## discovery, the meta-command wire shape, and the hot-reload diff engine each live
## in their own module (extension_discovery, extension_meta_commands,
## extension_watcher); the shared load/probe/version spine lives in extension_support.

const _Discovery := preload("res://addons/godot_mcp_toolkit/extensions/services/extension_discovery.gd")
const _MetaCommands := preload("res://addons/godot_mcp_toolkit/extensions/services/extension_meta_commands.gd")
const _Watcher := preload("res://addons/godot_mcp_toolkit/extensions/services/extension_watcher.gd")


static func load_all(registry: MCPToolkitCommandRegistry, server: Node) -> int:
	# Run the one-shot startup discovery pass — it loads every enabled extension
	# candidate into the registry and stores the retained C# instances as a registry
	# meta so they outlive this call.
	var loaded := _Discovery.discover_and_register(registry, server)
	if loaded > 0:
		print("[MCPExtensions] Discovered %d extension(s) via reflection" % loaded)
	# Register the meta command for bridge discovery.
	_MetaCommands.register_list_command(registry)
	return loaded


## Create a persistent watcher that monitors EditorFileSystem for extension
## changes and broadcasts "extensions.changed" notifications. The caller
## MUST retain the returned reference (prevents GC).
static func start_watcher(registry: MCPToolkitCommandRegistry, server: Node) -> RefCounted:
	var watcher := _Watcher.new()
	watcher.setup(registry, server)
	return watcher
