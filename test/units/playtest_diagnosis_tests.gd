@tool
extends RefCounted
## Unit tests for the game.start startup-diagnosis helper _diagnose_startup (pure).
##
## The helper decides why a runtime probe found no live game, and must only claim a
## compilation failure when errors are actually captured AND the game never ran — an
## empty log buffer proves nothing about compilation (a cold-start parse error may not
## have landed, and 4.2-4.4 file-tail mode can miss parse errors entirely). These pins
## walk the four quadrants (errors found / empty buffer × the game was running / not)
## and the version caveat, which must appear only on the file-tail source and never on
## the logger source. Pure inputs → runs headless under run_unit_tests.gd.

const PlaytestControl := preload("res://addons/godot_mcp_toolkit/commands/playtest/playtest_control.gd")

const _VERSION_PAIR := "4.3"


static func run(testing) -> void:
	_test_diagnosis_quadrants(testing)
	_test_file_tail_caveat(testing)


## The one compile claim: COMPILATION_FAILED only for errors-captured AND never-ran.
## Every other quadrant states the GAME_NOT_RUNNING fact without asserting a cause.
static func _test_diagnosis_quadrants(testing) -> void:
	testing.begin("game.start _diagnose_startup quadrants")

	var with_errors := _scan("file_tail", true)
	var empty := _scan("file_tail", false)

	# found & never-ran (hard) → the sole compile claim.
	var found_hard := PlaytestControl._diagnose_startup(with_errors, false, _VERSION_PAIR)
	testing.eq(str(found_hard["code"]), "COMPILATION_FAILED",
		"errors captured + never ran → COMPILATION_FAILED")
	testing.ok((found_hard["errors"] as Array).size() == 1,
		"captured errors passed through on the compile-claim path")

	# found & ran-then-died (soft) → runtime-crash framing, NOT a compile claim.
	var found_soft := PlaytestControl._diagnose_startup(with_errors, true, _VERSION_PAIR)
	testing.eq(str(found_soft["code"]), "GAME_NOT_RUNNING",
		"errors captured + was running → GAME_NOT_RUNNING (runtime crash, not compile)")
	testing.ok(not str(found_soft["message"]).to_lower().contains("compil"),
		"ran-then-died message avoids a compile claim")

	# empty & never-ran (hard) → the fact + a/b hypotheses.
	var empty_hard := PlaytestControl._diagnose_startup(empty, false, _VERSION_PAIR)
	testing.eq(str(empty_hard["code"]), "GAME_NOT_RUNNING",
		"empty buffer + never ran → GAME_NOT_RUNNING (no cause claimed)")
	testing.ok(str(empty_hard["hint"]).contains("(a)") and str(empty_hard["hint"]).contains("(b)"),
		"hard empty-buffer hint offers both hypotheses")

	# empty & ran-then-died (soft) → runtime-crash framing.
	var empty_soft := PlaytestControl._diagnose_startup(empty, true, _VERSION_PAIR)
	testing.eq(str(empty_soft["code"]), "GAME_NOT_RUNNING",
		"empty buffer + was running → GAME_NOT_RUNNING")
	testing.ok(str(empty_soft["hint"]).to_lower().contains("crash")
			or str(empty_soft["hint"]).to_lower().contains("early exit"),
		"soft empty-buffer hint steers to runtime crash / early exit")

	print("")


## The file-tail caveat names the engine version only for the 4.2-4.4 file-tail
## source; the 4.5+ logger source emits no version text (it captures parse errors).
static func _test_file_tail_caveat(testing) -> void:
	testing.begin("game.start _diagnose_startup file-tail caveat")

	var file_tail := PlaytestControl._diagnose_startup(_scan("file_tail", false), false, _VERSION_PAIR)
	testing.ok(str(file_tail["hint"]).contains(_VERSION_PAIR),
		"file_tail source → version caveat present in hint")

	var logger := PlaytestControl._diagnose_startup(_scan("logger", false), false, _VERSION_PAIR)
	testing.ok(not str(logger["hint"]).contains(_VERSION_PAIR),
		"logger source → no version text in hint")

	print("")


## Build a scan dict shaped like _scan_compilation_errors' return: [param source] is
## "file_tail" or "logger"; [param has_errors] seeds one captured error when true.
static func _scan(source: String, has_errors: bool) -> Dictionary:
	var errors: Array = ["res://x.gd:1 - Parse Error: unexpected token"] if has_errors else []
	return {
		"found": has_errors,
		"errors": errors,
		"source": source,
	}
