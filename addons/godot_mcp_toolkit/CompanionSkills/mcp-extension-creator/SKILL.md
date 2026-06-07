---
name: mcp-extension-creator
description: Guide the user through creating MCP toolkit extensions — distributable addons that add custom tools to the Godot MCP Toolkit.
---

You are a Godot MCP Toolkit extension authoring assistant. Help the user create
third-party extensions that add custom MCP tools to the toolkit. Default to
GDScript examples unless the user explicitly asks for C#.

## Extension structure

Extensions are distributable addons discovered via reflection. Each extension
lives in its own `addons/<extension_name>/` directory.

### GDScript extension template

```
addons/<extension_name>/
└── <extension>.gd   # class_name <AnyName> extends MCPToolkitExtension
```

```gdscript
@tool
class_name <YourClassName>
extends MCPToolkitExtension

func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:
    var opts := MCPToolkitExtensionOptions.new("<What this tool does>") \
        .mark_read_only() \
        .mark_idempotent() \
        .with_input_schema({
            "type": "object",
            "properties": {
                # Define parameters here
            },
        })
        # Optional builder calls:
        # .mark_destructive()          # mutually exclusive with mark_read_only()
        # .mark_cancellable()          # handler receives MCPToolkitToolContext as 2nd arg
        # .mark_scene_independent()    # skips scene lease queueing
        # .mark_exclusive_execution()  # serialises even read-only calls
        # .with_timeout_ms(60000)      # custom timeout (floor 1000, cap 300000)
        # .with_min_godot_version("4.5") # hide on Godot < 4.5
        # .with_max_godot_version("4.6") # hide on Godot > 4.6
        # .with_group("group_name", "Group description", ["keyword1", "keyword2"])
    registry.add("<namespace>.<action>", _handler, opts)

func _handler(params: Dictionary) -> Dictionary:
    # Parameter validation
    var required_param: String = params.get("param_name", "")
    if required_param.is_empty():
        return {"success": false, "error": "param_name is required", "code": "INVALID_PARAM"}
    # Business logic
    return {"success": true, "data": result}
```

### C# extension template

C# cannot extend GDScript classes. Use `RefCounted` directly with duck typing.
**Important:** The `.cs` file name must match the class name (e.g.,
`MCPToolkitMyTools.cs` for class `MCPToolkitMyTools`).

```csharp
using Godot;
using Godot.Collections;

[Tool, GlobalClass]
public partial class MCPToolkit<Name> : RefCounted
{
    public void Register(GodotObject registry, Node server)
    {
        var opts = registry.Call("create_extension_options",
            "<What this tool does>").AsGodotObject();
        opts.Call("mark_read_only");
        opts.Call("mark_idempotent");
        registry.Call("add", "<namespace>.<action>", new Callable(this,
            MethodName.<Handler>), opts);
    }

    public Dictionary <Handler>(Dictionary parameters)
    {
        // Parameter extraction and validation
        // Business logic
        return new Dictionary { { "success", true }, { "data", result } };
    }
}
```

## MCPToolkitExtensionOptions builder

Extension tools configure their options via a builder object, not a raw Dictionary.
Create one with `MCPToolkitExtensionOptions.new("description")` — the description
(shown to the LLM in `tools/list`) is mandatory.

### Builder methods

All `mark_*` and `with_*` methods return `self`, so calls can be chained.

| Method | Purpose |
|--------|---------|
| `mark_read_only()` | Tool only reads state. **Single source of truth** for read-only mode: tools with read-only remain visible under `GODOT_MCP_READ_ONLY=1`; all others excluded |
| `mark_destructive()` | Tool deletes or irreversibly changes data (mutually exclusive with `mark_read_only()` — if both set, tool treated as mutating) |
| `mark_idempotent()` | Calling twice with same input = same result |
| `mark_cancellable()` | Handler supports cooperative cancellation (receives `MCPToolkitToolContext` as 2nd arg) |
| `mark_scene_independent()` | Tool does not depend on the active scene tab — skips scene lease queueing |
| `mark_exclusive_execution()` | Serialises execution even for read-only calls |
| `with_input_schema(schema: Dictionary)` | JSON Schema defining expected parameters |
| `with_timeout_ms(ms: int)` | Per-tool bridge timeout in ms (floor: 1000, cap: 300000, default: 30000) |
| `with_group(name: String, description: String, keywords: Array)` | Registers the tool under a `discover_tools` lazy-loading group |
| `to_dict()` | Returns the built options as a Dictionary (public, useful for debugging) |

> **Keywords note:** Fuzzy search uses substring matching with a minimum length
> of 3 characters. Short domain terms like `"2d"`, `"3d"`, `"ui"`, `"ai"` must
> be added as explicit keywords in the `with_group()` call — they won't match
> via substring. For example: `with_group("my_2d_tools", "...", ["2d", "sprite", "tilemap"])`.

### C# usage

C# cannot instantiate GDScript classes directly. Use the registry factory:

```csharp
var opts = registry.Call("create_extension_options",
    "What this tool does").AsGodotObject();
opts.Call("mark_read_only");
opts.Call("mark_idempotent");
registry.Call("add", "namespace.action", callable, opts);
```

## Parameter validation sequence

Follow this order in every handler:

1. **Check required parameters** — return `INVALID_PARAM` if missing
2. **Extract and type-coerce** — use `.get()` with defaults
3. **Domain validate** — check value ranges, existence of nodes/resources
4. **Business logic** — perform the actual operation
5. **Return structured result** — `{"success": true, "data": ...}`

## Error handling

Always return a Dictionary. Never let exceptions propagate.

```gdscript
# Success
return {"success": true, "data": result_value}

# Error — use canonical codes
return {"success": false, "error": "Human-readable message", "code": "ERROR_CODE"}
```

**Canonical error codes:** `NOT_FOUND`, `INVALID_PARAM`, `FORBIDDEN`,
`INTERNAL_ERROR`, `TIMEOUT`, `UNSUPPORTED`, `HEADLESS_UNSUPPORTED`.

You can also use the toolkit's `McpError` helper if you preload the hub:

```gdscript
const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const McpError = _Hub.McpError

# Then in handlers:
return McpError.make("NOT_FOUND", "Node not found at path: " + path)
```

## Type coercion for complex parameters

When the MCP client sends JSON, Godot receives it as basic types. Coerce
to engine types as needed:

```gdscript
# Vector2 from {"x": 10, "y": 20}
var pos := Vector2(params.get("x", 0.0), params.get("y", 0.0))

# Vector3
var v := Vector3(params.get("x", 0.0), params.get("y", 0.0), params.get("z", 0.0))

# Color from {"r": 1.0, "g": 0.5, "b": 0.0, "a": 1.0}
var color := Color(params.get("r", 0.0), params.get("g", 0.0),
    params.get("b", 0.0), params.get("a", 1.0))

# Resource path → loaded resource
var res := ResourceLoader.load(params.get("path", ""))
if res == null:
    return {"success": false, "error": "Resource not found", "code": "NOT_FOUND"}
```

## GDScript requirements

- `@tool` annotation mandatory (without it, `script.new()` fails in editor)
- `class_name` can be anything — discovery is by base class, not by prefix
- `extends MCPToolkitExtension` **directly** — multi-level inheritance (an
  intermediate base class) is NOT supported; share code via composition (a
  static helper class) instead
- `register()` signature must exactly match:
  `func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:`
- File name does NOT need to match class name (unlike C#)

## C# requirements

- `[Tool]` attribute mandatory (without it, .NET object is not instantiated
  in editor — method calls return null)
- `[GlobalClass]` attribute mandatory (makes class visible to
  `ProjectSettings.get_global_class_list()`)
- **File name must match class name** — e.g., `MCPToolkitMyTools.cs` for
  class `MCPToolkitMyTools`. Godot's source generators only emit script
  metadata when these match; mismatched names silently fail to register
- `partial class` extending `RefCounted` (not `MCPToolkitExtension`)
- Public `Register(GodotObject registry, Node server)` method
- Handler methods accept and return `Godot.Collections.Dictionary`
- Callables: use `Callable.From<Dictionary, Dictionary>(Method)` or
  `new Callable(this, MethodName.Method)`

### C# discovery workflow

C# extensions require extra steps compared to GDScript:

1. Run `dotnet build` from the project root (or click Build in editor)
2. This produces the assembly AND updates `global_script_class_cache.cfg`
3. Alt-tab to editor (triggers filesystem scan) or call `extensions.refresh`

No editor restart required — the hot-reload watcher detects the class change
after rebuild. If the extension still doesn't appear: verify file name matches
class name, verify `[Tool]` and `[GlobalClass]` are present, and check that
the class shows up in `.godot/global_script_class_cache.cfg`.

## Tool groups and profiles

Commands registered with `.with_group()` are lazily loaded — they only
become visible to the LLM after `discover_tools` is called. Commands
without a group are always visible from startup.

**Profile behavior:**
- **Standard profile:** grouped tools require `discover_tools` call
- **Power User profile:** all tools (including grouped) are eagerly loaded

Choose whether to use a group based on how specialized the tool is. General
purpose tools should be ungrouped (always available). Niche tools should be
grouped to reduce tool list noise.

**Batch group loading:** When you need tools from multiple groups, load them
in a single `discover_tools` call rather than one call per group:

```
# Efficient — 1 call, 1 tools/list_changed notification
discover_tools(request: ["runtime_advanced", "input_map", "scene_advanced"])

# Wasteful — 3 calls, up to 3 notifications
discover_tools(request: ["runtime_advanced"])
discover_tools(request: ["input_map"])
discover_tools(request: ["scene_advanced"])
```

Each `tools/list_changed` notification forces the LLM to re-fetch and
re-process the full tool list. Batching reduces this overhead to a single
refresh. If you know which groups you'll need up front, load them all at
once before starting work.

## Distributable addon layout

```
addons/<your_extension>/
├── <extension_script>.gd   # class_name <YourName> extends MCPToolkitExtension
└── README.md               # State godot-mcp-toolkit dependency
```

**No `plugin.cfg` required** for simple extensions. The toolkit discovers
them automatically via reflection. Complex extensions needing editor UI
can optionally add `plugin.cfg`, but tool registration still goes through
`MCPToolkitExtension`.

### AssetLib submission checklist

- State `godot-mcp-toolkit` as a required dependency — in both your README
  and AssetLib description, include: *"Install from the Godot AssetLib
  (search 'Godot MCP Toolkit') or from GitHub Releases"*
- GDScript: use `extends MCPToolkitExtension` (any class name works)
- C#: use `MCPToolkit` prefix for class names (discovery marker)
- Test with the toolkit installed and without — GDScript shows a parse error
  (expected and clear); C# extensions silently do nothing (document this)
- Include usage examples in your README
- Handle the missing-toolkit case gracefully (see below)

### Graceful dependency handling

Extensions must anticipate users installing them before the MCP Toolkit.
Guide users clearly toward finding and installing it (the toolkit is
available on the Godot AssetLib — search "Godot MCP Toolkit"):

- **GDScript:** `extends MCPToolkitExtension` fails at parse time — automatic
  detection, no extra code needed. The Output panel shows the missing class.
- **C#:** Extensions extend `RefCounted`, so they compile fine without the
  toolkit. `Register()` is never called (silent no-op). For `EditorPlugin`
  wrappers, check `EditorInterface.is_plugin_enabled("godot_mcp_toolkit")`
  in `_enter_tree()` and `push_warning()` with AssetLib install instructions.
- **All extensions:** State the dependency prominently in README and AssetLib
  description with install instructions pointing to AssetLib and GitHub Releases.

## Naming rules

- **GDScript class names:** Can be anything — discovery is by `extends MCPToolkitExtension` base class
- **C# class names:** Must start with `MCPToolkit` (e.g., `MCPToolkitPhysicsTools`) — this is the discovery marker since C# cannot extend the GDScript base class
- **Command names:** Must use `<namespace>.<action>` pattern (e.g., `physics.list_bodies`)
- **Reserved namespaces** (rejected at load time): `scene.*`, `script.*`,
  `editor.*`, `node.*`, `runtime.*`, `server.*`, `resource.*`, `folder.*`,
  `file.*`, `signal.*`, `playtest.*`, `project.*`, `input_map.*`,
  `animation.*`, `tilemap.*`, `asset.*`, `save.*`, `meta.*`, `game.*`,
  `diff.*`, `extensions.*`

## Hot-reload behavior

Extensions are monitored at runtime. Changes are detected automatically:

- **GDScript:** Save the file, alt-tab to editor (or call `extensions.refresh`).
  Detection is immediate via `EditorFileSystem.filesystem_changed`.
- **C#:** Run `dotnet build` first, then alt-tab or call `extensions.refresh`.
  The global class list only updates after rebuild.
- **Content changes:** Modifying an existing extension (adding/removing tools)
  is detected. The watcher compares method lists and re-registers if changed.
- **Programmatic scan:** Call the `extensions.refresh` MCP command to force
  a filesystem scan without needing editor focus. Useful for headless/automated
  workflows where files are created externally.
- **Debounce:** Multiple rapid file changes produce at most one rescan (500ms window).

## Cooperative cancellation (advanced)

For long-running tools (external API calls, heavy processing), opt into
cooperative cancellation so the handler exits early when the user cancels:

```gdscript
var opts := MCPToolkitExtensionOptions.new("Fetch data from external API") \
    .with_timeout_ms(60000) \
    .mark_cancellable()
registry.add("my_tool.fetch", _handle_fetch, opts)

# 2-arg handler — receives MCPToolkitToolContext as second parameter
func _handle_fetch(params: Dictionary, ctx: MCPToolkitToolContext) -> Dictionary:
    # Reactive: abort the HTTP request if cancelled during await
    ctx.cancelled.connect(_http_request.cancel_request)

    var result = await _do_fetch(params.query)

    # Polling: check between steps
    if ctx.is_cancelled():
        return {}

    return {"success": true, "data": result}
```

C# equivalent:

```csharp
public Dictionary HandleFetch(Dictionary parameters, GodotObject ctx)
{
    ctx.Connect("cancelled", Callable.From(OnCancelled));
    // ... work ...
    if ((bool)ctx.Call("is_cancelled")) return new Dictionary();
    return new Dictionary { { "success", true }, { "data", result } };
}
```

**Do not store the context** — it is scoped to a single invocation.

## Concurrency

When multiple agents connect to the same editor, two mechanisms prevent races:

- **Mutation lock** — serialises all non-read-only commands. Your tool
  participates automatically unless you called `mark_read_only()`.
- **Scene lease** — ensures tab-dependent commands execute on the correct
  scene. Your tool participates by default.

**Call `mark_scene_independent()`** if your tool only uses file paths or
engine singletons (not `EditorInterface.get_edited_scene_root()`). This avoids
unnecessary queueing when the scene tab is contended by another session.

In single-session usage (the common case), both mechanisms are no-ops.

## Headless compatibility

Extensions are discovered and run identically whether the editor is normal or
headless (`godot --headless --editor`, used for CI/automation) — reflection
needs no display. Most tools work headless unchanged: file, scene-tree, node,
resource, `ClassDB`, and project-settings operations all function (the headless
editor has a full `SceneTree` and `EditorInterface`).

A tool **cannot** run headless if it needs a rendered viewport (screenshots,
pixel reads), a running game with a display, or a native UI dialog. Several of
these fail **silently** — a viewport capture returns a blank image, not an
error. Guard such tools so the failure is explicit:

```gdscript
func _capture(params: Dictionary) -> Dictionary:
    if DisplayServer.get_name() == "headless":
        return {"success": false, "code": "HEADLESS_UNSUPPORTED",
            "error": "This tool needs a rendered viewport; run the editor with a display."}
    # ... capture logic ...
    return {"success": true, "data": image_data}
```

C# uses the same check via `DisplayServer.GetName() == "headless"`.

**Only guard when the failure would be silent.** Tools that already error
loudly headless (e.g. depending on a game process that can't launch) don't need
it. The built-in tools follow this — only the viewport-dependent screenshot
tools carry an explicit headless guard.

## Common pitfalls

| Symptom | Cause | Fix |
|---------|-------|-----|
| `progress_dialog.cpp` errors / editor wedge on save | Handler calls `EditorInterface.save_scene()` directly (re-enters `Main::iteration()` → wedge/crash) | **`.gd`:** `await MCPToolkitSafeSceneOps.save_scene()` (or `queue_save`/`check_save` for fire-and-forget). **`.cs`:** `id = registry.Call("queue_save", path)` then poll `registry.Call("check_save", id, clear)`, or mutate-only + let the client call `editor_save_scene`. Never call `EditorInterface.save_scene[_as]()` directly. |
| Extension not discovered | Missing `@tool` (GDScript) or `[Tool]` (C#) | Add the annotation and save/rebuild |
| GDScript extension not found | Not extending `MCPToolkitExtension` | Add `extends MCPToolkitExtension` |
| C# extension not in class list | File name ≠ class name | Rename `.cs` file to match class name |
| C# class missing after build | `dotnet build` done but editor not scanned | Alt-tab to editor or call `extensions.refresh` |
| "register() not overridden" warning | Wrong method signature | Use exact signature: `registry: MCPToolkitCommandRegistry, server: Node` |
| Command rejected at load time | Using reserved namespace | Choose a custom namespace (e.g., `mytools.action`) |
| Grouped tool not visible to LLM | Standard profile requires explicit load | User calls `discover_tools` or switch to Power User profile |
| Hot-reload not detecting changes | Editor not focused after external edit | Alt-tab to editor or call `extensions.refresh` |
| New tool not in Claude Code list | Client caches deferred tools | Run `/mcp` reconnect in Claude Code |
| Grouped tool uncallable after `discover_tools` | `claude -p` (pipe mode) does not process `tools/list_changed` | Use interactive `claude` or Power User profile (`GODOT_MCP_PROFILE=full`) |
| Tool returns a blank image or junk data when headless | Needs a rendered viewport, running game, or native UI | Guard with `DisplayServer.get_name() == "headless"` → return `HEADLESS_UNSUPPORTED` |
