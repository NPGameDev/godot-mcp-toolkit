@tool
extends RefCounted
## Unit tests for the onboarding wizard's pure macOS-setup step-relevance predicate
## (OnboardingWizard._macos_setup_needs_help): the final wizard step surfaces ONLY
## when the host is macOS AND Node couldn't be resolved from a login shell (empty
## resolved node) — otherwise the wizard skips it and finishes one step earlier.

const OnboardingWizard := preload("res://addons/godot_mcp_toolkit/ui/onboarding_wizard.gd")


static func run(testing) -> void:
	_test_macos_step_relevance(testing)
	_test_effective_step_count(testing)


static func _test_macos_step_relevance(testing) -> void:
	testing.begin("OnboardingWizard — macOS setup step relevance")
	testing.ok(
		OnboardingWizard._macos_setup_needs_help("macOS", ""),
		"macOS + unresolved node → step relevant")
	testing.ok(
		not OnboardingWizard._macos_setup_needs_help("macOS", "/opt/homebrew/bin/node"),
		"macOS + resolved node → skip (a GUI client will find Node)")
	testing.ok(
		not OnboardingWizard._macos_setup_needs_help("Windows", ""),
		"non-macOS (Windows) + unresolved → skip")
	testing.ok(
		not OnboardingWizard._macos_setup_needs_help("Windows", "C:/node/node.exe"),
		"non-macOS (Windows) + resolved → skip")
	testing.ok(
		not OnboardingWizard._macos_setup_needs_help("Linux", ""),
		"non-macOS (Linux) → skip regardless of node")
	print("")


# The "Step X of N" total and the resume clamp use the EFFECTIVE step count: the
# macOS-setup step is counted only when it will actually show, so a good-setup host
# sees "of 3", never "of 4" followed by an early finish.
static func _test_effective_step_count(testing) -> void:
	testing.begin("OnboardingWizard — effective step count")
	var wizard := OnboardingWizard.new(null, null, null, null)
	# Default (macOS step not needed — the non-macOS / resolved-node case) → 3 steps.
	testing.eq(wizard._effective_step_count(), 3, "no macOS step → total 3")
	wizard._macos_help_needed = true
	testing.eq(wizard._effective_step_count(), 4, "macOS step applies → total 4")
	print("")
