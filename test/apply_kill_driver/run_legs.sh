#!/usr/bin/env bash
# test/apply_kill_driver/run_legs.sh
# The self-update's swap in real editors: kills at each step, a clean update, a scan in
# flight at exit, a real git repository and a linked folder, each on a scratch project.
#
# The toolkit settles at its start and applies at its exit. A test-only plugin
# (plugin/driver_plugin.gd) records what the toolkit's start settled, once it has, and
# applies before the toolkit's exit does. Godot 4.3 and later exit the enabled plugins in
# the order project.godot lists them, and 4.2 in the reverse, so the driver is listed first
# on 4.3+ and last on 4.2. Its apply can kill the editor at one of the steps the applier
# names; when it runs, the toolkit's exit finds nothing staged. Each session is one real
# editor start and exit, closed by a close request sent from inside it. The run grades
# what that left: the plugin's notes, the journal and the folders on disk, never an exit
# code.
#
# Both versions are built by scripts/build-plugin-release.sh; B is signed by
# scripts/sign-release.sh with a throwaway key, so staging runs a really built zip through
# the name rules. Both embed a trust document naming that key, so each toolkit trusts the
# release the run signed. A is this checkout's version; B is one patch newer. Each carries
# a file the other lacks, and A also gets a file by hand, the one a release never lists.
#
# Legs (default: all of them):
#   k1     kill with the journal at applying; the next start settles, the next exit retries
#   k2     kill between the renames; the next start finds no toolkit, and both trees whole
#   k3     kill after the swap; the next start settles it as applied
#   clean  A to B with no copy-back; the toolkit starts on B and its icon reimports
#   scan   a scan requested in the same frame as the close, its walk inside the folder the
#          swap moves. The row fails if the scan is not in flight across the swap. What the
#          scan does to the swap is evidence: anything but a clean apply prints a warning.
#   scan_beside
#          the same, the walk in a folder beside the one the swap moves
#   git    the update folder stays out of a real repository's index
#   link   a linked addon folder refuses the swap and its target stays whole
#
# Usage: bash test/apply_kill_driver/run_legs.sh [leg...]
#   (needs a display: xvfb-run on Linux. Runs on Linux and in Git Bash on Windows.)
# Environment variables:
#   GODOT_BIN                  - Godot binary (default: "godot")
#   APPLY_KILL_OUT             - folder for everything this run writes (default: a new
#                                temp folder); logs/ under it holds the evidence
#   APPLY_KILL_SESSION_TIMEOUT - seconds one editor session gets (default: 300)
# Exit 0 = every leg passed, 1 = a leg failed, 2 = setup error. The last line printed is
# the verdict, so a caller can tell a finished run from one that died.

set -uo pipefail

GODOT_BIN="${GODOT_BIN:-godot}"
SESSION_TIMEOUT="${APPLY_KILL_SESSION_TIMEOUT:-300}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/release_files.sh
source "$REPO_ROOT/scripts/lib/release_files.sh"
# shellcheck source=../../scripts/lib/update_test_env.sh
source "$REPO_ROOT/scripts/lib/update_test_env.sh"
OUT="${APPLY_KILL_OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
LOGS="$OUT/logs"
PROJECT_NAME="ApplyKillDriver"
ADDON="addons/godot_mcp_toolkit"
UPDATES="addons/.godot_mcp_toolkit_update"
DRIVER_DIR=".kill_driver"
# Where B's assets wait until the driver moves them into the update folder: the toolkit
# clears that folder at start when no journal names a release.
RELEASE_DIR="$DRIVER_DIR/release"
ONLY_IN_A="driver_only_in_a.txt"
ONLY_IN_B="driver_only_in_b.txt"
HAND_ADDED="driver_added_by_hand.txt"
ICON_IMPORT="icon.svg.import"
ALL_LEGS="k1 k2 k3 clean scan scan_beside git link"
SCAN_SEED="driver_scan_seed"
SCAN_SEED_FOLDERS=100
SCAN_SEED_FILES=30

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ON_WINDOWS=1 ;;
  *) ON_WINDOWS=0 ;;
esac

# Everything the editor keeps outside the project goes under the run's folder, so a run
# neither reads nor changes this machine's editor settings.
EDITOR_HOME="$OUT/editor_home"
if [ "$ON_WINDOWS" = 1 ]; then
  EDITOR_ENV=("APPDATA=$(cygpath -m "$EDITOR_HOME/appdata")" "LOCALAPPDATA=$(cygpath -m "$EDITOR_HOME/localappdata")")
  EDITOR_CONFIG="$EDITOR_HOME/appdata/Godot"
  EDITOR_USER_DATA="$EDITOR_HOME/appdata/Godot/app_userdata/$PROJECT_NAME"
  GUI_ARGS=()
else
  EDITOR_ENV=("HOME=$EDITOR_HOME" "XDG_DATA_HOME=$EDITOR_HOME/.local/share" "XDG_CONFIG_HOME=$EDITOR_HOME/.config" "XDG_CACHE_HOME=$EDITOR_HOME/.cache")
  EDITOR_CONFIG="$EDITOR_HOME/.config/godot"
  EDITOR_USER_DATA="$EDITOR_HOME/.local/share/godot/app_userdata/$PROJECT_NAME"
  GUI_ARGS=(--rendering-driver opengl3 --audio-driver Dummy)
fi
# The setup steps are seen, so the toolkit may check for updates and fetch a release. Its
# requests go to a loopback port nothing listens on, and fail there, never reaching GitHub.
EDITOR_ENV+=("GODOT_MCP_UPDATE_CHECK_HOST=http://127.0.0.1:9")

FAILED=0
LEG=""
LEG_LOGS=""
PROJECT=""
A_VERSION=""
B_VERSION=""
B_TREE=""
A_DIGEST=""

die() {
  echo "ERROR: $1" >&2
  echo "apply kill legs: SETUP ERROR"
  exit 2
}

check() { # <what> <actual> <expected>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "::error title=Apply kill driver ($LEG)::$1: expected '$3', got '$2'"
    FAILED=1
  fi
}

# A file's text, line ends normalised; nothing when it is not there.
text_of() {
  [ -f "$1" ] && tr -d '\r' < "$1"
}

# Every file's path and bytes under a folder, its engine-written .import files aside.
tree_digest() {
  [ -d "$1" ] || { echo "no folder"; return 0; }
  (cd "$1" && find . -type f ! -name '*.import' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
}

note() { # <session> <key>: the session's last note under that key
  text_of "$LEG_LOGS/$1.txt" | sed -n "s/^$2=//p" | tail -1
}

steps_of() { # <session>: the steps the applier reached, in order
  text_of "$LEG_LOGS/$1.txt" | sed -n 's/^step=//p' | paste -sd, -
}

journal_state() {
  text_of "$PROJECT/$UPDATES/journal.json" | sed -nE 's/.*"state": *"([^"]*)".*/\1/p'
}

live_version() {
  text_of "$PROJECT/$ADDON/plugin.cfg" | sed -nE 's/^version="([^"]*)".*/\1/p'
}

exists() { # <path relative to the project>
  if [ -e "$PROJECT/$1" ] || [ -L "$PROJECT/$1" ]; then echo present; else echo absent; fi
}

# One real editor start and exit. <id> names the session; the rest are its key=value lines.
session() {
  local id="$1"
  shift
  mkdir -p "$PROJECT/$DRIVER_DIR" "$LEG_LOGS"
  printf '%s\n' "id=$id" "$@" > "$PROJECT/$DRIVER_DIR/session.txt"
  echo "  session $id: $*"
  local started="$SECONDS" editor_exit=0
  env "${EDITOR_ENV[@]}" "$(ut_timeout_bin)" -k 10 "$SESSION_TIMEOUT" \
    "$GODOT_BIN" ${GUI_ARGS[@]+"${GUI_ARGS[@]}"} --editor --path "$PROJECT" \
    > "$LEG_LOGS/$id.log" 2>&1 < /dev/null || editor_exit=$?
  rm -f "$PROJECT/$DRIVER_DIR/session.txt"
  cp "$PROJECT/$DRIVER_DIR/$id.txt" "$LEG_LOGS/$id.txt" 2>/dev/null || : > "$LEG_LOGS/$id.txt"
  # Recorded for a reader. A kill exits 0 on Windows and 137 on Linux, so nothing grades it.
  echo "editor_exit=$editor_exit" >> "$LEG_LOGS/$id.txt"
  echo "seconds=$((SECONDS - started))" >> "$LEG_LOGS/$id.txt"
  cp "$PROJECT/$UPDATES/install.log" "$LEG_LOGS/$id.install.log" 2>/dev/null || true
  cp "$PROJECT/$UPDATES/journal.json" "$LEG_LOGS/$id.journal.json" 2>/dev/null || true
  check "session $id started" "$(note "$id" session_started)" "1"
}

# A release of <version> built by the real script in a throwaway copy of this checkout.
# The copy gets a commit of its own, since the manifest's expiry reads HEAD's time.
build_release() { # <version> <file only this version has> <out folder> <private key> <public key>
  local version="$1" only_here="$2" out="$3" tree="$OUT/build/$1"
  mkdir -p "$tree/addons" "$out"
  cp -r "$REPO_ROOT/$ADDON" "$tree/addons/" || return 1
  cp -r "$REPO_ROOT/scripts" "$tree/" || return 1
  # A checkout an editor has opened holds .import files; a release's clean checkout has none.
  find "$tree/addons" -name '*.import' -delete
  rm -f "$tree/$ADDON/release_files.sha256"
  ut_embed_trust "$tree/$ADDON" "$4" "$5" || return 1
  sed -i -E "s/^version=\"[^\"]*\"/version=\"$version\"/" "$tree/$ADDON/plugin.cfg"
  printf 'only in %s\n' "$version" > "$tree/$ADDON/$only_here"
  git -C "$tree" init -q || return 1
  git -C "$tree" -c user.name=driver -c user.email=driver@example.invalid commit -q --allow-empty -m build || return 1
  (cd "$tree" && bash scripts/build-plugin-release.sh) || return 1
  cp "$tree/dist-plugin/"* "$out/" || return 1
  rm -rf "$tree"
}

# The editor's own settings, and every setup step the toolkit's wizard shows marked seen,
# so no session opens the wizard.
seed_editor_home() {
  local settings='[gd_resource type="EditorSettings" format=3]

[resource]
interface/editor/single_window_mode = true
interface/editor/editor_language = "en"
'
  mkdir -p "$EDITOR_CONFIG"
  printf '%s' "$settings" > "$EDITOR_CONFIG/editor_settings-4.tres"
  printf '%s' "$settings" > "$EDITOR_CONFIG/editor_settings-$GODOT_MINOR.tres"
  ut_mark_setup_seen "$EDITOR_USER_DATA"
}

# Builds and signs both releases, then makes the project every leg starts from: A
# installed and warmed, one windowed session behind it, B's assets put in the update folder
# by the driver once the toolkit has started, as a download leaves them, and the stage made
# by the real stepper in a real editor. That editor is killed at its exit, before the
# toolkit's exit can install the stage.
prepare_template() {
  local releases="$OUT/releases"
  LEG="setup"
  LEG_LOGS="$LOGS/setup"
  PROJECT="$OUT/template"
  mkdir -p "$releases" "$PROJECT/addons" "$LEG_LOGS"

  A_VERSION="$(sed -nE 's/^version="([^"]*)".*/\1/p' "$REPO_ROOT/$ADDON/plugin.cfg" | tr -d '\r')"
  [ -n "$A_VERSION" ] || die "no version in $ADDON/plugin.cfg"
  B_VERSION="${A_VERSION%.*}.$((${A_VERSION##*.} + 1))"
  local private_key="$OUT/release_key.pem" public_key="$OUT/release_key.pub.pem"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$private_key" 2>/dev/null || die "could not make a key"
  openssl pkey -in "$private_key" -pubout -out "$public_key" || die "could not read the key's public half"

  echo "=== Build: A $A_VERSION, B $B_VERSION ==="
  build_release "$A_VERSION" "$ONLY_IN_A" "$releases" "$private_key" "$public_key" || die "could not build $A_VERSION"
  build_release "$B_VERSION" "$ONLY_IN_B" "$releases" "$private_key" "$public_key" || die "could not build $B_VERSION"

  # sign-release.sh reads a passphrase line from a pipe even for a plain key.
  echo unused | bash "$REPO_ROOT/scripts/sign-release.sh" \
    "$releases/godot-mcp-toolkit-$B_VERSION.update.json" "$private_key" "$public_key" > /dev/null \
    || die "could not sign $B_VERSION"

  unzip -q "$releases/godot-mcp-toolkit-$A_VERSION.zip" -d "$PROJECT" || die "could not unpack A"
  printf 'put here by hand\n' > "$PROJECT/$ADDON/$HAND_ADDED"
  B_TREE="$OUT/b_tree"
  unzip -q "$releases/godot-mcp-toolkit-$B_VERSION.zip" -d "$B_TREE" || die "could not unpack B"
  B_TREE="$B_TREE/$ADDON"

  cp -r "$REPO_ROOT/test/apply_kill_driver/plugin" "$PROJECT/addons/apply_kill_driver"
  mkdir -p "$PROJECT/$DRIVER_DIR"
  cp "$public_key" "$PROJECT/$DRIVER_DIR/public_key.pem"
  # The order that makes the driver exit before the toolkit (see the header).
  local toolkit_cfg="\"res://$ADDON/plugin.cfg\"" driver_cfg='"res://addons/apply_kill_driver/plugin.cfg"' enabled
  if [ "$GODOT_MINOR" = "4.2" ]; then
    enabled="$toolkit_cfg, $driver_cfg"
  else
    enabled="$driver_cfg, $toolkit_cfg"
  fi
  cat > "$PROJECT/project.godot" <<EOF
config_version=5

[application]

config/name="$PROJECT_NAME"

[editor_plugins]

enabled=PackedStringArray($enabled)
EOF
  seed_editor_home

  echo "=== Warm-up ==="
  (cd "$PROJECT" && env "${EDITOR_ENV[@]}" GODOT_BIN="$GODOT_BIN" GODOT_WARM_ONLY=1 \
    bash "$REPO_ROOT/scripts/test_framework/run_units_cold.sh") > "$LEG_LOGS/warm.log" 2>&1 \
    || { tail -20 "$LEG_LOGS/warm.log"; die "the warm-up failed"; }

  echo "=== Template sessions ==="
  session first_start wait_toolkit=1 wait_import=1
  check "A's toolkit loads" "$(note first_start toolkit_loaded)" "true"
  check "A's toolkit reports A" "$(note first_start toolkit_version)" "$A_VERSION"
  check "the icon has its .import before any swap" "$(exists "$ADDON/$ICON_IMPORT")" "present"

  mkdir -p "$PROJECT/$RELEASE_DIR"
  cp "$releases/godot-mcp-toolkit-$B_VERSION."* "$PROJECT/$RELEASE_DIR/"
  session stage "stage=1" "from=$A_VERSION" "to=$B_VERSION" "kill_at_exit=1"
  check "the built zip passes the name rules and stages whole" "$(note stage stage_state)" "done"
  check "the stepper wrote every listed file" "$(note stage stage_written)" "$(note stage stage_total)"
  check "the stage equals the zip" "$(tree_digest "$PROJECT/$UPDATES/stage")" "$(tree_digest "$B_TREE")"
  check "the journal says staged" "$(journal_state)" "staged"
  echo "  record: staging's begin took $(note stage stage_begin_ms) ms, its longest step $(note stage stage_longest_step_ms) ms"

  check "the ignore file for git holds a star" "$(text_of "$PROJECT/$UPDATES/.gitignore")" "*"
  check "the ignore file for Perforce holds a star" "$(text_of "$PROJECT/$UPDATES/.p4ignore")" "*"
  check "the ignore file for the engine is there and empty" \
    "$( [ -f "$PROJECT/$UPDATES/.gdignore" ] && wc -c < "$PROJECT/$UPDATES/.gdignore" | tr -d ' ' )" "0"
  A_DIGEST="$(tree_digest "$PROJECT/$ADDON")"
  [ "$FAILED" = 0 ] || die "the template did not come out as the legs need it"
}

begin_leg() {
  LEG="$1"
  LEG_LOGS="$LOGS/$LEG"
  PROJECT="$OUT/legs/$LEG"
  echo ""
  echo "=== Leg $LEG ==="
  mkdir -p "$OUT/legs" "$LEG_LOGS"
  cp -a "$OUT/template" "$PROJECT" || die "could not copy the template for $LEG"
}

# What a kill at <step> must leave in the session's notes: it fired there, nothing ran past
# it, and the apply never returned.
check_killed_at() { # <session> <step> <steps expected>
  check "the applier reached exactly these steps" "$(steps_of "$1")" "$3"
  check "the kill fired at $2" "$(note "$1" kill_fired)" "$2"
  check "the process died at the kill" "$(note "$1" survived_kill)" ""
  check "the apply never returned" "$(note "$1" apply_state)" ""
}

check_updated_on_b() { # <session>
  check "settle reports the update" "$(note "$1" settle_report)" "updated"
  check "from A" "$(note "$1" settle_from)" "$A_VERSION"
  check "to B" "$(note "$1" settle_to)" "$B_VERSION"
  check "B is on disk" "$(live_version)" "$B_VERSION"
  check "the toolkit reached its loaded state" "$(note "$1" toolkit_loaded)" "true"
  check "the running toolkit reports B" "$(note "$1" toolkit_version)" "$B_VERSION"
  check "the journal is gone" "$(exists "$UPDATES/journal.json")" "absent"
  check "the stage is gone" "$(exists "$UPDATES/stage")" "absent"
  check "the release's folder is gone" "$(exists "$UPDATES/$B_VERSION")" "absent"
  check "the backup stays, whole" "$(tree_digest "$PROJECT/$UPDATES/backup-$A_VERSION")" "$A_DIGEST"
}

leg_k1() {
  begin_leg k1
  session kill apply=1 kill_at=applying
  check_killed_at kill applying "checked,applying"
  check "the journal says applying" "$(journal_state)" "applying"
  check "the live folder is still A" "$(tree_digest "$PROJECT/$ADDON")" "$A_DIGEST"
  check "the stage is whole" "$(tree_digest "$PROJECT/$UPDATES/stage")" "$(tree_digest "$B_TREE")"

  session retry settle=1 apply=1
  check "settle puts it back to waiting" "$(note retry settle_report)" "waiting"
  check "the next exit retries and applies" "$(note retry apply_state)" "applied"
  check "the retry walked every step" "$(steps_of retry)" "checked,applying,live_moved,stage_moved"
  check "the journal says applied" "$(journal_state)" "applied"

  session after_retry settle=1 wait_toolkit=1
  check_updated_on_b after_retry
}

leg_k2() {
  begin_leg k2
  session kill apply=1 kill_at=live_moved
  check_killed_at kill live_moved "checked,applying,live_moved"
  check "the journal says applying" "$(journal_state)" "applying"
  check "the live folder is gone" "$(exists "$ADDON")" "absent"
  check "the backup holds A, whole" "$(tree_digest "$PROJECT/$UPDATES/backup-$A_VERSION")" "$A_DIGEST"
  check "the stage is whole" "$(tree_digest "$PROJECT/$UPDATES/stage")" "$(tree_digest "$B_TREE")"

  # The settler sits in the folder that is gone, so no start can run it here. This row
  # belongs to a guard outside that folder; what a real start must do is disturb nothing.
  session next_start wait_toolkit=0
  check "the next start finds no toolkit" "$(note next_start toolkit_folder_present)" "false"
  check "the journal still says applying" "$(journal_state)" "applying"
  check "the live folder is still gone" "$(exists "$ADDON")" "absent"
  check "the backup is still whole" "$(tree_digest "$PROJECT/$UPDATES/backup-$A_VERSION")" "$A_DIGEST"
  check "the stage is still whole" "$(tree_digest "$PROJECT/$UPDATES/stage")" "$(tree_digest "$B_TREE")"
}

leg_k3() {
  begin_leg k3
  session kill apply=1 kill_at=stage_moved
  check_killed_at kill stage_moved "checked,applying,live_moved,stage_moved"
  check "the journal still says applying" "$(journal_state)" "applying"
  check "the live folder is B, whole" "$(tree_digest "$PROJECT/$ADDON")" "$(tree_digest "$B_TREE")"

  session next_start settle=1 wait_toolkit=1
  check_updated_on_b next_start
}

leg_clean() {
  begin_leg clean
  session apply apply=1
  check "the apply finished" "$(note apply apply_state)" "applied"
  check "the apply walked every step" "$(steps_of apply)" "checked,applying,live_moved,stage_moved"
  check "the journal says applied" "$(journal_state)" "applied"
  check "the live folder is B, whole" "$(tree_digest "$PROJECT/$ADDON")" "$(tree_digest "$B_TREE")"
  check "no copy-back: the hand-added file stays behind" "$(exists "$ADDON/$HAND_ADDED")" "absent"
  check "no copy-back: A's own file stays behind" "$(exists "$ADDON/$ONLY_IN_A")" "absent"
  check "B's own file arrived" "$(exists "$ADDON/$ONLY_IN_B")" "present"
  check "the backup holds the hand-added file" "$(exists "$UPDATES/backup-$A_VERSION/$HAND_ADDED")" "present"
  check "the swap discards the icon's .import" "$(exists "$ADDON/$ICON_IMPORT")" "absent"
  check "the backup holds that .import" "$(exists "$UPDATES/backup-$A_VERSION/$ICON_IMPORT")" "present"

  session next_start settle=1 wait_toolkit=1 wait_import=1
  check_updated_on_b next_start
  check "the plugin stays enabled" "$(note next_start toolkit_enabled)" "true"
  check "the icon reimports and loads" "$(note next_start icon_imported)" "true"
  check "the .import is back" "$(exists "$ADDON/$ICON_IMPORT")" "present"
  check "B's start logs no script error" "$(grep -ac '^SCRIPT ERROR' "$LEG_LOGS/next_start.log")" "0"
  echo "  record: the apply took $(note apply apply_ms) ms, the plugin's whole _exit_tree $(note apply exit_tree_ms) ms"
}

# Scripts in a folder under <folder, relative to the project>, hidden from the session's
# first scan by a .gdignore the plugin deletes just before it asks for the second one. To
# that scan every one is new, so it reads each of them, far slower than files it knows.
seed_scan_files() {
  local seed="$PROJECT/$1" folder file
  mkdir -p "$seed"
  : > "$seed/.gdignore"
  (cd "$seed" && seq -f 'f%g' 1 "$SCAN_SEED_FOLDERS" | xargs mkdir)
  for ((folder = 1; folder <= SCAN_SEED_FOLDERS; folder++)); do
    for ((file = 1; file <= SCAN_SEED_FILES; file++)); do
      echo 'extends RefCounted' > "$seed/f$folder/s$file.gd"
    done
  done
}

scanning_at_step() { # <step>: what the applier's notes say of the scan at that step
  text_of "$LEG_LOGS/apply.txt" | sed -nE "s/^scanning_at_step=$1:([a-z]*):.*/\1/p"
}

# A scan requested in the closing frame, seeded so that it is still walking at the swap. The
# editor waits for a running scan only in its filesystem's own exit, which on every supported
# version comes after a plugin's _exit_tree, so the overlap can happen and this row requires
# it. What the overlap then does is the evidence: anything but a clean apply prints a warning.
scan_row() { # <seed folder, relative to the project>
  seed_scan_files "$1"
  session apply apply=1 scan_at_close=1 "reveal_at_close=res://$1/.gdignore"
  check "the seed was revealed" "$(note apply seed_revealed)" "true"
  check "the scan was requested in the closing frame" "$(note apply scan_called)" "1"
  check "the editor's exit reached the plugin" "$(note apply exit_tree_reached)" "1"
  check "the scan was in flight before the first rename" "$(scanning_at_step applying)" "true"
  check "the scan outlasted the whole apply" "$(note apply scanning_after_apply | cut -d: -f1)" "true"

  local apply_state errors live_after_apply stage_after_apply
  apply_state="$(note apply apply_state)"
  errors="$(grep -acE '^(ERROR|SCRIPT ERROR)' "$LEG_LOGS/apply.log")"
  live_after_apply="$(live_version)"
  stage_after_apply="gone or changed"
  [ "$(tree_digest "$PROJECT/$UPDATES/stage")" = "$(tree_digest "$B_TREE")" ] && stage_after_apply="whole"
  echo "  record: _exit_tree came $(note apply exit_tree_after_scan_ms) ms after the scan call"
  echo "  record: step:scanning:progress: $(text_of "$LEG_LOGS/apply.txt" | sed -n 's/^scanning_at_step=//p' | paste -sd' ' -)"
  echo "  record: after the apply: $(note apply scanning_after_apply); the apply took $(note apply apply_ms) ms"
  echo "  record: apply_state=$apply_state reason=$(note apply apply_reason) journal=$(journal_state) editor_exit=$(note apply editor_exit)"
  echo "  record: live version $live_after_apply; stage $stage_after_apply; error lines in the closing log: $errors"
  echo "  record: the install log's applies of $B_VERSION: $(grep -F "apply $B_VERSION:" "$LEG_LOGS/apply.install.log" 2>/dev/null | paste -sd'|' -)"

  session next_start settle=1 wait_toolkit=1 apply=1
  session after settle=1 wait_toolkit=1
  local final_digest="differs from B"
  [ "$(tree_digest "$PROJECT/$ADDON")" = "$(tree_digest "$B_TREE")" ] && final_digest="equals B"
  echo "  record: next start's report=$(note next_start settle_report), its exit's apply=$(note next_start apply_state)"
  echo "  record: the start after that: report=$(note after settle_report), toolkit loaded=$(note after toolkit_loaded) on $(note after toolkit_version); the live folder $final_digest"
  if [ "$apply_state" != "applied" ]; then
    echo "::warning title=Apply kill driver ($LEG)::a scan in flight changed the outcome: apply_state=$apply_state, reason=$(note apply apply_reason). See logs/$LEG."
  fi
  if [ "$final_digest" != "equals B" ] || [ "$(note after toolkit_version)" != "$B_VERSION" ]; then
    echo "::warning title=Apply kill driver ($LEG)::the update did not finish after the scan: live version $(live_version). See logs/$LEG."
  fi
}

# The whole walk is inside the folder the swap moves.
leg_scan() {
  begin_leg scan
  scan_row "$ADDON/$SCAN_SEED"
}

# The walk is beside that folder, the likelier case on a real project.
leg_scan_beside() {
  begin_leg scan_beside
  scan_row "addons/$SCAN_SEED"
}

git_in_project() {
  git -C "$PROJECT" -c core.autocrlf=false -c core.safecrlf=false -c user.name=driver -c user.email=driver@example.invalid "$@"
}

# How many staged paths start with <prefix>.
staged_under() {
  git_in_project diff --cached --name-only | tr -d '\r' | grep -c "^$1" || true
}

leg_git() {
  begin_leg git
  git_in_project init -q || die "git init failed"
  printf '.godot/\n%s/\n!addons/**\n' "$DRIVER_DIR" > "$PROJECT/.gitignore"

  git_in_project add -A
  # Counted on disk, because the index reads 0 on both sides when a rule hides the toolkit.
  # The .gitignore above re-includes addons/ whole, so every file there has to be staged.
  local on_disk
  on_disk="$(find "$PROJECT/$ADDON" -type f | wc -l | tr -d ' ')"
  [ "$on_disk" -gt 0 ] || check "the toolkit has files on disk" "$on_disk" "more than 0"
  check "after staging, git add -A stages the toolkit" "$(staged_under "$ADDON/")" "$on_disk"
  check "after staging, it stages nothing from the update folder" "$(staged_under "$UPDATES/")" "0"
  git_in_project commit -q -m baseline

  # Without the ignore file the same command takes the folder, so the rule above is what
  # kept it out.
  rm "$PROJECT/$UPDATES/.gitignore"
  git_in_project add -A
  local exposed
  exposed="$(staged_under "$UPDATES/")"
  if [ "$exposed" -eq 0 ]; then
    check "with its .gitignore deleted, the folder shows up" "$exposed" "more than 0"
  else
    echo "  ok: with its .gitignore deleted, the folder shows up ($exposed paths)"
  fi
  git_in_project reset -q

  session apply apply=1
  check "the apply finished" "$(note apply apply_state)" "applied"
  check "another entry point writes the .gitignore back" "$(text_of "$PROJECT/$UPDATES/.gitignore")" "*"
  git_in_project add -A
  check "after the swap, git add -A stages the toolkit's change" "$(staged_under "$ADDON/plugin.cfg")" "1"
  check "after the swap, it stages nothing from the update folder" "$(staged_under "$UPDATES/")" "0"
  git_in_project diff --cached --name-only > "$LEG_LOGS/staged_after_swap.txt"
}

leg_link() {
  begin_leg link
  local target="$OUT/legs/link_target"
  mv "$PROJECT/$ADDON" "$target" || die "could not move the addon out"
  if [ "$ON_WINDOWS" = 1 ]; then
    cmd //c mklink //J "$(cygpath -w "$PROJECT/$ADDON")" "$(cygpath -w "$target")" > /dev/null \
      || die "could not make a junction"
  else
    ln -s "$target" "$PROJECT/$ADDON" || die "could not make a link"
  fi
  session apply apply=1
  check "the apply refuses" "$(note apply apply_state)" "not_applied"
  check "the refusal names the link" "$(note apply apply_reason)" "The toolkit's folder is a link to another place."
  check "no step of the swap ran" "$(steps_of apply)" ""
  check "the link's target is whole" "$(tree_digest "$target")" "$A_DIGEST"
  check "the link stays" "$(exists "$ADDON/plugin.cfg")" "present"
  check "no backup was taken" "$(exists "$UPDATES/backup-$A_VERSION")" "absent"
  check "the stage is gone" "$(exists "$UPDATES/stage")" "absent"

  session next_start settle=1
  check "the next start reports the failure" "$(note next_start settle_report)" "failed"
  check "and clears the journal" "$(exists "$UPDATES/journal.json")" "absent"
  check "the link's target is still whole" "$(tree_digest "$target")" "$A_DIGEST"
}

[ -f "$REPO_ROOT/project.godot" ] || die "cannot find the repository root from $0"
command -v "$GODOT_BIN" > /dev/null 2>&1 || die "no Godot binary: $GODOT_BIN"
GODOT_MINOR="$("$GODOT_BIN" --version 2>/dev/null | tr -d '\r' | head -1 | cut -d. -f1,2)"
[ -n "$GODOT_MINOR" ] || die "$GODOT_BIN --version printed nothing"

LEGS="${*:-$ALL_LEGS}"
for leg in $LEGS; do
  case " $ALL_LEGS " in
    *" $leg "*) ;;
    *) die "no such leg: $leg (legs: $ALL_LEGS)" ;;
  esac
done

prepare_template
for leg in $LEGS; do
  before="$FAILED"
  FAILED=0
  "leg_$leg"
  if [ "$FAILED" = 0 ]; then echo "leg $leg: PASS" | tee -a "$LOGS/summary.txt"; else echo "leg $leg: FAIL" | tee -a "$LOGS/summary.txt"; fi
  FAILED=$((before | FAILED))
done

echo ""
if [ "$FAILED" != 0 ]; then
  echo "apply kill legs: FAILED (evidence in $LOGS)"
  exit 1
fi
echo "apply kill legs: PASS ($LEGS on Godot $GODOT_MINOR)"
exit 0
