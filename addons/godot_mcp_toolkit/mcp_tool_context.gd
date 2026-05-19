@tool
class_name MCPToolContext
extends RefCounted
## Per-invocation context for cancellable extension tool handlers.
##
## Provides cooperative cancellation via:
## - [signal cancelled] — reactive: connect to abort long-running operations
## - [method is_cancelled] — polling: check between discrete steps
##
## Owned by mcp_server.gd dispatch. Do not store this object beyond
## the handler's return — it is scoped to a single tool invocation.

signal cancelled

var _cancelled := false


func cancel() -> void:
	if _cancelled:
		return
	_cancelled = true
	cancelled.emit()


func is_cancelled() -> bool:
	return _cancelled
