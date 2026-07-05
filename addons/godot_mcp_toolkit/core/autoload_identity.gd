@tool
extends RefCounted
## Single source of truth for the toolkit's runtime autoload identity — the
## [name, res:// path] pair(s) the plugin must register, plus the pure derivation
## of the ProjectSettings key/value each pair maps to.
##
## A pure-const leaf: it preloads nothing and holds no behavior beyond derivation.
## It exists so the plugin-lifecycle domain (registration + on-load self-heal) and
## the export-strip domain (null-for-bake, restore-after) share one identity without
## coupling to each other — each preloads this leaf, neither preloads the other, so a
## rename or path change lands in exactly one place. No [code]class_name[/code]:
## consumers reach it as [code]const AutoloadIdentity := preload(...)[/code].

## Mode B — the runtime autoload that hosts the game-side WebSocket server. The
## enabled plugin guarantees this autoload is registered; registration is idempotent,
## so a project.godot that already carries the entry keeps its existing value.
const RUNTIME_AUTOLOAD_NAME := "MCPRuntimeServer"
const RUNTIME_AUTOLOAD_PATH := "res://addons/godot_mcp_toolkit/runtime/mcp_runtime_server.gd"

## The autoloads the enabled plugin must guarantee, as [name, res:// path] pairs.
## One entry today (the runtime server); the list shape future-proofs a second.
const REQUIRED_AUTOLOADS := [[RUNTIME_AUTOLOAD_NAME, RUNTIME_AUTOLOAD_PATH]]


## The ProjectSettings key for an autoload — [code]"autoload/<name>"[/code].
## [param autoload_name] is the singleton name (e.g. "MCPRuntimeServer").
static func settings_key(autoload_name: String) -> String:
	return "autoload/" + autoload_name


## The ProjectSettings value for an autoload script — [code]"*<path>"[/code]. The
## leading "*" marks the singleton enabled, matching how the editor writes autoloads.
static func settings_value(script_path: String) -> String:
	return "*" + script_path
