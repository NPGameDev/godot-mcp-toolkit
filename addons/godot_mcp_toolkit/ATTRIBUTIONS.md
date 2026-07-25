# Attributions (godot-mcp-toolkit)

This addon's GDScript source was independently written. No code from any
reference repository has been copied verbatim or near-verbatim into this addon.
The entries below cover the original artwork made for this project and the
architectural patterns we studied while designing the plugin.

If a future version imports or adapts code from any of the sources below, a
"Copied into: …" line with the file path(s) will be appended to keep this file
accurate.

---

## Artwork

The project logo and hero banner were created by **Jessica Mariana Aisen** for the
Godot MCP Toolkit.

Commissioned for this project; the copyright is held by NPGameDev.

The MIT licence covers the source code. It does not cover the project logo,
icons, banner or name, which are the project's brand identity and are not
licensed for reuse.

---

## Coding-Solo/godot-mcp

Source: <https://github.com/Coding-Solo/godot-mcp>
License: MIT

Copyright (c) 2025 Solomon Elias

Contributed (architecture reference only — no code copied): bundled-GDScript
handler pattern (the editor plugin loads and runs a registry of command
handlers), cross-platform Godot auto-detection approach, debug output capture
strategy.

---

## tugcantopaloglu/godot-mcp

Source: <https://github.com/tugcantopaloglu/godot-mcp>
License: MIT

Copyright (c) 2025 Tugcan Topaloglu
Copyright (c) 2025 Solomon Elias

Contributed (architecture reference only — no code copied): code-execution
pattern (arbitrary GDScript execution with return values and `await` support),
signal management system concepts (connect/disconnect/emit/await with timeout),
generic node property inspection via `get_property_list()`, reentrancy-guard
pattern for concurrent command prevention.

---

## salvo10f/godotiq

Source: <https://github.com/salvo10f/godotiq>
License: MIT

Copyright (c) 2026 GodotIQ

Contributed (architecture reference only — no code copied): three-tier scene
parser architecture (raw → resolved → indexed), spatial intelligence tool
concepts (`scene_map`, placement, spatial audit), token-optimisation approach
(brief / normal / full detail levels), `EngineDebugger` IPC pattern for
runtime access, **the UndoRedo + `add_undo_reference` pattern for editor-safe
node deletion** (our scene-delete handler standardises on the same pattern —
the code itself was independently written).

---

## youichi-uda/godot-mcp-pro (GDScript plugin only)

Source: <https://github.com/youichi-uda/godot-mcp-pro> — `addons/godot_mcp/`
only.
License: MIT (plugin component); the TypeScript server component is separately
licensed and is NOT referenced or reproduced here.

Copyright (c) 2026 Youichi Uda (y1uda)

Contributed (architecture reference only — no code copied): WebSocket bridge
architecture (Godot editor plugin ↔ external Node.js process), JSON-RPC 2.0
over WebSocket protocol design, UndoRedo integration approach (see
salvo10f/godotiq entry — both projects converge on the same pattern), port
`6505` as the standard MCP port for this style of plugin, **returning screenshot
bytes inline via base64 + mime_type** (our screenshot handler standardises on
the same shape — independently written).

---

## ee0pdt/Godot-MCP

Source: <https://github.com/ee0pdt/Godot-MCP>
License: MIT

Copyright (c) 2025 (author unnamed in LICENSE)

Contributed (architecture reference only — no code copied): structural reference
for the two-layer plugin + external-server architecture.

---

## tomyud1/godot-mcp

Source: <https://github.com/tomyud1/godot-mcp>
License: MIT

Copyright (c) 2025-2026 Tomer Yud

Contributed (architecture reference only — no code copied): reference
implementation for MCP server + Godot plugin integration.

---

## rayxuln/hastur-operation-plugin

Source: <https://github.com/rayxuln/hastur-operation-plugin>
License: MIT

Copyright (c) 2026 Raiix

Contributed (architecture reference only — no code copied): GDScript snippet
execution pattern (wrap user code in `@tool extends RefCounted`, call
`execute(context)`), broker-relay architecture reference.

---

## AndreaTerenz/WebSocket

Source: <https://github.com/AndreaTerenz/WebSocket>
License: MIT

Copyright (c) 2023 Andrea Terenziani

Contributed (architecture reference only — no code copied): Godot 4
`WebSocketPeer` wrapper patterns.

---

## Notes

MIT only requires preserving notices for code that is directly copied or
substantially reproduced. No code from the repositories listed above was
copied into this addon — those entries document the architectural study we
credit by courtesy.

The companion npm package (`@npgamedev/godot-mcp-server`) carries its own
`ATTRIBUTIONS.md` with the subset of references relevant to the bridge /
Node.js side.
