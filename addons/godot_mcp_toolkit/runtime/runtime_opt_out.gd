@tool
extends RefCounted
## The runtime opt-out: the environment variable that keeps the runtime server
## inert, and the values that count as off.
##
## The runtime autoload reads it to stay inert, and the editor reads it to explain
## why a game it launched never opened the runtime channel. Being in the
## autoload's preload closure, it uses core APIs only and preloads nothing.

## The opt-out variable. A game the editor launches inherits the editor's
## environment, so the editor names it when its own environment sets it.
const ENV_RUNTIME := "GODOT_MCP_RUNTIME"

const _OFF_VALUES: Array[String] = ["0", "false", "off"]


## Returns true when [param value], the raw [code]GODOT_MCP_RUNTIME[/code]
## environment value, turns the runtime server off: [code]0[/code],
## [code]false[/code] or [code]off[/code], any case, surrounding spaces ignored.
## Empty (unset) and any other value leave it on.
static func is_opted_out(value: String) -> bool:
	return value.strip_edges().to_lower() in _OFF_VALUES
