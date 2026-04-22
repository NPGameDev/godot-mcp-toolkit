# Extending the MCP Toolkit

## User Commands (supported)

The toolkit supports custom MCP tools via the user commands system. Drop a
`.gd` file into `addons/godot_mcp_toolkit/user_commands/` and implement a
`register(registry, server)` function:

```gdscript
@tool
extends RefCounted

static func register(registry, server: Node) -> void:
    registry.add("mymod.do_thing", func(params: Dictionary) -> Dictionary:
        return _cmd_do_thing(params))

static func _cmd_do_thing(params: Dictionary) -> Dictionary:
    # Your logic here
    return {"success": true, "data": "hello"}
```

### Rules

- Commands must use `<namespace>.<action>` naming (e.g., `mymod.greet`).
- Built-in namespaces (`scene.*`, `script.*`, `editor.*`, `node.*`, etc.)
  are reserved and rejected at load time.
- User commands are **profile-exempt** -- they register regardless of the
  active profile (minimal/standard/Power User/custom).
- User commands inherit the plugin's security context (FileGuard, FeatureGate,
  audit logging).
- Errors in user command scripts are logged but never crash the plugin.
- Restart the editor (or disable/re-enable the plugin) to pick up changes.

The TypeScript bridge auto-discovers user commands via `meta.user_commands`
and registers them as MCP tools. Your MCP client receives a
`tools/list_changed` notification when new user commands are found.

## Third-Party Plugin Integration (not yet supported)

Currently, only scripts inside `addons/godot_mcp_toolkit/user_commands/` can
register MCP tools. A third-party Godot plugin (in its own `addons/` folder)
cannot directly access the command registry.

### What would need to change

To enable cross-addon extensibility, the toolkit would need one of:

1. **Autoload-exposed registry.** Register the command registry as an autoload
   singleton so any script can call `MCPRegistry.add(method, handler)`.
2. **Signal-based registration.** Emit a global signal with the registry
   reference at startup; other plugins connect and register their commands.
3. **Scan external directories.** Extend the user commands loader to scan
   additional directories (e.g., `addons/*/mcp_commands/`).

Option 1 (autoload) is the cleanest path and would require:
- Moving the registry to a standalone autoload script.
- Ensuring add/remove symmetry when third-party plugins are disabled.
- Enforcing namespace reservation to prevent conflicts.

This is tracked as a potential post-1.0 enhancement. For now, the recommended
approach is to place extension files in the `user_commands/` directory.
