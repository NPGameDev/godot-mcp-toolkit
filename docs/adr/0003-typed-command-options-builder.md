# Typed command options builder (MCPToolkitCommandOptions)

The raw `Dictionary` parameter in `registry.add()` was replaced with a typed `MCPToolkitCommandOptions` builder class. Extension authors (and built-in commands) construct options via chained setters instead of freeform string-keyed dictionaries.

## Considered Options

**A. Keep the Dictionary.** Zero effort, but the API accepts any key — typos like `"is_readonly"` silently produce wrong defaults. No autocomplete, no documentation on hover. C# usage (`new Dictionary { { "is_read_only", true } }`) is stringly-typed.

**B. Typed class with constructor parameters.** Type-safe, but GDScript lacks named parameters and method overloading — a 9-parameter constructor is unusable. C# interop through `ClassDB.Instantiate` can't call GDScript constructors with arguments.

**C. Typed class with builder pattern (chosen).** A `RefCounted` class with chained setters (`mark_read_only()`, `with_description(...)`) that returns `self`. Builds via `MCPToolkitCommandOptions.new()` in GDScript or `registry.Call("create_options")` in C#. Internally exposes data via `to_dict()` — the registry validates the final state and converts to its internal format.

Option C was chosen because it gives full autocomplete and type safety in GDScript, works through Godot's `Call()` interop for C#, and keeps the class itself simple (no cross-field validation, no order-dependent logic). The builder pattern is the standard GDScript workaround for the lack of named parameters.

## Consequences

- **Breaking change** to `registry.add()` — third parameter changes from `Dictionary` to `MCPToolkitCommandOptions`. Acceptable pre-1.0 (no third-party extensions in the wild).
- All ~55 built-in commands must migrate to explicit `MCPToolkitCommandOptions.new()` — no null default. Built-in code becomes the reference implementation for extension authors.
- `_force_serialize` (internal-only, used by `game.start`/`game.stop`) stays off the public class — the registry handles it via a separate internal path.
- `MCPToolContext` renamed to `MCPToolkitToolContext` for prefix consistency (separate commit).

## API surface

```gdscript
# Value setters (return self)
with_description(description: String) -> MCPToolkitCommandOptions
with_input_schema(schema: Dictionary) -> MCPToolkitCommandOptions
with_timeout_ms(timeout: int) -> MCPToolkitCommandOptions
with_group(name: String, description: String = "", keywords: Array = []) -> MCPToolkitCommandOptions

# Boolean flags — positive-only, no arguments
mark_read_only() -> MCPToolkitCommandOptions
mark_destructive() -> MCPToolkitCommandOptions
mark_idempotent() -> MCPToolkitCommandOptions
mark_cancellable() -> MCPToolkitCommandOptions
mark_scene_independent() -> MCPToolkitCommandOptions

# Conversion (public — used by registry, useful for debugging)
to_dict() -> Dictionary
```

Registry additions:
- `create_options() -> MCPToolkitCommandOptions` — factory for C# discoverability
- `add()` signature: `add(method: String, handler: Callable, options: MCPToolkitCommandOptions)`

Validation (read_only + destructive contradiction, timeout clamping, empty description warning) stays in `registry.add()`, not in the class. The class stores intent; the registry validates the final state.
