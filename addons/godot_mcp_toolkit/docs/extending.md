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
	registry.add("physics.list_bodies", _list_bodies, {
		"description": "List all physics bodies in the current scene",
		"input_schema": {
			"type": "object",
			"properties": {
				"body_type": {
					"type": "string",
					"enum": ["rigid", "static", "character", "all"]
				}
			}
		},
		"annotations": {
			"readOnlyHint": true,
			"idempotentHint": true
		},
		"group": {
			"name": "physics_tools",
			"description": "Physics inspection and manipulation"
		}
	})

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
		registry.Call("add", "dialogue.list_nodes", new Callable(this,
			MethodName.ListNodes), new Dictionary {
			{ "description", "List all dialogue nodes in the current scene" },
			{ "annotations", new Dictionary {
				{ "readOnlyHint", true },
				{ "idempotentHint", true }
			}}
		});
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
registry.add(method: String, handler: Callable, options: Dictionary)
```

| Key | Type | Default | Purpose |
|-----|------|---------|---------|
| `description` | String | `""` | Tool description in MCP `tools/list` |
| `input_schema` | Dictionary | `{}` | JSON Schema for tool input validation |
| `annotations` | Dictionary | `{}` | MCP tool annotations (see below) |
| `group` | Dictionary | `{}` | Tool group for `discover_tools` (see below) |

**Annotations:**

| Key | Type | Default | When to use |
|-----|------|---------|-------------|
| `readOnlyHint` | bool | `false` | Tool only reads state, never modifies it |
| `destructiveHint` | bool | `false` | Tool deletes or irreversibly changes data |
| `idempotentHint` | bool | `false` | Calling twice with the same input produces the same result |
| `openWorldHint` | bool | `false` | Tool interacts with external systems outside the editor |

**Groups:**

Commands declaring a `group` key are registered behind `discover_tools`
with lazy-load semantics. Commands without a `group` stay at root level —
always visible from startup.

```gdscript
"group": {
	"name": "physics_tools",          # Group identifier
	"description": "Physics inspection and manipulation",  # Shown in discover_tools
	"keywords": ["physics", "force", "collision", "rigidbody", "gravity"],  # For keyword search
}
```

Commands sharing a group name are collected together. The MCP client loads
the group by calling `discover_tools({"groups": ["physics_tools"]})` or
by keyword search: `discover_tools({"request": "physics"})`.

**Keywords** help `discover_tools` find your group when the LLM searches
by domain or task. Without keywords, matching falls back to description
tokens and tool names — explicit keywords give much better results.
Include Godot-specific terms, task descriptions, and abbreviations.

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
`INTERNAL_ERROR`, `TIMEOUT`. Use `MCPError.make(code, message)` from
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

### Motivating example: C# script_check

The built-in `script.check` tool only supports `.gd` files — no in-process
C# parser exists. A community extension could fill this gap:

```csharp
[Tool, GlobalClass]
public partial class MCPToolkitCSharpCheck : RefCounted
{
	public void Register(GodotObject registry, Node server)
	{
		registry.Call("add", "csharp.check", new Callable(this,
			MethodName.CheckScript), new Dictionary {
			{ "description", "Run dotnet build and return C# diagnostics" },
			{ "annotations", new Dictionary {
				{ "readOnlyHint", true },
				{ "idempotentHint", true }
			}}
		});
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
changing descriptions, fixing handler logic) is also detected. The watcher
re-probes each known extension on every scan and compares method lists. If
they differ, old tools are unregistered and the extension is re-loaded fresh.

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
