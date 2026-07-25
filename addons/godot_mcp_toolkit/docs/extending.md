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
	return MCPToolkitSuccess.ok({"data": bodies})
```

**Start from the bundled example.** A complete, ready-to-copy single-tool
extension ships at
`addons/godot_mcp_toolkit/CompanionSkills/mcp-extension-creator/references/example-extension.gd`
— copy it into your own project and adapt it as a starting point.

**Declaring the class is all it takes.** The toolkit auto-discovers any script
that declares `class_name` **and** `extends MCPToolkitExtension` anywhere in your
project (unless it lives inside a *disabled* addon). Just declaring the class in
your enabled project registers its tools — you never call a manual registration
step yourself.

**Why the bundled example is inert where it ships.** `CompanionSkills/` holds
skills and docs, not project code, so it carries a `.gdignore` and the editor
never scans it — that deliberately keeps the example from auto-registering its
`notes.write` tool inside the toolkit itself. To use it, copy the file into your
**own** project (outside `addons/godot_mcp_toolkit/`); it's discovered on the next
filesystem scan or when you call `extensions_refresh`.

### Quick start (C#)

C# extensions cannot inherit GDScript classes (hard Godot limitation). Instead,
extend `RefCounted` directly with `[Tool]` and `[GlobalClass]` attributes, and
name the class with the `MCPToolkit` prefix — because C# cannot extend the
GDScript base class, that prefix is the discovery marker. The loader then
verifies each candidate via duck typing (`has_method("Register")`).

```
addons/my_dialogue_tools/
└── MCPToolkitDialogueTools.cs   ← [GlobalClass] MCPToolkitDialogueTools (file name matches class name)
```

```csharp
// addons/my_dialogue_tools/MCPToolkitDialogueTools.cs
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

**C# note:** The raw `new Dictionary { { "success", true }, ... }` pattern
is valid and recommended for C#. Alternatively, you can call the GDScript
`MCPToolkitSuccess.ok()` via interop
(`GD.Load<GDScript>("res://addons/godot_mcp_toolkit/contract/mcp_toolkit_success.gd").Call("ok", dict)`)
but the raw Dictionary is simpler. Both produce the same result.

**C# requirements:**
- **Class name must start with `MCPToolkit`** (e.g., `MCPToolkitMyTools`) —
  this prefix is the loader's discovery filter for C#; a class without it is
  never found, regardless of its attributes or methods
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
| `with_input_schema(dict)` | JSON Schema declaring expected parameters (sent to MCP client; not validated at runtime — handlers must check their own inputs). **Important:** parameters not declared in the schema may not be forwarded to the handler — always declare every parameter your tool accepts |
| `with_timeout_ms(ms)` | Per-tool bridge timeout in milliseconds (floor: 1000, cap: 300000) |
| `with_min_godot_version(ver)` | Hide tool on Godot versions below `ver` (e.g. `"4.5"`) |
| `with_max_godot_version(ver)` | Hide tool on Godot versions above `ver` (e.g. `"4.6"`) |
| `with_success_hint(text)` | Default hint injected into successful responses (LLM guidance for next steps) |
| `with_group(name, description)` | Tool group for `discover_tools` (see below) |
| `guard_project_path(param)` | Validate a `res://` path parameter before your handler runs — rejects traversal/escape with `PATH_DENIED` (see *Path safety* below) |
| `guard_user_path(param)` | Same, for a `user://` path parameter |
| `to_dict()` | Returns the options as a Dictionary (for debugging) |

**Registry factory methods** (alternative to direct construction):

| Method | Returns | Use case |
|--------|---------|----------|
| `registry.create_options()` | `MCPToolkitCommandOptions` | Built-in tools |
| `registry.create_extension_options(description)` | `MCPToolkitExtensionOptions` | Extension tools (especially C#) |
| `registry.fail(code, message, hint)` | `Dictionary` | Structured error (C# parity for `MCPToolkitError.fail()`) |
| `registry.require(parameters, required)` | `Variant` | Param validation (C# parity for `MCPToolkitError.require()`) |

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

**Path safety — guard every LLM-supplied path.** If your tool takes a path the
LLM fills in, validate it so a traversal/escape path (`res://../../secret`,
`/etc/passwd`, a drive letter, a UNC share) can't reach your file ops. Two ways:

- **Declarative (recommended):** declare the parameter on the builder. The
  dispatch validates it and returns `PATH_DENIED` *before* your handler runs.

  ```gdscript
  var opts = MCPToolkitExtensionOptions.new("Read a config file") \
      .mark_read_only() \
      .guard_project_path("file_path")   # res:// path parameter
      # .guard_user_path("slot")          # user:// path parameter
  ```

- **Imperative:** for a path the declarative guards don't fit (e.g. a parameter
  that legitimately accepts an *absolute* filesystem path), validate inside the
  handler with the same guard the built-ins use:

  ```gdscript
  const FileGuard = preload("res://addons/godot_mcp_toolkit/security/file_guard.gd")
  var guard := FileGuard.resolve_safe(params.get("file_path", ""))   # res://, path-boundary checked
  if guard["error"] != null:
	  return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
  # user:// paths: FileGuard.resolve_safe_user(path) → {ok, error_code, error_message}
  ```

**Wrap untrusted content you return.** Whenever your tool returns content whose
bytes came from **outside your own code** — a file you read, project/scene data,
user input echoed back, an external tool's output — wrap that field so the LLM
treats it as data, not instructions:

```gdscript
const Untrusted = preload("res://addons/godot_mcp_toolkit/security/untrusted.gd")

func _read_config(params: Dictionary) -> Dictionary:
    var text := FileAccess.get_file_as_string(params["file_path"])
    return {
        "success": true,
        # kind + source are labels; body is the untrusted text.
        # JSON.stringify(...) a Dictionary/Array body first.
        "content": Untrusted.wrap("config", params["file_path"], text),
    }
```

Built-in tools already wrap file/project content where they read it; do the same
for content **your** extension produces. Do **not** re-wrap content a built-in
tool already returned to you — it is wrapped once, at origin, and re-wrapping
corrupts the envelope.

### Reading large data: size caps & pagination

If your tool reads data and returns it — a file's bytes, scene/resource dumps, a
list of matches — it faces the **same transport limit as the built-ins**, and it
should follow the **same pagination contract**. Hand back a megabyte in one
response and the model never sees it.

**The WebSocket frame ceiling — oversized responses silently vanish.** Every
response travels as one WebSocket frame that must fit under the per-peer outbound
buffer (`ws_buffer_kb`, default **1 MB** in the editor; the runtime server that
ships inside an exported game is **hardcoded at 1 MB** and ignores the setting).
The engine does **not** chunk a frame that exceeds the buffer — it rejects the
whole frame at the send call (Godot's `modules/websocket/wsl_peer.cpp`,
`WSLPeer::_send`, fails with `ERR_OUT_OF_MEMORY` when
`queued + p_buffer_size > outbound_buffer_size`; this guard is present unchanged
across 4.2–4.5). The toolkit's send path does **not** inspect that return, so an
oversized response is **dropped with no error** — the client just waits and times
out. You cannot rely on "it'll truncate"; it won't. **Never emit a response you
haven't bounded.**

**Token economics — even a frame that fits can be too big.** Returned text costs
the model context (and money). A rough rule is ~4 chars/token ≈ **250 tokens/KB**,
so **256 KB ≈ 64K tokens** and a full **1 MB ≈ ~250K tokens** — enough to swamp the
context window on a single call (see Anthropic's Claude context-window
documentation for current limits). Return only what the task needs; let the agent
page for the rest. For **binary** payloads remember **base64 inflates ~33%** — size
your cap against the encoded worst case, not the raw bytes.

**Mirror the uniform pagination contract.** A capped or windowed read returns a
**fixed response shape** so the agent runs the same loop for every paginating tool.
Match these field names exactly (they are the built-in contract):

| Field | Type | When present | Meaning |
|-------|------|--------------|---------|
| `has_more` | bool | **always** (on success) | `true` if more data remains beyond this window; `false` if this window reached the end. |
| `total_<unit>` | int | **always** | The full size of the source — e.g. `total_bytes`, `total_lines`, `total_entries`. Lets the agent see how much is left. |
| `returned` | int | **always** | The size of this window — this page's row/byte/line count. |
| `next_<cursor>` | (matches request) | only when `has_more` is `true` | The value to pass back to resume — e.g. `next_offset` (bytes), `next_start_line` (lines). |
| `hint` | string | only when `has_more` is `true` | One prose line telling the agent to re-call with that cursor until `has_more` is `false`. |

The loop the agent runs is always: *call → if `has_more`, pass `next_<cursor>`
back as the matching request parameter → call again → stop when `has_more` is
`false`.*

**Copy a built-in.** Two built-ins already implement this — read them and follow
the same shape:

- **`save.read`** pages a `user://` file by **bytes**: request `offset` (default
  `0`) + `max_bytes`; response carries `next_offset`, `total_bytes`, `returned`,
  `has_more`, and (when there's more) a `hint` to re-call with `offset = next_offset`.
- **`script.read`** pages a project script by **lines**: request
  `start_line`/`end_line` (1-based); response carries `next_start_line`,
  `total_lines`, `returned`, `has_more`, and (when there's more) a `hint`.

**Keep the request parameters unit-appropriate** — only the *response* shape is
uniform. Page bytes with a byte `offset`; page lines with a line cursor; don't
force a byte offset onto a tool whose natural unit is something else. A tool that
reads a region or set rather than a linear stream may legitimately be
**cursor-less**: return `has_more` + `returned` + a total and let the agent narrow
by filter or re-query (e.g. a tighter region), instead of inventing a meaningless
`next_offset`. The contract still holds — `has_more` and a total are always
there; the resumable `next_<cursor>` is simply omitted when there is nothing
linear to resume.

**Cap the read with a setting, and reject — never dump.** Don't let payload size
be unbounded. Mirror the built-ins, which cap each window with a project setting
(`save_read_cap_kb` / `script_read_cap_kb`, default **256 KB**) and read it
**live** on every call. If a requested window — or the full read — would exceed
that cap or the frame buffer, return a structured **`FILE_TOO_LARGE`** error with a
"narrow the range / paginate" hint, **instead of** sending a payload the transport
will silently drop:

```gdscript
const CAP_BYTES := 256 * 1024   # better: read a live ProjectSettings limit here

func _read_blob(params: Dictionary) -> Dictionary:
	var offset: int = max(0, int(params.get("offset", 0)))
	var total := _blob_size(params)                       # full source size
	var want: int = clampi(int(params.get("max_bytes", CAP_BYTES)), 1, CAP_BYTES)
	if want > CAP_BYTES:                                   # window exceeds the cap
		return MCPToolkitError.fail("FILE_TOO_LARGE",
			"Requested window exceeds the %d-byte cap." % CAP_BYTES,
			"Lower max_bytes (cap %d) or page with offset." % CAP_BYTES)

	var chunk := _read_range(params, offset, want)        # at most `want` bytes
	var end := offset + chunk.size()
	var more := end < total
	var out := {
		"success": true,
		"returned": chunk.size(),
		"offset": offset,
		"total_bytes": total,        # total_<unit> — always present
		"has_more": more,            # has_more — always present
		"content": Untrusted.wrap("blob", str(params.get("path", "")), chunk),
	}
	if more:
		out["next_offset"] = end     # next_<cursor> — only when has_more
		out["hint"] = "more bytes remain — re-call with offset = next_offset (%d) until has_more is false" % end
	return out
```

This is the only safe way to expose data larger than the frame buffer: the agent
reads it across several capped calls. (A capped read also keeps any *single*
response cheap — see token economics above.) The same idea applies on the
**line** axis for a script-style tool: cap the line window, set
`total_lines` / `returned` / `has_more` / `next_start_line`, and reject an
over-cap full read with `FILE_TOO_LARGE` and a "use a line range" hint.

The user-facing **`advanced_configuration.md`** documents this contract from the
*caller's* side (the loop an agent follows, with worked `save_read` / `script_read`
examples) — your tool returning these same fields lets an agent that already knows
the built-in loop page your tool with zero new learning.

> **Use the shared helper.** `contract/pagination.gd` (reached as
> `Modules.Pagination`) centralizes the cap + `has_more` + `next_<cursor>`
> bookkeeping shown above — call its family methods (`list_page`, `byte_page`,
> `line_page`) or its generic `build()` instead of hand-rolling the pattern.

**Saving a scene from a handler — choose by your scripting language.**
Handlers run inside a `call_deferred` dispatch. Calling
`EditorInterface.save_scene()` / `save_scene_as()` directly is **unsafe in any
language** — the progress dialog re-enters `Main::iteration()`, which can
dispatch another command mid-save and **wedge or crash the editor** (all Godot
versions). Use the editor-safe API:

**GDScript (`.gd`) handlers — `await MCPToolkitSafeSceneOps.save_scene()`:**

```gdscript
func _my_handler(params: Dictionary) -> Dictionary:
	# Waits out any EditorFileSystem scan, escapes the deferred context, and wraps
	# the synchronous save in a re-entrancy flag. path == "" → active scene.
	return await MCPToolkitSafeSceneOps.save_scene()
```

This is the only supported **inline** save (you get the result back). A `.gd`
handler that wants fire-and-forget can instead call
`MCPToolkitSafeSceneOps.queue_save(path)` → save id, and poll
`MCPToolkitSafeSceneOps.check_save(id, clear)`.

**C# (`.cs`) handlers — via the `registry` facade.** C# handlers are
synchronous and cannot `await` a GDScript coroutine or call its statics, so they
reach the editor-safe save through the `registry` from `Register(registry,
server)` — the same single facade as `create_undo_action` / `fail`:

```csharp
// Start-and-poll. queue_save returns a save id immediately; the editor-safe
// save runs after your handler returns. path "" = active scene.
string id = (string)registry.Call("queue_save", path);
// ...poll until done (e.g. from a companion status tool the client calls):
var status = (Godot.Collections.Dictionary)registry.Call("check_save", id, /*clear*/ true);
// status = {done:bool, success:bool, result:{...}}  (or {done:false, unknown:true})
```

A synchronous C# handler can't wait on the save itself, so polling is
**client-driven**: return the `id` (or expose a thin `check_*` tool that calls
`registry.Call("check_save", id, clear)`) and let the MCP client poll until
`done`. If you don't need the result, the simplest path is **mutate-only** —
change the scene tree, return, and let the client persist via the built-in
`editor_save_scene` tool.

> Never call `EditorInterface.save_scene[_as]()` (GDScript) or
> `EditorInterface.SaveScene()` (C#) directly — the crash applies to both.

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

	return MCPToolkitSuccess.ok({"data": processed})
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

	return MCPToolkitSuccess.ok()
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

	return MCPToolkitSuccess.ok({"data": {"node_path": str(marker.get_path())}})
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

**Context object is required for scene operations:** The second argument to
`begin()` (`context_object`) tells `EditorUndoRedoManager` which undo history
to use. When omitted (or `null`), the action lands in the **global history**
(ID 0). If the do/undo callbacks then reference nodes that belong to a
**scene history** (ID 1+), Godot logs `UndoRedo history mismatch` errors and
undo/redo may silently fail.

Always pass an in-tree node as `context_object` when your tool operates on
scene nodes:

```gdscript
# WRONG — missing context, routes to global history:
MCPToolkitUndoRedoAction.begin("add to group") \
	.do_method(node.add_to_group.bind("enemies")) \
	...

# CORRECT — node is in the scene tree, routes to scene history:
MCPToolkitUndoRedoAction.begin("add to group", node) \
	.do_method(node.add_to_group.bind("enemies")) \
	...
```

The only time `null` context is correct is for **global operations** that don't
touch scene nodes (e.g., writing a script file to disk).

**Gotcha — orphaned context:** If you remove a node from the tree *before*
calling `begin()`, the node is orphaned and resolves to global history even
though you passed it explicitly. Record the undo action using a node that is
still in the tree (typically the parent):

```gdscript
# WRONG — node already removed, resolves to global history:
parent.remove_child(node)
MCPToolkitUndoRedoAction.begin("delete node", node) ...

# CORRECT — parent is still in the tree:
parent.remove_child(node)
MCPToolkitUndoRedoAction.begin("delete node", parent) ...
```

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

### Setting `editor_description` (Godot 4.3 crash guard)

Setting a node's `editor_description` arms a 0.5-second one-shot tooltip timer in
the editor's scene-tree dock that holds a **raw pointer to that node's tree row**.
On **Godot 4.3**, concurrent scene-tree churn frees that row before the timer
fires (4.3 rebuilds the whole dock on every node add/remove/move and has no
tree-row cache), so the timer can fire on freed memory and crash the editor with a
use-after-free. Godot 4.2 has no such timer, and 4.4+ keeps the row alive across
rebuilds — 4.3 is the only affected version.

The built-in `node_set_property` and `scene_create_node` tools prevent this
automatically, but a set you perform **directly from your own GDScript bypasses
that guard**. Disarm the timer yourself immediately *before* the write by calling
the shared helper — it drops the editor's tooltip connections on that node so the
set arms nothing, is a **no-op on every version except 4.3**, and needs no
`await`:

```gdscript
const Helpers := preload("res://addons/godot_mcp_toolkit/commands/editor_helpers.gd")

func _annotate(params: Dictionary) -> Dictionary:
	var node := _resolve(params)  # a node in the edited scene
	Helpers.disarm_tooltip_uaf(node, "editor_description")  # no-op off 4.3
	node.set("editor_description", str(params.get("text", "")))
	# ... register undo (see "Making mutations undoable" above) ...
	return MCPToolkitSuccess.ok({})
```

Call it right before the set, with no `await` in between (a yield would let tree
churn re-arm the timer). If you cannot call the helper (e.g. a C# extension, which
cannot call the GDScript helper), set `editor_description` only when you will
**not** churn the scene tree (add/remove/move nodes) within half a second — and
never batch it with other tree mutations on Godot 4.3.

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

### Non-blocking waits

**Never use `OS.delay_msec()` or `OS.delay_usec()` in command handlers.**
These are hard OS-level thread sleeps that freeze Godot's entire main thread
— the editor UI, rendering, and input all stop responding until the sleep
completes. A polling loop with `OS.delay_msec(100)` and a 5-second timeout
will freeze the editor for up to 5 seconds.

Use `await Engine.get_main_loop().create_timer(seconds).timeout` instead.
This yields control back to the engine so the UI stays responsive while your
handler waits:

```gdscript
# BAD — freezes the editor:
while some_condition():
	OS.delay_msec(100)

# GOOD — editor stays responsive:
while some_condition():
	await Engine.get_main_loop().create_timer(0.1).timeout
```

`Engine.get_main_loop()` returns the `SceneTree` and works in both instance
and static methods. The dispatch system already `await`s every handler call,
so your handler becoming a coroutine requires no extra setup.

Common scenarios where this applies:
- Waiting for `EditorFileSystem.is_scanning()` to finish — prefer
  `await MCPToolkitSafeSceneOps.wait_for_scan_idle()` (bounded by
  `mcp_toolkit/concurrency/scan_idle_timeout_ms`) over an unbounded loop
- Polling for a process or service to become ready
- Any loop that needs to pause between iterations

### Headless compatibility

Your extension is discovered and registered identically whether the editor runs
normally or headless (`godot --headless --editor`, used for CI and automated
runs) — reflection discovery needs no display. Most tools work unchanged
headless: file, scene-tree, node, resource, `ClassDB`, and project-settings
operations all function, because the headless editor still has a full
`SceneTree` and `EditorInterface`.

A tool **cannot** work headless if it needs a rendered viewport (screenshots,
pixel reads via `get_viewport().get_texture()`), a running game with a display,
or a native UI dialog. The trap is that several of these fail **silently** — a
viewport capture returns a blank image rather than an error — so the caller
can't tell the result is junk. Guard those tools explicitly:

```gdscript
func _screenshot_bodies(params: Dictionary) -> Dictionary:
	if DisplayServer.get_name() == "headless":
		return MCPToolkitError.fail("HEADLESS_UNSUPPORTED",
			"physics.screenshot_bodies needs a rendered viewport.",
			"Run the editor with a display (omit --headless) to use this tool.")
	# ... capture logic ...
	return MCPToolkitSuccess.ok({"data": image_data})
```

C# handlers use the same check via `DisplayServer.GetName() == "headless"`,
returning the error with `registry.Call("fail", "HEADLESS_UNSUPPORTED", ...)`.

**Rule of thumb:** add this guard only when the tool would otherwise return
*silent* junk. Tools that already fail loudly headless — e.g. a handler that
depends on a game process that can't launch — don't need it; the natural error
is clear enough. This mirrors the built-in tools, where the headless-divergent
ones (viewport screenshots, texture generation, game start, console capture,
hot-reload) each return a self-explaining headless response instead of silent junk.

### Discovery rules

Extensions are discovered via `ProjectSettings.get_global_class_list()` at
plugin startup (and live via hot-reload). The discovery algorithm:

1. Scan all global classes for extension candidates:
   - **GDScript:** any class whose **immediate** `base` is `MCPToolkitExtension`
	 — i.e. extend it **directly**. Multi-level inheritance is **not** supported:
	 a class two or more levels deep (e.g. `class_name Child extends ParentExt`)
	 is not discovered. Share code across extensions via composition (a static
	 helper both call), not an intermediate base — independent per-subclass
	 discovery would otherwise cause order-dependent duplicate registrations.
	 Your class name can still be anything (discovery is by base class, not prefix).
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
- The **MCP tool name** the client sees replaces the dots with underscores
  (`physics.list_bodies` → `physics_list_bodies`). Register with the dotted wire name;
  the LLM calls the underscore form.
- The following namespaces are reserved and rejected at load time:
  `scene.*`, `script.*`, `editor.*`, `node.*`, `runtime.*`, `server.*`,
  `resource.*`, `folder.*`, `file.*`, `signal.*`, `playtest.*`, `project.*`,
  `input_map.*`, `animation.*`, `tilemap.*`, `asset.*`, `save.*`, `meta.*`,
  `game.*`, `diff.*`, `autoload.*`, `extensions.*`
- GDScript extensions: extend `MCPToolkitExtension` **directly** (multi-level
  inheritance is not supported); `class_name` can be anything (discovery is by
  base class, not prefix)
- C# extensions: `class_name` must start with `MCPToolkit` (discovery marker)

### Error handling contract

Command handlers must return a `Dictionary` with a `"success"` key. The
framework enforces this contract at dispatch — malformed returns are caught
and converted to structured errors.

**Success response** (use `MCPToolkitSuccess.ok()`):

```gdscript
return MCPToolkitSuccess.ok({"data": result_data})
# => {"data": result_data, "success": true}
```

`MCPToolkitSuccess.ok()` guarantees the `"success": true` key is present,
symmetric with `MCPToolkitError.fail()` for errors.

**Error response** (use `MCPToolkitError.fail()`):

```gdscript
return MCPToolkitError.fail("NOT_FOUND", "Node not found",
	"Use scene.get_tree to list valid node paths.")
# Returns: {"success": false, "error": "Node not found", "code": "NOT_FOUND", "hint": "..."}
```

**Response validation enforcement:**

The framework validates all handler returns in `call_command()` before
sending them to the MCP client:

- **Non-Dictionary return** → `push_error` logged, INTERNAL error returned
  to client
- **Dictionary without `success` key** → `push_error` logged, INTERNAL
  error returned to client

Use `MCPToolkitSuccess.ok()` for success responses and
`MCPToolkitError.fail()` for error responses — both guarantee the correct
shape.

**Partial results:** For tools that process multiple items where some
succeed and others fail, use `MCPToolkitSuccess.ok()` with descriptive
payload fields:

```gdscript
return MCPToolkitSuccess.ok({
	"files_removed": 8,
	"files_failed": 2,
	"errors": ["res://locked.cfg: permission denied", "res://other.cfg: in use"]
})
```

Optionally add `"status": "partial"` for machine-readable disambiguation.

### MCPToolkitError — structured error API

`MCPToolkitError` is a globally available class (via `class_name`) that
provides the canonical error contract. Use it for all error responses:

```gdscript
# Structured error with explicit hint:
return MCPToolkitError.fail("NOT_FOUND", "Node not found",
	"Use scene.get_tree to list valid node paths.")

# Auto-hint — TIMEOUT gets its default hint automatically:
return MCPToolkitError.fail("TIMEOUT", "Editor busy")
# → includes hint: "The editor may be busy. Try editor.wait_for_idle before retrying."

# Parameter validation with auto-contextual hints:
var err = MCPToolkitError.require(params, ["node_path", "file_path"])
if err != null:
	return err  # hint auto-attached based on parameter name
```

**Gotcha — type your `Variant` reads; never `:=` from a `Variant`.** GDScript can't infer a
concrete type from a `Variant` source, so `:=` (inferred typing) on one is flagged
`INFERENCE_ON_VARIANT` and, under strict checking (warnings-as-errors — as the toolkit's own
validation runs), fails to compile. This covers a raw parameter (`params["file_path"]`), a
`Variant`-returning call like `MCPToolkitError.require()` (see the return-type table above), and an
element of an untyped `Array`. Type the local explicitly instead —
`var name: String = params["name"]`, `var missing: Variant = MCPToolkitError.require(params, [...])`
— or use a plain untyped `var err = …` as in the example above.
`var missing := MCPToolkitError.require(…)` is the classic first-compile stumble when hand-authoring
an extension.

**C# usage** (via registry factories — C# cannot call GDScript statics):

```csharp
// Structured error:
var err = _registry.Call("fail", "NOT_FOUND", "Node missing",
	"Use scene.get_tree to find valid paths").AsGodotDictionary();

// Parameter validation:
var reqErr = _registry.Call("require", parameters,
	new Godot.Collections.Array { "node_path" });
if (reqErr.Obj != null) return reqErr.AsGodotDictionary();
```

**Available constants:**

| Constant | Description |
|----------|-------------|
| `MCPToolkitError.CODES` | All 40 canonical error codes |
| `MCPToolkitError.DEFAULT_HINTS` | 8 error codes with auto-attached recovery hints |
| `MCPToolkitError.HINT_NODE_PATH` | Standard hint for node_path parameters |
| `MCPToolkitError.HINT_FILE_PATH` | Standard hint for file_path parameters |
| `MCPToolkitError.HINT_CLASS_NAME` | Standard hint for class_name parameters |

### Response hints

Hints are short guidance strings that help the LLM decide what to do next
after a tool call. They appear in the MCP response alongside the result
data.

**Static hints (recommended):** Set at registration time. The framework
injects the hint automatically into successful responses:

```gdscript
registry.add("physics.simulate", _simulate,
	MCPToolkitExtensionOptions.new("Run physics simulation step")
		.with_success_hint("Call physics.get_results to see the simulation output."))
```

When `_simulate` returns `MCPToolkitSuccess.ok({...})`, the framework adds
`"hint": "Call physics.get_results to see the simulation output."` to the
response — no handler code needed.

**Dynamic hints:** When the hint depends on the result, set it in the
handler. Handler-set hints take precedence over the registered default:

```gdscript
func _simulate(params: Dictionary) -> Dictionary:
	var result = _run_simulation(params)
	if result.collisions > 0:
		return MCPToolkitSuccess.ok({"data": result,
			"hint": "%d collisions detected. Call physics.get_collisions for details." % result.collisions})
	return MCPToolkitSuccess.ok({"data": result})
	# ↑ Falls back to the registered with_success_hint() text
```

**C# — static hint:**

```csharp
var opts = registry.Call("create_extension_options",
	"Run physics simulation step").AsGodotObject();
opts.Call("with_success_hint",
	"Call physics.get_results to see the simulation output.");
```

**When to use hints:**
- Guide the LLM to a logical next tool call
- Suggest how to interpret the result
- Point to related tools or workflows

**When NOT to use hints:**
- Don't repeat information already in the result data
- Don't use hints for error recovery — `MCPToolkitError.fail()` has its own
  hint parameter for that
- Don't add hints to every tool — only where the next step isn't obvious

### Loading behavior

Extensions always load — the toolkit registers them unconditionally at startup
(and on hot-reload). Whether an extension tool is eager or on-demand for the
LLM is decided by its group, exactly like a built-in (see *Tool groups*), and
read-only mode filters extension tools by the same annotation rules. Extensions
run with the same trust level as the plugin itself (FileGuard, audit logging
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

### Getting listed in the extension catalog

The toolkit's dock offers a discoverable **extension catalog** — a
maintainer-curated list the toolkit fetches so users can find and install
community extensions. A catalog entry lives in that curated list, **not** in
your extension's own code: there is no author-supplied catalog metadata beyond
your tool's `with_group(...)` — the catalog reads only the curated entry.

To get your extension listed, a maintainer needs these fields:

- **Name** — the name shown in the catalog
- **Description** — a one-line summary
- **Repository URL** — must start with `https://`
- **Minimum toolkit version** (optional) — the earliest `godot-mcp-toolkit`
  your extension supports
- **Maximum toolkit version** (optional)
- **Minimum Godot version** (optional)
- **Maximum Godot version** (optional)

**How to get listed:** file a **Catalog Listing Request** issue on the toolkit
repository (use the `catalog_listing_request` issue template). This is a
**request for inclusion**, not a bug report.

**If an existing catalog entry is wrong or broken** (bad URL, incorrect version
range), report it through the normal **Bug Report** (`bug_report.md`) template
instead.

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

> **Godot 4.2 only — editing an existing extension needs an editor restart.** On
> Godot 4.2, re-loading a freshly-edited `@tool` script fresh while the editor is
> still reimporting it natively crashes the editor (a `CACHE_MODE_IGNORE`
> reimport reentrancy — see `COMPATIBILITY.md`). To stay crash-safe, the 4.2
> loader reads through the editor cache, so an in-session **edit** to an existing
> extension is **not** applied until you restart the editor. `extensions_refresh`
> returns a `hint` naming the changed extension, and a `push_warning` appears in
> the editor's Output panel. **Adding** and **removing** extensions still apply
> live on 4.2. Godot 4.3+ applies all changes (add / edit / remove) live.

**Editor focus required:** Godot's `EditorFileSystem` only scans for external
file changes when the editor window regains focus. If you create or modify
extension files from an external tool (terminal, Claude Code, etc.), you must
alt-tab back to the Godot editor to trigger the hot-reload. Files changed
from within Godot's script editor are detected immediately.

**Programmatic refresh:** As an alternative to editor focus, call the
`extensions_refresh` MCP command to force a filesystem scan and immediate
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

## Exporting games with extensions

When you export your game, the MCP Toolkit must not ship in the build. The addon
registers an export plugin that handles this automatically.

**GDScript extensions — automatic (text export mode).** At export time the
plugin removes `.gd` extension files (direct subclasses of
`MCPToolkitExtension`, wherever they live), the entire
`addons/godot_mcp_toolkit/` folder, and `res://.mcp.json`.

**Binary-token script export (Godot 4.3+ default) — scripts ship as inert
`.gdc`, and the plugin warns.** Godot's default Script Export Mode is "Binary
tokens (compressed)". In any binary-token mode the engine compiles each `.gd` to
`.gdc` **before** the addon's strip can run, so addon and extension **scripts
ship** in the build as compiled `.gdc`. They are orphaned and never executed (the
loader that references them is editor-only, and GDScript loads lazily), so there
is **no runtime effect** — they are dead weight only. Non-script files and
`.mcp.json` are stripped in every mode.

At the end of such an export the plugin emits a **warning** — in the export
dialog on Godot 4.4+, or the Output log on 4.3 — naming the addon and any leaked
extensions, because there is no safe way for a GDScript addon to remove an
already-compiled `.gdc` (the engine's export-preset exclude-filter setter is not
scriptable — a long-standing engine limitation, godotengine/godot#4054). **For a
fully clean build, either:**
- set the preset's **Script Export Mode to "Text"** — the plugin then strips all
  addon and extension scripts, or
- add `res://addons/godot_mcp_toolkit/*` **and each extension `.gd` path** to the
  preset's **Resources → exclude filter**.

**Godot 4.2** has no binary-token mode — scripts always ship as text there, so the
plugin strips them and **no warning is shown**. Caveat: if you manually exclude a
*single* extension via the filter (but not the whole addon), that extension may
still be named by the warning — it is excluded correctly; the mention is cosmetic.

**C# extensions — NOT auto-stripped, author action required.** C# compiles into
a .NET assembly (DLL); individual classes cannot be removed from it at export.
The class will be present in the shipped DLL, but the loader that calls
`Register()` is stripped, so it is never instantiated. To be safe, guard any
editor-only work so it cannot run in a build:

```csharp
public void Register(GodotObject registry, Node server)
{
	if (!Engine.IsEditorHint()) return; // defence-in-depth
	// ...
}
```

You may also exclude the extension `.cs` from release builds via a `.csproj`
condition (`<Compile Remove="..." Condition="..." />`).

**If the addon is disabled** (but still on disk) when you export, the export
plugin does not run, so addon files, extensions, and `.mcp.json` all ship — but
they are inert: all addon code is editor-only (`@tool`), the runtime server
refuses to start in any exported build (it self-gates on the editor feature, so
debug exports are covered too), and `Register()` is never called.
Re-enable the addon (or delete the addon folder) before exporting to keep your
build clean.

**Note on `.mcp.json`:** most projects never export it (Godot skips it unless you
add a `*.json` non-resource export filter), so this strip is defensive; if it
does ship it is an inert config file.

## Known limitations

The extension API covers the full tool lifecycle for the vast majority of
use cases — registration, discovery, execution, error handling, hints,
cancellation, undo/redo, hot-reload. The following gaps exist but are
non-blocking; each has a practical workaround:

| Limitation | Impact | Workaround |
|------------|--------|------------|
| No lifecycle hooks (scene changed, file saved) | Extensions can't auto-trigger on editor events | Set up own signal connections to `EditorInterface` in your `register()` method |
| No persistent configuration API | Extensions store settings ad-hoc | Use `ProjectSettings.set_setting()` for project-level or `ConfigFile` for user-level config |
| No progress/streaming for long operations | Long-running operations can't report intermediate status | Use a polling pattern: register a companion `_status` tool the LLM calls to check progress |
| No inter-extension communication | Extension A can't directly call Extension B's tools | Call `registry.call_command("other_ext.tool", params)` directly (works, but undocumented contract) |
| In-session **edit** of an existing extension not applied (**Godot 4.2 only**) | A `@tool`-script edit isn't reflected until restart — engine reimport-crash avoidance (`CACHE_MODE_REUSE`). Adding/removing extensions still apply live | Restart the editor to load the edit (4.3+ applies edits live); `extensions_refresh` returns a restart `hint` |

Each gap is tracked as a post-1.0 improvement candidate. None prevent an
extension from being built and shipped — they affect convenience, not
capability. The signal-connection and ProjectSettings workarounds are
already used internally by the toolkit itself (hot-reload watcher, plugin
configuration). The polling and cross-tool workarounds are straightforward
patterns that require no special framework support.

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
prevent hooks from escalating privilege beyond their tool's annotation level.

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
