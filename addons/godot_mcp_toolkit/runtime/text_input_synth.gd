@tool
extends RefCounted
## Pure, headless-testable helpers for the input_simulate `send_text` event:
## per-codepoint [InputEventKey] synthesis, the submit-Enter pair, the `text_after`
## truncate/redact, and the focus/diagnostic hint.
##
## Runtime-clean by construction — it names only [InputEventKey], [String], and
## string formatting, never an editor class — so it is safe inside the runtime
## autoload's preload closure. An editor symbol anywhere in that static graph
## parse-fails the autoload in an unstripped export (godotengine/godot#91713), and
## the runtime server preloads this file; keep it editor-free.

## Largest `text_after` length echoed back before truncation kicks in.
const TEXT_AFTER_CAP := 200


## Synthesizes one press+release [InputEventKey] pair per CODEPOINT of [param text],
## with `unicode` set to the codepoint and `keycode` left 0 (unicode-only).
##
## Unicode-only so a typed character drives text entry via the focus owner's
## `gui_input` without also matching a keycode-based shortcut. [param text] is
## walked by codepoint ([method String.unicode_at]); a Godot [String] is UTF-32, so
## each index is a whole codepoint and non-ASCII needs no surrogate handling.
## Returns press, release, press, release… — twice the codepoint count.
static func synthesize_text_events(text: String) -> Array[InputEventKey]:
	var events: Array[InputEventKey] = []
	for i in text.length():
		var codepoint := text.unicode_at(i)
		var press := InputEventKey.new()
		press.unicode = codepoint
		press.pressed = true
		events.append(press)
		var release := InputEventKey.new()
		release.unicode = codepoint
		release.pressed = false
		events.append(release)
	return events


## Synthesizes the press+release [InputEventKey] pair for the optional `submit`
## Enter, keyed on `keycode = KEY_ENTER` (not unicode).
##
## Enter is the one keycode exception: `ui_text_submit` / `ui_text_newline` match
## on KEYCODE, so a unicode-only event would neither fire `text_submitted` on a
## [LineEdit] nor insert a newline in a multiline [TextEdit].
static func synthesize_enter() -> Array[InputEventKey]:
	var press := InputEventKey.new()
	press.keycode = KEY_ENTER
	press.pressed = true
	var release := InputEventKey.new()
	release.keycode = KEY_ENTER
	release.pressed = false
	return [press, release]


## Codepoint count [method synthesize_text_events] will type for [param text] — its
## reported `chars_sent`. A Godot [String] is UTF-32, so this is just its length.
static func char_count(text: String) -> int:
	return text.length()


## Builds the `text_after` result field from the target's real [param raw] text.
##
## Redaction wins over truncation: when [param is_secret] the value is replaced by
## its length alone (a [LineEdit] with `secret = true`), so the secret characters
## never reach the response — yet `text_changed` still computes from the real value
## upstream. A non-secret value longer than [param cap] is truncated with a
## "...[+N chars]" suffix (same form as execute.code's log truncation); otherwise it
## is returned verbatim.
static func format_text_after(raw: String, is_secret: bool, cap: int = TEXT_AFTER_CAP) -> String:
	if is_secret:
		return "[redacted: %d chars]" % raw.length()
	if raw.length() > cap:
		return raw.substr(0, cap) + "...[+%d chars]" % (raw.length() - cap)
	return raw


## Builds the actionable `hint` for a send_text result, or "" on clean success.
##
## [param text_changed] is tri-state (true / false / null); null means the target
## exposes no readable `text` property (a custom `_input` reader), which is not an
## error and gets no hint. A "none" [param focus_source] steers the caller to
## `event_data.node_path`; an unchanged editable target flags the likely causes and,
## when [param tree_paused], notes that a paused tree skips `gui_input`. The
## node_path-unresolved case is hinted inline by the handler (it holds the path).
static func build_hint(focus_source: String, text_changed: Variant, focus_path: String,
		focus_class: String, chars_sent: int, tree_paused: bool) -> String:
	if focus_source == "none":
		return "No Control had focus; pass event_data.node_path to focus the target field before typing. (Custom _input handlers may still have received the %d characters.)" % chars_sent
	if text_changed == false:
		var changed_hint := "Focus was on %s (%s) but its text didn't change — non-editable, at max_length, or not a text field. Verify the target or pass node_path." % [focus_path, focus_class]
		if tree_paused:
			changed_hint += " The scene tree is paused (process_mode), so gui_input was skipped."
		return changed_hint
	return ""
