#!/usr/bin/env bash
# scripts/test_framework/run_units_cold.sh
# Cold-cache unit runner for Godot 4.2 — real execution signal where the
# editor-headless static validator cannot run.
#
# Godot 4.2's editor scan aborts on cross-file class_name references before it
# completes, so validate_gdscript.sh is gated 4.3+. The fix is the 4.3 GDScript
# analyzer overhaul (godotengine/godot#94617, #93346), which is in no 4.2.x. 4.2
# still gets an execution signal here: two --import passes warm the global class
# cache (pass 1 populates it while emitting transient `Identifier "…" not
# declared` ordering errors and exits non-zero; pass 2 resolves clean), then the
# unit suite runs against the warm cache.
#
# The unit runner's exit code is the ONLY gate. An --import exit code is
# unreliably 1 even on a clean pass (benign headless warnings — "custom cursor",
# "no Blender path"), so both warm-up passes are tolerated with `|| true`.
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

echo "=== Warm-up pass 1 (populates global_script_class_cache.cfg; transient class_name errors expected) ==="
"$GODOT_BIN" --headless --path . --import || true

echo ""
echo "=== Warm-up pass 2 (resolves clean against the warmed cache) ==="
"$GODOT_BIN" --headless --path . --import || true

echo ""
echo "=== Unit runner (exit code gates the job) ==="
"$GODOT_BIN" --headless --script test/run_unit_tests.gd
