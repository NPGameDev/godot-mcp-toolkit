@tool
extends RefCounted
## Shared extension-support leaf: load, validate, and probe a single MCP-toolkit
## extension, plus the candidate-detection and Godot-4.2 cache/version questions
## that both the discovery pass and the live watcher rely on.
##
## Stateless — every function takes its inputs (registry, server, class name,
## script path) as parameters and returns its result. load_extension() returns
## the loaded instance so the CALLER owns retention (the C# GC-safety reference),
## rather than this leaf holding any cross-call state.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")

const _PREFIX := "MCPToolkit"

# Built-in namespaces that extensions cannot override.
const RESERVED_PREFIXES: Array[String] = [
	"scene.", "script.", "editor.", "node.", "runtime.", "server.",
	"resource.", "folder.", "file.", "signal.", "playtest.", "project.",
	"input_map.", "animation.", "tilemap.", "asset.", "save.", "meta.",
	"game.", "diff.", "autoload.", "extensions.",
]


## Check whether a global-class-list entry is an extension candidate.
## GDScript: detected by base class (extends MCPToolkitExtension) — no naming restriction.
## C#: detected by MCPToolkit prefix (cross-language inheritance isn't possible).
## The base-class check naturally excludes internal toolkit classes (their base
## is RefCounted/Node, not MCPToolkitExtension).
static func is_extension_candidate(entry: Dictionary) -> bool:
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
static func is_addon_enabled(script_path: String) -> bool:
	if not script_path.begins_with("res://addons/"):
		return true
	var addon_name := script_path.trim_prefix("res://addons/").get_slice("/", 0)
	if addon_name.is_empty():
		return true
	# No plugin.cfg → not a formal addon, no toggle mechanism exists.
	if not FileAccess.file_exists("res://addons/%s/plugin.cfg" % addon_name):
		return true
	return EditorInterface.is_plugin_enabled(addon_name)


## True on Godot 4.2.x ONLY. The 4.2 editor natively crashes when a brand-new or
## just-modified @tool extension is (re)loaded in-session via a fresh
## CACHE_MODE_IGNORE load while EditorFileSystem is still reimporting it: IGNORE forces
## a second, unregistered, SYNCHRONOUS parallel load (resource_loader.cpp:478-479)
## that collides with the editor's own reimport during global-class registration
## (engine bugs godot#95527 / #58883 / #59669). 4.3+ handles this cleanly. The match
## is explicit major.minor equality so a future 5.2 is NOT caught and all 4.2.x patch
## releases ARE.
static func is_godot_42() -> bool:
	return Modules.VersionUtils.is_engine_version_pair("4.2")


## Cache mode for loading extension scripts. 4.2 uses CACHE_MODE_REUSE, which returns
## the editor's existing (or in-flight) resource instead of spawning the crash-prone
## duplicate synchronous load — the trade-off is that an in-session EDIT to an existing
## extension is not reflected until restart (a cached read; surfaced as a nudge). 4.3+
## keeps CACHE_MODE_IGNORE: a guaranteed-fresh read (reliable live modify-detection),
## proven crash-free.
static func _extension_cache_mode() -> int:
	return ResourceLoader.CACHE_MODE_REUSE if is_godot_42() else ResourceLoader.CACHE_MODE_IGNORE


## Hash of an extension's source file, or 0 if unreadable. A plain text read — no
## script instantiation — so it is safe to call mid-reimport on 4.2. Used to detect
## an in-session edit the 4.2 cache path cannot apply live.
static func hash_extension_source(script_path: String) -> int:
	if not FileAccess.file_exists(script_path):
		return 0
	var f := FileAccess.open(script_path, FileAccess.READ)
	if f == null:
		return 0
	var text := f.get_as_text()
	f.close()
	return text.hash()


static func arrays_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i] != b[i]:
			return false
	return true


## Load an extension into a scratch registry to discover which methods it
## registers and their metadata. Does NOT modify the live registry.
## Returns {"methods": Array[String], "metadata": Dictionary}.
static func probe_extension(class_name_str: String, script_path: String, server: Node) -> Dictionary:
	var empty := {"methods": [] as Array[String], "metadata": {}}
	var script: Script = ResourceLoader.load(script_path, "", _extension_cache_mode())
	if script == null:
		return empty
	var instance = script.new()
	if instance == null:
		return empty
	var scratch := MCPToolkitCommandRegistry.new()
	if instance.has_method("Register"):
		instance.Register(scratch, server)
	elif instance.has_method("register"):
		instance.register(scratch, server)
	var methods: Array[String] = []
	var metadata: Dictionary = {}
	for method: String in scratch.get_all_methods():
		methods.append(method)
		metadata[method] = str(scratch.get_command_metadata(method))
	return {"methods": methods, "metadata": metadata}


## Load, validate, and register a single extension into the live registry. Returns
## the retained instance on success, or null on any failure (unloadable script,
## failed contract validation, or zero new commands registered). The CALLER must
## retain the returned instance — it is the C# GC-safety reference that keeps the
## extension's registered Callables alive.
static func load_extension(class_name_str: String, script_path: String, registry: MCPToolkitCommandRegistry, server: Node) -> Object:
	var script: Script = ResourceLoader.load(script_path, "", _extension_cache_mode())
	if script == null:
		push_warning("[MCPExtensions] '%s': failed to load script at %s" % [class_name_str, script_path])
		return null

	var is_csharp := script_path.ends_with(".cs")
	var instance = script.new()
	if instance == null:
		push_warning("[MCPExtensions] '%s': script.new() returned null" % class_name_str)
		return null

	# Validate extension contract.
	if is_csharp:
		# C# cannot extend GDScript classes — use duck typing.
		if not instance.has_method("Register") and not instance.has_method("register"):
			push_warning("[MCPExtensions] '%s': C# class missing Register() method - skipped" % class_name_str)
			return null
	else:
		# GDScript must extend MCPToolkitExtension.
		if not (instance is MCPToolkitExtension):
			push_warning("[MCPExtensions] '%s': GDScript class does not extend MCPToolkitExtension - skipped" % class_name_str)
			return null

	# Record methods before registration to detect new ones.
	var before: Array = registry.get_all_methods()

	# Open the load-time collision-guard window around register(). While it is
	# active, any add() of an already-registered name (built-in or earlier extension)
	# is refused in the registry rather than silently overwriting it — closing the
	# accidental-reuse footgun that registry.add() would otherwise allow (it is
	# last-writer-wins outside this window). First-loaded wins within the window;
	# the loser is reported below. Note: the guard is window-scoped — it does NOT
	# prevent a full-trust extension from deferring an add() past register()
	# (installed extensions are full-trust in-process code; that is out of scope).
	registry.begin_extension_load()

	# Call register — handle both GDScript (snake_case) and C# (PascalCase).
	if instance.has_method("Register"):
		instance.Register(registry, server)
	elif instance.has_method("register"):
		instance.register(registry, server)

	# Drain + report any collisions the guard refused during register(). These
	# went to the editor (push_error + a dock toast where available) only — never
	# into the MCP response stream, so the LLM sees no extra noise.
	var refused: Array[Dictionary] = registry.end_extension_load()
	for entry: Dictionary in refused:
		_report_collision(class_name_str, str(entry.get("method", "")))

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
				push_warning("[MCPExtensions] '%s': '%s' uses reserved namespace '%s*' - rejected" % [class_name_str, method, prefix])
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
		# When every add() collided, the refusals above are the reason — say so
		# rather than a bare "zero new commands". Not retaining the instance is
		# correct here: it registered nothing live, so there is no live Callable
		# bound to it (no GC-break risk), and every incumbent command it tried to
		# overwrite is untouched.
		if refused.is_empty():
			push_warning("[MCPExtensions] '%s': registered zero new commands" % class_name_str)
		else:
			push_warning("[MCPExtensions] '%s': registered zero new commands - all %d add(s) collided with already-registered commands" % [class_name_str, refused.size()])
		return null

	# Return the instance so the caller can retain it (critical for C# —
	# prevents GC from invalidating Callables).
	return instance


## Surface a refused extension command collision to the EDITOR only — never the
## MCP response stream (no agent-facing noise). push_error always fires (Output
## panel + Errors tab); a dock toast is added when the EditorToaster exists
## (Godot 4.4+; null-safe degrade below). Names the offending extension + the
## command it tried to claim. The colliding add() was already refused in the
## registry, so this is a report, not a mutation.
static func _report_collision(class_name_str: String, method: String) -> void:
	var msg := (
		"MCP Toolkit: extension '%s' tried to register '%s', " % [class_name_str, method]
		+ "but that command is already registered - keeping the existing one. "
		+ "Rename the extension's command to a unique <namespace>.<action>.")
	push_error("[MCPExtensions] " + msg)
	# EditorToaster is 4.4+ — get_toaster() returns null below that, so degrade
	# to the push_error alone. Severity 2 == EditorToaster.SEVERITY_ERROR.
	var toaster = Modules.EditorAccess.get_toaster()
	if toaster != null:
		toaster.push_toast(msg, 2)
