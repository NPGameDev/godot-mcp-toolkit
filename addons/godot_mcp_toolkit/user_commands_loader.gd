@tool
extends RefCounted
## Auto-discovers and loads user command extensions from user_commands/*.gd.
##
## Each .gd file must provide a static register(registry, server) function
## that calls registry.add(method, handler) for its commands.
## Commands under reserved namespaces are rejected.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPCommandRegistry = _Hub.MCPCommandRegistry

const CUSTOM_DIR := "res://addons/godot_mcp_toolkit/user_commands"

# Built-in namespaces that user commands cannot override.
const RESERVED_PREFIXES: Array[String] = [
	"scene.", "script.", "editor.", "node.", "runtime.", "server.",
	"resource.", "folder.", "file.", "signal.", "playtest.", "project.",
	"input_map.", "animation.", "tilemap.", "asset.", "save.", "meta.",
	"game.", "diff.",
]


static func load_all(registry: MCPCommandRegistry, server: Node) -> int:
	var dir := DirAccess.open(CUSTOM_DIR)
	if dir == null:
		# Directory doesn't exist or can't be opened — no user commands.
		return 0
	var loaded := 0
	for filename in dir.get_files():
		if not filename.ends_with(".gd"):
			continue
		if filename == ".gitkeep":
			continue
		if _load_one(filename, registry, server):
			loaded += 1
	if loaded > 0:
		print("[MCP] Loaded %d user command file(s) from %s" % [loaded, CUSTOM_DIR])
	# Register the meta command for bridge discovery.
	_register_meta(registry)
	return loaded


static func _load_one(filename: String, registry: MCPCommandRegistry, server: Node) -> bool:
	var path := CUSTOM_DIR.path_join(filename)
	var script: GDScript = load(path) as GDScript
	if script == null:
		push_warning("[MCPTools] failed to load user command script: %s" % filename)
		return false
	var before: Array = registry.get_all_methods()
	# User scripts may use static register() or instance register().
	if script.has_method("register"):
		script.register(registry, server)
	else:
		var instance = script.new()
		if instance.has_method("register"):
			instance.register(registry, server)
		else:
			push_warning("[MCPTools] user command '%s' missing register(registry, server) — skipped" % filename)
			return false
	# Validate newly registered methods against reserved namespaces.
	var after: Array = registry.get_all_methods()
	var new_count := 0
	for method: String in after:
		if method in before:
			continue
		var rejected := false
		for prefix: String in RESERVED_PREFIXES:
			if method.begins_with(prefix):
				registry.remove(method)
				push_warning("[MCPTools] user command '%s' rejected: '%s' uses reserved namespace '%s*'" % [filename, method, prefix])
				rejected = true
				break
		if not rejected:
			registry.mark_user(method)
			new_count += 1
	if new_count == 0:
		push_warning("[MCPTools] user command '%s' registered zero new commands" % filename)
		return false
	return true


static func _register_meta(registry: MCPCommandRegistry) -> void:
	registry.add("meta.user_commands", func(params: Dictionary) -> Dictionary:
		return _cmd_user_commands(registry, params))


static func _cmd_user_commands(registry: MCPCommandRegistry, _params: Dictionary) -> Dictionary:
	var methods := registry.get_user_methods()
	var result: Array[Dictionary] = []
	for method: String in methods:
		result.append({
			"method": method,
		})
	return {"success": true, "commands": result}
