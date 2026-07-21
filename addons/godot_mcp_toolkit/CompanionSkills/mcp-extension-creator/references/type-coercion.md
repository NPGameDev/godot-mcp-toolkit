# Type coercion for complex parameters

When the MCP client sends JSON, Godot receives it as basic types (numbers,
strings, booleans, dictionaries, arrays). Coerce them to engine types inside the
handler as needed.

```gdscript
# Vector2 from {"x": 10, "y": 20}
var pos := Vector2(params.get("x", 0.0), params.get("y", 0.0))

# Vector3 from {"x": 1, "y": 2, "z": 3}
var v := Vector3(params.get("x", 0.0), params.get("y", 0.0), params.get("z", 0.0))

# Color from {"r": 1.0, "g": 0.5, "b": 0.0, "a": 1.0}
var color := Color(params.get("r", 0.0), params.get("g", 0.0),
    params.get("b", 0.0), params.get("a", 1.0))

# Resource path → loaded resource
var res := ResourceLoader.load(params.get("path", ""))
if res == null:
    return MCPToolkitError.fail("NOT_FOUND", "Resource not found")
```

The same pattern extends to any engine type — read the plain fields off `params`
and construct the type. Validate ranges and existence (a loaded resource,
a resolvable node) before using the value.
