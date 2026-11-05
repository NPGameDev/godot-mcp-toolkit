#!/usr/bin/env bash
# scripts/test_framework/validate_gdscript.sh
# Centralized GDScript validation — replaces unreliable --check-only.
#
# --check-only is a no-op without --script (engine source audit: the flag
# is only consumed inside `if (!script.is_empty())` in main.cpp:4164).
# This script uses editor-headless mode instead, which loads the full
# editor, compiles all project scripts, and surfaces real errors.
#
# A tree with no class cache is warmed first, by the sibling run_units_cold.sh.
# The per-file pass needs its script in the working directory, so another
# project's root runs the editor pass alone and says so.
#
# Usage: ./scripts/test_framework/validate_gdscript.sh [godot-binary-path]
# The first argument is the binary, read only when GODOT_BIN is unset; a .gd path
# there exits 2.
# Exit 0 = clean, Exit 1 = script errors found, Exit 2 = setup error: not run from
# a project root, the warm-up failed, Godot never started, or the per-file pass
# reported no verdict.
#
# Environment variables:
#   GODOT_BIN              - Godot binary (default: first arg, or "godot")
#   GODOT_VALIDATE_TIMEOUT - timeout per pass in seconds (default: 60); the warm-up
#                            has its own bound
#   GODOT_QUIT_AFTER       - editor frames before quit (default: 30)
#   SKIP_SCRIPT_RUNNER     - set to 1 to skip the per-file loader pass

set -euo pipefail

GODOT_BIN="${GODOT_BIN:-${1:-godot}}"
GODOT_VALIDATE_TIMEOUT="${GODOT_VALIDATE_TIMEOUT:-60}"
GODOT_QUIT_AFTER="${GODOT_QUIT_AFTER:-30}"
SKIP_SCRIPT_RUNNER="${SKIP_SCRIPT_RUNNER:-0}"
# From this script's own path: extension authors run it from their project's root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_FILE=".godot/global_script_class_cache.cfg"
PASS2_SCRIPT="scripts/test_framework/check_all_scripts.gd"

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

# --- Warm-up: the class cache -----------------------------------------------
# Godot 4.3 writes the cache only when its threaded scan ends, so pass 1's
# frame-count quit can beat the write, and pass 2 then fails on every class_name.
# The warm-up polls for the file instead. It runs on any version with no cache.
# A stale cache gets no warm-up: one held with a new class_name and a script
# typed on it.
if [ ! -f "$CACHE_FILE" ]; then
  if ! GODOT_BIN="$GODOT_BIN" GODOT_WARM_ONLY=1 bash "$SCRIPT_DIR/run_units_cold.sh"; then
    echo "ERROR: the class-cache warm-up failed, so nothing was validated" >&2
    exit 2
  fi
  echo ""
fi

# --- Pass 1: Editor-headless validation -----------------------------------
echo "=== Pass 1: Editor-headless validation ==="
echo "  Binary:     $GODOT_BIN"
echo "  Timeout:    ${GODOT_VALIDATE_TIMEOUT}s"
echo "  Quit-after: $GODOT_QUIT_AFTER frames"
echo ""

PASS1_EXIT=0
PASS1_OUTPUT=$(timeout "$GODOT_VALIDATE_TIMEOUT" \
  "$GODOT_BIN" --headless --editor --quit-after "$GODOT_QUIT_AFTER" 2>&1) || PASS1_EXIT=$?

echo "Pass 1 exit code: $PASS1_EXIT"
# 126 and 127 mean Godot never started. Every other code stays unenforced, since
# 134 and 139 appear on good runs: the output below is the verdict.
if [ "$PASS1_EXIT" -eq 126 ] || [ "$PASS1_EXIT" -eq 127 ]; then
  # The output holds the real reason: a missing timeout, a loader error.
  echo "$PASS1_OUTPUT" >&2
  echo "ERROR: Godot could not start: running '$GODOT_BIN' under timeout exited $PASS1_EXIT" >&2
  exit 2
fi

# A here-string, not a pipe: grep -q stops at its first match, which can kill the
# writer of a large output, and pipefail then reads that as no match.
if grep -qE "$ERROR_PATTERN" <<<"$PASS1_OUTPUT"; then
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
if [ "$SKIP_SCRIPT_RUNNER" = "1" ]; then
  echo ""
  echo "=== Pass 2: Skipped (SKIP_SCRIPT_RUNNER=1) ==="
elif [ ! -f "$PASS2_SCRIPT" ]; then
  echo ""
  echo "=== Pass 2: Skipped ($PASS2_SCRIPT is not in this project) ==="
else
  echo ""
  echo "=== Pass 2: Per-file script runner ==="

  PASS2_OUTPUT=$(timeout "$GODOT_VALIDATE_TIMEOUT" \
    "$GODOT_BIN" --headless --script "$PASS2_SCRIPT" 2>&1) || true

  echo "$PASS2_OUTPUT"

  # The script always ends on one of these two lines, so neither means it crashed,
  # hung or never loaded. No retry: a retry would hide a real crash.
  if ! grep -qE "^(PASS|FAIL):" <<<"$PASS2_OUTPUT"; then
    echo "ERROR: pass 2 reported neither PASS: nor FAIL:, so it reached no verdict" >&2
    exit 2
  fi

  # Check both the script runner's own FAIL line and the centralized error
  # patterns in Godot's output (belt-and-suspenders).
  if grep -q "^FAIL:" <<<"$PASS2_OUTPUT"; then
    ERRORS_FOUND=1
  elif grep -qE "$ERROR_PATTERN" <<<"$PASS2_OUTPUT"; then
    echo ""
    echo "FAIL — GDScript errors detected in script runner output:"
    echo "$PASS2_OUTPUT" | grep -E -A 3 "$ERROR_PATTERN"
    ERRORS_FOUND=1
  fi
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
