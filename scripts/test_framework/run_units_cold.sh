#!/usr/bin/env bash
# scripts/test_framework/run_units_cold.sh
# Cold-cache unit runner for Godot 4.2 — real execution signal where the
# editor-headless static validator cannot run.
#
# Godot 4.2's editor scan aborts on cross-file class_name references before it
# completes, so validate_gdscript.sh is gated 4.3+. The fix is the 4.3 GDScript
# analyzer overhaul (godotengine/godot#94617, #93346), which is in no 4.2.x. 4.2
# still gets an execution signal here: an editor-scan boot warms
# global_script_class_cache.cfg, then the unit suite runs against the warm
# cache.
#
# The warm-up gates on the ARTIFACT, not on frames: the editor boot runs in
# the background and the script polls for the cache file, then kills the
# editor. A frame-count quit (--quit-after) races the threaded scan — on slow
# runner disks the editor can exit before the cache write lands (observed CI
# flake), while fast local disks always win the race. Polling for the file is
# deterministic on both.
#
# The warm-up must NOT use --import: on Godot 4.2.0, --import hangs
# indefinitely after the autoload load failure and never writes the class
# cache (engine bug, fixed by 4.2.2). The editor-scan boot works on all 4.2.x.
#
# The warm-up is quiet by default, loud on failure: its output (including the
# transient `Identifier "…" not declared` ordering errors, expected on 4.2)
# goes to a temp log summarized in one line; the log tail is dumped if the
# warm-up cannot produce the cache or the unit run fails, so CI forensics
# survive without drowning the green path.
#
# The unit runner's exit code is the ONLY test gate. The warm-up boot's exit
# code is unreliable (benign headless warnings), so it is never consulted.
#
# Same script runs locally (in a 4.2 Linux container) and in CI (composite
# action + the cross-version warm-up step), GODOT_BIN-parameterized exactly
# like validate_gdscript.sh — zero drift.
#
# Usage: ./scripts/test_framework/run_units_cold.sh [godot-binary-path]
# Exit 0 = all units passed, 1 = unit failures, 2 = setup/warm-up error.
#
# Environment variables:
#   GODOT_BIN       - Godot binary (default: first arg, or "godot")
#   GODOT_WARM_ONLY - set to 1 to exit 0 right after a successful warm-up
#                     (cache written, no unit run) — lets workflows reuse the
#                     warm-up logic without duplicating it

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
CACHE_FILE=".godot/global_script_class_cache.cfg"

echo "=== Warm-up: editor scan (poll for global_script_class_cache.cfg) ==="
"$GODOT_BIN" --headless --editor --path . > "$WARMUP_LOG" 2>&1 &
WARMUP_PID=$!

WAITED=0
while [ ! -f "$CACHE_FILE" ] && [ "$WAITED" -lt 120 ]; do
  sleep 1
  WAITED=$((WAITED + 1))
done

if [ -f "$CACHE_FILE" ]; then
  # Settle: the file exists; give the writer a beat to finish before the kill.
  sleep 1
fi

kill "$WARMUP_PID" 2>/dev/null || true
for _ in 1 2 3 4 5; do
  kill -0 "$WARMUP_PID" 2>/dev/null || break
  sleep 1
done
kill -9 "$WARMUP_PID" 2>/dev/null || true
wait "$WARMUP_PID" 2>/dev/null || true

NOT_DECLARED="$(grep -c "not declared" "$WARMUP_LOG" || true)"
if [ ! -f "$CACHE_FILE" ]; then
  echo "warm-up: $NOT_DECLARED transient 'not declared' errors (expected on 4.2), cache written: no (waited ${WAITED}s)"
  echo "--- warm-up failed to produce the class cache; log tail ---"
  tail -40 "$WARMUP_LOG"
  rm -f "$WARMUP_LOG"
  exit 2
fi
echo "warm-up: $NOT_DECLARED transient 'not declared' errors (expected on 4.2), cache written: yes (${WAITED}s)"

if [ "${GODOT_WARM_ONLY:-0}" = "1" ]; then
  rm -f "$WARMUP_LOG"
  exit 0
fi

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
