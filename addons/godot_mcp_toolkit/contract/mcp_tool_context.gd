@tool
class_name MCPToolkitToolContext
extends RefCounted
## Per-invocation context for cancellable extension tool handlers.
##
## When a command is registered with
## [method MCPToolkitCommandOptions.mark_cancellable], the dispatcher passes an
## instance of this class as the handler's second argument. The handler observes
## cancellation cooperatively in one of two ways: reactively, by connecting to
## [signal cancelled] to abort a long-running operation; or by polling
## [method is_cancelled] between discrete steps. The dispatcher owns this object —
## do not store it beyond the handler's return, as it is scoped to a single tool
## invocation.

## Emitted once when the invocation is cancelled, for handlers that want to react
## immediately rather than poll [method is_cancelled].
signal cancelled

var _cancelled := false


## Requests cancellation: flips the cancelled state and emits [signal cancelled]
## (idempotent — a second call is ignored). [b]Called by the dispatch system[/b],
## not by extension handlers; a handler observes cancellation through
## [method is_cancelled] or [signal cancelled] instead of calling this.
func cancel() -> void:
	if _cancelled:
		return
	_cancelled = true
	cancelled.emit()


## Returns [code]true[/code] once the invocation has been cancelled. Poll it
## between steps of a long operation and return early when it is set.
## [codeblock]
## func _on_long_tool(parameters, ctx):
##     for item in big_list:
##         if ctx.is_cancelled():
##             return MCPToolkitError.fail("FAILED", "cancelled")
##         _process(item)
##     return MCPToolkitSuccess.ok()
## [/codeblock]
func is_cancelled() -> bool:
	return _cancelled
