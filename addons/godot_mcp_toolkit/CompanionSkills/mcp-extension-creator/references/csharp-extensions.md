# C# extensions

C# extensions add the same tools as GDScript ones, but C# cannot extend a
GDScript base class, so the mechanics differ. Prefer GDScript unless the project
is a .NET project — C# needs a build step before the toolkit can see the tool.

## Two hard gotchas (also in the main skill)

1. **File name must match the class name** — `MCPToolkitMyTools.cs` for class
   `MCPToolkitMyTools`. Godot's source generators only emit script metadata when
   these match; a mismatch silently fails to register.
2. **Class name must start with `MCPToolkit`** — this prefix is the C# discovery
   marker (C# cannot extend `MCPToolkitExtension`, so the loader recognizes an
   extension by the prefix on a `[GlobalClass]`).

## Template

C# uses `RefCounted` directly with duck typing. The options builder is obtained
from the registry factory (C# cannot instantiate the GDScript builder class).

```csharp
using Godot;
using Godot.Collections;

[Tool, GlobalClass]
public partial class MCPToolkitNotesTools : RefCounted
{
    /// Registers this extension's tools. Called once at load.
    public void Register(GodotObject registry, Node server)
    {
        var opts = registry.Call("create_extension_options",
            "Write a markdown note to a res:// path").AsGodotObject();
        opts.Call("guard_project_path", "file_path");
        registry.Call("add", "notes.write",
            new Callable(this, MethodName.Write), opts);
    }

    /// Writes a note. Returns a success envelope or an error dict.
    public Dictionary Write(Dictionary parameters)
    {
        // Parameter extraction, validation, and business logic.
        // Return the same {"success": bool, ...} envelope as GDScript.
        return new Dictionary { { "success", true }, { "data", "written" } };
    }
}
```

## Requirements

- `[Tool]` attribute mandatory — without it the .NET object is not instantiated
  in the editor (method calls return null).
- `[GlobalClass]` attribute mandatory — makes the class visible to
  `ProjectSettings.get_global_class_list()`.
- `partial class` extending `RefCounted` (not `MCPToolkitExtension`).
- Public `Register(GodotObject registry, Node server)` method.
- Handler methods accept and return `Godot.Collections.Dictionary`.
- Callables: `new Callable(this, MethodName.Method)` or
  `Callable.From<Dictionary, Dictionary>(Method)`.

## Options builder from the registry factory

C# cannot construct the GDScript builder directly, so call the factory and drive
it by name. Every `mark_*` / `with_*` verb works the same as GDScript.

```csharp
var opts = registry.Call("create_extension_options",
    "What this tool does").AsGodotObject();
opts.Call("mark_read_only");
opts.Call("mark_idempotent");
registry.Call("add", "namespace.action", callable, opts);
```

## Discovery workflow (C# needs a build)

1. Run `dotnet build` from the project root (or click **Build** in the editor).
2. This produces the assembly AND updates `global_script_class_cache.cfg`.
3. Alt-tab to the editor (triggers a filesystem scan) or call `extensions_refresh`.

No editor restart required — the hot-reload watcher detects the class change
after the rebuild. If the extension still doesn't appear: verify the file name
matches the class name, verify `[Tool]` and `[GlobalClass]` are present, and
check the class shows up in `.godot/global_script_class_cache.cfg`.

## Cancellation (C#)

The context arrives as a second `GodotObject` argument and is driven by name.

```csharp
public Dictionary HandleFetch(Dictionary parameters, GodotObject ctx)
{
    ctx.Connect("cancelled", Callable.From(OnCancelled));
    // ... work ...
    if ((bool)ctx.Call("is_cancelled")) return new Dictionary();
    return new Dictionary { { "success", true }, { "data", result } };
}
```

Do not store the context — it is scoped to a single invocation.

## Headless

Same guard as GDScript, via `DisplayServer.GetName() == "headless"`.

## Exporting

C# extensions compile into the project's .NET assembly and cannot be stripped
per-class. Guard editor-only work with `if (!Engine.IsEditorHint()) return;` so
nothing runs in a build.

## Doc comments (`///`)

Write `///` XML-doc comments on the class and each registered handler — they are
valuable to anyone reading your distributed source. Note, however, that Godot
does **not** harvest C# `///` into the in-editor Help (F1) page — only GDScript
`##` doc comments surface there. So `///` documents the code for human readers of
the file; it does not produce an in-editor reference entry the way `##` does.

## Graceful missing-toolkit handling

C# extensions extend `RefCounted`, so they compile fine even when the toolkit is
absent — `Register()` is simply never called (a silent no-op). For an
`EditorPlugin` wrapper, check
`EditorInterface.is_plugin_enabled("godot_mcp_toolkit")` in `_enter_tree()` and
`push_warning()` with install instructions (search "Godot MCP Toolkit" in the
Godot AssetLib). State the dependency prominently in your README either way.
