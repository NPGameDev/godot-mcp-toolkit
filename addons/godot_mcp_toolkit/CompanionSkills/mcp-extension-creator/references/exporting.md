# Exporting your game (extension scripts in builds)

When a user exports their game, the toolkit's export plugin strips the addon,
your GDScript extension's `.gd` (a direct subclass of `MCPToolkitExtension`), and
`res://.mcp.json` in every Script Export Mode: Text, and both binary-token modes,
including the Godot 4.3+ default.

## Why binary tokens are covered

Godot offers each exported file to its export plugins in name order and stops at
the first one that skips or remaps it. The strip's name sorts before the built-in
GDScript plugin, so it removes your `.gd` before that plugin can compile it to
`.gdc`.

## If the export warns

The toolkit warns at export time when your script never reached the strip, and
names the affected paths. Unless the preset already excludes it, another export
plugin that sorts earlier and skips or remaps `.gd` files (an obfuscator, for
example) consumed it first, and it may ship, as `.gdc` if that plugin compiles
scripts. Add your extension's `.gd` path to the preset's **Resources → exclude
filter** to remove it.

## C#

C# extensions compile into the project's .NET assembly and cannot be stripped
per-class. Guard editor-only work with `if (!Engine.IsEditorHint()) return;` so
nothing runs in a build.
