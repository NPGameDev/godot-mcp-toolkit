# `input_simulate` event reference

`input_simulate` injects input into the **running game** (requires `game_start`).

## Event shape

Each event is `{event_type, event_data?, delay_before_ms?, delay_after_ms?}`.
Pass a single event object, or an `events` array for a sequence — **prefer one
call with multiple events** over separate calls. `summary: true` (the default)
returns compact per-event output.

## Event types

| `event_type` | Key `event_data` fields | Notes |
|--------------|-------------------------|-------|
| `key` | `keycode`, `pressed` | Godot key constants (e.g. `KEY_SPACE`) |
| `mouse_button` | `button_index`, `position`, `pressed` | `button_index`: 1 = left, 2 = right |
| `mouse_motion` | `position`, `relative` | For drag / hover |
| `action` | `action`, `pressed` | Matches an Input Map action name |
| `click` | `position` (or `world_position`) | Composite: press + 50 ms + release at the position via `push_input` (GUI-safe; no OS mouse warp or window focus) |
| `click_node` | `node_path` | Calls `grab_focus` + emits `pressed` on `BaseButton`s — no coordinate guessing |
| `send_text` | `text` (required), `node_path?`, `submit?` | Types a string by synthesizing per-character key events, firing the real `text_changed` / `text_submitted` signals that setting `.text` skips |

## Coordinate modes (mouse events)

- `position: {x, y}` — raw viewport / screen coordinates (default). Use for UI
  elements (buttons, menus).
- `world_position: {x, y}` — game-world coordinates, auto-translated via the
  canvas transform (accounts for camera offset and zoom). Use for clicking a
  specific in-game location.

## `send_text` return fields

`send_text` returns `focus_target`, `focus_source`, `text_changed`,
`text_after` (secret/password fields redacted), `chars_sent`, and a `hint`
(which steers you to pass `node_path` when nothing is focused).

## Timing warning

`delay_after_ms` waits after each event. Keep it to **100–300 ms**. Values
**> 500 ms** are dangerous: the live game world keeps advancing during the wait
— enemies move, timers tick, damage accumulates — so a long delay can change
the state you were about to assert on.

## Focus and routing

Mouse events route through `push_input` with `position` + `global_position` set
— sufficient for viewport / `CanvasLayer` / GUI hit-testing with **no OS-level
window focus or mouse warp**, so parallel sessions driving multiple game
instances never fight over the OS mouse. Window foregrounding is a separate,
explicit opt-in (`force_foreground_game`) — input synthesis never needs it.
Every event returns per-event diagnostics for debugging what landed.
