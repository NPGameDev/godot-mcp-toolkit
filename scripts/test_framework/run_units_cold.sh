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

# Headless teardown emits benign leak-at-exit reports (dummy-renderer RIDs +
# a few ObjectDB instances). They are NOT a failure signal - the unit runner's
# exit code (below) is the sole gate. Godot exposes no env/CLI switch to silence
# them (leak reporting is the internal CoreGlobals::leak_reporting_enabled, always
# on in editor/debug builds), so they simply print. (A prior
# GODOT_DISABLE_LEAK_CHECKS=1 export here was a no-op - no such engine variable
# exists - and was removed.)

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

# Windows (Git Bash/MSYS) only: record the warm-up's REAL Windows PID while it
# is alive. $WARMUP_PID is an MSYS-space pid (and may even be a launcher shim),
# so the POSIX kills below don't always reach the native process — the mapping
# must be captured up front for the taskkill escalation in the teardown.
WARMUP_WINPID=""
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    WARMUP_WINPID="$(cat "/proc/$WARMUP_PID/winpid" 2>/dev/null || true)"
    ;;
esac

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

# Windows-proof teardown (41n-quater-sexies C3). The POSIX kills above target
# the MSYS pid and do not always reach the native Windows process. A surviving
# warm-up editor is a PORT THIEF for the real editor boot that follows: it
# keeps the editor WS port (6550) and the LSP port (6005), the next editor
# silently re-registers its WS on 6551+ while its LSP bind fails for the whole
# session (Godot 4.2-4.4 never retries a failed LSP bind) — the leading
# hypothesis for the Win-4.2 CI LSP-initialize mute. Escalation, Windows-branch
# only (the POSIX flow above is byte-identical on Linux/macOS):
#   1. taskkill the recorded WinPID tree (harmless no-op if already dead);
#   2. if 6550/6005 still LISTEN after a bounded settle — GitHub Actions only
#      — taskkill the PID(s) that OWN those LISTENING sockets (parsed from
#      netstat -ano), image-agnostic so it targets the orphaned holder the
#      shim's own PID tree misses (validated locally; CI-pending vs the live
#      zombie), loudly;
#   3. GitHub Actions only: assert the ports are free; a zombie that survived force-kill
#      fails HERE, fast, with tasklist/netstat evidence (exit 2, the script's
#      setup-error class) — the subsequent editor boot is already doomed, and
#      failing here names the cause instead of a downstream LSP mute.
# The destructive image-kill and the hard-fail are gated on
# GITHUB_ACTIONS=true (set only by GitHub runners — deliberately NOT the
# ambient CI=true, which other CI systems set and developers export to repro
# CI behavior): on a developer machine another editor legitimately holding
# 6550 for a different project must be neither killed nor treated as a
# failure — locally this only warns.
#
# Taxonomy (H1/H2, 41n-quater-sexies): this teardown exists to kill H1 — the
# zombie warm-up editor holding 6550/6005 (only the 4.2 legs boot a warm-up
# editor, hence the 4.2-only CI exposure). A ports-free failure HERE is H1
# caught red-handed. The H2 signature (exactly one godot PID, 6005 owned by
# the main editor, initialize still mute) never reaches this script — see the
# behavioral composite's "forensics key" in the server repo for the decoder.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    ports_listening() {
      netstat -ano 2>/dev/null | grep -E ":(6550|6005)[^0-9]" 2>/dev/null | grep -c "LISTENING" 2>/dev/null || true
    }
    # The owning PID(s) of the LISTENING sockets on 6550/6005 — the last
    # whitespace field of each LISTENING netstat -ano row. This is what roots
    # the reliable kill: setup-godot puts a SHIM on PATH (GODOT_BIN =
    # .../bin/godot, extensionless), so $! and the WinPID tree can be the
    # shim's, and the orphaned real editor holds the port under a different PID
    # whose image name is not "godot" (observed: PID 7880 held 6005, tasklist
    # grep -i godot empty). Killing the port-OWNER PID is image-agnostic and
    # reaches it regardless of the shim-orphan.
    port_owner_pids() {
      netstat -ano 2>/dev/null | grep -E ":(6550|6005)[^0-9]" 2>/dev/null | grep "LISTENING" 2>/dev/null | awk '{print $NF}' | sort -u || true
    }
    if [ -n "$WARMUP_WINPID" ]; then
      taskkill //F //T //PID "$WARMUP_WINPID" >/dev/null 2>&1 || true
    fi
    HELD="$(ports_listening)"
    if [ "$HELD" != "0" ]; then
      for _ in 1 2 3 4 5; do
        sleep 1
        HELD="$(ports_listening)"
        [ "$HELD" = "0" ] && break
      done
    fi
    # Reliable fallback (GitHub Actions only): kill whatever process OWNS the
    # ports. REPLACES the former //IM image-name kill, which was proven
    # ineffective in CI — the shim basename 'godot' matched no running image
    # while the orphaned editor (PID 7880) kept 6005. On the runner nothing but
    # a warm-up zombie can hold these ports at this point, so killing the owner
    # (and its tree) is safe; the GITHUB_ACTIONS gate keeps it off dev machines.
    if [ "$HELD" != "0" ] && [ "${GITHUB_ACTIONS:-}" = "true" ]; then
      for pid in $(port_owner_pids); do
        { [ -n "$pid" ] && [ "$pid" != "0" ]; } || continue
        echo "warm-up teardown: ports 6550/6005 still held — force-killing port-owner PID $pid"
        taskkill //F //T //PID "$pid" >/dev/null 2>&1 || true
      done
      sleep 2
      HELD="$(ports_listening)"
    fi
    if [ "$HELD" != "0" ]; then
      if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        echo "ERROR: warm-up editor ZOMBIE survived force-kill — 6550/6005 still LISTENING; the next editor boot is doomed (LSP bind loss is permanent on 4.2-4.4)." >&2
        echo "--- port-owner processes (by PID) ---"
        for pid in $(port_owner_pids); do
          { [ -n "$pid" ] && [ "$pid" != "0" ]; } || continue
          tasklist //FI "PID eq $pid" 2>/dev/null | grep -viE "No tasks|^$|Image Name|^=" || true
        done
        echo "--- netstat (6550/6005) ---"
        netstat -ano 2>/dev/null | grep -E ":(6550|6005)[^0-9]" || true
        echo "--- warm-up log tail (may explain the zombie) ---"
        tail -40 "$WARMUP_LOG" 2>/dev/null || true
        rm -f "$WARMUP_LOG"
        exit 2
      fi
      echo "WARNING: ports 6550/6005 still LISTENING after the warm-up teardown (another editor running locally?) — continuing (non-CI)."
    fi
    ;;
esac

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
