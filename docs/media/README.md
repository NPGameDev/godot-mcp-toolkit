# Media manifest

Captions and provenance for every image in this folder. When an image is
replaced, update its row and the provenance comment above each embed that
uses it.

| File | Shows | Provenance |
| --- | --- | --- |
| `editor-dock-breakout.png` | The Godot 4.7 editor driving the toolkit: the agent-built brick-breaker scene open in the viewport, the game running in a debug window (full wall of red/orange/yellow/green/blue bricks), and the MCP dock reporting `Listening on 127.0.0.1:6550` with 1 connected peer and the runtime server on 6570. | captured: pre-1.0, Godot 4.7, 2026-07-24; human-recorded UI-chrome shot (editor + dock) with a client peer connected and the game running. |
| `breakout-running.png` | The agent-built brick-breaker running: a full wall of red/orange/yellow/green/blue bricks on a dark background, the ball mid-flight, a paddle at the bottom, and a Score/Lives readout. | captured: pre-1.0, Godot 4.5, 2026-07-24, via `runtime_screenshot` of the running game (ball speed reduced to catch a clean mid-flight frame). |

UI-chrome shots (dock, menus, Info panel) and the demo GIF are recorded by a
human at release preparation — `editor_screenshot` captures the viewport only.
