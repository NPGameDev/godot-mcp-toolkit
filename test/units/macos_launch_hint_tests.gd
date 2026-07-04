@tool
extends RefCounted
## Unit tests for the pure macOS launch-hint predicate
## (MacosLaunchHint.should_show): the Q4 all-AND gate — macOS ∧ listening ∧ a valid
## .mcp.json exists ∧ no peer ever connected this session ∧ grace elapsed ∧ not
## already shown — so any single false keeps the dock silent (the anti-nag
## property), plus that the message carries the launchd cause + recovery actions.

const MacosLaunchHint := preload("res://addons/godot_mcp_toolkit/ui/dock/status/macos_launch_hint.gd")


static func run(testing) -> void:
	_test_all_conditions_show(testing)
	_test_each_missing_condition_silent(testing)
	_test_message_carries_cause_and_actions(testing)


# All six conditions met → show the hint.
static func _test_all_conditions_show(testing) -> void:
	testing.begin("MacosLaunchHint — all conditions met shows the hint")
	testing.ok(
		MacosLaunchHint.should_show("macOS", true, true, false, true, false),
		"macOS + listening + valid json + never-connected + grace + not-shown → show")
	print("")


# Flipping any single gate off → silent. Baseline is the all-true case above.
static func _test_each_missing_condition_silent(testing) -> void:
	testing.begin("MacosLaunchHint — any single failing gate stays silent")
	testing.ok(
		not MacosLaunchHint.should_show("Windows", true, true, false, true, false),
		"non-macOS (Windows) → silent")
	testing.ok(
		not MacosLaunchHint.should_show("Linux", true, true, false, true, false),
		"non-macOS (Linux) → silent")
	testing.ok(
		not MacosLaunchHint.should_show("macOS", false, true, false, true, false),
		"not listening → silent")
	testing.ok(
		not MacosLaunchHint.should_show("macOS", true, false, false, true, false),
		"no valid .mcp.json (client not configured) → silent (anti-nag)")
	testing.ok(
		not MacosLaunchHint.should_show("macOS", true, true, true, true, false),
		"a peer connected this session → silent (covers connected-then-dropped)")
	testing.ok(
		not MacosLaunchHint.should_show("macOS", true, true, false, false, false),
		"grace not elapsed → silent")
	testing.ok(
		not MacosLaunchHint.should_show("macOS", true, true, false, true, true),
		"already shown → silent (one-shot)")
	print("")


# The hint text names the PATH cause and the recovery actions (write + terminal).
static func _test_message_carries_cause_and_actions(testing) -> void:
	testing.begin("MacosLaunchHint — message carries cause + actions")
	var msg := MacosLaunchHint.message()
	testing.ok(msg.contains("PATH"), "names the PATH cause")
	testing.ok(msg.to_lower().contains("write"), "action: write .mcp.json")
	testing.ok(msg.to_lower().contains("terminal"), "action: launch from a terminal")
	print("")
