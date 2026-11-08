#!/usr/bin/env bash
# scripts/test_framework/update_gui.sh
# The self-update's interactive checks, in editors with a window on a virtual display.
#
# Like update_flow.sh, it installs the release built from this tree over the same tree
# one version older, which trusts a key made for the run, with a local HTTP server in
# place of GitHub and the Asset Store. Each scenario boots editors with a window on a
# virtual X display (Xvfb) and a test-only plugin (test/update_gui_driver/) that
# presses the update badge's and the dialogs' buttons the way a click does; the script
# then checks what the plugin recorded and what the project holds.
#
# Scenarios (UPDATE_GUI_SCENARIOS, default all):
#   restart      Update with nothing open: Godot 4.4 and later restart on their own once
#                the release is staged, 4.2 and 4.3 open the ready view and its Restart
#                restarts; the next editor runs the release and says so
#   later        the editor-start window: Later brings it back at the next start, Skip
#                this version hides the version, and a .mcp.json set by hand adds no
#                line to it
#   unsaved     a script edited before Update: the ready view opens, Restart refuses
#                while the edit is unsaved, Not now collapses the view, and once the
#                script is saved Restart installs the release
#   untitled     a scene that was never saved: the ready view opens and the editor does
#                not restart; its exit installs the release
#   quit         Update, then the editor's quit shortcut closes the window, and that
#                exit installs the release
#   server       the release recommends another server than the one the toolkit wrote
#                into .mcp.json: the badge says the pin will move, the update moves it
#                and keeps the user's env key and the other server, the notice says so,
#                and its Undo puts the pin back
#   server_edit  a pin equal to what the installed toolkit recommends, with no record of
#                a write, moves the same way; then .mcp.json is edited by hand: Undo
#                leaves the edit, and Undo and the moved line go
#   server_hand  a .mcp.json set by hand: the pin stays and nothing is said
#   server_prompt  a pin equal only to this machine's last write: the editor-start window
#                says it will move, and Later moves nothing
#   server_readonly  a read-only .mcp.json. On Windows the move's write fails: the notice
#                says so and offers Update .mcp.json, the file keeps its bytes, and no
#                write is recorded. On Linux and macOS the engine's safe save renames over
#                the file, which a missing write bit does not stop, so the pin moves
#   server_gap  an MCP server connects, older and then newer than the recommended
#                version: the dock's status panel says so, and follows a setting that
#                changes with no server event. The MCP server is this test's own
#                WebSocket client, since the job runs no real one
#   major        a major release: the badge only links
#
# Usage: scripts/test_framework/update_gui.sh [godot-binary]
# Exit 0 = every scenario passed, 1 = a scenario failed, 2 = setup error.
#
# Environment variables:
#   GODOT_BIN              Godot binary (default: first arg, or "godot")
#   UPDATE_GUI_SCENARIOS   the scenarios to run, space-separated
#   UPDATE_GUI_SKIP_BUILD  set to 1 to test the zip and manifest already in dist-plugin/
#   UPDATE_GUI_KEEP        set to 1 to keep the scratch folder for forensics
#   UPDATE_GUI_ARTIFACTS   a folder to copy each scenario's screenshots and logs into
#   XVFB_BIN, XDOTOOL_BIN  the Xvfb and xdotool binaries (default: found on PATH)
#   UT_PYTHON              the Python 3 to run (default: python3 or python on the
#                          PATH, never one in a WindowsApps folder)
# Needs Python 3, openssl, Xvfb, xdotool, an OpenGL driver Xvfb can serve (Mesa) and,
# unless UPDATE_GUI_SKIP_BUILD is set, zip. Runs everything under a scratch HOME, so
# the machine's own registry and editor settings are never touched. On Windows (Git
# Bash) the editors open on the desktop instead, and the quit scenario, which needs
# xdotool, is skipped.

set -uo pipefail

GODOT_BIN="${GODOT_BIN:-${1:-godot}}"
SCENARIOS="${UPDATE_GUI_SCENARIOS:-restart later unsaved untitled quit server server_edit server_hand server_prompt server_readonly server_gap major}"
XVFB_BIN="${XVFB_BIN:-Xvfb}"
XDOTOOL_BIN="${XDOTOOL_BIN:-xdotool}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/release_files.sh
source "${REPO_ROOT}/scripts/lib/release_files.sh"
# shellcheck source=../lib/update_test_env.sh
source "${REPO_ROOT}/scripts/lib/update_test_env.sh"

OS="$(ut_os)"
PYTHON_BIN="$(ut_python_bin)" || { echo "ERROR: Python 3 is required" >&2; exit 2; }
TOOLS=(openssl)
[[ "${UPDATE_GUI_SKIP_BUILD:-0}" == 1 ]] || TOOLS+=(zip)
[[ "${OS}" == windows ]] || TOOLS+=("${XVFB_BIN}" "${XDOTOOL_BIN}")
for tool in "${TOOLS[@]}"; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "ERROR: ${tool} is required" >&2; exit 2; }
done

# Whether an editor whose command line holds `pattern` is running (`running`), or stops
# them (`stop`). A restart starts an editor that is no child of this script, so the
# command line is how it is found. Windows has no pgrep or pkill; PowerShell reads the
# command lines there.
editors() {
  local action="$1" pattern="$2"
  if [[ "${OS}" != windows ]]; then
    if [[ "${action}" == stop ]]; then pkill -f -- "${pattern}"; else pgrep -f -- "${pattern}" > /dev/null; fi
    return
  fi
  local verb='exit [int](-not $found)'
  [[ "${action}" == stop ]] && verb='$found | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }'
  powershell.exe -NoProfile -NonInteractive -Command \
    "\$found = @(Get-CimInstance Win32_Process | Where-Object { \$_.ProcessId -ne \$PID -and \$_.CommandLine -like '*${pattern}*' }); ${verb}"
}

# The form a path takes on an editor's command line.
native_path() {
  if [[ "${OS}" == windows ]]; then cygpath -m "$1"; else echo "$1"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/update_gui.XXXXXX")"
SERVER_PID=""
XVFB_PID=""
cleanup() {
  [[ -n "${SERVER_PID}" ]] && kill "${SERVER_PID}" 2>/dev/null
  editors stop "--path $(native_path "${WORK}")/" 2>/dev/null
  [[ -n "${XVFB_PID}" ]] && kill "${XVFB_PID}" 2>/dev/null && wait "${XVFB_PID}" 2>/dev/null
  if [[ -n "${UPDATE_GUI_ARTIFACTS:-}" ]]; then
    mkdir -p "${UPDATE_GUI_ARTIFACTS}"
    cp -r "${WORK}/shots" "${UPDATE_GUI_ARTIFACTS}/" 2>/dev/null
    for log in "${WORK}"/*/boot.log "${WORK}"/*/results_*.txt; do
      [[ -f "${log}" ]] && cp "${log}" "${UPDATE_GUI_ARTIFACTS}/$(basename "$(dirname "${log}")")_$(basename "${log}")"
    done
  fi
  if [[ "${UPDATE_GUI_KEEP:-0}" == 1 ]]; then
    echo "kept ${WORK}"
  else
    rm -rf "${WORK}"
  fi
}
trap cleanup EXIT

export HOME="${WORK}/home" XDG_DATA_HOME="${WORK}/home/.local/share" \
  XDG_CONFIG_HOME="${WORK}/home/.config" XDG_CACHE_HOME="${WORK}/home/.cache"
export GODOT_MCP_RUNTIME=0
mkdir -p "${HOME}" "${WORK}/shots"
if [[ "${OS}" == windows ]]; then
  mkdir -p "${HOME}/AppData/Roaming" "${HOME}/AppData/Local"
  APPDATA="$(cygpath -w "${HOME}/AppData/Roaming")"
  LOCALAPPDATA="$(cygpath -w "${HOME}/AppData/Local")"
  export APPDATA LOCALAPPDATA
fi

FAILED=0
fail() { echo "  FAIL [${SCENARIO}] $*"; FAILED=1; }
pass() { echo "  PASS [${SCENARIO}] $*"; }

# ── The release under test ──────────────────────────────────────────────────
if [[ "${UPDATE_GUI_SKIP_BUILD:-0}" != 1 ]]; then
  (cd "${REPO_ROOT}" && bash scripts/build-plugin-release.sh) > "${WORK}/build.log" 2>&1 \
    || { cat "${WORK}/build.log"; echo "ERROR: build-plugin-release.sh failed" >&2; exit 2; }
fi
NEW_VERSION="$(sed -nE 's/^version="([^"]+)".*/\1/p' "${REPO_ROOT}/addons/godot_mcp_toolkit/plugin.cfg" | tr -d '\r')"
RELEASE_ZIP="${REPO_ROOT}/dist-plugin/godot-mcp-toolkit-${NEW_VERSION}.zip"
RELEASE_MANIFEST="${REPO_ROOT}/dist-plugin/godot-mcp-toolkit-${NEW_VERSION}.update.json"
[[ -f "${RELEASE_ZIP}" && -f "${RELEASE_MANIFEST}" ]] || { echo "ERROR: no release zip or manifest for ${NEW_VERSION}" >&2; exit 2; }
OLD_VERSION="$(ut_previous_version "${NEW_VERSION}")"
if [[ -z "${OLD_VERSION}" ]]; then
  echo "SKIP: ${NEW_VERSION} is a major release, which the toolkit only links to; nothing to install."
  exit 0
fi
NEXT_MAJOR="$(( ${NEW_VERSION%%.*} + 1 )).0.0"
COMPATIBLE_SERVER="$(sed -nE 's/^const COMPATIBLE_SERVER_VERSION := "([^"]+)".*/\1/p' \
  "${REPO_ROOT}/addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd" | tr -d '\r')"
# A server no release pins, for the installed toolkit of the .mcp.json scenarios.
OLD_SERVER="0.0.1"
# What the installed toolkit recommends when the pin must not count as its recommended
# version: a pin equal to that version is the toolkit's own and moves.
OTHER_RECOMMENDED="0.0.2"
PIN_PREVIEW_LINE="This also changes the MCP server in .mcp.json from ${OLD_SERVER} to ${COMPATIBLE_SERVER}. Restart your AI client after the update."
PIN_MOVED_LINE=".mcp.json now runs MCP server ${COMPATIBLE_SERVER} instead of ${OLD_SERVER}. Restart your AI client to use it."
# The server_edit scenario's hand edit, and the versions the server_gap scenario's MCP
# servers report around the version its installed toolkit recommends. These pass the
# toolkit's floors and differ from that version by a patch.
export UPDATE_GUI_HAND_SERVER="0.0.9"
GAP_RECOMMENDED="1.5.5"
export UPDATE_GUI_OLDER_SERVER="1.5.4" UPDATE_GUI_NEWER_SERVER="1.5.6"
ENGINE_MINOR="$("${GODOT_BIN}" --version | cut -d. -f1-2)"

# ── The virtual display and the editor settings ─────────────────────────────
if [[ "${OS}" != windows ]]; then
  DISPLAY_NUMBER=""
  for number in $(seq 90 99); do
    [[ -e "/tmp/.X${number}-lock" ]] || { DISPLAY_NUMBER="${number}"; break; }
  done
  [[ -n "${DISPLAY_NUMBER}" ]] || { echo "ERROR: no free X display between :90 and :99" >&2; exit 2; }
  "${XVFB_BIN}" ":${DISPLAY_NUMBER}" -screen 0 1600x1000x24 -nolisten tcp > "${WORK}/xvfb.log" 2>&1 &
  XVFB_PID=$!
  sleep 2
  kill -0 "${XVFB_PID}" 2>/dev/null || { cat "${WORK}/xvfb.log"; echo "ERROR: Xvfb did not start" >&2; exit 2; }
  export DISPLAY=":${DISPLAY_NUMBER}"
fi

# Dialogs embed in the editor window, so a capture of it shows them, and the editor
# speaks English whatever the machine's language, so the plugin finds the engine's
# own dialogs by their text. Godot 4.2 names the file by major version only.
if [[ "${OS}" == windows ]]; then
  SETTINGS_DIR="${HOME}/AppData/Roaming/Godot"
else
  SETTINGS_DIR="${XDG_CONFIG_HOME}/godot"
fi
mkdir -p "${SETTINGS_DIR}"
for settings in "editor_settings-4.tres" "editor_settings-${ENGINE_MINOR}.tres"; do
  printf '[gd_resource type="EditorSettings" format=3]\n\n[resource]\ninterface/editor/single_window_mode = true\ninterface/editor/editor_language = "en"\n' \
    > "${SETTINGS_DIR}/${settings}"
done

# ── The installed toolkit, warmed once ──────────────────────────────────────
ut_make_key "${WORK}/trusted.pem"
TEMPLATE="${WORK}/template"
ut_install_old_toolkit "${REPO_ROOT}" "${TEMPLATE}/addons/godot_mcp_toolkit" "${OLD_VERSION}" \
  "${WORK}/trusted.pem" "${WORK}/trusted.pub.pem" "update_gui_old_only.txt" \
  || { echo "ERROR: could not install the old toolkit" >&2; exit 2; }
cp -r "${REPO_ROOT}/test/update_gui_driver" "${TEMPLATE}/addons/update_gui_driver"
printf 'extends Node\n' > "${TEMPLATE}/probe_script.gd"
cat > "${TEMPLATE}/project.godot" <<'EOF'
config_version=5

[application]

config/name="Update GUI"

[editor_plugins]

enabled=PackedStringArray("res://addons/godot_mcp_toolkit/plugin.cfg", "res://addons/update_gui_driver/plugin.cfg")
EOF
ut_warm "${GODOT_BIN}" "${TEMPLATE}" "${WORK}/warm.log" \
  || { tail -30 "${WORK}/warm.log"; echo "ERROR: warm-up wrote no class cache" >&2; exit 2; }

PORT="$("${PYTHON_BIN}" -c'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
export GODOT_MCP_EDITOR_PORT="$(( PORT % 1000 + 31000 ))"
export GODOT_MCP_UPDATE_CHECK_HOST="http://127.0.0.1:${PORT}"

# A scenario's own project (its own name, so its own user:// folder), install mode
# and server replies; the latest release the server names is `tag`.
prepare() {
  local mode="$1" tag="$2"
  local dir="${WORK}/${SCENARIO}"
  mkdir -p "${dir}"
  cp -r "${TEMPLATE}" "${dir}/project"
  # The editor drops a setting at its default from project.godot, so the mode is
  # written per scenario rather than kept in the template.
  sed -i.bak "s/config\/name=\"Update GUI\"/config\/name=\"Update GUI ${SCENARIO}\"/" "${dir}/project/project.godot" \
    && rm -f "${dir}/project/project.godot.bak"
  printf '\n[mcp_toolkit]\n\nupdates/install_mode="%s"\n' "${mode}" >> "${dir}/project/project.godot"
  USER_DIR="$(ut_user_dir "${GODOT_BIN}" "${dir}/project")"
  [[ -n "${USER_DIR}" ]] || { fail "could not read the project's user folder"; return 1; }
  ut_mark_setup_seen "${USER_DIR}"
  ut_stage_release "${dir}/server" "${tag}" "${NEW_VERSION}" "${RELEASE_ZIP}" "${RELEASE_MANIFEST}" "${WORK}/trusted.pem"
  # The scenario's server takes the port the last one held, so that one is gone first.
  if [[ -n "${SERVER_PID}" ]]; then
    kill "${SERVER_PID}" 2>/dev/null
    wait "${SERVER_PID}" 2>/dev/null
  fi
  "${PYTHON_BIN}" -u -m http.server "${PORT}" --bind 127.0.0.1 --directory "${dir}/server" > "${dir}/server.log" 2>&1 &
  SERVER_PID=$!
  # The editor's first request comes within seconds of its boot, so the editor boots
  # only once the server answers.
  local ready=0
  for _ in $(seq 1 50); do
    if "${PYTHON_BIN}" -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${PORT}/repos/NPGameDev/godot-mcp-toolkit/releases/latest', timeout=1)" 2>/dev/null; then
      ready=1
      break
    fi
    sleep 0.2
  done
  [[ ${ready} -eq 1 ]] || { fail "the local server did not answer within 10 s"; return 1; }
}

# One editor boot playing `step`; waits for it and for the editor a restart starts
# on its own after it. A crash fails the scenario, even one on the way out.
# The deadline is a watchdog of this script's own rather than timeout(1): the Rust
# coreutils' timeout dumps core when its command dies of a signal, and the system's
# crash reporter keeps a report of it.
boot() {
  local step="$1"
  local dir="${WORK}/${SCENARIO}"
  local crashes_before
  crashes_before="$(grep -c "Program crashed with signal" "${dir}/boot.log" 2>/dev/null)"
  UPDATE_GUI_SCENARIO="${SCENARIO}" UPDATE_GUI_STEP="${step}" UPDATE_GUI_RESULTS="${dir}/results_${step}.txt" \
    UPDATE_GUI_SHOTS="${WORK}/shots" \
    "${GODOT_BIN}" --editor --path "${dir}/project" --rendering-driver opengl3 --audio-driver Dummy \
    >> "${dir}/boot.log" 2>&1 &
  local pid=$!
  touch "${dir}/watchdog_${step}"
  (
    for _ in $(seq 1 400); do
      sleep 1
      kill -0 "${pid}" 2>/dev/null || exit 0
    done
    rm -f "${dir}/watchdog_${step}"
    kill "${pid}" 2>/dev/null
  ) &
  if [[ "${SCENARIO}/${step}" == quit/a ]]; then
    for _ in $(seq 1 300); do
      grep -qF "[UPDATE-GUI] waiting for the quit shortcut" "${dir}/boot.log" && break
      kill -0 "${pid}" 2>/dev/null || break
      sleep 1
    done
    local window
    window="$("${XDOTOOL_BIN}" search --name "Update GUI quit" | head -1)"
    if [[ -n "${window}" ]]; then
      "${XDOTOOL_BIN}" windowfocus "${window}"
      sleep 1
      "${XDOTOOL_BIN}" key --clearmodifiers ctrl+q
    fi
  fi
  wait "${pid}"
  [[ -f "${dir}/watchdog_${step}" ]] || fail "the ${step} boot hung past 400 s"
  rm -f "${dir}/watchdog_${step}"
  local editor_pattern still_running=1
  editor_pattern="--path $(native_path "${dir}")/project"
  for _ in $(seq 1 300); do
    editors running "${editor_pattern}" || { still_running=0; break; }
    sleep 1
  done
  if [[ ${still_running} -eq 1 ]]; then
    fail "the editor after the ${step} boot still ran after 300 s"
    editors stop "${editor_pattern}"
  fi
  local crashes_after
  crashes_after="$(grep -c "Program crashed with signal" "${dir}/boot.log" 2>/dev/null)"
  (( ${crashes_after:-0} > ${crashes_before:-0} )) && fail "the ${step} boot crashed (backtrace in boot.log)"
  return 0
}

# Passes when the step's record holds `key=value` exactly.
expect() {
  local step="$1" key="$2" value="$3"
  if grep -qxF "${SCENARIO} ${key}=${value}" "${WORK}/${SCENARIO}/results_${step}.txt" 2>/dev/null; then
    pass "${step}: ${key} is ${value}"
  else
    fail "${step}: ${key} is not ${value} (recorded: $(grep -F "${SCENARIO} ${key}=" "${WORK}/${SCENARIO}/results_${step}.txt" 2>/dev/null | tr '\n' ' '))"
  fi
}

# Passes when what the step recorded under `key` holds `text`.
expect_contains() {
  local step="$1" key="$2" text="$3"
  if grep -F "${SCENARIO} ${key}=" "${WORK}/${SCENARIO}/results_${step}.txt" 2>/dev/null | grep -qF -- "${text}"; then
    pass "${step}: ${key} holds ${text}"
  else
    fail "${step}: ${key} does not hold ${text} (recorded: $(grep -F "${SCENARIO} ${key}=" "${WORK}/${SCENARIO}/results_${step}.txt" 2>/dev/null | tr '\n' ' '))"
  fi
}

# Passes when the project's .mcp.json runs server `version` and still holds the user's
# env key and the other server.
expect_mcp_json_runs() {
  local version="$1" file="${WORK}/${SCENARIO}/project/.mcp.json"
  grep -qF "@npgamedev/godot-mcp-server@${version}\"" "${file}" \
    && pass ".mcp.json runs server ${version}" || fail ".mcp.json does not run server ${version}"
  grep -qF "GODOT_MCP_TEST_KEEP" "${file}" && grep -qF "other-server" "${file}" \
    && pass ".mcp.json keeps the env key and the other server" || fail ".mcp.json lost the env key or the other server"
}

# Passes when the step recorded the pin move in `key`: the release's recommended server,
# with the user's env key and the other server kept.
expect_recorded_move() {
  local step="$1" key="$2"
  expect_contains "${step}" "${key}" "@npgamedev/godot-mcp-server@${COMPATIBLE_SERVER}\""
  expect_contains "${step}" "${key}" "GODOT_MCP_TEST_KEEP"
  expect_contains "${step}" "${key}" "other-server"
}

# Passes when the step recorded nothing under `key`.
expect_absent() {
  local step="$1" key="$2"
  if [[ ! -f "${WORK}/${SCENARIO}/results_${step}.txt" ]]; then
    fail "${step}: no results file, so ${key} cannot be shown absent"
  elif grep -qF "${SCENARIO} ${key}=" "${WORK}/${SCENARIO}/results_${step}.txt" 2>/dev/null; then
    fail "${step}: ${key} was recorded ($(grep -F "${SCENARIO} ${key}=" "${WORK}/${SCENARIO}/results_${step}.txt" | tr '\n' ' '))"
  else
    pass "${step}: no ${key} recorded"
  fi
}

# Whether the editor under test is Godot `version` or later.
engine_at_least() {
  [[ "$(printf '%s\n%s\n' "${ENGINE_MINOR}" "$1" | sort -V | head -1)" == "$1" ]]
}

expect_installed() {
  local installed
  installed="$(sed -nE 's/^version="([^"]+)".*/\1/p' "${WORK}/${SCENARIO}/project/addons/godot_mcp_toolkit/plugin.cfg")"
  [[ "${installed}" == "$1" ]] && pass "plugin.cfg reads $1" || fail "plugin.cfg reads '${installed}', not $1"
}

# .mcp.json runs OLD_SERVER. The pin is the toolkit's to move when the installed toolkit
# recommends that server or this machine's last write names it, so each mode sets those
# two facts:
#   recommended_only  recommends it, with no last write
#   last_write_only   recommends another server, and the last write names it
#   by_hand           recommends another server, with no last write, so the pin stays
pin_old_server() {
  local mode="$1"
  local project="${WORK}/${SCENARIO}/project"
  ut_write_mcp_json "${project}" "${OLD_SERVER}"
  case "${mode}" in
    recommended_only)
      ut_recommend_server "${project}/addons/godot_mcp_toolkit" "${OLD_SERVER}"
      ;;
    last_write_only | by_hand)
      ut_recommend_server "${project}/addons/godot_mcp_toolkit" "${OTHER_RECOMMENDED}"
      ;;
  esac
  case "${mode}" in
    last_write_only)
      ut_record_last_write "${project}" "${OLD_SERVER}"
      ;;
  esac
}

# ── Scenarios ───────────────────────────────────────────────────────────────
for SCENARIO in ${SCENARIOS}; do
  echo "== ${SCENARIO} (Godot ${ENGINE_MINOR})"
  case "${SCENARIO}" in
    restart)
      prepare ask "${NEW_VERSION}" || continue
      boot a
      expect a available true
      if engine_at_least 4.4; then
        expect_absent a ready_view
      else
        expect a ready_view true
        expect a restart_text Restart
      fi
      expect a step after_restart
      expect a toolkit_version "${NEW_VERSION}"
      expect a notice_shown true
      expect_installed "${NEW_VERSION}"
      ;;
    later)
      prepare ask "${NEW_VERSION}" || continue
      boot a
      expect a available true
      # Without a click nothing downloads: the verified manifest and its signature wait
      # in the update folder for the next start, and no journal is written.
      kept="${WORK}/${SCENARIO}/project/addons/.godot_mcp_toolkit_update"
      [[ -f "${kept}/${NEW_VERSION}/godot-mcp-toolkit-${NEW_VERSION}.update.json" \
        && -f "${kept}/${NEW_VERSION}/godot-mcp-toolkit-${NEW_VERSION}.update.json.sig" && ! -e "${kept}/journal.json" ]] \
        && pass "a: the verified manifest is kept for the next start, with no journal" \
        || fail "a: no kept manifest and signature, or a journal was written"
      if ls "${kept}/${NEW_VERSION}"/*.zip > /dev/null 2>&1 \
        || grep -qF "godot-mcp-toolkit-${NEW_VERSION}.zip" "${WORK}/${SCENARIO}/server.log"; then
        fail "a: the release's zip was asked for without a click"
      else
        pass "a: the release's zip was never asked for"
      fi
      boot b
      expect b window_shown true
      expect b window_pin_line ""
      expect b pressed true
      expect b window_after false
      expect b update_visible true
      pin_old_server by_hand
      boot c
      expect c window_shown true
      expect c window_pin_line ""
      expect c pressed true
      expect c badge_visible false
      boot d
      expect d window_shown false
      expect d badge_visible false
      # The window and the badge stay away because the user skipped the release the
      # check found, not because the check found nothing.
      cache="${USER_DIR}/addons/godot_mcp_toolkit/update_check_cache.json"
      grep -qE "\"latest_version\":[[:space:]]*\"${NEW_VERSION}\"" "${cache}" 2>/dev/null \
        && grep -qE "\"dismissed_version\":[[:space:]]*\"${NEW_VERSION}\"" "${cache}" \
        && pass "d: the check knows ${NEW_VERSION} and the user skipped it" \
        || fail "d: the check's cache does not hold ${NEW_VERSION} as found and skipped"
      expect_installed "${OLD_VERSION}"
      ;;
    unsaved)
      prepare ask "${NEW_VERSION}" || continue
      boot a
      expect a available true
      expect a script_edited true
      expect a ready_view true
      expect a view_names_script true
      expect a restart_text Restart
      expect a after_refuse_toolkit_version "${OLD_VERSION}"
      expect a after_refuse_view true
      expect a after_not_now_view false
      expect a after_not_now_restart_text "Restart now"
      expect a script_saved true
      expect a step after_restart
      expect a toolkit_version "${NEW_VERSION}"
      expect a notice_shown true
      expect_installed "${NEW_VERSION}"
      ;;
    untitled)
      prepare ask "${NEW_VERSION}" || continue
      boot a
      expect a available true
      expect a scene_created true
      expect a ready_view true
      expect a view_names_scene true
      expect a still_running true
      expect a after_wait_toolkit_version "${OLD_VERSION}"
      expect_installed "${NEW_VERSION}"
      ;;
    quit)
      if [[ "${OS}" == windows ]]; then
        echo "  SKIP [quit] the quit shortcut is sent with xdotool, which Windows lacks"
        continue
      fi
      prepare ask "${NEW_VERSION}" || continue
      boot a
      expect a available true
      expect a script_edited true
      expect a ready_view true
      expect a script_saved true
      grep -qF "quit_timeout" "${WORK}/quit/results_a.txt" && fail "a: the quit shortcut never closed the editor"
      expect_installed "${NEW_VERSION}"
      boot b
      expect b notice_shown true
      ;;
    server | server_edit)
      prepare ask "${NEW_VERSION}" || continue
      if [[ "${SCENARIO}" == server ]]; then
        pin_old_server last_write_only
      else
        pin_old_server recommended_only
      fi
      boot a
      expect a offer_status "${PIN_PREVIEW_LINE}"
      expect a step after_restart
      expect a notice_shown true
      expect a status "${PIN_MOVED_LINE}"
      expect a undo_visible true
      expect a update_mcp_json_visible false
      expect_recorded_move a mcp_json_moved
      expect a undo_visible_after false
      expect a status_after ""
      if [[ "${SCENARIO}" == server ]]; then
        expect_mcp_json_runs "${OLD_SERVER}"
      else
        expect_mcp_json_runs "${UPDATE_GUI_HAND_SERVER}"
      fi
      expect_installed "${NEW_VERSION}"
      ;;
    server_hand)
      prepare ask "${NEW_VERSION}" || continue
      pin_old_server by_hand
      boot a
      expect a offer_status ""
      expect a step after_restart
      expect a notice_shown true
      expect a status ""
      expect a update_mcp_json_visible false
      expect a undo_visible false
      expect_mcp_json_runs "${OLD_SERVER}"
      expect_installed "${NEW_VERSION}"
      ;;
    server_prompt)
      prepare ask "${NEW_VERSION}" || continue
      pin_old_server last_write_only
      boot a
      expect a available true
      expect a offer_status "${PIN_PREVIEW_LINE}"
      boot b
      expect b window_shown true
      expect b window_pin_line "${PIN_PREVIEW_LINE}"
      expect b pressed true
      expect_mcp_json_runs "${OLD_SERVER}"
      expect_installed "${OLD_VERSION}"
      ;;
    server_readonly)
      prepare ask "${NEW_VERSION}" || continue
      pin_old_server recommended_only
      project="${WORK}/${SCENARIO}/project"
      cp "${project}/.mcp.json" "${WORK}/${SCENARIO}/mcp_json_before"
      if [[ "${OS}" == windows ]]; then
        attrib.exe +R "$(cygpath -w "${project}/.mcp.json")"
      else
        chmod a-w "${project}/.mcp.json"
      fi
      boot a
      expect a offer_status "${PIN_PREVIEW_LINE}"
      expect a step after_restart
      expect a notice_shown true
      if [[ "${OS}" == windows ]]; then
        expect_contains a status "but .mcp.json couldn't be updated: Failed to write .mcp.json"
        expect a update_mcp_json_visible true
        expect a undo_visible false
        cmp -s "${project}/.mcp.json" "${WORK}/${SCENARIO}/mcp_json_before" \
          && pass "a: .mcp.json keeps its bytes" || fail "a: .mcp.json changed"
        grep -qF "last_written_server_spec" "${project}/.godot/editor/project_metadata.cfg" 2>/dev/null \
          && fail "a: a write was recorded" || pass "a: no write recorded"
        attrib.exe -R "$(cygpath -w "${project}/.mcp.json")"
      else
        expect a status "${PIN_MOVED_LINE}"
        expect a update_mcp_json_visible false
        expect a undo_visible true
        expect_mcp_json_runs "${COMPATIBLE_SERVER}"
        grep -qF "last_written_server_spec=\"npx:${COMPATIBLE_SERVER}\"" "${project}/.godot/editor/project_metadata.cfg" 2>/dev/null \
          && pass "a: the write is recorded" || fail "a: the write is not recorded"
      fi
      leftovers="$(ls -A "${project}" | grep -E '^\.mc.*\.tmp$|^\.mcp\.json-')"
      [[ -z "${leftovers}" ]] && pass "a: no temp file left" || fail "a: temp files left: ${leftovers}"
      expect_installed "${NEW_VERSION}"
      ;;
    server_gap)
      prepare ask "${NEW_VERSION}" || continue
      ut_recommend_server "${WORK}/${SCENARIO}/project/addons/godot_mcp_toolkit" "${GAP_RECOMMENDED}"
      boot a
      expect a available true
      expect a older_connected true
      expect_contains a older_line "MCP server ${UPDATE_GUI_OLDER_SERVER} is older than ${GAP_RECOMMENDED}"
      expect a newer_connected true
      # Only the update check runner the dock hands the panel knows this version.
      expect_contains a newer_line "MCP server ${UPDATE_GUI_NEWER_SERVER} is newer than ${GAP_RECOMMENDED}"
      expect_contains a newer_line "Update the toolkit to ${NEW_VERSION}"
      # Nothing but the dock's one-second tick repaints the line for a setting.
      expect_contains a line_before_setting "MCP server ${UPDATE_GUI_NEWER_SERVER} is newer than ${GAP_RECOMMENDED}"
      expect a hidden_by_setting true
      expect a back_without_setting true
      expect_contains a line_after_setting "MCP server ${UPDATE_GUI_NEWER_SERVER} is newer than ${GAP_RECOMMENDED}"
      expect_installed "${OLD_VERSION}"
      ;;
    major)
      prepare ask "${NEXT_MAJOR}" || continue
      boot a
      expect a badge_visible true
      expect a update_visible false
      expect a major_icon_visible true
      expect_installed "${OLD_VERSION}"
      ;;
    *)
      fail "unknown scenario"
      ;;
  esac
done

if [[ ${FAILED} -ne 0 ]]; then
  # Loud on failure, for CI, where the scratch folder is gone with the runner.
  for results in "${WORK}"/*/results_*.txt; do
    [[ -f "${results}" ]] && { echo "--- ${results#"${WORK}"/}"; cat "${results}"; }
  done
  for log in "${WORK}"/*/boot.log; do
    [[ -f "${log}" ]] && { echo "--- ${log#"${WORK}"/} (last 40 lines)"; tail -40 "${log}"; }
  done
  echo "RESULT: FAIL — see the logs (UPDATE_GUI_KEEP=1 keeps ${WORK}, UPDATE_GUI_ARTIFACTS copies the screenshots)"
  exit 1
fi
echo "RESULT: PASS — every update GUI scenario passed"
