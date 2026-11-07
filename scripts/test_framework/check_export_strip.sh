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
# Then it holds the self-update's folder to the same standard, with two more exports
# in Text mode (update_folder_leg below). The folder and every other seed they need
# are written here and deleted on exit, so a checkout that already has that folder is
# a setup error:
#   - include filter `*`: no entry under the folder, and a seeded sibling with no dot,
#     which ships only because of that filter, must be there;
#   - selected scenes: a scene references a script in the seeded backup, and the
#     exporter offers that path because of the reference. No entry under the folder.
#     The same scene references a script in another dot-folder, which must ship, so
#     the reference did reach the exporter and only the strip kept the backup out.
#     The pack is then run with --main-pack: the scene that references the backup must
#     fail to load, and a control scene without that reference must run.
#
# The preset is rewritten in place for each export and restored on exit.
#
# Usage: bash scripts/test_framework/check_export_strip.sh <probe-res-path> <mode>...
#   (project root; modes: 0 = Text, 1 = binary tokens, 2 = compressed binary
#   tokens; Godot 4.2 has Text only)
# Needs GNU sed (Linux CI, Git Bash): the preset is rewritten with `sed -i`.
# Environment variables:
#   GODOT_BIN        - Godot binary (default: "godot")
#   PYTHON           - Python 3 interpreter, checked as UT_PYTHON is (default:
#                      UT_PYTHON, else python3 or python on the PATH, never one in
#                      a WindowsApps folder; scripts/lib/python_bin.sh)
#   EXPORT_STRIP_OUT - folder for the packs and logs (default: a new temp folder)
# Exit 0 = every mode clean, 1 = a leak or a failed export, 2 = setup error.

set -uo pipefail

GODOT_BIN="${GODOT_BIN:-godot}"
# shellcheck source=../lib/python_bin.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/python_bin.sh"
# PYTHON reaches ut_python_bin as UT_PYTHON, and its errors name UT_PYTHON either way.
PYTHON="$(UT_PYTHON="${PYTHON:-${UT_PYTHON:-}}" ut_python_bin)" \
  || { echo "ERROR: Python 3 is required; set PYTHON (or UT_PYTHON) to a Python 3 interpreter" >&2; exit 2; }
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

UPDATE_FOLDER="addons/.godot_mcp_toolkit_update"
SEED_SIBLING_FOLDER="addons/godot_mcp_toolkit_update"
SEED_DOT_FOLDER="addons/.export_strip_seed"
SEED_SCENE="export_strip_seed.tscn"
SEED_CONTROL_SCENE="export_strip_seed_control.tscn"
SEED_BACKUP_SCRIPT="$UPDATE_FOLDER/backup-1.0.0/seed_backup.gd"
SEED_DOT_SCRIPT="$SEED_DOT_FOLDER/seed_control.gd"
if [ -e "$UPDATE_FOLDER" ]; then
  echo "ERROR: $UPDATE_FOLDER already exists; this check seeds it and deletes it after" >&2
  exit 2
fi

OUT="${EXPORT_STRIP_OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
cp "$PRESETS_FILE" "$OUT/export_presets.cfg.orig"
trap 'cp "$OUT/export_presets.cfg.orig" "$PRESETS_FILE"; rm -rf "$UPDATE_FOLDER" "$SEED_SIBLING_FOLDER" "$SEED_DOT_FOLDER" "$SEED_SCENE" "$SEED_CONTROL_SCENE"' EXIT

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

fail_update_folder() {
  echo "::error title=Export strip (update folder)::$1"
  FAILED=1
}

# Exports the current preset to $OUT/<name>.pck and writes its parsed listing beside it.
export_listing() {
  local name="$1" export_exit=0
  rm -f "$OUT/$name.pck"
  timeout 180 "$GODOT_BIN" --headless --path . --export-pack "$PRESET" "$OUT/$name.pck" > "$OUT/export_$name.log" 2>&1 || export_exit=$?
  if [ "$export_exit" -ne 0 ] || [ ! -f "$OUT/$name.pck" ]; then
    fail_update_folder "the $name export failed (exit $export_exit); log tail below"
    tail -40 "$OUT/export_$name.log"
    return 1
  fi
  if ! "$PYTHON" "$LISTER" "$OUT/$name.pck" | tr -d '\r' > "$OUT/pck_$name.txt"; then
    fail_update_folder "pck_list.py could not read the $name pack"
    return 1
  fi
}

assert_nothing_from_update_folder() {
  local name="$1" hits
  hits="$(with_prefix "res://$UPDATE_FOLDER" < "$OUT/pck_$name.txt")"
  echo "$name: entries under the update folder: $(printf '%s' "$hits" | count_lines)"
  if [ -n "$hits" ]; then
    fail_update_folder "the $name export shipped the update folder"
    printf '%s\n' "$hits" | head -5 | sed 's/^/  /'
  fi
}

assert_shipped() {
  local name="$1" entry="$2" why="$3"
  if [ -z "$(with_prefix "$entry" < "$OUT/pck_$name.txt")" ]; then
    fail_update_folder "$entry is not in the $name pack, so $why"
  fi
}

# Writes the folder as the self-update leaves it, with something of every kind in it.
seed_update_folder() {
  mkdir -p "$UPDATE_FOLDER/backup-1.0.0" "$UPDATE_FOLDER/stage" "$UPDATE_FOLDER/1.0.1" "$SEED_SIBLING_FOLDER"
  : > "$UPDATE_FOLDER/.gdignore"
  printf '*\n' > "$UPDATE_FOLDER/.gitignore"
  printf '*\n' > "$UPDATE_FOLDER/.p4ignore"
  printf '{"format": 1, "state": "staged", "from": "1.0.0", "to": "1.0.1"}\n' > "$UPDATE_FOLDER/journal.json"
  printf 'seed\n' > "$UPDATE_FOLDER/install.log"
  printf 'extends Node\n\n\nfunc _ready() -> void:\n\tprint("export strip seed: backup script ran")\n' > "$SEED_BACKUP_SCRIPT"
  if [ ! -f "$SEED_BACKUP_SCRIPT" ]; then
    echo "ERROR: could not seed $SEED_BACKUP_SCRIPT" >&2
    exit 2
  fi
  printf 'extends Node\n' > "$UPDATE_FOLDER/stage/seed_stage.gd"
  printf 'not a real zip\n' > "$UPDATE_FOLDER/1.0.1/godot-mcp-toolkit-1.0.1.zip"
  printf 'seed\n' > "$SEED_SIBLING_FOLDER/seed_sibling.txt"
}

seed_scenes() {
  mkdir -p "$SEED_DOT_FOLDER"
  printf 'extends Node\n\n\nfunc _ready() -> void:\n\tprint("export strip seed: control scene ran")\n\tget_tree().quit()\n' > "$SEED_DOT_SCRIPT"
  cat > "$SEED_SCENE" <<EOF
[gd_scene load_steps=3 format=3]

[ext_resource type="Script" path="res://$SEED_BACKUP_SCRIPT" id="1"]
[ext_resource type="Script" path="res://$SEED_DOT_SCRIPT" id="2"]

[node name="Seed" type="Node"]
script = ExtResource("1")

[node name="Control" type="Node" parent="."]
script = ExtResource("2")
EOF
  cat > "$SEED_CONTROL_SCENE" <<EOF
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://$SEED_DOT_SCRIPT" id="1"]

[node name="SeedControl" type="Node"]
script = ExtResource("1")
EOF
}

# Runs a scene from the pack alone, from an empty folder: res:// falls back to the
# working folder, where the project's own files would stand in for what the pack lacks.
# The run's output goes to $OUT/<log>.log.
run_scene_from_pack() {
  local pack="$1" scene="$2" log="$3" run_folder="$OUT/empty_run_folder" godot="$GODOT_BIN"
  mkdir -p "$run_folder"
  case "$godot" in
    */*) godot="$(cd "$(dirname "$godot")" && pwd)/$(basename "$godot")" ;;
  esac
  (cd "$run_folder" && timeout 60 "$godot" --headless --main-pack "$pack" "res://$scene" --quit-after 300 > "$log" 2>&1 < /dev/null) || true
}

# One leg in Text mode, the only mode every version has. The strip's script handling is
# what the modes above prove; this is about the folder.
update_folder_leg() {
  local out_absolute
  out_absolute="$(cd "$OUT" && pwd)"
  echo ""
  echo "=== update folder: include filter * ==="
  seed_update_folder
  cp "$OUT/export_presets.cfg.orig" "$PRESETS_FILE"
  sed -i -e "s/^script_export_mode=[0-9]*/script_export_mode=0/" -e 's/^include_filter=.*/include_filter="*"/' "$PRESETS_FILE"
  if ! tr -d '\r' < "$PRESETS_FILE" | grep -qx 'include_filter="\*"'; then
    echo "ERROR: could not set the include filter in $PRESETS_FILE" >&2
    exit 2
  fi
  if export_listing update_filter; then
    assert_nothing_from_update_folder update_filter
    assert_shipped update_filter "res://$SEED_SIBLING_FOLDER/seed_sibling.txt" "the include filter did nothing and the check proves nothing"
  fi

  echo ""
  echo "=== update folder: a selected scene references the backup ==="
  seed_scenes
  cp "$OUT/export_presets.cfg.orig" "$PRESETS_FILE"
  sed -i -e "s/^script_export_mode=[0-9]*/script_export_mode=0/" \
    -e "s|^export_filter=.*|export_filter=\"scenes\"\nexport_files=PackedStringArray(\"res://$SEED_SCENE\", \"res://$SEED_CONTROL_SCENE\")|" \
    "$PRESETS_FILE"
  if ! tr -d '\r' < "$PRESETS_FILE" | grep -qx 'export_filter="scenes"'; then
    echo "ERROR: could not select scenes in $PRESETS_FILE" >&2
    exit 2
  fi
  export_listing update_scenes || return 0
  assert_nothing_from_update_folder update_scenes
  assert_shipped update_scenes "res://$SEED_SCENE" "the scene that references the backup never exported"
  assert_shipped update_scenes "res://$SEED_DOT_SCRIPT" "a reference into a dot-folder does not reach the exporter and the check proves nothing"

  run_scene_from_pack "$out_absolute/update_scenes.pck" "$SEED_CONTROL_SCENE" "$out_absolute/run_control.log"
  run_scene_from_pack "$out_absolute/update_scenes.pck" "$SEED_SCENE" "$out_absolute/run_seed.log"
  if ! grep -aqF "export strip seed: control scene ran" "$out_absolute/run_control.log"; then
    fail_update_folder "the control scene did not run from the pack, so the failed load below would prove nothing"
    tail -20 "$out_absolute/run_control.log"
  fi
  if grep -aqF "export strip seed: backup script ran" "$out_absolute/run_seed.log"; then
    fail_update_folder "the scene that references the backup ran its backup script"
  fi
  if grep -aqF "export strip seed: control scene ran" "$out_absolute/run_seed.log"; then
    fail_update_folder "the scene that references the backup loaded without it"
  fi
  echo "the scene that references the backup, run from the pack:"
  grep -aE "^(ERROR|SCRIPT ERROR)" "$out_absolute/run_seed.log" | head -4 | sed 's/^/  /' || true
}

update_folder_leg

echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "export strip: FAILED (packs and logs in $OUT)"
  exit 1
fi
echo "export strip: clean in every mode ($*)"
exit 0
