#!/usr/bin/env bash
# test/apply_kill_driver/run_legs.sh
# The self-update's swap in real editors: kills at each step, a clean update, a scan in
# flight at exit, a real git repository and a linked folder, each on a scratch project.
#
# The toolkit settles at its start and applies at its exit. A test-only plugin
# (plugin/driver_plugin.gd) records what the toolkit's start settled, once it has, and
# applies before the toolkit's exit does. Godot 4.3 and later exit the enabled plugins in
# the order project.godot lists them, and 4.2 in the reverse, so the driver is listed first
# on 4.3+ and last on 4.2. Every save of that list sorts it, which on 4.2 makes the driver
# exit after the toolkit, so the template writes the 4.2 order back after staging's save. Its
# apply can kill the editor at one of the steps the applier names; when it runs, the
# toolkit's exit finds nothing staged. Each session is one real editor start and exit,
# closed by a close request sent from inside it. The run grades what that left: the
# plugin's notes, the journal and the folders on disk, never an exit code.
#
# Both versions are built by scripts/build-plugin-release.sh; B is signed by
# scripts/sign-release.sh with a throwaway key, so staging runs a really built zip through
# the name rules. Both embed a trust document naming that key, so each toolkit trusts the
# release the run signed. A is this checkout's version; B is one patch newer. Each carries
# a file the other lacks, and A also gets a file by hand, the one a release never lists.
#
# Two more builds of B, signed the same way, are staged by the legs that need them: one
# where a file plugin.gd preloads does not parse, and one where a class_name script that
# such a file uses sits in another folder than in A.
#
# Legs (default: all of them):
#   k1     kill with the journal at applying; the next start settles, the next exit retries
#   k2     kill between the renames; the next start's recovery plugin moves the whole stage
#          in and asks for a restart, answered Later, and the start after that settles the
#          update
#   k2_tampered
#          the same kill, then a stage file changed; the recovery plugin moves A back and
#          asks for a restart, answered Later, and A's settle in the start after that
#          reports the stage not whole
#   k3     kill after the swap; the next start settles it as applied
#   clean  A to B with no copy-back; the toolkit starts on B and its icon reimports
#   scan   a scan requested in the same frame as the close, its walk inside the folder the
#          swap moves. The row fails if the scan is not in flight across the swap. What the
#          scan does to the swap is evidence: anything but a clean apply prints a warning.
#   scan_beside
#          the same, the walk in a folder beside the one the swap moves
#   git    the update folder stays out of a real repository's index
#   link   a linked addon folder refuses the swap and its target stays whole
#   broken B does not load after a clean swap; the recovery plugin puts A back and its
#          dialog is answered Later, and the start after that runs A
#   stale_cache
#          a clean swap to B under A's class cache, which names a class_name script B's
#          plugin.gd needs where A kept it. From Godot 4.3 B runs at once; on 4.2 the
#          recovery plugin asks for one more restart, answered Later, and the start after
#          that runs B
#   held   the toolkit's folder cannot be moved: the apply waits, staged, with nothing
#          moved, and once the hold goes the next exit applies
#
# Usage: bash test/apply_kill_driver/run_legs.sh [leg...]
#   (needs a display: xvfb-run on Linux. Runs on Linux, macOS and in Git Bash on Windows.)
# Environment variables:
#   GODOT_BIN                  - Godot binary (default: "godot")
#   APPLY_KILL_OUT             - folder for everything this run writes (default: a new
#                                temp folder); logs/ under it holds the evidence
#   APPLY_KILL_SESSION_TIMEOUT - seconds one editor session gets (default: 300)
#   UT_PYTHON                  - the Python 3 that holds a file open in the held leg on
#                                Windows (default: python3 or python on the PATH, never
#                                one in a WindowsApps folder)
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
RELEASE_KEY="$OUT/release_key.pem"
RELEASE_PUBLIC_KEY="$OUT/release_key.pub.pem"
PROJECT_NAME="ApplyKillDriver"
ADDON="addons/godot_mcp_toolkit"
UPDATES="addons/.godot_mcp_toolkit_update"
RECOVERY="addons/.godot_mcp_toolkit_recovery"
TOOLKIT_CFG="\"res://$ADDON/plugin.cfg\""
DRIVER_CFG='"res://addons/apply_kill_driver/plugin.cfg"'
RECOVERY_CFG="\"res://$RECOVERY/plugin.cfg\""
DRIVER_DIR=".kill_driver"
# Where B's assets wait until the driver moves them into the update folder: the toolkit
# clears that folder at start when no journal names a release.
RELEASE_DIR="$DRIVER_DIR/release"
ONLY_IN_A="driver_only_in_a.txt"
ONLY_IN_B="driver_only_in_b.txt"
HAND_ADDED="driver_added_by_hand.txt"
ICON_IMPORT="icon.svg.import"
# A file plugin.gd preloads, relative to the addon folder: the broken B's line that does
# not parse goes there, and so does the moved B's use of the class_name script.
PRELOADED_FILE="core/modules.gd"
BROKEN_LINE="this line does not parse ("
# The class_name script A keeps in one folder and B in another, with the same .uid.
MOVED_CLASS="driver_moved_class.gd"
MOVED_CLASS_NAME="DriverMovedClass"
MOVED_CLASS_USE="static func driver_moved_class() -> $MOVED_CLASS_NAME:"
CLASS_IN_A="driver_class_in_a"
CLASS_IN_B="driver_class_in_b"
CLASS_CACHE=".godot/global_script_class_cache.cfg"
ALL_LEGS="k1 k2 k2_tampered k3 clean scan scan_beside git link broken stale_cache held"
SCAN_SEED="driver_scan_seed"
SCAN_SEED_FOLDERS=100
SCAN_SEED_FILES=30

ON_WINDOWS=0
ON_MACOS=0
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ON_WINDOWS=1 ;;
  Darwin) ON_MACOS=1 ;;
esac
# macOS has shasum and no sha256sum; both print "<hash>  <name>".
if command -v sha256sum > /dev/null 2>&1; then
  SHA256=(sha256sum)
else
  SHA256=(shasum -a 256)
fi

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
  if [ "$ON_MACOS" = 1 ]; then
    # macOS keeps both under HOME's Library, whatever the XDG variables say.
    EDITOR_CONFIG="$EDITOR_HOME/Library/Application Support/Godot"
    EDITOR_USER_DATA="$EDITOR_CONFIG/app_userdata/$PROJECT_NAME"
  else
    EDITOR_CONFIG="$EDITOR_HOME/.config/godot"
    EDITOR_USER_DATA="$EDITOR_HOME/.local/share/godot/app_userdata/$PROJECT_NAME"
  fi
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
B_BROKEN_TREE=""
B_MOVED_TREE=""
A_DIGEST=""
HELD_FOLDER=""
HOLD_PYTHON=""
HOLD_FLAG=""
HOLD_PID=""

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
  (cd "$1" && find . -type f ! -name '*.import' -print0 | LC_ALL=C sort -z | xargs -0 "${SHA256[@]}" | "${SHA256[@]}" | cut -d' ' -f1)
}

# The in-place flag of sed differs between GNU and BSD, so the edit goes through a copy.
edit_in_place() { # <file> <sed arguments...>
  local file="$1"
  shift
  sed "$@" "$file" > "$file.edited" && mv "$file.edited" "$file"
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

# The plugin entries project.godot saves, as written between the brackets.
saved_plugins() {
  text_of "$PROJECT/project.godot" | sed -n 's/^enabled=PackedStringArray(\(.*\))$/\1/p'
}

recovery_entry() { # "saved" when project.godot names the recovery plugin, else "not saved"
  if [ "$(text_of "$PROJECT/project.godot" | grep -cF "$RECOVERY_CFG")" != 0 ]; then echo saved; else echo "not saved"; fi
}

# The order that makes the driver exit before the toolkit (see the header), the recovery
# plugin first when <with recovery> is 1, where its own sorted save puts it: listed after
# the toolkit, it would start after the toolkit's start may have deleted its folder.
plugin_order() { # <with recovery: 1 or 0>
  local order
  if [ "$GODOT_MINOR" = "4.2" ]; then
    order="$TOOLKIT_CFG, $DRIVER_CFG"
  else
    order="$DRIVER_CFG, $TOOLKIT_CFG"
  fi
  if [ "$1" = 1 ]; then order="$RECOVERY_CFG, $order"; fi
  printf '%s\n' "$order"
}

# Writes plugin_order into project.godot after an editor's sorted save, keeping the
# recovery entry only when the file saves it.
write_plugin_order() {
  local with_recovery=0
  [ "$(recovery_entry)" = saved ] && with_recovery=1
  edit_in_place "$PROJECT/project.godot" \
    "s|^enabled=PackedStringArray(.*)\$|enabled=PackedStringArray($(plugin_order "$with_recovery"))|"
}

# Moves the journal's applying time two minutes back, past the window in which a start
# waits for an apply that may still be running, so the next session settles at once.
backdate_applying() {
  local journal="$PROJECT/$UPDATES/journal.json" backdated
  if [ -z "$(applying_at)" ]; then
    check "the journal holds an applying time" "none" "a time"
    return
  fi
  backdated=$(($(date +%s) - 120))
  edit_in_place "$journal" -E "s/(\"applying_at\": *)[0-9][0-9.eE+]*/\1$backdated/"
  check "the journal's applying time is two minutes back" "$(applying_at)" "$backdated"
}

applying_at() {
  text_of "$PROJECT/$UPDATES/journal.json" | sed -nE 's/.*"applying_at": *([0-9][0-9.eE+]*).*/\1/p'
}

# What the start that settles an update must leave once nothing is in flight: no recovery
# plugin on disk or in project.godot.
check_recovery_removed() {
  check "the recovery folder is gone" "$(exists "$RECOVERY")" "absent"
  check "project.godot no longer names the recovery plugin" "$(recovery_entry)" "not saved"
}

journal_reason() {
  text_of "$PROJECT/$UPDATES/journal.json" | sed -nE 's/.*"reason": *"([^"]*)".*/\1/p'
}

journal_attempts() {
  text_of "$PROJECT/$UPDATES/journal.json" | sed -nE 's/.*"attempts": *([0-9]+).*/\1/p'
}

journal_restored() { # "true" when the journal records a restore
  text_of "$PROJECT/$UPDATES/journal.json" | sed -nE 's/.*"restored": *(true|false).*/\1/p'
}

toolkit_entry() { # "saved" when project.godot names the toolkit, else "not saved"
  if [ "$(text_of "$PROJECT/project.godot" | grep -cF "$TOOLKIT_CFG")" != 0 ]; then echo saved; else echo "not saved"; fi
}

# The toolkit's start disables the recovery plugin, and the editor frees a disabled plugin
# at once; a call still running in it then prints one of these. The k2 and k2_tampered legs
# run this check, in the session the recovery plugin acts in and in the one after it.
check_no_freed_instance() { # <session>
  check "the log names no freed instance" "$(grep -acE 'previously freed|freed instance' "$LEG_LOGS/$1.log")" "0"
}

# A toolkit enabled in a session whose first scan did not register its classes fails to
# compile, and the editor prints one of these.
check_no_compile_error() { # <session>
  check "the log names no compile error" "$(grep -acE 'Parse Error|Compilation failed' "$LEG_LOGS/$1.log")" "0"
}

# What a start that found no toolkit left, for a reader of a run where nothing set it right.
record_after_start() { # <session>
  echo "  record: after $1 the journal says '$(journal_state)', the toolkit's folder is $(exists "$ADDON"), its version '$(live_version)'"
}

class_cache_names() { # <folder in the addon>: "yes" when the class cache names the class there
  if [ "$(text_of "$PROJECT/$CLASS_CACHE" | grep -cF "res://$ADDON/$1/$MOVED_CLASS")" != 0 ]; then echo yes; else echo no; fi
}

# The class_name script and its .uid, written into <folder>.
write_moved_class() { # <folder>
  mkdir -p "$1" || return 1
  printf 'extends RefCounted\nclass_name %s\n' "$MOVED_CLASS_NAME" > "$1/$MOVED_CLASS" || return 1
  printf 'uid://drivermovedclass' > "$1/$MOVED_CLASS.uid"
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
  # Recorded for a reader. A kill exits 0 on Windows and 137 on Linux and macOS, so nothing
  # grades it.
  echo "editor_exit=$editor_exit" >> "$LEG_LOGS/$id.txt"
  echo "seconds=$((SECONDS - started))" >> "$LEG_LOGS/$id.txt"
  cp "$PROJECT/$UPDATES/install.log" "$LEG_LOGS/$id.install.log" 2>/dev/null || true
  cp "$PROJECT/$UPDATES/journal.json" "$LEG_LOGS/$id.journal.json" 2>/dev/null || true
  check "session $id started" "$(note "$id" session_started)" "1"
}

# A release of <version> built by the real script in a throwaway copy of this checkout.
# The copy gets a commit of its own, since the manifest's expiry reads HEAD's time. A
# <change> function, when given, runs on the copy's addon folder before the build.
build_release() { # <version> <file only this version has> <out folder> <private key> <public key> [change]
  local version="$1" only_here="$2" out="$3" change="${6:-}" tree="$OUT/build/$1"
  mkdir -p "$tree/addons" "$out"
  cp -r "$REPO_ROOT/$ADDON" "$tree/addons/" || return 1
  cp -r "$REPO_ROOT/scripts" "$tree/" || return 1
  # A checkout an editor has opened holds .import files; a release's clean checkout has none.
  find "$tree/addons" -name '*.import' -delete
  rm -f "$tree/$ADDON/release_files.sha256"
  ut_embed_trust "$tree/$ADDON" "$4" "$5" || return 1
  edit_in_place "$tree/$ADDON/plugin.cfg" -E "s/^version=\"[^\"]*\"/version=\"$version\"/" || return 1
  printf 'only in %s\n' "$version" > "$tree/$ADDON/$only_here"
  if [ -n "$change" ]; then "$change" "$tree/$ADDON" || return 1; fi
  git -C "$tree" init -q || return 1
  git -C "$tree" -c user.name=driver -c user.email=driver@example.invalid commit -q --allow-empty -m build || return 1
  (cd "$tree" && bash scripts/build-plugin-release.sh) || return 1
  cp "$tree/dist-plugin/"* "$out/" || return 1
  rm -rf "$tree"
}

# sign-release.sh reads a passphrase line from a pipe even for a plain key.
sign_release() { # <out folder holding B's build>
  echo unused | bash "$REPO_ROOT/scripts/sign-release.sh" \
    "$1/godot-mcp-toolkit-$B_VERSION.update.json" "$RELEASE_KEY" "$RELEASE_PUBLIC_KEY" > /dev/null
}

break_preloaded_file() { # <addon folder>
  printf '\n%s\n' "$BROKEN_LINE" >> "$1/$PRELOADED_FILE"
}

# The class_name script goes into B's folder, and the preloaded file gets a function typed
# with that class, so B's plugin.gd compiles only once the class cache names the script
# where B keeps it.
move_class_to_b() { # <addon folder>
  write_moved_class "$1/$CLASS_IN_B" || return 1
  printf '\n\n%s\n\treturn null\n' "$MOVED_CLASS_USE" >> "$1/$PRELOADED_FILE"
}

# A build of B with <change> run on its addon folder, signed as B is: its assets go to
# releases_<name> and its unpacked zip to b_<name>_tree, both under the run's folder.
build_b_variant() { # <name> <change>
  local releases="$OUT/releases_$1"
  build_release "$B_VERSION" "$ONLY_IN_B" "$releases" "$RELEASE_KEY" "$RELEASE_PUBLIC_KEY" "$2" \
    || die "could not build $B_VERSION ($1)"
  sign_release "$releases" || die "could not sign $B_VERSION ($1)"
  unzip -q "$releases/godot-mcp-toolkit-$B_VERSION.zip" -d "$OUT/b_$1_tree" || die "could not unpack $B_VERSION ($1)"
}

preloads_preloaded_file() { # <addon folder>: whether its plugin.gd preloads that file
  grep -qF "preload(\"res://$ADDON/$PRELOADED_FILE\")" "$1/plugin.gd"
}

# "yes" when <addon folder>'s plugin.gd preloads the broken file and that file ends in the
# line that does not parse.
holds_broken_preload() { # <addon folder>
  if preloads_preloaded_file "$1" \
    && [ "$(text_of "$1/$PRELOADED_FILE" | tail -1)" = "$BROKEN_LINE" ]; then
    echo yes
  else
    echo no
  fi
}

# "yes" when <addon folder> keeps the class_name script in B's folder and not in A's, and
# a file its plugin.gd preloads uses that class.
holds_moved_class() { # <addon folder>
  if [ -f "$1/$CLASS_IN_B/$MOVED_CLASS" ] && [ ! -e "$1/$CLASS_IN_A" ] \
    && preloads_preloaded_file "$1" && grep -qF "$MOVED_CLASS_USE" "$1/$PRELOADED_FILE"; then
    echo yes
  else
    echo no
  fi
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
  local private_key="$RELEASE_KEY" public_key="$RELEASE_PUBLIC_KEY"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$private_key" 2>/dev/null || die "could not make a key"
  openssl pkey -in "$private_key" -pubout -out "$public_key" || die "could not read the key's public half"

  echo "=== Build: A $A_VERSION, B $B_VERSION ==="
  build_release "$A_VERSION" "$ONLY_IN_A" "$releases" "$private_key" "$public_key" || die "could not build $A_VERSION"
  build_release "$B_VERSION" "$ONLY_IN_B" "$releases" "$private_key" "$public_key" || die "could not build $B_VERSION"

  sign_release "$releases" || die "could not sign $B_VERSION"
  build_b_variant broken break_preloaded_file
  B_BROKEN_TREE="$OUT/b_broken_tree/$ADDON"
  build_b_variant moved move_class_to_b
  B_MOVED_TREE="$OUT/b_moved_tree/$ADDON"
  check "B built with a file plugin.gd preloads that does not parse" "$(holds_broken_preload "$B_BROKEN_TREE")" "yes"
  check "B built with the class_name script in another folder than A's, used by a file plugin.gd preloads" \
    "$(holds_moved_class "$B_MOVED_TREE")" "yes"

  unzip -q "$releases/godot-mcp-toolkit-$A_VERSION.zip" -d "$PROJECT" || die "could not unpack A"
  printf 'put here by hand\n' > "$PROJECT/$ADDON/$HAND_ADDED"
  B_TREE="$OUT/b_tree"
  unzip -q "$releases/godot-mcp-toolkit-$B_VERSION.zip" -d "$B_TREE" || die "could not unpack B"
  B_TREE="$B_TREE/$ADDON"

  cp -r "$REPO_ROOT/test/apply_kill_driver/plugin" "$PROJECT/addons/apply_kill_driver"
  mkdir -p "$PROJECT/$DRIVER_DIR"
  cp "$public_key" "$PROJECT/$DRIVER_DIR/public_key.pem"
  local enabled
  enabled="$(plugin_order 0)"
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
  # The legs that stage another build of B start from here.
  cp -a "$PROJECT" "$OUT/unstaged" || die "could not keep the project from before staging"

  stage_release "$releases" "$B_TREE"
  A_DIGEST="$(tree_digest "$PROJECT/$ADDON")"
  [ "$FAILED" = 0 ] || die "the template did not come out as the legs need it"
}

# Stages the B in <releases> by the real stepper in a real editor, killed at its exit, and
# checks that stage against <B's addon folder> unpacked from the same zip.
stage_release() { # <releases> <B's addon folder>
  local releases="$1" b_tree="$2"
  mkdir -p "$PROJECT/$RELEASE_DIR"
  cp "$releases/godot-mcp-toolkit-$B_VERSION."* "$PROJECT/$RELEASE_DIR/"
  session stage "stage=1" "from=$A_VERSION" "to=$B_VERSION" "kill_at_exit=1"
  check "the built zip passes the name rules and stages whole" "$(note stage stage_state)" "done"
  check "the stepper wrote every listed file" "$(note stage stage_written)" "$(note stage stage_total)"
  check "the stage equals the zip" "$(tree_digest "$PROJECT/$UPDATES/stage")" "$(tree_digest "$b_tree")"
  check "the journal says staged" "$(journal_state)" "staged"
  echo "  record: staging's begin took $(note stage stage_begin_ms) ms, its longest step $(note stage stage_longest_step_ms) ms"

  check "the ignore file for git holds a star" "$(text_of "$PROJECT/$UPDATES/.gitignore")" "*"
  check "the ignore file for Perforce holds a star" "$(text_of "$PROJECT/$UPDATES/.p4ignore")" "*"
  check "the ignore file for the engine is there and empty" \
    "$( [ -f "$PROJECT/$UPDATES/.gdignore" ] && wc -c < "$PROJECT/$UPDATES/.gdignore" | tr -d ' ' )" "0"

  check "staging installs the recovery plugin" "$(note stage recovery_installed)" "true"
  check "the recovery install reports no failure" "$(note stage recovery_failure)" ""
  check "project.godot saves the recovery plugin's entry" "$(recovery_entry)" "saved"
  check "the recovery folder's ignore file for git holds a star" "$(text_of "$PROJECT/$RECOVERY/.gitignore")" "*"
  check "the recovery folder's ignore file for Perforce holds a star" "$(text_of "$PROJECT/$RECOVERY/.p4ignore")" "*"
  check "the recovery folder has no ignore file for the engine" "$(exists "$RECOVERY/.gdignore")" "absent"
  # Staging's save sorted the list.
  [ "$GODOT_MINOR" = "4.2" ] && { write_plugin_order || die "could not write the plugin order back"; }
  check "project.godot saves the plugins in the order the legs need" "$(saved_plugins)" "$(plugin_order 1)"
}

begin_leg() { # <leg> [project to copy: the template by default]
  LEG="$1"
  LEG_LOGS="$LOGS/$LEG"
  PROJECT="$OUT/legs/$LEG"
  echo ""
  echo "=== Leg $LEG ==="
  mkdir -p "$OUT/legs" "$LEG_LOGS"
  cp -a "${2:-$OUT/template}" "$PROJECT" || die "could not copy the template for $LEG"
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

  backdate_applying
  session retry settle=1 apply=1
  check "settle puts it back to waiting" "$(note retry settle_report)" "waiting"
  check "the next exit retries and applies" "$(note retry apply_state)" "applied"
  check "the retry walked every step" "$(steps_of retry)" "checked,applying,live_moved,stage_moved"
  check "the journal says applied" "$(journal_state)" "applied"

  session after_retry settle=1 wait_toolkit=1
  check_updated_on_b after_retry
  check_recovery_removed
}

# A kill between the renames: A has gone to the backup, B is still the stage, and no
# toolkit folder is live.
kill_between_renames() {
  session kill apply=1 kill_at=live_moved
  check_killed_at kill live_moved "checked,applying,live_moved"
  check "the journal says applying" "$(journal_state)" "applying"
  check "the live folder is gone" "$(exists "$ADDON")" "absent"
  check "the backup holds A, whole" "$(tree_digest "$PROJECT/$UPDATES/backup-$A_VERSION")" "$A_DIGEST"
  check "the stage is whole" "$(tree_digest "$PROJECT/$UPDATES/stage")" "$(tree_digest "$B_TREE")"
}

# The settler sits in the folder that is gone, so the start finds no toolkit. The recovery
# plugin, outside that folder, moves the whole stage in and asks for a restart: that start's
# first scan found no toolkit folder, so the toolkit's classes load only at the next one.
# The user answers Later, and the start after that settles the update.
leg_k2() {
  begin_leg k2
  kill_between_renames

  backdate_applying
  session next_start press_later=1
  check "the next start finds no toolkit" "$(note next_start toolkit_folder_present)" "false"
  check "the recovery plugin's dialog says what it did" "$(note next_start recovery_dialog_text)" \
    "The update to version $B_VERSION stopped partway, and it is now finished. Restart the editor to load it.\\n\\nUntil the restart, the toolkit stays off."
  check "the dialog was answered Later" "$(note next_start later_pressed)" "1"
  check "the toolkit stays off" "$(note next_start toolkit_enabled)" "false"
  check_no_compile_error next_start
  check "the live folder is B, whole" "$(tree_digest "$PROJECT/$ADDON")" "$(tree_digest "$B_TREE")"
  check "the backup is still whole" "$(tree_digest "$PROJECT/$UPDATES/backup-$A_VERSION")" "$A_DIGEST"
  check "the journal says applied" "$(journal_state)" "applied"
  check "project.godot keeps the toolkit's entry" "$(toolkit_entry)" "saved"
  check "the recovery folder stays for the next start" "$(exists "$RECOVERY")" "present"
  check "project.godot keeps the recovery plugin's entry" "$(recovery_entry)" "saved"
  check_no_freed_instance next_start
  record_after_start next_start

  session after settle=1 wait_toolkit=1
  check_updated_on_b after
  check "the toolkit is enabled" "$(note after toolkit_enabled)" "true"
  check "the live folder is B, whole" "$(tree_digest "$PROJECT/$ADDON")" "$(tree_digest "$B_TREE")"
  check "project.godot keeps the toolkit's entry" "$(toolkit_entry)" "saved"
  check_no_compile_error after
  check_recovery_removed
  check_no_freed_instance after
}

# A stage that is not whole is never moved in: the recovery plugin puts A back and asks for
# a restart, the user answers Later, and A's start after that settles the update as failed.
leg_k2_tampered() {
  begin_leg k2_tampered
  kill_between_renames
  printf 'changed after the kill\n' >> "$PROJECT/$UPDATES/stage/$ONLY_IN_B"

  backdate_applying
  session next_start press_later=1
  check "the next start finds no toolkit" "$(note next_start toolkit_folder_present)" "false"
  check "the recovery plugin's dialog says what it did" "$(note next_start recovery_dialog_text)" \
    "The update to version $B_VERSION stopped partway and could not be finished, so $A_VERSION was put back. Restart the editor to load it.\\n\\nUntil the restart, the toolkit stays off."
  check "the dialog was answered Later" "$(note next_start later_pressed)" "1"
  check "the toolkit stays off" "$(note next_start toolkit_enabled)" "false"
  check_no_compile_error next_start
  check "the live folder is A, whole" "$(tree_digest "$PROJECT/$ADDON")" "$A_DIGEST"
  check "the backup went back in place" "$(exists "$UPDATES/backup-$A_VERSION")" "absent"
  check "the journal still says applying" "$(journal_state)" "applying"
  check "project.godot keeps the toolkit's entry" "$(toolkit_entry)" "saved"
  check "the recovery folder stays for the next start" "$(exists "$RECOVERY")" "present"
  check "project.godot keeps the recovery plugin's entry" "$(recovery_entry)" "saved"
  check_no_freed_instance next_start
  record_after_start next_start

  session after settle=1 wait_toolkit=1
  check "the toolkit reached its loaded state" "$(note after toolkit_loaded)" "true"
  check "the toolkit is enabled" "$(note after toolkit_enabled)" "true"
  check "the running toolkit reports A" "$(note after toolkit_version)" "$A_VERSION"
  check "settle reports the failure" "$(note after settle_report)" "failed"
  check "the failure names the stage" "$(note after settle_reason)" "the stage or its zip is not whole"
  check "the live folder is A, whole" "$(tree_digest "$PROJECT/$ADDON")" "$A_DIGEST"
  check "the backup went back in place" "$(exists "$UPDATES/backup-$A_VERSION")" "absent"
  check "the journal is gone" "$(exists "$UPDATES/journal.json")" "absent"
  check "project.godot keeps the toolkit's entry" "$(toolkit_entry)" "saved"
  check_no_compile_error after
  check_recovery_removed
  check_no_freed_instance after
}

leg_k3() {
  begin_leg k3
  session kill apply=1 kill_at=stage_moved
  check_killed_at kill stage_moved "checked,applying,live_moved,stage_moved"
  check "the journal still says applying" "$(journal_state)" "applying"
  check "the live folder is B, whole" "$(tree_digest "$PROJECT/$ADDON")" "$(tree_digest "$B_TREE")"

  backdate_applying
  session next_start settle=1 wait_toolkit=1
  check_updated_on_b next_start
  check_recovery_removed
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
  check_recovery_removed
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
  check "after staging, it stages nothing from the recovery folder" "$(staged_under "$RECOVERY/")" "0"
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
  check "after the swap, it stages nothing from the recovery folder" "$(staged_under "$RECOVERY/")" "0"
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

# A clean swap to a B that does not load. The next start drops the toolkit, the recovery
# plugin puts A back and asks for a restart, the user answers Later, and the start after
# that runs A and settles the update as failed.
leg_broken() {
  begin_leg broken "$OUT/unstaged"
  stage_release "$OUT/releases_broken" "$B_BROKEN_TREE"
  session apply apply=1
  check "the apply finished" "$(note apply apply_state)" "applied"
  check "the live folder is the broken B, whole" "$(tree_digest "$PROJECT/$ADDON")" "$(tree_digest "$B_BROKEN_TREE")"

  session next_start press_later=1
  check "B's toolkit does not load" "$(note next_start toolkit_loaded)" "false"
  check "the toolkit stays off" "$(note next_start toolkit_enabled)" "false"
  check "the recovery plugin's dialog says what it did" "$(note next_start recovery_dialog_text)" \
    "Version $B_VERSION did not load in Godot $GODOT_MINOR, so $A_VERSION was put back. Restart the editor to load it.\\n\\nUntil the restart, the toolkit stays off."
  check "the dialog was answered Later" "$(note next_start later_pressed)" "1"
  check "the live folder is A, whole" "$(tree_digest "$PROJECT/$ADDON")" "$A_DIGEST"
  check "the backup went back in place" "$(exists "$UPDATES/backup-$A_VERSION")" "absent"
  check "the broken B is gone" "$(exists "$UPDATES/broken-$B_VERSION")" "absent"
  check "the journal says not applied" "$(journal_state)" "not_applied"
  check "the journal records the restore" "$(journal_restored)" "true"
  check "project.godot keeps the toolkit's entry" "$(toolkit_entry)" "saved"
  check "the recovery folder stays for the next start" "$(exists "$RECOVERY")" "present"
  record_after_start next_start

  session after settle=1 wait_toolkit=1
  check "the toolkit reached its loaded state" "$(note after toolkit_loaded)" "true"
  check "the toolkit is enabled" "$(note after toolkit_enabled)" "true"
  check "the running toolkit reports A" "$(note after toolkit_version)" "$A_VERSION"
  check "settle reports the failure" "$(note after settle_report)" "failed"
  check "settle reports the restore" "$(note after settle_restored)" "true"
  check "the failure names the version and the engine" "$(note after settle_reason)" \
    "version $B_VERSION did not load in Godot $GODOT_MINOR"
  check "the journal is gone" "$(exists "$UPDATES/journal.json")" "absent"
  check_recovery_removed
}

# A clean swap to B under the class cache A's editor left, which names a class_name script
# in a folder B no longer has, while B's plugin.gd needs that class to compile. From Godot
# 4.3 the start's first scan names the class where B keeps it before any plugin starts, so
# B runs at once and the recovery plugin leaves it alone. Godot 4.2 starts the plugins
# before that scan, so B stays enabled but never starts: the recovery plugin asks for one
# more restart and moves nothing, the user answers Later, and the start after that runs B.
leg_stale_cache() {
  begin_leg stale_cache "$OUT/unstaged"
  write_moved_class "$PROJECT/$ADDON/$CLASS_IN_A" || die "could not write the class into A"
  stage_release "$OUT/releases_moved" "$B_MOVED_TREE"
  check "the class cache names the class in A's folder" "$(class_cache_names "$CLASS_IN_A")" "yes"
  local a_digest runs_b=next_start
  a_digest="$(tree_digest "$PROJECT/$ADDON")"

  session apply apply=1
  check "the apply finished" "$(note apply apply_state)" "applied"
  check "the class cache still names A's folder after the swap" "$(class_cache_names "$CLASS_IN_A")" "yes"

  if [ "$GODOT_MINOR" = "4.2" ]; then
    session next_start press_later=1
    check "the recovery plugin is enabled at the start" "$(note next_start recovery_enabled)" "true"
    check "the recovery plugin's dialog asks for one more restart" "$(note next_start recovery_dialog_text)" \
      "Version $B_VERSION is installed, and Godot $GODOT_MINOR needs one more restart to load it.\\n\\nUntil the restart, the toolkit does not run."
    check "the dialog was answered Later" "$(note next_start later_pressed)" "1"
    check "the toolkit is enabled" "$(note next_start toolkit_enabled)" "true"
    check "B's toolkit never started" "$(note next_start toolkit_loaded)" "false"
    check "the recovery plugin left B in place" "$(tree_digest "$PROJECT/$ADDON")" "$(tree_digest "$B_MOVED_TREE")"
    check "the backup holds A, whole" "$(tree_digest "$PROJECT/$UPDATES/backup-$A_VERSION")" "$a_digest"
    check "the journal says applied" "$(journal_state)" "applied"
    check "the recovery folder stays for the next start" "$(exists "$RECOVERY")" "present"
    check "the class cache names the class in B's folder" "$(class_cache_names "$CLASS_IN_B")" "yes"
    record_after_start next_start
    runs_b=after
    session after settle=1 wait_toolkit=1
    check_no_compile_error after
  else
    session next_start settle=1 wait_toolkit=1
  fi
  check "the recovery plugin is enabled at the start" "$(note "$runs_b" recovery_enabled)" "true"
  check "settle reports the update" "$(note "$runs_b" settle_report)" "updated"
  check "B is on disk" "$(live_version)" "$B_VERSION"
  check "the toolkit reached its loaded state" "$(note "$runs_b" toolkit_loaded)" "true"
  check "the running toolkit reports B" "$(note "$runs_b" toolkit_version)" "$B_VERSION"
  check "the toolkit is enabled" "$(note "$runs_b" toolkit_enabled)" "true"
  check "the recovery plugin left B in place" "$(tree_digest "$PROJECT/$ADDON")" "$(tree_digest "$B_MOVED_TREE")"
  check "the backup holds A, whole" "$(tree_digest "$PROJECT/$UPDATES/backup-$A_VERSION")" "$a_digest"
  check "the journal is gone" "$(exists "$UPDATES/journal.json")" "absent"
  check_recovery_removed
}

# The swap's first rename moves the toolkit's folder from addons/ into the update folder,
# which needs addons/ writable, so a read-only addons folder refuses it on Linux and macOS.
# NTFS ignores chmod but refuses to rename a folder while a file in it is open, so on
# Windows <python> holds one open until its flag file goes, or until a session's timeout
# and a minute more have passed. Returns 1 when nothing holds.
hold_toolkit() { # <python: Windows only>
  if [ "$ON_WINDOWS" != 1 ]; then
    # Staging made the recovery plugin's folder; in a read-only addons folder nothing could.
    if [ ! -d "$PROJECT/$RECOVERY" ]; then
      echo "the recovery plugin's folder is missing before the hold" >&2
      return 1
    fi
    chmod a-w "$PROJECT/addons" || return 1
    HELD_FOLDER="$PROJECT/addons"
    # Root writes through a read-only folder, so for root nothing would hold.
    if [ -w "$HELD_FOLDER" ]; then
      release_toolkit
      echo "the addons folder stays writable after chmod a-w; is this run root?" >&2
      return 1
    fi
    return 0
  fi
  HOLD_FLAG="$OUT/hold.flag"
  "$1" -c '
import os, sys, time
held = open(sys.argv[1], "rb")
open(sys.argv[2], "w").close()
deadline = time.time() + float(sys.argv[3])
while os.path.exists(sys.argv[2]) and time.time() < deadline:
    time.sleep(0.2)
' "$(cygpath -w "$PROJECT/$ADDON/$ONLY_IN_A")" "$(cygpath -w "$HOLD_FLAG")" "$((SESSION_TIMEOUT + 60))" &
  HOLD_PID=$!
  for _ in $(seq 1 50); do
    [ -f "$HOLD_FLAG" ] && return 0
    sleep 0.2
  done
  release_toolkit
  return 1
}

# Ends the hold, whichever kind holds; does nothing when none does.
release_toolkit() {
  if [ -n "$HELD_FOLDER" ]; then
    chmod u+w "$HELD_FOLDER"
    HELD_FOLDER=""
  fi
  if [ -n "$HOLD_PID" ]; then
    rm -f "$HOLD_FLAG"
    wait "$HOLD_PID" 2>/dev/null
    HOLD_PID=""
    HOLD_FLAG=""
  fi
}

# A toolkit folder that cannot be moved is something that may pass by itself: the exit's
# apply waits with the journal staged and nothing moved, and once the hold goes the next
# exit applies.
leg_held() {
  begin_leg held
  # A run that ends inside the session still lets go of the folder.
  trap release_toolkit EXIT
  hold_toolkit "$HOLD_PYTHON" || die "could not hold the toolkit's folder"
  session held apply=1
  release_toolkit
  trap - EXIT
  check "the apply waits" "$(note held apply_state)" "staged"
  check "the wait names the move" "$(note held apply_reason)" \
    "could not move the installed toolkit to backup-$A_VERSION"
  check "the apply stopped at the first rename" "$(steps_of held)" "checked,applying"
  check "the journal says staged" "$(journal_state)" "staged"
  check "the journal keeps the reason" "$(journal_reason)" \
    "could not move the installed toolkit to backup-$A_VERSION"
  check "the journal holds no applying time" "$(applying_at)" ""
  check "the live folder is still A" "$(tree_digest "$PROJECT/$ADDON")" "$A_DIGEST"
  check "no backup was taken" "$(exists "$UPDATES/backup-$A_VERSION")" "absent"
  check "the stage is whole" "$(tree_digest "$PROJECT/$UPDATES/stage")" "$(tree_digest "$B_TREE")"
  check "the recovery folder stays" "$(exists "$RECOVERY")" "present"
  check "project.godot keeps the recovery plugin's entry" "$(recovery_entry)" "saved"
  # The toolkit's own exit comes after the driver's apply and tries again.
  echo "  record: the journal counts $(journal_attempts) attempts; the install log's applies of $B_VERSION: $(grep -F "apply $B_VERSION:" "$LEG_LOGS/held.install.log" 2>/dev/null | paste -sd'|' -)"

  session next_start settle=1 apply=1
  check "settle reports the update waiting" "$(note next_start settle_report)" "waiting"
  check "the next exit applies" "$(note next_start apply_state)" "applied"
  check "it walked every step" "$(steps_of next_start)" "checked,applying,live_moved,stage_moved"
  check "the journal says applied" "$(journal_state)" "applied"

  session after settle=1 wait_toolkit=1
  check_updated_on_b after
  check_recovery_removed
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
# Found before the template's sessions, so a missing Python stops the run at its start.
if [ "$ON_WINDOWS" = 1 ] && [[ " $LEGS " == *" held "* ]]; then
  HOLD_PYTHON="$(ut_python_bin)" || die "the held leg needs Python 3 on Windows"
fi

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
