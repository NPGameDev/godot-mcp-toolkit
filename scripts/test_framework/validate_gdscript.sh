#!/usr/bin/env bash
# scripts/test_framework/validate_gdscript.sh
# Centralized GDScript validation — replaces unreliable --check-only.
#
# --check-only is a no-op without --script (engine source audit: the flag
# is only consumed inside `if (!script.is_empty())` in main.cpp:4164).
# This script uses editor-headless mode instead, which loads the full
# editor, compiles all project scripts, and surfaces real errors.
#
# Usage: ./scripts/test_framework/validate_gdscript.sh [godot-binary-path]
# Exit 0 = clean, Exit 1 = script errors found, Exit 2 = setup error
#
# Environment variables:
#   GODOT_BIN              - Godot binary (default: first arg, or "godot")
#   GODOT_VALIDATE_TIMEOUT - timeout in seconds (default: 60)
#   GODOT_QUIT_AFTER       - editor frames before quit (default: 30)
#   SKIP_SCRIPT_RUNNER     - set to 1 to skip the per-file loader pass

set -euo pipefail

GODOT_BIN="${GODOT_BIN:-${1:-godot}}"
GODOT_VALIDATE_TIMEOUT="${GODOT_VALIDATE_TIMEOUT:-60}"
GODOT_QUIT_AFTER="${GODOT_QUIT_AFTER:-30}"
SKIP_SCRIPT_RUNNER="${SKIP_SCRIPT_RUNNER:-0}"

# ---------------------------------------------------------------------------
# Centralized error patterns — update this single line when Godot changes
# its error format. Stable across Godot 4.2-4.5 (engine source audit,
# 2026-05-27). Patterns checked:
#
#   Parse Error:    — gdscript.cpp, parser stage  (all versions)
#   Compile Error:  — gdscript.cpp, compiler stage (all versions)
#   SCRIPT ERROR    — runtime/test error header    (all versions)
# ---------------------------------------------------------------------------
ERROR_PATTERN='Parse Error:|Compile Error:|SCRIPT ERROR'

# Must be run from the project root (where project.godot lives).
if [ ! -f "project.godot" ]; then
  echo "ERROR: must be run from the project root (where project.godot lives)" >&2
  exit 2
fi

ERRORS_FOUND=0

# --- Pass 1: Editor-headless validation -----------------------------------
echo "=== Pass 1: Editor-headless validation ==="
echo "  Binary:     $GODOT_BIN"
echo "  Timeout:    ${GODOT_VALIDATE_TIMEOUT}s"
echo "  Quit-after: $GODOT_QUIT_AFTER frames"
echo ""

PASS1_OUTPUT=$(timeout "$GODOT_VALIDATE_TIMEOUT" \
  "$GODOT_BIN" --headless --editor --quit-after "$GODOT_QUIT_AFTER" 2>&1) || true

if echo "$PASS1_OUTPUT" | grep -qE "$ERROR_PATTERN"; then
  echo "FAIL — GDScript errors detected in editor-headless output:"
  echo ""
  # Show 3 lines of context after each match to capture file paths
  # and stack traces from Godot's error output.
  echo "$PASS1_OUTPUT" | grep -E -A 3 "$ERROR_PATTERN"
  ERRORS_FOUND=1
else
  echo "PASS — no GDScript errors in editor-headless output"
fi

# --- Pass 2: Per-file script runner (optional) ----------------------------
if [ "$SKIP_SCRIPT_RUNNER" != "1" ]; then
  echo ""
  echo "=== Pass 2: Per-file script runner ==="

  PASS2_OUTPUT=$(timeout "$GODOT_VALIDATE_TIMEOUT" \
    "$GODOT_BIN" --headless --script \
    scripts/test_framework/check_all_scripts.gd 2>&1) || true

  echo "$PASS2_OUTPUT"

  # Check both the script runner's own FAIL line and the centralized error
  # patterns in Godot's output (belt-and-suspenders).
  if echo "$PASS2_OUTPUT" | grep -q "^FAIL:"; then
    ERRORS_FOUND=1
  elif echo "$PASS2_OUTPUT" | grep -qE "$ERROR_PATTERN"; then
    echo ""
    echo "FAIL — GDScript errors detected in script runner output:"
    echo "$PASS2_OUTPUT" | grep -E -A 3 "$ERROR_PATTERN"
    ERRORS_FOUND=1
  fi
else
  echo ""
  echo "=== Pass 2: Skipped (SKIP_SCRIPT_RUNNER=1) ==="
fi

# --- Result ---------------------------------------------------------------
echo ""
if [ "$ERRORS_FOUND" -eq 1 ]; then
  echo "RESULT: FAIL — GDScript validation errors found"
  exit 1
else
  echo "RESULT: PASS — all GDScript validation checks passed"
  exit 0
fi
