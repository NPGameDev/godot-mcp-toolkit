#!/usr/bin/env bash
# scripts/test_framework/check_export_strip.sh
# Export-strip check: export the project's data pack in each given Script Export
# Mode and fail if any toolkit or extension script, or res://.mcp.json, ships.
#
# It exports a pack (--export-pack) rather than a build: a pack needs no export
# templates, which cost about 1 GB per Godot version, and the strip acts on the
# pack's file list, which a pack export writes exactly as a full export does.
# Launching a build stays a manual release-checklist step.
#
# The assertions read the parsed PCK listing (pck_list.py), never a byte grep:
# the exported class cache, uid_cache.bin and project.binary name addon paths
# as metadata, so the bytes carry them even when the strip worked.
#
# Per mode it asserts:
#   - the export exits 0 and the listing has at least one script outside the
#     addon (a control: a listing that sees no scripts would pass vacuously);
#   - no script entry under addons/godot_mcp_toolkit/ (.gd, .gdc,
#     .gd.remap). Non-script addon entries are printed, not failed: Godot 4.2
#     ships the addon icon's .import sidecar in Text mode, which carries no code;
#   - no entry for the extension probe in any form;
#   - no res://.mcp.json;
#   - no export strip leak warning in the export log.
#
# The caller writes the probe, a direct MCPToolkitExtension subclass with a
# class_name, and warms the class cache before this runs, so the strip knows the
# probe as an extension. Both stay uncommitted, so the tool counts and coverage
# manifests do not move.
#
# The preset's script_export_mode is rewritten in place for each export and
# restored on exit.
#
# Usage: bash scripts/test_framework/check_export_strip.sh <probe-res-path> <mode>...
#   (project root; modes: 0 = Text, 1 = binary tokens, 2 = compressed binary
#   tokens; Godot 4.2 has Text only)
# Needs GNU sed (Linux CI, Git Bash): the preset is rewritten with `sed -i`.
# Environment variables:
#   GODOT_BIN        - Godot binary (default: "godot")
#   PYTHON           - Python 3 interpreter (default: python3)
#   EXPORT_STRIP_OUT - folder for the packs and logs (default: a new temp folder)
# Exit 0 = every mode clean, 1 = a leak or a failed export, 2 = setup error.

set -uo pipefail

GODOT_BIN="${GODOT_BIN:-godot}"
PYTHON="${PYTHON:-python3}"
PRESET="CLI Test Build Windows"
PRESETS_FILE="export_presets.cfg"
ADDON_PREFIX="res://addons/godot_mcp_toolkit/"
LISTER="scripts/test_framework/pck_list.py"
# The export plugin's warning when addon or extension scripts never reached it
# (export_strip.gd, _decide_warning). 4.2 and 4.3 print it through push_warning,
# 4.4+ through the export platform's message list; both carry this text.
LEAK_WARNING="export strip never saw"
SCRIPT_RE='\.(gd|gdc|gd\.remap)$'

if [ ! -f "project.godot" ] || [ ! -f "$PRESETS_FILE" ]; then
  echo "ERROR: run from the project root (project.godot and $PRESETS_FILE)" >&2
  exit 2
fi
if [ "$#" -lt 2 ]; then
  echo "usage: check_export_strip.sh <probe-res-path> <mode>..." >&2
  exit 2
fi
PROBE="$1"
shift
PROBE_FILE="${PROBE#res://}"
if [ ! -f "$PROBE_FILE" ]; then
  echo "ERROR: probe $PROBE is not on disk; the caller writes it before the class-cache warm-up" >&2
  exit 2
fi

OUT="${EXPORT_STRIP_OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
cp "$PRESETS_FILE" "$OUT/export_presets.cfg.orig"
trap 'cp "$OUT/export_presets.cfg.orig" "$PRESETS_FILE"' EXIT

FAILED=0
# Lines of stdin that start with $1, compared as a literal string.
with_prefix() {
  awk -v p="$1" 'index($0, p) == 1'
}
count_lines() {
  grep -c . || true
}
fail() {
  echo "::error title=Export strip (mode $MODE)::$1"
  FAILED=1
}

for MODE in "$@"; do
  echo ""
  echo "=== script_export_mode=$MODE ==="
  sed -i "s/^script_export_mode=[0-9]*/script_export_mode=$MODE/" "$PRESETS_FILE"
  if ! tr -d '\r' < "$PRESETS_FILE" | grep -qx "script_export_mode=$MODE"; then
    echo "ERROR: could not set script_export_mode=$MODE in $PRESETS_FILE" >&2
    exit 2
  fi

  PCK="$OUT/game_m$MODE.pck"
  LOG="$OUT/export_m$MODE.log"
  rm -f "$PCK"
  EXPORT_EXIT=0
  timeout 180 "$GODOT_BIN" --headless --path . --export-pack "$PRESET" "$PCK" > "$LOG" 2>&1 || EXPORT_EXIT=$?
  if [ "$EXPORT_EXIT" -ne 0 ] || [ ! -f "$PCK" ]; then
    fail "the pack export failed (exit $EXPORT_EXIT); log tail below"
    tail -40 "$LOG"
    continue
  fi

  LISTING="$OUT/pck_m$MODE.txt"
  # tr: a Windows Python prints CRLF, which would hide every suffix match below.
  if ! "$PYTHON" "$LISTER" "$PCK" | tr -d '\r' > "$LISTING"; then
    fail "pck_list.py could not read the pack"
    continue
  fi

  ADDON_ENTRIES="$(with_prefix "$ADDON_PREFIX" < "$LISTING")"
  ADDON_SCRIPTS="$(printf '%s\n' "$ADDON_ENTRIES" | grep -E "$SCRIPT_RE" || true)"
  PROBE_HITS="$(with_prefix "$PROBE" < "$LISTING")"
  TOTAL="$(count_lines < "$LISTING")"
  CONTROL="$(awk -v p="$ADDON_PREFIX" 'index($0, p) != 1' "$LISTING" | grep -cE "$SCRIPT_RE" || true)"
  ADDON_COUNT="$(printf '%s' "$ADDON_ENTRIES" | count_lines)"
  ADDON_SCRIPT_COUNT="$(printf '%s' "$ADDON_SCRIPTS" | count_lines)"
  PROBE_COUNT="$(printf '%s' "$PROBE_HITS" | count_lines)"
  MCP_JSON_COUNT="$(grep -cxF "res://.mcp.json" "$LISTING" || true)"
  WARNING_LINES="$(grep -aF "$LEAK_WARNING" "$LOG" || true)"
  WARNING_COUNT="$(printf '%s' "$WARNING_LINES" | count_lines)"

  echo "pack entries: $TOTAL; scripts outside the addon (control): $CONTROL"
  echo "addon entries: $ADDON_COUNT, of which scripts: $ADDON_SCRIPT_COUNT"
  printf '%s\n' "$ADDON_ENTRIES" | grep -vE "$SCRIPT_RE" | grep . | sed 's/^/  non-script addon entry: /' || true
  echo "probe entries: $PROBE_COUNT; res://.mcp.json entries: $MCP_JSON_COUNT; leak warning lines: $WARNING_COUNT"

  if [ "$CONTROL" -eq 0 ]; then
    fail "the listing has no script outside the addon, so it cannot show a leak either"
  fi
  if [ "$ADDON_SCRIPT_COUNT" -ne 0 ]; then
    fail "$ADDON_SCRIPT_COUNT toolkit script entries shipped in the pack"
    printf '%s\n' "$ADDON_SCRIPTS" | head -5 | sed 's/^/  /'
  fi
  if [ "$PROBE_COUNT" -ne 0 ]; then
    fail "the extension probe shipped in the pack"
    printf '%s\n' "$PROBE_HITS" | sed 's/^/  /'
  fi
  if [ "$MCP_JSON_COUNT" -ne 0 ]; then
    fail "res://.mcp.json shipped in the pack"
  fi
  if [ "$WARNING_COUNT" -ne 0 ]; then
    fail "the export log carries the export strip leak warning"
    printf '%s\n' "$WARNING_LINES" | head -3 | sed 's/^/  /'
  fi
done

echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "export strip: FAILED (packs and logs in $OUT)"
  exit 1
fi
echo "export strip: clean in every mode ($*)"
exit 0
