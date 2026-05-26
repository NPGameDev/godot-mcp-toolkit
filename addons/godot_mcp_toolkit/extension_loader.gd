@tool
extends RefCounted
## Discovers and loads MCP toolkit extensions via reflection.
##
## Extensions are discovered by scanning ProjectSettings.get_global_class_list():
## - GDScript: any class whose base is MCPToolkitExtension (no naming restriction)
## - C#: any [GlobalClass] prefixed "MCPToolkit" with a Register() method (duck typing)
##
## Live hot-reload: call start_watcher() after load_all() to connect to
## EditorFileSystem.filesystem_changed. On each scan (debounced 500ms), diffs
## the class list against the last known state and broadcasts an
## "extensions.changed" notification to all connected MCP bridges.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")

const _PREFIX := "MCPToolkit"

# Built-in namespaces that extensions cannot override.
const RESERVED_PREFIXES: Array[String] = [
	"scene.", "script.", "editor.", "node.", "runtime.", "server.",
	"resource.", "folder.", "file.", "signal.", "playtest.", "project.",
	"input_map.", "animation.", "tilemap.", "asset.", "save.", "meta.",
	"game.", "diff.", "autoload.", "extensions.",
]

# Retain references to C# extension instances to prevent GC from
# invalidating registered Callables.
var _instances: Array = []

# ── Live watcher state ───────────────────────────────────────────────
# Populated only when start_watcher() creates a persistent instance.
var _registry: MCPToolkitCommandRegistry = null
var _server: Node = null
var _known_extensions: Dictionary = {}      # class_name_str -> script_path
var _class_methods: Dictionary = {}         # class_name_str -> Array[String] (methods)
var _class_metadata: Dictionary = {}        # class_name_str -> Dictionary (method -> str(meta))
var _failed_classes: Dictionary = {}        # class_name_str -> true (failed validation, retry on scan)
var _debounce_pending := false


static func load_all(registry: MCPToolkitCommandRegistry, server: Node) -> int:
	var loader := new()
	var loaded := loader._discover_and_register(registry, server)
	if loaded > 0:
		print("[MCPExtensions] Discovered %d extension(s) via reflection" % loaded)
	# Register the meta command for bridge discovery.
	_register_meta(registry)
	# Transfer instance ownership to the registry so they outlive this call.
	if not loader._instances.is_empty():
		registry.set_meta("_extension_instances", loader._instances)
	return loaded


## Create a persistent watcher that monitors EditorFileSystem for extension
## changes and broadcasts "extensions.changed" notifications. The caller
## MUST retain the returned reference (prevents GC).
static func start_watcher(registry: MCPToolkitCommandRegistry, server: Node) -> RefCounted:
	var watcher := new()
	watcher._registry = registry
	watcher._server = server
	# Snapshot current extension classes.
	watcher._snapshot_current_extensions()
	# Build class->methods map from already-registered extension methods.
	watcher._rebuild_class_methods_map()
	# Connect to EditorFileSystem.
	var efs := EditorInterface.get_resource_filesystem()
	efs.filesystem_changed.connect(watcher.on_filesystem_changed)
	# Also rescan when project settings change (catches addon enable/disable toggles).
	ProjectSettings.settings_changed.connect(watcher.on_settings_changed)
	# Register extensions.refresh — allows LLMs / headless mode to force
	# a filesystem scan + extension re-discovery without editor focus.
	registry.add("extensions.refresh", func(params: Dictionary) -> Dictionary:
		return await watcher._cmd_refresh(params)
	, MCPToolkitCommandOptions.new()
		.with_description("Force a filesystem scan and re-discover extensions (use when files were created externally)")
		.mark_idempotent()
		.mark_scene_independent())
	print("[MCPExtensions] Hot-reload watcher active")
	return watcher


## Check whether a global-class-list entry is an extension candidate.
## GDScript: detected by base class (extends MCPToolkitExtension) — no naming restriction.
## C#: detected by MCPToolkit prefix (cross-language inheritance isn't possible).
## The base-class check naturally excludes internal toolkit classes (their base
## is RefCounted/Node, not MCPToolkitExtension).
static func _is_extension_candidate(entry: Dictionary) -> bool:
	var base_class: String = entry.get("base", "")
	if base_class == "MCPToolkitExtension":
		return true
	# C# can't extend the GDScript base class — use prefix convention instead.
	var class_name_str: String = entry.get("class", "")
	var script_path: String = entry.get("path", "")
	if class_name_str.begins_with(_PREFIX) and script_path.ends_with(".cs"):
		return true
	return false


## Returns false only when the script lives inside a formal Godot addon
## (has plugin.cfg) AND that addon is disabled.  Everything else → true.
static func _is_addon_enabled(script_path: String) -> bool:
	if not script_path.begins_with("res://addons/"):
		return true
	var addon_name := script_path.trim_prefix("res://addons/").get_slice("/", 0)
	if addon_name.is_empty():
		return true
	# No plugin.cfg → not a formal addon, no toggle mechanism exists.
	if not FileAccess.file_exists("res://addons/%s/plugin.cfg" % addon_name):
		return true
	return EditorInterface.is_plugin_enabled(addon_name)


func _discover_and_register(registry: MCPToolkitCommandRegistry, server: Node) -> int:
	var classes: Array = ProjectSettings.get_global_class_list()
	var loaded := 0
	for entry in classes:
		if not _is_extension_candidate(entry):
			continue
		var script_path: String = entry.get("path", "")
		if not _is_addon_enabled(script_path):
			continue
		var class_name_str: String = entry.get("class", "")
		if _load_extension(class_name_str, script_path, registry, server):
			loaded += 1
	return loaded


# ── Watcher internals ────────────────────────────────────────────────

func _snapshot_current_extensions() -> void:
	_known_extensions.clear()
	var classes: Array = ProjectSettings.get_global_class_list()
	for entry in classes:
		if not _is_extension_candidate(entry):
			continue
		if not _is_addon_enabled(entry.get("path", "")):
			continue
		_known_extensions[entry.get("class", "")] = entry.get("path", "")


func _rebuild_class_methods_map() -> void:
	## Build class_name -> methods + metadata mapping from the registry's extension methods.
	## Called once at watcher start. During live reload, new methods are tracked
	## incrementally in _load_extension_tracked().
	_class_methods.clear()
	_class_metadata.clear()
	var all_ext_methods := _registry.get_extension_methods()
	# We can't perfectly attribute methods to classes after the fact, so we
	# re-scan: for each known class, load its script and call Register on a
	# temporary registry to capture which methods it adds.
	for cn: String in _known_extensions:
		var sp: String = _known_extensions[cn]
		var probe := _probe_extension(cn, sp)
		var methods: Array = probe["methods"]
		if not methods.is_empty():
			_class_methods[cn] = methods
			_class_metadata[cn] = probe["metadata"]


func _probe_extension(class_name_str: String, script_path: String) -> Dictionary:
	## Load an extension into a scratch registry to discover which methods it
	## registers and their metadata. Does NOT modify the live registry.
	## Returns {"methods": Array[String], "metadata": Dictionary}.
	var empty := {"methods": [] as Array[String], "metadata": {}}
	var script: Script = ResourceLoader.load(script_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if script == null:
		return empty
	var instance = script.new()
	if instance == null:
		return empty
	var scratch := MCPToolkitCommandRegistry.new()
	if instance.has_method("Register"):
		instance.Register(scratch, _server)
	elif instance.has_method("register"):
		instance.register(scratch, _server)
	var methods: Array[String] = []
	var metadata: Dictionary = {}
	for method: String in scratch.get_all_methods():
		methods.append(method)
		metadata[method] = str(scratch.get_command_metadata(method))
	return {"methods": methods, "metadata": metadata}


static func _arrays_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i] != b[i]:
			return false
	return true


func _cmd_refresh(_params: Dictionary) -> Dictionary:
	## Force a filesystem scan and immediate extension re-discovery.
	## Uses scan() (not scan_sources()) so NEW files are discovered —
	## scan_sources() only re-checks already-known resources.
	var efs := EditorInterface.get_resource_filesystem()
	efs.scan()
	# Wait for the full scan to complete (check is_scanning with a timeout
	# rather than a fixed timer — scan() may take longer than 1s for large
	# projects but finishes in <100ms for small ones).
	var deadline := Time.get_ticks_msec() + 5000
	while efs.is_scanning() and Time.get_ticks_msec() < deadline:
		await _server.get_tree().create_timer(0.1).timeout
	# Run rescan on the now-fresh class list (bypass debounce).
	_debounce_pending = false
	_do_rescan()
	# Return current extension list with full metadata (same shape as
	# extensions.list and extensions.changed — input_schema, annotations, etc.).
	var methods := _registry.get_extension_methods()
	var result: Array[Dictionary] = []
	var grouped_keywords: PackedStringArray = []
	for method: String in methods:
		var meta := _registry.get_command_metadata(method)
		var entry: Dictionary = {"method": method}
		if meta.get("description", "") != "":
			entry["description"] = meta["description"]
		if not meta.get("input_schema", {}).is_empty():
			entry["input_schema"] = meta["input_schema"]
		if not meta.get("annotations", {}).is_empty():
			entry["annotations"] = meta["annotations"]
		var group: Dictionary = meta.get("group", {})
		if not group.is_empty():
			entry["group"] = group
			# Collect keywords for the activation hint.
			for kw in group.get("keywords", []):
				if str(kw) not in grouped_keywords:
					grouped_keywords.append(str(kw))
		if meta.has("timeout_ms"):
			entry["timeout_ms"] = meta["timeout_ms"]
		result.append(entry)
	var response := {"success": true, "refreshed": true, "commands": result}
	if not grouped_keywords.is_empty():
		response["hint"] = (
			"Some extension tools are in on-demand groups and need activation "
			+ "before use. Call discover_tools(request: '%s') to load them."
		) % ", ".join(grouped_keywords)
	return response


func on_filesystem_changed() -> void:
	_schedule_rescan()


func on_settings_changed() -> void:
	# Don't rescan if the toolkit itself is being disabled — avoids race
	# conditions during teardown.
	if not EditorInterface.is_plugin_enabled("godot_mcp_toolkit"):
		return
	_schedule_rescan()


func _schedule_rescan() -> void:
	if _debounce_pending:
		return
	_debounce_pending = true
	# Use a SceneTree timer for debounce (500ms). The watcher is a RefCounted
	# so it can't own timers directly — the server node's tree provides them.
	_server.get_tree().create_timer(0.5).timeout.connect(_do_rescan)


func _do_rescan() -> void:
	_debounce_pending = false
	var current: Dictionary = {}
	var classes: Array = ProjectSettings.get_global_class_list()
	for entry in classes:
		if not _is_extension_candidate(entry):
			continue
		if not _is_addon_enabled(entry.get("path", "")):
			continue
		current[entry.get("class", "")] = entry.get("path", "")

	# Diff against known state.
	var added_classes: Dictionary = {}     # class_name -> path
	var removed_classes: Array[String] = []
	for cn: String in current:
		if cn not in _known_extensions:
			added_classes[cn] = current[cn]
	for cn: String in _known_extensions:
		if cn not in current:
			removed_classes.append(cn)

	# Retry previously-failed classes (script was fixed since last scan).
	var retry_classes: Dictionary = {}
	for cn: String in _failed_classes:
		if cn in current and cn not in added_classes:
			retry_classes[cn] = current[cn]

	# Detect content changes in existing extensions (tools added/removed/modified
	# within the same class). Re-probe each known class and compare method lists
	# AND metadata (annotations, description, schema, timeout).
	var modified_classes: Dictionary = {}  # class_name -> path
	for cn: String in current:
		if cn in added_classes or cn in retry_classes:
			continue
		if not _class_methods.has(cn):
			continue
		var sp: String = current[cn]
		var probe := _probe_extension(cn, sp)
		var fresh_methods: Array = probe["methods"]
		var old_methods: Array = _class_methods.get(cn, [])
		var fresh_meta: Dictionary = probe["metadata"]
		var old_meta: Dictionary = _class_metadata.get(cn, {})
		if not _arrays_equal(fresh_methods, old_methods) or fresh_meta != old_meta:
			modified_classes[cn] = sp

	if added_classes.is_empty() and removed_classes.is_empty() \
			and retry_classes.is_empty() and modified_classes.is_empty():
		return

	# Collect removed method names before modifying state.
	var removed_methods: Array[String] = []
	for cn: String in removed_classes:
		if _class_methods.has(cn):
			removed_methods.append_array(_class_methods[cn])
			_class_methods.erase(cn)
		_class_metadata.erase(cn)
		_failed_classes.erase(cn)

	# Handle modified extensions: unregister old methods, then re-load fresh.
	for cn: String in modified_classes:
		if _class_methods.has(cn):
			for method: String in _class_methods[cn]:
				_registry.remove(method)
				print("[MCPExtensions]   ~ %s (modified, re-registering)" % method)
			removed_methods.append_array(_class_methods[cn])
			_class_methods.erase(cn)
		_class_metadata.erase(cn)

	# Unregister removed methods from the live registry.
	for method: String in removed_methods:
		if _registry.has_command(method):
			_registry.remove(method)
			print("[MCPExtensions]   - %s (removed)" % method)

	# Register new extensions.
	for cn: String in added_classes:
		_load_extension_tracked(cn, added_classes[cn])

	# Retry previously-failed classes.
	for cn: String in retry_classes:
		_load_extension_tracked(cn, retry_classes[cn])

	# Re-load modified extensions.
	for cn: String in modified_classes:
		_load_extension_tracked(cn, modified_classes[cn])

	# Update known state.
	_known_extensions = current

	# Broadcast if anything changed.
	var total_changes := removed_methods.size()
	for cn: String in added_classes:
		if _class_methods.has(cn):
			total_changes += _class_methods[cn].size()
	for cn: String in retry_classes:
		if _class_methods.has(cn):
			total_changes += _class_methods[cn].size()
	for cn: String in modified_classes:
		if _class_methods.has(cn):
			total_changes += _class_methods[cn].size()

	if total_changes > 0:
		_broadcast_extensions_changed(removed_methods)
		var parts: Array[String] = []
		var add_count := 0
		for cn: String in added_classes:
			if _class_methods.has(cn):
				add_count += 1
		for cn: String in retry_classes:
			if _class_methods.has(cn):
				add_count += 1
		if add_count > 0:
			parts.append("+%d" % add_count)
		if not modified_classes.is_empty():
			parts.append("~%d" % modified_classes.size())
		if not removed_classes.is_empty():
			parts.append("-%d" % removed_classes.size())
		if not parts.is_empty():
			print("[MCPExtensions] Hot-reload: %s class(es) changed" % " ".join(parts))


func _load_extension_tracked(class_name_str: String, script_path: String) -> void:
	## Load and register a single extension, tracking its methods + metadata.
	var before: Array = _registry.get_all_methods()
	if _load_extension(class_name_str, script_path, _registry, _server):
		var after: Array = _registry.get_all_methods()
		var new_methods: Array[String] = []
		var new_metadata: Dictionary = {}
		for method: String in after:
			if method not in before:
				new_methods.append(method)
				new_metadata[method] = str(_registry.get_command_metadata(method))
		_class_methods[class_name_str] = new_methods
		_class_metadata[class_name_str] = new_metadata
		_failed_classes.erase(class_name_str)
	else:
		_failed_classes[class_name_str] = true


func _broadcast_extensions_changed(removed_methods: Array[String]) -> void:
	## Build the extensions.changed notification payload (same shape as
	## extensions.list response + removed array) and broadcast to all peers.
	var commands: Array[Dictionary] = []
	var methods := _registry.get_extension_methods()
	for method: String in methods:
		var meta := _registry.get_command_metadata(method)
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
		commands.append(entry)
	var params := {"commands": commands, "removed": removed_methods}
	_server.broadcast_notification("extensions.changed", params)


func _load_extension(class_name_str: String, script_path: String, registry: MCPToolkitCommandRegistry, server: Node) -> bool:
	var script: Script = ResourceLoader.load(script_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if script == null:
		push_warning("[MCPExtensions] '%s': failed to load script at %s" % [class_name_str, script_path])
		return false

	var is_csharp := script_path.ends_with(".cs")
	var instance = script.new()
	if instance == null:
		push_warning("[MCPExtensions] '%s': script.new() returned null" % class_name_str)
		return false

	# Validate extension contract.
	if is_csharp:
		# C# cannot extend GDScript classes — use duck typing.
		if not instance.has_method("Register") and not instance.has_method("register"):
			push_warning("[MCPExtensions] '%s': C# class missing Register() method — skipped" % class_name_str)
			return false
	else:
		# GDScript must extend MCPToolkitExtension.
		if not (instance is MCPToolkitExtension):
			push_warning("[MCPExtensions] '%s': GDScript class does not extend MCPToolkitExtension — skipped" % class_name_str)
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
				push_warning("[MCPExtensions] '%s': '%s' uses reserved namespace '%s*' — rejected" % [class_name_str, method, prefix])
				rejected = true
				break
		if not rejected:
			registry.mark_extension(method)
			var meta := registry.get_command_metadata(method)
			var group_name: String = meta.get("group", {}).get("name", "")
			if group_name:
				print("[MCPExtensions]   + %s (group: %s)" % [method, group_name])
			else:
				print("[MCPExtensions]   + %s" % method)
			new_count += 1

	if new_count == 0:
		push_warning("[MCPExtensions] '%s': registered zero new commands" % class_name_str)
		return false

	# Retain the instance reference (critical for C# — prevents GC from
	# invalidating Callables).
	_instances.append(instance)
	return true


static func _register_meta(registry: MCPToolkitCommandRegistry) -> void:
	var handler := func(params: Dictionary) -> Dictionary:
		return _cmd_extensions_list(registry, params)
	registry.add("extensions.list", handler, MCPToolkitCommandOptions.new()
		.with_description("List all discovered third-party extensions and their commands")
		.mark_read_only()
		.mark_idempotent()
		.mark_scene_independent())


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
		if meta.has("timeout_ms"):
			entry["timeout_ms"] = meta["timeout_ms"]
		result.append(entry)
	return {"success": true, "commands": result}
