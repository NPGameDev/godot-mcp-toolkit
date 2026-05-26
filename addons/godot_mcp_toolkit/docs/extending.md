# Extending the MCP Toolkit

## Extensions (supported)

The toolkit supports distributable third-party extensions via the
`MCPToolkitExtension` base class and reflection-based discovery. Extensions
live in their own `addons/` directory (or anywhere in the project) and are
discovered automatically at plugin startup — no configuration required.

### Quick start (GDScript)

Create a `@tool` script with a `class_name` that extends `MCPToolkitExtension`.
The class name can be anything — discovery is by base class, not by prefix:

```
addons/my_physics_tools/
└── physics_extension.gd   ← class_name PhysicsTools (any name works)
```

```gdscript
# addons/my_physics_tools/physics_extension.gd
@tool
class_name PhysicsTools
extends MCPToolkitExtension

func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:
	registry.add("physics.list_bodies", _list_bodies,
		MCPToolkitExtensionOptions.new("List all physics bodies in the current scene")
			.with_input_schema({
				"type": "object",
				"properties": {
					"body_type": {
						"type": "string",
						"enum": ["rigid", "static", "character", "all"]
					}
				}
			})
			.mark_read_only()
			.mark_idempotent()
			.with_group("physics_tools", "Physics inspection and manipulation"))

func _list_bodies(params: Dictionary) -> Dictionary:
	var body_type: String = params.get("body_type", "all")
	# ... scene tree traversal logic ...
	return {"success": true, "data": bodies}
```

### Quick start (C#)

C# extensions cannot inherit GDScript classes (hard Godot limitation). Instead,
extend `RefCounted` directly with `[Tool]` and `[GlobalClass]` attributes.
The loader discovers them via duck typing (`has_method("Register")`).

```
addons/my_dialogue_tools/
└── DialogueExtension.cs   ← [GlobalClass] MCPToolkitDialogueTools
```

```csharp
// addons/my_dialogue_tools/DialogueExtension.cs
using Godot;
using Godot.Collections;

[Tool, GlobalClass]
public partial class MCPToolkitDialogueTools : RefCounted
{
	public void Register(GodotObject registry, Node server)
	{
		var opts = registry.Call("create_extension_options",
			"List all dialogue nodes in the current scene").AsGodotObject();
		opts.Call("mark_read_only");
		opts.Call("mark_idempotent");
		registry.Call("add", "dialogue.list_nodes", new Callable(this,
			MethodName.ListNodes), opts);
	}

	public Dictionary ListNodes(Dictionary parameters)
	{
		// ... scene tree traversal logic ...
		return new Dictionary { { "success", true }, { "data", nodes } };
	}
}
```

**C# requirements:**
- `[Tool]` attribute mandatory (without it, the .NET object is not
  instantiated in editor — method calls return null)
- `[GlobalClass]` attribute mandatory (makes the class visible to
  `ProjectSettings.get_global_class_list()`)
- **File name must match class name** (e.g., `MCPToolkitMyTools.cs` for
  class `MCPToolkitMyTools`) — Godot's source generators only emit
  `[ScriptPath]` metadata when these match; mismatched names silently
  fail to register in the global class list
- `partial class` extending `RefCounted` (not `MCPToolkitExtension`)
- Public `Register(GodotObject registry, Node server)` method
- Handler methods accept and return `Godot.Collections.Dictionary`
- Callables created via `new Callable(this, MethodName.Method)`
- Project must be built (`dotnet build`) before extensions are
  discoverable — the loader skips classes that haven't been compiled

### `registry.add()` API

```
registry.add(method: String, handler: Callable, options: MCPToolkitCommandOptions)
```

Options are built using a fluent builder API. Two classes are available:

- **`MCPToolkitCommandOptions`** -- base class used by built-in tools.
  Description is optional (set via `with_description()`).
- **`MCPToolkitExtensionOptions`** -- subclass for extension tools.
  Requires a description string in the constructor.

Extension tools should always use `MCPToolkitExtensionOptions`:

```gdscript
var opts = MCPToolkitExtensionOptions.new("Describe what your tool does")
```

**Builder methods** (all return `self` for chaining):

| Method | Purpose |
|--------|---------|
| `mark_read_only()` | Tool only reads state, never modifies it |
| `mark_destructive()` | Tool deletes or irreversibly changes data |
| `mark_idempotent()` | Calling twice with the same input produces the same result |
| `mark_cancellable()` | Handler supports cooperative cancellation (see below) |
| `mark_scene_independent()` | Tool does not depend on the active editor tab |
| `mark_exclusive_execution()` | Tool acquires the mutation lock despite being read-only (see below) |
| `with_description(text)` | Set or override the tool description |
| `with_input_schema(dict)` | JSON Schema for tool input validation |
| `with_timeout_ms(ms)` | Per-tool bridge timeout in milliseconds (floor: 1000, cap: 300000) |
| `with_min_godot_version(ver)` | Hide tool on Godot versions below `ver` (e.g. `"4.5"`) |
| `with_max_godot_version(ver)` | Hide tool on Godot versions above `ver` (e.g. `"4.6"`) |
| `with_group(name, description)` | Tool group for `discover_tools` (see below) |
| `to_dict()` | Returns the options as a Dictionary (for debugging) |

**Registry factory methods** (alternative to direct construction):

| Method | Returns | Use case |
|--------|---------|----------|
| `registry.create_options()` | `MCPToolkitCommandOptions` | Built-in tools |
| `registry.create_extension_options(description)` | `MCPToolkitExtensionOptions` | Extension tools (especially C#) |

**Annotations** are mapped to MCP hints internally (`mark_read_only()` →
`readOnlyHint`, `mark_destructive()` → `destructiveHint`, `mark_idempotent()` →
`idempotentHint`). Extension authors use the builder methods only.

All annotation defaults are **safe**: omitting them means the tool is
treated as mutating, non-destructive, and non-idempotent.

**Read-only mode:** The `mark_read_only()` annotation is the **single source
of truth** for read-only filtering. When the server runs with
`GODOT_MCP_READ_ONLY=1`, only tools marked read-only appear in
`tools/list` -- both built-in and extension tools use the same
annotation-driven filter. If your extension tool only inspects state
(reads nodes, queries data, lists files), call `mark_read_only()` so it
remains available in read-only environments. Tools without this annotation
are excluded by default (strict inclusion -- safe posture).

**Exclusivity:** `mark_read_only()` and `mark_destructive()` is a
logical contradiction -- a read-only tool cannot be destructive. If both
are set, a warning is logged and the tool is treated as mutating
(excluded from read-only mode).

**Timeout:** Defaults to 30 seconds. If your tool calls external services
(HTTP APIs, databases, LLM inference), increase `timeout_ms`. Values
below 1000ms are floored to 1s; values above 300000ms (5 min) are capped
and a warning is logged. Zero or negative values use the default. Tools
needing longer than 5 minutes should restructure to a start-and-poll
pattern rather than blocking the bridge.

**Async handlers:** Command handlers can use `await` internally (GDScript
coroutines). The dispatch path already awaits handler results, so both
synchronous and asynchronous handlers work without additional configuration.

**Deferred-call context:** Command handlers run inside a `call_deferred`
dispatch (used to reduce editor crash risk from main-thread reentrancy).
This means Godot APIs that use the **progress dialog** (e.g.
`EditorInterface.save_scene()`, `EditorInterface.save_scene_as()`) will
log `progress_dialog.cpp` errors if called directly. To work around this,
yield one frame before calling such APIs:

```gdscript
func _my_handler(params: Dictionary) -> Dictionary:
	# Escape the deferred-call context before calling progress-dialog APIs.
	await (Engine.get_main_loop() as SceneTree).process_frame
	EditorInterface.save_scene()
	return {"success": true}
```

This adds ~16ms of latency (one frame) and is only needed for the small
set of Godot APIs that internally show a progress dialog.

**Groups:**

Commands with a group are registered behind `discover_tools` with
lazy-load semantics. Commands without a group stay at root level --
always visible from startup.

```gdscript
MCPToolkitExtensionOptions.new("List all physics bodies in the current scene")
	.with_group("physics_tools", "Physics inspection and manipulation")
```

Commands sharing a group name are collected together. The MCP client loads
the group by calling `discover_tools({"groups": ["physics_tools"]})` or
by keyword search: `discover_tools({"request": "physics"})`.

**Keywords** help `discover_tools` find your group when the LLM searches
by domain or task. Without keywords, matching falls back to description
tokens and tool names — explicit keywords give much better results.
Include Godot-specific terms, task descriptions, and abbreviations.

### Cooperative cancellation

When an MCP client cancels a request mid-flight (e.g., user presses Ctrl+C),
the server automatically stops waiting for the result and suppresses the
response. This works for **all** tools with no code changes needed.

For extension tools that do long-running work (external API calls, heavy
computation, multi-step processing), you can opt into **cooperative
cancellation** so the handler itself bails out early, freeing resources
sooner.

**Opt in** by calling `mark_cancellable()` on the options builder.
Your handler then receives an `MCPToolkitToolContext` as the second argument:

```gdscript
registry.add("weather.fetch", _handle_weather,
	MCPToolkitExtensionOptions.new("Fetch weather data from external API")
		.with_timeout_ms(60000)
		.mark_cancellable())

func _handle_weather(params: Dictionary, ctx: MCPToolkitToolContext) -> Dictionary:
	# Reactive: connect a cleanup action to the cancelled signal.
	# If cancelled during the await, the HTTP request is aborted.
	ctx.cancelled.connect(_http_request.cancel_request)

	var result = await _fetch_api(params.query)

	# Polling: check between discrete steps.
	if ctx.is_cancelled():
		return {}

	var processed = await _process_result(result)
	if ctx.is_cancelled():
		return {}

	return {"success": true, "data": processed}
```

**`MCPToolkitToolContext` API:**

| Member | Type | Description |
|--------|------|-------------|
| `cancelled` | signal | Emitted when the request is cancelled. Connect cleanup actions to this. |
| `is_cancelled()` | bool | Returns `true` after cancellation. Poll this between steps. |

**Two cancellation patterns:**

1. **Reactive (signal):** Connect `ctx.cancelled` to a method that aborts
   the in-progress operation (e.g., `HTTPRequest.cancel_request()`). This
   can interrupt a blocked `await`.

2. **Polling:** Call `ctx.is_cancelled()` between discrete steps in a
   multi-step handler. Return an empty dictionary to exit early.

**C# usage:**

```csharp
public void Register(GodotObject registry, Node server)
{
	var opts = registry.Call("create_extension_options",
		"Fetch weather data from external API").AsGodotObject();
	opts.Call("with_timeout_ms", 60000);
	opts.Call("mark_cancellable");
	registry.Call("add", "weather.fetch", new Callable(this,
		MethodName.HandleWeather), opts);
}

public Dictionary HandleWeather(Dictionary parameters, GodotObject ctx)
{
	// Reactive: connect the cancelled signal
	ctx.Connect("cancelled", Callable.From(OnCancelled));

	// ... do work ...

	// Polling: check is_cancelled()
	bool cancelled = (bool)ctx.Call("is_cancelled");
	if (cancelled) return new Dictionary();

	return new Dictionary { { "success", true }, { "data", result } };
}
```

**Important notes:**

- **Do not store the context.** `MCPToolkitToolContext` is scoped to a single tool
  invocation. It is invalidated when your handler returns. Signal connections
  are cleaned up automatically via reference counting.

- **No preemptive cancellation.** GDScript cannot kill a running coroutine.
  If your handler never checks `is_cancelled()` and doesn't connect to the
  `cancelled` signal, it runs to completion. The server still discards the
  result — cooperative cancellation just makes it faster.

- **Mutation tools.** If your cancellable tool performs mutations, you are
  responsible for cleanup in your signal handler or polling checks. The
  toolkit does not validate your cancel path. Consider whether `is_cancellable`
  is appropriate for mutation tools — simple operations are safer without it.

- **Non-cancellable tools.** Handlers without `mark_cancellable()` keep
  their 1-arg signature and work exactly as before. No context is created,
  no overhead is added.

### Making mutations undoable

Extensions that mutate editor state should record their changes in Godot's
undo system so users can Ctrl+Z/Ctrl+Shift+Z. The toolkit provides
`MCPToolkitUndoRedoAction` — a fluent builder that wraps
`EditorUndoRedoManager` with automatic "MCP: " prefixing and headless-safe
no-op behavior.

**Recommended pattern — apply first, then record:**

```gdscript
func _set_custom_prop(params: Dictionary) -> Dictionary:
    var node = get_tree().edited_scene_root.get_node(params.node_path)
    var old_val = node.get(params.property)
    node.set(params.property, params.value)

    MCPToolkitUndoRedoAction.begin(
        "set %s.%s" % [params.node_path, params.property], node) \
        .do_property(node, params.property, params.value) \
        .undo_property(node, params.property, old_val) \
        .commit_recorded()

    return {"success": true}
```

The mutation executes first (`node.set(...)`), then the builder records it for
undo/redo. `commit_recorded()` tells Godot "the do-side already happened —
just record it." This is the standard pattern for all MCP tools.

**Node creation with reference tracking:**

```gdscript
func _create_marker(params: Dictionary) -> Dictionary:
    var parent = get_tree().edited_scene_root.get_node(params.parent_path)
    var root = get_tree().edited_scene_root
    var marker = Marker2D.new()
    marker.name = params.get("name", "Marker")
    parent.add_child(marker)
    marker.set_owner(root)

    MCPToolkitUndoRedoAction.begin("create %s" % marker.name, parent) \
        .do_method(parent.add_child.bind(marker)) \
        .do_method(marker.set_owner.bind(root)) \
        .do_reference(marker) \
        .undo_method(parent.remove_child.bind(marker)) \
        .commit_recorded()

    return {"success": true, "data": {"node_path": str(marker.get_path())}}
```

Use `do_reference()` to keep newly created objects alive for redo (they'd
otherwise be freed when undo removes them). Use `undo_reference()` to keep
old objects alive for undo (e.g., a resource being replaced).

**Two commit modes:**

| Method | When to use |
|--------|-------------|
| `commit_recorded()` | Mutation already applied. **Recommended default.** |
| `commit()` | UndoRedo executes the do-side. Use for batching scenarios. |

**Skipping expensive snapshots in headless:**

```gdscript
var action = MCPToolkitUndoRedoAction.begin("expensive op", node)
if action.is_active():
    var snapshot = _capture_expensive_state()
    action.undo_method(Callable(self, "_restore_state").bind(snapshot))
_apply_mutation(params)
if action.is_active():
    action.do_method(Callable(self, "_apply_mutation").bind(params))
    action.commit_recorded()
```

`is_active()` returns `false` in headless mode (no editor plugin). Use it to
skip expensive state capture that's only needed for undo registration.

**Double-commit guard:** Calling `commit()` or `commit_recorded()` twice on
the same builder instance fires a warning and is a no-op. This prevents
accidental undo history corruption.

**C# usage:**

C# extensions cannot call GDScript static methods directly. Instead, use the
registry factory — cache the registry reference from `Register()`:

```csharp
private GodotObject _registry;

public void Register(GodotObject registry, Node server)
{
    _registry = registry;
    var opts = registry.Call("create_extension_options",
        "Set custom property on a node").AsGodotObject();
    registry.Call("add", "custom.set_prop",
        new Callable(this, MethodName.SetCustomProp), opts);
}

public Dictionary SetCustomProp(Dictionary parameters)
{
    var nodePath = (string)parameters["node_path"];
    var prop = (string)parameters["property"];
    var node = GetTree().EditedSceneRoot.GetNode(nodePath);
    var oldVal = node.Get(prop);
    node.Set(prop, parameters["value"]);

    var action = _registry.Call("create_undo_action",
        $"set {nodePath}.{prop}", node).AsGodotObject();
    action.Call("do_property", node, prop, parameters["value"]);
    action.Call("undo_property", node, prop, oldVal);
    action.Call("commit_recorded");

    return new Dictionary { { "success", true } };
}
```

### Concurrency: scene lease and mutation lock

When multiple WebSocket peers (e.g. parallel Claude Code sessions) connect to
the same Godot editor, two concurrency mechanisms protect against races:

1. **Mutation serialisation** — at most one mutation command executes at a time.
   All mutations (including yours) are queued in FIFO order. Read-only commands
   bypass the lock entirely.

2. **Scene lease** — one peer at a time "owns" the active editor tab. Tab-
   dependent commands from other peers queue until the lease is available (up
   to an 8-second TTL before a steal occurs).

**How your extension participates:**

Your builder method calls control which mechanisms apply:

| Method | Default (if not called) | Effect |
|--------|-------------------------|--------|
| `mark_read_only()` | not read-only | Bypasses the mutation lock (executes concurrently) |
| `mark_scene_independent()` | scene-dependent | Bypasses the scene lease (no tab ownership needed) |

**Guidelines:**

- If your tool reads scene tree state via `EditorInterface.get_edited_scene_root()`,
  do not call `mark_scene_independent()` (keep the default). The lease ensures
  your tool reads the correct scene.
- If your tool only uses explicit file paths or engine singletons, call
  `mark_scene_independent()`. This lets it execute immediately even when
  the scene tab is contended.
- If your tool is read-only but scene-dependent (no `mark_scene_independent()`),
  it queues for the lease when another peer holds it. Consider whether a
  file-path-based approach could avoid the dependency.

**Single-session behaviour:** When only one peer is connected, both mechanisms
are no-ops. Zero overhead, identical behaviour to pre-concurrency versions.

### Exclusive execution

Some tools are read-only (they don't modify the scene tree) but still have
side effects that shouldn't overlap with mutations. Use
`mark_exclusive_execution()` for these cases.

Example: `game.start` and `game.stop` are read-only (they don't modify the
scene tree) but they start and stop the game process. Running a mutation
tool while the game is starting could produce unpredictable results.
`mark_exclusive_execution()` causes the tool to acquire the mutation lock
despite being marked read-only, ensuring it doesn't overlap with mutations
or other exclusive tools.

```gdscript
registry.add("physics.recalculate", _recalculate,
	MCPToolkitExtensionOptions.new("Recalculate all physics caches")
		.mark_read_only()
		.mark_exclusive_execution())
```

Use this when your tool:
- Is genuinely read-only (doesn't modify the scene tree)
- Has side effects that conflict with concurrent mutations
- Needs serialised access even though it only reads state

### Discovery rules

Extensions are discovered via `ProjectSettings.get_global_class_list()` at
plugin startup (and live via hot-reload). The discovery algorithm:

1. Scan all global classes for extension candidates:
   - **GDScript:** any class whose `base` is `MCPToolkitExtension` (no naming
	 restriction — your class can be called anything)
   - **C#:** any `[GlobalClass]` whose name starts with `MCPToolkit` (C# cannot
	 extend the GDScript base class, so prefix is the discovery marker)
   - Internal toolkit classes are naturally excluded (they extend `RefCounted`
	 or `Node`, not `MCPToolkitExtension`)
2. For GDScript classes: verify `is MCPToolkitExtension` (inheritance check)
4. For CSharpScript classes: verify `has_method("Register")` or
   `has_method("register")` (duck typing)
5. Call `register(registry, server)` (or `Register` for C#)
6. Validate newly registered methods against reserved namespaces
7. Mark valid methods as extension methods

**Discovery order:** built-in commands → extensions (reflection). No
filesystem scanning. Collision policy: first-loaded wins, subsequent
registrations of the same method name are rejected with a logged warning.

### Naming rules

- Commands must use `<namespace>.<action>` naming (e.g., `physics.list_bodies`)
- The following namespaces are reserved and rejected at load time:
  `scene.*`, `script.*`, `editor.*`, `node.*`, `runtime.*`, `server.*`,
  `resource.*`, `folder.*`, `file.*`, `signal.*`, `playtest.*`, `project.*`,
  `input_map.*`, `animation.*`, `tilemap.*`, `asset.*`, `save.*`, `meta.*`,
  `game.*`, `diff.*`, `extensions.*`
- GDScript extensions: no `class_name` prefix required (discovery is by base class)
- C# extensions: `class_name` must start with `MCPToolkit` (discovery marker)

### Error handling contract

Command handlers must return a `Dictionary`. On success:

```gdscript
return {"success": true, "data": "result here"}
```

On failure, return `success: false` with an `error` string and an
uppercase `code` for programmatic matching:

```gdscript
return {"success": false, "error": "Node not found", "code": "NOT_FOUND"}
```

The extension loader validates handler return values at runtime. Malformed
returns (non-Dictionary, missing `success` key) are normalized to the
standard error envelope with `push_error` logged. Never let exceptions
propagate — validate inputs and return structured errors instead.

**Standard error codes:** `NOT_FOUND`, `INVALID_PARAM`, `FORBIDDEN`,
`INTERNAL_ERROR`, `TIMEOUT`. Use `McpError.make(code, message)` from
`_hub.gd` if you preload the hub, or return the Dictionary directly.

### Profile behavior

Extensions are **profile-exempt** — they register regardless of the active
profile (Minimal/Standard/Power User/custom). Extensions run with the same
trust level as the plugin itself (FileGuard, FeatureGate, audit logging
all apply).

### Distributable extensions

Extension addons are submittable to Godot's AssetLib as separate entries.
Requirements for distribution:

1. Place your extension script in its own `addons/<your_addon>/` directory
2. Declare `class_name MCPToolkit<YourName>` with `extends MCPToolkitExtension`
3. No `plugin.cfg` required (simple extensions are "content addons")
4. State the `godot-mcp-toolkit` dependency prominently in your AssetLib
   description and README
5. If the base toolkit is not installed, `extends MCPToolkitExtension` fails
   at parse time — a clear error signal, not silent failure

**AssetLib update safety:** Extensions live outside the toolkit's addon
directory, so AssetLib updates to `godot-mcp-toolkit` never touch your
extension files.

### Graceful dependency handling

Extensions depend on the MCP Toolkit addon. Users may install your extension
before installing the toolkit — handle this gracefully:

**GDScript extensions:** `extends MCPToolkitExtension` causes a parse error
when the toolkit is not installed. Godot logs the error and disables the
script. This is automatic dependency detection — no extra code needed.

**C# extensions:** Since C# extensions extend `RefCounted` (not the GDScript
base class), they compile and load without the toolkit present. The extension
simply does nothing — the toolkit's extension loader is not running, so
`Register()` is never called. If you ship your extension as an
`EditorPlugin` (with `plugin.cfg`), add an active check in `_enter_tree()`:

```gdscript
# Optional: plugin.cfg wrapper for active dependency detection
@tool
extends EditorPlugin

func _enter_tree() -> void:
	if not EditorInterface.is_plugin_enabled("godot_mcp_toolkit"):
		push_warning("MyExtension requires the Godot MCP Toolkit plugin. "
			+ "Install it from the Godot AssetLib (search 'Godot MCP Toolkit') "
			+ "or from GitHub: https://github.com/NPGameDev/godot-mcp-toolkit/releases")
```

**Required for all distributable extensions:**

1. State the dependency prominently in your `README.md`:
   *"Requires the [Godot MCP Toolkit](https://github.com/NPGameDev/godot-mcp-toolkit)
   plugin. Install it from the Godot AssetLib (search 'Godot MCP Toolkit')
   or from [GitHub Releases](https://github.com/NPGameDev/godot-mcp-toolkit/releases)."*
2. Include the same dependency note in your AssetLib description
3. Test your extension both with and without the toolkit installed to
   confirm the failure mode is clear, not silent

### Motivating example: C# script_check

The built-in `script.check` tool only supports `.gd` files — no in-process
C# parser exists. A community extension could fill this gap:

```csharp
[Tool, GlobalClass]
public partial class MCPToolkitCSharpCheck : RefCounted
{
	public void Register(GodotObject registry, Node server)
	{
		var opts = registry.Call("create_extension_options",
			"Run dotnet build and return C# diagnostics").AsGodotObject();
		opts.Call("mark_read_only");
		opts.Call("mark_idempotent");
		registry.Call("add", "csharp.check", new Callable(this,
			MethodName.CheckScript), opts);
	}

	public Dictionary CheckScript(Dictionary parameters)
	{
		// Shell out to dotnet build, parse MSBuild output,
		// return structured diagnostics
		// ...
	}
}
```

This shows how extensions solve limitations of the core toolkit — any gap
in the built-in tool set can be addressed by community extensions without
forking.

### Hot-Reload Behavior

Extensions are discovered at plugin startup AND monitored at runtime. When
you add or remove an extension script while the MCP session is active, the
changes are detected automatically — no restart or reconnect required.

**GDScript extensions:** Detected immediately when the file is saved. Godot's
`EditorFileSystem.filesystem_changed` signal fires, the watcher rescans the
global class list, and new `MCPToolkit`-prefixed classes are loaded within
~500ms (debounce window). Deletion is also immediate — the tool disappears
from the MCP tool list on the next scan.

**C# extensions:** Require `dotnet build` (or Godot's Build button) for
`ProjectSettings.get_global_class_list()` to reflect additions or removals.
This matches Godot's own C# hot-reload behavior. After a build, the watcher
detects the change and registers/unregisters tools accordingly.

**Deletion while loaded (GDScript):** If a loaded extension's script file is
deleted, the GDScript handler becomes unreachable. The next tool call returns
a bridge error (not a crash). On the next filesystem scan, the tool is
automatically unregistered from the tool list.

**Deletion while loaded (C#):** The compiled DLL retains the class until the
next `dotnet build`. The tool remains callable (stale but functional) until
rebuild, at which point `get_global_class_list()` drops the class and the
tool is unregistered. This asymmetry with GDScript is inherent to Godot's
C# architecture.

**Content changes:** Modifying an existing extension script (adding tools,
changing descriptions, updating annotations, fixing handler logic) is
detected automatically. The watcher re-probes each known extension on
every scan and compares both method lists and metadata (description,
annotations, schema, timeout). If anything differs, old tools are
unregistered and the extension is re-loaded fresh.

**Editor focus required:** Godot's `EditorFileSystem` only scans for external
file changes when the editor window regains focus. If you create or modify
extension files from an external tool (terminal, Claude Code, etc.), you must
alt-tab back to the Godot editor to trigger the hot-reload. Files changed
from within Godot's script editor are detected immediately.

**Programmatic refresh:** As an alternative to editor focus, call the
`extensions.refresh` MCP command to force a filesystem scan and immediate
re-discovery. This is useful in headless/automated workflows where the LLM
creates extension files and needs them registered without user interaction.

**Debounce:** Godot fires `filesystem_changed` multiple times for a single
file operation (save triggers scan, scan triggers changed, etc.). The
extension watcher debounces at 500ms — multiple rapid signals produce at
most one rescan.

**Client-side limitation:** Some MCP clients (including Claude Code) cache
deferred tools. Mid-session additions may not appear in the client's tool
list until `/mcp` reconnect, even though the server has already registered
them. This is a platform-side limitation, not actionable server-side.

## Hooks (Internal API)

The TypeScript bridge has a hook pipeline that wraps every tool call with
pre- and post-execution middleware. The logging hook records all tool
invocations to the audit log.

**Why internal-only for 1.0:** Exposing user-extensible hooks adds security
surface (hooks can intercept or cancel any tool call) for zero demonstrated
user demand. Neither major competing implementation offers user-extensible
hooks. The internal pipeline already exceeds the ecosystem baseline.

**Post-1.0 roadmap:** If community feedback warrants it, hook extensibility
could be exposed via a configuration file (e.g., `hooks.json`) that maps
tool names to pre/post scripts. This would require careful sandboxing to
prevent hooks from escalating privilege beyond their tool's gate level.

## Prompts & Resources (Internal API)

The server exposes MCP prompts (named workflow templates like `debug-scene`,
`write-test`) and resources (`godot://scene/{path}`, `godot://script/{path}`,
`godot://project/info`, `godot://roots`). These are currently hardcoded in
the TypeScript source.

**Why internal-only for 1.0:** No competing Godot MCP implementation is
MCP-native (most use custom WebSocket protocols with no prompts or resources
at all). Our seed set of prompts and resources is already ahead of the
ecosystem. User-extensible prompt templates (custom JSON files) are a natural
post-1.0 feature but not a 1.0 requirement.

**Post-1.0 roadmap:** User-extensible prompts via JSON template files in a
`prompts/` directory. Resource extensibility via the same extension addon
pattern used for tools — extensions could declare resource providers
alongside tool handlers.
