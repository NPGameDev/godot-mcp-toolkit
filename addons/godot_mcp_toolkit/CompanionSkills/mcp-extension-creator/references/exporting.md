# Exporting your game (extension scripts in builds)

When a user exports their game, the toolkit's export plugin strips the addon,
your extension's **non-script** files, and `res://.mcp.json` in every mode, and
strips extension **scripts** too when Script Export Mode is **Text**.

## The binary-token caveat (Godot 4.3+)

In a **binary-token** script mode (the Godot 4.3+ default) the engine compiles
each `.gd` to `.gdc` before the strip can run, so your extension `.gd` ships as
an inert, orphaned `.gdc` — never loaded at runtime, no effect on the game. The
plugin warns at export time and names the leaked extensions.

This is a long-standing engine limitation (godotengine/godot#4054), not specific
to your extension. Godot 4.2 has no binary-token mode, so extension scripts
always strip cleanly there.

## For a clean strip

Either of these removes the orphaned `.gdc`:

- Set **Script Export Mode** to **Text** in the export preset, or
- Add your extension's `.gd` path to the preset's **Resources → exclude filter**.

## C#

C# extensions compile into the project's .NET assembly and cannot be stripped
per-class. Guard editor-only work with `if (!Engine.IsEditorHint()) return;` so
nothing runs in a build.
