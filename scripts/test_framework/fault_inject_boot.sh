#!/usr/bin/env bash
# scripts/test_framework/fault_inject_boot.sh
#
# Fault-injection harness for the CI boot-robustness hardening: the bounded boot
# retry, the Windows kill-verify escalation, the WS port-agility fallback, and the
# LSP-consumer-aware hard-stop. It validates the SHELL control flow deterministically
# with FAKE editor binaries — no real Godot needed (the retry/kill/port logic is
# orthogonal to what the engine does), so it is a fast, reproducible proof.
#
# What it exercises:
#   run_units_cold.sh (sibling, this repo) — warm-up boot retry + teardown:
#     T1  forced boot-fail  -> 3 bounded attempts then clean exit 2 + forensics
#     T3  kill-verify        -> a held port is escalation-killed, no false "survived"
#     T4  port-agility       -> a PERSISTENT 6550 holder -> relocate + export, no fail
#     T5a LSP hard-stop      -> a persistent 6005 holder + GODOT_WARM_ONLY -> exit 2
#     T5b LSP warn-only      -> a persistent 6005 holder, no consumer -> warn, continue
#     T6  silent-when-healthy-> no held ports -> zero warnings
#   cross-version-behavioral/action.yml (sibling server repo, if present) — main boot,
#   tested via bash EXTRACTION of the composite `run:` block (it is GitHub-YAML and
#   cannot execute as-is; inputs.* are substituted with locals):
#     C1  forced boot-fail  -> 3 bounded attempts then ::error:: + exit 1
#     C2  reap-kill path     -> between-attempt reap kills the poll-port owner (the
#                              fixed winpid+port-owner path, NOT the inert //IM kill)
#     C3  relocation breadcrumb -> POLL_PORT != 6550 prints the NOTE line
#     C4  healthy boot        -> port served on attempt 1 -> zero warnings, exit 0
#
# Windows-only cases (T3/T4/T5/C2) are SKIPPED on non-Windows, where the teardown
# escalation branch (case $(uname -s) MINGW) does not execute anyway.
#
# Safety: aborts if 6550/6005 are already held at start (it force-kills port owners,
# so nothing real may be squatting them). Creates its own throwaway project + fakes
# in a mktemp dir; a trap frees ports, kills spawned jobs, and deletes the scratch.
#
# Usage:  bash scripts/test_framework/fault_inject_boot.sh [path/to/action.yml]
# Exit 0 = all non-skipped cases PASS, 1 = at least one FAIL/setup error.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARM_SCRIPT="$SCRIPT_DIR/run_units_cold.sh"
TOOLKIT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSITE="${1:-$TOOLKIT_ROOT/../godot-mcp-server/.github/actions/cross-version-behavioral/action.yml}"

is_windows() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac; }
if is_windows; then TIMEOUT_BIN=/usr/bin/timeout; else TIMEOUT_BIN=timeout; fi

PASS=0; FAIL=0; SKIP=0
BG_PIDS=()
SCRATCH=""

port_owners() { # $1=port -> LISTENING owner PID(s)
  if is_windows; then
    netstat -ano 2>/dev/null | grep -E ":$1[^0-9]" 2>/dev/null | grep "LISTENING" 2>/dev/null | awk '{print $NF}' | sort -u
  else
    { ss -ltnp 2>/dev/null || true; } | grep -E ":$1[^0-9]" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
  fi
}
port_held() { [ -n "$(port_owners "$1")" ] && echo 1 || echo 0; }
kill_port() { # $1=port
  local pid
  for pid in $(port_owners "$1"); do
    if is_windows; then taskkill //F //T //PID "$pid" >/dev/null 2>&1 || true
    else kill -9 "$pid" 2>/dev/null || true; fi
  done
}
wait_held() { local p; for _ in $(seq 1 30); do [ "$(port_held "$1")" = "1" ] && return 0; sleep 0.3; done; return 1; }

cleanup() {
  local p port
  # Kill supervisors FIRST (stop respawns), then sweep the ports until free so no
  # orphaned listener outlives the harness (a persistent holder respawns otherwise).
  for p in "${BG_PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; kill -9 "$p" 2>/dev/null || true; done
  for port in 6550 6005 6551; do
    for _ in 1 2 3 4 5; do
      kill_port "$port"
      [ "$(port_held "$port")" = "0" ] && break
      sleep 0.3
    done
  done
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

record() { # $1=name $2=PASS/FAIL/SKIP $3=detail
  case "$2" in
    PASS) PASS=$((PASS + 1)) ;;
    FAIL) FAIL=$((FAIL + 1)) ;;
    SKIP) SKIP=$((SKIP + 1)) ;;
  esac
  printf '[%s] %s — %s\n' "$2" "$1" "$3"
}
has() { grep -qF "$1" "$SCRATCH/out.txt"; }
# grep -c prints "0" AND exits 1 on no-match, so `|| true` (NOT `|| echo 0`, which
# would print a SECOND "0" and break `= "0"` comparisons).
cnt() { grep -cF "$1" "$SCRATCH/out.txt" 2>/dev/null || true; }
evidence() { grep -F "$1" "$SCRATCH/out.txt" 2>/dev/null | head -n "${2:-3}" | sed 's/^/    > /'; }

# ── Persistent (respawning) port holder: a supervisor re-binds instantly whenever
# the escalation kills the listener, so the port stays held across the whole
# kill-verify window (also exercises re-resolve-owner-per-sample). ──
start_persistent_holder() { # $1=port -> supervisor bg pid
  # Bounded respawner: re-binds $1 whenever the escalation kills the listener, so the
  # port survives the whole kill-verify window (forces the port-agility / LSP branch).
  # LEAK-SAFE by construction — each node self-exits after 40s and the supervisor
  # loop stops after ~50s, so even an uncaught kill of the harness frees the port
  # within ~90s instead of the UNBOUNDED leak an infinite respawner would cause.
  # The window comfortably outlives one test case (warm-up + ~10s escalation ≈ 15s).
  # The subshell's OWN stdout is redirected off the command-substitution pipe, or
  # `$(start_persistent_holder ...)` blocks forever on the never-closing pipe (the
  # subshell would otherwise inherit and hold it open).
  ( deadline=$(( $(date +%s) + 50 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      node -e 'const n=require("net");const s=n.createServer();s.on("error",()=>process.exit(1));s.listen(+process.argv[1],"127.0.0.1",()=>{});setTimeout(()=>process.exit(0),40000)' "$1" 2>/dev/null || true
    done ) >/dev/null 2>&1 &
  local sup=$!
  BG_PIDS+=("$sup")
  echo "$sup"
}
start_one_shot_holder() { # $1=port -> node bg pid (dies on first kill, no respawn)
  node -e 'const n=require("net");n.createServer().listen(+process.argv[1],"127.0.0.1",()=>{});setInterval(()=>{},1e9)' "$1" >/dev/null 2>&1 &
  local pid=$!
  BG_PIDS+=("$pid")
  echo "$pid"
}
stop_holder() { # $1=supervisor-or-listener pid  $2=port
  # Kill the supervisor FIRST (stops the respawn loop), then re-kill the port owner
  # each pass until free — a persistent holder can respawn one last node between the
  # supervisor kill and the port kill, so a single kill_port can race and miss it.
  kill "$1" 2>/dev/null || true
  kill -9 "$1" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill_port "$2"
    [ "$(port_held "$2")" = "0" ] && break
    sleep 0.3
  done
}

reset_proj() { rm -rf "$SCRATCH/proj/.godot" 2>/dev/null || true; : > "$SCRATCH/genv.txt"; }

run_warm() { # env assignments... ; runs run_units_cold.sh in the scratch proj
  reset_proj
  ( cd "$SCRATCH/proj" && env "$@" "$TIMEOUT_BIN" 150 bash "$WARM_SCRIPT" ) > "$SCRATCH/out.txt" 2>&1
  RC=$?
}
run_boot() { # env assignments... ; runs the EXTRACTED composite boot step
  ( cd "$SCRATCH/proj" && env "$@" "$TIMEOUT_BIN" 150 bash "$SCRATCH/boot.sh" ) > "$SCRATCH/out.txt" 2>&1
  RC=$?
}

# ── Setup ──────────────────────────────────────────────────────────────────────
if [ ! -f "$WARM_SCRIPT" ]; then echo "SETUP FAIL: run_units_cold.sh not found at $WARM_SCRIPT"; exit 1; fi
if [ "$(port_held 6550)" = "1" ] || [ "$(port_held 6005)" = "1" ]; then
  echo "SETUP ABORT: 6550/6005 already held — refusing to run (this harness force-kills port owners)."
  exit 1
fi
command -v node >/dev/null 2>&1 || { echo "SETUP FAIL: node required for port holders"; exit 1; }

SCRATCH="$(mktemp -d)"
mkdir -p "$SCRATCH/proj" "$SCRATCH/bin"
: > "$SCRATCH/proj/project.godot"

# fake that dies instantly (never writes the class cache) — the boot-crash analogue
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCRATCH/fake_die.sh"
# fake that writes the cache then idles (so the warm-up finds the artifact + kills it);
# on the unit-runner invocation (--script) it exits 0 to simulate a passing suite
cat > "$SCRATCH/fake_cache.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p .godot
: > .godot/global_script_class_cache.cfg
for a in "$@"; do [ "$a" = "--script" ] && exit 0; done
sleep 30
EOF
# fake that BINDS the poll port and idles — a healthy composite boot
cat > "$SCRATCH/fake_bind.sh" <<'EOF'
#!/usr/bin/env bash
node -e 'require("net").createServer().listen(+(process.env.POLL_PORT||6550),"127.0.0.1",()=>{});setInterval(()=>{},1e9)'
EOF
chmod +x "$SCRATCH"/fake_*.sh

echo "=============================================================="
echo " Fault-injection: CI boot-robustness hardening"
echo " scratch: $SCRATCH"
echo " warm:    $WARM_SCRIPT"
echo "=============================================================="

# ── T1: forced boot-fail (warm-up) -> 3 bounded attempts, clean exit 2 ──────────
run_warm GODOT_BIN="$SCRATCH/fake_die.sh" GITHUB_ACTIONS=true GODOT_WARM_ONLY=1
n=$(cnt "::warning::warm-up boot attempt")
if [ "$RC" = "2" ] && [ "$n" = "3" ] && has "editor process died during scan" && has "cache written: no"; then
  record "T1 forced-boot-fail (warm-up)" PASS "3 bounded attempts, exit 2, forensics present"
else
  record "T1 forced-boot-fail (warm-up)" FAIL "rc=$RC warn-lines=$n"
fi
evidence "::warning::warm-up boot attempt"

# ── T6: silent-when-healthy (warm-up) -> zero warnings ──────────────────────────
run_warm GODOT_BIN="$SCRATCH/fake_cache.sh" GITHUB_ACTIONS=true GODOT_WARM_ONLY=1
if [ "$RC" = "0" ] && has "cache written: yes" \
   && [ "$(cnt "::warning::")" = "0" ] && [ "$(cnt "force-killing")" = "0" ] && [ "$(cnt "relocated")" = "0" ]; then
  record "T6 silent-when-healthy (warm-up)" PASS "exit 0, cache yes, zero warning/kill/relocate lines"
else
  record "T6 silent-when-healthy (warm-up)" FAIL "rc=$RC warnings=$(cnt "::warning::") kills=$(cnt "force-killing")"
fi

# ── Windows-only teardown cases ─────────────────────────────────────────────────
if is_windows; then
  # T3: kill-verify — a one-shot 6550 holder must be escalation-killed, port freed,
  # no false ZOMBIE-survived, run proceeds.
  h=$(start_one_shot_holder 6550)
  if wait_held 6550; then
    run_warm GODOT_BIN="$SCRATCH/fake_cache.sh" GITHUB_ACTIONS=true GODOT_WARM_ONLY=1
    if [ "$RC" = "0" ] && has "force-killing port-owner PID" && ! has "ZOMBIE survived" && [ "$(port_held 6550)" = "0" ]; then
      record "T3 kill-verify escalation" PASS "escalation fired, 6550 freed, exit 0, no false survival"
    else
      record "T3 kill-verify escalation" FAIL "rc=$RC held6550=$(port_held 6550) survived=$(cnt "ZOMBIE survived")"
    fi
    evidence "force-killing port-owner PID"
  else
    record "T3 kill-verify escalation" FAIL "could not stand up 6550 holder"
  fi
  stop_holder "$h" 6550

  # T4: port-agility — a PERSISTENT 6550 holder survives escalation -> relocate + export.
  h=$(start_persistent_holder 6550)
  if wait_held 6550; then
    run_warm GODOT_BIN="$SCRATCH/fake_cache.sh" GITHUB_ACTIONS=true GODOT_WARM_ONLY=1 GITHUB_ENV="$SCRATCH/genv.txt"
    if [ "$RC" = "0" ] && has "WS port 6550 still held" && has "pinning the next editor boot to spare port" \
       && grep -qE '^GODOT_MCP_EDITOR_PORT=(655[1-9]|6560)$' "$SCRATCH/genv.txt"; then
      record "T4 port-agility (6550)" PASS "relocated + GODOT_MCP_EDITOR_PORT exported to GITHUB_ENV, exit 0"
    else
      record "T4 port-agility (6550)" FAIL "rc=$RC genv=[$(cat "$SCRATCH/genv.txt" 2>/dev/null)]"
    fi
    evidence "pinning the next editor boot to spare port"
    grep -E '^GODOT_MCP_EDITOR_PORT=' "$SCRATCH/genv.txt" 2>/dev/null | sed 's/^/    GITHUB_ENV> /'
  else
    record "T4 port-agility (6550)" FAIL "could not stand up persistent 6550 holder"
  fi
  stop_holder "$h" 6550

  # T5a: LSP hard-stop — persistent 6005 holder + downstream consumer -> exit 2.
  h=$(start_persistent_holder 6005)
  if wait_held 6005; then
    run_warm GODOT_BIN="$SCRATCH/fake_cache.sh" GITHUB_ACTIONS=true GODOT_WARM_ONLY=1
    if [ "$RC" = "2" ] && has "ZOMBIE survived force-kill — 6005"; then
      record "T5a LSP 6005 retry-then-fail" PASS "exit 2 with 6005 LSP forensics (consumer present)"
    else
      record "T5a LSP 6005 retry-then-fail" FAIL "rc=$RC (expected 2 + '6005' forensics)"
    fi
    evidence "ZOMBIE survived force-kill"
  else
    record "T5a LSP 6005 retry-then-fail" FAIL "could not stand up persistent 6005 holder"
  fi
  stop_holder "$h" 6005

  # T5b: LSP warn-only — persistent 6005 holder, NO downstream consumer -> warn, continue.
  h=$(start_persistent_holder 6005)
  if wait_held 6005; then
    run_warm GODOT_BIN="$SCRATCH/fake_cache.sh" GITHUB_ACTIONS=true
    if [ "$RC" = "0" ] && has "LSP port 6005 still held after force-kill, but no downstream LSP consumer"; then
      record "T5b LSP 6005 warn-only (no consumer)" PASS "warned + continued to unit runner, exit 0"
    else
      record "T5b LSP 6005 warn-only (no consumer)" FAIL "rc=$RC (expected 0 + warn-only)"
    fi
    evidence "no downstream LSP consumer"
  else
    record "T5b LSP 6005 warn-only (no consumer)" FAIL "could not stand up persistent 6005 holder"
  fi
  stop_holder "$h" 6005
else
  record "T3/T4/T5 Windows teardown cases" SKIP "not MINGW/MSYS — escalation branch inert off Windows"
fi

# ── Composite boot-step cases (extracted from the server action.yml) ────────────
if [ -f "$COMPOSITE" ] && command -v python >/dev/null 2>&1; then
  python - "$COMPOSITE" "$SCRATCH/boot.sh" "$(is_windows && echo windows || echo linux)" <<'PY'
import re, sys
ay, out, osval = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(ay, encoding="utf-8").read().splitlines()
start = next(i for i, l in enumerate(lines) if "Launch headless editor + poll WS port (bounded retry)" in l)
ri = next(i for i in range(start, len(lines)) if lines[i].strip() == "run: |")
block = []; base = None
for l in lines[ri + 1:]:
    if l.strip() == "":
        block.append(""); continue
    ind = len(l) - len(l.lstrip())
    if base is None: base = ind
    if ind < base and l.strip(): break
    block.append(l[base:])
body = "\n".join(block)
body = re.sub(r"\$\{\{\s*inputs\.os\s*\}\}", osval, body)
body = re.sub(r"\$\{\{\s*inputs\.godot-version\s*\}\}", "4.2.0", body)
body = re.sub(r"\$\{\{\s*inputs\.project-path\s*\}\}", ".", body)
open(out, "w", encoding="utf-8", newline="\n").write("#!/usr/bin/env bash\nset -eo pipefail\n" + body + "\n")
print("extracted", len(block), "lines")
PY
  cp "$SCRATCH/fake_die.sh" "$SCRATCH/bin/godot"; chmod +x "$SCRATCH/bin/godot"

  # C1: forced boot-fail -> 3 attempts, ::error::, exit 1
  run_boot PATH="$SCRATCH/bin:$PATH" GITHUB_ACTIONS=true GITHUB_ENV="$SCRATCH/genv.txt"
  n=$(cnt "::warning::boot attempt")
  if [ "$RC" != "0" ] && [ "$n" = "3" ] && has "::error::editor failed to boot"; then
    record "C1 composite forced-boot-fail" PASS "3 bounded attempts, ::error::, exit $RC"
  else
    record "C1 composite forced-boot-fail" FAIL "rc=$RC warn-lines=$n"
  fi
  evidence "::warning::boot attempt"

  # C2 (Windows): reap-kill uses the poll-port-owner path (not the inert //IM kill)
  if is_windows; then
    h=$(start_one_shot_holder 6550)
    if wait_held 6550; then
      run_boot PATH="$SCRATCH/bin:$PATH" GITHUB_ACTIONS=true GITHUB_ENV="$SCRATCH/genv.txt"
      if has "boot retry: force-killing LISTENING owner of port 6550"; then
        record "C2 composite reap-kill (port-owner path)" PASS "between-attempt reap killed the 6550 owner"
      else
        record "C2 composite reap-kill (port-owner path)" FAIL "reap did not log the port-owner kill"
      fi
      evidence "boot retry: force-killing LISTENING owner"
    else
      record "C2 composite reap-kill (port-owner path)" FAIL "could not stand up 6550 holder"
    fi
    stop_holder "$h" 6550
  else
    record "C2 composite reap-kill (port-owner path)" SKIP "Windows-only reap branch"
  fi

  # C3: relocation breadcrumb — POLL_PORT != 6550 prints the NOTE
  run_boot PATH="$SCRATCH/bin:$PATH" GODOT_MCP_EDITOR_PORT=6551 GITHUB_ACTIONS=true GITHUB_ENV="$SCRATCH/genv.txt"
  if has "NOTE: main editor intentionally relocated to port 6551"; then
    record "C3 composite relocation breadcrumb" PASS "NOTE naming 6551 emitted"
  else
    record "C3 composite relocation breadcrumb" FAIL "breadcrumb not printed"
  fi
  evidence "NOTE: main editor intentionally relocated"

  # C4: healthy boot — port served on attempt 1 -> zero warnings, exit 0
  cp "$SCRATCH/fake_bind.sh" "$SCRATCH/bin/godot"; chmod +x "$SCRATCH/bin/godot"
  run_boot PATH="$SCRATCH/bin:$PATH" GITHUB_ACTIONS=true GITHUB_ENV="$SCRATCH/genv.txt"
  if [ "$RC" = "0" ] && [ "$(cnt "::warning::")" = "0" ] && [ "$(cnt "::error::")" = "0" ]; then
    record "C4 composite healthy boot" PASS "served on attempt 1, zero warnings, exit 0"
  else
    record "C4 composite healthy boot" FAIL "rc=$RC warnings=$(cnt "::warning::")"
  fi
  kill_port 6550; kill_port 6551
  cp "$SCRATCH/fake_die.sh" "$SCRATCH/bin/godot"; chmod +x "$SCRATCH/bin/godot"  # restore
else
  record "C1-C4 composite boot-step cases" SKIP "composite YAML or python not available ($COMPOSITE)"
fi

echo "=============================================================="
echo " RESULT: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
echo "=============================================================="
[ "$FAIL" = "0" ]
