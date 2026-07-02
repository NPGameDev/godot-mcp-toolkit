#!/usr/bin/env bash
# scripts/test_framework/run_units_cold.sh
# Cold-cache unit runner for Godot 4.2 — real execution signal where the
# editor-headless static validator cannot run.
#
# Godot 4.2's editor scan aborts on cross-file class_name references before it
# completes, so validate_gdscript.sh is gated 4.3+. The fix is the 4.3 GDScript
# analyzer overhaul (godotengine/godot#94617, #93346), which is in no 4.2.x. 4.2
# still gets an execution signal here: a bounded editor-scan boot
# (--editor --quit-after) warms global_script_class_cache.cfg, then the unit
# suite runs against the warm cache.
#
# The warm-up must NOT use --import: on Godot 4.2.0, --import hangs
# indefinitely after the autoload load failure and never writes the class
# cache (engine bug, fixed by 4.2.2). The bounded editor-scan boot works on
# all 4.2.x and writes the full cache in one pass.
#
# The warm-up is quiet by default, loud on failure: its output (including the
# transient `Identifier "…" not declared` ordering errors, expected on 4.2)
# goes to a temp log summarized in one line; the log tail is dumped only if
# the unit run fails, so CI forensics survive without drowning the green path.
#
# The unit runner's exit code is the ONLY gate. The warm-up boot's exit code
# is unreliable (benign headless warnings), so it is tolerated with `|| true`.
#
# Same script runs locally (in a 4.2 Linux container) and in CI (composite
# action), GODOT_BIN-parameterized exactly like validate_gdscript.sh — zero drift.
#
# Usage: ./scripts/test_framework/run_units_cold.sh [godot-binary-path]
# Exit 0 = all units passed, 1 = unit failures, 2 = setup error.
#
# Environment variables:
#   GODOT_BIN - Godot binary (default: first arg, or "godot")

set -euo pipefail

GODOT_BIN="${GODOT_BIN:-${1:-godot}}"

# Teardown leak-at-exit warnings must not fail the job (standard GUT/GdUnit4 CI
# convention). Set before any Godot run so it covers the unit teardown.
export GODOT_DISABLE_LEAK_CHECKS=1

# Must be run from the project root (where project.godot lives).
if [ ! -f "project.godot" ]; then
  echo "ERROR: must be run from the project root (where project.godot lives)" >&2
  exit 2
fi

WARMUP_LOG="$(mktemp)"

echo "=== Warm-up: bounded editor scan (writes global_script_class_cache.cfg) ==="
"$GODOT_BIN" --headless --editor --path . --quit-after 100 > "$WARMUP_LOG" 2>&1 || true

NOT_DECLARED="$(grep -c "not declared" "$WARMUP_LOG" || true)"
CACHE_WRITTEN="no"
if [ -f ".godot/global_script_class_cache.cfg" ]; then
  CACHE_WRITTEN="yes"
fi
echo "warm-up: $NOT_DECLARED transient 'not declared' errors (expected on 4.2), cache written: $CACHE_WRITTEN"

echo ""
echo "=== Unit runner (exit code gates the job) ==="
UNIT_EXIT=0
"$GODOT_BIN" --headless --script test/run_unit_tests.gd || UNIT_EXIT=$?

if [ "$UNIT_EXIT" -ne 0 ]; then
  echo ""
  echo "--- unit run failed (exit $UNIT_EXIT); warm-up log tail for forensics ---"
  tail -40 "$WARMUP_LOG"
fi

rm -f "$WARMUP_LOG"
exit "$UNIT_EXIT"
