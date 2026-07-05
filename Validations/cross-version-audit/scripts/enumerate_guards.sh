#!/usr/bin/env bash
# enumerate_guards.sh --- (e) version-guard enumeration (the class-3/4 complement).
#
# Delta-driven grep (grep_delta_symbols.sh) only re-examines guards on symbols whose
# availability CHANGED across 4.2-4.7. A wrong-threshold guard on a symbol that is
# STABLE across all six versions appears in no delta, so it is never re-checked ---
# the exact blind spot assumption-class 3 targets. This script runs the inverse pass:
# enumerate EVERY version guard in the toolkit GDScript so each gated symbol can be
# resolved in the compat map and its threshold confirmed against the symbol's TRUE
# introduction version.
#
# It also enumerates the server's version-logic (class-4: min/max_godot_version,
# getGodotVersion branches, version-tailored hints) when the server repo is found.
#
# Output is file:line grouped by guard family --- feed each site to the compat map
# (lookup.py <symbol>) and confirm the threshold.
#
# Options:
#   --toolkit <dir>   toolkit repo root (default: sibling godot-mcp-toolkit)
#   --server  <dir>   server  repo root (default: sibling godot-mcp-server; skipped if absent)
#
# Usage:  bash enumerate_guards.sh
set -uo pipefail

TOOLKIT="${TOOLKIT:-C:/Users/nicol/OneDrive/Desktop/Personal/AIWithGodot/godot-mcp-toolkit}"
SERVER="${SERVER:-C:/Users/nicol/OneDrive/Desktop/Personal/AIWithGodot/godot-mcp-server}"
while [ $# -gt 0 ]; do
  case "$1" in
    --toolkit) TOOLKIT="$2"; shift 2;;
    --server)  SERVER="$2"; shift 2;;
    *) echo "unknown arg: $1"; exit 2;;
  esac
done
GD_ROOT="$TOOLKIT/addons/godot_mcp_toolkit"
[ -d "$GD_ROOT" ] || { echo "toolkit GDScript root not found: $GD_ROOT"; exit 1; }

section() { echo; echo "### $1"; }
# grep helper: prints "-- label: N" + each hit as a repo-relative file:line, and
# sets the global LAST_N to the hit count (so callers can total without consuming
# the detail output on a pipe).
LAST_N=0
count_pat() {  # <label> <root> <include-glob> <regex>
  local label="$1" root="$2" glob="$3" re="$4" hits n
  hits="$(grep -rnE "$re" "$root" --include="$glob" 2>/dev/null | grep -vE ':\s*#|://' || true)"
  n=$(printf '%s' "$hits" | grep -c . || true)
  echo "-- $label: $n"
  [ -n "$hits" ] && printf '%s\n' "$hits" | sed "s|$root/||"
  LAST_N="$n"
}

echo "========================================================================"
echo " TOOLKIT version guards (assumption-class 3) --- $GD_ROOT"
echo "========================================================================"
T_TOTAL=0
for spec in \
  "explicit version threshold (is_at_least/is_at_most/is_version_in_range)|(is_at_least|is_at_most|is_version_in_range)\s*\(" \
  "dynamic-dispatch existence (has_method)|has_method\s*\(" \
  "ClassDB existence (class_exists/class_has_method)|ClassDB\.(class_exists|class_has_method|class_has_integer_constant)\s*\(" \
  "property/signal probe (has_signal/get_property_list/in obj)|(has_signal\s*\(|has_property\s*\()" \
  "string-named dynamic call (.call/.callv with literal)|\.callv?\s*\(\s*\"" \
  "engine version read (get_version_info/get_engine_version_pair)|(get_version_info|get_engine_version_pair|Engine\.get_version_info)" \
  "feature detection (OS.has_feature)|OS\.has_feature\s*\(" \
; do
  label="${spec%%|*}"; re="${spec#*|}"
  section "$label"
  count_pat "$label" "$GD_ROOT" "*.gd" "$re"
  T_TOTAL=$((T_TOTAL + LAST_N))
done
# files touched by any guard
T_FILES=$(grep -rlE '(is_at_least|is_at_most|is_version_in_range)\s*\(|has_method\s*\(|ClassDB\.(class_exists|class_has_method)' "$GD_ROOT" --include=*.gd 2>/dev/null | wc -l | tr -d ' ')
echo
echo ">> toolkit guard sites (sum of families, may double-count a line matching two): $T_TOTAL across ~$T_FILES files"

if [ -d "$SERVER/src" ]; then
  echo
  echo "========================================================================"
  echo " SERVER version-logic (assumption-class 4) --- $SERVER/src"
  echo "========================================================================"
  S_TOTAL=0
  for spec in \
    "min/max godot version (schema + logic)|(min_godot_version|max_godot_version|minGodotVersion|maxGodotVersion|min_version|max_version)" \
    "runtime version read/branch (getGodotVersion/godotVersion)|(getGodotVersion|godotVersion|GODOT_VERSION|parseGodotVersion|compareVersions?)" \
    "version-tailored hint / gating|(version.*hint|gatedByVersion|requiresGodot|since 4\.|4\.[2-7]\+)" \
  ; do
    label="${spec%%|*}"; re="${spec#*|}"
    section "$label"
    count_pat "$label" "$SERVER/src" "*.ts" "$re"
    S_TOTAL=$((S_TOTAL + LAST_N))
  done
  S_FILES=$(grep -rlE '(min_godot_version|max_godot_version|getGodotVersion|godotVersion)' "$SERVER/src" --include=*.ts 2>/dev/null | wc -l | tr -d ' ')
  echo
  echo ">> server version-logic sites (sum of families): $S_TOTAL across ~$S_FILES files"
else
  echo; echo "(server repo not found at $SERVER --- skipping class-4 enumeration)"
fi
echo
echo "Resolve each gated symbol against the compat map:  python lookup.py <Class.member>"
