#!/usr/bin/env bash
# run_all.sh --- one-shot, idempotent cross-version audit harness pipeline.
#
# Regenerates the raw dumps (if missing), rebuilds the committed compat map, and
# runs the .NET cross-diff. Re-runnable: cached dumps are reused (FORCE=1 to
# redump). The per-version + guard passes (grep_delta_symbols.sh /
# enumerate_guards.sh) are printed at the end for a human/agent to consume.
#
#   Stage 1  dump_api.sh          --- extension_api.json x6 (+4 mono) -> DUMPROOT
#   Stage 2  build_compat_map.py  --- compat-map.json/.tsv + delta-report.md (COMMITTED)
#   Stage 3  cross_diff_dotnet.py --- reflect GodotSharp x4 + reflect-vs-manifest diff
#   Stage 4  (report) grep_delta_symbols.sh + enumerate_guards.sh
#
# Gotchas: Godot is not on PATH and headless runs must never overlap --- dump_api.sh
# handles both (explicit binaries, strictly sequential). Never run two copies of
# this script at once.
#
# Usage:  bash run_all.sh            (FORCE=1 bash run_all.sh to redump)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "########## Stage 1/4 : dump extension_api.json (sequential headless) ##########"
bash "$HERE/dump_api.sh" || { echo "dump stage failed"; exit 1; }

echo; echo "########## Stage 2/4 : build distilled compat map ##########"
python "$HERE/build_compat_map.py" || { echo "compat-map build failed"; exit 1; }

echo; echo "########## Stage 3/4 : .NET reflect + cross-diff ##########"
python "$HERE/cross_diff_dotnet.py" || echo "(.NET cross-diff reported divergence --- review above)"

echo; echo "########## Stage 4/4 : delta-symbol grep + guard enumeration (report) ##########"
echo "--- toolkit delta-symbol usage (all versions) ---"
bash "$HERE/grep_delta_symbols.sh" 2>&1 | tail -n +1 | head -40
echo "--- version-guard enumeration (summary) ---"
bash "$HERE/enumerate_guards.sh" 2>&1 | grep -E "^>> "
echo
echo "Harness complete. Committed artifacts in $(dirname "$HERE"):"
echo "  compat-map.json  compat-map.tsv  delta-report.md"
echo "Raw dumps (regenerated, not committed) under DUMPROOT."
