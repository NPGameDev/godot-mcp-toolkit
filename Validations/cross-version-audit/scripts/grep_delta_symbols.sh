#!/usr/bin/env bash
# grep_delta_symbols.sh --- (d) GDScript delta-symbol grep.
#
# The delta-driven half of the audit: intersect the compat-map DELTA symbols
# (members added/removed/drifted across 4.2-4.7 --- the non-`class` rows of
# compat-map.tsv) with the member tokens actually used in the toolkit's GDScript.
# Every hit is a place the toolkit touches a version-varying symbol --- the
# per-version audit agents confirm each has a correct guard.
#
# GDScript is dynamically typed, so a bare `.member` token can't be pinned to a
# receiver class from source alone. This script therefore reports CANDIDATE usages
# (member-name match) with the symbol's full name + per-version presence + intro;
# the agent judges whether the receiver is really that class. Common names
# (`close`, `play`, ...) over-match by design --- a candidate list, not a verdict.
#
# Options:
#   --version <v>   restrict to symbols ABSENT in <v> (the sharpest class-1 view:
#                   "toolkit uses a symbol missing in <v>").
#   --toolkit <dir> toolkit repo root (default: sibling godot-mcp-toolkit).
#
# Usage:
#   bash grep_delta_symbols.sh
#   bash grep_delta_symbols.sh --version 4.2
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AUDIT_DIR="$(dirname "$HERE")"
TSV="$AUDIT_DIR/compat-map.tsv"
TOOLKIT="${TOOLKIT:-C:/Users/nicol/OneDrive/Desktop/Personal/AIWithGodot/godot-mcp-toolkit}"
VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2;;
    --toolkit) TOOLKIT="$2"; shift 2;;
    *) echo "unknown arg: $1"; exit 2;;
  esac
done
[ -f "$TSV" ] || { echo "compat-map.tsv not found ($TSV) --- run build_compat_map.py first"; exit 1; }
GD_ROOT="$TOOLKIT/addons/godot_mcp_toolkit"
[ -d "$GD_ROOT" ] || { echo "toolkit GDScript root not found: $GD_ROOT"; exit 1; }

# version index (0-based) for presence-string filtering
declare -A VIDX=( [4.2]=0 [4.3]=1 [4.4]=2 [4.5]=3 [4.6]=4 [4.7]=5 )

# 1) member tokens actually used in the toolkit (dotted access/calls), unique.
USED="$(mktemp)"
grep -rohE '\.[A-Za-z_][A-Za-z0-9_]*' "$GD_ROOT" --include=*.gd 2>/dev/null \
  | sed 's/^\.//' | sort -u > "$USED"

# 2) walk delta rows; for member symbols whose member-name is used, report.
echo "== delta symbols used by the toolkit${VERSION:+ (absent in $VERSION)} =="
awk -F'\t' -v used="$USED" -v ver="$VERSION" -v vidx="${VIDX[${VERSION:-4.2}]}" '
  BEGIN { while ((getline u < used) > 0) U[u]=1 }
  NR==1 { next }                              # header
  $1=="class" { next }                        # class rows are not member deltas
  {
    sym=$2; present=$3; intro=$4; note=$5
    if (sym ~ /^@/) next                       # globals handled separately below
    n=split(sym, parts, "."); member=parts[n]
    if (!(member in U)) next
    if (ver != "") {                           # restrict to absent-in-<ver>
      if (substr(present, vidx+1, 1) == "Y") next
    }
    printf "  %-55s present=%s intro=%s  [%s]\n", sym, present, intro, note
  }
' "$TSV" | sort -u

# 3) global utility functions (called bare, not dotted).
echo "== global utility-function / singleton deltas used by the toolkit =="
awk -F'\t' '$1=="utility_function" || $1=="singleton" { print $2 }' "$TSV" | while read -r g; do
  name="${g#@util:}"; name="${name#@singleton:}"
  if grep -rqwE "$name" "$GD_ROOT" --include=*.gd 2>/dev/null; then
    line="$(awk -F'\t' -v s="$g" '$2==s{printf "present=%s intro=%s [%s]", $3,$4,$5}' "$TSV")"
    echo "  $g  $line"
  fi
done
rm -f "$USED"
echo "Done. (Candidate usages --- confirm receiver class per site.)"
