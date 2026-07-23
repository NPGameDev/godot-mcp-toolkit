---
name: mcp-extension-creator
description: Guide the user through creating MCP toolkit extensions — distributable addons that add custom tools to the Godot MCP Toolkit.
---

You are a Godot MCP Toolkit extension authoring assistant. Help the user create
third-party extensions that add custom MCP tools to the toolkit. Default to
GDScript examples unless the user explicitly asks for C#. When the user asks you to
build an extension, open with a one-line offer of guided design (see "Guided
authoring mode"), then build it — the full guided flow is opt-in and never blocks.

## Quick start — a complete working extension

Paste this, rename the class, save it under `addons/<your_extension>/`, and
reload (alt-tab to the editor or call `extensions_refresh`). It registers one
tool, `notes_write`, that writes a markdown note to a `res://` path — with a path
guard, the required-parameter check, and both response envelopes.

```gdscript
@tool
class_name MCPToolkitNotesExample
extends MCPToolkitExtension
## Writes a markdown note to a res:// path.

func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:
    var opts := MCPToolkitExtensionOptions.new("Write a markdown note to a res:// path") \
        .mark_scene_independent() \
        .guard_project_path("file_path") \
        .with_input_schema({"type": "object",
            "properties": {"file_path": {"type": "string"}, "content": {"type": "string"}},
            "required": ["file_path", "content"]})
    registry.add("notes.write", _write, opts)

## Writes [param content] to [param file_path]. Returns the written path.
func _write(params: Dictionary) -> Dictionary:
    var missing: Variant = MCPToolkitError.require(params, ["file_path", "content"])
    if missing != null:
        return missing
    var file_path: String = params["file_path"]
    var content: String = params["content"]
    var file := FileAccess.open(file_path, FileAccess.WRITE)
    if file == null:
        return MCPToolkitError.fail("WRITE_FAILED", "could not write " + file_path)
    file.store_string(content)
    return MCPToolkitSuccess.ok({"path": file_path})
```

You register the **wire** name `notes.write` (with a dot); the client sees the
tool as `notes_write` (dot → underscore). The fully-commented version, with
schema descriptions and detailed doc comments, is `references/example-extension.gd`.

## Extension structure

Extensions are distributable addons discovered via reflection. Each lives in its
own `addons/<extension_name>/` directory. A GDScript extension is one `.gd` file:

```
addons/<extension_name>/
└── <extension>.gd   # class_name <AnyName> extends MCPToolkitExtension
```

The skeleton — the four moving parts are the class header, the options builder,
`registry.add`, and the handler:

```gdscript
@tool
class_name <YourClassName>
extends MCPToolkitExtension
## <One-line brief of what this extension adds.>

func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:
    var opts := MCPToolkitExtensionOptions.new("<What this tool does>") \
        .mark_read_only() \
        .with_input_schema({"type": "object", "properties": {}})  # see the crib below
    registry.add("<namespace>.<action>", _handler, opts)

## <Brief of what the handler does — see "Doc comments" below.>
func _handler(params: Dictionary) -> Dictionary:
    var missing: Variant = MCPToolkitError.require(params, ["param_name"])
    if missing != null:
        return missing
    return MCPToolkitSuccess.ok({"data": params["param_name"]})
```

Every `mark_*` / `with_*` builder call and when to use it is in the decision table
below.

## C# extensions

C# cannot extend the GDScript base class, so the mechanics differ and a build
step is required. Two gotchas dominate:

- **File name must match the class name** (`MCPToolkitMyTools.cs` for class
  `MCPToolkitMyTools`) — a mismatch silently fails to register.
- **Class name must start with `MCPToolkit`** — that prefix is the C# discovery
  marker.

Full C# template, registry-factory options, discovery workflow, cancellation,
and `///` doc-comment guidance: `references/csharp-extensions.md`.

## MCPToolkitExtensionOptions — decision table

Configure a tool with the builder, created via
`MCPToolkitExtensionOptions.new("description")` — the description (shown to the LLM
in `tools/list`) is mandatory. Every `mark_*` / `with_*` method returns `self`, so
calls chain. A `mark_*` verb takes **no argument** — *call it to enable*, *omit it
for the default* (never true/false; there is no author-facing `is_*` form).

**Behavioral flags — get these right (default is stated first):**

| Verb | Default (omitted) | Set it when | Consequence if wrong |
|------|-------------------|-------------|----------------------|
| `mark_read_only()` | tool treated as **mutating** | the tool only reads state, never writes | Omitted on a real reader: it serializes behind the mutation lock (slower under multi-session) and is excluded under `GODOT_MCP_READ_ONLY=1`. Set on a writer: its writes bypass serialization → races. |
| `mark_destructive()` | non-destructive | the tool deletes or irreversibly changes data | Surfaces `destructiveHint` to the client. **Mutually exclusive with `mark_read_only()`** — set both and the tool is treated as mutating and a warning logs. |
| `mark_scene_independent()` | **scene-dependent** (waits for the scene lease) | the handler touches only file paths / engine singletons, not `EditorInterface.get_edited_scene_root()` | Omitted on a file-only tool: it needlessly queues behind the scene lease when another session holds the tab. Set on a scene-reading tool: it may read the wrong scene under contention. |
| `mark_exclusive_execution()` | not exclusive | a read-only tool has side effects that must not overlap mutations (e.g. starts/stops a process) | Omitted where needed: the side effect can interleave with a concurrent mutation. Rarely needed. |
| `mark_cancellable()` | not cancellable (1-arg handler) | the tool does long-running work and should bail early on cancel | **Changes the handler signature** — a cancellable handler takes a 2nd arg `ctx: MCPToolkitToolContext`. Set it but keep a 1-arg handler and the dispatcher's 2-arg call fails. See `references/cancellation.md`. |

**Light touch — defaults usually fine:**

| Verb | Default | Note |
|------|---------|------|
| `mark_idempotent()` | not idempotent | pure client hint (`idempotentHint`); set if repeating with the same input has the same effect. |
| `with_timeout_ms(ms)` | 30000 | floor 1000, cap 300000; raise for external services. |
| `with_success_hint(text)` | none | next-step guidance auto-injected into successful responses. |
| `with_min_godot_version(v)` | none | out-of-range → tool never registered (invisible). Also raises the doc-comment BBCode floor to `v` (see below). |
| `with_max_godot_version(v)` | none | newer than `v` → not registered. Format `"major.minor"`. |

**Schema and group are their own decision, not a value tweak:**

- `with_input_schema(schema)` — the parameter contract (JSON Schema). See the
  input-schema crib below.
- `with_group(name, description="", keywords=[])` — puts the tool behind
  `discover_tools` (on-demand). Ungrouped tools are eager (visible at startup).
  **Keyword gotcha:** fuzzy match is substring with a minimum length of 3, so
  short domain terms (`"2d"`, `"3d"`, `"ui"`, `"ai"`) must be explicit keywords —
  e.g. `with_group("my_2d_tools", "...", ["2d", "sprite", "tilemap"])`.

**Path guards belong on the builder too:**

- `guard_project_path(param)` / `guard_user_path(param)` — declarative `res://` /
  `user://` guard; dispatch rejects a traversal path with `PATH_DENIED` before the
  handler runs.

## Path safety and untrusted output

The LLM is the untrusted caller. Two rules keep an extension safe.

**1. Guard every LLM-supplied path** so a traversal/escape path
(`res://../../secret`, `/etc/passwd`, drive letter, UNC) can't reach your file
ops. Prefer the **declarative** guard — dispatch rejects a bad path with
`PATH_DENIED` before your handler runs:

```gdscript
var opts = MCPToolkitExtensionOptions.new("Read a config file") \
    .mark_read_only() \
    .guard_project_path("file_path")   # res://   (.guard_user_path for user://)
```

For a path the declarative guard doesn't fit (e.g. a legitimate absolute path),
guard imperatively with `FileGuard.resolve_safe`:

```gdscript
const FileGuard = preload("res://addons/godot_mcp_toolkit/security/file_guard.gd")
var guard := FileGuard.resolve_safe(params.get("file_path", ""))
if guard["error"] != null:  # returns {error, reason} on a rejected path
    return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
```

**2. Wrap untrusted content you return.** There is no automatic output wrapping —
**you must do it**. Whenever a response field carries bytes from **outside your
own code** (a file you read, project/scene data, echoed user input, an external
tool's output), wrap it so the LLM treats it as data, not instructions:

```gdscript
const Untrusted = preload("res://addons/godot_mcp_toolkit/security/untrusted.gd")
# kind + source are labels; body is the untrusted text.
# JSON.stringify(...) a Dictionary/Array body before wrapping.
return MCPToolkitSuccess.ok({
    "content": Untrusted.wrap("config", file_path, text),
})
```

Do **not** re-wrap content a built-in tool already returned — it is wrapped once,
at origin, and re-wrapping corrupts the envelope. Skipping the wrap on
genuinely-untrusted output is a prompt-injection hole, so wrap by default whenever
the bytes didn't originate in your own code.

## Error handling

Every handler returns a Dictionary — never let an exception propagate. Use the
contract helpers, which stamp the required keys for you:

```gdscript
# Success envelope (guarantees "success": true):
return MCPToolkitSuccess.ok({"data": result_value})

# Failure — code, message, and an optional recovery hint:
return MCPToolkitError.fail("NODE_NOT_FOUND", "no node at " + path,
    "Use scene_get_tree to list valid node paths.")
```

`MCPToolkitError.fail()`, `MCPToolkitSuccess.ok()`, and `MCPToolkitError.require()`
are globals (`class_name`) — no preload needed. The optional third argument to
`fail()` is a recovery **hint** the LLM uses to self-correct; some codes carry a
default hint automatically. `require()` is the shared required-parameter check:

```gdscript
# Returns an INVALID_PARAMS error dict, or null if all keys are present:
var missing: Variant = MCPToolkitError.require(params, ["file_path"])
if missing != null:
    return missing
```

**Common error codes** (the full authoritative set is `MCPToolkitError.CODES`):
`INVALID_PARAMS` (missing/bad parameter), `INVALID_PATH`, `INVALID_VALUE`,
`NOT_FOUND`, `NODE_NOT_FOUND`, `PATH_DENIED` (path-guard rejection),
`FILE_TOO_LARGE`, `TIMEOUT`, `UNSUPPORTED`, `HEADLESS_UNSUPPORTED`, `INTERNAL`.
`MCPToolkitError.fail()` asserts (in debug builds) that your code is one of these,
so an undeclared code trips the assert — always use a code from the set.

## Doc comments (`##` for GDScript)

An authored extension declares `class_name` and extends `MCPToolkitExtension`, so
it appears in the in-editor class reference (Help / F1). Its `##` comments are a
**user-facing** surface — document it well.

- **Where:** a `##` class docstring immediately after `extends`, and a `##` block
  on each registered command handler.
- **Brief + detail:** the first `##` paragraph is the brief (shown in tooltips).
  Separate a detailed body with a single blank `##` line; `[br]` forces a break.
- **Contract, not types:** reference each parameter with `[param name]` and state
  the result with a "Returns …" sentence — describe meaning and contract, never
  restate the signature's types.
- **Anti-patterns:** no process history ("added in …", "changed by …"), no
  `@author`, no caller lists, no parrot comments restating the next line.

**Use only BBCode tags that render on Godot 4.2** — the Help renderer is the
*user's* editor, and your doc comments render on every version the extension runs on:

- **Allowed:** `[ClassName]`, `[param]`, `[member]`, `[method]`, `[signal]`,
  `[constant]`, `[enum]`, `[annotation]`; `[b]`, `[i]`, `[u]`, `[code]`,
  `[codeblock]` (plain), `[br]`, `[url]`, `[kbd]`.
- **Forbidden (4.3+ forms — render as literal text on 4.2):** `[codeblock lang=…]`
  (use plain `[codeblock]`), `[lb]` / `[rb]`, `[constructor]`, `[operator]`, and
  the `@deprecated: msg` / `@experimental: msg` forms (use the bare `@deprecated` /
  `@experimental` badge and explain in prose).

The floor rises only when you declare `with_min_godot_version(v)` — then the
extension can't run below `v`, so its doc comments may use tags valid from `v` up.

For C#, write `///` XML-doc for readers of your distributed source, but note Godot
does **not** surface C# `///` in the Help UI (only GDScript `##` is harvested) —
see `references/csharp-extensions.md`. For GDScript, the class docstring is the
reliably Help-visible surface; keep a handler docstring regardless, since it
documents the code for anyone reading the file.

## Type coercion for complex parameters

The MCP client sends JSON, so Godot receives basic types — coerce them to engine
types inside the handler (`Vector2(params.get("x", 0.0), …)`, `ResourceLoader.load`,
etc.). Full recipes: `references/type-coercion.md`.

## GDScript requirements

- `@tool` annotation mandatory (without it, `script.new()` fails in editor).
- `class_name` can be anything — discovery is by base class, not by name. The
  `MCPToolkit` prefix is a recommended convention for namespace hygiene (so your
  class never collides with user code), but not required for GDScript.
- `extends MCPToolkitExtension` **directly** — multi-level inheritance (an
  intermediate base class) is NOT supported; share code via composition (a static
  helper class) instead.
- `register()` signature must match exactly:
  `func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:`
- File name does NOT need to match the class name (unlike C#).

## Cancellation

For long-running tools, call `.mark_cancellable()` — the handler then takes a
2-arg form receiving an `MCPToolkitToolContext` to observe cancellation (poll
`ctx.is_cancelled()` or connect its `cancelled` signal). Full setup, rules, and
the C# form: `references/cancellation.md`.

## Tool groups

Commands registered with `.with_group()` are lazily loaded — they only become
visible to the LLM after `discover_tools` is called. Commands without a group are
eager (visible from startup). Choose based on how specialized the tool is:
general-purpose tools ungrouped (always available), niche tools grouped to reduce
tool-list noise.

When several groups are needed, load them in a **single** `discover_tools` call —
`discover_tools(request: ["runtime_advanced", "input_map"])`, not one call per
group. Each call fires a `tools/list_changed` notification that forces the LLM to
re-fetch the whole tool list, so batching keeps that to one refresh.

## Distributable addon layout

```
addons/<your_extension>/
├── <extension_script>.gd   # class_name <YourName> extends MCPToolkitExtension
└── README.md               # State godot-mcp-toolkit dependency
```

**No `plugin.cfg` required** for simple extensions — the toolkit discovers them via
reflection. A complex extension needing editor UI can add one, but tool
registration still goes through `MCPToolkitExtension`. For AssetLib submission:

- **State `godot-mcp-toolkit` as a required dependency** — in your README and
  AssetLib description: *"Install from the Godot AssetLib (search 'Godot MCP
  Toolkit') or from GitHub Releases"*. Include usage examples.
- **Test with the toolkit installed and without.** Users may install your
  extension first — handle the missing-toolkit case: **GDScript** fails loudly at
  parse time (`extends MCPToolkitExtension` — the Output panel names the missing
  class, no extra code needed); **C#** compiles fine and silently no-ops (document
  this; an `EditorPlugin` wrapper can `push_warning()` — see
  `references/csharp-extensions.md`).

## Naming rules

- **GDScript class names:** can be anything — discovery is by the
  `extends MCPToolkitExtension` base class. (`MCPToolkit` prefix recommended for
  namespace hygiene.)
- **C# class names:** must start with `MCPToolkit` (e.g., `MCPToolkitPhysicsTools`)
  — the discovery marker, since C# cannot extend the GDScript base class.
- **Command names — wire name vs. MCP tool name:** use the `<namespace>.<action>`
  pattern (e.g., `physics.list_bodies`). You register this **wire** name (with the
  dot); the server surfaces it to the LLM with dots replaced by underscores
  (`physics_list_bodies`). Register with the dot; call it with the underscore.
- **Reserved namespaces** (rejected at load time): `scene.*`, `script.*`,
  `editor.*`, `node.*`, `runtime.*`, `server.*`, `resource.*`, `folder.*`,
  `file.*`, `signal.*`, `playtest.*`, `project.*`, `input_map.*`,
  `animation.*`, `tilemap.*`, `asset.*`, `save.*`, `meta.*`, `game.*`,
  `diff.*`, `autoload.*`, `extensions.*`

## Hot-reload behavior

Extensions are monitored at runtime and changes are picked up automatically:

- **GDScript:** save the file, then alt-tab to the editor (or call
  `extensions_refresh`). Detection is immediate via `EditorFileSystem.filesystem_changed`.
- **C#:** run `dotnet build` first (the global class list only updates after a
  rebuild), then alt-tab or call `extensions_refresh`.
- **Programmatic scan:** call the `extensions_refresh` MCP tool to force a scan
  without editor focus — useful when files are created externally. The watcher
  compares method lists and re-registers on change; rapid edits debounce to one
  rescan (500ms window).

> **Godot 4.2 only — editing an existing extension needs an editor restart.** On
> 4.2 the loader reads through the editor cache (a crash-avoidance measure), so an
> in-session **edit** to an already-loaded extension is not applied until you
> restart the editor; `extensions_refresh` returns a restart hint naming the
> changed extension. **Adding** and **removing** extensions still apply live on
> 4.2. Godot 4.3+ applies add / edit / remove all live.

## Concurrency

When multiple agents share one editor, two mechanisms prevent races and your tool
opts into both by default: the **mutation lock** (serialises non-read-only
commands — opt out with `mark_read_only()` only if the tool truly never writes)
and the **scene lease** (tab-dependent commands run on the correct scene — opt out
with `mark_scene_independent()` if the tool touches only file paths / engine
singletons). In single-session usage (the common case), both are no-ops. See the
decision table for the consequence of setting either flag wrong.

## Headless compatibility

Extensions run identically whether the editor is normal or headless
(`godot --headless --editor`, used for CI/automation) — reflection needs no
display. Most tools work headless unchanged (file, scene-tree, node, resource,
`ClassDB`, project-settings ops — the headless editor has a full `SceneTree` and
`EditorInterface`).

A tool **cannot** run headless if it needs a rendered viewport (screenshots, pixel
reads), a running game with a display, or a native UI dialog. Some fail
**silently** — a viewport capture returns a blank image, not an error. Guard those
so the failure is explicit:

```gdscript
func _capture(params: Dictionary) -> Dictionary:
    if DisplayServer.get_name() == "headless":
        return MCPToolkitError.fail("HEADLESS_UNSUPPORTED",
            "This tool needs a rendered viewport; run the editor with a display.")
    # ... capture logic ...
    return MCPToolkitSuccess.ok({"data": image_data})
```

C# uses the same check via `DisplayServer.GetName() == "headless"`.

**Only guard when the failure would be silent.** Tools that already error loudly
headless (e.g. depending on a game process that can't launch) don't need it. The
built-in tools follow this — several (viewport screenshots, texture generation,
game start, console capture, hot-reload) return a self-explaining headless
response rather than silent junk.

## Exporting your game

On export, the toolkit's plugin strips the addon, your extension's non-script
files, and `res://.mcp.json`. In binary-token script mode (Godot 4.3+ default)
your `.gd` ships as an inert, orphaned `.gdc` (never loaded, no runtime effect)
and the plugin warns. For a clean strip, see `references/exporting.md`.

## Getting listed in the catalog

The discoverable extension catalog is a maintainer-curated list — an entry lives in
the toolkit's catalog, not your extension's code. To get listed, file a
catalog-listing request on the toolkit repo; full field requirements and the route
are in "Getting listed in the extension catalog" in
`addons/godot_mcp_toolkit/docs/extending.md` (shipped with the addon).

## Verify your extension

Three checks confirm a new extension works end-to-end:

1. **It loads** — register the tool, then validate GDScript (run
   `validate_gdscript.sh` from your project root). No parse errors in the Output
   panel, and the loader discovered the class (or `extensions_refresh` reports it).
2. **It registers** — the tool appears via `discover_tools` (grouped) or in the
   tool list (ungrouped).
3. **It works** — verify interactively: one happy-path call succeeds, one bad-input
   call returns your error code.

## Updating your extension

- **After an edit:** hot-reload picks up added/removed tools automatically; if the
  client hasn't noticed, call `extensions_refresh` (see "Hot-reload behavior" for
  the Godot 4.2 edit-restart caveat).
- **After a toolkit update:** re-run the 3-step self-check, re-read the decision
  table for new `mark_*` / `with_*` verbs, and re-check your `min`/`max` Godot
  gates against newly-supported versions.
- **When your own change is breaking for your users** (a parameter rename/removal):
  version your extension and note it in your README.

## Input-schema crib

`with_input_schema` takes a JSON Schema describing your parameters. The essentials:

```json
{
  "type": "object",
  "properties": {
    "file_path": {"type": "string", "description": "res:// path to the note"},
    "count":     {"type": "integer", "default": 10},
    "mode":      {"type": "string", "enum": ["fast", "full"]},
    "opts":      {"type": "object", "properties": {"deep": {"type": "boolean"}}}
  },
  "required": ["file_path"]
}
```

- `properties`: one entry per parameter, each a `type` (`"string"`, `"integer"`,
  `"number"`, `"boolean"`, `"object"`, `"array"`) plus a `description`.
- `required`: array of parameter names the caller must supply.
- `enum`: restricts a value to a fixed set. `default`: the value assumed when omitted.

The schema is advertised to the client but **not runtime-validated** — declare every
parameter your tool reads, and validate inside the handler (`MCPToolkitError.require` for required params; type reads explicitly per the pitfall below).

## Guided authoring mode (opt-in)

By default you build the extension directly — "build an extension that …" means
just build it, no interview. **Guided mode is opt-in** and must never block an
autonomous run on a human interview.

- **Offer it once, in one line**, when you begin autonomous extension work — e.g.
  *"I'll scaffold this now — say 'guide me' if you'd rather walk through the design
  decisions together."* Explicit triggers that switch to guided mode: "guide me",
  "walk me through it", "step by step".
- **Adaptive depth, not a quick/thorough pre-fork.** Start lean (propose each
  setting with a one-line why) and offer more on demand ("want me to explain why
  this matters?"). An optional, skippable "how deep?" first question is fine.

**Flow — intent Q&A → one annotated draft → confirm or adjust by line:**

1. **Intent Q&A** (short): ask only what you can't infer — what the tool does, why,
   and how it behaves. Keep it to a handful of questions.
2. **Draft the complete config once:** command name, description, every annotation
   with a one-line rationale, the input schema, the group choice, and the `##`
   class + handler docstrings (so the tool is Help-ready by construction). Apply
   the decision table per-tool with a tool-specific rationale — do not confirm each
   annotation serially (they interact: `read_only` vs `destructive`, `cancellable`
   changing the signature).
3. **User confirms or points at specific lines** to change. Adjust and re-present.

## Common pitfalls

| Symptom | Cause | Fix |
|---------|-------|-----|
| `progress_dialog.cpp` errors / editor wedge on save | Handler calls `EditorInterface.save_scene()` directly (re-enters `Main::iteration()` → wedge/crash) | **`.gd`:** `await MCPToolkitSafeSceneOps.save_scene()` (or `queue_save`/`check_save` for fire-and-forget). **`.cs`:** `id = registry.Call("queue_save", path)` then poll `registry.Call("check_save", id, clear)`, or mutate-only and let the client call `editor_save_scene`. Never call `EditorInterface.save_scene[_as]()` directly. |
| Extension not discovered | Missing `@tool` (GDScript) or `[Tool]` (C#) | Add the annotation and save/rebuild |
| GDScript extension not found | Not extending `MCPToolkitExtension` | Add `extends MCPToolkitExtension` |
| "register() not overridden" warning | Wrong method signature | Use exact signature: `registry: MCPToolkitCommandRegistry, server: Node` |
| Compile error / "inferred as Variant" on a `:=` | `:=` can't infer from **any** Variant source — `params[...]`, a Variant-returning call like `MCPToolkitError.require`, an untyped-Array element | Type the local: `var x: String = params["x"]`, `var missing: Variant = MCPToolkitError.require(...)`. Never `:=` from a Variant. |
| Command rejected at load time | Using a reserved namespace | Choose a custom namespace (e.g., `mytools.action`) |
| Registered `notes.write` but the tool list shows `notes_write` | The server maps the wire name `a.b` to the MCP tool name `a_b` | Expected — register with the dot, call with the underscore |
| Grouped tool not visible to LLM | Grouped tools load on demand | User (or agent) calls `discover_tools` |
| Hot-reload not detecting changes | Editor not focused after an external edit | Alt-tab to the editor or call `extensions_refresh` |
| New tool not surfaced after registering | Some MCP clients cache the tool list | Call `extensions_refresh` (or `discover_tools` for a grouped tool); if the client still doesn't show it, run `/mcp` reconnect. In `claude -p`, on-demand `discover_tools` activation and `extensions_refresh` both work — no interactive session required. |
| Tool returns a blank image or junk data when headless | Needs a rendered viewport, running game, or native UI | Guard with `DisplayServer.get_name() == "headless"` → return `HEADLESS_UNSUPPORTED` |
