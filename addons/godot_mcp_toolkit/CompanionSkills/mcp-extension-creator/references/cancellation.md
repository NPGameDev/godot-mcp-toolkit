# Cooperative cancellation

For long-running tools (external API calls, heavy processing), opt into
cooperative cancellation so the handler exits early when the caller cancels.
Most tools do **not** need this — reach for it only when a tool does slow work
that should be able to bail out mid-flight.

## Enabling it

Call `.mark_cancellable()` on the options. This changes the handler contract:
a cancellable handler takes a **second argument**, a `MCPToolkitToolContext`.

```gdscript
var opts := MCPToolkitExtensionOptions.new("Fetch data from an external API") \
    .with_timeout_ms(60000) \
    .mark_cancellable()
registry.add("weather.fetch", _handle_fetch, opts)
```

> If you set `mark_cancellable()` but keep a one-argument handler, the dispatcher's
> two-argument call fails. The two must match.

## Observing cancellation

The context exposes two ways to notice a cancel — use whichever fits the work:

- **Reactive** — connect the `cancelled` signal to abort an in-flight operation.
- **Polling** — call `ctx.is_cancelled()` between discrete steps.

```gdscript
## Fetches weather data, aborting early if the call is cancelled.
##
## Returns a success envelope with the payload, or an empty dict if cancelled
## mid-flight. [param params] carries the request; [param ctx] is the
## per-invocation cancellation context.
func _handle_fetch(params: Dictionary, ctx: MCPToolkitToolContext) -> Dictionary:
    # Reactive: abort the HTTP request the moment cancellation is requested.
    ctx.cancelled.connect(_http_request.cancel_request)

    var result = await _do_fetch(params.get("query", ""))

    # Polling: check between steps and return early.
    if ctx.is_cancelled():
        return {}

    return MCPToolkitSuccess.ok({"data": result})
```

## Rules

- **Do not store the context.** It is scoped to a single invocation — the
  dispatcher owns it, and holding a reference past the handler's return is a bug.
- **Return promptly once cancelled.** A cancelled handler should stop work and
  return; an empty dict or an `MCPToolkitError.fail("FAILED", "cancelled")` are
  both fine — the point is to stop, not to keep computing.

## C#

The context arrives as a second `GodotObject` and is driven by name
(`ctx.Connect("cancelled", …)`, `(bool)ctx.Call("is_cancelled")`). See
`references/csharp-extensions.md`.
