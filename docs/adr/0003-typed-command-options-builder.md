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
- `_force_serialize` is exposed publicly as `mark_exclusive_execution()` on the builder. The internal-only `_set_force_serialize()` path was removed — all callers (including `game.start`/`game.stop`) use the builder method.
- `MCPToolContext` renamed to `MCPToolkitToolContext` for prefix consistency (bundled in the same commit as the builder migration).
- `MCPToolkitExtensionOptions` subclass added with mandatory `description` in its constructor. Built-in tools use `MCPToolkitCommandOptions` (description optional via `with_description()`); extension tools use `MCPToolkitExtensionOptions` (description required at construction). This enforces the boundary between built-in and extension tools at the type level.
- `push_warning` for empty description was removed — enforcement moved to `MCPToolkitExtensionOptions` constructor, making it a hard error for extensions and a non-issue for built-ins.

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
mark_exclusive_execution() -> MCPToolkitCommandOptions  # force serialization for read-only tools with side effects

# Conversion (public — used by registry, useful for debugging)
to_dict() -> Dictionary
```

`MCPToolkitExtensionOptions` (extends `MCPToolkitCommandOptions`):
```gdscript
# Constructor — description is mandatory for extension tools
_init(description: String)
```

Registry additions:
- `create_options() -> MCPToolkitCommandOptions` — factory for C# discoverability
- `create_extension_options(description: String) -> MCPToolkitExtensionOptions` — factory for extension tools (enforces mandatory description)
- `add()` signature: `add(method: String, handler: Callable, options: MCPToolkitCommandOptions)`

Validation (read_only + destructive contradiction, timeout clamping) stays in `registry.add()`, not in the class. The class stores intent; the registry validates the final state. Empty description warning removed — `MCPToolkitExtensionOptions` enforces at construction time.
