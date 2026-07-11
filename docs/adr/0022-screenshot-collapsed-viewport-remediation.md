# Editor and runtime screenshot: collapsed-viewport remediation

A screenshot that cannot produce a usable frame now distinguishes and acts on the
cause instead of returning a misleading tiny/blank PNG.

Godot clamps every viewport to a hard 2x2 floor (`Size2i new_size = p_size.max(Size2i(2, 2))`,
`viewport.cpp`), and the editor's central viewport is a `SubViewport`
(`get_editor_viewport_2d()` == the scene-root viewport). So when the editor lays
out no 2D/3D canvas — because a non-2D/3D screen (Script / AssetLib / Output) is
the active main screen, or because the window is minimized and composites
nothing — a capture *succeeds* but bottoms out at a ~81-byte 2x2 PNG. This is a
**valid success, not headless** (headless short-circuits with
`HEADLESS_UNSUPPORTED` before any capture, so any returned PNG rules headless
out) and not a tool bug — but a blank frame is worthless, and an earlier reactive
`warning` field still handed one back. The running game's window never collapses
(it is a real OS window, full dims windowed/unfocused/minimized), so only the
minimized case has a runtime analogue.

## Decision

Detect the cause up front and act on it:

- **A wrong editor main screen** (2x2 floor, *not* minimized) is **auto-healed** —
  switch to the 2D/3D main screen (keyed on the target node's type: 3D for a
  `Node3D`, else 2D), re-capture across a bounded frame loop, and disclose via a
  success-side `remediation: ["switched_main_screen"]` field. There is no getter
  for the prior main-screen name (`editor_interface.h`), so the switch is one-way;
  the `remediation` field is the disclosure rather than a fragile restore.
- **Unrecoverable states return first-class error codes** instead of a tiny/blank
  PNG: a minimized editor → `EDITOR_VIEWPORT_UNAVAILABLE`; a minimized game
  window → `RUNTIME_WINDOW_MINIMIZED`. Distinct codes (not one shared code)
  because the two failures carry different retry params, so a 1:1 code→tool→param
  mapping helps a grading agent.
- **Both minimized cases are detected up front** via `DisplayServer.window_get_mode`,
  *before* any `await frame_post_draw` — a suspended-render window never fires
  that signal, so an un-guarded await would hang the handler until the server's
  30 s call timeout (which reads as a dead editor). This replaces a latent hang
  with an immediate, diagnostic signal — net-safer.
- **An opt-in `force_foreground_*` param (default off)** on each tool
  un-minimizes + raises + focuses the window before capturing
  (`window_set_mode(WINDOWED, 0)` only-if-minimized so a maximized window is not
  un-maximized, + `window_move_to_foreground(0)` + `Window.grab_focus()`;
  the 4.6+-deprecated `Window.move_to_foreground()` is deliberately avoided).
  Default-off so an interactive user's window is never yanked and parallel game
  instances don't fight for focus; the terminal-driven agent opts in.
- **The runtime handler returns the last-drawn frame** when a *bounded*
  `frame_post_draw` await lapses on a **non-minimized** (idle, redraw-on-demand)
  window, because a compositing window's last frame is its current state — the
  stale-frame risk only ever applied to the minimized/suspended case, which is
  handled up front. This also fixes a pre-existing hang where an idle
  redraw-on-demand game never fired `frame_post_draw`.

The collapse decision is extracted into a pure, headless-unit-tested
`classify_capture(width, height)` static, so the usable-vs-collapsed judgement is
verifiable without an editor (the reason the original behavior went unverified).
The window-mode read stays at the call site (before any capture/await); the
classifier only decides from dimensions.

## Consequences

- Both screenshot tools are trustworthy for agent use: a capture is either a
  usable frame (optionally with a `remediation` disclosure) or an actionable
  error code with a cause-specific hint — never a silent blank.
- The wire contract gains 2 error codes (`EDITOR_VIEWPORT_UNAVAILABLE`,
  `RUNTIME_WINDOW_MINIMIZED`), 2 params (`force_foreground_editor`,
  `force_foreground_game`), and 1 success field (`remediation: string[]`),
  recorded in `docs/dev/contract.md` C3/C4/C8. The new codes are additive (no
  existing code repurposed), and the `force_foreground_*` levers are default-off,
  so interactive and parallel runs are behaviorally unchanged.
- The `remediation` field must be carried through the server's screenshot mapper
  (`buildScreenshotResult`), the one non-REFLECT success path — it would
  otherwise be dropped by the image+text re-shape.
- The DisplayServer / EditorInterface APIs relied on
  (`set_main_screen_editor`, `window_get_mode` / `window_set_mode` /
  `WINDOW_MODE_MINIMIZED` / `window_move_to_foreground`, `Window.grab_focus`,
  `RenderingServer.frame_post_draw`) all exist on the 4.2 floor through 4.7,
  source-verified on the 4.2 and 4.7 worktrees.

## Amendment — embedded playtests and the runtime path

The original premise above ("the running game's window never collapses — it is a
real OS window") does not hold for an **embedded** playtest. Since Godot 4.4 the
editor's Game view runs the game embedded (default on desktop: Windows and X11 in
4.4, macOS added in 4.5); an embedded game is an **owner-linked top-level popup
that the engine hard-gates to WINDOWED mode** and whose z-order the editor
re-asserts every frame. Two consequences for the runtime screenshot:

- **`window_get_mode(0)` never reports `WINDOW_MODE_MINIMIZED` for an embedded
  game** — minimizing the *editor* hides the owned popup without setting its
  minimize flag. So the up-front mode-based short-circuit and the
  `force_foreground_game` lever were both structurally blind to the embedded case.
  The lever is additionally **inert** there: `window_set_mode` rejects any
  non-WINDOWED mode when embedded, and `window_move_to_foreground` can't win
  against the editor's per-frame z-order control.
- **The runtime handler is now capability-based, not mode-based.** It attempts a
  bounded `frame_post_draw` capture first and returns the fresh frame whenever the
  window still composites (the embedded case — it keeps rendering into the Game
  dock even while the editor is minimized). It signals `RUNTIME_WINDOW_MINIMIZED`
  only when the bounded await lapses **and** `DisplayServer.window_can_draw(0)` is
  false — the genuine render-suspended case (a top-level game minimized, or fully
  occluded on macOS, which suspends on occlusion rather than minimize-mode).
  `window_can_draw` is preferred over `window_get_mode == MINIMIZED` because it is
  the occlusion-aware superset. `RUNTIME_WINDOW_MINIMIZED` stays emittable
  (top-level minimized / macOS-occluded), so **the wire contract is unchanged** —
  this is a behavioral correction, not a code repurpose.
- **`force_foreground_game` now honors the request regardless of the mode read,
  but discloses truthfully.** Embedding is detected with
  `Engine.is_embedded_in_editor()` (4.4+; `Engine.has_method`-guarded, since the
  method and the embed feature landed together in 4.4 and embedding is impossible
  on 4.2/4.3). Embedded → the lever can't work, so it emits **no**
  `foregrounded_game` remediation and instead returns a `hint` explaining the game
  is already composited in the Game dock. Top-level → it does the real
  un-minimize + foreground and claims `foregrounded_game` for both an un-minimize
  and a raise-from-background. (`Window.is_embedded()` is a false friend — it means
  subwindow-embedded-within-a-Viewport, not game-embedded-in-editor — and is not
  used.)

## Amendment — image_response_mode and the disk-persist lean response

Both capture tools now take an optional **`image_response_mode: "inline" | "disk"
| "both"`** (default `"inline"`) that selects how the PNG comes back:

- **inline** (default) embeds the base64 PNG in the response, byte-identical to the
  prior shape (`{image_base64, mime_type, width, height, bytes}`).
- **disk** persists the PNG and returns only a **lean envelope** — `{path, width,
  height, bytes, mime_type}`, no `image_base64` — where `path` is the globalized
  absolute file path. This is the escape hatch for a capture too large for the
  WebSocket buffer (a full-size 3D viewport routinely exceeds it) and for conserving
  the agent's context tokens.
- **both** returns the inline shape plus `path`.

An optional **`save_path`** (`.png`) names the destination; when omitted, disk/both
auto-name under `user://screenshots/`. The save-path allowlist differs by context:
`editor.screenshot` accepts `res://` or `user://screenshots/`; `runtime.screenshot`
(which also gains `save_path`) accepts `user://screenshots/` only, because the game
process has no `res://` write surface. A `save_path` supplied in **inline** mode is
validated but **not** persisted, so the guard is deterministic across modes and the
response stays byte-identical.

Design points:

- **No auto-fallback to disk on oversize.** An over-buffer inline capture returns
  `RESPONSE_TOO_LARGE` (C4) with a **tailored** hint that names
  `image_response_mode:"disk"` as the fix (alongside a smaller size, or raising
  `mcp_toolkit/limits/ws_buffer_kb`). The caller chooses the mode; the tool never
  silently changes what it returns. There is no `allow_large` / `max_bytes` bypass —
  the buffer ceiling stays a hard, disclosed limit.
- **Shaping lives in a runtime-safe helper.** `contract/screenshot_response.gd`
  (`RefCounted`, no `class_name`, preloads only `security/file_guard.gd`) owns the
  mode parse, save-path validation via `FileGuard`, the persist, and the inline /
  disk / both shaping. Both editor handlers reach it via the `Modules` aggregator;
  the runtime autoload preloads it directly. It names **no** `Editor*` symbol, so it
  stays in the runtime autoload's export-clean static graph (`godotengine/godot#91713`).

## Known limitations

- **The `force_foreground_*` levers un-minimize to a *windowed* state, not a prior
  maximized one.** Restoring the exact pre-minimize window mode after un-minimizing
  is **not fixable via the public API** (source-verified 4.5 + 4.7): there is no
  getter for a "was maximized before minimize" flag, `window_set_mode(WINDOWED)`
  maps to `SW_NORMAL` + `maximized=false` (it un-maximizes), and no `SW_RESTORE`
  equivalent is exposed. This holds for **both** the editor (`force_foreground_editor`)
  and the top-level game (`force_foreground_game`) paths. By design there is **no
  agent-facing hint** about it — a foregrounded capture succeeds; the window simply
  lands windowed. Documented so a future reader does not treat it as a bug or try to
  "fix" the mode restore.
- **Node-focus does not reframe a 2D node.** `editor_screenshot node_path:<node>`
  **selects** the target node but cannot pan/zoom the 2D viewport camera around it —
  it captures the current 2D view, so a node away from the view origin renders
  off-centre or out of frame. A **3D** node-focused capture gets the engine's
  internal camera framing; **2D has no equivalent public reframe**. Framing a
  specific 2D node is out of reach of the public editor API today.
