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
# fuse-killed — retune both together, never one alone. Teardown overhead is not
# free and is part of THIS budget: the per-attempt kill_warmup_editor rounds
# plus, on Windows, the kill-verify loop and the dead-owner grace window
# (LINGER_GRACE_SECS) below each spend real seconds against the same fuse. The
# fuse kills the step outright, so overrunning it costs the run's verdict, not
# just its forensics — count all of them whenever any one is retuned.
MAX_BOOT_ATTEMPTS=3
BOOT_POLL_SECS=80
WARMUP_PID=""
WARMUP_WINPID=""

# Windows CI only: move the WARM-UP editor's GDScript LSP off the default 6005 so
# it can never collide with the real editor that boots after it. Godot's Windows
# sockets are created INHERITABLE, so a child process can inherit the warm-up
# editor's LSP listen handle and keep the socket alive after the editor itself is
# gone — netstat then reports the dead creator PID, there is no process by that
# PID to kill, and the next editor's 6005 bind fails outright (Windows has no
# usable address reuse, and the 4.2-4.4 LSP never retries a failed bind). Not
# binding 6005 in the first place removes the collision at the source; the
# teardown gate below stays as the generic net for any other holder.
# Triple-gated to the exact failing combination — Windows, GitHub Actions, and a
# downstream behavioral consumer — so every other invocation (POSIX CI, local
# dev, the unit-runner path) boots the byte-identical command line it always did.
# --lsp-port exists in every supported 4.2+ build and is applied before editor
# settings are read. Deliberately unquoted at the call site: an empty value must
# expand to NO argv entry, and a set one must split into two.
WARMUP_LSP_ARGS=""
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ "${GODOT_WARM_ONLY:-0}" = "1" ]; then
      WARMUP_LSP_ARGS="--lsp-port 6105"
    fi
    ;;
esac

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
  "$GODOT_BIN" --headless --editor $WARMUP_LSP_ARGS --path . > "$WARMUP_LOG" 2>&1 &
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
#      and could FALSE-POSITIVE "survived" on an already-exiting process. A NEW
#      owner PID is not the old zombie, which is why the owner is re-resolved (not
#      cached). Killing the port-OWNER PID resolves the target from the SOCKET,
#      so it needs neither an image name (a renamed or shim-wrapped binary is
#      still reached) nor membership in the recorded WinPID tree (an editor
#      orphaned from that tree is reached too) — both of which a name- or
#      tree-based kill depends on.
#   2. Liveness gate: a held port is a ZOMBIE only if its owner is ALIVE. On
#      Windows a LISTENING row can NAME a PID that no longer exists — the engine
#      creates its sockets inheritable and spawns children with handle
#      inheritance on, so a child can inherit the LSP listen handle and keep the
#      socket open long after its creator is gone, with netstat still reporting
#      that dead creator. Occupancy alone reads that as a survivor, yet there is
#      no process by that PID to kill. So the owner is corroborated with
#      tasklist: a LIVE owner is a real zombie and escalates below, while NO live
#      owner (or no owner at all) is a socket outliving its creator and is waited
#      out in a kill-free grace window instead. Survival is declared only for a
#      LIVE owner, or for a dead-owner row that outlives that window. The warm-up
#      no longer binds 6005 at all on this platform (see WARMUP_LSP_ARGS), so
#      this gate is the net for any OTHER holder, not the primary defence.
#   3. WS port (6550) still held → PORT-AGILITY, not failure: 6550 is fully
#      env-configurable (GODOT_MCP_EDITOR_PORT pins the toolkit's exact bind and
#      the server smoke/flows read the same var), so pin the next editor boot to
#      the first free port in 6551-6560 and export it (GITHUB_ENV) for the
#      downstream steps. Loud, but the run continues.
#   4. LSP port (6005) still held → retry-then-FAIL, but only with a downstream
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
    # sample because a socket's owner can change between passes. CRs are stripped
    # first: netstat is a .cmd-family tool, and a PID carrying a trailing CR is
    # rejected by every consumer below (tasklist errors out, taskkill no-ops), so
    # a LIVE owner would read as dead.
    port_owner_pids() {
      netstat -ano 2>/dev/null | tr -d '\r' | grep -E ":(6550|6005)[^0-9]" 2>/dev/null | grep "LISTENING" 2>/dev/null | awk '{print $NF}' | sort -u || true
    }
    # True iff PID $1 still exists — the image-agnostic liveness probe that tells
    # a live zombie from a socket outliving the PID netstat names for it. tasklist
    # prints an "INFO: No tasks…" line (not an error) when nothing matches and
    # pads its output with a banner and CRs, so all of that is filtered out and
    # only the surviving data rows are counted.
    pid_alive() {
      { [ -n "${1:-}" ] && [ "$1" != "0" ]; } || return 1
      local rows
      rows="$(tasklist //FI "PID eq $1" 2>/dev/null \
        | tr -d '\r' \
        | grep -cviE "No tasks|^$|Image Name|^=" 2>/dev/null || true)"
      [ -n "$rows" ] && [ "$rows" != "0" ]
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
      # Liveness gate + dead-owner grace. A port still LISTENING with a LIVE
      # owner is the real zombie and drops straight through to the escalation
      # below, unchanged. A row naming a PID that is already gone (or naming no
      # owner at all) is not a process to begin with: the socket outlived its
      # creator, held open by a child that inherited the handle. Nothing by that
      # PID remains to kill, so the row is polled out in a bounded, kill-free
      # window rather than blamed on the editor. Only a row that outlives that
      # window is treated as survival.
      DEAD_OWNER_LINGER=0
      LINGER_WAITED=0
      LINGER_GRACE_SECS=10
      if [ "$(port_listening 6550)" != "0" ] || [ "$(port_listening 6005)" != "0" ]; then
        OWNER_ALIVE=0
        for pid in $(port_owner_pids); do
          { [ -n "$pid" ] && [ "$pid" != "0" ]; } || continue
          if pid_alive "$pid"; then
            OWNER_ALIVE=1
            break
          fi
        done
        if [ "$OWNER_ALIVE" = "0" ]; then
          DEAD_OWNER_LINGER=1
          while [ "$LINGER_WAITED" -lt "$LINGER_GRACE_SECS" ]; do
            [ "$(port_listening 6550)" = "0" ] && [ "$(port_listening 6005)" = "0" ] && break
            sleep 2
            LINGER_WAITED=$((LINGER_WAITED + 2))
          done
          if [ "$(port_listening 6550)" = "0" ] && [ "$(port_listening 6005)" = "0" ]; then
            echo "warm-up teardown: the LISTENING row named a PID that no longer exists (a socket outliving its creator, not a live process) and cleared after ${LINGER_WAITED}s; continuing."
          fi
        fi
      fi
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
          if [ "$DEAD_OWNER_LINGER" = "1" ]; then
            echo "NOTE: no LIVE owner was found when the grace window opened, and the row was STILL LISTENING ${LINGER_GRACE_SECS}s later — the socket has outlived the PID netstat names for it (a surviving child holding an inherited handle), so there is nothing by that PID to kill and the port-owner dump below is expected to be empty." >&2
          fi
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
