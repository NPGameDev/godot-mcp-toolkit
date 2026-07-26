# Media manifest

Captions and provenance for every image in this folder. When an image is
replaced, update its row and the provenance comment above each embed that
uses it.

| File | Shows | Provenance |
| --- | --- | --- |
| `hero-banner.png` | The project banner, 1280×640: the toolbox logo beside a "Godot · MCP · Toolkit" wordmark on dark navy. | commissioned brand art by Jessica Mariana Aisen, supplied 2026-07-24. Used as the README hero in both repos and as the GitHub social-preview card. |
| `editor-dock-brick-breaker.png` | The Godot 4.7 editor driving the toolkit: the agent-built brick-breaker scene open in the viewport, the game running in a debug window (full wall of red/orange/yellow/green/blue bricks), and the MCP dock reporting `Listening on 127.0.0.1:6550` with 1 connected peer and the runtime server on 6570. | captured: pre-1.0, Godot 4.7, 2026-07-24; human-recorded UI-chrome shot (editor + dock) with a client peer connected and the game running. |
| `brick-breaker-running.png` | The agent-built brick-breaker running: a full wall of red/orange/yellow/green/blue bricks on a dark background, the ball mid-flight, a paddle at the bottom, and a Score/Lives readout. | captured: pre-1.0, Godot 4.5, 2026-07-24, via `runtime_screenshot` of the running game (ball speed reduced to catch a clean mid-flight frame). |

UI-chrome shots (dock, menus, Info panel) and the demo GIF are recorded by a
human at release preparation — `editor_screenshot` captures the viewport only.
Brand artwork is commissioned rather than captured.

`editor-dock-breakout.png` and `breakout-running.png` are byte-identical
legacy aliases of the two brick-breaker screenshots above: the README inside
the published npm 1.0.0 tarball hotlinks those filenames, and a published
package cannot be edited. Retire them once a later release rolls the npm
README onto the brick-breaker names.
