@tool
extends RefCounted
## Shared test-assertion object for the decomposed unit suite.
##
## One instance is built by the thin run_unit_tests.gd orchestrator and passed to
## every test module's `static func run(testing)`. Owns the pass/fail counters and the
## current-group label; modules call begin/ok/eq and never touch the counters.

var _passed := 0
var _failed := 0
var _errors: Array[String] = []
var _group := ""


## Start a new test group; [param name] is the printed banner + the failure prefix.
func begin(name: String) -> void:
	_group = name
	print("[%s]" % name)


## Record a boolean assertion under the current group.
func ok(value: bool, label: String) -> void:
	if value:
		_passed += 1
		print("  PASS: %s" % label)
	else:
		_failed += 1
		_errors.append("%s > %s" % [_group, label])
		print("  FAIL: %s" % label)


## Record an equality assertion; prints expected/got on failure.
func eq(actual, expected, label: String) -> void:
	if actual == expected:
		_passed += 1
		print("  PASS: %s" % label)
	else:
		_failed += 1
		_errors.append("%s > %s" % [_group, label])
		print("  FAIL: %s (expected: %s, got: %s)" % [
			label, str(expected), str(actual)])


## A no-op command handler returning {"success": true} — a Callable several
## registry/dispatch modules register as a stand-in handler.
func noop(_p: Dictionary) -> Dictionary:
	return {"success": true}


## Print the final banner + any failures. Returns the failed count so the
## orchestrator sets the exit code.
func report() -> int:
	print("")
	if _failed == 0:
		print("=== ALL %d PASSED ===" % _passed)
	else:
		print("=== %d FAILED (%d passed) ===" % [_failed, _passed])
		for e in _errors:
			print("  FAIL: %s" % e)
	return _failed
