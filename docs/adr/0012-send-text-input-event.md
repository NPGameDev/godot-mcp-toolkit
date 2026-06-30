---
status: accepted
---

# 0012 — send_text input event (push_input + unicode-only)

## Context

`input_simulate` could click and press keys but had no first-class way to fill a text field. The
available workaround — `node_set_property` on `.text` — is lossy: assigning `LineEdit.text`
inserts the characters but never fires `text_changed` (that signal originates in `gui_input`, not in
`insert_text_at_caret`), and `text_submitted` is unreachable. The automated test flows that
surfaced this gap care precisely about those signals, so a fill that skips them is not equivalent to
a user typing.

The route a maintainer would naively reuse is also a trap. The existing `key` and `action` paths
feed events through `Input.parse_input_event`, which drives the `Input` singleton so
`is_key_pressed()` / `is_action_pressed()` polling tests observe them. But the `Input` singleton is
**not** the path GUI text controls read — they consume `gui_input` delivered by the viewport to the
focus owner. Sending typed characters through `parse_input_event` would therefore poll-register the
keys yet still skip the text-entry signals. The two transports are not interchangeable.

## Decision

`send_text` synthesizes one press+release `InputEventKey` per **codepoint** of the string (walked
with `String.unicode_at`, so a UTF-32 string yields non-ASCII codepoints directly) and delivers each
through `Viewport.push_input()`, which routes a key event to the GUI focus owner. The real
`gui_input` runs, so `text_changed` (and, on submit, `text_submitted`) fire exactly as for a human.
Focus is taken from an optional `event_data.node_path` (a `Control`, resolved against `/root` and
given `grab_focus()`) or the current focus owner; a custom `_input` reader receives the events
regardless.

Typed characters are **unicode-only** — the synthesized events carry `unicode` but no `keycode`. A
keycode would risk matching a keycode-based shortcut handler while typing. The single exception is
the optional `submit` Enter, which **must** carry `keycode = KEY_ENTER`: the built-in
`ui_text_submit` / `ui_text_newline` actions match on keycode, not unicode, so a unicode-only Enter
would neither submit a `LineEdit` nor insert a newline in a multiline `TextEdit`.

The existing `key` path is left on `Input.parse_input_event`, unchanged — it serves the polling-test
contract that `send_text` deliberately does not. No version gate is added: every API used
(`push_input`, `gui_get_focus_owner`, `InputEventKey.unicode` / `.keycode`, `String.unicode_at`,
`Control.grab_focus`, `LineEdit.secret`) is present on all supported versions (4.2–4.7), and four of
them are already exercised by the shipped runtime autoload.

## Consequences

- Any unicode reader is covered: the built-in text controls plus any node with a custom
  `_input` / `_gui_input` that reads `event.unicode`.
- The result is self-verifiable: `focus_target`, `focus_source`, `text_changed`, `text_after`,
  `chars_sent`, and an actionable `hint`. `text_changed` is null when the target exposes no readable
  `text` property (a custom reader), which is a normal outcome, not an error.
- A `LineEdit` with `secret = true` has its `text_after` replaced by a length-only marker, so the
  secret value never reaches the response. `text_changed` is still computed from the real value, so
  redaction never hides whether the typing landed.
- A paused scene tree silently drops `gui_input` (the `can_process()` gate). This is surfaced rather
  than hidden: when the editable target's text did not change, the hint notes the paused tree.

## Considered and rejected

- **`insert_text_at_caret()` directly** — works only on the built-in controls and still skips
  `text_changed`, so it reproduces the workaround's core defect under a different name.
- **`node_set_property(.text)`** — today's lossy workaround; the very gap this event closes.
- **Per-character keycode derivation** — would require a character→keycode map and reintroduce the
  shortcut-trip risk that unicode-only avoids, for no fidelity gain over `unicode`.
