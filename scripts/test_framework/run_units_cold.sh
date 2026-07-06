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

# Bounded boot retry: an editor can die at boot (a one-off engine crash) or hang
# without ever writing the class cache. Rather than burn the whole poll window on
# a single doomed boot, try up to MAX_BOOT_ATTEMPTS fresh boots — each = launch →
# poll for the cache ARTIFACT (never a frame-count/time quit, which races the
# threaded scan) with a process-death short-circuit → on death or timeout, warn,
# dump the log tail, kill the remnant, and retry with a fresh log.
# INVARIANT: MAX_BOOT_ATTEMPTS x BOOT_POLL_SECS + teardown overhead must stay
# under the CI caller's 300s warm-up-step fuse (3 x 80s = 240s today), so an
# all-attempts-fail still exits cleanly with forensics rather than being
# fuse-killed — retune both together, never one alone.
MAX_BOOT_ATTEMPTS=3
BOOT_POLL_SECS=80
WARMUP_PID=""
WARMUP_WINPID=""

# Kill the current warm-up editor as thoroughly as the platform allows: the POSIX
# signal (escalating to -9), plus — on Windows — a taskkill of the recorded REAL
# Windows PID tree, because $WARMUP_PID is an MSYS-space pid (possibly a launcher
# shim) that the POSIX kill does not always reach. A no-op when nothing is running.
kill_warmup_editor() {
  [ -n "$WARMUP_PID" ] || return 0
  kill "$WARMUP_PID" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    kill -0 "$WARMUP_PID" 2>/dev/null || break
    sleep 1
  done
  kill -9 "$WARMUP_PID" 2>/dev/null || true
  wait "$WARMUP_PID" 2>/dev/null || true
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      [ -n "$WARMUP_WINPID" ] && taskkill //F //T //PID "$WARMUP_WINPID" >/dev/null 2>&1 || true
      ;;
  esac
}

echo "=== Warm-up: editor scan (poll for global_script_class_cache.cfg, up to ${MAX_BOOT_ATTEMPTS} boots) ==="
WAITED=0
for attempt in $(seq 1 "$MAX_BOOT_ATTEMPTS"); do
  : > "$WARMUP_LOG"  # fresh log per attempt
  "$GODOT_BIN" --headless --editor --path . > "$WARMUP_LOG" 2>&1 &
  WARMUP_PID=$!
  # Windows (Git Bash/MSYS) only: record the warm-up's REAL Windows PID while it
  # is alive. $WARMUP_PID is an MSYS-space pid (and may even be a launcher shim),
  # so the POSIX kills don't always reach the native process — the mapping must be
  # captured up front for the taskkill escalation (kill_warmup_editor + teardown).
  WARMUP_WINPID=""
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      WARMUP_WINPID="$(cat "/proc/$WARMUP_PID/winpid" 2>/dev/null || true)"
      ;;
  esac

  WAITED=0
  BOOT_REASON=""
  while [ ! -f "$CACHE_FILE" ] && [ "$WAITED" -lt "$BOOT_POLL_SECS" ]; do
    if ! kill -0 "$WARMUP_PID" 2>/dev/null; then
      BOOT_REASON="editor process died during scan"
      break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
  done

  [ -f "$CACHE_FILE" ] && break  # cache written — success; the editor is killed once in the teardown below

  [ -n "$BOOT_REASON" ] || BOOT_REASON="cache not written after ${BOOT_POLL_SECS}s"
  echo "::warning::warm-up boot attempt ${attempt}/${MAX_BOOT_ATTEMPTS} failed (${BOOT_REASON})"
  echo "warm-up boot attempt ${attempt}/${MAX_BOOT_ATTEMPTS} failed (${BOOT_REASON}); log tail:"
  tail -40 "$WARMUP_LOG" 2>/dev/null || true
  kill_warmup_editor  # never leave a failed attempt holding the project or the ports
  WARMUP_PID=""
  WARMUP_WINPID=""
done

if [ -f "$CACHE_FILE" ]; then
  # Settle: the file exists; give the writer a beat to finish before the kill.
  sleep 1
fi
kill_warmup_editor

# Windows-proof teardown. The POSIX kills above target the MSYS pid and do not
# always reach the native Windows process. A surviving warm-up editor is a PORT
# THIEF for the real editor boot that follows: it keeps the editor WS port (6550)
# and the LSP port (6005); the next editor silently re-registers its WS on 6551+
# while its LSP bind fails for the whole session (Godot 4.2-4.4 never retries a
# failed LSP bind) — the confirmed cause of the Win-4.2 CI LSP-initialize mute.
# Escalation, Windows-branch only (the POSIX flow above is byte-identical on
# Linux/macOS), destructive steps GitHub Actions only:
#   1. Kill-verify loop: re-sample netstat in a BOUNDED loop (every 2s, up to
#      ~10s), re-resolving the port OWNER each pass and re-killing it. This
#      replaces a single post-taskkill sample, which raced the OS socket teardown
#      and could FALSE-POSITIVE "survived" on an already-exiting process. Survival
#      is declared only if a port is still held after the whole window; a NEW
#      owner PID is not the old zombie, which is why the owner is re-resolved (not
#      cached). Killing the port-OWNER PID is image-agnostic and reaches the
#      shim-orphaned editor the WinPID tree misses (observed: a PID held 6005
#      while `tasklist | grep -i godot` was empty).
#   2. WS port (6550) still held → PORT-AGILITY, not failure: 6550 is fully
#      env-configurable (GODOT_MCP_EDITOR_PORT pins the toolkit's exact bind and
#      the server smoke/flows read the same var), so pin the next editor boot to
#      the first free port in 6551-6560 and export it (GITHUB_ENV) for the
#      downstream steps. Loud, but the run continues.
#   3. LSP port (6005) still held → retry-then-FAIL, but only with a downstream
#      consumer: 6005 is Godot's network/language_server/remote_port editor
#      setting, bound by the editor and NOT relocatable from this wrapper. The
#      behavioral smoke §41 (LSP tools) CONSUMES it and can fail on an
#      accepted-but-mute socket, so a zombie still holding 6005 ahead of a
#      behavioral suite (GODOT_WARM_ONLY set) is a hard stop (exit 2, the
#      setup-error class) with full forensics — the kill-verify loop above WAS
#      the retry. Without a downstream suite (the unit-runner path binds no
#      ports), nothing consumes 6005, so warn only.
# The destructive kills and the hard-fail are gated on GITHUB_ACTIONS=true (set
# only by GitHub runners — deliberately NOT the ambient CI=true, which other CI
# systems set and developers export to repro CI behavior): on a developer machine
# another editor legitimately holding 6550 for a different project must be neither
# killed nor treated as a failure — locally this only warns.
#
# Taxonomy (H1/H2): this teardown exists to kill H1 — the zombie warm-up editor
# holding 6550/6005 (only the 4.2 legs boot a warm-up editor, hence the 4.2-only
# CI exposure). A ports-free failure HERE is H1 caught red-handed. The H2
# signature (exactly one godot PID, 6005 owned by the main editor, initialize
# still mute) never reaches this script — see the behavioral composite's
# "forensics key" in the server repo for the decoder.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    # LISTENING socket count on a single port (arg 1). "0" == free.
    port_listening() {
      netstat -ano 2>/dev/null | grep -E ":$1[^0-9]" 2>/dev/null | grep -c "LISTENING" 2>/dev/null || true
    }
    # The owning PID(s) of the LISTENING sockets on 6550/6005 — the last
    # whitespace field of each LISTENING netstat -ano row. Re-resolved on every
    # sample because a socket's owner can change between passes.
    port_owner_pids() {
      netstat -ano 2>/dev/null | grep -E ":(6550|6005)[^0-9]" 2>/dev/null | grep "LISTENING" 2>/dev/null | awk '{print $NF}' | sort -u || true
    }
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
      # Kill-verify: check-then-kill, bounded. The healthy path (the WinPID
      # taskkill in kill_warmup_editor already freed the ports) breaks on the
      # first check WITHOUT printing — silent when nothing lingers.
      for _ in 1 2 3 4 5; do
        [ "$(port_listening 6550)" = "0" ] && [ "$(port_listening 6005)" = "0" ] && break
        for pid in $(port_owner_pids); do
          { [ -n "$pid" ] && [ "$pid" != "0" ]; } || continue
          echo "warm-up teardown: ports 6550/6005 still held — force-killing port-owner PID $pid"
          taskkill //F //T //PID "$pid" >/dev/null 2>&1 || true
        done
        sleep 2
      done
    else
      # Non-CI: bounded settle only, no destructive image-agnostic kill (another
      # editor may legitimately hold 6550 for a different project on a dev box).
      for _ in 1 2 3 4 5; do
        [ "$(port_listening 6550)" = "0" ] && [ "$(port_listening 6005)" = "0" ] && break
        sleep 1
      done
    fi

    HELD_6550="$(port_listening 6550)"
    HELD_6005="$(port_listening 6005)"
    if [ "$HELD_6550" != "0" ] || [ "$HELD_6005" != "0" ]; then
      if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        # WS port agility — relocate, do not fail.
        if [ "$HELD_6550" != "0" ]; then
          SPARE=""
          for p in 6551 6552 6553 6554 6555 6556 6557 6558 6559 6560; do
            if [ "$(port_listening "$p")" = "0" ]; then SPARE="$p"; break; fi
          done
          if [ -n "$SPARE" ] && [ -n "${GITHUB_ENV:-}" ]; then
            echo "GODOT_MCP_EDITOR_PORT=$SPARE" >> "$GITHUB_ENV"
            echo "::warning::warm-up teardown: WS port 6550 still held after force-kill — pinning the next editor boot to spare port $SPARE (exported as GODOT_MCP_EDITOR_PORT for smoke/flows)."
            echo "warm-up teardown: WS port 6550 relocated to $SPARE"
          else
            echo "::warning::warm-up teardown: WS port 6550 still held and no free spare in 6551-6560 (or GITHUB_ENV unset) — the next editor boot may collide."
          fi
        fi
        # LSP port (6005) — hard stop only when a downstream behavioral suite
        # will consume it (GODOT_WARM_ONLY); the LSP bind is not relocatable.
        if [ "$HELD_6005" != "0" ] && [ "${GODOT_WARM_ONLY:-0}" = "1" ]; then
          echo "ERROR: warm-up editor ZOMBIE survived force-kill — 6005 (GDScript LSP) still LISTENING; the behavioral leg's LSP checks are doomed (LSP bind loss is permanent on 4.2-4.4, and the LSP port is not relocatable from this wrapper)." >&2
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
        if [ "$HELD_6005" != "0" ]; then
          echo "::warning::warm-up teardown: LSP port 6005 still held after force-kill, but no downstream LSP consumer (unit-runner path) — continuing."
        fi
      else
        echo "WARNING: ports 6550/6005 still LISTENING after the warm-up teardown (another editor running locally?) — continuing (non-CI)."
      fi
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
