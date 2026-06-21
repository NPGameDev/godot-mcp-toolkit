#!/usr/bin/env bash
# verify_multi_instance.sh — autonomous, agent-agnostic multi-instance registry check.
#
# WHAT IT PROVES
#   The machine-wide registry (the toolkit's RegistryClient + its leaves
#   ProjectKey / RegistryPaths / RegistryEntryFile / RegistryProjection) works
#   LIVE across multiple real editor processes:
#     1. Aggregation — launch N editors (each a different project with the addon)
#        and assert projects.json aggregates ALL N instances (RegistryProjection
#        scanning + merging real entry files across processes).
#     2. End-to-end reach — drive a parameterized AGENT against each project and
#        assert the MCP server discovers + connects to the CORRECT editor via
#        registry lookup (ProjectKey hash -> projects.json -> port), not a
#        hardcoded port.
#   This is the Pass-3 live confirmation that complements the unit tests + the
#   static behavior-equivalence review (41n concern 039).
#
# AGENT-AGNOSTIC BY DESIGN
#   The agent invocation is a TEMPLATE (AGENT_CMD) with placeholders the script
#   substitutes per project: {MCP_CONFIG} {PROMPT} {SERVER_NAME}. The default is
#   `claude -p`, but any agent that can talk to the MCP server and print one line
#   works — success is detected by grepping the agent's stdout for the line
#   `PROJECT_NAME=<config/name>`, so nothing is coupled to a specific agent's
#   output format. Swap AGENT_CMD to test a different agent.
#
# USAGE
#   bash verify_multi_instance.sh [PROJECT_PATH ...]
#   (no args -> defaults to the toolkit repo root + the dogfood playground)
#
# ENV (all defaulted for this machine; override for portability / CI)
#   GODOT_BIN     editor binary (console exe on Windows so stdout is captured)
#   SERVER_DIST   path to godot-mcp-server dist/index.js
#   SERVER_NAME   MCP server name used in the generated config (default godot-mcp-toolkit)
#   REGISTRY_DIR  machine-wide registry dir
#   READY_TIMEOUT seconds to wait for projects.json to aggregate all N (default 120)
#   AGENT_CMD     agent command template; placeholders {MCP_CONFIG} {PROMPT} {SERVER_NAME}
#   TMPDIR_BASE   scratch dir for generated MCP configs + agent/editor logs
#
# EXIT CODES: 0 PASS · 1 a check failed · 2 preflight/setup error.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# pwd -W yields the Windows form (C:/Users/...) on git-bash so the derived key
# matches the registry's canonical key; plain pwd gives /c/Users/... which never
# matches. Falls back to pwd off-Windows.
TOOLKIT_ROOT="$(cd "$SCRIPT_DIR/../.." && { pwd -W 2>/dev/null || pwd; })"

GODOT_BIN="${GODOT_BIN:-C:/Users/nicol/Godot/Editors/4.5-stable/Godot_v4.5-stable_win64_console.exe}"
SERVER_DIST="${SERVER_DIST:-C:/Users/nicol/OneDrive/Desktop/Personal/AIWithGodot/godot-mcp-server/dist/index.js}"
SERVER_NAME="${SERVER_NAME:-godot-mcp-toolkit}"
REGISTRY_DIR="${REGISTRY_DIR:-C:/Users/nicol/AppData/Roaming/godot-mcp-toolkit}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"
TMPDIR_BASE="${TMPDIR_BASE:-${TEMP:-/tmp}/mcp-multiverify-$$}"
PLAYGROUND_DEFAULT="C:/Users/nicol/OneDrive/Desktop/Personal/AIWithGodot/godot-mcp-dogfood-playground"

# Default agent: claude -p. < /dev/null skips its 3s no-stdin wait. The agent is
# told to print PROJECT_NAME=NAME; the script greps for it (output-format agnostic).
DEFAULT_AGENT_CMD='claude -p "{PROMPT}" --mcp-config "{MCP_CONFIG}" --strict-mcp-config --allowedTools "mcp__{SERVER_NAME}" --output-format text < /dev/null'
AGENT_CMD="${AGENT_CMD:-$DEFAULT_AGENT_CMD}"

if [ "$#" -gt 0 ]; then PROJECTS=("$@"); else PROJECTS=("$TOOLKIT_ROOT" "$PLAYGROUND_DEFAULT"); fi
want="${#PROJECTS[@]}"
PJ="$REGISTRY_DIR/projects.json"

# Greppable, agent-agnostic prompt — no shell metacharacters (so eval is safe).
AGENT_PROMPT="You have MCP tools from a server named ${SERVER_NAME} that bridges to a running Godot editor. Call a read-only tool to read the project setting application/config/name, then print EXACTLY one line of the form PROJECT_NAME=NAME where NAME is the value you read, verbatim. Use at most 3 tool calls, then stop."

mkdir -p "$TMPDIR_BASE"
declare -a EDITOR_PIDS=()
FAIL=0
log(){ echo "[verify] $*"; }
fail(){ echo "[verify] FAIL: $*" >&2; FAIL=1; }

EDITOR_REAL_PIDS=""  # the editors' own PIDs (registry 'pid'); filled after aggregation
kill_pid(){ [ -n "${1:-}" ] || return 0; if command -v taskkill >/dev/null 2>&1; then taskkill //F //PID "$1" >/dev/null 2>&1 || true; else kill "$1" 2>/dev/null || true; fi; }
cleanup(){
  log "cleanup: closing editors + clearing registry"
  # The _console launcher (captured in $!) re-spawns + DETACHES the GUI editor, so
  # killing $! alone orphans the editor. Kill the editors' real PIDs the registry
  # recorded (entry 'pid' = the editor's OS.get_process_id()), then the launchers,
  # then a fallback sweep of anything still LISTENING on the toolkit port range
  # (NOTE: that sweep will close ANY toolkit editor in 6550-6560 — run this only
  # when no other toolkit editor you care about is open).
  local pid
  for pid in ${EDITOR_REAL_PIDS:-}; do kill_pid "$pid"; done
  for pid in "${EDITOR_PIDS[@]:-}"; do kill_pid "${pid:-}"; done
  for pid in $(netstat -ano 2>/dev/null | grep -iE "127\.0\.0\.1:65(5[0-9]|60)[^0-9].*listening" | awk '{print $NF}' | sort -u); do kill_pid "$pid"; done
  # A force-killed editor skips its _exit_tree deregister, leaving a stale entry — clear it.
  rm -f "$REGISTRY_DIR/entries/"*.json "$REGISTRY_DIR/projects.json" 2>/dev/null || true
}
trap cleanup EXIT

# Count toolkit editor WS listeners in the 6550-6560 range (editor mode, Mode A).
port_listening_count(){ netstat -ano 2>/dev/null | grep -icE "127\.0\.0\.1:65(5[0-9]|60)[^0-9].*listening"; }
# ProjectKey.canonical: lowercase (Win/macOS), backslash->slash, strip trailing /.
canon(){ printf '%s' "$1" | tr 'A-Z' 'a-z' | tr '\\' '/' | sed 's:/*$::'; }
# Exact JSON key-membership via node (robust where git-bash grep -F aborts; exact,
# not substring): is <key> a real by_path entry in projects.json?
key_present(){ [ -f "$PJ" ] && node -e 'const fs=require("fs");const bp=(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).by_path)||{};process.exit(Object.prototype.hasOwnProperty.call(bp,process.argv[2])?0:1)' "$PJ" "$1"; }
present_count(){ local n=0 p; for p in "${PROJECTS[@]}"; do key_present "$(canon "$p")" && n=$((n+1)); done; echo "$n"; }
# The editor's own PID for a given key (entry 'pid' = OS.get_process_id()) — used to
# kill the real GUI editor at cleanup (the $! launcher PID detaches it).
key_pid(){ [ -f "$PJ" ] && node -e 'const fs=require("fs");const e=((JSON.parse(fs.readFileSync(process.argv[1],"utf8")).by_path)||{})[process.argv[2]];if(e&&e.pid)console.log(e.pid)' "$PJ" "$1" 2>/dev/null; }

# ---- preflight ----
[ -f "$GODOT_BIN" ] || { fail "editor binary not found: $GODOT_BIN (set GODOT_BIN)"; exit 2; }
[ -f "$SERVER_DIST" ] || { fail "server dist not found: $SERVER_DIST (run npm run build; set SERVER_DIST)"; exit 2; }
command -v node >/dev/null 2>&1 || { fail "node not on PATH"; exit 2; }
for p in "${PROJECTS[@]}"; do
  [ -f "$p/project.godot" ] || { fail "no project.godot in $p"; exit 2; }
  [ -f "$p/addons/godot_mcp_toolkit/plugin.cfg" ] || { fail "godot_mcp_toolkit addon not installed in $p"; exit 2; }
done
log "projects ($want): ${PROJECTS[*]}"

# ---- 1. clean slate ----
# Wait out any prior run's editors still dying (their ports/entries would race us).
log "waiting for a clean port slate (no 6550-6560 listeners)..."
for _ in $(seq 1 30); do [ "$(port_listening_count)" -eq 0 ] && break; sleep 1; done
[ "$(port_listening_count)" -eq 0 ] || log "  WARN: ports still busy after 30s; proceeding"
log "clearing registry: $REGISTRY_DIR"
rm -f "$REGISTRY_DIR/entries/"*.json "$REGISTRY_DIR/projects.json" 2>/dev/null || true
mkdir -p "$REGISTRY_DIR/entries"

# ---- 2. launch editors ----
for p in "${PROJECTS[@]}"; do
  log "launching editor: $p"
  "$GODOT_BIN" --path "$p" --editor >"$TMPDIR_BASE/editor-$(basename "$p").log" 2>&1 &
  EDITOR_PIDS+=("$!")
done

# ---- 3. wait until projects.json aggregates ALL projects (the real readiness +
#         the assertion in one — avoids the port-bound-before-register race) ----
log "waiting for projects.json to aggregate all $want project(s) (timeout ${READY_TIMEOUT}s)..."
for _ in $(seq 1 "$READY_TIMEOUT"); do [ "$(present_count)" -ge "$want" ] && break; sleep 1; done
got="$(present_count)"
# Capture the editors' real PIDs now (registry has them) so cleanup can kill the
# detached GUI processes on BOTH the pass and fail paths.
EDITOR_REAL_PIDS="$(for p in "${PROJECTS[@]}"; do key_pid "$(canon "$p")"; done)"
if [ "$got" -ge "$want" ]; then
  log "aggregation PASS: $got/$want project(s) present in projects.json"
  for p in "${PROJECTS[@]}"; do log "  aggregated: $(canon "$p")"; done
else
  fail "only $got/$want project(s) aggregated after ${READY_TIMEOUT}s (ports up: $(port_listening_count)/$want; projects.json: $([ -f "$PJ" ] && echo present || echo absent))"
  for p in "${PROJECTS[@]}"; do k="$(canon "$p")"; key_present "$k" && log "  present: $k" || log "  MISSING: $k"; done
fi

# ---- 4. per-project agent reach (parameterized template -> agent-agnostic) ----
i=0
for p in "${PROJECTS[@]}"; do
  i=$((i+1))
  expected="$(grep -m1 '^config/name=' "$p/project.godot" | sed -E 's/^config\/name="?([^"]*)"?.*/\1/')"
  cfg="$TMPDIR_BASE/mcp-$i.json"
  cat >"$cfg" <<JSON
{ "mcpServers": { "$SERVER_NAME": { "command": "node", "args": ["$SERVER_DIST"],
  "env": { "GODOT_MCP_CONFIG_VERSION": "1", "GODOT_MCP_PROJECT_PATH": "$p" } } } }
JSON
  cmd="$AGENT_CMD"
  cmd="${cmd//\{MCP_CONFIG\}/$cfg}"
  cmd="${cmd//\{SERVER_NAME\}/$SERVER_NAME}"
  cmd="${cmd//\{PROMPT\}/$AGENT_PROMPT}"
  log "agent reach [$i/$want]: expect project '$expected' (server discovers port via registry)"
  out="$TMPDIR_BASE/agent-$i.out"
  eval "$cmd" >"$out" 2>&1 || true
  if grep -qF "PROJECT_NAME=$expected" "$out"; then
    log "  PASS: agent reached '$expected'"
  else
    fail "agent [$i] did not confirm reaching '$expected' — see $out"; tail -4 "$out" >&2
  fi
done

# ---- 5. report ----
if [ "$FAIL" -eq 0 ]; then
  log "RESULT: PASS — $want instances aggregated in projects.json + each agent-reachable via registry discovery"
else
  log "RESULT: FAIL (logs in $TMPDIR_BASE)"
fi
exit "$FAIL"
