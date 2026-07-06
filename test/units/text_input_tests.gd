@tool
extends RefCounted
## Unit tests for the input_simulate helpers: the send_text synthesis leaf
## (runtime/text_input_synth.gd) — per-codepoint InputEventKey synthesis (incl.
## non-ASCII via String.unicode_at), the submit-Enter keycode pair, text_after
## truncate/redact (secret precedence), the actionable focus/diagnostic hint — plus
## the InputMap.has_action predicate the action-event guard depends on.
## Pure logic — no editor, no viewport.

const TextInputSynth := preload("res://addons/godot_mcp_toolkit/runtime/text_input_synth.gd")


static func run(testing) -> void:
	_test_char_synthesis(testing)
	_test_enter_synthesis(testing)
	_test_text_after_redact_truncate(testing)
	_test_hint_selection(testing)
	_test_action_guard_predicate(testing)


# --- input_simulate action guard: InputMap.has_action predicate ----
# The runtime input_simulate "action" branch rejects an action not registered in
# the InputMap (else it dispatches a silent no-op). The guard is InputMap.has_action;
# pin that predicate — registered → true (guard passes), unknown → false (guard
# rejects) — so the contract the guard relies on is locked headless across versions.
# (The WS handler itself needs a live peer, so this pins its decision, not the send.)
static func _test_action_guard_predicate(testing) -> void:
	testing.begin("input_simulate action guard predicate")

	var probe := &"sv2_unit_probe_action_xyz"
	# Unknown action → false (the guard rejects with INVALID_PARAMS).
	testing.ok(not InputMap.has_action(probe), "unregistered action → has_action false")
	# Registered action → true (the guard lets it dispatch).
	InputMap.add_action(probe)
	testing.ok(InputMap.has_action(probe), "registered action → has_action true")
	# Clean up the global singleton so no other test sees the probe action.
	InputMap.erase_action(probe)
	testing.ok(not InputMap.has_action(probe), "erased action → has_action false again")

	print("")


# --- per-codepoint key synthesis (ASCII + non-ASCII + empty) ----------------
static func _test_char_synthesis(testing) -> void:
	testing.begin("text_input_synth: char synthesis")

	# ASCII "ab" → press a, release a, press b, release b; unicode-only (keycode 0).
	var ascii_events := TextInputSynth.synthesize_text_events("ab")
	testing.eq(ascii_events.size(), 4, "\"ab\" → 4 events (press+release per char)")
	testing.ok(ascii_events[0].unicode == 97 and ascii_events[0].pressed, "[0] press 'a' (unicode 97)")
	testing.ok(ascii_events[1].unicode == 97 and not ascii_events[1].pressed, "[1] release 'a'")
	testing.ok(ascii_events[2].unicode == 98 and ascii_events[2].pressed, "[2] press 'b' (unicode 98)")
	testing.ok(ascii_events[3].unicode == 98 and not ascii_events[3].pressed, "[3] release 'b'")
	testing.eq(ascii_events[0].keycode, 0, "typed char carries no keycode (unicode-only)")

	# Non-ASCII proves the UTF-32 path: each codepoint maps 1:1 (no surrogates).
	# Built from codepoints so the test is independent of source-file encoding.
	var non_ascii := String.chr(233) + String.chr(8364)  # "é" U+00E9 + "€" U+20AC
	testing.eq(non_ascii.length(), 2, "two codepoints (UTF-32 length)")
	var non_ascii_events := TextInputSynth.synthesize_text_events(non_ascii)
	testing.eq(non_ascii_events.size(), 4, "2 codepoints → 4 events")
	testing.eq(non_ascii_events[0].unicode, 233, "[0] 'é' codepoint 233")
	testing.eq(non_ascii_events[2].unicode, 8364, "[2] '€' codepoint 8364")

	# Empty string synthesizes nothing; char_count counts codepoints.
	testing.eq(TextInputSynth.synthesize_text_events("").size(), 0, "\"\" → 0 events")
	testing.eq(TextInputSynth.char_count("abc"), 3, "char_count(\"abc\") == 3")


# --- submit Enter (the one keycode exception) ------------------------------
static func _test_enter_synthesis(testing) -> void:
	testing.begin("text_input_synth: enter synthesis")

	var enter_events := TextInputSynth.synthesize_enter()
	testing.eq(enter_events.size(), 2, "submit → press+release pair")
	testing.ok(enter_events[0].keycode == KEY_ENTER and enter_events[0].pressed, "[0] press KEY_ENTER")
	testing.ok(enter_events[1].keycode == KEY_ENTER and not enter_events[1].pressed, "[1] release KEY_ENTER")


# --- text_after: secret redaction precedes truncation ----------------------
static func _test_text_after_redact_truncate(testing) -> void:
	testing.begin("text_input_synth: text_after redact/truncate")

	# Secret → length only; the typed value never appears in the echo.
	var redacted := TextInputSynth.format_text_after("hunter2", true, 200)
	testing.eq(redacted, "[redacted: 7 chars]", "secret → \"[redacted: 7 chars]\"")
	testing.ok(not redacted.contains("hunter2"), "secret value absent from text_after")

	# Non-secret over cap → first `cap` chars + "...[+N chars]" suffix.
	var long_text := "a".repeat(250)
	var truncated := TextInputSynth.format_text_after(long_text, false, 200)
	testing.ok(truncated.begins_with("a".repeat(200)), "truncated keeps first 200 chars")
	testing.ok(truncated.ends_with("...[+50 chars]"), "truncated suffix reports the remainder")

	# Non-secret under cap → returned verbatim.
	testing.eq(TextInputSynth.format_text_after("short", false, 200), "short", "short value verbatim")


# --- actionable hint selection ---------------------------------------------
static func _test_hint_selection(testing) -> void:
	testing.begin("text_input_synth: hint selection")

	# No focus → steer to node_path; mentions the char count for custom readers.
	var no_focus := TextInputSynth.build_hint("none", null, "", "", 5, false)
	testing.ok(no_focus.contains("node_path"), "no-focus hint steers to node_path")
	testing.ok(no_focus.contains("5"), "no-focus hint names the char count")

	# Editable target unchanged → flags likely causes, names the class, no pause note.
	var unchanged := TextInputSynth.build_hint("existing", false, "/root/Main/X", "Label", 3, false)
	testing.ok(unchanged.contains("didn't change"), "unchanged hint says text didn't change")
	testing.ok(unchanged.contains("Label"), "unchanged hint names the focus class")
	testing.ok(not unchanged.contains("paused"), "unchanged hint omits pause note when running")

	# Same, paused tree → adds the gui_input-skipped pause note.
	var unchanged_paused := TextInputSynth.build_hint("existing", false, "/root/Main/X", "Label", 3, true)
	testing.ok(unchanged_paused.contains("paused"), "paused tree → pause note appended")

	# Clean success (focus obtained, text changed) → no hint.
	testing.eq(TextInputSynth.build_hint("node_path", true, "/root/Main/E", "LineEdit", 3, false), "",
		"clean success → empty hint")
