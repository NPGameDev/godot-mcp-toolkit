#!/usr/bin/env bash
# dump_api.sh --- (a) the dump wrapper of the cross-version audit harness.
#
# Runs `godot --headless --dump-extension-api` for each supported Godot version
# (standard editors 4.2-4.7, plus the four installed .NET/mono editors) and
# collects each version's `extension_api.json` into a temp dump root. These raw
# dumps are multi-MB and are REGENERATED, never committed (see the repo-root
# .gitignore for cross-version-audit). The distilled compat map built from them
# (build_compat_map.py) is what gets committed.
#
# Gotchas baked in (do not remove):
#   * Godot is NOT on PATH --- binaries are resolved by glob under EDITORS_ROOT.
#   * `--dump-extension-api` writes extension_api.json to the CWD --- we cd into
#     a per-version dir before each run.
#   * NEVER run two Godot headless processes at once (Windows project-lock /
#     reimport contention) --- this loop is strictly sequential.
#   * Each run is wrapped with `timeout` (the GNU coreutils one; on Git-Bash for
#     Windows that is /usr/bin/timeout, NOT System32\timeout.exe).
#
# Env overrides:
#   EDITORS_ROOT  default: C:/Users/nicol/Godot/Editors
#   DUMPROOT      default: C:/Users/nicol/OneDrive/Desktop/Personal/AIWithGodot/_TempForClaude/xversion-dumps
#   FORCE=1       re-dump even if a non-empty extension_api.json already exists
#
# Usage:  bash dump_api.sh
set -uo pipefail

EDITORS_ROOT="${EDITORS_ROOT:-C:/Users/nicol/Godot/Editors}"
DUMPROOT="${DUMPROOT:-C:/Users/nicol/OneDrive/Desktop/Personal/AIWithGodot/_TempForClaude/xversion-dumps}"
FORCE="${FORCE:-0}"
TIMEOUT_BIN="/usr/bin/timeout"
[ -x "$TIMEOUT_BIN" ] || TIMEOUT_BIN="timeout"

STD_VERSIONS="4.2 4.3 4.4 4.5 4.6 4.7"
NET_VERSIONS="4.2 4.5 4.6 4.7"   # only these .NET editors are installed

# Resolve a standard editor dir for a major.minor: prefer exact "<mm>-stable",
# else the highest-patch "<mm>.N-stable" (never a NET- dir).
resolve_std_dir() {
  local mm="$1"
  if [ -d "$EDITORS_ROOT/$mm-stable" ]; then echo "$EDITORS_ROOT/$mm-stable"; return 0; fi
  ls -d "$EDITORS_ROOT/$mm."*-stable 2>/dev/null | grep -vi 'NET-' | sort -V | tail -1
}
# Resolve a mono editor dir: prefer "NET-<mm>-stable", else "NET-<mm>.N-stable".
resolve_net_dir() {
  local mm="$1"
  if [ -d "$EDITORS_ROOT/NET-$mm-stable" ]; then echo "$EDITORS_ROOT/NET-$mm-stable"; return 0; fi
  ls -d "$EDITORS_ROOT/NET-$mm."*-stable 2>/dev/null | sort -V | tail -1
}
# Find the *_console.exe inside an editor dir (std or mono).
resolve_bin() {
  ls "$1"/*_win64_console.exe 2>/dev/null | head -1
}

dump_one() {  # <label> <editor-dir>
  local label="$1" dir="$2"
  local out="$DUMPROOT/$label"
  local bin; bin="$(resolve_bin "$dir")"
  if [ -z "$bin" ]; then echo "  [$label] SKIP --- no console binary under $dir"; return 1; fi
  if [ "$FORCE" != "1" ] && [ -s "$out/extension_api.json" ]; then
    echo "  [$label] cached ($(wc -c < "$out/extension_api.json") bytes) --- FORCE=1 to redump"; return 0
  fi
  mkdir -p "$out"
  ( cd "$out" && "$TIMEOUT_BIN" 180 "$bin" --headless --dump-extension-api >/dev/null 2>&1 )
  if [ -s "$out/extension_api.json" ]; then
    echo "  [$label] OK ($(wc -c < "$out/extension_api.json") bytes)  <- $(basename "$bin")"
  else
    echo "  [$label] FAIL --- no extension_api.json produced by $bin"; return 1
  fi
}

echo "== Standard editor dumps (GDScript surface) =="
for v in $STD_VERSIONS; do dump_one "$v" "$(resolve_std_dir "$v")"; done
echo "== Mono editor dumps (.NET consistency) =="
for v in $NET_VERSIONS; do dump_one "net-$v" "$(resolve_net_dir "$v")"; done
echo "Done. Dumps under: $DUMPROOT"
